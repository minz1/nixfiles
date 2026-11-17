#!/usr/bin/env bash
set -euo pipefail

script="$(cd "$(dirname "$0")" && pwd)/bindery-bootstrap.sh"
work="$(mktemp -d)"
stub_pid=""
cleanup() {
    if [ -n "$stub_pid" ]; then kill "$stub_pid" 2> /dev/null || true; fi
    rm -rf "$work"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

[ -f "$script" ] || fail "missing $script"

state="$work/state"
mkdir -p "$state/settings" "$work/www/cgi-bin" "$work/bin" "$work/secrets" "$work/fp" "$work/ready"
for c in providers prowlarr downloadclient rootfolder notification; do echo '[]' > "$state/$c.json"; done
echo local-only > "$state/mode"
: > "$state/log"
: > "$state/fail"

bash_bin=$(command -v bash)
{
    printf '#!%s\n' "$bash_bin"
    cat << 'CGI'
set -euo pipefail
s=$STUB_STATE
m=$REQUEST_METHOD
p=$PATH_INFO
body=$(cat)
reply() {
    printf 'Status: %s\r\nContent-Type: application/json\r\n\r\n%s\n' "$1" "$2"
    exit 0
}
if [ "$p" = /api/v1/health ]; then reply 200 '{"status":"ok"}'; fi
echo "$m $p" >> "$s/log"
[ "${HTTP_X_API_KEY:-}" = "$(cat "$s/apikey")" ] || reply 401 '{"error":"unauthorized"}'
if grep -qxF "$m $p" "$s/fail"; then reply 502 '{"error":"injected"}'; fi
blank='map(if has("apiKey") then .apiKeyConfigured = (.apiKey != "") | .apiKey = "" else . end
    | if has("password") then .passwordConfigured = (.password != "") | .password = "" else . end)'
coll() { cat "$s/$1.json"; }
save() { cat > "$s/$1.json.tmp" && mv "$s/$1.json.tmp" "$s/$1.json"; }
case "$m $p" in
    "GET /api/v1/auth/config")
        reply 200 "$(jq -nc --arg m "$(cat "$s/mode")" '{mode: $m, apiKey: "BODY-LEAK-MARKER", username: ""}')" ;;
    "PUT /api/v1/auth/mode")
        jq -r .mode <<< "$body" > "$s/mode"
        reply 200 '{"mode":"enabled"}' ;;
    "GET /api/v1/auth/oidc/providers")
        reply 200 "$(coll providers | jq -c 'map(del(.client_secret) + {status: {state: "ready"}})')" ;;
    "PUT /api/v1/auth/oidc/providers")
        new=$(jq -c --slurpfile e "$s/providers.json" 'map(. as $p | (first($e[0][] | select(.id == $p.id)) // {}) as $prev
            | if ($p.client_secret // "") == "" then .client_secret = $prev.client_secret else . end)' <<< "$body")
        if jq -e 'any(.[]; (.client_secret // "") == "")' <<< "$new" > /dev/null; then
            reply 400 '{"error":"client_secret required for new provider"}'
        fi
        save providers <<< "$new"
        reply 200 '{"ok":true}' ;;
    "GET /api/v1/prowlarr" | "GET /api/v1/downloadclient")
        reply 200 "$(coll "${p##*/}" | jq -c "$blank")" ;;
    "GET /api/v1/rootfolder" | "GET /api/v1/notification")
        reply 200 "$(coll "${p##*/}")" ;;
    "POST /api/v1/prowlarr" | "POST /api/v1/downloadclient" | "POST /api/v1/rootfolder" | "POST /api/v1/notification")
        c=${p##*/}
        new=$(jq -c --argjson b "$body" '($b + {id: (length + 1)}) as $n | . + [$n]' "$s/$c.json")
        save "$c" <<< "$new"
        reply 201 "$(jq -c "last | [.] | $blank | first" <<< "$new")" ;;
    "PUT /api/v1/prowlarr/"* | "PUT /api/v1/downloadclient/"*)
        c=${p#/api/v1/}
        c=${c%%/*}
        i=${p##*/}
        new=$(jq -c --argjson b "$body" --argjson i "$i" 'map(if .id == $i
            then . + ($b | with_entries(select((.key == "apiKey" or .key == "password") and .value == "" | not)))
            else . end)' "$s/$c.json")
        save "$c" <<< "$new"
        reply 200 '{}' ;;
    "PUT /api/v1/notification/"*)
        i=${p##*/}
        new=$(jq -c --argjson b "$body" --argjson i "$i" 'map(if .id == $i then $b + {id: $i} else . end)' "$s/notification.json")
        save notification <<< "$new"
        reply 200 '{}' ;;
    "POST /api/v1/prowlarr/"*/sync)
        reply 200 '{"added":0,"updated":0,"removed":0}' ;;
    "POST /api/v1/downloadclient/"*/test)
        reply 200 '{"message":"Connection verified"}' ;;
    "GET /api/v1/setting/"*)
        k=${p##*/}
        [ -f "$s/settings/$k" ] || reply 404 '{"error":"setting not found"}'
        reply 200 "$(jq -nc --arg k "$k" --rawfile v "$s/settings/$k" '{key: $k, value: $v}')" ;;
    "PUT /api/v1/setting/"*)
        jq -j .value <<< "$body" > "$s/settings/${p##*/}"
        reply 200 '{}' ;;
