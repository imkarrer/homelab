# ADR 0006: The System Closure Deploys By Staging In CI And Applying On The Box

**Status:** Accepted, 9 Sep 2026. Option 3 (stage in CI, apply on the box),
run **fully unattended inside the maintenance window** — the operator's
explicit choice over the staged-plus-human-unblock variant this ADR originally
recommended. The reasoning for that call is recorded under "Decision" below.

## Context

ac-box takes code by two entirely separate routes and only one is wired.

The **tenant tree** (`ac-host`: containers, scripts, content) has a working
path: push → Buildkite runs test and lint → `wait: ~` → `queue-prod` stages the
sha into `/var/lib/ac-host/pending-deploy.json` and syncs the tree → a human
sets `DOWNTIME=1` and the ops pipeline applies it in the 03:00 window.

The **system closure** (`homelab`: every unit, slice, firewall rule and port)
has no path at all. `hub/repos.psv` registers homelab `deploy=none`. Its
pipeline runs `nix flake check` and the module eval harnesses, and stops. The
only edge from a green build to the box is a human remembering to run
`nixos-rebuild switch --flake`.

Measured consequence, 9 Sep 2026: generation 29 was built on 7 Sep 19:41 and
the repo was **15 commits** past it (first miscounted as 26 — a UTC-vs-`-0500` error, corrected against the box's actual store path), two of which flip services on. Nothing
reported this, because nothing compares homelab's HEAD to
`/run/current-system` (see `docs/current-state.md` §1). The drift was silent,
not tolerated.

The goal this ADR serves: **future updates reach the box through git and CI,
not through a human at an SSH prompt.**

### Why the obvious answer is forbidden

The obvious fix is a `nixos-rebuild switch` step in homelab's Buildkite
pipeline. It cannot be done, and the reason is structural rather than a matter
of care.

`ac-host-ci-agent-1` — the Buildkite agent that would run that step — is a
Docker container **on ac-box**, and once `homelab.ci.enable` lands it is a
systemd unit (`ac-host-ci.service`) owned by the very closure being switched.
`modules/ci/default.nix`'s HAZARD 2 states the consequence: a switch that
touches that unit kills the process running the job partway through, which can
leave the job orphaned, the switch half-applied, and no agent alive to pick up
a retry. Restarting the thing that is currently restarting you is not a
recoverable state to discover by accident.

So the applying step must run **outside** the agent, on the box, as something
systemd owns.

## Options

**1. A `nixos-rebuild switch` step in the homelab pipeline.**
Rejected — HAZARD 2 above. Not a risk to be managed; a circularity.

**2. `system.autoUpgrade` pointed at the flake.**
NixOS ships this: `system.autoUpgrade.flake = "github:imkarrer/homelab#ac-box"`
with `dates` and `allowReboot = false`. It runs as `nixos-upgrade.service`, a
systemd unit, so it sidesteps HAZARD 2 cleanly. It is the idiomatic answer and
should be taken seriously.

Rejected for this host on two counts:

- **It is window-blind.** It switches whenever its timer fires. `assetto` is
  `quiet.drainable = false` and its `ExecStop` is `docker rm -f` on live race
  servers; `homelab.host.maintenance.window` is 03:00 for a reason the Discord
  community already understands. `autoUpgrade` has no notion of either, and
  bolting a drain check onto it means reimplementing `quiet.nix` inside a
  nixpkgs module's `preStart`.
- **It stages nothing.** There is no pending record, so `hub-status.sh` still
  cannot say "queued but not applied" for the closure — the exact reporting gap
  that let this drift accrue. `autoUpgrade` converts silent drift into silent
  application, which is an improvement in liveness and no improvement at all in
  observability.

**3. Stage in CI, apply on the box from a systemd unit. — RECOMMENDED**
Mirror the shape `ac-host` already proved, one layer up.

## Decision

Split the closure deploy into a staging half that CI may run and an applying
half that only systemd on the box may run.

**Staging — a Buildkite step, safe by construction.** After the existing
`flake check` and eval gates, behind `wait: ~`, a `queue-closure` step writes
`/var/lib/homelab/pending-closure.json`:

```json
{ "rev": "<BUILDKITE_COMMIT>", "flake": "github:imkarrer/homelab",
  "queued_at": "...", "build": "...", "branch": "..." }
```

It writes a file and bounces nothing, so it is immune to HAZARD 2. It must
never call `nixos-rebuild`.

> **Blocker, found 9 Sep 2026 by checking rather than assuming: the agent
> cannot write this path.** `docker-compose.buildkite.yml` mounts exactly
> `/var/lib/ac-host`, `/var/run/docker.sock`, and the `buildkite-builds` and
> `buildkite-nix` named volumes. `/var/lib/homelab` is not among them, so a
> `queue-closure` step as described would fail on its first write.
>
> The fix is a bind mount in `compose/docker-compose.buildkite.yml`, in the
> `ac-host` repo. **One place, not two** — this was first written as "both the
> compose file and `modules/ci`", but `modules/ci` declares no volumes; it runs
> the compose file, which does. So the mount is a tenant-tree change that
> lands through `ac-host`'s own pipeline, and `modules/ci` picks it up for free
> once adopted. It still depends on the CI adoption sequence (HAZARD 1) to be
> *meaningful*, since the hand-started stack would also need restarting to see
> the new mount.
>
> The tempting shortcut — putting `pending-closure.json` under
> `/var/lib/ac-host`, which is already mounted — is rejected. That directory is
> the racing tenant's state, and the closure's deploy record is a platform
> fact. Borrowing a tenant's state directory for a platform record is precisely
> the coupling this whole repo exists to undo, and it would be load-bearing the
> moment anyone tried to give a second host the same pipeline. Deliberately it does **not** pre-build the closure:
building is what the applying half does, so a build failure surfaces on the box
against the box's own store rather than passing a green CI badge to a machine
that cannot realise it.

**Applying — `homelab-deploy.service`, timed, on the box, unattended.** A
systemd unit,
therefore in `system.slice`, therefore not killed when the switch bounces
`ac-host-ci.service`. On each firing it:

1. Reads `pending-closure.json`; exits 0 if `rev` equals `last-applied.json`.
2. Consults the quiet policy before touching anything. `/etc/homelab/
   tenants.json` already carries every tenant's `drainable`, `busyCheck`,
   `drain` and `resume`, and `boxctl` already reads it. A tenant that is
   `drainable = false` and reports busy defers the run to the next firing
   rather than draining it unasked.
3. Builds and switches:
   `nixos-rebuild switch --flake github:imkarrer/homelab/<rev>#ac-box`.
4. Records the applied rev, so `hub-status.sh` has a pending/applied pair to
   compare exactly as it does for the tenant tree.

Two properties this unit must have, both easy to get wrong:

- `restartIfChanged = false`, so a switch that changes the deploy unit does not
  restart the deploy unit mid-switch. This is the same self-reference HAZARD 2
  describes, one level in.
- The timer fires inside `homelab.host.maintenance.window`, not on a bare
  interval, so the default case is a switch at 03:00 rather than a switch
  whenever a build happened to go green.

**Implementation status, 9 Sep 2026.** The applying half exists:
`modules/deploy/default.nix`, imported into the ac-box module list and inert
(`homelab.deploy.enable` defaults false; the import is proven a no-op by an
unchanged toplevel drvPath). Its safety branches are exercised against
fixtures rather than asserted:

| Case | Behaviour |
| --- | --- |
| nothing staged | exits 0, no switch |
| staged but inventory unreadable | **fails closed**, exit 1 |
| staged rev already applied | exits 0, no switch |
| staged file has no `.rev` | refuses rather than guessing, exit 1 |
| `assetto` busy (real `/etc/homelab/tenants.json`) | **defers**, exit 0, no switch |
| `assetto` drained | passes the quiet gate |

The staging half is **not** implemented, blocked on the bind mount above.

**Reporting.** `hub-status.sh` gains the closure pending/applied comparison
alongside the tenant tree's, so one call still answers the whole three-way
state. Setting `system.configurationRevision` from the flake makes the running
closure self-identifying and turns that comparison from a heuristic into an
exact check.

## Consequences

**The box becomes self-switching, and that was chosen deliberately.** A merge
to `main` will change the running system with nobody present. The alternative —
staging and waiting for a human to unblock — was rejected because it recreates
the exact failure this ADR exists to remove: `queue-prod` already stages and
waits for a human, and the tenant tree is nonetheless reconciled only because
someone remembers. A gate a human must remember to open is a gate that silently
stays shut, and 15 commits of undeployed closure is what that looks like.

Three things must therefore hold, and none is optional:

- **The drain policy must actually be consulted, not assumed.** This is the
  load-bearing one. Unattended plus `assetto.quiet.drainable = false` means the
  deploy unit's `busyCheck` is the only thing standing between a merge and
  `docker rm -f` on three live race servers. It must defer, not drain, and it
  must fail closed if `/etc/homelab/tenants.json` is unreadable.
- **`nix flake check` must remain a real gate.** It builds the full toplevel
  today (`docs/current-state.md` F5), and unattended deployment is what makes
  that cost worth paying rather than a thing to optimise away.
- **The applied/pending pair must be reported**, so an operator sees what
  happened without being asked to remember it. `hub-status.sh` now has the read
  side of this.

**Every tree that reaches the box needs a real gate before this is turned on.**
`home-arcade` currently has none — `hub-gates.sh` skips module-only flakes
silently (`docs/current-state.md` F9). Unattended deployment of an ungated tree
is strictly worse than the manual switching it replaces, because the human step
being removed is the one that would have caught it. F9 is a blocker for this
ADR, not a parallel cleanup.

**Rollback is a generation, not a revert.** `nixos-rebuild switch --rollback`
on the box remains the fast path; git revert plus a wait for the next window is
the slow one. The runbook must say which is which.

**The first application is still a human action.** This ADR describes the
steady state. Adopting it does not change the fact that the *current* 26-commit
backlog includes `homelab.ci.enable`, whose adoption sequence
(`modules/ci/default.nix`, HAZARD 1) requires stopping a hand-started compose
stack from a plain SSH session first. That switch is human-run, in a window, and
this pipeline is what stops the next one from having to be.

**`deploy=none` becomes `deploy=buildkite` in `hub/repos.psv`** — and homelab's
`agent-push=yes` then means an agent pushing a green commit is, indirectly,
scheduling a system switch. That is a meaningful widening of what unattended
push authority means and should be reconsidered at the same time, not after.
