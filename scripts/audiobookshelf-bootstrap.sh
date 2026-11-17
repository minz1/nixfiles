#!/usr/bin/env bash
set -euo pipefail

: "${SYSTEMCTL:=systemctl}"
: "${DISCOVERY_DEADLINE:=900}"
marker="$READY_DIR/audiobookshelf"
restarts="$READY_DIR/audiobookshelf.restarts"
pending="$READY_DIR/audiobookshelf.pending"
fingerprint="$FINGERPRINT_DIR/audiobookshelf.sha256"

rm -f "$marker"
umask 077
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

die() {
    echo "audiobookshelf-bootstrap: $*" >&2
    exit 1
}

call() {
    local method=$1 path=$2
    shift 2
    curl -sS --max-time 30 -o "$tmp/resp" -w '%{http_code}' -X "$method" "$@" "$ABS_URL$path"
}

api() {
    local method=$1 path=$2
    shift 2
    call "$method" "$path" -K "$tmp/auth" "$@"
}

send() {
    local method=$1 path=$2
    api "$method" "$path" -H 'Content-Type: application/json' --data-binary @"$tmp/body"
}

expect() {
    [ "$1" = 200 ] || die "$2 returned HTTP $1"
}

invocation() {
    local id
    id=$("$SYSTEMCTL" show -p InvocationID --value audiobookshelf.service) \
        || die "cannot read the InvocationID of audiobookshelf.service"
    [ -n "$id" ] || die "audiobookshelf.service has no InvocationID"
    printf '%s\n' "$id"
}

request_restart() {
    "$SYSTEMCTL" restart --no-block audiobookshelf.service \
        || die "restart request for audiobookshelf.service failed; $pending stays until it restarts"
}

token_pattern='^[A-Za-z0-9._-]+$'
login() {
    jq -n --rawfile p "$1" '{username: "root", password: $p}' > "$tmp/body"
    local code token
    code=$(call POST /login -H 'Content-Type: application/json' --data-binary @"$tmp/body")
    case $code in
        200) ;;
        401) return 1 ;;
        *) die "POST /login returned HTTP $code" ;;
    esac
    jq -r '.user.accessToken // empty' "$tmp/resp" > "$tmp/token" || die "POST /login returned an unreadable response"
    token=$(< "$tmp/token")
    [[ $token =~ $token_pattern ]] || die "POST /login returned a missing or malformed access token"
    printf 'header = "Authorization: Bearer %s"\n' "$token" > "$tmp/auth"
}

settings_match() {
    jq -e -n --slurpfile c "$tmp/current" --slurpfile d "$tmp/desired" '
        def norm: if type == "array" then sort elif . == "" then null else . end;
        $c[0] as $c | $d[0] as $d
        | all($d | keys[]; . as $k
            | ($k == "authOpenIDClientSecret" and ($c | has($k) | not))
              or (($c[$k] | norm) == ($d[$k] | norm)))
        and (($c.authOpenIDMatchExistingBy // "") == "")' > /dev/null
}

has_library() {
    jq -e --arg p "$1" 'any(.libraries[].folders[]?; .fullPath == $p)' "$tmp/libraries" > /dev/null
}

deadline=$((SECONDS + 60))
until curl -fsS --max-time 5 -o /dev/null "$ABS_URL/healthcheck" 2> /dev/null; do
    [ "$SECONDS" -lt "$deadline" ] || die "healthcheck did not pass within 60s"
    sleep 1
done

deadline=$((SECONDS + DISCOVERY_DEADLINE))
until curl -fsS --max-time 15 -o "$tmp/discovery" "$OIDC_DISCOVERY_URL" 2> "$tmp/discovery.err"; do
    [ "$SECONDS" -lt "$deadline" ] \
        || die "issuer discovery failed for ${DISCOVERY_DEADLINE}s: $(< "$tmp/discovery.err")"
    sleep 2
done
jq -S -c --rawfile secret "$OIDC_SECRET_FILE" --arg id "$OIDC_CLIENT_ID" --arg sub "$REDIRECT_SUBFOLDER" '
    if [.issuer, .authorization_endpoint, .token_endpoint, .userinfo_endpoint, .jwks_uri, .end_session_endpoint]
        | all(type == "string" and . != "") then . else error("issuer discovery is missing an endpoint") end
    | {
        authOpenIDIssuerURL: .issuer,
        authOpenIDAuthorizationURL: .authorization_endpoint,
        authOpenIDTokenURL: .token_endpoint,
        authOpenIDUserInfoURL: .userinfo_endpoint,
        authOpenIDJwksURL: .jwks_uri,
        authOpenIDLogoutURL: .end_session_endpoint,
        authOpenIDTokenSigningAlgorithm: "RS256",
        authOpenIDClientID: $id,
        authOpenIDClientSecret: $secret,
        authOpenIDGroupClaim: "abs_roles",
        authOpenIDSubfolderForRedirectURLs: $sub,
        authOpenIDMobileRedirectURIs: ["audiobookshelf://oauth"],
        authOpenIDAutoRegister: true,
        authOpenIDAutoLaunch: false,
        authOpenIDAdvancedPermsClaim: null,
        authOpenIDButtonText: "Sign in with Authentik",
        authLoginCustomMessage: "Use the Sign in with Authentik button below.",
        authActiveAuthMethods: ["local", "openid"]
    }' "$tmp/discovery" > "$tmp/desired" || die "issuer discovery response unusable"
want_fp=$(sha256sum < "$tmp/desired")
want_fp=${want_fp%% *}

expect "$(call GET /status)" "GET /status"
case $(jq -r '.isInit' "$tmp/resp") in
    true) ;;
    false)
        jq -n --rawfile p "$ROOT_PASSWORD_FILE" '{newRoot: {username: "root", password: $p}}' > "$tmp/body"
        expect "$(call POST /init -H 'Content-Type: application/json' --data-binary @"$tmp/body")" "POST /init"
        ;;
    *) die "GET /status returned no isInit" ;;
