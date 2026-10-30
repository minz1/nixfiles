#!/usr/bin/env bash
set -euo pipefail

scripts="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
unset SKIP_ATTIC_VERIFY STUB_GIT_RC STUB_VERIFY_RC STUB_RETRY_RC STUB_WAIT_RC STUB_NIX_BUILD_RC STUB_NIX_OMIT STUB_NIX_DUP
export STUB_WORK="$work"
log="$work/log"
mkdir -p "$work/bin"
export PATH="$work/bin:$PATH"

cat > "$work/bin/verify-attic-closure" << 'EOF'
#!/usr/bin/env bash
echo "verify-attic-closure $*" >> "$STUB_WORK/log"
var="STUB_VERIFY_RC_${1//-/_}"
exit "${!var:-${STUB_VERIFY_RC:-0}}"
EOF
cat > "$work/bin/deploy-retry" << 'EOF'
#!/usr/bin/env bash
echo "deploy-retry $*" >> "$STUB_WORK/log"
exit "${STUB_RETRY_RC:-0}"
EOF
cat > "$work/bin/deploy-wait-healthy" << 'EOF'
#!/usr/bin/env bash
echo "deploy-wait-healthy $*" >> "$STUB_WORK/log"
exit "${STUB_WAIT_RC:-0}"
EOF
cat > "$work/bin/fleet" << 'EOF'
#!/usr/bin/env bash
if [ "$*" = phases ]; then
    printf '%s\n' minz-vultr-nix-0 minz-home-nix-0 minz-attic-0 "minz-obs-0 minz-runner-0 minz-vultr-nix-1"
    exit 0
fi
if [ "$*" = "host attic" ]; then
    echo minz-attic-0
    exit 0
