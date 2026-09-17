# ADR 0009: Tenants Become Flox Environments; The Closure Keeps The Host And The Contract

**Status:** Proposed, 17 Sep 2026. Epic `homelab-158` carries the steps in
order; the ADR moves to Accepted when step 1 (agent-hub) has reached the box
through the new edge and been watched surviving a restart.

## Context

Every tenant on ac-box is a NixOS module today: Nix code that installs
packages from the host's pinned `nixpkgs` and writes systemd units, composed
into one closure with the platform and the contract (ADR 0001). The closure
deploys as one transaction (ADR 0006, ADR 0008). That shape has earned its
place — the layering, the eval-time contract and the self-identifying
closure are what turned drift and port collisions into detectable things
(`docs/architecture.md` Part III) — and it has three costs the same document
records:

1. **The Nix tax.** ~4,900 lines of Nix in `modules/` and `hosts/` for one
   machine. A tenant author must write module code to add a package.
2. **One red blocks everything.** One closure means an eval error in
   `agent-hub`'s module holds up an `observability` dashboard
   (`CONTEXT.md`, "Green / red").
3. **One pin for everyone.** `nixpkgs` is owned by the host; tenants
   `follows` it. `agent-hub`'s `llama-cpp` is 26.05's `9190` and the README
   warns about verifying flags against that build. A newer `llama-server`
   is a host change with a flags audit, not a tenant change.

Flox is already in this hub, in the middle of the pipeline: `ac-host` and
`home-arcade` carry `.flox/env/manifest.toml`, CI runs every gate under the
flox Buildkite plugin, and `hub-gates.sh` reproduces that environment
locally. It is not used for the two ends — what a developer runs and what the
box runs are specified separately from what CI tests (the bot's runtime is
declared twice: the manifest for CI, `bot/Dockerfile` + `requirements.txt`
for prod, assembled on the box at 03:00 by `docker compose up --build`).

The operator works at flox, and this box is deliberately a dogfooding ground:
the question is how far flox can replace hand-written Nix here, honestly,
with each place it cannot recorded as product feedback rather than treated
as a reason to stop.

## Decision

**A tenant's contents are a flox environment. The closure keeps the host and
the contract.** Concretely:

- **A tenant is a `manifest.toml`** in its own tree: `[install]` with the
  package versions it needs, `[vars]`, `[services]` or a single command. The
  same manifest is the developer's shell, the CI gate (as now), and what runs
  on the box. A tenant author writes no Nix.
