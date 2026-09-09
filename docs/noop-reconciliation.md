# Phase 1 No-Op Reconciliation: ac-box Settings Inventory

Human-readable counterpart to `nix store diff-closures`. The diff tool proves
*that* two closures differ; it is bad at explaining *what got forgotten* when
composing homelab's modules against ac-box's live system. This document walks
every setting contributing to ac-box's current system — sourced from
`~/src/ac-host` (now authoritative; the box's fork was committed and pushed
before this was written) — and records exactly where homelab reproduces it,
where it is deliberately deferred, or where it has **no home yet**.

Surveyed 7 Sep 2026. Live values were re-verified over read-only `ssh ac-box`
(`cat`, `systemctl show/status/cat`, `ss`, `docker ps`, `nixos-version`, and
similar inspection commands only — nothing was written to the box).

**Sources read:** `hosts/ac-box/host.nix`, `hosts/ac-box/tenants.nix`,
`modules/tenant/enforce.nix`, and all of `modules/platform/` (this repo);
`flake.nix`, `hosts/ac-box/configuration.nix`, `modules/ac-host.nix`,
`modules/monitoring.nix`, `modules/arcade-hub.nix`, and
`hosts/ac-box/hardware-configuration.nix` (`~/src/ac-host`, pulled fresh —
`a05a908` at time of writing).

`hosts/ac-box/configuration.nix` and `flake.nix` in **this** repo
(`homelab`) are being written concurrently by the cutover coordinator and are
intentionally not read as sources of truth here — every "GAP" below is a gap
against the files that exist *today*.

> **Correction, 9 Sep 2026 — `hardware-configuration.nix` and
> `ssh-keys.local.nix` are no longer gitignored.** The survey below describes
> them as gitignored, which was true when it was written and stopped being true
> hours later: Gate 1 showed that a flake copies only git-tracked files, so a
> build from `github:imkarrer/homelab` had neither file and fell back to the
> `[]` key list and the hardware stub that will not boot a real machine. Both
> files were tracked in commit `daac96f`; `.gitignore`'s NOTE is the
> authoritative account. Read the parentheticals below as a record of what was
> true on 7 Sep, not as the current rule.

---

## Boot

| Setting | Live value (ac-box) | Homelab reproduces via |
| --- | --- | --- |
| `boot.loader.systemd-boot.enable` | `true` | `modules/platform/boot.nix` |
| `boot.loader.systemd-boot.configurationLimit` | `5` (5 entries in `/boot/loader/entries`, live-verified) | `modules/platform/boot.nix` — **exact-match value, verified equal** |
| `boot.loader.efi.canTouchEfiVariables` | `true` | `modules/platform/boot.nix` |
| `boot.tmp.cleanOnBoot` | `true` | `modules/platform/boot.nix` |
| `fileSystems."/"`, `fileSystems."/boot"`, `swapDevices = []`, `nixpkgs.hostPlatform`, `hardware.cpu.intel.updateMicrocode` (all from `hardware-configuration.nix`) | ext4 root (`5ae5d017-…`), vfat `/boot` (`F5F3-902E`, `fmask=0022,dmask=0022`), no swap (`/proc/swaps` empty), `x86_64-linux` | `hosts/ac-box/hardware-configuration.nix` — byte-identical copy already exists in this repo (gitignored at the time; tracked since `daac96f` — see the correction above). **Not yet imported by anything**: `boot.nix`'s own header explains why the conditional import can't live in a platform module (would be `imports` depending on `config`, genuine infinite recursion) and must go in the per-host `configuration.nix`/`flake.nix` — which is what the coordinator is writing right now. Tracked here as *pending*, not a gap. |
| `boot.kernelPackages` | unset (nixpkgs default for `nixos-26.05`) | unset on both sides — reproduced by omission, contingent on the pinned-`nixpkgs` rule in README holding |
| `system.stateVersion` | `"26.05"` (from `hosts/ac-box/configuration.nix`) | **GAP** — not set in any of `modules/platform/*.nix`, `hosts/ac-box/host.nix`, or `hosts/ac-box/tenants.nix`. This almost certainly belongs in the in-progress `hosts/ac-box/configuration.nix`, but as of the files this document was scoped to read, it has no home. `system.stateVersion` drives default-value selection across many NixOS modules (not just an activation label) — confirm it lands as the literal string `"26.05"`, not a re-derivation, before Gate 1. |

