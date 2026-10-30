# nixfiles

NixOS fleet (deploy-rs) plus OpenTofu (`tofu/infra`, `tofu/app`), secrets in sops-nix. Docs live in `docs/` (gitignored); `docs/README.md` indexes them. Open work: `docs/roadmap.md` (`AREA-n` IDs); finished plans: `docs/history.md`.

## Declarative or it doesn't exist
Anything not declared in this repo (Nix, tofu, repo scripts + just recipes) is transient: treat it as if it could be wiped any time. That covers host-local scripts in `/root`, `systemd-run` units, app settings changed through an API, plugins installed through an API, and session scratchpads. Don't build on it or point future work at it as durable. Clean up one-off work when it's done; anything worth keeping becomes a declarative change or a roadmap item. When a fix has to be applied imperatively, say so and name the declarative follow-up.

## Commands
- Dev shell: `nix develop` (tofu, aws, etc. only exist inside it).
- Before any deploy or install of a changed host: `nix build .#nixosConfigurations.<host>.config.system.build.toplevel`. `nix eval` misses derivation-time errors.
- Deploy: `just deploy node <host>`, `just deploy phased`, `just deploy all`, `just deploy list`. Every deploy pre-builds exactly the hosts it deploys, then deploys each with `--skip-checks`. Hosts after attic-0's phase need `SKIP_ATTIC_VERIFY=1` if Attic is down. `just admin build-all` checks the whole fleet builds.
- Never pipe `just deploy` through `tail`/`head`: it hides progress and replaces the exit status. Judge progress from the hosts' own state.
- While any `just deploy` runs, don't edit any `.nix` or `secrets/*.yaml` (the whole flake is re-evaluated per phase). Editing `docs/` is fine.
- Tofu: `just tofu ...`. Always review `plan` before `apply`.

## Deploy ordering
`deployPhases` in flake.nix follows routing topology only. Service deps must be explicit: attic-0 (`services.attic.host` in common/services.nix) deploys in its own phase before its consumers via `dependsOnBinaryCache`. Phases: `[vultr-nix-0] [home-nix-0] [attic-0] [everything else + vultr-nix-1]`. Any new dep added this way must keep the old ordering transitively.

