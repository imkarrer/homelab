# ADR 0008: Switch At Push Time When The Blast Radius Excludes Racing

**Status:** Accepted, 15 Sep 2026. Option 2, with the question this ADR left
open answered "any hour is fine" — so the parser and the policy word it was
sketched with are not built, and the schedule alone is. Implemented as
`homelab.deploy.schedule = "continuous"`; ac-box sets it.

## Context

ADR 0006 made the box self-switching, and it chose *when*: `homelab-deploy.timer`
fires at `maintenance.window + 30min`, 03:30, and nowhere else. Every closure
change — a firewall rule, a tier share, a Grafana dashboard, a sops secret, a
change to the deploy unit itself — sits staged in `pending-closure.json` until
then. The operator asked, 13 Sep, which parts of the deploy could be automated
*without affecting the Assetto Corsa lobbies*, wanting as much as possible to
land when the commit is pushed.

The answer from reading the box rather than the docs (`docs/architecture.md`
Part III rows 30–32) was that nothing left to automate carries lobby risk,
because the lobbies are already out of the closure's reach by construction:

- `ac-host-static.service` — the unit whose `ExecStop` is `docker rm -f` on
  three live race servers — is `restartIfChanged = false` and `stopIfChanged
  = false` (`ac-host` `modules/ac-host.nix`). A switch cannot bounce it.
  The same holds for `ac-host-bot`, `ac-host-nightly` and `ac-host-dev`.
- The auth, details and plugin sidecars and the bot are compose-owned
  containers. The closure does not create or restart them; only the tenant
  tree's `ci_downtime.py` (`rebuild_sidecars`) does, at 03:00.
- `critical.slice` limits apply live to a cgroup; changing them moves no
  process.
- The one closure change that *can* reach a race is a `docker.service`
  restart, which takes every container with it. `AGENTS.md` already names it
  an abort criterion in `dry-activate` output.

So the window protects racing from nothing the closure can do. What the window
actually protects is **everything else that is `drainable`**: `arcade`'s
`samba-smbd`, `rsync`, `arcade-freeciv`, `arcade-mindustry` — which
`resources.nix` assigns `Slice=` and which therefore restart on a change to
them — and the eight observability units. Those are kid-facing and
dashboard-facing bounces, not racing ones, and the window is the reason they
happen at 03:30 rather than at 19:00 on a school night.

## Options

**1. Keep the window for everything.** Status quo. Simple to reason about,
one bounce time for the whole machine, and the operator can say "nothing on
this box changes outside 03:00–03:35" and be right. Latency from push to
live is up to 27 hours. No lobby cost. Arcade and observability changes wait
alongside changes that had no reason to.

**2. Switch at push time when `dry-activate` says the restart set is boring.**
`queue-closure` stages as now. A second timer (or the same unit on a short
cadence, say every 10 minutes) reads the staged rev, builds it, runs
`switch-to-configuration dry-activate`, and parses the "would restart / would
stop" lists. If the set is a subset of an allowlist — no `docker.service`, no
`assetto`/`bot` unit, no unit belonging to a tenant whose policy says
"window only" — it switches now. Otherwise it leaves the rev staged for the
03:30 firing exactly as today. The quiet-policy check stays in front of both.

  Gains: a firewall rule, tier share, secret, deploy-unit fix or agent-hub
  change is live minutes after green. Costs: a new per-tenant policy word
  (roughly `quiet.windowOnly`, distinct from `drainable`) so `arcade` can say
  "I am drainable, but only at night"; a build on the box at push time, which
  is CPU in `system.slice` while people may be racing — the build must be
  fenced or niced, and `nix build` of a full toplevel is not small; and the
  operator loses the "nothing changes outside the window" sentence.

**3. Split the tenant tree's apply from its recycle.** The analogue one layer
down. `ci_downtime.py` does two things: sync the tree (and rebuild the bot),
then recycle the lobbies (and rebuild the sidecars). The first half is
drainable — the bot reconnects in seconds, and running lobbies rendered their
config at start and do not re-read the tree. The second half is the 03:00
bounce. Running the first half at push time (a `queue-prod` that applies
rather than stages, when `rebuild_sidecars` is false) would make bot, site and
script changes live immediately.

  Gains: bot fixes land when pushed instead of the next night. Costs: the
  `plugin` sidecar bind-mounts `../catalog` read-only from the tree, so a
  catalog change is seen by a live session; `acctl.py` and `drivers_online.py`
  are read from the tree by the units and by `busyCheck`, so a broken script
  is live immediately too. The tree is less inert than it looks, and the
  separation would need to be by path, not by "sidecar or not".


## Decision

**Option 2, adopted 15 Sep 2026**, with the open question answered "any hour is
fine". The operator's words: *full automation that always does a switch and
only waits / batches if there are people racing.*

That answer is what makes this small. Option 2 was sketched as
`dry-activate` parsing plus a `windowOnly` policy word, and both existed for
one purpose: telling blast radii apart, so that a change touching `arcade`
could be held back while an unsliced change went early. Deciding that arcade
and observability may bounce at any hour removes the distinction, and with it
the parser, the new policy word, and the "two switch times, two reports"
problem in this ADR's own Consequences. What is left is the question
`busyCheck` already answers — *is anyone racing?* — asked on a loop instead of
once a night. The deploy script has had that branch since ADR 0006; it simply
never ran outside 03:30.

