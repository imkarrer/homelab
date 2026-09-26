# homelab

The platform layer for two home servers (ADR 0010), and the hub from which the four source
trees are coordinated. This glossary is the vocabulary those trees, the docs
and the agent skills share; a term used here means exactly this.

## The machines

**Box**:
Any one of the physical hosts, always named. There is no "the box":
since ADR 0010 a verdict, runbook or skill says which one.
_Avoid_: the box, the server, the host, prod

**llm-box**:
The HP Z840 (formerly `ac-box`), which runs `agent-hub` and nothing else:
all of its cores and memory, unfenced. The rename is part of the split
(ADR 0010); until it lands, `ac-box` in an older doc means this machine.
_Avoid_: ac-box (after the rename), the Z840

**arcade-box**:
The small always-on host (a Lenovo M920q Tiny) that runs every tenant but
`agent-hub`: `assetto`, `bot`, `arcade`, `observability` and `ci` — what
people notice when it breaks, plus the pipelines. The router's forwards
and the stations' SMB mount point here.

**ci-box**:
A deferred host (ADR 0010) that would take `ci` off arcade-box if its
queue or its switch windows start to hurt. Not built; named so the trigger
has a name.

**Peer** (or **peer host**):
Another homelab host as one host's configuration sees it:
`homelab.host.peers.<name>` names it, carries its address (read from that
host's own `host.nix`, never retyped) and lists what this host's Prometheus
scrapes from it. arcade-box's peer is `ac-box` (llm-box once renamed); the
host being scraped declares none.

**Platform layer**:
Everything on a box that is not a workload — hardware, identity, the
Docker daemon, Nix, boot — owned by this repository (`homelab`).
_Avoid_: base system, OS config

**Tenant**:
One workload, declared against the contract by name and assigned to one box
by that box's host facts. There are exactly six: `assetto`, `bot`, `arcade`,
`agent-hub`, `observability`, `ci`.
_Avoid_: service, app, project, workload

**Contract**:
The schema every tenant declares itself against — its units, ports, tier,
state path and secrets — and the only thing the platform layer knows about a
tenant. One instance per box.
_Avoid_: tenant module, interface

**Tier**:
A named share of a box's capacity (`critical`, `interactive`, `background`,
`batch`) that a tenant is placed in. A share, never an absolute amount.
_Avoid_: priority, class, cgroup

**Slice**:
The systemd resource group a tier maps to. A tenant's units live in its
tier's slice.

## The trees and the hub

**Hub**:
This repository in its coordinating role: it holds the registry, the tooling
and the tracker for work landing in any tree.

**Tree** (or **source tree**):
One of the four git repositories the hub coordinates: `homelab`, `ac-host`,
`agent-hub`, `home-arcade`. Each has a checkout in WSL and a remote on GitHub.
_Avoid_: repo (ambiguous with the hub), project, codebase

**Registry**:
The hub's list of trees and, per tree, how it reaches the box and whether an
agent may push it unattended.

**Registry checkout**:
The one working copy of a tree where merges and pushes happen. Every other
writer works in a worktree.

**Worktree**:
A separate working copy of a tree, on its own branch, given to one worker for
one bead. Nothing in it reaches the registry checkout until the supervisor
merges it.

## How a change reaches the box