## Networking

| Setting | Live value | Homelab reproduces via |
| --- | --- | --- |
| `networking.hostName` | `"ac-box"` | `modules/platform/network.nix`, derived from `homelab.host.name` (`hosts/ac-box/host.nix`) |
| `networking.networkmanager.enable` | `true` (live: `systemctl is-enabled NetworkManager` → `enabled`) | `modules/platform/network.nix` |
| `time.timeZone` | `America/Chicago` (live: `timedatectl`) | `modules/platform/network.nix`, derived from `homelab.host.timezone` |
| LAN address `192.168.1.50/24` on `enp8s0` | Not declared in NixOS on either side — owned by NetworkManager + a router DHCP reservation | `homelab.host.networks.lan` (`hosts/ac-box/host.nix`) records it as metadata for tenant port-scoping; `network.nix`'s own header confirms it deliberately does not configure `networking.interfaces` because ac-box's `configuration.nix` doesn't either. Reproduced (by matching omission). |
| `eno1` management interface, cabled, **down**, no address | Not present anywhere in `~/src/ac-host` — genuinely new | `homelab.host.networks.mgmt` (`hosts/ac-box/host.nix`). This is forward-looking scaffolding for a future dual-NIC runbook, not a live setting today, so it is not a gap — but note it is the one host fact with **no live counterpart to verify against**. |
| `ac-host` firewall: `allowedTCPPorts`/`allowedUDPPorts` for game (9600–9615), http (8081–8096), details (8181–8196) — set directly by `services.ac-host`'s own config block | Live-verified via `ss -tulnp`: 9600–9602/9608 (TCP+UDP), 8081–8083/8089, 8181–8183/8189 all bound by `acServer` | Consumed as flake input — `ac-host.nix` sets these itself, unconditionally, regardless of `homelab.enforce.firewall`. `hosts/ac-box/tenants.nix`'s `portRanges` records the same numbers as **registry metadata only** (no firewall effect while `homelab.enforce.firewall = false`). |
| `arcade-hub` firewall: interface-scoped on `enp8s0` (freeciv 5556, mindustry 6567, smb 445/139, rsync 873) | Live-verified via `ss -tulnp`, all bound to `192.168.1.50` specifically (not `0.0.0.0`) | Consumed as flake input — `arcade-hub.nix`'s own `networking.firewall.interfaces.${cfg.gameInterface}` block |
| `monitoring.nix` firewall: **global** `networking.firewall.allowedTCPPorts = [ 3000 ]` for Grafana | Live-verified: Grafana bound to `192.168.1.50:3000` | Consumed as flake input. **Forward-looking note, not a phase-1 gap**: `modules/tenant/ports.nix` never touches the global `allowedTCPPorts`/`allowedUDPPorts` — everything it emits is interface-scoped (its own header is explicit about this). `hosts/ac-box/tenants.nix` declares grafana as `scope = "lan"`. So the day `homelab.enforce.firewall` flips to `true` *and* observability's firewall ownership moves off `monitoring.nix`, the opening for port 3000 changes shape from global to interface-scoped — a real (if likely desirable) behavior change to plan for, not to be surprised by mid-cutover. |
| **Additional observation, not a settings gap**: `acServer` also binds UDP `11200/11201/11202/11208` (each declared game port + 1600) on `0.0.0.0`, live-verified via `ss -tulnp` | Live only | **No home anywhere** — not in `ac-host.nix`'s own `allowedUDPPorts`, not in `hosts/ac-box/tenants.nix`'s `portRanges`. This predates homelab entirely (it's an ac-host/AC-binary omission, not something this extraction introduced), but it means the tenant port registry that `hosts/ac-box/tenants.nix` claims was "verified live on the box" is missing a real, currently-open port range. Flagging per the instruction to be exhaustive; not fixing it here. |

## Identity / users

| Setting | Live value | Homelab reproduces via |
| --- | --- | --- |
| `users.users.nixosuser.extraGroups` | `[ "networkmanager" "wheel" "docker" ]` — live-verified: `id nixosuser` → `groups=100(users),1(wheel),57(networkmanager),131(docker)` | `modules/platform/identity.nix` — **exact-match, verified equal (order-independent, set-identical)** |
| `users.users.ac.extraGroups` | `[ "wheel" "docker" ]` — live-verified: `id ac` → `groups=100(users),1(wheel),131(docker)` | `modules/platform/identity.nix` — **exact-match, verified equal** |
| `users.users.{nixosuser,ac,root}.openssh.authorizedKeys.keys` | 2 keys (an `ssh-ed25519` deploy key, an `sk-ssh-ed25519@…` flox-signing key) | `modules/platform/identity.nix` reads `hosts/<name>/ssh-keys.local.nix`; `hosts/ac-box/ssh-keys.local.nix` in **this** repo is byte-identical (diffed) to the file on the box |
| `security.sudo.wheelNeedsPassword` | `false` | `modules/platform/identity.nix` |
| `environment.systemPackages` (base): `htop`, `tmux`, `curl`, `rsync`, `git` | present | `modules/platform/identity.nix` — exact list match |
| Tenant-contributed `environment.systemPackages`: `docker-compose`, `python3`, `git`, `rsync` (added by `services.ac-host.enable`) | present (union with the base list above) | Consumed as flake input — `ac-host.nix` adds these itself; not part of the platform layer's job |

## Nix daemon

| Setting | Live value | Homelab reproduces via |
| --- | --- | --- |
| `nixpkgs.config.allowUnfree` | `true` (needed to build the nvidia package) | `modules/platform/nix.nix` |
| `nix.settings.experimental-features` | `nix-command flakes` (live: `/etc/nix/nix.conf`) | `modules/platform/nix.nix` |
| `nix.settings.trusted-users` | `root root nixosuser ac` (live `/etc/nix/nix.conf`; root appears twice because NixOS auto-adds it alongside the literal list) | `modules/platform/nix.nix` — literal `[ "root" "nixosuser" "ac" ]`, deliberately **not** derived from `identity.nix`'s user set (the module's own comment: this layer's job is a clean no-op diff, not a tidier equivalent) — **exact-match, verified equal** |
| `nix.settings.auto-optimise-store` | `true` (live `/etc/nix/nix.conf`) | `modules/platform/nix.nix` |
| `nix.gc` (`automatic=true`, `dates="weekly"`, `options="--delete-older-than 7d"`) | live-verified: `nix-gc.timer` active, next run Mon 2026-09-14 | `modules/platform/nix.nix` |
| `nix.optimise.automatic` | `true` (live-verified: `nix-optimise.timer` active) | `modules/platform/nix.nix` |

## sshd / fail2ban

| Setting | Live value | Homelab reproduces via |
| --- | --- | --- |
| `services.openssh.enable` | `true` | `modules/platform/ssh.nix` |
| `services.openssh.settings.PasswordAuthentication` | `true` — live-verified (`sshd -T`) | `modules/platform/ssh.nix` — **recorded as reality, not aspiration**; the original "leave it on until you confirm key-only logins" comment is preserved verbatim rather than acted on |
| `services.openssh.settings.KbdInteractiveAuthentication` | `true` — live-verified | `modules/platform/ssh.nix` — same, recorded as-is |
| `services.openssh.settings.PermitRootLogin` | `"prohibit-password"` — live-verified | `modules/platform/ssh.nix` |
| `services.fail2ban.enable` | `true` — live-verified (`systemctl is-active fail2ban` → `active`), default jail only, no custom jail config on either side | `modules/platform/ssh.nix` |

## journald

| Setting | Live value | Homelab reproduces via |
| --- | --- | --- |
| `services.journald.extraConfig` → `SystemMaxUse` | `200M` — live-verified in `/etc/systemd/journald.conf` | `modules/platform/boot.nix` (journald caps live here; no platform module was a natural fit, so it rides along with other system hygiene) — **exact-match, verified equal** |
| `services.journald.extraConfig` → `MaxRetentionSec` | `14day` — live-verified | `modules/platform/boot.nix` — **exact-match, verified equal** |

## GPU

| Setting | Live value | Homelab reproduces via |
| --- | --- | --- |
| `hardware.graphics.enable` | `true` | `modules/platform/boot.nix`, gated on `homelab.host.gpu == "nvidia"` (`hosts/ac-box/host.nix` sets `gpu = "nvidia"`, so effectively unconditional for this host, same as today) |
| `services.xserver.videoDrivers` | `[ "nvidia" ]` | `modules/platform/boot.nix`, same gate |
| `hardware.nvidia.modesetting.enable` | `true` | `modules/platform/boot.nix` |
| `hardware.nvidia.powerManagement.enable` | `true` | `modules/platform/boot.nix` |
| `hardware.nvidia.open` | `false` | `modules/platform/boot.nix` |
| `hardware.nvidia.package` | `config.boot.kernelPackages.nvidiaPackages.stable` → resolves live to `nvidia-x11-595.71.05-bin` | `modules/platform/boot.nix` — same expression, so resolves identically by construction |
| **Operational aside, not a config gap**: `nvidia-smi` currently fails (`NVRM: No NVIDIA GPU found` in `dmesg`) | live, today | Not a setting difference — the driver stack builds and activates identically either way; whether the physical GPU is currently detected is a hardware/runtime fact, not something a NixOS config controls. Noted for completeness only. |

## Docker

| Setting | Live value | Homelab reproduces via |
| --- | --- | --- |
| `virtualisation.docker.enable` | `true` | **Known intentional difference** — see below. Still set by `services.ac-host`'s own config block (`ac-host.nix`, a flake input) in phase 1, *not* by `modules/platform/docker.nix`, even though that module already exists in this repo. |
| `virtualisation.docker.autoPrune.enable` | `true` | Same — same intentional deferral |
| Daemon defaults (`group=docker`, `hosts=["fd://"]`, `live-restore=false`, `log-driver=journald`) | live-verified via the rendered `daemon.json` | Pure NixOS-module defaults triggered by `enable=true` alone — no separate literal to carry on either side |

## Tenants

| Setting | Live value | Homelab reproduces via |
| --- | --- | --- |
| `homelab.enforce.firewall` | n/a — no such concept exists on ac-box today | `modules/tenant/enforce.nix`, default `false` — **known intentional difference**, see below |
| `homelab.enforce.slices` | n/a | `modules/tenant/enforce.nix`, default `false` — same |
| `homelab.enforce.scrape` | n/a | `modules/tenant/enforce.nix`, default `false` — same |
| `homelab.enforce.inventory` | n/a | `modules/tenant/enforce.nix`, default `false` — same |
| assetto units (`ac-host-static`, `ac-host-nightly.{service,timer}`, `ac-host-dev`) | all live and running (`ac-host-static` active since before this survey; `NRestarts=0` per runbook baseline) | Entirely produced by `ac-host.nix` (flake input). `hosts/ac-box/tenants.nix`'s `units` list is registry metadata only — it has no derivation effect while `homelab.enforce.*` is off |
| arcade units (`arcade-freeciv`, `arcade-mindustry`) | `arcade-freeciv` live and bound on `192.168.1.50:5556`. `arcade-mindustry` is `active (running)` per systemd but **not actually bound** — no listener on 6567 in `ss -tulnp` | Produced by `arcade-hub.nix` (flake input) — see the drift section below for *why* mindustry isn't bound; `hosts/ac-box/tenants.nix`'s own comment already flags "mindustry not actually bound despite active," this document explains the mechanism |
| agent-hub unit (`agent-hub-llm.service`, port 8100) | **Does not exist.** No such systemd unit is loaded on ac-box (`systemctl list-units --all` returns nothing), and no `agent-hub` module exists anywhere in `~/src/ac-host` | `hosts/ac-box/tenants.nix` declares this tenant as if it has a home, but nothing in the sources this document was scoped to read wires it up. This is not a phase-1 *equivalence* gap (nothing needs to be dropped from the box), but it is a **registry-accuracy problem**: the tenant contract currently describes a unit and a port claim that correspond to no real flake input yet. Per the README, `agent-hub` is a separate, not-yet-`follows`-ed flake pinned to `nixos-unstable` — this tenant entry is aspirational scaffolding for that future wiring, not a description of ac-box today. |
| observability units (all 8: `prometheus`, `alertmanager`, `grafana`, `prometheus-node-exporter`, `cadvisor`, `unifi-poller`, `docker-name-exporter`, `udr-fw-exporter`) | all live-verified `active running`, unit names match `hosts/ac-box/tenants.nix` exactly | Produced by `monitoring.nix` (flake input) |
| ci tenant (minio-api/console ports, Buildkite agent) | **No systemd unit on either side.** `hosts/ac-box/tenants.nix`'s own comment: "Started by hand via docker compose today — no systemd unit wraps it." Live-verified: `ac-host-ci-agent-1` and `ac-host-ci-minio-1` containers are up, started manually. | Consistent absence on both sides — nothing to reproduce; not a gap |
| `homelab.host.capacity` (`cpuThreads=56`, `memoryGiB=251`) | live-verified: `nproc` → 56, `free -g` → 251 total | `hosts/ac-box/host.nix`. Feeds the activation-time capacity-drift check in `modules/tenant/resources.nix`, itself gated off by `homelab.enforce.slices = false` — so the check doesn't run yet either, consistent with the values being unused today |

## Monitoring

| Setting | Live value | Homelab reproduces via |
| --- | --- | --- |
| `users.groups.monitoring`, `users.{unifi-poller,grafana}.extraGroups=["monitoring"]` | present | Consumed as flake input (`monitoring.nix`) |
| `services.prometheus.exporters.node` (`listenAddress=127.0.0.1`, `port=9100`, `enabledCollectors=[systemd,filesystem]`) | live-verified, loopback-bound | Consumed as flake input |
| `services.cadvisor` (`listenAddress=127.0.0.1`, `port=9102`, `--docker_only=true` + related flags) | live-verified | Consumed as flake input |
| `services.unpoller` (`prometheus.http_listen=127.0.0.1:9130`, one UniFi controller at `https://192.168.1.1`) | live-verified | Consumed as flake input |
| `docker-name-exporter.service` (custom unit, `${../scripts/docker_name_exporter.py}`, binds `127.0.0.1:9132`) | live-verified running | Consumed as flake input. The runbook's own "One-Way Doors" table already flags this script-path dependency as a reason not to lift `observability` into its own flake input casually. |
| `udr-fw-exporter.service` (custom unit, `${../scripts/udr_fw_exporter.py}`, binds `127.0.0.1:9131`) | live-verified running | Consumed as flake input, same caveat |
| `services.prometheus` (`listenAddress=127.0.0.1:9090`, `retentionTime=14d`, `--storage.tsdb.retention.size=2GB`, `scrape_interval=30s`, 5 `scrapeConfigs`, 7 alert `rules`) | live-verified | Consumed as flake input. Note: `hosts/ac-box/tenants.nix` sets `metrics = null` on **every** tenant including `observability` itself — so even once `homelab.enforce.scrape` flips on, `modules/tenant/metrics.nix` has nothing to generate here; these scrapeConfigs and alert rules stay solely owned by `monitoring.nix` for the foreseeable future, not a transitional state. |
| `services.prometheus.alertmanager` (`listenAddress=127.0.0.1:9093`, Discord receiver via webhook file) | live-verified | Consumed as flake input |
| `services.grafana` (`http_addr=192.168.1.50:3000`, anonymous Viewer auth enabled, admin creds from generated secret files, one Prometheus datasource, dashboards provisioned from `./grafana-dashboards`) | live-verified bound on LAN | Consumed as flake input |
| `system.activationScripts.monitoring-secrets` (generates Grafana admin/secret-key passwords on first activation if absent) | present, files exist under `/var/lib/monitoring/secrets` | Consumed as flake input |
| `/var/lib/monitoring` state directory (holds hand-placed Discord webhook + unpoller password files) | present | `hosts/ac-box/tenants.nix` — `state.dirs = [ "/var/lib/monitoring" ]`, explicitly **not** the schema's derived default (`/var/lib/observability`), with the reasoning spelled out in the file's own comment |

## Filesystems

| Setting | Live value | Homelab reproduces via |
| --- | --- | --- |
| `fileSystems."/"` (ext4, `5ae5d017-8b98-4e5b-b8c5-f5658120ac89`) | live-verified via `mount` | `hosts/ac-box/hardware-configuration.nix` (byte-identical copy already in this repo; import pending, see Boot section) |
| `fileSystems."/boot"` (vfat, `F5F3-902E`, `fmask=0022,dmask=0022`) | live-verified via `mount` | same file |
| `swapDevices = [ ]` | live-verified: `/proc/swaps` empty | same file |
| `nixpkgs.hostPlatform = mkDefault "x86_64-linux"` | consistent | same file |

---

## Known intentional differences

What phase 1 deliberately does not reproduce, and why:

1. **The tenant contract's four effects are gated off.** `homelab.enforce.firewall`,
   `.slices`, `.scrape`, and `.inventory` all default to `false`
   (`modules/tenant/enforce.nix`). None of `ports.nix`'s firewall rules,
   `resources.nix`'s slices, `metrics.nix`'s scrapeConfigs, or `quiet.nix`'s
   `/etc/homelab/tenants.json` exist on ac-box today, so turning all four on
   at once on day one would fail Gate 1 by construction. Each will be turned
   on independently, in its own verifiable step, later.

2. **`virtualisation.docker` deliberately stays owned by `ac-host.nix` in
   phase 1**, even though `modules/platform/docker.nix` already exists in
   this repo and computes the identical `enable`/`autoPrune` values from
   `needsDocker` across the tenant set. The subtlety worth remembering: NixOS
   merges two modules setting the **same** boolean to the **same** value
   silently — they only conflict when the values differ. So importing
   `modules/platform/docker.nix` into `ac-box`'s module list *right now*,
   alongside `ac-host.nix` still setting `virtualisation.docker.enable = true`
   directly, would not fail anything today (`true == true`). It is a latent
   landmine, not a guaranteed error: the day either side's computed value
   diverges — a tenant's `needsDocker` gets toggled, or `ac-host.nix`'s own
   line is edited without the platform side changing in lockstep — the two
   modules will produce a genuine, silent-until-then conflict (or, if only
   one side changes, an unnoticed change with no assertion to catch it).
   Ownership should move to `docker.nix` deliberately, in its own step, with
   `ac-host.nix`'s own `virtualisation.docker.*` lines removed in the same
   change — not left to coexist indefinitely.

## Gaps

Anything the live system sets that homelab has no home for. Exhaustive, as
instructed — an omission here is exactly the failure mode this document
exists to catch.

1. **`system.stateVersion = "26.05"`** — not set in any of
   `modules/platform/*.nix`, `hosts/ac-box/host.nix`, or
   `hosts/ac-box/tenants.nix`. It almost certainly belongs in the in-progress
   `hosts/ac-box/configuration.nix`, but as of today it has no home in any
   file this document was scoped to read. This is one of the values the task
   explicitly called out as needing an exact match — confirm the literal
   string `"26.05"` lands somewhere before Gate 1.

2. **`hardware-configuration.nix` is not imported anywhere yet.** The file
   itself is byte-identical and already sitting at
   `hosts/ac-box/hardware-configuration.nix` (gitignored at the time; tracked since `daac96f` — see the correction above), but
   nothing in `modules/platform/` imports it — by design, per `boot.nix`'s
   own header comment (importing it there would make `imports` depend on
   `config`, a genuine infinite recursion). The conditional
   `hardware-configuration.nix` vs `.example` import has to live in the
   per-host `configuration.nix`/`flake.nix`, which the coordinator is writing
   concurrently with this document. Not treated as a numbered gap above
   because it is already known and in flight, but recorded here so it isn't
   lost: if the coordinator's composition forgets this import, Gate 1 fails
   immediately and loudly (no filesystem/hardware config at all), which is a
   much easier failure to diagnose than a silently-dropped boolean — but it's
   still worth a deliberate check before the first `nix build`.

3. **The tenant port registry is missing a real, currently-open port range.**
   `acServer` binds UDP `11200/11201/11202/11208` (each active game port +
   1600) on `0.0.0.0`, live-verified via `ss -tulnp`. This is in neither
   `ac-host.nix`'s own `networking.firewall.allowedUDPPorts` nor
   `hosts/ac-box/tenants.nix`'s `portRanges`, despite that file's own comment
   claiming the port table was fully verified live. This predates homelab
   (it's an ac-host-side omission, not something this extraction introduced)
   and has no closure-equivalence consequence today (`homelab.enforce.firewall`
   is off), but it means the registry itself is not yet trustworthy as a
   complete inventory, and it should be accounted for before firewall
   enforcement is ever turned on for assetto.

4. **`agent-hub` is declared as a tenant with no corresponding flake input,
   module, or live unit.** `hosts/ac-box/tenants.nix` gives it a full entry —
   description, tier, a unit name (`agent-hub-llm.service`), a port
   (`8100/tcp`) — but no such systemd unit exists on ac-box today, and no
   `agent-hub` module exists anywhere in `~/src/ac-host`. This has zero
   closure impact right now (the units list is inert metadata while
   `homelab.enforce.inventory` is off), but it means the tenant registry
   currently describes a piece of aspirational future wiring
   indistinguishably from the five tenants that are actually live — worth
   distinguishing before someone reads `tenants.nix` as ground truth for
   "what ac-box runs today."

---

## Remaining box-vs-git drift (ground-truth check)

`~/src/ac-host` was pulled fresh (`git -C ~/src/ac-host pull`, already
up to date at `a05a908`) and diffed against
`/var/lib/ac-host/src` on the box directly, file by file, for every file this
document reads from: `flake.nix`, `hosts/ac-box/configuration.nix`,
`modules/ac-host.nix`, `modules/monitoring.nix`, `modules/arcade-hub.nix`.

**Confirmed, as expected:**

- **CRLF line endings** in the box's copies (every file). Diffs above were
  taken with `\r` stripped from both sides first.
- **A stale top-level `arcade-hub.nix`** sits at
  `/var/lib/ac-host/src/arcade-hub.nix` (4862 bytes, dated 5 Sep), separate
  from and not imported instead of `modules/arcade-hub.nix`. Dead weight, not
  consumed by `flake.nix`.
- **`modules/ac-host.nix` is missing the `TimeoutStartSec = "15min"` guard**
  on `ac-host-static.service` that git has (git's comment: "If a sidecar
  rebuild ever hangs again, fail instead of blocking boot forever"). Confirmed
  via `systemctl cat`-equivalent diff; this is the one substantive
  line-level difference in that file, exactly as expected.
- `modules/monitoring.nix` and `hosts/ac-box/configuration.nix` are
  otherwise identical (CRLF aside) — no other drift found in either.

**New findings, not on the expected list:**

1. **`flake.nix` on the box is missing the `nixosModules.monitoring = import
   ./modules/monitoring.nix;` output line** that git has (added in git commit
   `4f29103`, "Expose nixosModules.monitoring as a flake output"). This has
   **no effect on the built closure** — `nixosConfigurations.ac-box`'s module
   list references `./modules/monitoring.nix` directly on both box and git,
   not through the `self.nixosModules.monitoring` alias — so it is purely an
   unexposed output attribute, informational only. It does mean git is
   currently a little *ahead* of the box's last-activated flake, which is
   worth knowing going into a diff exercise: not everything that differs
   between the box and git is "the box forked ahead," some of it is now the
   reverse.

2. **`modules/arcade-hub.nix` (the real, imported module — not the stale
   top-level copy above) has substantive content differences beyond CRLF**,
   and this is the one worth reading carefully:
   - The box's copy carries a stray header ("Deploy copy. Canonical source is
     github.com/imkarrer/home-arcade…") that git's canonical version dropped.
   - The box's copy still hardcodes `default = "192.168.1.50"` and
     `default = "enp8s0"` for `lanAddress`/`gameInterface`; git's version
     deliberately removed those defaults (its own comment explains why: a
     hardcoded default here is "exactly how it drifted" — this module and
     `agent-hub` each carried their own copy of the same IP). This has
     **no effect on the built config** for ac-box specifically, because
     `hosts/ac-box/configuration.nix` (both box and git, identical) sets both
     values explicitly to the same literals anyway — but it means the two
     module copies are not simply CRLF-apart, and a host that relied on the
     module's own default would get a different, wrong answer from the box's
     copy than from git's.
   - The box's copy has a mangled em-dash (`â€”`, a UTF-8 double-encoding
     artifact) in one comment — cosmetic only, unrelated to the CRLF issue.
   - **The `arcade-mindustry.service` `ExecStart` genuinely differs in
     behavior, not just text.** Git's version pipes the startup commands into
     the java process's stdin:
     ```
     printf '%s\n' "config name Arcade" "host sandbox" | exec ${pkgs.jre_headless}/bin/java -jar …
     ```
     The box's version instead passes them as trailing command-line
     arguments to the same `java -jar …` invocation. Live-verified via
     `systemctl cat arcade-mindustry.service` and `systemctl status`: the
     unit is `active (running)`, but the server log shows it only parsed
     `"config name Arcade" "host sandbox"` as **one** command-line argument
     (setting the server's display name to `Arcade host sandbox`) — it never
     actually received or ran the `host sandbox` console command that starts
     the game host. This is why `ss -tulnp` shows no listener on port 6567
     despite the unit being "active" — this is precisely the "mindustry not
     actually bound despite active" quirk that `hosts/ac-box/tenants.nix`'s
     own comment already flags, and this diff is the mechanism behind it.
     Git's version is the fix; the box is still running the broken one. If
     homelab composes `arcade-hub` from the pulled git tree (as it should),
     the generated `arcade-mindustry.service` unit file will differ from what
     is currently active on the box — a real, expected Gate 1 unit-file
     difference for this one unit, not a sign that homelab's composition is
     wrong. Worth calling out explicitly during Gate 1 review so it isn't
     mistaken for an unexplained regression, and worth deciding on purpose
     whether phase 1 should carry the box's current (broken) behavior forward
     for a true no-op, or accept this one intentional fix as part of the cut.
   - Not itself a nix-level difference, but adjacent: the box's `ac-host` tree
     also has a duplicate, unused `hosts/ac-box/ssh-keys.nix` (278 bytes,
     content-identical to the real `ssh-keys.local.nix` that's actually
     imported) — the same kind of harmless dead-file clutter as the stale
     top-level `arcade-hub.nix`.

3. **A vestigial `/etc/nixos/configuration.nix` exists on the box** (dated 31
   Aug, 4792 bytes) alongside a `hardware-configuration.nix` in the same
   directory. `readlink -f /run/current-system/configuration.nix` confirms
   the live system was built from the flake
   (`/nix/store/…nixos-system-ac-box-26.05.20260829.c5c4a43/configuration.nix`),
   not from `/etc/nixos`, so this file is dead and not part of the running
   system — but it's a stray file worth knowing about if anyone goes looking
   in the conventional NixOS location and gets confused about which config is
   authoritative.

4. **Operational aside, unrelated to any config file**: `nvidia-smi` on the
   box currently fails with "couldn't communicate with the NVIDIA driver,"
   and `dmesg` shows repeated `NVRM: No NVIDIA GPU found`. The nvidia driver
   stack is still declared and will still build/activate identically in
   homelab's composition (see GPU section above) — this is a hardware/runtime
   state, not a missing setting — but it means Gate 3's "no new RED targets"
   check won't catch a GPU regression either way, since the GPU already
   isn't functioning today.

---

## Summary

- **~72 discrete settings/facts enumerated** across the eleven areas above.
- **~68 have a home** in this repo today — either reproduced directly in a
  `modules/platform/*.nix` file, recorded as `homelab.host`/`homelab.tenants`
  metadata, or correctly left to arrive "consumed as flake input" from
  `ac-host.nix` / `arcade-hub.nix` / `monitoring.nix`.
- **1 hard gap**: `system.stateVersion`.
- **1 pending-but-tracked item**: the `hardware-configuration.nix` import,
  known to belong in the coordinator's in-progress `configuration.nix`/
  `flake.nix`.
- **2 registry-accuracy findings** that don't block Gate 1 but should not be
  mistaken for it being clean: the missing `11200`-series UDP ports in the
  port registry, and the `agent-hub` tenant entry with no real backing.
- **2 known, deliberate deferrals**: the tenant contract's four `enforce.*`
  effects, and Docker daemon ownership staying with `ac-host.nix`.
- **1 confirmed, expected functional difference on rebuild**: the
  `arcade-mindustry.service` `ExecStart` fix already present in git but not
  yet deployed to the box — this one will show up in Gate 1's closure diff
  and dry-activate output and should be recognized as intentional, not
  investigated as a regression.