## flake.lock
Before deploying, make sure flake.lock is not older than what the fleet runs (compare against the running systems' nixpkgs revision). Deploying a stale lock downgraded lego and broke ACME once.

## Secrets
- Never print secret values: no `sops -d` to a terminal, no `cat /run/secrets/*`, no env dumps, no reading service state files that hold tokens. To list keys, use Read on the encrypted YAML (key names are plaintext).
- `sops --extract ''` (empty or invalid path) silently decrypts everything. Only ever `--extract '["exact_key"]'`, piped straight into the consumer.
- App APIs can echo secrets: Grafana's `GET /api/v1/provisioning/contact-points` returns plaintext. The k8s-style `/apis/notifications.alerting.grafana.app/...` endpoint redacts. Prefer reading the Nix source/rendered file over asking the live service.
- Rotation: generate and pipe into `sops set file '["key"]' "\"$(...)\""`; verify by hash, never by printing. Token/secret entry is the owner's manual step: tell them the key name and file.
- Shared secrets live in `secrets/shared/<topic>.yaml` (NixOS `sopsFile`, tofu `sops_file`).
- All SSH host keys go through the sops key ceremony (bootstrap-keygen → bootstrap-store-key → bootstrap-install[-vm]), no exceptions.

## Live hosts
- If a test result surprises you, read the command's stdout/stderr before acting. `sudo -u '#UID'` is unsupported on this fleet; test as a UID with `setpriv --reuid=<uid> --regid=<gid> --clear-groups --no-new-privs <cmd>`.
- Before `restic restore`, `df -h` the exact target. Impermanence roots are small tmpfs; restore into `/persist/...` or restore a subset.
- Units with `RefuseManualStop` (auditd daemon) only pick up changes on reboot. Check `systemctl show <unit> -p RefuseManualStop` before assuming a deploy applied. auditd *plugin* changes do apply via its reload.
- Scripts handed to the owner must assert every precondition before the first stop/copy/write, live in this session's scratchpad with the full path given, and after they run, check the services they touched are up.

## Area rules

Each section applies when working on the paths in its heading.

### NixOS conventions (`hosts/**`, `modules/**`, `common/**`)

#### Impermanence
- Service dirs in `environment.persistence."/persist".directories` always use the submodule form with `user`, `group`, `mode`. A bare string defaults to root:root 0755 and the service can't write its own home.
- `DynamicUser = true` services (prowlarr, alloy, check nixpkgs for new ones): persist `/var/lib/private/<svc>` with `mode = "0700"`, never `/var/lib/<svc>` (that's a runtime symlink; persisting it fails with status=238/STATE_DIRECTORY). Exception: a module that also declares a static user and no `StateDirectory` (crowdsec since nixpkgs 02c087f) runs as that user; persist `/var/lib/<svc>` with user/group.
- In Incus LXC containers, DynamicUser idmapped mounts and `LoadCredential`/`CREDENTIALS_DIRECTORY` don't work. Override with `DynamicUser = mkForce false`, `StateDirectory = mkForce ""`, static `User`/`Group`, `LoadCredential = mkForce ""`, read the secret from `/run/secrets/<x>` directly, and persist `/var/lib/<svc>` with user/group.

#### Disko
- Sizes are `"30G"`, `"100M"`; `GiB` fails (that form is only for Incus resources).
- Every `zfs_fs` with a `mountpoint` also sets `options.canmount = "noauto"`, or zfs-mount and fstab race, `local-fs.target` fails and the host drops to emergency mode with no sshd. Existing datasets also need a one-time `zfs set` on the host.

#### sops-nix
- Every secret or template a running service consumes gets `restartUnits` on the `sops.secrets.<x>` / `sops.templates.<x>`. `restartTriggers` on template `content` can't see a rotated value (the text only holds a placeholder).
- A deploy doesn't restart a service whose secret didn't change; after a manual rotation, restart the consumer or compare `ExecMainStartTimestamp` with the secret's mtime.

#### systemd hardening (`modules/lib/hardening.nix` mkHardened)
- Never apply mkHardened or a custom `SystemCallFilter` to `caddy.service`; it SIGSYS-crashes on `fchownat` ~40s after start. The upstream unit is hardened already.
- Alloy (and Go agents doing eBPF detection) need `"bpf"` after `"~@privileged"` in the filter.
- A unit whose script drops root to another user: use `setpriv --reuid/--regid --init-groups` (not runuser/su), pass the set*id/capset syscalls through mkHardened's `extraSystemCallFilter` (a separate serviceConfig override lands after the deny and is stripped), and mirror `CAP_SETUID`/`CAP_SETGID` into both `capabilityBoundingSet` and `ambientCapabilities`. Scope it to that unit only.

#### Networking and TLS
- `security.acme` with `listenHTTP = ":80"` doesn't open port 80; `modules/nixos/common.nix` adds it. Don't remove it. A cert issued by minica instead of step-ca means the HTTP-01 challenge couldn't reach port 80.
- After changing `security.pki.certificates`, fully restart Go services (Caddy, alloy); reload keeps the old cert pool.
- forgejo-runner cache: `settings.cache.host = wgAddr` (10.8.0.1). The rootful podman bridge 10.88.0.1 never exists here.
- Quadlet containers (rootless, `oci` user) are system units: manage them with `sudo systemctl restart|status <name>.service`, never `podman restart` (systemd kills and recreates the container behind it) or `systemctl --user`. Use podman only to inspect (`exec`, `ps`, `inspect`).
- Rootless podman containers (pasta) share the host IP, so `mediaIp` inside a container is the container itself. Reach host services via `host.containers.internal:<port>`. Debug distroless containers with `nsenter -t <pid> -n curl ...`.

### Caddy (`hosts/**`, `modules/**`)

- Every `reverse_proxy` to an internal backend sets `header_up Host {http.request.host}`; otherwise backends build redirects and origin checks against the internal IP.
- Caddy's JSON reverse_proxy overwrites `X-Forwarded-Host`. Where the upstream value matters (authentik's embedded outpost behind `forward_auth`), set `headers.request.set."X-Forwarded-Host" = [ "{http.request.header.X-Forwarded-Host}" ]`.
- Adding `client_authentication` to a server's TLS policy turns on `strict_sni_host`. The edge (vultr-nix-1) dials internal Caddies by IP, so every vhost then returns 421. Set `strict_sni_host = false` and authorize on `{http.request.tls.client.subject}` in the route. After any internal TLS policy change, curl every public vhost through the edge, not only the one changed.
- IP connections carry no SNI. Tag the cert in `load_files` (`tags = [ "x" ]`) and pin it with `certificate_selection.any_tag`; the cert needs an IP SAN via `security.acme.certs.<n>.extraDomainNames`. Avoid `default_sni`.
- A TLS server using `load_files` on a host that also runs lego needs `automatic_https.disable_redirects = true`, or Caddy grabs port 80.

### Scripts and justfiles (`scripts/**`, `pkgs/**`, `justfile`, `just/**`)

- Every shell script passes `shellcheck -x -P scripts` with no suppressions. `scripts/default.nix` prepends `lib.sh` to scripts that use it, so nothing sources it; run scripts as `nix run .#<name>`, not by path (helpers like `find_ram_dir` are undefined by path).
- Public justfile recipes are 1-3 command invocations. Anything with control flow moves to `scripts/*.sh` (only scripts get shellcheck coverage).
- Quote heredocs sent to remote shells (`<<'REMOTE'`) and pass local values as `bash -s -- "$val"`.

### OpenTofu (`tofu/**`)

- New resources are declarative tofu resources. The imperative `rustfs-bucket-setup` buckets exist only because tofu's own state bucket can't be created by tofu; that reason doesn't extend to new buckets.
- State encryption is `TF_ENCRYPTION` in `secrets/tofu.env`: one-line JSON, references without `${}`. Migrating plaintext state needs an `unencrypted` migrate fallback for one `apply -refresh-only` per layer. Verify with a write and check the S3 object contains `encrypted_data`, not with a plan.
- decypharr download clients in `tofu/app/arr.tf` authenticate with `decypharr_api_token` from `secrets/shared/decypharr.yaml` (the arr API key won't authenticate). SABnzbd clients use `api_key`, never `username`/`password`: Sonarr logs `ma_password` in plain text in failed-request URLs but redacts `apikey`. qBit clients keep `password` (sent in the POST body, not logged).

### Grafana / Loki (`hosts/minz-obs-0/**`, `modules/nixos/observability-agent.nix`)

- File provisioning never removes anything. Removing an alert rule or contact-point receiver from Nix needs a matching `deleteRules` / `deleteContactPoints` entry (`{ orgId; uid; }`, receiver uid) in the same settings block, then confirm via the API that the uid is gone.
- ngalert webhook basic auth keys are `username`/`password` (not `basicAuthUsername`). Wrong keys are accepted silently and fail only at send time (403 with no Authorization header seen).
- Custom payload: the key is `settings.payload.template`. No `$var` anywhere in it (provisioning's `os.Expand` blanks them; use `(or (and (eq .Status "firing") 4) 3)`). No `{{ define }}`/`tmpl.Exec` (broken in 13.1.x). ntfy `tags` must be a JSON array (`coll.Slice`). Test with the receiver test API pointed at a scratch `nc -l` listener.
- LogQL: `(?i)a.*(b|c)` silently matches nothing. Use `.+`, split into two `|~`, or drop `(?i)`. Backtest every new or edited alert against a window with a known-positive line, then check rule health=ok.

### Media stack (`hosts/minz-media-0/**`, `hosts/minz-services-0/**`, `tofu/app/**`)

- services-0 ↔ media-0 traffic stays HTTPS through media-0's Caddy. Backends bind loopback, only Caddy's port is opened in the firewall and Incus ACL, never a plain-HTTP port between hosts. If a design keeps that, no need to ask about routing.
- decypharr `/api/torrents` is optimistic (reports complete with no files under `/mnt/decypharr/__all__/`). `/api/repair/status` is authoritative; don't conclude healthy or trigger arr searches from `/api/torrents`.
