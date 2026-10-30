#!/usr/bin/env bash
set -euo pipefail

script="$(cd "$(dirname "$0")" && pwd)/ci-affected-hosts.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() {
    echo "FAIL: case $1" >&2
    exit 1
}

mkdir -p "$tmp/bin" "$tmp/fixtures" "$tmp/repo"
cat > "$tmp/bin/fleet" <<EOF
#!$(command -v bash)
[ "\$1" = hosts ] && printf '%s\n' a b c
EOF
cat > "$tmp/bin/nix" <<EOF
#!$(command -v bash)
echo "warning: stub noise" >&2
for arg in "\$@"; do
    case "\$arg" in
        git+file://*\?rev=*) rev=\${arg##*rev=}; rev=\${rev%%#*} ;;
    esac
done
cat "$tmp/fixtures/\$rev.json"
EOF
chmod +x "$tmp/bin/fleet" "$tmp/bin/nix"
export PATH="$tmp/bin:$PATH"

cd "$tmp/repo"
git init -q
commit() {
    git -c user.name=t -c user.email=t commit -q --allow-empty -m c
    git rev-parse HEAD
}
c1=$(commit)
c2=$(commit)
c3=$(commit)
c4=$(commit)
echo '{"a":"1","b":"1"}' > "$tmp/fixtures/$c1.json"
echo '{"a":"1","b":"2","c":"1"}' > "$tmp/fixtures/$c2.json"
echo '{"a":"1","b":"2","c":"1","d":"9"}' > "$tmp/fixtures/$c3.json"

run() { bash "$script" "$@" 2> "$tmp/err"; }

[ "$(run "$c1" "$c2")" = "b c" ] || fail "1: changed and new host"
[ "$(run "$c2" "$c2")" = "" ] || fail "2: no change"
for before in "" 0000000000000000000000000000000000000000 deadbeef; do
    [ "$(run "$before" "$c2")" = "a b c" ] || fail "3: fallback for '$before'"
done
[ "$(run "$c2" "$c3")" = "" ] || fail "4: host outside fleet ignored"
[ "$(run "$c4" "$c2")" = "a b c" ] || fail "5: base eval failure"
grep -q "base eval failed" "$tmp/err" || fail "5: stderr '$(cat "$tmp/err")'"

rc=0
out=$(run "$c2" "$c4") || rc=$?
[ "$rc" -ne 0 ] || fail "6: head eval failure exit 0"
[ -z "$out" ] || fail "6: head eval failure printed '$out'"

git checkout -q "$c3"
[ "$(run "$c2")" = "" ] || fail "7: after defaults to HEAD"
[ "$(run "$(git rev-parse --short "$c1")" "$c2")" = "b c" ] || fail "8: short sha"

echo ok
