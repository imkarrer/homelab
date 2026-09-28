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
The HP Z840, which since the cutover of 26 Sep 2026 runs `agent-hub` and
nothing else: all 28 physical cores and all 251 GiB, unsliced and unfenced
(`homelab.enforce.slices = false`). At `192.168.1.51`. Its closure has no
deploy edge — an operator switches it by hand from a sha on origin (ADR
0010) — and its environment arrives by its own poll of GitHub. Renamed from
`ac-box` on <rename-date> (`homelab-ygc.9`, `docs/runbook-llm-box-rename.md`).
_Avoid_: ac-box. "The Z840" is the hardware, fine as a name for the machine
across the rename; it is what the docs dated 26 Sep 2026 use.

**ac-box**:
Not a host name any more. The Z840's name — in `hosts/`, the flake, its
hostname, the ssh alias and the tracker — until <rename-date>, when
`homelab-ygc.9` renamed it `llm-box`. It is how history reads: in anything
dated before 26 Sep 2026 it means the one machine that ran all six tenants,
and that doc's "the box" is this machine; from 26 Sep to the rename it means
the model host alone. It survives where history is kept or no host is
meant: restic's `ac-box` snapshots, `secrets/ac-box.yaml` until its own
rename (that runbook, section 5), and the `acbox` model-provider key.
_Avoid_: as a name for either host now.

**arcade-box**:
The small always-on host (a Lenovo M920q Tiny) that since 26 Sep 2026 runs
every tenant but `agent-hub`: `assetto`, `bot`, `arcade`, `observability`
and `ci` — what people notice when it breaks, plus the pipelines. At
`192.168.1.50`, the address the router's forwards, the stations' SMB mount
and Grafana's URL have always named. The only host with a CI agent, and the
only host whose closure reaches it by itself (continuous deploy, ADR 0008).

**ci-box**:
A deferred host (ADR 0010) that would take `ci` off arcade-box if its
queue or its switch windows start to hurt. Not built; named so the trigger
has a name.

**Peer** (or **peer host**):
Another homelab host as one host's configuration sees it:
`homelab.host.peers.<name>` names it, carries its address (read from that
host's own `host.nix`, never retyped) and lists what this host's Prometheus
scrapes from it. arcade-box's peer is `llm-box`; the host being scraped
declares none.

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
The hub's list of trees and, per tree, which box it reaches and how, and
whether an agent may push it unattended.

**Registry checkout**:
The one working copy of a tree where merges and pushes happen. Every other
writer works in a worktree.

**Worktree**:
A separate working copy of a tree, on its own branch, given to one worker for
one bead. Nothing in it reaches the registry checkout until the supervisor
merges it.

## How a change reaches a box

**Closure** (or **system closure**):
The complete built operating system for one box — every package, unit and
config — produced from a specific `homelab` commit. One commit builds one
closure per host (`nixosConfigurations.llm-box`, `.arcade-box`), so "both
hosts on `ab21161`" means each runs its own. Changing a box's platform means
switching it to a new closure.
_Avoid_: build, image, generation (a generation is a closure's slot in the
box's history, not the closure itself)

**Tenant tree**:
The racing tenant's scripts, compose files and content as they sit on
arcade-box, synced from `ac-host`. It is deployed separately from the closure
and on its own schedule.
_Avoid_: the ac-host deploy, the rsync

**Gate**:
The set of checks a tree must pass before a change is called done, committed
or pushed. Green is the literal `PASS` line; nothing is reported red.
_Avoid_: tests, CI (the gate runs locally too)

**Green** / **red**:
A gate that passed / a gate that failed. A red gate blocks every deploy in
that tree, not only the change that broke it.

**Landing**:
Carrying a change into a box through git: gate, commit, push, and confirm
the pipeline staged it. The opposite of a hand-edit on a box.
_Avoid_: shipping, releasing, deploying (deploy is one step of landing)

**Staged** (or **queued**):
A specific commit that CI has proven green and recorded on the host that will
apply it, as the next thing to apply — by CI's own local step on arcade-box,
by the tenant's poll of GitHub on the Z840. Staged is not applied; that host
is still running the old one.
_Avoid_: pending (the file names say pending; the state is staged)

**Applied**:
A staged tenant tree or environment that its box has taken. The tenant tree
is applied by the DOWNTIME build; an environment by `<tenant>-environment-pull`.

**Switched**:
A closure a box has activated as its running system. Switched is not
booted: the kernel and initrd are still those of the closure booted into.

**Booted**:
The closure a box last started from. Equal to switched only after a reboot.

**Window** (or **maintenance window**):
The nightly period, 03:00–04:00 host-local (America/Chicago on both), in
which disruptive changes are allowed to touch the racing tenant on
arcade-box: the tenant tree is applied, the lobbies recycled, the closure
switched if it was deferred. The Z840 has no window: nothing on it races,
and its switches are an operator's, taken with the model server idle.
_Avoid_: downtime (that is the build), maintenance, the nightly

**DOWNTIME build**:
The CI build, requested by the bot at the start of the window, that applies
the staged tenant tree and recycles the lobbies. If it does not run, the
tenant tree stays staged however green it is.
_Avoid_: the ops pipeline, the nightly build, the deploy job

**Deploy timer**:
arcade-box's own step that switches to a staged closure within a minute of
its being staged (continuous, ADR 0008), deferring while anyone is racing and
during the 03:00 blackout. Armed on the Z840 too, where nothing stages, so it
never has anything to do there.

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
closure still takes as an input reaches a box. A push to such a tree
reaches nothing until its pin is bumped. Since 18 Sep 2026 that tree is
`ac-host` alone; `agent-hub` and `home-arcade` are not inputs. An environment
is not bumped; it has generations (or a staged sha).

**Environment**:
A tenant's contents — the packages and processes it runs — declared in the
tenant's own tree as a flox environment, and the same whether a developer,
CI or a box runs it. The contract still says where on its box it lives;
the environment says what it is.
_Avoid_: the manifest (that is the file), the flox env

**Generation**:
One published version of an environment. For a tenant that is an
environment, a generation is what CI stages, what its box applies, and what
a rollback returns to — the tenant's analogue of a closure rev.
_Avoid_: version, release

**Unit stub**:
What the closure keeps of a tenant that has become an environment: the
pinned unit name, its slice, its restart rules, and the instruction to run
the environment. It says nothing about what the environment contains.
_Avoid_: the module, the wrapper

**Migration exception**:
The one sanctioned way to change a box by hand: an agent applies a commit
that is already on origin, by its full sha, and stops at a runbook's abort
criteria. Everything else on either box is read-only. On the Z840 the same
command is not an exception but the closure's only edge (ADR 0010); the
sha-on-origin and abort-criteria rules apply unchanged.

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
The list of players allowed into the lobbies. The one file on arcade-box that
is never in git.

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
One line of the hub's status report naming one way a box, origin and the
WSL trees disagree. Each verdict names its host; each is a distinct failure,
not a degree of one.

**Delta row**:
One numbered gap between the hosts as they are and as designed, in
`docs/architecture.md` Part III, carrying the bead that closes it.
_Avoid_: todo, gap (in prose), item

**ADR**:
A recorded decision that is hard to reverse, surprising without context, and
the result of a real trade-off. Pinned conventions are decided; ADRs say why.