esac
reply 404 '{"error":"not found"}'
CGI
} > "$work/www/cgi-bin/b"
chmod +x "$work/www/cgi-bin/b"

real_curl=$(command -v curl)
for t in curl jq base64 sha256sum; do
    real=$(command -v "$t")
    printf '#!%s\nprintf "%%s\\0" %s "$@" >> %q\nprintf "\\n" >> %q\nexec %q "$@"\n' \
        "$bash_bin" "$t" "$work/argv" "$work/argv" "$real" > "$work/bin/$t"
    chmod +x "$work/bin/$t"
done

port=18787
STUB_STATE="$state" busybox httpd -f -p "127.0.0.1:$port" -h "$work/www" &
stub_pid=$!
until "$real_curl" -s -o /dev/null "http://127.0.0.1:$port/cgi-bin/b/api/v1/health"; do sleep 0.1; done

api_key='k3y-"q\b-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
oidc1='oidc "s3cret" 1'
oidc2=oidc-second-SECRET
prowlarr_key=prowlarr-KEY-ffffffffffffffff
token1=decypharr-TOKEN-one-1111
token2=decypharr-TOKEN-two-2222
ntfy_pw=ntfy-PASSWORD-xyz
ntfy_b64=$(printf 'bindery:%s' "$ntfy_pw" | base64 -w0)
printf '%s' "$api_key" > "$state/apikey"
printf '%s\n' "$api_key" > "$work/secrets/api"
printf '%s' "$oidc1" > "$work/secrets/oidc"
printf '%s' "$prowlarr_key" > "$work/secrets/prowlarr"
printf '%s' "$token1" > "$work/secrets/decypharr"
printf '%s' "$ntfy_pw" > "$work/secrets/ntfy"

export BINDERY_URL="http://127.0.0.1:$port/cgi-bin/b"
export API_KEY_FILE="$work/secrets/api" OIDC_SECRET_FILE="$work/secrets/oidc"
export OIDC_ISSUER=https://auth.example.invalid/application/o/bindery/ OIDC_CLIENT_ID=bindery-client
export PROWLARR_URL=http://127.0.0.1:9696/prowlarr PROWLARR_KEY_FILE="$work/secrets/prowlarr"
export DECYPHARR_HOST=127.0.0.1 DECYPHARR_PORT=8282 DECYPHARR_TOKEN_FILE="$work/secrets/decypharr"
export NTFY_URL=https://ntfy.example.invalid NTFY_TOPIC=books-requests NTFY_USER=bindery
export NTFY_PASSWORD_FILE="$work/secrets/ntfy"
export FINGERPRINT_DIR="$work/fp" READY_DIR="$work/ready"
marker="$READY_DIR/bindery"

run() {
    : > "$state/log"
    local rc=0
    PATH="$work/bin:$PATH" bash "$script" > "$work/out" 2>&1 || rc=$?
    cat "$work/out" >> "$work/allout"
    return "$rc"
}
ok() { run || fail "$1: exit $? $(cat "$work/out")"; }
writes() { grep -v "^GET " "$state/log" | LC_ALL=C sort | tr '\n' ';' || true; }
expect_writes() {
    local got
    got=$(writes)
    [ "$got" = "$2" ] || fail "$1: writes were '$got', want '$2'"
}
st() { jq -r "$2" "$state/$1.json"; }

ok "1 fresh"
[ -f "$marker" ] || fail "1: no marker after one run"
[ "$(cat "$state/mode")" = enabled ] || fail "1: auth mode"
[ "$(st providers '.[0].client_secret')" = "$oidc1" ] || fail "1: oidc secret"
[ "$(st providers '.[0].allowed_groups | join(",")')" = book-users,arr-admins ] || fail "1: allowed_groups"
[ "$(st providers '.[0].issuer')" = "$OIDC_ISSUER" ] || fail "1: issuer"
[ "$(st providers 'length')" = 1 ] || fail "1: provider count"
[ "$(st prowlarr '.[0] | [.url, .apiKey, .syncOnStartup, .enabled] | join(" ")')" = \
    "$PROWLARR_URL $prowlarr_key true true" ] || fail "1: prowlarr"