- **The closure keeps a unit stub per tenant**, not a module: the pinned unit
  name (`agent-hub-llm.service`, `arcade-freeciv`, … — "unit and container
  names never change"), its `Slice=` from the tier, `restartIfChanged`,
  hardening, and `ExecStart=flox activate -d <env> -- <command>` (or
  `--start-services`). Roughly fifteen lines where a module was.
- **The contract stays where it is and says what it says.** Ports → firewall,
  tier → slice, quiet policy, state path, secret names are *host facts about
  a tenant*, declared in `hosts/ac-box/tenants.nix` and consumed by L2. The
  manifest has no vocabulary for them and this ADR does not invent one.
- **A flox tenant deploys through FloxHub, independently of the closure.**
  CI `flox push`es a generation on green; the box pulls it and the unit
  restarts under the tenant's quiet policy. A generation is the staged /
  applied / rollback unit for that tenant, the way a closure rev is for the
  host. `bump-lock` stops being the way a tenant change reaches the box; the
  closure is touched only when a host fact changes.
- **`flox containerize` builds every image this hub builds** (bead
  `homelab-ybm`). Only tenants that are deployed *as* containers get images —
  the `assetto` sidecars and bot, whose compose project, container names and
  `cgroup_parent` are pinned and stay. Native tenants are not containerised
  to fit flox; they run from the environment under systemd.
- **L0–L2 stay NixOS**: hardware, NICs, the Docker daemon, sshd, boot, sops,
  slices, the firewall, the busy-gated deploy unit, and the observability
  stack whose scrape config is generated *from* the contract. Flox is built to
  sit on an OS that someone else configures; NixOS is that OS here, and it
  gets thinner.

### Order, by risk

| Step | Tenant | Proves |
| --- | --- | --- |
| 1 | `agent-hub` | manifest as tenant; `flox activate` under a slice; FloxHub push/pull as the deploy edge; generation as the drift stamp. One process, `background`, drainable, and the tenant the host pin hurts most. |
| 2 | `arcade` | `[services]` as the supervisor of two long-running processes under one unit. |
| 3 | `ci` | `buildkite-agent` + `minio` natively from a manifest instead of two containers. The agent runs the flox plugin from a flox environment, and `ci`'s own deploy becomes a pull rather than a closure switch, which narrows HAZARD 2. |
| 4 | `assetto` / `bot` | images via containerize (`homelab-ybm`); compose stays the runtime. |
| 5 | `observability` | last, and possibly never. The value there is config generated from the contract; attempting it answers whether flox wants a config-generation story. |

## Options considered

**A. Flox as the host's deploy mechanism.** Rejected: there is no layer of
flox that owns hardware, units, slices, the firewall or secrets, so "flox
instead of the closure" is really "closure plus flox", and the four things
the closure is load-bearing for — one self-identifying artifact, rejection at
eval, an atomic switch with rollback, the busy gate — have no flox
counterpart today. That is the boundary this ADR draws, not a verdict on the
product.

**B. QEMU / VMs per tenant.** Rejected: on one Z840 with a latency-critical
tenant and a 163 GiB model server, VMs replace *shares* (ADR 0002) with
static partitions, the tenants that would justify isolation are already
containers, and every downstream tool (backup, metrics, forwarded UDP) forks.
HAZARD 2 is already solved by `modules/deploy`; a single microvm for the CI
agent is the surgical fix if it ever bites again, not a re-architecture.

**C. Fold the tenant repos into homelab (monorepo).** Considered as the way
to remove `bump-lock` and the per-tree webhook and pipeline objects. Not
taken, because the flox deploy edge removes those for every flox tenant
without collapsing the repos: a tenant pushes its own generation.

**D. Flox environments composed into the closure via Nix.** Rejected: it
keeps every cost this ADR is trying to remove (one pin, one red, Nix in the
tenant) and gains only the manifest syntax.

## Consequences

**The whole-box transaction narrows.** A closure switch still changes the
host and the contract atomically; a tenant's contents now change on their
own schedule. That is the point — one tenant's red no longer blocks another's
green — and it means a port or slice change and the tenant change that needs
it can land in either order. The contract's assertions still run at eval;
what they can no longer see is the tenant's package set, which is the
manifest lock's job.

**`hub-status` gains a second kind of pending/applied pair**: the FloxHub
generation pushed by CI against the generation the box is running, per flox
tenant, beside the closure's rev pair. Reading the running generation off the
box is an open question below.

**`docs/architecture.md` Part II changes**, once accepted: L3 is no longer
"flake inputs — declare, never reach" but "environments, with a stub in the
closure"; row 24 (`bump-lock`) applies only to trees that are still inputs.

**Flox's own version becomes a host fact.** `hub-gates.sh` already pins
`v1.14.0` because a lock written by a newer flox was unreadable in CI. With
flox on the box, in CI and in dev, the pin lives in one place — the `flox`
input in `flake.nix`, which `modules/platform/flox.nix` installs and
`hub-gates.sh` reads from the lock — and the three must agree.

**The gate per flox tenant is the tenant's, not the closure's.** `nix flake
check` proved the whole box built. For a flox tenant the gate is the CI
steps under the flox plugin; a green push is a pushed generation. Nothing is
pushed red, as before.

### Open questions — product feedback, to be answered by the steps above

Recorded here so each step's handoff answers one, and the answer is the
dogfooding result.

1. **Deploy-time network dependency.** `flox activate -r` and `flox pull`
   reach FloxHub. If the box pulls at activation, flox.dev is a dependency of
   a 03:00 restart — the class of problem `homelab-ybm` removes for PyPI. Is
   there a "pull on green, activate offline from the pinned generation"
   shape, or does the unit need a soft-failing pull step?
2. **`[services]` under systemd.** Does `flox activate --start-services`
   foreground, forward `SIGTERM`, and exit non-zero when a service dies, so
   `Restart=` and the slice's accounting behave? Or is `flox activate --
   <binary>` the intended production shape, with `[services]` for dev?
3. **Which generation is running.** `configurationRevision` is the closure's
   stamp. What is the machine-readable equivalent for an activated
   environment — "this is generation N of owner/env"?
4. **Secrets.** `[vars]` is plaintext; the box renders secrets to
   `/run/secrets/…` via sops. A `[hook]` that sources them works; is there a
   blessed pattern?
5. **Host facts.** Ports, tier, state dir, "may I be bounced now" — the
   contract this hub declares per tenant. Correctly outside a manifest, or a
   `[deploy]`-shaped gap?
6. **Version coupling.** Who owns flox's version across dev, CI and the box,
   and what happens when a developer's newer flox rewrites a lock?