So the change is a schedule, not a mechanism: `homelab.deploy.schedule =
"continuous"` (`modules/deploy/default.nix`), which replaces the single
calendar firing with

- a **path unit** on `pending-closure.json`, so a revision is applied the
  moment CI stages it rather than at the next tick; and
- a **retry timer** (`retryInterval`, 10 min) for the only two cases a file
  event cannot cover: a revision deferred because someone was racing — nothing
  will rewrite the file when they leave — and a firing missed across a reboot.

**Batching falls out of the existing design rather than being built.** While a
deferral is in force, later pushes overwrite `pending-closure.json` with newer
revisions; the retry reads whatever is there when the lobbies clear. Five
pushes during a race are one switch afterwards, at the newest revision, and
nothing accumulates a queue that has to be drained in order.

Three things the decision does *not* license, each handled rather than
assumed:

1. **The build moved into the day.** This ADR's Consequences called for `Nice=`
   before running a toplevel build at 19:00. The unit now carries `Nice = 19`,
   `IOSchedulingClass = idle` and `CPUWeight = 10`. Deliberately NOT
   `Slice = batch.slice`: batch's `MemoryMax` on ac-box is 12.5 GiB and a
   toplevel build under it would be OOM-killed mid-deploy, which converts a
   resource guard into an outage. Weight and priority slow a build down; a
   ceiling ends it.
2. **"Nobody was racing when this started" is not the question.** The build is
   the long part, and it is exactly when someone joins a lobby. The script now
   builds first (`nix build`, no gcroot), asks the busy question again, and
   only then switches — so the exposure between the last check and the switch
   is a `switch-to-configuration` against a warm store, seconds, instead of a
   whole build.
3. **A drained lobby reads as empty.** At the window's start the bot queues
   `DOWNTIME=1`, and that build *drains the lobbies* before applying the
   tenant tree. To `drivers_online.py` that is indistinguishable from a quiet
   night, so the continuous schedule would happily switch into the middle of
   the tenant deploy — the "two operators in one room" the 30-minute offset
   was invented to prevent, arriving by a door the offset does not cover. The
   window is therefore a **blackout** under this schedule: nothing switches
   between `maintenance.window` and `window + windowOffsetMinutes`, and the
   offset that used to be the only firing time is now the moment the blackout
   lifts.

Option 3 (splitting the tenant tree's apply from its recycle) is still **not
taken**, and this decision does not bear on it. Its costs are unchanged: the
`plugin` sidecar bind-mounts `../catalog` read-only from the tree and
`acctl.py` is read from the tree by live units, so a push-time tree apply is
read by a race in progress. That is a different question about a different
delivery path, and it is still answered "probably no".

## Consequences

- **One switch time, not two.** The draft of this ADR worried that a
  push-time path beside the window would make "staged" ambiguous again —
  the reporting gap ADR 0006 exists to close. Adopting the schedule as a
  *replacement* rather than an addition avoids it: `pending-closure.json` is
  applied by whichever of the path unit or the retry timer gets there first,
  and both run the same script with the same guards. `hub-status.sh` needs no
  new vocabulary; "staged" still means exactly one thing.
- **`dry-activate` never becomes a contract.** The draft's second consequence
  was that parsing `switch-to-configuration`'s free-text "would restart" list
  makes a fragile thing load-bearing. Answering the open question removed the
  parser, so this consequence is retired rather than accepted.
- **The build moved into the day, and yields.** `Nice = 19`,
  `IOSchedulingClass = idle`, `CPUWeight = 10`; not `Slice = batch.slice`,
  because that slice's 12.5 GiB ceiling would OOM-kill a toplevel build
  mid-deploy. The box substitutes most of the closure from MinIO, so the
  common case is a fetch rather than a compile, but the guards are sized for
  the day it is not.
- **The window still means something, and it means the opposite.** It is no
  longer *the* time the closure switches; it is the one time it will not. The
  tenant tree's DOWNTIME build owns 03:00–03:30, and its drain makes the
  lobbies read as empty, so the blackout is what stops a closure switch from
  landing in the middle of it.
- **`agent-push=ask` gets sharper, not looser.** An agent pushing green to
  `homelab` is now switching the box in minutes rather than scheduling
  something for 03:30. `hub/repos.psv` keeps `ask`, and the reason is now
  stronger than when it was written.
- **The lobbies are the only brake.** If `drivers_online.py` breaks, or the
  racing tenant's tree is mid-rsync when it is read, the busy question gets
  the wrong answer — and unlike the window schedule, there is no clock behind
  it as a second line of defence. `busyCheck` failing *closed* matters more
  under this schedule than it did under ADR 0006: the script's inventory check
  already refuses to switch when `/etc/homelab/tenants.json` is unreadable,
  and that refusal is now the thing standing between a green push and three
  live race servers.
- **Latency is now a property of CI, not of the clock.** Push to live is the
  pipeline's own duration plus at most the path unit's reaction — minutes.
  Anything that makes the pipeline slow or silent (a dead trigger, as on
  14 Sep) is now the whole of the delay, which raises the value of
  `hub-status.sh` being able to see build state (bead `homelab-g49`).
