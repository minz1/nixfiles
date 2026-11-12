#!/usr/bin/env bash
set -euo pipefail

scripts="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export STUB_WORK="$work"
mkdir -p "$work/bin" "$work/remote"
export PATH="$work/bin:$PATH"

cat > "$work/bin/fleet" << 'EOF'
#!/usr/bin/env bash
case "$*" in
    "host attic") echo minz-attic-0 ;;
    "address minz-attic-0") echo 10.10.0.12 ;;
    *) exit 99 ;;
esac
EOF
cat > "$work/bin/git" << 'EOF'
#!/usr/bin/env bash
echo "$STUB_WORK"
EOF
cat > "$work/bin/curl" << 'EOF'
#!/usr/bin/env bash
exit "${STUB_CURL_RC:-0}"
EOF
cat > "$work/bin/nix" << 'EOF'
#!/usr/bin/env bash
[ "$1 $2" = "store info" ] && exit "${STUB_NIX_STORE_RC:-0}"
[ "$1" = path-info ] || exit 98
if [[ " $* " == *" --store "* ]]; then
    p="${@: -1}"
    f="$STUB_WORK/remote/$(basename "$p")"
    [ -f "$f" ] || exit 1
    printf '{"%s":{"narHash":"%s"}}' "$p" "$(cat "$f")"
    exit 0
fi
cat "$STUB_WORK/local.json"
EOF
chmod +x "$work/bin/"*
sed -i "1s|.*|#!$BASH|" "$work"/bin/*

fail() {
    echo "FAIL: $1" >&2
    exit 1
}
a=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-from-attic
b=/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-built-here
local_json() {
    printf '{"%s":{"narHash":"sha256-A","signatures":["homelab:x"]},"%s":{"narHash":"sha256-B","signatures":%s}}' \
        "$a" "$b" "$1" > "$work/local.json"
}
run() { bash "$scripts/verify-attic-closure.sh" minz-git-0 "$b" > "$work/out" 2>&1; }

local_json '[]'
echo sha256-OTHER > "$work/remote/$(basename "$a")"
echo sha256-B > "$work/remote/$(basename "$b")"
run || fail "1: exit $? $(cat "$work/out")"
grep -q "1 of 2 closure paths cross-checked.*1 substituted from Attic" "$work/out" || fail "1: $(cat "$work/out")"

echo sha256-EVIL > "$work/remote/$(basename "$b")"
rc=0
run || rc=$?
[ "$rc" = 1 ] || fail "2: unsigned mismatch exit $rc"
grep -q "possible poisoned closure" "$work/out" || fail "2: $(cat "$work/out")"

local_json '["cache.nixos.org-1:y"]'
rc=0
run || rc=$?
[ "$rc" = 1 ] || fail "3: cache.nixos.org path mismatch exit $rc"

local_json '["homelab:z"]'
run || fail "4: all from Attic exit $? $(cat "$work/out")"
grep -q "0 of 2 closure paths cross-checked.*2 substituted from Attic" "$work/out" || fail "4: $(cat "$work/out")"

local_json null
rc=0
run || rc=$?
[ "$rc" = 1 ] || fail "4b: path with null signatures must be cross-checked, exit $rc"

rc=0
STUB_CURL_RC=7 run || rc=$?
[ "$rc" = 2 ] || fail "5: unreachable exit $rc"

rc=0
STUB_NIX_STORE_RC=1 run || rc=$?
[ "$rc" = 2 ] || fail "6: nix cannot open the store, exit $rc"

echo "verify-attic-closure: all cases pass"
