#!/usr/bin/env bash
# Publishes both the VM bootstrap image and the container bootstrap image to the
# S3 simplestreams registry as two products in a single images.json.
#
# Prerequisites:
#   - result/{nixos.qcow2,metadata.tar.xz} built (nix build .#incus-bootstrap-image)
#   - result-container/{rootfs.tar.xz,metadata.tar.xz} built (nix build .#incus-bootstrap-container-image)
#   - incus-images bucket exists (created by rustfs-bucket-setup)
#   - secrets/tofu.env is sops-encrypted and contains AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
set -euo pipefail

cd "${ROOT_DIR}"

# --- VM image hashes ---
vm_meta_sha256=$(sha256sum result/metadata.tar.xz | awk '{print $1}')
vm_meta_size=$(wc -c < result/metadata.tar.xz | awk '{print $1}')
vm_disk_sha256=$(sha256sum result/nixos.qcow2 | awk '{print $1}')
vm_disk_size=$(wc -c < result/nixos.qcow2 | awk '{print $1}')
vm_combined_sha256=$(cat result/metadata.tar.xz result/nixos.qcow2 | sha256sum | awk '{print $1}')

# --- Container image hashes ---
ct_meta_sha256=$(sha256sum result-container/metadata.tar.xz | awk '{print $1}')
ct_meta_size=$(wc -c < result-container/metadata.tar.xz | awk '{print $1}')
ct_rootfs_sha256=$(sha256sum result-container/rootfs.tar.xz | awk '{print $1}')
ct_rootfs_size=$(wc -c < result-container/rootfs.tar.xz | awk '{print $1}')
ct_combined_sha256=$(cat result-container/metadata.tar.xz result-container/rootfs.tar.xz | sha256sum | awk '{print $1}')

# Version key must start with YYYYMMDD — ToAPI() silently skips keys that don't parse as a date.
version=$(date -u +%Y%m%d%H%M)

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/streams/v1"

# index.json — references both products in the same images.json
cat > "$tmpdir/streams/v1/index.json" <<ENDJSON
{"format":"index:1.0","index":{"images":{"datatype":"image-downloads","path":"streams/v1/images.json","format":"products:1.0","products":["nixos:unstable:default:amd64","nixos:unstable:container:amd64"]}}}
ENDJSON

# images.json — VM product + container product
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
              "combined_disk-kvm-img_sha256": "${vm_combined_sha256}",
              "ftype": "incus.tar.xz",
              "path": "images/${vm_meta_sha256}.incus.tar.xz",
              "sha256": "${vm_meta_sha256}",
              "size": ${vm_meta_size}
            },
            "disk-kvm.img": {
              "ftype": "disk-kvm.img",
              "path": "images/${vm_meta_sha256}.qcow2",
              "sha256": "${vm_disk_sha256}",
              "size": ${vm_disk_size}
            }
          }
        }
      }
    },
    "nixos:unstable:container:amd64": {
      "aliases": "nixos/unstable/container,nixos-bootstrap-container",
      "arch": "amd64",
      "os": "nixos",
      "release": "unstable",
      "release_title": "NixOS Unstable",
      "variant": "container",
      "versions": {
        "${version}": {
          "items": {
            "incus.tar.xz": {
              "combined_rootxz_sha256": "${ct_combined_sha256}",
              "ftype": "incus.tar.xz",
              "path": "images/${ct_meta_sha256}.incus.tar.xz",
              "sha256": "${ct_meta_sha256}",
              "size": ${ct_meta_size}
            },
            "root.tar.xz": {
              "ftype": "root.tar.xz",
              "path": "images/${ct_rootfs_sha256}.root.tar.xz",
              "sha256": "${ct_rootfs_sha256}",
              "size": ${ct_rootfs_size}
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
  creds="${ROOT_DIR}/secrets/tofu.env"
  _aws() { sops exec-env "$creds" "aws --endpoint-url $endpoint $*"; }
fi

# Upload VM image artifacts (skip if already present)
if ! _aws s3api head-object --bucket incus-images --key "images/${vm_meta_sha256}.qcow2" 2>/dev/null; then
  _aws s3 cp result/metadata.tar.xz "s3://incus-images/images/${vm_meta_sha256}.incus.tar.xz"
  _aws s3 cp result/nixos.qcow2     "s3://incus-images/images/${vm_meta_sha256}.qcow2"
  echo "Uploaded VM image ${version} (${vm_meta_sha256})"
else
  echo "VM image ${vm_meta_sha256} already in registry, skipping upload."
fi

# Upload container image artifacts (skip if already present)
if ! _aws s3api head-object --bucket incus-images --key "images/${ct_rootfs_sha256}.root.tar.xz" 2>/dev/null; then
  _aws s3 cp result-container/metadata.tar.xz "s3://incus-images/images/${ct_meta_sha256}.incus.tar.xz"
  _aws s3 cp result-container/rootfs.tar.xz   "s3://incus-images/images/${ct_rootfs_sha256}.root.tar.xz"
  echo "Uploaded container image ${version} (${ct_rootfs_sha256})"
else
  echo "Container image ${ct_rootfs_sha256} already in registry, skipping upload."
fi

# Always update the manifests so aliases and product list stay current
_aws s3 cp "$tmpdir/streams/v1/index.json"  s3://incus-images/streams/v1/index.json
_aws s3 cp "$tmpdir/streams/v1/images.json" s3://incus-images/streams/v1/images.json

echo "Registry updated: VM=${vm_combined_sha256} container=${ct_combined_sha256}"