**Closure** (or **system closure**):
The complete built operating system for the box — every package, unit and
config — produced from a specific `homelab` commit. Changing the box's
platform means switching it to a new closure.
_Avoid_: build, image, generation (a generation is a closure's slot in the
box's history, not the closure itself)

**Tenant tree**:
The racing tenant's scripts, compose files and content as they sit on the box,
synced from `ac-host`. It is deployed separately from the closure and on its
own schedule.
_Avoid_: the ac-host deploy, the rsync

**Gate**:
The set of checks a tree must pass before a change is called done, committed
or pushed. Green is the literal `PASS` line; nothing is reported red.
_Avoid_: tests, CI (the gate runs locally too)

**Green** / **red**:
A gate that passed / a gate that failed. A red gate blocks every deploy in
that tree, not only the change that broke it.

**Landing**:
Carrying a change into the box through git: gate, commit, push, and confirm
the pipeline staged it. The opposite of a hand-edit on the box.
_Avoid_: shipping, releasing, deploying (deploy is one step of landing)

**Staged** (or **queued**):
A specific commit that CI has proven green and recorded on the box as the
next thing to apply. Staged is not applied; the box is still running the old
one.
_Avoid_: pending (the file names say pending; the state is staged)

**Applied**:
A staged tenant tree that the box has taken. The tenant tree is applied by
the DOWNTIME build.

**Switched**:
A closure the box has activated as its running system. Switched is not
booted: the kernel and initrd are still those of the closure booted into.

**Booted**:
The closure the box last started from. Equal to switched only after a reboot.

**Window** (or **maintenance window**):
The nightly period, 03:00–04:00 box-local, in which disruptive changes are
allowed to touch the racing tenant: the tenant tree is applied, the lobbies
recycled, the closure switched.
_Avoid_: downtime (that is the build), maintenance, the nightly

**DOWNTIME build**:
The CI build, requested by the bot at the start of the window, that applies
the staged tenant tree and recycles the lobbies. If it does not run, the
tenant tree stays staged however green it is.
_Avoid_: the ops pipeline, the nightly build, the deploy job

**Deploy timer**:
The box's own scheduled step that switches to a staged closure at 03:30,
deferring to the next window if anyone is racing.

**Busy check**:
The question "is anyone racing right now?", asked before anything disruptive.
It fails closed: an unclear answer counts as busy.

**Drain**:
Emptying a tenant of live users before its units are bounced. Only tenants
that declare themselves drainable may be bounced outside a window.

**Bounce**:
Stopping and restarting a unit or container. Whether a tenant may be bounced
is a per-tenant fact, not a judgement.
_Avoid_: restart, cycle

**Bump-lock**:
The act of moving one tree's pin in `homelab` so that a change in a tree the
closure still takes as an input reaches the box. A push to such a tree
reaches nothing until its pin is bumped. Since 18 Sep 2026 that tree is
`ac-host` alone; `agent-hub` and `home-arcade` are not inputs. An environment
is not bumped; it has generations (or a staged sha).

**Environment**:
A tenant's contents — the packages and processes it runs — declared in the
tenant's own tree as a flox environment, and the same whether a developer,
CI or the box runs it. The contract still says where on the box it lives;
the environment says what it is.
_Avoid_: the manifest (that is the file), the flox env

**Generation**:
One published version of an environment. For a tenant that is an
environment, a generation is what CI stages, what the box applies, and what
a rollback returns to — the tenant's analogue of a closure rev.
_Avoid_: version, release

**Unit stub**:
What the closure keeps of a tenant that has become an environment: the
pinned unit name, its slice, its restart rules, and the instruction to run
the environment. It says nothing about what the environment contains.
_Avoid_: the module, the wrapper

**Migration exception**:
The one sanctioned way to change the box by hand: an agent applies a commit
that is already on origin, by its full sha, and stops at a runbook's abort
criteria. Everything else on the box is read-only.

## Racing

**Lobby** (or **practice lobby**):
One Assetto Corsa game server, on one track, that players join. Three run
continuously.
_Avoid_: race server, static, instance

**Recycle**:
Tearing down and recreating the lobbies so they pick up new content and
configuration. Anyone in a lobby is dropped, which is why it happens in the
window.
_Avoid_: restart, redeploy

**Sidecar**:
A helper container that serves a lobby from outside it — details, auth, the
plugin. Sidecars are not lobbies and may be rebuilt without dropping a driver.

**Whitelist**:
The list of players allowed into the lobbies. The one file on the box that is
never in git.

## Work

**Bead**:
One tracked item of work, in the hub's single tracker (`bd`). Every change in
any tree is a bead before it is a commit.
_Avoid_: issue, ticket, task (a bead may be any of these)

**Supervisor**:
The one interactive session that owns the tracker, the merges into `main`,
the pushes, and the decision to dispatch.

**Worker**:
A subagent given one bead in one tree in one worktree. It edits, gates and
commits on its branch; it never merges, pushes or writes the tracker.

**Handoff**:
A worker's report back to the supervisor: branch, gate result, what was
proven, and what is open. The tracker is written from the handoff, never by
the worker.

**Verdict**:
One line of the hub's status report naming one way the box, origin and the
WSL trees disagree. Each verdict is a distinct failure, not a degree of one.

**Delta row**:
One numbered gap between the box as it is and the box as designed, in
`docs/architecture.md` Part III, carrying the bead that closes it.
_Avoid_: todo, gap (in prose), item

**ADR**:
A recorded decision that is hard to reverse, surprising without context, and
the result of a real trade-off. Pinned conventions are decided; ADRs say why.
