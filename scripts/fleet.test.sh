#!/usr/bin/env bash
set -euo pipefail

FLEET_JSON="$(cd "$(dirname "$0")" && pwd)/fleet.test.json"
export FLEET_JSON
fleet="$(dirname "$0")/fleet.sh"

fail() {
    echo "FAIL: case $1" >&2
    exit 1
}

[ "$(bash "$fleet" hosts)" = $'a\nb\nc' ] || fail "1: hosts"
[ "$(bash "$fleet" phases)" = $'a\nb c' ] || fail "2: phases"
[ "$(bash "$fleet" target b)" = root@10.0.0.2 ] || fail "3: target b"

rc=0
out=$(bash "$fleet" target nope 2> err) || rc=$?
[ "$rc" -eq 1 ] || fail "4: unknown host exit $rc, want 1"
[ -z "$out" ] || fail "4: unknown host printed '$out'"
[ "$(cat err)" = "fleet: unknown host nope" ] || fail "4: stderr '$(cat err)'"
rm -f err

[ "$(bash "$fleet" address d)" = 10.0.0.4 ] || fail "5: address d"

[ "$(bash "$fleet" hosts --kind vps)" = a ] || fail "7: hosts --kind vps"
[ -z "$(bash "$fleet" hosts --kind device)" ] || fail "7: --kind device lists an undeployable node"

for args in "" bogus "target" "target a b" "hosts --kind" "hosts --bogus vps"; do
    rc=0
    read -ra argv <<< "$args"
    bash "$fleet" "${argv[@]}" > /dev/null 2>&1 || rc=$?
    [ "$rc" -eq 2 ] || fail "6: '$args' exit $rc, want 2"
done

echo ok
