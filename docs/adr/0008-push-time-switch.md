# ADR 0008: Switch At Push Time When The Blast Radius Excludes Racing

**Status:** Proposed, 13 Sep 2026. Not decided. Nothing is built for it and
nothing should be until the operator answers the one question in "Decision".

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

Not taken. Options 2 and 3 are independent and either can be adopted alone.
The question that decides option 2 is not about racing at all:

> Is it acceptable for `arcade`'s file share and game servers, and the
> observability stack, to restart at any hour on a change to them — or should
> those keep the window while only the *unsliced* remainder switches at push
> time?

If the answer is "keep the window for them", option 2 needs the
`windowOnly` policy word before it needs anything else, and the allowlist is
then derived from the inventory rather than written by hand — the same shape
`busyCheck` already has. If the answer is "any hour is fine", option 2 is
mostly `dry-activate` parsing and a second timer.

Option 3 is decided by whether a bot fix landing at push time is worth the
tree being live-read by a race in progress. Today the answer is probably no:
the bot's one time-critical job is at 03:00, and a fix that misses one night
misses one countdown.

## Consequences (if adopted)

- **Two switch times, two reports.** `hub-status.sh` must say *which* firing
  applied a rev and why the other did not, or "staged" becomes ambiguous
  again — the reporting gap ADR 0006 exists to close.
- **`dry-activate` output becomes a contract.** Its "would restart" list is
  free text from `switch-to-configuration`; a parser that misses a unit name
  because the format shifted would switch when it should have deferred. The
  parse must fail closed: an unparseable plan is a deferral, never a switch.
- **The build moves into the day.** ADR 0006 keeps the build on the box (a
  failure surfaces against the box's own store). At push time that is a
  `nix build` in `system.slice` at weight 100 against `background.slice` at
  700, while racing is unfenced in the same slice. It needs `Nice=` and
  probably its own scope under `batch.slice` before it is run at 19:00.
- **`agent-push=ask` gets sharper, not looser.** Under option 2 an agent
  pushing green to homelab is scheduling a switch in minutes, not at 03:30.
  The flag should stay `ask` at least until the push-time path has been
  watched deferring correctly on a change that touches `arcade`.
