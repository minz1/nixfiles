flake := justfile_directory()

# OpenTofu infrastructure management

[private]
_with-incus command:
    nix run {{ flake }}#with-incus -- "{{ command }}"

# Build the Incus VM bootstrap image. Produces result/nixos.qcow2 + result/metadata.tar.xz.
build-image:
    nix build {{ flake }}#incus-bootstrap-image -o {{ flake }}/result

# Build the Incus container bootstrap image. Produces result-container/rootfs.tar.xz + result-container/metadata.tar.xz.
build-container-image:
    nix build {{ flake }}#incus-bootstrap-container-image -o {{ flake }}/result-container

publish-image: build-image build-container-image
    nix run {{ flake }}#tofu-publish-image

# --- Infra layer ---

infra-init flags="":
    @just tofu _with-incus "sops exec-env {{ flake }}/secrets/tofu.env 'tofu -chdir={{ flake }}/tofu/infra init {{ flags }}'"

infra-plan:
    @fleet="$(nix eval --json {{ flake }}#fleet)" && TF_VAR_fleet="$fleet" just tofu _with-incus "sops exec-env {{ flake }}/secrets/tofu.env 'tofu -chdir={{ flake }}/tofu/infra plan -out={{ flake }}/tofu/infra/tofu.plan'"

infra-apply:
    @fleet="$(nix eval --json {{ flake }}#fleet)" && TF_VAR_fleet="$fleet" just tofu _with-incus "sops exec-env {{ flake }}/secrets/tofu.env 'tofu -chdir={{ flake }}/tofu/infra apply {{ flake }}/tofu/infra/tofu.plan'"

# Destroys exactly one host's Incus instance + persist volume, via -target= (never a bare destroy).
infra-destroy-host hostname:
    nix run {{ flake }}#tofu-destroy-host -- {{ hostname }}

# --- App layer ---

app-init flags="":
    sops exec-env {{ flake }}/secrets/tofu.env 'tofu -chdir={{ flake }}/tofu/app init {{ flags }}'

app-plan:
    @fleet="$(nix eval --json {{ flake }}#fleet)" && TF_VAR_fleet="$fleet" sops exec-env {{ flake }}/secrets/tofu.env 'tofu -chdir={{ flake }}/tofu/app plan -out={{ flake }}/tofu/app/tofu.plan'

app-apply:
    sops exec-env {{ flake }}/secrets/tofu.env 'tofu -chdir={{ flake }}/tofu/app apply {{ flake }}/tofu/app/tofu.plan'
