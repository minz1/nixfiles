# OpenTofu infrastructure management

[private]
_with-incus command:
    {{ ROOT_DIR }}/scripts/with-incus.sh "{{ command }}"

# --- Infra layer ---

infra-init flags="":
    @just tofu _with-incus "sops exec-env ${ROOT_DIR}/secrets/tofu.env 'tofu -chdir=${ROOT_DIR}/tofu/infra init {{ flags }}'"

infra-plan hostname="":
    @just tofu _with-incus "sops exec-env ${ROOT_DIR}/secrets/tofu.env 'tofu -chdir=${ROOT_DIR}/tofu/infra plan -var=\"hostname={{ hostname }}\" -out=${ROOT_DIR}/tofu/infra/tofu.plan'"

infra-apply:
    @just tofu _with-incus "sops exec-env ${ROOT_DIR}/secrets/tofu.env 'tofu -chdir=${ROOT_DIR}/tofu/infra apply ${ROOT_DIR}/tofu/infra/tofu.plan'"

infra-destroy hostname="":
    @just tofu _with-incus "sops exec-env ${ROOT_DIR}/secrets/tofu.env 'tofu -chdir=${ROOT_DIR}/tofu/infra destroy -var=\"hostname={{ hostname }}\"'"

# --- App layer ---

app-init flags="":
    sops exec-env ${ROOT_DIR}/secrets/tofu.env 'tofu -chdir=${ROOT_DIR}/tofu/app init {{ flags }}'

app-plan:
    sops exec-env ${ROOT_DIR}/secrets/tofu.env 'tofu -chdir=${ROOT_DIR}/tofu/app plan -out=${ROOT_DIR}/tofu/app/tofu.plan'

app-apply:
    sops exec-env ${ROOT_DIR}/secrets/tofu.env 'tofu -chdir=${ROOT_DIR}/tofu/app apply ${ROOT_DIR}/tofu/app/tofu.plan'
