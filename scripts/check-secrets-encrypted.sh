#!/usr/bin/env bash
# Every tracked file under secrets/ must be sops-encrypted (or a public cert). gitleaks allowlists
# the directory, so without this a plaintext drop there would pass CI unnoticed.
set -euo pipefail

cd "${ROOT_DIR:-$(git rev-parse --show-toplevel)}"

bad=()
while IFS= read -r f; do
    case "$f" in
        *.crt) openssl x509 -in "$f" -noout 2>/dev/null || bad+=("$f (not a certificate)") ;;
        *) grep -q '^sops:\|"sops":\|sops_version' "$f" || bad+=("$f (no sops metadata)") ;;
    esac
done < <(git ls-files 'secrets/*')

if [ "${#bad[@]}" -gt 0 ]; then
    echo "Unencrypted file(s) under secrets/:" >&2
    printf '  %s\n' "${bad[@]}" >&2
    exit 1
fi

echo "secrets/: all $(git ls-files 'secrets/*' | wc -l) tracked files encrypted or public certs."
