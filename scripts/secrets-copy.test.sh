#!/usr/bin/env bash
set -euo pipefail

scripts="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cd "$work"

age-keygen -o key.txt 2>/dev/null
export SOPS_AGE_KEY_FILE="$work/key.txt"
recipient="$(age-keygen -y key.txt)"
cat > .sops.yaml <<EOF
creation_rules:
  - path_regex: src\.(yaml|env)$
    age: $recipient
  - path_regex: shared/.*\.yaml$
    age: $recipient
EOF
mkdir shared

jq -n '{k1: "a\"b\nc\n", k2: "x", k3: "y"}' \
    | sops encrypt --filename-override src.yaml --input-type json --output-type yaml /dev/stdin > enc.tmp
mv enc.tmp src.yaml

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

"$scripts/secrets-copy.sh" shared/t.yaml src.yaml k1
sops decrypt --extract '["k1"]' shared/t.yaml | cmp -s - <(printf 'a"b\nc\n') || fail "k1 not byte-identical after create"

"$scripts/secrets-copy.sh" shared/t.yaml src.yaml k2
sops decrypt --extract '["k1"]' shared/t.yaml | cmp -s - <(printf 'a"b\nc\n') || fail "k1 lost after adding k2"
[ "$(sops decrypt --extract '["k2"]' shared/t.yaml)" = x ] || fail "k2 not added"

[ "$("$scripts/secrets-same.sh" src.yaml:k1 shared/t.yaml:k1)" = match ] || fail "same values not reported as match"

printf 'TF_VAR_k2=x\n' | sops encrypt --filename-override src.env --input-type dotenv --output-type dotenv /dev/stdin > enc.tmp
mv enc.tmp src.env
[ "$("$scripts/secrets-same.sh" src.env:TF_VAR_k2 src.yaml:k2)" = match ] || fail "dotenv value not compared"

jq -n '{e: ""}' | sops encrypt --filename-override src.yaml --input-type json --output-type yaml /dev/stdin > enc.tmp
mv enc.tmp shared/empty.yaml
set +e
out="$("$scripts/secrets-same.sh" shared/empty.yaml:e src.yaml:nope 2>/dev/null)"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "undecryptable reference exited 0"
[ "$out" != match ] || fail "undecryptable reference reported match"

set +e
out="$("$scripts/secrets-same.sh" src.yaml:k2 src.yaml:k3)"
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "mismatch exit code $rc, want 1"
[ "$out" = "MISMATCH src.yaml:k3" ] || fail "mismatch output: $out"

while IFS= read -r f; do
    grep -q '^sops:\|^sops_version=' "$f" || fail "plaintext file left behind: $f"
done < <(find . -type f ! -name key.txt ! -name .sops.yaml)

echo "PASS"
