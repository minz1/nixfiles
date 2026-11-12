#!/usr/bin/env bash
set -euo pipefail
repo=$(git rev-parse --show-toplevel)

case "$#" in
    0) ;;
    2)
        if before=$(git -C "$repo" rev-parse --verify --quiet "$1^{commit}") \
            && after=$(git -C "$repo" rev-parse --verify --quiet "$2^{commit}") \
            && git -C "$repo" diff --quiet "$before" "$after" -- flake.lock; then
            echo "flake.lock unchanged between $1 and $2; caddy pins not checked"
            exit 0
        fi
        ;;
    *)
        echo "usage: caddy-pins-check [<before> <after>]" >&2
        exit 2
        ;;
esac

mapfile -t hosts < <(nix eval --no-update-lock-file --json "${repo}#nixosConfigurations" --apply '
  cs: builtins.filter (h:
    let c = (builtins.getAttr h cs).config.services.caddy; in
    c.enable && builtins.substring 0 22 c.package.src.name == "caddy-src-with-plugins"
  ) (builtins.attrNames cs)' | jq -r '.[]')

if [ "${#hosts[@]}" -eq 0 ]; then
    echo "no withPlugins caddy found in any nixosConfiguration" >&2
    exit 1
fi
echo "checking: ${hosts[*]}"

failed=()
for h in "${hosts[@]}"; do
    attr="${repo}#nixosConfigurations.${h}.config.services.caddy.package.src"
    echo "==> ${h}"
    if ! nix build --no-update-lock-file --no-link "$attr" || ! nix build --no-update-lock-file --no-link --rebuild "$attr"; then
        failed+=("$h")
    fi
done

if [ "${#failed[@]}" -gt 0 ]; then
    echo "DRIFT: ${failed[*]}" >&2
    exit 1
fi
echo "ok"