[ "$(st downloadclient '.[] | select(.name == "decypharr-qbit") | [.type, .host, .port, .password, .category, .enabled, .removeOnImport] | join(" ")')" = \
    "qbittorrent 127.0.0.1 8282 $token1 bindery true true" ] || fail "1: qbit client"
[ "$(st downloadclient '.[] | select(.name == "decypharr-sab") | [.type, .host, .port, .apiKey, .urlBase, .category, .enabled, .removeOnImport] | join(" ")')" = \
    "sabnzbd 127.0.0.1 8282 $token1 /sabnzbd bindery true true" ] || fail "1: sab client"
for kv in import.mode=copy import.audiobook.mode=copy requests.auto_approve_default=true requests.max_pending_per_user=25; do
    [ "$(cat "$state/settings/${kv%%=*}")" = "${kv#*=}" ] || fail "1: setting $kv"
done
[ "$(st rootfolder '[.[].path] | join(",")')" = /data/books/ebooks,/data/books/audiobooks ] || fail "1: root folders"
[ "$(st notification '.[0] | [.url, .topic, .enabled, .onRequestCreated, .onGrab, (.headers | fromjson | .Authorization)] | join(" ")')" = \
    "$NTFY_URL books-requests true true false Basic $ntfy_b64" ] || fail "1: ntfy notification"
grep -qx 'POST /api/v1/downloadclient/1/test' "$state/log" || fail "1: qbit not tested"
grep -qx 'POST /api/v1/downloadclient/2/test' "$state/log" || fail "1: sab not tested"
[ "$(stat -c %a "$FINGERPRINT_DIR/bindery.sha256")" = 600 ] || fail "1: fingerprint file mode"

ok "2 no change"
[ -f "$marker" ] || fail "2: no marker"
expect_writes "2" "POST /api/v1/prowlarr/1/sync;"

printf '%s' "$token2" > "$DECYPHARR_TOKEN_FILE"
ok "3 rotated decypharr token"
expect_writes "3" "POST /api/v1/downloadclient/1/test;POST /api/v1/downloadclient/2/test;POST /api/v1/prowlarr/1/sync;PUT /api/v1/downloadclient/1;PUT /api/v1/downloadclient/2;"
[ "$(st downloadclient '[.[] | .password // .apiKey] | join(" ")')" = "$token2 $token2" ] || fail "3: token not rotated"
[ -f "$marker" ] || fail "3: no marker"

printf '%s' "$oidc2" > "$OIDC_SECRET_FILE"
ok "4 rotated oidc secret"
expect_writes "4" "POST /api/v1/prowlarr/1/sync;PUT /api/v1/auth/oidc/providers;"
[ "$(st providers '.[0].client_secret')" = "$oidc2" ] || fail "4: oidc secret not rotated"

printf move > "$state/settings/import.mode"
ok "5 settings drift"
expect_writes "5" "POST /api/v1/prowlarr/1/sync;PUT /api/v1/setting/import.mode;"
[ -f "$marker" ] || fail "5: settings change did not publish the marker in one run"

printf move > "$state/settings/import.mode"
echo 'PUT /api/v1/setting/import.mode' > "$state/fail"
if run; then fail "6: exit 0 on HTTP 502"; fi
[ -f "$marker" ] && fail "6: marker left after a failed run"
grep -q 'PUT /api/v1/setting/import.mode returned HTTP 502' "$work/out" || fail "6: no error line: $(cat "$work/out")"

printf '%s' "$token1" > "$DECYPHARR_TOKEN_FILE"
echo 'POST /api/v1/downloadclient/1/test' > "$state/fail"
if run; then fail "7: exit 0 on failed client test"; fi
[ -f "$marker" ] && fail "7: marker after failed client test"
: > "$state/fail"
ok "7b retry after failed test"
grep -qx 'PUT /api/v1/downloadclient/1' "$state/log" || fail "7b: client not rewritten after a failed test"
[ -f "$marker" ] || fail "7b: no marker"

printf '%s' wrong-key > "$state/apikey"
if run; then fail "8: exit 0 with a rejected API key"; fi
[ -f "$marker" ] && fail "8: marker with a rejected API key"
printf '%s' "$api_key" > "$state/apikey"
ok "8b"

for v in "$api_key" "$oidc1" "$oidc2" "$prowlarr_key" "$token1" "$token2" "$ntfy_pw" "$ntfy_b64" BODY-LEAK-MARKER; do
    if grep -qaF -- "$v" "$work/argv"; then fail "9: a secret reached argv"; fi
done
grep -qaF -- "-K" "$work/argv" || fail "9: curl not given a config file"
for v in "$api_key" "$oidc2" "$prowlarr_key" "$token1" "$ntfy_pw" "$ntfy_b64" BODY-LEAK-MARKER; do
    if grep -qaF -- "$v" "$work/allout"; then fail "9: a secret reached stdout/stderr"; fi
done

echo "bindery-bootstrap: all cases pass"
