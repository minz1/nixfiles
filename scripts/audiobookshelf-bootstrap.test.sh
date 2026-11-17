#!/usr/bin/env bash
set -euo pipefail

script="$(cd "$(dirname "$0")" && pwd)/audiobookshelf-bootstrap.sh"
work="$(mktemp -d)"
pids=()
cleanup() {
    for p in "${pids[@]}"; do kill "$p" 2> /dev/null || true; done
    rm -rf "$work"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $1" >&2
    exit 1
}
[ -f "$script" ] || fail "missing $script"

bash_bin=$(command -v bash)
state="$work/state"
bin="$work/bin"
mkdir -p "$state" "$bin" "$work/fp" "$work/ready"

cat > "$work/handler" << 'HANDLER'
set -uo pipefail
export LC_ALL=C
s=$STUB_STATE
reply() {
    printf 'HTTP/1.1 %s X\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' \
        "$1" "${#2}" "$2"
    exit 0
}
read -r method target _ || exit 0
path=${target%%\?*}
len=0
auth=""
while IFS= read -r line; do
    line=${line%$'\r'}
    [ -z "$line" ] && break
    case ${line,,} in
        content-length:*) len=${line#*:} && len=${len// /} ;;
        authorization:*) auth=${line#*: } ;;
    esac
done
body=""
[ "$len" -gt 0 ] && body=$(head -c "$len")
if [ "$path" != /healthcheck ]; then
    printf '%s %s\n' "$method" "$path" >> "$s/requests"
    printf '%s' "$body" > "$s/body.$(wc -l < "$s/requests")"
fi
authed() { [ -n "$auth" ] && grep -qxF "$auth" "$s/tokens"; }
case "$method $path" in
    "GET /healthcheck") reply 200 OK ;;
    "GET "*/.well-known/openid-configuration)
        [ -e "$s/discovery_down" ] && reply 503 Unavailable
        reply 200 "$(cat "$s/discovery.json")"
        ;;
    "GET /status")
        if [ -e "$s/init" ]; then reply 200 '{"isInit":true}'; else reply 200 '{"isInit":false}'; fi
        ;;
    "POST /init")
        [ -e "$s/init" ] && reply 500 Error
        jq -j '.newRoot.password' <<< "$body" > "$s/rootpw"
        touch "$s/init"
        reply 200 OK
        ;;
    "POST /login")
        if jq -e --rawfile p "$s/rootpw" '.username == "root" and .password == $p' <<< "$body" > /dev/null; then
            t="tok-$RANDOM$RANDOM"
            [ -e "$s/bad_token" ] && reply 200 "{\"user\":{\"accessToken\":\"$t\\\"\\nheader = x\"}}"
            echo "Bearer $t" >> "$s/tokens"
            echo "$t" >> "$s/alltokens"
            reply 200 "{\"user\":{\"username\":\"root\",\"accessToken\":\"$t\"}}"
        fi
        reply 401 Unauthorized
        ;;
esac
authed || reply 401 Unauthorized
case "$method $path" in
    "GET /api/auth-settings")
        if [ -e "$s/hide_secret" ]; then
            reply 200 "$(jq -c 'del(.authOpenIDClientSecret)' "$s/auth.json")"
        fi
        reply 200 "$(cat "$s/auth.json")"
        ;;
    "PATCH /api/auth-settings")
        if [ ! -e "$s/ignore_patch" ]; then
            jq -c --argjson b "$body" '. + $b | .authOpenIDAdvancedPermsClaim //= ""' "$s/auth.json" > "$s/auth.tmp" && mv "$s/auth.tmp" "$s/auth.json"
        fi
        reply 200 '{"updated":true}'
        ;;
    "GET /api/libraries") reply 200 "$(jq -c '{libraries: .}' "$s/libs.json")" ;;
    "POST /api/libraries")
        [ -e "$s/lib_fail" ] && reply 500 Error
        jq -c --argjson b "$body" '. + [{id: ("lib-" + (length | tostring)), name: $b.name, mediaType: $b.mediaType,
            folders: [{fullPath: $b.folders[0].fullPath}]}]' "$s/libs.json" > "$s/libs.tmp" && mv "$s/libs.tmp" "$s/libs.json"
        reply 200 '{}'
        ;;
    "PATCH /api/me/password")
        if jq -e --rawfile p "$s/rootpw" '.password == $p' <<< "$body" > /dev/null; then
            jq -j '.newPassword' <<< "$body" > "$s/rootpw"
            : > "$s/tokens"
            reply 200 OK
        fi
        reply 400 'Invalid password'
        ;;
