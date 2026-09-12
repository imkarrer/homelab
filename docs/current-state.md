# Current State: What ac-box Actually Runs

The standing answer to "what is deployed, and does it conform?" — maintained,
not archived. `docs/noop-reconciliation.md` is the *phase 1* survey and is
frozen as a historical record of that migration step; this file is the one
that must be true today.

**Last reconciled:** 12 Sep 2026, read-only over `ssh ac-box`, after
generations 30 and 31 were switched. The box runs HEAD.
**Method:** see [Keeping this current](#keeping-this-current) at the bottom.

> **History of this document, kept because the corrections are the useful
> part.** First written 9 Sep against generation 29 with a 26-commit drift
> figure; corrected the same day to **15** (a UTC-vs-`-0500` error, settled by
> reproducing the box's store path from a scratch worktree). The drift grew to
> 25 over three days of committed, gated, unapplied work, then closed to zero
> on 12 Sep in two switches. §1 records how.

Diagrams of the structures this document reports on —
[`docs/architecture.md`](architecture.md), tracked in git.

Visual companion to this survey (hosted, outside version control):
<https://claude.ai/code/artifact/49abb0ae-3374-4ba4-921f-8e87fba0c52d>

---

## 1. The headline: the closure is on the box

**12 Sep 2026, ~12:00 CDT: generations 30 and 31 were switched, and
`HUB_STATUS_EXACT=1 bash scripts/hub-status.sh` reports "CLEAN — this tree
builds exactly what the box runs."** The 25-commit closure gap this document
was written to expose is closed. The box runs HEAD `c97cbbe`.

The two delivery paths still differ in *mechanism*, and that difference is the
next slice of work (ADR 0006), but they no longer differ in *state*:

| | Tenant tree | System closure |
| --- | --- | --- |
| Owns | containers, scripts, content | units, slices, firewall, ports |
| Repo | `ac-host` | `homelab` |
| Registry | `deploy=buildkite` | `deploy=none` |
| Applied | `340b4fb`, byte-clean | `c97cbbe`, store-path exact |
| Reaches the box by | `queue-prod` → human `DOWNTIME=1` → rsync | `nixos-rebuild switch --flake`, by an operator or, during the migration, an agent (`AGENTS.md`) |
| Staging artifact | `pending-deploy.json` | none yet — `modules/deploy` is on the box, inert |
| Drift detectable by `hub-status.sh` | yes | **yes**, since `1c6827f` |

### How the switch was done

Two switches, not one, on this repo's own smallest-blast-radius rule:

- **Generation 30 → `3fef4fe`.** Fence fix and the `tcp/8100` close; neither
  service-enabling commit. `diff-closures` empty, `dry-activate` a firewall
  reload only. Bounced nothing.
- **Generation 31 → HEAD.** After the HAZARD 1 adoption sequence (hand-started
  compose stack stopped, three volumes verified, ports free). Started
  `agent-hub-llm` and `ac-host-ci`, moved samba/rsync into `interactive.slice`,
  stopped `wpa_supplicant`, rebalanced the tiers.

One defect surfaced by doing it: `docker compose … --build` under systemd
needed `git` on `ac-host-ci`'s `PATH` to fetch its build context. Fixed in
`c97cbbe`.

`/etc/nixos/configuration.nix` is a `throw` (runbook-decommission item 1).

### What is still owed

- **A reboot.** `/run/booted-system` is still the 7 Sep generation. Now safe:
  `ac-host-ci` is under systemd and returns on boot, which was the ordering
  constraint. No kernel change is pending; this is hygiene.
- **The deploy path** (ADR 0006, delta rows 2 and 21). Until it is on,
  closure changes still need an operator. The applying half is on the box and
  inert; the staging half needs a `/var/lib/homelab` bind mount in `ac-host`'s
  compose file.

---

## 2. Classification

"Conforming" means: declared in the tenant contract, present on the box, and
matching the declaration on ports, slice and state path.

### Conforming

| Service | Tenant | Basis |
| --- | --- | --- |
| `ac-host-static.service` + 3 `ac-static-*` containers + sidecars | assetto | Lobbies on 9600–9602 / 8081–8083 / 8181–8183 / 11200–11202; sidecar sockets 18080, 11300–11302 — every one declared. Containers in `critical.slice` via `cgroup_parent`; the unit unsliced by design. State at `/var/lib/ac-host`. |
| `ac-host-nightly.timer`, `ac-host-dev.service` | assetto | Declared; dev inactive by design. |
| `arcade-freeciv`, `arcade-mindustry` | arcade | `interactive.slice`. 5556/tcp, 4555/udp, 6567, **20151/udp** all declared and open — LAN discovery now works. |
| `samba-smbd`, `samba-winbindd`, `rsync` | arcade | **Now in `interactive.slice`** — were `system.slice` until gen 31. |
| observability, 8 units | observability | All in `interactive.slice`; nine declared ports, nine live binds. UniFi address read from `homelab.host`, not hardcoded. |
| **`agent-hub-llm.service`** | agent-hub | **Running since gen 31**, alone in `background.slice` (weight 700, 163 GiB ceiling, cores 3–25 + siblings). `llama-server` on `192.168.1.50:8100`; the firewall rule now has a listener behind it. |
| **`ac-host-ci.service`** | ci | **Adopted under systemd at gen 31.** `units = [ "ac-host-ci.service" ]`; agent and MinIO in `batch.slice`, attached to the same `ac-host-ci_*` volumes as before. |

### Nonconforming

| Item | Tenant | Gap |
| --- | --- | --- |
| `ac-host-bot-1` | assetto | The Discord bot, still a compose profile inside assetto, in no tenant's `units`. README's "splits out after phase 6" deferral has expired. Delta row 8. |
| `agent-hub` metrics | agent-hub | `/metrics` served on the LAN address, unscraped — `metricsEndpoint` has no address field. Delta row 12. |

### Decommission

| Item | Why |
| --- | --- |
| ~~`/etc/nixos/configuration.nix`~~ | **Done** — a `throw` since 12 Sep. Hardware file kept; proven AST-identical to git. |
| ~~`wpa_supplicant.service`~~ | **Done** — `mkForce false` in `network.nix`, gone at gen 31. |
| `inquire-platform` (registry row) | Still in `hub/repos.psv` with no remote and nothing on the box. Your call. |

---

## 3. The box at rest

Live from `systemctl show`, 12 Sep 2026, generation 31. These are the
**rebalanced** shares from `45f67ab`/`0de8c09`.

| Slice | CPUWeight | MemoryMax | AllowedCPUs | Members |
| --- | --- | --- | --- | --- |
| `critical.slice` | 100 | 25.1 GiB | unfenced | 7 docker scopes (3 lobbies, 3 sidecars, the bot) |
| `interactive.slice` | 50 | 12.5 GiB | unfenced | arcade ×2, samba ×2, rsync, observability ×8 |
| `background.slice` | **700** | **163.1 GiB** | **`3-25,31-53`** | `agent-hub-llm` |
| `batch.slice` | 50 | 25.1 GiB | **`26-27,54-55`** | buildkite agent, minio |
| `system.slice` | 100 | none | — | `ac-host-static`, platform only (sshd, fail2ban, docker, NetworkManager) |

The fence now fences: background and batch hold distinct physical cores, and
neither touches cores 0–2 or their siblings 28–30, which stay with the unsliced
racing stack. Background's weight 700 against `system.slice`'s 100 ranks the
model server above racing under contention — deliberate, per
`configuration.nix`; the fence is what protects racing, not the weight.

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
| 1 | Neutralise the stale `/etc/nixos/configuration.nix` on the box | **Done 12 Sep** — a `throw`, hardware file kept. |
| 2 | Teach `hub-status.sh` to report closure drift (F3) | **Done** — `1c6827f`. Three-tier cascade; `HUB_STATUS_EXACT=1` is the exact check. Also reports the owed reboot. |
| 3 | Correct the stale `hardware-configuration.nix` documentation (F1) | **Done** — `37e6927`. Nine sites, not three; the silent `.example` fallback is now a `throw`. |
| 4 | Register `udp 11300–11302`; adjudicate `udp 20151` | **Done.** Both registered; 20151 turned out to be a live LAN-discovery outage, fixed in `home-arcade`. |
| 5 | Run the CI adoption sequence, then switch | **Done 12 Sep** — generations 30 (`3fef4fe`) and 31 (HEAD). One defect found and fixed in the doing (`c97cbbe`, git on `ac-host-ci`'s PATH). |
| 6 | Add samba/winbindd/rsync to arcade's `units` | **Done, and live** since gen 31 — all three in `interactive.slice`. Uncovered and fixed F8. |
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
