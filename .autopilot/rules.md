# Autopilot rules: nixfiles

## Checks
Run inside `nix develop` from `/home/minz1/projects/nixfiles`. Check `$?`; never pipe `just deploy` through `head` or `tail`.
- Nix change: `nix build --no-link .#nixosConfigurations.<host>.config.system.build.toplevel` for each affected host (`nix eval` misses derivation-time errors). Hosts: minz-vultr-nix-0, minz-vultr-nix-1, minz-home-nix-0, minz-obs-0, minz-authentik-0, minz-media-0, minz-services-0, minz-pki-0, minz-game-0, minz-attic-0, minz-runner-0.
- Tofu change in `tofu/app` or `tofu/infra`: `just tofu app-plan` or `just tofu infra-plan`, and read the plan.
- Script change: `cd scripts && shellcheck -x *.sh`.
- flake.lock bump: `just admin update` (updates inputs and builds every host). Only for a full input update.
- Peer build (decypharr or mediafixer): `nix flake update <input>` only, then build each host that input reaches (decypharr → minz-media-0; mediafixer → minz-services-0 and minz-media-0).
- Final item: `just admin check` (flake check, `nix fmt --fail-on-change`, shellcheck, secrets encrypted), then a build of every host the run changed.

## May happen mid-run
- Deploy to any host after its toplevel build passes and flake.lock is not older than what the fleet runs: one host `just deploy node <host>`, several `just deploy phased <host>...` (dependency order, attic verify on; do not set `SKIP_ATTIC_VERIFY`). deploy-rs rolls back on failure. Do not edit `*.nix` or `secrets/*.yaml` while a phased deploy runs.
- After each deploy: `just admin health`; no failed units on the deployed hosts, else roll each bad host back to its previous generation (`ssh "$(just admin _target <host>)" sudo nixos-rebuild switch --rollback`). For nixfiles' own changes: mark the item failed and exit `STOP`. For a peer build: post `nack <id>: <reason>, rolled back to <gen>` and carry on; the peer fixes it and re-posts. A rollback that fails is always `STOP`.
- Live reads: Loki, and read-only GETs to the arr/decypharr/Seerr APIs through the redacting `/root` helpers. Never print a raw response that can embed keys (Sonarr `release`/`history`).
- Push: after a deploy is verified, fast-forward `main` to the item's commit on the run branch and push `main` to `origin`, `github` and `codeberg`. Only `main`. No tags.
- `just tofu app-apply` after `just tofu app-plan` shows no resource destroyed or replaced.
- Not allowed mid-run: `just tofu infra-apply`, `tofu destroy`, `just tofu infra-destroy-host`, `just admin gc`, reboots, bootstrap or install scripts.

## Reviewer stand-in
Before every deploy, and before the Final item merges and pushes: run the `reviewer` agent with `model: opus` on the diff. Apply its changes; record verdict and commit in `log.md`. A BLOCK verdict blocks the item.

## Fleet
None. Do not launch fleet agents. decypharr code belongs to the decypharr session (`/home/minz1/projects/decypharr`), mediafixer code to the mediafixer session (`/home/minz1/projects/mediafixer`; media-fixer runs on minz-services-0, media-agent on minz-media-0). Never edit either. This session deploys and verifies their revisions, answers their board requests, and requests changes through the board.

## Board protocol
- Answer every request addressed to nixfiles before picking queue work.
- `ack <id>` = deployed, `just admin health` clean, and the immediate live check's result.
- A live check that waits on an event (e.g. a partial pack import) is not part of the ack: post it later as `watch <id>: <result>`. Peers never block on it.
- One peer deploy per session.

## Stop list
Exit `STOP <reason>` and park the item for:
- Any change to `secrets/`, `.sops.yaml` or a secret's value, including rotation.
- Disk or data-destroying steps: disko or ZFS changes on a live host, `restic restore`, deleting files under `/var/lib` or `/persist`, `just admin gc`.
- `tofu destroy`, a plan that shows a resource destroyed or replaced, `just tofu infra-apply`.
- Anything a NixOS generation rollback cannot undo: schema or data migrations, state-format changes.
- A deploy of nixfiles' own change that fails twice, or leaves hosts unhealthy. (Peer builds: see `nack` above.)
- Changing app settings through an API (e.g. Sonarr `autoRedownloadFailedFromInteractiveSearch`), unless the plan names that exact change.
- Anything listed as not allowed mid-run above.

## Where to look for more work
Mandate (open scope only): keep the fleet and the media stack healthy and declarative.
- `docs/main-plan.md`: "Active plans", "Upcoming plans (recommended order)", "Deferred" (docs/ is gitignored, local only).
- `docs/autonomous-log-2026-10-18.md`: "Passive watches" and open findings.
- `docs/ops.md`: entries marked unresolved.
- `docs/owner-checklist-2026-10-17.md` is owner-only: never act on it.
