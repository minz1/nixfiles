#!/usr/bin/env bash
# Builds the bootstrap image (via `nix build`) and publishes it to the S3
# simplestreams registry so `tofu apply` can pull it via source_image.
#
# Prerequisites:
#   - result/nixos.qcow2 and result/metadata.tar.xz already built (call nix build first)
#   - incus-images bucket exists (created by rustfs-bucket-setup systemd service)
#   - secrets/rustfs-tofu.env is sops-encrypted and contains AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
#
# combined_disk-kvm-img_sha256 is placed on the incus.tar.xz (metadata) item
# per https://github.com/lxc/incus/blob/main/cmd/incus-simplestreams/main_add.go
set -euo pipefail

cd "${ROOT_DIR}"

meta_sha256=$(sha256sum result/metadata.tar.xz | awk '{print $1}')
meta_size=$(wc -c < result/metadata.tar.xz | awk '{print $1}')
disk_sha256=$(sha256sum result/nixos.qcow2 | awk '{print $1}')
disk_size=$(wc -c < result/nixos.qcow2 | awk '{print $1}')
combined_sha256=$(cat result/metadata.tar.xz result/nixos.qcow2 | sha256sum | awk '{print $1}')
# Version key must start with YYYYMMDD — ToAPI() silently skips keys that don't parse as a date.
version=$(date -u +%Y%m%d%H%M)

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/streams/v1"

# index.json — static, points to images.json
cat > "$tmpdir/streams/v1/index.json" <<'ENDJSON'
{"format":"index:1.0","index":{"images":{"datatype":"image-downloads","path":"streams/v1/images.json","format":"products:1.0","products":["nixos:unstable:default:amd64"]}}}
ENDJSON

# images.json — one product, one version entry
cat > "$tmpdir/streams/v1/images.json" <<ENDJSON
{
  "content_id": "images",
  "datatype": "image-downloads",
  "format": "products:1.0",
  "products": {
    "nixos:unstable:default:amd64": {
      "aliases": "nixos/unstable/default,nixos-bootstrap",
      "arch": "amd64",
      "os": "nixos",
      "release": "unstable",
      "release_title": "NixOS Unstable",
      "variant": "default",
      "versions": {
        "${version}": {
          "items": {
            "incus.tar.xz": {
              "combined_disk-kvm-img_sha256": "${combined_sha256}",
              "ftype": "incus.tar.xz",
              "path": "images/${meta_sha256}.incus.tar.xz",
              "sha256": "${meta_sha256}",
              "size": ${meta_size}
            },
            "disk-kvm.img": {
              "ftype": "disk-kvm.img",
              "path": "images/${meta_sha256}.qcow2",
              "sha256": "${disk_sha256}",
              "size": ${disk_size}
            }
          }
        }
      }
    }
  }
}
ENDJSON

endpoint="http://10.8.0.1:9000"

if [ -n "${AWS_ACCESS_KEY_ID:-}" ]; then
  _aws() { aws --endpoint-url "$endpoint" "$@"; }
else
  creds="${ROOT_DIR}/secrets/rustfs-tofu.env"
  _aws() { sops exec-env "$creds" "aws --endpoint-url $endpoint $*"; }
fi

if _aws s3api head-object --bucket incus-images --key "images/${meta_sha256}.qcow2" 2>/dev/null; then
  echo "Image ${version} (${meta_sha256}) already in registry, skipping upload."
  exit 0
fi

_aws s3 cp result/metadata.tar.xz "s3://incus-images/images/${meta_sha256}.incus.tar.xz"
_aws s3 cp result/nixos.qcow2     "s3://incus-images/images/${meta_sha256}.qcow2"
_aws s3 cp "$tmpdir/streams/v1/index.json"  s3://incus-images/streams/v1/index.json
_aws s3 cp "$tmpdir/streams/v1/images.json" s3://incus-images/streams/v1/images.json

echo "Published ${version} fingerprint=${combined_sha256}"
