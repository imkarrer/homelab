# homelab

Platform layer for `ac-box` (HP Z840). Owns the host; tenants are flake inputs.

Six workloads share this machine — Assetto Corsa race servers, the AC Discord
bot, the kid arcade hub, a CPU-only LLM server, the Prometheus/Grafana stack,
and a self-hosted Buildkite runner. Until this repo existed, the host
configuration lived inside the oldest of them.

Design rationale and the full migration plan:
<https://claude.ai/code/artifact/61c15556-ccc7-4cc5-994d-a213c669556c>

## Layers

| | Layer | Owns |
| --- | --- | --- |
| L0 | `modules/platform/` | hardware, NICs, identity, Docker daemon, Nix, sshd, boot |
| L1 | `modules/tenant/` | the contract: schema, port registry, tiers, metrics, drain |
| L2 | `modules/observability/`, `modules/ci/` | shared services that *consume* the contract |
| L3 | flake inputs | `assetto`, `arcade`, `agent-hub` — declare, never reach |

Dependency direction is one-way: L0 knows nothing about tenants, L1 knows only
the schema, L2 reads declarations, L3 declares without knowing its neighbours.

## Pinned conventions

These are decided. Do not re-litigate them in a module, and do not introduce a
second spelling of any of them.

**Namespace** is `homelab.*` — `homelab.host.*`, `homelab.tenants.<name>.*`,
`homelab.tiers.<tier>.*`. Never `platform.*` or `box.*`.

**Tenant names** are exactly: `assetto`, `arcade`, `agent-hub`,
`observability`, `ci`. The Discord bot is a compose profile *inside* `assetto`
(`profiles: ["bot"]`), not its own tenant — it splits out after phase 6.

**Unit and container names never change.** `docker_name_exporter.py` maps
container names to Grafana dashboards; `arcade-freeciv`, `arcade-mindustry`,
`ac-host-static`, `agent-hub-llm` and the `ac-*` containers keep their current
names. The contract assigns units to slices; it does not rename them.

**Port scopes** are `local` / `lan` / `forwarded` / `mgmt`. `forwarded` exists
because AC is internet-facing on purpose: `unifi_pf.py` opens UniFi Dream
Router forwards per lobby slot at the box's LAN address. Forwarded traffic
still arrives on `enp8s0`, so interface-scoping is correct — but it must be
declared, and it requires a `justification`.

**Tiers are shares of declared capacity**, never absolute gigabytes or CPU
indices, or the config stops being portable. Use `CPUWeight` so idle capacity
stays usable, and `AllowedCPUs` only to fence `background`/`batch` *away from*
the cores `critical` uses — do not hard-cap `critical`.

**State paths are preserved, not tidied.** Derived default is
`${paths.state}/<tenant>`, but `assetto` explicitly keeps `/var/lib/ac-host`.
Renaming code is a commit; renaming a state directory is a data migration of
races, series, content and the player whitelist.

**`nixpkgs` is owned here.** The host channel is `nixos-26.05`. Tenant flake
inputs take `inputs.nixpkgs.follows = "nixpkgs"`; a tenant must not drag its
own nixpkgs into the closure. `agent-hub` currently pins `nixos-unstable` and
must be made to follow — `llama-cpp` on 26.05 is version `9190`, so verify any
`llama-server` flag against that build, not against unstable.

**`hardware-configuration.nix` and `ssh-keys.local.nix` are tracked.** A flake
copies only git-tracked files into the store, so a build from
`github:imkarrer/homelab` sees exactly what git sees. Ignoring them — the
convention inherited from rsync-deployed `ac-host` — made gate 1 build a system
with no authorized keys and the hardware stub that says of itself it will not
boot a real machine, and it did so without an error. `.gitignore`'s NOTE and
commit `daac96f` carry the full account; do not re-add either path to it. Fetch
them read-only from `ac-box:/var/lib/ac-host/src/hosts/ac-box/` and never invent
one. `hosts/ac-box/configuration.nix` now *throws* on a missing hardware file
rather than substituting the `.example` stub.

**Everything is public except one file.** `whitelist.json` holds third-party
`steam_id` + `discord_id` pairs and stays box state, never git. Credentials go
to sops-nix. SSH *public* keys are not secrets, and neither are disk UUIDs —
which is why the two files above are tracked in a public repo.

## Working agreements for automated changes

- **Never write to ac-box.** Read-only inspection over SSH is fine. Every
  `nixos-rebuild`, `systemctl`, and file write on the box is a human action,
  gated by the cutover runbook.
- **Never push.** Commit locally; publishing is a human action.
- **Do not run `bd` write commands.** The tracker is updated by one coordinator
  to avoid Dolt lock contention between parallel workers.
- Prove Nix work with `nix eval` / `nix flake check` in WSL. The closure gates
  (`diff-closures`, `switch-to-configuration dry-activate`) run on the box, by
  a human, in the window.
