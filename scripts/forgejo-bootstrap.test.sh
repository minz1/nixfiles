#!/usr/bin/env bash
set -euo pipefail

script="$(cd "$(dirname "$0")" && pwd)/forgejo-bootstrap.sh"
work="$(mktemp -d)"
export HOME="$work" PGHOST="$work" PGDATABASE=forgejo
export FORGEJO_WORK_DIR="$work/forgejo" FORGEJO_CUSTOM="$work/forgejo/custom"
stub_pid=""
cleanup() {
    [ -n "$stub_pid" ] && kill "$stub_pid" 2> /dev/null
    pg_ctl -D "$work/pg" -m immediate stop > /dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $1" >&2
    exit 1
}
q() { psql -tAq -c "$1"; }
cfg() { q "select cfg::jsonb->>'$1' from login_source where name = 'authentik'"; }

initdb -D "$work/pg" -A trust > /dev/null
pg_ctl -D "$work/pg" -o "-k $work -c listen_addresses=''" -l "$work/pg.log" -w start > /dev/null
createdb forgejo

mkdir -p "$FORGEJO_CUSTOM/conf"
cat > "$FORGEJO_CUSTOM/conf/app.ini" << INI
[database]
DB_TYPE = postgres
HOST = $work
NAME = forgejo
USER = $(id -un)
[security]
INSTALL_LOCK = true
[log]
LEVEL = Warn
INI
forgejo migrate > /dev/null 2>&1 || fail "forgejo migrate"

port=18080
base="http://127.0.0.1:$port"
mkdir -p "$work/www/.well-known"
cat > "$work/www/.well-known/openid-configuration" << JSON
{"issuer": "$base", "authorization_endpoint": "$base/authorize", "token_endpoint": "$base/token",
 "userinfo_endpoint": "$base/userinfo", "jwks_uri": "$base/jwks"}
JSON
stub_up() {
    busybox httpd -f -p "127.0.0.1:$port" -h "$work/www" &
    stub_pid=$!
    until (exec 3<> "/dev/tcp/127.0.0.1/$port") 2> /dev/null; do sleep 0.1; done
}
stub_down() {
    kill "$stub_pid"
    wait "$stub_pid" 2> /dev/null || true
    stub_pid=""
}

export FORGEJO_DB=forgejo OIDC_DISCOVERY_URL="$base/.well-known/openid-configuration"
export OIDC_SECRET_FILE="$work/oidc" RUNNER_SECRET_FILE="$work/runner"
export RUNNER_SCOPE=minz1 RUNNER_NAME=minz-runner-0
printf '%s' 5a69464e270e0821aaaaaaaaaaaaaaaaaaaaaaaa > "$RUNNER_SECRET_FILE"
run() { bash -euo pipefail "$script" > "$work/out" 2>&1 || fail "$1: exit $? $(cat "$work/out")"; }

stub_up
printf '%s' "s3cret 1'x" > "$OIDC_SECRET_FILE"
run "1"
[ "$(q "select count(*) from login_source where name = 'authentik'")" = 1 ] || fail "1: source count; script said: $(cat "$work/out")"
[ "$(cfg ClientSecret)" = "s3cret 1'x" ] || fail "1: client secret = $(cfg ClientSecret)"
[ "$(cfg AdminGroup)" = forgejo-admins ] || fail "1: admin group"
[ "$(cfg GroupClaimName)" = groups ] || fail "1: group claim"
[ "$(q "select count(*) from action_runner")" = 0 ] || fail "1: runner registered without minz1"
grep -q "runner registration skipped" "$work/out" || fail "1: no skip line"

printf '%s' s3cret-2 > "$OIDC_SECRET_FILE"
run "2"
[ "$(q "select count(*) from login_source where name = 'authentik'")" = 1 ] || fail "2: source count"
[ "$(cfg ClientSecret)" = s3cret-2 ] || fail "2: rotated secret"

stub_down
printf '%s' s3cret-3 > "$OIDC_SECRET_FILE"
run "3"
grep -q "auth source not updated" "$work/out" || fail "3: no discovery failure line"
[ "$(q "select count(*) from login_source where name = 'authentik'")" = 1 ] || fail "3: source count"
[ "$(cfg AdminGroup)" = forgejo-admins ] || fail "3: admin group changed"
[ "$(cfg ClientSecret)" = s3cret-3 ] || fail "3: secret not written while discovery down"
# discovery that accepts but never answers: the step gives up well inside the unit's start timeout
sleep 120 | busybox nc -l -p 18081 > /dev/null 2>&1 &
hang_pid=$!
start=$(date +%s)
OIDC_DISCOVERY_URL="http://127.0.0.1:18081/.well-known/openid-configuration" run "3b"
took=$(($(date +%s) - start))
kill "$hang_pid" 2> /dev/null || true
grep -q "auth source not updated" "$work/out" || fail "3b: no discovery failure line"
[ "$took" -lt 40 ] || fail "3b: hung discovery took ${took}s"
[ "$(cfg AdminGroup)" = forgejo-admins ] || fail "3b: admin group changed"

stub_up

forgejo admin user create --username minz1 --email t@example.invalid --random-password > /dev/null 2>&1 \
    || fail "4: user create"
uid=$(q "select id from \"user\" where lower_name = 'minz1'")
run "4"
[ "$(q "select count(*) from action_runner where name = 'minz-runner-0' and owner_id = $uid and repo_id = 0")" = 1 ] \
    || fail "4: runner not registered to minz1"
run "4b"
[ "$(q "select count(*) from action_runner")" = 1 ] || fail "4b: runner registered twice"

printf '%s' xyz > "$RUNNER_SECRET_FILE"
run "5"
grep -q "runner registration failed" "$work/out" || fail "5: no registration failure line"
[ "$(cfg ClientSecret)" = s3cret-3 ] || fail "5: auth source changed"

if grep -qE -- '--secret( |=|$)' "$script"; then fail "6: secret passed as argv"; fi
if grep -qF '`' "$script"; then fail "6: backtick spawns a shell"; fi

echo "forgejo-bootstrap: all cases pass"
