#!/usr/bin/env bash
set -euo pipefail

marker="$READY_DIR/bindery"
fpfile="$FINGERPRINT_DIR/bindery.sha256"

rm -f "$marker"
umask 077
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

die() {
    echo "bindery-bootstrap: $*" >&2
    exit 1
}

load() {
    local v
    v=$(< "$2")
    [ -n "$v" ] || die "$2 is empty"
    printf '%s' "$v" > "$tmp/$1"
}

load apikey "$API_KEY_FILE"
load oidc "$OIDC_SECRET_FILE"
load prowlarr "$PROWLARR_KEY_FILE"
load decypharr "$DECYPHARR_TOKEN_FILE"
load ntfy-password "$NTFY_PASSWORD_FILE"
{
    printf '%s:' "$NTFY_USER"
    cat "$tmp/ntfy-password"
} | base64 -w0 > "$tmp/ntfy"

key=$(< "$tmp/apikey")
key=${key//\\/\\\\}
key=${key//\"/\\\"}
printf 'header = "X-Api-Key: %s"\n' "$key" > "$tmp/curlrc"
unset key

status=""
api() {
    local method=$1 path=$2 body=${3:-}
    local args=(-sS --max-time 60 -K "$tmp/curlrc" -X "$method" -o "$tmp/resp" -w '%{http_code}')
    if [ -n "$body" ]; then
        args+=(-H 'Content-Type: application/json' --data-binary "@$body")
    fi
    status=$(curl "${args[@]}" "$BINDERY_URL$path") || status=000
}

req() {
    api "$@"
    case $status in
        2??) ;;
        *) die "$1 $2 returned HTTP $status" ;;
    esac
}

verify=0
drift() {
    [ "$verify" = 0 ] || die "$1 still differs after reconcile"
    echo "bindery-bootstrap: updating $1"
}

fp_calc() {
    {
        printf '%s\n' "$2"
        cat "$tmp/$1"
    } | sha256sum | cut -d' ' -f1
}

fp_get() {
    [ -f "$fpfile" ] || return 0
    awk -v n="$1" '$1 == n { print $2 }' "$fpfile"
}

fp_put() {
    {
        if [ -f "$fpfile" ]; then awk -v n="$1" '$1 != n' "$fpfile"; fi
        printf '%s %s\n' "$1" "$2"
    } > "$fpfile.tmp"
    mv "$fpfile.tmp" "$fpfile"
}

reconcile_oidc() {
    jq -n --arg i "$OIDC_ISSUER" --arg c "$OIDC_CLIENT_ID" '[{
        id: "authentik", name: "Authentik", issuer: $i, client_id: $c,
        scopes: ["openid", "profile", "email"], allowed_groups: ["book-users", "arr-admins"]
    }]' > "$tmp/desired"
    req GET /api/v1/auth/oidc/providers
    local fp present same send=0
    fp=$(fp_calc oidc "oidc $OIDC_ISSUER $OIDC_CLIENT_ID")
    present=$(jq '[.[] | select(.id == "authentik")] | length' "$tmp/resp")
    same=$(jq --slurpfile d "$tmp/desired" \
        '[.[] | {id, name, issuer, client_id, scopes, allowed_groups}] == $d[0]' "$tmp/resp")
    if [ "$present" = 0 ] || [ "$fp" != "$(fp_get oidc)" ]; then send=1; fi
    [ "$same" = true ] && [ "$send" = 0 ] && return 0
    drift "OIDC provider authentik"
    if [ "$send" = 1 ]; then
        jq --rawfile s "$tmp/oidc" '.[0].client_secret = $s' "$tmp/desired" > "$tmp/body"
    else
        cp "$tmp/desired" "$tmp/body"
    fi
    req PUT /api/v1/auth/oidc/providers "$tmp/body"
    if [ "$send" = 1 ]; then fp_put oidc "$fp"; fi
}

reconcile_mode() {
    req GET /api/v1/auth/config
    [ "$(jq -r .mode "$tmp/resp")" = enabled ] && return 0
    drift "auth mode"
    printf '{"mode":"enabled"}' > "$tmp/body"
    req PUT /api/v1/auth/mode "$tmp/body"
}

