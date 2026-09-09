# Current State: What ac-box Actually Runs

The standing answer to "what is deployed, and does it conform?" — maintained,
not archived. `docs/noop-reconciliation.md` is the *phase 1* survey and is
frozen as a historical record of that migration step; this file is the one
that must be true today.

**Last reconciled:** 9 Sep 2026, read-only over `ssh ac-box`.
**Last updated:** 9 Sep 2026, after the first round of supervised work landed
(`45db9dc`, `6e18170`, `1c6827f`, `37e6927`, and `home-arcade` `92c1c68`).
**Method:** see [Keeping this current](#keeping-this-current) at the bottom.
**Nothing on ac-box was modified to produce this document.**

> **Correction, same day.** The closure drift was first recorded here as 26
> commits against boundary `8f17486`. That compared the box's `-0500` wall
> clock against UTC committer dates. On epochs the boundary is `5fc6c90` and
> the count is **15** — settled against ground truth rather than by argument,
> by checking both candidates out into scratch worktrees and evaluating each:
> `5fc6c90` reproduces the box's exact toplevel store path `2a6qm0b…`,
> `8f17486` does not. Corrected throughout. The finding is unchanged; only its
> magnitude was wrong.

> **Reboot owed — but narrower than first recorded.** `/run/booted-system`
> (`9ick7piz…`) differs from `/run/current-system` (`2a6qm0b…`), so the box was
> switched after boot. But `kernel`, `initrd`, `kernel-modules` and
> `kernel-params` are **identical** between the two; only `init` and
> `system-path` differ (gen 28→29: samba, freeciv, the four slices). **No
> kernel change is pending.** The general hazard stands — a future kernel or
> boot-parameter change would look applied and not be — and `hub-status.sh`
> reports the condition. Order the reboot last: HAZARD 1 step 2 removes the CI
> containers, and nothing restarts them until the switch creates
> `ac-host-ci.service`, so rebooting in that window leaves no Buildkite agent.

Visual companion (same survey, diagrammed):
<https://claude.ai/code/artifact/49abb0ae-3374-4ba4-921f-8e87fba0c52d>

---

## 1. The headline: two delivery paths, one of them missing

ac-box takes code by two entirely separate routes, and only one is wired.

| | Tenant tree | System closure |
| --- | --- | --- |
| Owns | containers, scripts, content | units, slices, firewall, ports |
| Repo | `ac-host` | `homelab` |
| Registry | `deploy=buildkite` | `deploy=none` |
| Pipeline | test → lint → `wait: ~` → `queue-prod` | `nix flake check` → module eval → **stops** |
| Reaches the box by | `rsync` to `/var/lib/ac-host/src` | `nixos-rebuild switch --flake`, by hand |
| Staging artifact | `pending-deploy.json` | none |
| Drift detectable by `hub-status.sh` | yes | **no** |

Both paths end at a human — `queue-prod` sits behind a `DOWNTIME=1` block step
with no webhook. The difference is that the tenant-tree path ends at a human
*who is prompted*: it stages a sha, and `hub-status.sh` reports it as pending
until applied. The closure path stages nothing and is checked by nothing.

`home-arcade` and `agent-hub` reach the box only *through* homelab's closure
(they are flake inputs, not deploy targets), so they inherit the same stall.

### The consequence, as of this survey

`scripts/hub-status.sh` exits 0 and prints `VERDICT: reconciled`. Every claim
it makes is true. It compares each WSL tree to origin, and the box's tenant
tree to the sha in `/var/lib/ac-host/last-applied.json`. Both are clean.

It never reads `/run/current-system`. So the one repo that owns the host is the
one repo whose deployed state the hub does not check — which is how 15 commits,
two of which enable services, sat unapplied under a green verdict.

| | |
| --- | --- |
| Running generation | 29, built 2026-09-07 19:41 |
| System closure | `nixos-system-ac-box-26.05.20260829.c5c4a43` |
| Commit that built it | `5fc6c90` "Phase 8: lift observability out of the racing tenant into L2" — confirmed by reproducing the box's exact store path from a scratch worktree |
| homelab HEAD at survey | `492064b` |
| Closure drift | **15 commits**, 2 of which flip services on |
| Tenant tree | `340b4fb`, applied = pending, box tree byte-clean |

Undeployed commits that change behaviour, not just text:

| Commit | Effect still missing from the box |
| --- | --- |
| `45f67ab` | enables the agent-hub model server + retargets tier shares at it |
| `4257aea` | `homelab.ci.enable` — adopts the CI stack under systemd |
| `3fef4fe` | fences tiers by *physical* core; stops opening ports for disabled tenants |
| `0de8c09` | restores batch's memory ceiling |
| `3803e45` | moves observability's Grafana firewall rule onto the tenant contract |

---

## 2. Classification

"Conforming" means: declared in the tenant contract, present on the box, and
matching the declaration on ports, slice and state path. Anything that is only
two of those three is nonconforming, in either direction — a declaration with
no service behind it fails just as surely as a service with no declaration.

### Conforming

| Service | Tenant | Basis |
| --- | --- | --- |
| `ac-host-static.service` + 3 `ac-static-*` containers | assetto | Three lobbies live on 9600–9602 / 8081–8083 / 8181–8183 / 11200–11202, all inside declared ranges. State preserved at `/var/lib/ac-host`. |
| `ac-host-nightly.timer` / `.service` | assetto | Declared, scheduled, no failures. |
| `ac-host-dev.service` | assetto | Inactive, and correctly so — the unit is documented "manual, does not start at boot". Its port 18081 is declared and unbound. The absence *is* the declaration being honoured. |
| `ac-host-auth-1`, `-details-1`, `-plugin-1` | assetto | All in `critical.slice` via `cgroup_parent`. Loopback bind on 18080 matches `scope = "local"`. |
| `arcade-freeciv.service` | arcade | 5556/tcp on the LAN address, 4555/udp announce — both declared, matching the correction recorded in `tenants.nix`. |
| observability, 8 units | observability | All eight in `interactive.slice`. Nine declared ports, nine live binds; every collector on loopback, Grafana the one LAN port. State preserved at `/var/lib/monitoring`. |

### Nonconforming

| Item | Tenant | Gap |
| --- | --- | --- |
| `agent-hub-llm.service` | agent-hub | **Does not exist on the box.** `enable = true` with a full `llm` block (modelPath, threads 23, mlock, NUMA). `background.slice` is inactive with no members; 8100 has no listener. Undeployed (`45f67ab`, `0de8c09`). |
| `tcp/8100` firewall rule | agent-hub | Open on `enp8s0` with nothing behind it — `iptables -S nixos-fw` confirms the accept rule. The exact stale-rule bug `tenants.nix` describes as "fixed now"; the fix (`3fef4fe`) has not reached the box. |
| `ac-host-ci-agent-1`, `-minio-1` | ci | Declared with `units = []` — an empty unit set is the tell. Hand-started with `docker compose up -d`; no systemd unit, no start-on-boot, no supervised restart. Resource fencing is correct (`cgroup_parent: batch.slice`); lifecycle is not managed at all. Fix committed (`4257aea`), undeployed, and gated behind a human-run adoption sequence. |
| `ac-host-bot-1` | assetto | The Discord bot, running in `critical.slice` as compose profile `["bot"]`, in no tenant's `units` list — invisible to drain, quiet hours and `/etc/homelab/tenants.json`. README defers the split to "after phase 6"; phase 6 (slices) is applied, so the deferral has expired. |
| ~~`samba-smbd`, `samba-winbindd`, `rsync.service`~~ | arcade | **Closed 9 Sep.** Added to arcade's `units`, so all three now take `Slice=interactive.slice`. Doing it exposed a contract defect — see F8. |
| ~~`udp 11300–11302`~~ | assetto | **Closed 9 Sep.** Registered as `assetto.portRanges.pluginEvent`, `start = 11300; count = 16`, derived from `render_cfg.py`'s `PLUGIN_EVENT_START` and `acctl.py`'s `SLOT_COUNT = 16` — not from the three sockets that happened to be bound. |
| ~~`udp 20151`~~ | arcade | **Closed 9 Sep, and it was a live bug.** Proven a fixed constant, not ephemeral: outside the kernel ephemeral range, and `javap -constants mindustry.Vars` on the shipped jar gives `multicastPort = 20151` / `multicastGroup = "227.2.7.7"`, corroborated by `/proc/net/igmp` showing group `070702E3` joined on `enp8s0`. **Mindustry LAN discovery was broken** — nothing opened 20151, so every discovery packet was dropped and the only way onto the server was typing its address. Fixed in `home-arcade` (`mindustry.multicastPort`, mirroring `freeciv.announcePort`) and the claim flipped to `scope = "lan"`. |
| `background` + `batch` share `AllowedCPUs = 28-55` | — | Live, and wrong: a Buildkite Nix build lands on precisely the cores the model server is meant to be pinned to; only `CPUWeight` (50 vs 250) separates them, which is a share, not an isolation. Fixed in `3fef4fe`, undeployed. |

### Decommission

| Item | Why |
| --- | --- |
| `/etc/nixos/configuration.nix` | A stock, pre-refactor NixOS host config dated 31 Aug, at the path `nixos-rebuild` reads when `--flake` is omitted. **Correction:** this was first recorded here as building silently and exiting 0. It does not — a bare `nixos-rebuild switch` fails at evaluation, because the box's `NIX_PATH` carries no `nixos-config` entry (`nix-instantiate --find-file nixos-config` → not found). The danger is real but narrower: that protection is an accidental nixpkgs default that nothing in this repo asserts, and four ordinary actions re-arm it (`-I nixos-config=`, `NIXOS_CONFIG=`, anyone setting `nix.nixPath`, a nixpkgs bump) — plus the reader who opens `/etc/nixos` to learn what the box runs and believes it. If it *did* apply: no `virtualisation.docker`, so `docker.service` stops and all nine containers with it, and `PermitRootLogin = "yes"` against the platform's `"prohibit-password"`. Remedy is a `throw`, not deletion — `nixos-generate-config` writes `configuration.nix` only when the path is *absent*, so an empty `/etc/nixos` is one accidental invocation away from a fresh stock config. See `docs/runbook-decommission.md`. |
| ~~`/etc/nixos/hardware-configuration.nix`~~ | **Keep.** Verified AST-identical to the tracked copy and to the one at `5fc6c90` (the commit that built the running closure) — `nix-instantiate --parse` sha256 `0f0e8b723682cbe8` for all three, despite three different formattings. It declares no services and reverts nothing. Do **not** verify by regenerating: `nixos-generate-config` on the box today emits a *worse* file — nine `fileSystems."/var/lib/docker/rootfs/overlayfs/<hash>"` entries, one per running container, and drops `usbhid`, `usb_storage` and `sd_mod` from the initrd modules. |
| `wpa_supplicant.service` | Running on a machine with no wireless interface — `/sys/class/net` lists `eno1`, `enp8s0`, docker bridges and veths, nothing else. A NetworkManager default nobody turned off. |
| ~~`ac-host-ci-minio-init-1`~~ | **Not a leftover — this entry was wrong.** The `agent` service declares `depends_on: minio-init: service_completed_successfully`, so the exited container *is* the record that the condition was met. Compose needs it, and it reappears after adoption. No action. |
| `inquire-platform` (registry row) | `hub/repos.psv` carries it as `remote=none deploy=none` on branch `local-dev-environment`. Nothing on ac-box runs it, and with no remote it cannot be gated, pushed or deployed. It is a WSL working tree, not a home-lab service. |

---

## 3. The box at rest

Live values, read from `systemctl show`. Note that these reflect the *old* tier
defaults — the rebalance in `45f67ab`/`0de8c09` is undeployed.

| Slice | CPUWeight | MemoryMax | AllowedCPUs | Members |
| --- | --- | --- | --- | --- |
| `critical.slice` | 500 | 87.9 GiB | unfenced | 7 docker scopes (3 lobbies, 3 sidecars, the bot) |
| `interactive.slice` | 200 | 37.7 GiB | unfenced | arcade ×2, observability ×8 |
| `background.slice` | 250 | 75.3 GiB | `28-55` | **inactive, none** |
| `batch.slice` | 50 | 25.1 GiB | `28-55` | 2 docker scopes (buildkite agent, minio) |
| `system.slice` | 100 (default) | none | — | `ac-host-static`, nightly timer, samba, rsync, sshd, fail2ban |

Two structural facts read straight off this table:

**Assetto's containers are fenced but its units are not.** The compose file's
`cgroup_parent: critical.slice` puts the seven containers in the tier, while
`ac-host-static.service` itself stays in `system.slice` — exactly as
`resources.nix` intends. `tier = "critical"` *and* `quiet.drainable = false`
each independently disqualify a tenant from `Slice=` assignment, because
`Slice=` applies at unit start and `ac-host-static`'s `ExecStop` is
`docker rm -f` on three live race servers. This is correct, deliberate, and
documented in the module; it is listed here so it is not re-discovered as a bug.

**`background` and `batch` share one fence.** See the nonconforming table.

---

## 4. Idiomatic Nix: audit

Assessed against the migration this repo is carrying out. Short version: the
module layer is unusually disciplined — `mkIf`/`mkMerge` are used correctly
throughout, assertions are separated from derivations so the contract can ship
inert, `follows` is applied to every input that has a `nixpkgs`, and the
option namespace is single-spelled. The findings below are the exceptions.

### Confirmed good

- **`mkIf false` contributes nothing, and the tests assert it.** `ports.nix`,
  `resources.nix` and `metrics.nix` each wrap their effect in `mkIf` rather
  than leaving an unconditional attrset with empty lists, and each has an
  `allFalse` eval case asserting the option is *undefined* rather than merely
  empty. This is the correct instinct and it is rarer than it should be.
- **Evaluation-time assertions are ungated.** Port collisions, the forwarded
  justification, the mgmt address and the 0.9 memory budget all fire with
  every `enforce.*` flag off, because they cost nothing in the closure. This
  is what let the contract ship before its effects were turned on.
- **`mkDefault` on tier values.** Every entry in `tierDefaults` is `mkDefault`,
  so a host overrides without `mkForce`. `configuration.nix` relies on this.
- **Shares, never absolute units.** No CPU index or gigabyte figure appears in
  a host file; `host.nix` is the only file with machine literals. ADR 0002
  holds under inspection.
- **Single `nixpkgs` node.** `ac-host` and `agent-hub` both `follows`;
  `home-arcade` has no inputs at all (`outputs = { self }`), so there is
  nothing to make follow and the comment saying so is accurate.
- **The `.service.service` class of bug is fixed and documented.**
  `resources.nix` strips the suffix before keying `systemd.services`, and its
  comment records that the built closure once carried ten phantom units while
  `dry-activate` cheerfully reported no restarts.

### Findings

**F1 — A silent fallback decides whether the system can boot.**
`hosts/ac-box/configuration.nix` selects `hardware-configuration.nix` if
`builtins.pathExists` finds it, else `.example`, which states it will not boot
a real machine. A flake copies only *git-tracked* files into the store, so this
conditional is really testing "is the file tracked?" — and the answer today is
yes (`git ls-files` confirms both it and `ssh-keys.local.nix` are tracked;
`.gitignore` carries a NOTE explaining they were deliberately un-ignored for
exactly this reason). The build is therefore correct. The hazard is that
`README.md`'s pinned conventions and `configuration.nix`'s own comment both
still say the file *is* gitignored. Anyone who "restores" that documented
behaviour gets a silently unbootable closure with no error. This is the same
failure shape the repo has caught twice before: *a comment describing an
intention the code does not implement.* A `throw` would be safer than a silent
substitution. **In progress — see §5.**

**F2 — `outputs` destructures without `...`.**
`outputs = { self, nixpkgs, ac-host, home-arcade, agent-hub }:` breaks
evaluation the moment an input is added, with an error that points at the
output function rather than at the input. `{ self, nixpkgs, ... }@inputs` is
the idiom. Minor, and arguably a deliberate strictness — but the failure mode
is misleading, which is the usual reason to prefer the idiom.

**F3 — `system.configurationRevision` is unset.**
`nixos-rebuild list-generations` reports `Configuration Revision: Unknown` for
every generation. Setting it (`self.rev or self.dirtyRev`) is the standard
idiom and would make the running closure self-identifying — which is precisely
what §1's blind spot needs. **In progress — see §5.**

**F4 — `nixosModules` under-exports.**
The flake offers `tenantContract` and `platform`, but `modules/observability`
and `modules/ci` are consumed only as inline paths in the `ac-box` module list.
`modules/observability/default.nix` was lifted out of a tenant repo *precisely*
so it could be shared; not exporting it leaves that half-done. Low urgency —
there is one host today — but it is the stated direction.

**F5 — `checks.ac-box` is the full system toplevel.**
`nix flake check` therefore *builds* the system, not merely evaluates it. The
pipeline comment argues this is affordable because the self-hosted agent reuses
a warm store and the MinIO substituter. That is true today and worth
re-examining if CI ever moves off ac-box, because it would then be a
from-source system build on every push.

**F6 — the UniFi router address was hardcoded in an L2 module. Fixed.**
`modules/observability/default.nix` reads `config.homelab.host.networks.lan
.address` for Grafana's bind (correct, and its comment says why), then
hardcodes `https://192.168.1.1` twice for `UNIFI_HOST` — once in the unpoller
config and once in `udr-fw-exporter`'s environment. The router's address is a
host fact with no home in `homelab.host.networks`, which today models only
`lan` and `mgmt` interfaces. This is the same drift trap the `arcade-hub`
comment in `configuration.nix` describes — *host facts are read from the host,
never inherited from a guess* — and it is the one place in the module layer
where a machine literal appears in code rather than in a comment. Everything
else surveyed is clean on this point: `grep` for `192.168.`, `enp8s0`, `eno1`
and `/var/lib/ac-host` across `modules/` returns comments only. The fix is a
schema addition (a gateway or `unifi.address` field on `homelab.host`), which
makes it a contract change rather than a drive-by edit. Landed in `6e18170`
as `homelab.host.unifi.address` — deliberately not `networks.lan.gateway`,
since the consumers speak the UniFi controller API and do not care what the
default route is; on ac-box those are one Dream Router wearing both hats, and a
`gateway` field would record the coincidence and go quietly wrong the day the
controller moves. Proven a no-op: the toplevel drvPath is byte-identical with
and without the change.

**F7 — the eval harnesses depended on `<nixpkgs>`, not on the flake. Fixed.**
`modules/tenant/tests/*.nix`, `modules/ci/tests/eval.nix` and
`modules/ci/scripts/run-eval-tests.sh` all default to
`(import <nixpkgs> { }).lib`, so they resolve through `NIX_PATH` rather than
through the pinned input. These are the tests that prove `ports.nix` still
*rejects* a colliding fixture — coverage `nix flake check` cannot provide,
since the real config has nothing to reject — so they are load-bearing. Being
load-bearing and unpinned is the objection: they can pass against a different
`lib` than the one the system is built with. Threading `lib` from the flake
(or exposing them as flake `checks`) closes it.

Fixed in `365e1d5`, with a correction to the finding as first written: the
*runner* was already pinned — `9c21cc7` injects the flake's nixpkgs with
`-I nixpkgs=…`. The live hole was the **harnesses**, each of which documents
`nix eval -f modules/tenant/tests/eval.nix <case>.checked` in its own Usage
block; that path got the channel's lib, or an error where no channel exists.
Fixing the injection would have fixed only the scripted path.

The pin now lives in `modules/tenant/tests/pinned-nixpkgs.nix`, which reads
`flake.lock` and `fetchTree`s the locked node verbatim — pure, no re-locking,
and the lock is *read* rather than the rev copied, so the pin keeps one home.
The `<nixpkgs>` fallback is gone, and `run-eval-tests.sh` passes
`--option nix-path ""` so a reintroduced lookup dies loudly instead of
resolving a channel. All 19 cases match baseline, including the five
expected-throw negatives, with `NIX_PATH` both cleared and poisoned. Suite
runtime dropped 18.0s → 3.8s, because three lib-only harnesses no longer
instantiate the whole package set.

**Open follow-up.** Exposing the harnesses as flake `checks` (F4's neighbour)
would let `nix flake check` cover them directly. The blocker is real: a fixture
that must *throw* cannot be a check that must *succeed* without inverting it
through `builtins.tryEval` and asserting `success == expected`. That inversion
belongs in the harnesses, and it would make `run-eval-tests.sh` largely
redundant — a separate design task, not a tidy-up.

**F8 — the contract could not claim any unit nixpkgs already sliced. Fixed.**
Found by doing the arcade work, not by reading: `resources.nix` emitted
`Slice=` at plain priority 100, which *ties* with any upstream module that sets
its own. nixpkgs' samba module pins `Slice = "system-samba.slice"` on
`samba-smbd` and `samba-winbindd`, so the moment arcade declared those units
the whole config stopped evaluating — `has conflicting definition values`, not
a merge. Every nixpkgs service that groups itself into a slice was
un-adoptable by a tenant, and a tenant's only lever (`units`) was the very
thing that triggered it.

Fixed by emitting `lib.mkOverride 90`, establishing a deliberate ladder:
upstream module 100 → this contract 90 → host composition 50 (`mkForce`).
The contract wins, because assigning units to slices is what it is *for*, and
naming a unit in `units` is a narrower, reviewed claim than an upstream
module's general default. `mkOverride 90` rather than `mkForce` keeps the top
of the ladder open so a host can still override without editing a pinned
module. The cost is real and recorded in the comment: a typo in a `units` list
now silently relocates someone else's unit instead of failing loudly.

Verified after the change — `samba-smbd`, `samba-winbindd`, `rsync`,
`arcade-freeciv`, `arcade-mindustry` and `prometheus` all resolve to
`interactive.slice`, while `ac-host-static` correctly resolves to no slice at
all.

**F9 — module-only flakes had no evaluation gate at all. Fixed.**
`hub-gates.sh` gates a Nix tree by enumerating its `nixosConfigurations` and
evaluating each. `home-arcade` is a module-only flake and has none, so the Nix
gate is *silently skipped* and the script falls through to a flox test that
fails in this tree for an unrelated reason (`.flox/env.json` is gitignored and
absent). `modules/arcade-hub.nix` defines real systemd services and firewall
rules on ac-box and nothing evaluates it before a push. The correct gate is to
evaluate it through the host that consumes it —
`nix eval --override-input home-arcade <local tree> .#nixosConfigurations
.ac-box…toplevel.drvPath` — which is how this round's arcade change was
actually verified. Fixed in `1c6827f`, and the gap was wider than F9 first
stated: `ac-host` and `agent-hub` are module-only too, and `agent-hub` ran
*zero* gates while printing a bare `GATES PASS`. The fix needed a guard worth
knowing about — `nix eval --override-input` with a name no input has exits 0,
warns nothing, and returns the unmodified drvPath, so a renamed input would
have turned the new gate back into a green no-op proving the pinned copy.
Input names are now checked against `nix flake metadata` first.

**Coverage caveat.** A composed eval proves what is *reachable* from ac-box's
config, not the whole module. `agent-hub` is imported but
`services.agent-hub.enable` defaults false, so its gate proves its option
declarations compose and little of its config body. Strictly better than zero,
and not the same as full coverage — which matters, because ADR 0006 makes these
gates the only thing between a merge and a switch.

**Minor — `nixpkgs.config.allowUnfree = true`** in `modules/platform/nix.nix`
is global. `allowUnfreePredicate` scoped to the packages that actually need it
(the nvidia driver, per `homelab.host.gpu`) states the intent and stops an
unrelated unfree dependency entering the closure unremarked.

**Not a finding: the tier model cannot fence Docker.** `resources.nix` emits a
`warnings` entry for any `needsDocker` tenant in a fenced tier, saying so
explicitly, and ADR 0005 records the decision. `cgroup_parent` in each tenant's
compose file is the fix, and it is applied. This is handled correctly.

---

## 5. Open work

Ordered by risk carried per unit of effort.

| # | Item | Status |
| --- | --- | --- |
| 1 | Neutralise the stale `/etc/nixos/configuration.nix` on the box | **Human action, runbook written** — `docs/runbook-decommission.md`. Gate 0 passes: the hardware files are proven AST-identical, so nothing blocks it. Replace with a `throw`; keep the hardware file. |
| 2 | Teach `hub-status.sh` to report closure drift (F3) | **Done** — `1c6827f`. Three-tier cascade; `HUB_STATUS_EXACT=1` is the exact check. Also reports the owed reboot. |
| 3 | Correct the stale `hardware-configuration.nix` documentation (F1) | **Done** — `37e6927`. Nine sites, not three; the silent `.example` fallback is now a `throw`. |
| 4 | Register `udp 11300–11302`; adjudicate `udp 20151` | **Done.** Both registered; 20151 turned out to be a live LAN-discovery outage, fixed in `home-arcade`. |
| 5 | Run the CI adoption sequence, then switch once | **Human action, in a window.** `modules/ci/default.nix` documents the order and both hazards. The switch must not be run *by* the Buildkite agent it bounces. Lands all 15 commits together. |
| 6 | Add samba/winbindd/rsync to arcade's `units` | **Done**, on explicit instruction that an arcade bounce is acceptable. Uncovered and fixed F8. The three still restart on the next switch — that is the intended, accepted cost. |
| 7 | Split the Discord bot into its own tenant | Deferral expired at phase 6. Needs a decision on tenant name and port/unit ownership. |
| 8 | Drop the `inquire-platform` registry row | Trivial, but it is a decision about the user's tree layout, not a defect. |
| 9 | Give the UniFi router address a home on `homelab.host` (F6) | **Done** — `6e18170`. `homelab.host.unifi.address`, not `networks.lan.gateway`. Proven a no-op: drvPath unchanged. |
| 10 | Pin the eval harnesses to the flake's `lib` (F7) | **Done** — `365e1d5`. The runner was already pinned; the harnesses were not. |
| 11 | Decide: does homelab get a pipeline, or a documented hand-off? | **Decision, not code.** Either is defensible — a switch that can bounce the CI agent may genuinely belong to a human. What is not defensible is the current state, where the registry says `deploy=none`, no runbook step names the switch, and drift accrues silently. |

---

## Keeping this current

This document is only worth having if it is refreshed rather than trusted.
Refresh it whenever the answer to "what is deployed?" could have changed — after
any `nixos-rebuild switch` on the box, after landing anything that changes the
closure, and before planning work that assumes a service is running.

**Step 1 — the three-way state.** One call, ~2s:

```bash
bash scripts/hub-status.sh; echo "EXIT=$?"
```

Exit 0 means the trees and the tenant tree are reconciled. Read the numbered
verdict on exit 1; each line names a distinct failure and they are not
interchangeable (see the `homelab-hub` skill for how to read them).

**Step 2 — the live survey.** These are the read-only commands this document
was built from. They are the ones that find drift `hub-status.sh` cannot see,
because they compare the *box* against the *declarations* rather than git
against git:

```bash
ssh ac-box 'nixos-rebuild list-generations | head -3; readlink -f /run/current-system; stat -c "%y" /run/current-system'
ssh ac-box 'systemctl --failed; systemctl list-units --type=service --state=running --no-legend'
ssh ac-box 'systemctl list-units --type=slice --no-legend; for s in critical interactive background batch; do systemctl show $s.slice -p CPUWeight -p MemoryMax -p AllowedCPUs -p ActiveState; done'
ssh ac-box 'docker ps -a --format "{{.Names}}\t{{.Status}}\t{{.Label \"com.docker.compose.project\"}}"'
ssh ac-box 'ss -tulnp'
ssh ac-box 'iptables -S nixos-fw'
ssh ac-box 'cat /etc/homelab/tenants.json'
```

**Step 3 — diff, in this order.** The order matters; each step assumes the one
before it passed.

1. `ss -tulnp` against the `ports`/`portRanges` blocks in
   `hosts/ac-box/tenants.nix`. **Every live listener must be declared, and
   every declared port must be live or explained.** Four separate gaps have
   been found this way and none of them by reading a config file — the
   11200 range, the 18080/18081 sidecars, freeciv's real 4555 announce port,
   the 11300 sidecar sockets, and Mindustry's 20151 multicast port. Assume
   there is a sixth.
2. `systemctl list-units --state=running` against every tenant's `units` list.
   A running service in nobody's `units` is invisible to drain, quiet hours
   and the inventory.
3. Slice membership against `tier`. Remember that `critical` and
   non-`drainable` tenants are *deliberately* unsliced — that is not drift.
4. `/etc/homelab/tenants.json` against `tenants.nix`. A tenant missing from
   the JSON was disabled when the closure was built; a tenant present with no
   running units is a declaration with nothing behind it.
5. The closure drift itself: homelab's HEAD against what built
   `/run/current-system`.

**Step 4 — update this file.** Move the date at the top, correct the tables,
and add a row to §5 rather than deleting one — an item that turned out to be a
human decision is more useful recorded as such than silently dropped.

### Open questions this round raised but did not settle

- **Thirteen containers became nine.** `docker ps` and `hub-status.sh` both
  report nine running; `docs/runbook-cutover.md`'s baseline and its success
  criterion 4 both say thirteen. Whether four were retired deliberately is
  unestablished — and until it is, the cutover runbook's success criterion
  cannot be evaluated.
- **`ci.units` is still `[]`**, in `tenants.nix` and in the live
  `/etc/homelab/tenants.json`. So even after the CI adoption switch,
  `ac-host-ci.service` is claimed by no tenant and lands in no slice —
  `batch.slice` will still be empty of the unit it exists for.
  `modules/ci/default.nix`'s header names this follow-up; it has not been made.
- **`modules/ci/default.nix`'s header is stale.** It says the module is "NOT
  imported by flake.nix or by hosts/ac-box/configuration.nix". Both import it
  now, and `configuration.nix` sets `homelab.ci.enable = true`.
- **`/var/lib/ac-host/src/hosts/ac-box/hardware-configuration.nix` is mode
  0666**, and `README.md` points operators at that path to fetch the hardware
  config.

**Standing rules while doing any of this.** ac-box is read-only: inspect over
ssh, change it by landing in git and letting the pipeline deploy. A hand-edit
on the box is a debugging step, never a resting state — land it the same
session. Leave `bd` writes to the coordinator.
