#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
log="$work/querylog.json"
out="$work/out"
pid=
cleanup() {
    if [ -n "$pid" ]; then kill "$pid" 2> /dev/null || true; fi
    pkill -f -- "-F $log" 2> /dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

mkdir "$work/bin"
ln -s "$(command -v busybox)" "$work/bin/tail"
export PATH="$work/bin:$PATH"

cmd=()
procd_open_instance() { :; }
procd_close_instance() { :; }
procd_set_param() {
    if [ "$1" = command ]; then
        shift
        cmd=("$@")
    fi
}
# shellcheck source=adguard-querylog
. "$here/adguard-querylog"
start_service
[ "${cmd[0]}" = awk ] || fail "command is not awk: ${cmd[0]}"

touch "$out"
busybox awk -v f="$log" -v dst="cat >> $out" "${cmd[-1]}" 2> "$work/err" &
pid=$!

wait_for() {
    local deadline=$((SECONDS + 10))
    until "$@"; do
        [ "$SECONDS" -lt "$deadline" ] || fail "timed out: $*"
        sleep 0.2
    done
}
tail_started() { grep -q "can.t open" "$work/err"; }
has_lines() { [ "$(wc -l < "$out")" -ge "$1" ]; }

wait_for tail_started

entry() {
    printf '{"T":"2026-10-23T19:00:00Z","QH":"%s","QT":"A","QC":"IN","CP":""%s,"Result":{},"Elapsed":1000,"IP":"192.168.0.10"}\n' "$1" "$2"
}

entry nx.example ',"Answer":"EjSBgwABAAAAAAAA"' > "$log"
{
    entry ok.example ',"Answer":"EjSBgAABAAEAAAAA"'
    entry servfail.example ',"Answer":"EjSBggABAAAAAAAA"'
    entry refused.example ',"Answer":"EjSBhQABAAAAAAAA"'
    entry noanswer.example ''
    entry orig-after.example ',"Answer":"EjSBgwABAAAAAAAA","OrigAnswer":"EjSBgAABAAEAAAAA"'
    entry orig-before.example ',"OrigAnswer":"EjSBgAABAAEAAAAA","Answer":"EjSBgwABAAAAAAAA"'
    entry pre-rotate.example ''
} >> "$log"
wait_for has_lines 8

mv "$log" "$log.1"
{
    entry post-rotate.example ''
    entry sentinel.example ''
} > "$log"
wait_for has_lines 10
sleep 1.5
[ "$(wc -l < "$out")" -eq 10 ] || fail "expected 10 lines, got $(wc -l < "$out")"

jq -e . "$out" > /dev/null || fail "output is not valid JSON lines"

rcode() {
    jq -r --arg q "$1" 'select(.QH == $q) | .Rcode // "none"' "$out"
}
[ "$(rcode nx.example)" = 3 ] || fail "nx rcode $(rcode nx.example)"
[ "$(rcode ok.example)" = 0 ] || fail "ok rcode $(rcode ok.example)"
[ "$(rcode servfail.example)" = 2 ] || fail "servfail rcode $(rcode servfail.example)"
[ "$(rcode refused.example)" = 5 ] || fail "refused rcode $(rcode refused.example)"
[ "$(rcode noanswer.example)" = none ] || fail "noanswer got an rcode"
[ "$(rcode orig-after.example)" = 3 ] || fail "orig-after rcode $(rcode orig-after.example)"
[ "$(rcode orig-before.example)" = 3 ] || fail "orig-before rcode $(rcode orig-before.example)"

[ "$(jq -s 'map(select(has("Answer") or has("OrigAnswer"))) | length' "$out")" = 0 ] || fail "Answer or OrigAnswer left in output"
for q in pre-rotate.example post-rotate.example sentinel.example; do
    [ "$(jq -r --arg q "$q" 'select(.QH == $q) | .QH' "$out" | wc -l)" = 1 ] || fail "$q not shipped exactly once"
done

echo "PASS"