esac
reply 404 'Not Found'
HANDLER

for c in curl jq mktemp rm mv cat sha256sum sleep; do
    printf '#!%s\n{ printf "%%s\\037" %q "$@"; echo; } >> %q\nexec %q "$@"\n' \
        "$bash_bin" "$c" "$work/argv" "$(command -v "$c")" > "$bin/$c"
done
cat > "$bin/systemctl-stub" << STUB
#!$bash_bin
echo "\$*" >> "$work/systemctl"
case "\$*" in
    "show -p InvocationID --value audiobookshelf.service") cat "$state/invocation" ;;
    "restart --no-block audiobookshelf.service")
        [ -e "$state/restart_fails" ] && exit 1
        echo "inv-\$RANDOM\$RANDOM" > "$state/invocation"
        ;;
    *) exit 1 ;;
esac
STUB
chmod +x "$bin"/*
echo inv-0 > "$state/invocation"

port=18090
dport=18091
export STUB_STATE="$state"
for p in "$port" "$dport"; do
    socat "TCP-LISTEN:$p,bind=127.0.0.1,reuseaddr,fork" "EXEC:$bash_bin $work/handler" 2> /dev/null &
    pids+=($!)
    until (exec 3<> "/dev/tcp/127.0.0.1/$p") 2> /dev/null; do sleep 0.1; done
done

issuer="http://127.0.0.1:$dport/application/o/audiobookshelf/"
cat > "$state/discovery.json" << JSON
{"issuer": "$issuer", "authorization_endpoint": "http://127.0.0.1:$dport/authorize",
 "token_endpoint": "http://127.0.0.1:$dport/token", "userinfo_endpoint": "http://127.0.0.1:$dport/userinfo",
 "jwks_uri": "http://127.0.0.1:$dport/jwks", "end_session_endpoint": "http://127.0.0.1:$dport/end-session"}
JSON
echo '{"authOpenIDAdvancedPermsClaim":"","authOpenIDAutoLaunch":false,"authLoginCustomMessage":null,"authActiveAuthMethods":["local"],"authOpenIDIssuerURL":null,"authOpenIDClientSecret":null,"authOpenIDAutoRegister":false,"authOpenIDMatchExistingBy":null,"authOpenIDMobileRedirectURIs":[]}' > "$state/auth.json"
echo '[]' > "$state/libs.json"
: > "$state/tokens"

export ABS_URL="http://127.0.0.1:$port"
export OIDC_DISCOVERY_URL="http://127.0.0.1:$dport/application/o/audiobookshelf/.well-known/openid-configuration"
export OIDC_CLIENT_ID=abs-client
export OIDC_SECRET_FILE="$work/oidc" ROOT_PASSWORD_FILE="$work/root" ROOT_PASSWORD_PREVIOUS_FILE="$work/root-prev"
export FINGERPRINT_DIR="$work/fp" READY_DIR="$work/ready"
export LIBRARY_EBOOKS=/data/books/ebooks LIBRARY_AUDIOBOOKS=/data/books/audiobooks
export REDIRECT_SUBFOLDER=/audiobookshelf
export SYSTEMCTL=systemctl-stub DISCOVERY_DEADLINE=3
secrets=("oidc s3cret 1'x" "oidc-s3cret-2" "root pw 'a\"1" "root-pw-2" "root-pw-other")
printf '%s' "${secrets[0]}" > "$OIDC_SECRET_FILE"
printf '%s' "${secrets[2]}" > "$ROOT_PASSWORD_FILE"
marker="$work/ready/audiobookshelf"
counter="$work/ready/audiobookshelf.restarts"
pending="$work/ready/audiobookshelf.pending"

run() {
    : > "$state/requests"
    : > "$work/systemctl"
    rc=0
    PATH="$bin:$PATH" bash "$script" > "$work/out" 2>&1 || rc=$?
    cat "$work/out" >> "$work/allout"
}
ok() { run && [ "$rc" = 0 ] || fail "$1: exit $rc: $(cat "$work/out")"; }
bad() { run && [ "$rc" != 0 ] || fail "$1: expected failure: $(cat "$work/out")"; }
count() { grep -cxF "$1" "$state/requests" || true; }
body_of() { echo "$state/body.$(grep -nxF "$1" "$state/requests" | tail -n1 | cut -d: -f1)"; }
restarted() { grep -qxF "restart --no-block audiobookshelf.service" "$work/systemctl"; }

ok a
[ "$(count "POST /init")" = 1 ] || fail "a: no POST /init"
[ "$(count "POST /login")" -ge 1 ] || fail "a: no login"
[ "$(count "PATCH /api/auth-settings")" = 1 ] || fail "a: no auth PATCH"
pb=$(body_of "PATCH /api/auth-settings")
jq -e --arg i "$issuer" --arg d "http://127.0.0.1:$dport" --rawfile s "$OIDC_SECRET_FILE" '
    .authOpenIDIssuerURL == $i and .authOpenIDAuthorizationURL == $d + "/authorize"
    and .authOpenIDTokenURL == $d + "/token" and .authOpenIDUserInfoURL == $d + "/userinfo"
    and .authOpenIDJwksURL == $d + "/jwks" and .authOpenIDLogoutURL == $d + "/end-session"
    and .authOpenIDTokenSigningAlgorithm == "RS256" and .authOpenIDClientID == "abs-client"
    and .authOpenIDSubfolderForRedirectURLs == "/audiobookshelf"
    and .authOpenIDClientSecret == $s and .authOpenIDGroupClaim == "abs_roles"
    and .authOpenIDMobileRedirectURIs == ["audiobookshelf://oauth"] and .authOpenIDAutoRegister == true
    and (.authOpenIDButtonText | type) == "string" and (.authLoginCustomMessage | type) == "string"
    and .authActiveAuthMethods == ["local", "openid"] and (has("authOpenIDMatchExistingBy") | not)
    and .authOpenIDAutoLaunch == false and has("authOpenIDAdvancedPermsClaim") and .authOpenIDAdvancedPermsClaim == null' "$pb" > /dev/null \
    || fail "a: PATCH body wrong"
[ "$(jq -j .password "$(body_of "POST /login")")" = "${secrets[2]}" ] || fail "a: login password"
restarted || fail "a: no restart --no-block"
[ ! -e "$marker" ] || fail "a: marker written in a restart run"
[ "$(cat "$counter")" = 1 ] || fail "a: restart counter"
[ -s "$FINGERPRINT_DIR/audiobookshelf.sha256" ] || fail "a: no fingerprint"
[ "$(cat "$pending")" = inv-0 ] || fail "a: pending does not hold the pre-PATCH InvocationID"
[ "$(count "POST /api/libraries")" = 2 ] || fail "c: libraries not created"
jq -e 'map({name, mediaType, p: .folders[0].fullPath}) == [
    {name: "Ebooks", mediaType: "book", p: "/data/books/ebooks"},
    {name: "Audiobooks", mediaType: "book", p: "/data/books/audiobooks"}]' "$state/libs.json" > /dev/null \
    || fail "c: libraries wrong"

ok b
[ "$(count "POST /init")" = 0 ] || fail "b: POST /init on an initialised server"
[ "$(count "PATCH /api/auth-settings")" = 0 ] || fail "b: PATCH with matching settings"
[ "$(count "POST /api/libraries")" = 0 ] || fail "b: library re-created"
[ -e "$marker" ] || fail "b: no marker"
[ ! -e "$counter" ] || fail "b: restart counter kept"
[ ! -e "$pending" ] || fail "b: pending kept after the restart"
! restarted || fail "b: restarted with no change"

jq -c '[{id: "x", name: "My Ebooks", mediaType: "book", folders: [{fullPath: "/data/books/ebooks"}]}]' -n > "$state/libs.json"
ok c
[ "$(count "POST /api/libraries")" = 1 ] || fail "c: library POST count"
[ "$(jq -j '.name' "$(body_of "POST /api/libraries")")" = Audiobooks ] || fail "c: created the wrong library"
[ "$(jq length "$state/libs.json")" = 2 ] || fail "c: library count"
[ "$(count "PATCH /api/auth-settings")" = 0 ] || fail "c: auth PATCH on a library-only change"
[ -e "$marker" ] || fail "c: library-only change did not publish the marker in one run"
! restarted || fail "c: restart on a library-only change"

touch "$state/hide_secret"
printf '%s' "${secrets[1]}" > "$OIDC_SECRET_FILE"
ok g
[ "$(count "PATCH /api/auth-settings")" = 1 ] || fail "g: rotated client secret not PATCHed"
[ "$(jq -j .authOpenIDClientSecret "$(body_of "PATCH /api/auth-settings")")" = "${secrets[1]}" ] || fail "g: PATCH secret"
restarted || fail "g: no restart"
[ ! -e "$marker" ] || fail "g: marker in a restart run"
ok g2
[ "$(count "PATCH /api/auth-settings")" = 0 ] || fail "g2: PATCH after converging"
[ -e "$marker" ] || fail "g2: no marker"
rm "$state/hide_secret"

export OIDC_CLIENT_ID=abs-client-2
ok loop1
restarted || fail "loop1: no restart"
export OIDC_CLIENT_ID=abs-client-3
bad loop2
[ "$(count "PATCH /api/auth-settings")" = 0 ] || fail "loop2: PATCH past the loop guard"
! restarted || fail "loop2: restarted past the loop guard"
[ ! -e "$marker" ] || fail "loop2: marker"
grep -qF "remove $counter" "$work/out" || fail "loop2: message does not name the counter file"
rm "$counter"
ok loop3
ok loop4
[ -e "$marker" ] || fail "loop4: no marker"

touch "$state/restart_fails"
export OIDC_CLIENT_ID=abs-client-5
inv_before=$(cat "$state/invocation")
bad p1
[ "$(count "PATCH /api/auth-settings")" = 1 ] || fail "p1: no PATCH"
restarted || fail "p1: no restart request"
[ "$(cat "$pending")" = "$inv_before" ] || fail "p1: pending missing after a failed restart request"
[ ! -e "$marker" ] || fail "p1: marker"
bad p2
[ "$(count "PATCH /api/auth-settings")" = 0 ] || fail "p2: PATCH while the restart is pending"
restarted || fail "p2: restart not re-requested"
[ ! -e "$marker" ] || fail "p2: marker while InvocationID is unchanged"
[ -e "$pending" ] || fail "p2: pending dropped"
rm "$state/restart_fails"
ok p3
restarted || fail "p3: restart not re-requested"
[ ! -e "$marker" ] || fail "p3: marker in the run that requested the restart"
[ "$(cat "$state/invocation")" != "$inv_before" ] || fail "p3: stub InvocationID unchanged"
ok p4
[ -e "$marker" ] || fail "p4: no marker after InvocationID changed"
[ ! -e "$pending" ] || fail "p4: pending kept"
[ ! -e "$counter" ] || fail "p4: counter kept"
touch "$state/restart_fails"
export OIDC_CLIENT_ID=abs-client-6
bad p5
echo inv-manual > "$state/invocation"
ok p6
! restarted || fail "p6: restart requested after InvocationID changed"
[ -e "$marker" ] || fail "p6: no marker once InvocationID changed"
rm "$state/restart_fails"

touch "$state/bad_token"
bad token
grep -qxF "audiobookshelf-bootstrap: POST /login returned a missing or malformed access token" "$work/out" \
    || fail "token: no fixed message"
[ "$(count "GET /api/auth-settings")" = 0 ] || fail "token: API used with a malformed token"
rm "$state/bad_token"
ok token-back

export OIDC_CLIENT_ID=abs-client-7
ok r1
restarted || fail "r1: no restart"
[ "$(cat "$counter")" = 1 ] || fail "r1: counter"
jq -c 'map(select(.name != "Audiobooks"))' "$state/libs.json" > "$state/libs.tmp" && mv "$state/libs.tmp" "$state/libs.json"
touch "$state/lib_fail"
bad r2
[ "$(count "PATCH /api/auth-settings")" = 0 ] || fail "r2: PATCH with matching settings"
[ ! -e "$pending" ] || fail "r2: pending kept after InvocationID changed"
[ ! -e "$counter" ] || fail "r2: counter kept after the restart was confirmed"
[ ! -e "$marker" ] || fail "r2: marker after a library failure"
rm "$state/lib_fail"
printf '%s' "${secrets[0]}" > "$OIDC_SECRET_FILE"
ok r3
[ "$(count "PATCH /api/auth-settings")" = 1 ] || fail "r3: rotation not PATCHed"
restarted || fail "r3: rotation did not restart"
ok r4
[ -e "$marker" ] || fail "r4: no marker"

touch "$state/ignore_patch"
export OIDC_CLIENT_ID=abs-client-4
fp_before=$(cat "$FINGERPRINT_DIR/audiobookshelf.sha256")
bad d
grep -q "read back differ" "$work/out" || fail "d: no mismatch message"
[ ! -e "$marker" ] || fail "d: marker after a read-back mismatch"
! restarted || fail "d: restart after a read-back mismatch"
[ "$(cat "$FINGERPRINT_DIR/audiobookshelf.sha256")" = "$fp_before" ] || fail "d: fingerprint written"
rm "$state/ignore_patch"
ok d2
ok d3
[ -e "$marker" ] || fail "d3: no marker"

OIDC_DISCOVERY_URL="http://127.0.0.1:1/.well-known/openid-configuration" bad issuer-down
[ "$(count "PATCH /api/auth-settings")" = 0 ] || fail "issuer-down: PATCH"
[ ! -e "$marker" ] || fail "issuer-down: marker"
ok issuer-up
touch "$state/discovery_down"
(sleep 3 && rm "$state/discovery_down") &
pids+=($!)
DISCOVERY_DEADLINE=30 ok issuer-retry
[ ! -e "$state/discovery_down" ] || fail "issuer-retry: finished before discovery came back"
[ -e "$marker" ] || fail "issuer-retry: no marker"

printf '%s' "${secrets[2]}" > "$ROOT_PASSWORD_PREVIOUS_FILE"
printf '%s' "${secrets[3]}" > "$ROOT_PASSWORD_FILE"
ok h-rotate
[ "$(count "PATCH /api/me/password")" = 1 ] || fail "h: no password PATCH"
[ "$(cat "$state/rootpw")" = "${secrets[3]}" ] || fail "h: root password not rotated"
[ -e "$marker" ] || fail "h: no marker after rotation"
ok h-after
[ "$(count "PATCH /api/me/password")" = 0 ] || fail "h: password PATCH after rotation"

printf '%s' "${secrets[4]}" > "$state/rootpw"
bad h-fail
[ "$(count "PATCH /api/me/password")" = 0 ] || fail "h: password PATCH with both logins failing"
[ ! -e "$marker" ] || fail "h: marker with both logins failing"
grep -q audiobookshelf_root_password "$work/out" || fail "h: message does not name audiobookshelf_root_password"
rm "$ROOT_PASSWORD_PREVIOUS_FILE"
bad h-noprev
grep -q audiobookshelf_root_password "$work/out" || fail "h-noprev: message"
printf '%s' "${secrets[3]}" > "$state/rootpw"
ok h-back

mapfile -t issued < "$state/alltokens"
[ "${#issued[@]}" -gt 0 ] || fail "e: no tokens issued"
for c in curl jq mktemp rm mv cat sha256sum; do
    grep -q "^$c"$'\037' "$work/argv" || fail "e: no recorded $c calls"
done
for s in "${secrets[@]}" "${issued[@]}"; do
    if grep -qF -- "$s" "$work/argv"; then fail "e: a secret or token reached a command argv"; fi
    if grep -qF -- "$s" "$work/allout"; then fail "e: a secret or token reached stdout/stderr"; fi
done

issuer_gets=0
while IFS=$'\037' read -r -a args; do
    [ "${args[0]}" = curl ] || continue
    url=""
    method=GET
    prev=""
    for a in "${args[@]}"; do
        case $a in
            http://* | https://*) url=$a ;;
            --data* | -d | -F | --form*) method=POST ;;
        esac
        [ "$prev" = -X ] && method=$a
        prev=$a
    done
    case $url in
        "$ABS_URL"/*) ;;
        "$OIDC_DISCOVERY_URL" | http://127.0.0.1:1/*)
            [ "$method" = GET ] || fail "f: $method to the issuer"
            issuer_gets=$((issuer_gets + 1))
            ;;
        *) fail "f: call to '$url' is neither ABS loopback nor issuer discovery" ;;
    esac
done < "$work/argv"
[ "$issuer_gets" -gt 0 ] || fail "f: argv log has no discovery GET"

echo "audiobookshelf-bootstrap: all cases pass"