fi
echo "unexpected fleet call: $*" >&2
exit 99
EOF
cat > "$work/bin/git" << 'EOF'
#!/usr/bin/env bash
[ "${STUB_GIT_RC:-0}" = 0 ] || exit "$STUB_GIT_RC"
echo "$STUB_WORK"
EOF
cat > "$work/bin/nix" << 'EOF'
#!/usr/bin/env bash
echo "nix $*" >> "$STUB_WORK/log"
if [ "${1:-}" = build ]; then
    [ "${STUB_NIX_BUILD_RC:-0}" = 0 ] || exit "$STUB_NIX_BUILD_RC"
    hosts=()
    for a in "$@"; do
        if [[ "$a" =~ \#nixosConfigurations\.([^.]+)\. ]]; then
            hosts+=("${BASH_REMATCH[1]}")
        fi
    done
    for ((i = ${#hosts[@]} - 1; i >= 0; i--)); do
        [ "${hosts[$i]}" = "${STUB_NIX_OMIT:-}" ] && continue
        echo "/nix/store/xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx-nixos-system-${hosts[$i]}-26.11"
        [ "${hosts[$i]}" = "${STUB_NIX_DUP:-}" ] && echo "/nix/store/yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy-nixos-system-${hosts[$i]}-26.11"
    done
fi
exit 0
EOF
sed -i "1s|.*|#!$BASH|" "$work"/bin/*
chmod +x "$work"/bin/*

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

path_of() {
    echo "/nix/store/xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx-nixos-system-$1-26.11"
}

run() {
    : > "$log"
    bash "$scripts/deploy-phased.sh" "$@" > "$work/out" 2>&1
}

has() {
    grep -qxF -- "$1" "$log"
}

line_of() {
    grep -nxF -- "$1" "$log" | head -1 | cut -d: -f1
}

before() {
    local a b
    a=$(line_of "$1")
    b=$(line_of "$2")
    [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}

count() {
    grep -c -- "$1" "$log" || true
}

toplevel() {
    echo "${work}#nixosConfigurations.$1.config.system.build.toplevel"
}

run minz-obs-0 minz-attic-0 || fail "case 1: exited non-zero"
[ "$(count '^nix build')" = 1 ] || fail "case 1: expected exactly one nix build"
build_line=$(grep '^nix build' "$log")
[[ "$build_line" == *"$(toplevel minz-obs-0)"* ]] || fail "case 1: build lacks minz-obs-0"
[[ "$build_line" == *"$(toplevel minz-attic-0)"* ]] || fail "case 1: build lacks minz-attic-0"
[ "$(grep -o '#nixosConfigurations\.' <<< "$build_line" | wc -l)" = 2 ] || fail "case 1: build names other hosts"
[ "$(count 'flake check')" = 0 ] || fail "case 1: flake check still runs"
before "$build_line" "deploy-retry minz-attic-0" || fail "case 1: build not before first deploy"
has "verify-attic-closure minz-obs-0 $(path_of minz-obs-0)" || fail "case 1: obs-0 not verified with its path"
has "verify-attic-closure minz-attic-0 $(path_of minz-attic-0)" || fail "case 1: attic-0 not verified with its path"
before "deploy-retry minz-attic-0" "deploy-retry minz-obs-0" || fail "case 1: phase order"

run minz-obs-0 minz-vultr-nix-0 || fail "case 2: exited non-zero"
before "deploy-retry minz-vultr-nix-0" "deploy-retry minz-obs-0" || fail "case 2: phase order"

if STUB_NIX_BUILD_RC=1 run minz-obs-0 minz-runner-0; then fail "case 3: build failure not fatal"; fi
[ "$(count '^deploy-retry')" = 0 ] || fail "case 3: deployed after build failure"

for bad in minz-obs obs-0; do
    if run "$bad"; then fail "case 4: accepted '$bad'"; fi
    [ "$(count '^nix build')" = 0 ] || fail "case 4: built for '$bad'"
done

if STUB_VERIFY_RC=1 run minz-obs-0 minz-vultr-nix-1; then fail "case 5: verify failure not fatal"; fi
[ "$(count '^deploy-retry')" = 0 ] || fail "case 5: deployed after verify failure"

run || fail "case 6: exited non-zero"
build_line=$(grep '^nix build' "$log")
[ "$(grep -o '#nixosConfigurations\.' <<< "$build_line" | wc -l)" = 6 ] || fail "case 6: build does not name all 6 hosts"
for h in minz-vultr-nix-0 minz-home-nix-0 minz-attic-0 minz-obs-0 minz-runner-0 minz-vultr-nix-1; do
    has "verify-attic-closure $h $(path_of "$h")" || fail "case 6: $h not verified"
done

STUB_VERIFY_RC_minz_vultr_nix_0=2 run minz-vultr-nix-0 || fail "case 7: unreachable Attic blocked an early-phase host"
has "deploy-retry minz-vultr-nix-0" || fail "case 7: vultr-nix-0 not deployed"

if STUB_VERIFY_RC_minz_obs_0=2 run minz-obs-0; then fail "case 8: unreachable Attic tolerated after attic phase"; fi
[ "$(count '^deploy-retry')" = 0 ] || fail "case 8: obs-0 deployed"

if STUB_VERIFY_RC_minz_vultr_nix_0=1 run minz-vultr-nix-0; then fail "case 9: mismatch tolerated on early-phase host"; fi
[ "$(count '^deploy-retry')" = 0 ] || fail "case 9: vultr-nix-0 deployed"

if STUB_NIX_OMIT=minz-runner-0 run minz-obs-0 minz-runner-0; then fail "case 10: missing path not fatal"; fi
[ "$(count '^deploy-retry')" = 0 ] || fail "case 10: deployed with a missing path"

SKIP_ATTIC_VERIFY=1 run || fail "case 11: exited non-zero"
[ "$(count '^verify-attic-closure')" = 0 ] || fail "case 11: verified despite SKIP_ATTIC_VERIFY"
[ "$(count '^deploy-retry')" = 6 ] || fail "case 11: not all hosts deployed"

STUB_VERIFY_RC_minz_attic_0=2 run minz-attic-0 || fail "case 12: unreachable Attic blocked attic-0 itself"
has "deploy-retry minz-attic-0" || fail "case 12: attic-0 not deployed"

STUB_VERIFY_RC_minz_home_nix_0=2 run minz-home-nix-0 || fail "case 13: unreachable Attic blocked home-nix-0"
has "deploy-retry minz-home-nix-0" || fail "case 13: home-nix-0 not deployed"

if STUB_NIX_DUP=minz-obs-0 run minz-obs-0; then fail "case 14: ambiguous path not fatal"; fi
[ "$(count '^deploy-retry')" = 0 ] || fail "case 14: deployed with an ambiguous path"

run minz-obs-0 minz-obs-0 || fail "case 15: repeated host name rejected"
[ "$(count '^deploy-retry minz-obs-0$')" = 1 ] || fail "case 15: repeated host not deployed exactly once"

if STUB_GIT_RC=128 run minz-obs-0; then fail "case 16: git failure not fatal"; fi
[ "$(count '^nix ')" = 0 ] || fail "case 16: built after git failure"

echo "deploy-phased.test.sh: all cases passed"