id=""
upsert() {
    local path=$1 cred=${2:-} secret=${3:-} ctx=${4:-} test=${5:-0}
    local name fp="" send=0 same
    name=$(jq -r .name "$tmp/desired")
    req GET "$path"
    jq --arg n "$name" '[.[] | select(.name == $n)] | first // {}' "$tmp/resp" > "$tmp/current"
    id=$(jq -r '.id // empty' "$tmp/current")
    same=$(jq --slurpfile d "$tmp/desired" '. as $c | all($d[0] | to_entries[]; $c[.key] == .value)' "$tmp/current")
    if [ -n "$cred" ]; then
        fp=$(fp_calc "$secret" "$name $ctx")
        if [ -z "$id" ] || [ "$(jq -r ".${cred}Configured" "$tmp/current")" != true ] \
            || [ "$fp" != "$(fp_get "$name")" ]; then
            send=1
        fi
    fi
    [ -n "$id" ] && [ "$same" = true ] && [ "$send" = 0 ] && return 0
    drift "$name"
    if [ "$send" = 1 ]; then
        jq --rawfile s "$tmp/$secret" --arg f "$cred" '.[$f] = $s' "$tmp/desired" > "$tmp/body"
    else
        cp "$tmp/desired" "$tmp/body"
    fi
    if [ -n "$id" ]; then
        req PUT "$path/$id" "$tmp/body"
    else
        req POST "$path" "$tmp/body"
        id=$(jq -r '.id // empty' "$tmp/resp")
        [ -n "$id" ] || die "POST $path returned no id"
    fi
    if [ "$test" = 1 ]; then req POST "$path/$id/test"; fi
    if [ "$send" = 1 ]; then fp_put "$name" "$fp"; fi
}

reconcile_prowlarr() {
    jq -n --arg u "$PROWLARR_URL" \
        '{name: "Prowlarr", url: $u, syncOnStartup: true, enabled: true}' > "$tmp/desired"
    upsert /api/v1/prowlarr apiKey prowlarr "$PROWLARR_URL"
    prowlarr_id=$id
}

reconcile_clients() {
    local c
    for c in qbittorrent sabnzbd; do
        jq -n --arg t "$c" --arg h "$DECYPHARR_HOST" --arg p "$DECYPHARR_PORT" '{
            name: (if $t == "qbittorrent" then "decypharr-qbit" else "decypharr-sab" end),
            type: $t, host: $h, port: ($p | tonumber), useSsl: false,
            urlBase: (if $t == "qbittorrent" then "" else "/sabnzbd" end),
            category: "bindery", enabled: true, removeOnImport: true
        } + (if $t == "qbittorrent" then {username: "bindery"} else {} end)' > "$tmp/desired"
        if [ "$c" = qbittorrent ]; then
            upsert /api/v1/downloadclient password decypharr "$c $DECYPHARR_HOST $DECYPHARR_PORT" 1
        else
            upsert /api/v1/downloadclient apiKey decypharr "$c $DECYPHARR_HOST $DECYPHARR_PORT" 1
        fi
    done
}

reconcile_settings() {
    local kv k v
    for kv in import.mode=copy import.audiobook.mode=copy \
        requests.auto_approve_default=true requests.max_pending_per_user=25; do
        k=${kv%%=*}
        v=${kv#*=}
        api GET "/api/v1/setting/$k"
        case $status in
            200) [ "$(jq -r .value "$tmp/resp")" = "$v" ] && continue ;;
            404) ;;
            *) die "GET /api/v1/setting/$k returned HTTP $status" ;;
        esac
        drift "setting $k"
        jq -n --arg v "$v" '{value: $v}' > "$tmp/body"
        req PUT "/api/v1/setting/$k" "$tmp/body"
    done
}

reconcile_roots() {
    local p
    for p in /data/books/ebooks /data/books/audiobooks; do
        req GET /api/v1/rootfolder
        jq -e --arg p "$p" 'any(.[]; .path == $p)' "$tmp/resp" > /dev/null && continue
        drift "root folder $p"
        jq -n --arg p "$p" '{path: $p}' > "$tmp/body"
        req POST /api/v1/rootfolder "$tmp/body"
    done
}

reconcile_ntfy() {
    jq -n --rawfile b "$tmp/ntfy" --arg u "$NTFY_URL" --arg t "$NTFY_TOPIC" '{
        name: "books-requests", type: "webhook", url: $u, method: "POST",
        headers: ({Authorization: ("Basic " + $b)} | tojson), topic: $t, enabled: true,
        onGrab: false, onImport: false, onUpgrade: false, onFailure: false,
        onHealth: false, onBookAnnounced: false, onRequestCreated: true
    }' > "$tmp/desired"
    upsert /api/v1/notification
}

reconcile() {
    reconcile_oidc
    reconcile_mode
    reconcile_prowlarr
    reconcile_clients
    reconcile_settings
    reconcile_roots
    reconcile_ntfy
}

deadline=$((SECONDS + 180))
until curl -fsS --max-time 5 -o /dev/null "$BINDERY_URL/api/v1/health" 2> /dev/null; do
    [ "$SECONDS" -lt "$deadline" ] || die "Bindery not healthy after 180s"
    sleep 2
done

prowlarr_id=""
reconcile
req POST "/api/v1/prowlarr/$prowlarr_id/sync"
verify=1
reconcile
: > "$marker"
echo "bindery-bootstrap: configuration verified"
