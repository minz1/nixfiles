#!/usr/bin/env bash
set -euo pipefail

: "${SYSTEMCTL:=systemctl}"
marker="$READY_DIR/bindery"
pending="$READY_DIR/bindery.pending"
restarts="$READY_DIR/bindery.restarts"
inflight="$READY_DIR/bindery.oidc-inflight"
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
[[ $key =~ ^[[:graph:]]+$ ]] || die "bindery_api_key has non-printable characters"
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

invocation() {
    local inv
    inv=$("$SYSTEMCTL" show -p InvocationID --value bindery.service) \
        || die "cannot read the InvocationID of bindery.service"
    [ -n "$inv" ] || die "bindery.service has no InvocationID"
    printf '%s\n' "$inv"
}

request_restart() {
    "$SYSTEMCTL" restart --no-block bindery.service \
        || die "restart request for bindery.service failed; $pending stays until it restarts"
}

oidc_restart=false
oidc_untrusted=false
oidc_status() {
    jq -r '[.[] | select(.id == "authentik")] | first | .status // {} | "\(.state // "") \(.last_attempt // "")"' "$tmp/resp"
}

require_oidc_ok() {
    local deadline=$((SECONDS + 60))
    while :; do
        case $(oidc_status) in
            "ok "*) return 0 ;;
            "failed "*) die "OIDC provider authentik is not loaded after reconcile" ;;
        esac
        [ "$SECONDS" -lt "$deadline" ] || die "OIDC provider authentik is not loaded after reconcile"
        sleep 1
        req GET /api/v1/auth/oidc/providers
    done
}

wait_oidc() {
    local before=$1 now deadline=$((SECONDS + 60))
    while :; do
        req GET /api/v1/auth/oidc/providers
        now=$(oidc_status)
        case $now in
            "ok "*)
                rm -f "$inflight"
                return 0
                ;;
            "failed "*)
                if [ "$now" != "$before" ]; then
                    rm -f "$inflight"
                    die "OIDC provider authentik failed to load, see the Bindery log"
                fi
                ;;
        esac
        [ "$SECONDS" -lt "$deadline" ] || die "OIDC provider authentik did not load within 60s"
        sleep 1
    done
}

restart_for_oidc() {
    [ "$(cat "$restarts" 2> /dev/null || echo 0)" -lt 1 ] \
        || die "OIDC provider needs another change before bindery.service restarted for the last one; not restarting again (remove $restarts once fixed)"
    local inv
    inv=$(invocation)
    printf '%s\n' "$inv" > "$pending"
    oidc_restart=true
}

put_oidc() {
    local inv
    inv=$(invocation)
    printf '%s\n' "$inv" > "$inflight"
    req PUT /api/v1/auth/oidc/providers "$tmp/body"
}

reconcile_oidc() {
    jq -n --arg i "$OIDC_ISSUER" --arg c "$OIDC_CLIENT_ID" '[{
        id: "authentik", name: "Authentik", issuer: $i, client_id: $c,
        scopes: ["openid", "profile", "email"], allowed_groups: ["book-users", "arr-admins"]
    }]' > "$tmp/desired"
    req GET /api/v1/auth/oidc/providers
    local fp present same send=0 before
    if [ "$verify" = 1 ] && [ "$oidc_restart" = false ] && [ ! -e "$pending" ]; then require_oidc_ok; fi
    fp=$(fp_calc oidc "oidc $OIDC_ISSUER $OIDC_CLIENT_ID")
    present=$(jq '[.[] | select(.id == "authentik")] | length' "$tmp/resp")
    same=$(jq --slurpfile d "$tmp/desired" \
        '[.[] | {id, name, issuer, client_id, scopes, allowed_groups}] == $d[0]' "$tmp/resp")
    if [ "$present" = 0 ] || [ "$fp" != "$(fp_get oidc)" ]; then send=1; fi
    before=$(oidc_status)
    if [ "$same" = true ] && [ "$send" = 0 ]; then
        [ "$verify" = 0 ] || return 0
        [ ! -e "$pending" ] || return 0
        if [ "$oidc_untrusted" = true ]; then
            drift "OIDC provider authentik (an earlier reload is unconfirmed)"
            restart_for_oidc
            return 0
        fi
        case $before in
            "failed "*) ;;
            *) return 0 ;;
        esac
        drift "OIDC provider authentik (reload after failed discovery)"
    else
        drift "OIDC provider authentik"
    fi
    if [ "$send" = 1 ]; then
        jq --rawfile s "$tmp/oidc" '.[0].client_secret = $s' "$tmp/desired" > "$tmp/body"
    else
        cp "$tmp/desired" "$tmp/body"
    fi
    case $oidc_untrusted:$before in
        true:* | false:"ok "*)
            restart_for_oidc
            put_oidc
            ;;
        *)
            put_oidc
            wait_oidc "$before"
            ;;
    esac
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

if [ -e "$pending" ]; then
    inv=$(invocation)
    [ "$inv" = "$(cat "$pending")" ] || rm -f "$pending" "$restarts"
fi
if [ -e "$inflight" ]; then
    inv=$(invocation)
    if [ "$inv" = "$(cat "$inflight")" ]; then
        oidc_untrusted=true
    else
        rm -f "$inflight"
    fi
fi

prowlarr_id=""
reconcile
api POST "/api/v1/prowlarr/$prowlarr_id/sync"
case $status in
    2??) ;;
    *) echo "bindery-bootstrap: warning: Prowlarr sync returned HTTP $status" >&2 ;;
esac
verify=1
reconcile
if [ "$oidc_restart" = true ]; then
    echo $(($(cat "$restarts" 2> /dev/null || echo 0) + 1)) > "$restarts"
    request_restart
    echo "bindery-bootstrap: OIDC provider changed, restarted bindery.service; the next run verifies"
    exit 0
fi
if [ -e "$pending" ]; then
    request_restart
    echo "bindery-bootstrap: bindery.service has not restarted since the last OIDC change; restart requested again"
    exit 0
fi
rm -f "$restarts"
(umask 022 && : > "$marker")
echo "bindery-bootstrap: configuration verified"