esac

if ! login "$ROOT_PASSWORD_FILE"; then
    previous=${ROOT_PASSWORD_PREVIOUS_FILE:-}
    [ -n "$previous" ] && [ -s "$previous" ] \
        || die "root login failed with audiobookshelf_root_password and no audiobookshelf_root_password_previous"
    login "$previous" \
        || die "root login failed with both audiobookshelf_root_password and audiobookshelf_root_password_previous"
    jq -n --rawfile o "$previous" --rawfile n "$ROOT_PASSWORD_FILE" '{password: $o, newPassword: $n}' > "$tmp/body"
    expect "$(send PATCH /api/me/password)" "PATCH /api/me/password"
    login "$ROOT_PASSWORD_FILE" || die "root login with the new audiobookshelf_root_password failed after the change"
    echo "audiobookshelf-bootstrap: root password rotated to audiobookshelf_root_password"
fi

expect "$(api GET /api/auth-settings)" "GET /api/auth-settings"
mv "$tmp/resp" "$tmp/current"
have_fp=$(cat "$fingerprint" 2> /dev/null || true)
auth_changed=false
if ! settings_match || [ "$have_fp" != "$want_fp" ]; then
    [ "$(cat "$restarts" 2> /dev/null || echo 0)" -lt 1 ] \
        || die "auth settings need another change right after a restart for one; not restarting again (remove $restarts once fixed)"
    inv=$(invocation)
    printf '%s\n' "$inv" > "$pending"
    jq --slurpfile c "$tmp/current" \
        'if ($c[0].authOpenIDMatchExistingBy // "") != "" then . + {authOpenIDMatchExistingBy: null} else . end' \
        "$tmp/desired" > "$tmp/body"
    expect "$(send PATCH /api/auth-settings)" "PATCH /api/auth-settings"
    auth_changed=true
elif [ -e "$pending" ]; then
    inv=$(invocation)
    [ "$inv" = "$(cat "$pending")" ] || rm -f "$pending" "$restarts"
fi

expect "$(api GET /api/libraries)" "GET /api/libraries"
mv "$tmp/resp" "$tmp/libraries"
for lib in "Ebooks:$LIBRARY_EBOOKS" "Audiobooks:$LIBRARY_AUDIOBOOKS"; do
    has_library "${lib#*:}" && continue
    jq -n --arg n "${lib%%:*}" --arg p "${lib#*:}" '{name: $n, mediaType: "book", folders: [{fullPath: $p}]}' > "$tmp/body"
    expect "$(send POST /api/libraries)" "POST /api/libraries"
    echo "audiobookshelf-bootstrap: created library ${lib%%:*}"
done

expect "$(api GET /api/auth-settings)" "GET /api/auth-settings"
mv "$tmp/resp" "$tmp/current"
settings_match || die "auth settings read back differ from the desired settings"
expect "$(api GET /api/libraries)" "GET /api/libraries"
mv "$tmp/resp" "$tmp/libraries"
has_library "$LIBRARY_EBOOKS" || die "no library has $LIBRARY_EBOOKS after reconcile"
has_library "$LIBRARY_AUDIOBOOKS" || die "no library has $LIBRARY_AUDIOBOOKS after reconcile"

if [ "$auth_changed" = true ]; then
    printf '%s\n' "$want_fp" > "$fingerprint.tmp"
    mv "$fingerprint.tmp" "$fingerprint"
    echo $(($(cat "$restarts" 2> /dev/null || echo 0) + 1)) > "$restarts"
    request_restart
    echo "audiobookshelf-bootstrap: auth settings changed, restarted audiobookshelf.service; the next run verifies"
    exit 0
fi

if [ -e "$pending" ]; then
    request_restart
    echo "audiobookshelf-bootstrap: audiobookshelf.service has not restarted since the last auth change; restart requested again"
    exit 0
fi

rm -f "$restarts"
(umask 022 && : > "$marker")
echo "audiobookshelf-bootstrap: verified, ready"
