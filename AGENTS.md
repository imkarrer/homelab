# Agent instructions — homelab

This repo is the hub for four source trees (`hub/repos.psv`), the platform
layer of its two hosts (`arcade-box`, `llm-box`), and the single `bd` tracker
for work landing in any of them. `README.md`'s **Pinned conventions** are
binding: namespace, tenant names, port scopes, unit-name stability, tier
semantics, state paths, nixpkgs ownership and the public/private boundary are
decided; a module does not re-litigate them.

## Roles

Two roles, and every session is one of them:

- The **supervisor** is the interactive session. It owns `bd`, the merge
  into `main`, `git push`, and the decision to dispatch. Its loop is
  `.agents/skills/homelab-supervise/`.
- A **worker** is a subagent dispatched with one bead in one tree, in its
  own worktree (`scripts/hub-worktree.sh add <tree> <bead>`, branch
  `wt/<bead>`). It edits, commits on that branch, runs the gate against
  the worktree, and returns a handoff. Four definitions in
  `.agents/agents/`: `homelab-worker` (changes), `homelab-local-worker`
  (changes drafted by agent-hub's model on llm-box — the `homelab-route` skill
  says which tasks; `scripts/hub-ask.sh` is the wire), `homelab-inspector`
  (read-only facts), `homelab-reviewer` (a diff against the rules below).

Skills live in `.agents/skills/`. Both directories are harness-agnostic
Markdown; `.claude/` holds only symlinks to them so Claude Code discovers
them, and another harness points at `.agents/` directly.

`bd prime` runs at session start and says *you MUST `bd close` before
done*. That sentence is addressed to the supervisor. A worker's tracker
update is its handoff; one writer keeps the Dolt tracker coherent.

## The gate

```bash
bash scripts/hub-gates.sh <repo>     # homelab ~7s; green is the literal PASS line
```

Nothing is done, reported or committed red. The `homelab-verify` skill has
the rest: the harness check, `NIX_CONFIG` for a bare `nix`, and how to show a
refactor was a no-op (`drvPath` unchanged) rather than merely evaluable.

## Where the rules live

| Question | Answer lives in |
| --- | --- |
| What is decided and not up for discussion | `README.md` → Pinned conventions |
| Why it was decided | `docs/adr/` |
| What runs where — machines, addresses, LAN ports, what crosses between hosts | `docs/topology.md` |
| What each host runs, every service classified | `docs/current-state.md` |
| How code reaches each host, and the delta to the target | `docs/architecture.md` (Part III rows carry bead ids) |
| What to do on a host, step by step | `docs/runbook-*.md` |
| Why CI is shaped the way it is, and what must never bounce | `modules/ci/default.nix` HAZARD 1 and 2 |
| What is actionable now | `bd ready` — the one open-work list |
| What a word means — box, tree, closure, window, bead | `CONTEXT.md`, the glossary; use its term, not a synonym |

## The hosts are read-only

Never hand-edit arcade-box or llm-box. Read-only SSH inspection is always
fine. The migration exception (CONTEXT.md): an agent may apply a pushed
revision with `nixos-rebuild switch --flake
github:imkarrer/homelab/<full-sha>#<host>`, and may run host-side steps a
runbook in `docs/` spells out verbatim. On llm-box that switch is the
closure's only edge, since no CI agent stages there (ADR 0010); it no longer
lapses the way ADR 0006 wrote it would. On arcade-box `homelab-deploy` is the
edge, and a hand switch there is for a broken path unit only, never for
impatience (`homelab-land` §5): it skips the deploy unit's busy check. Two
conditions: the sha must
already be on origin, and the agent must stop — not judge — at a runbook's
abort criteria. On arcade-box,
`ac-host-static.service` or `docker.service` under stop/restart in
`dry-activate` is an abort, full stop.

`modules/deploy` runs no closure gate of its own: it asks `busyCheck`,
builds the staged revision, asks again, and switches (ADR 0008). Nothing
proves a closure activates cleanly before it is switched: CI builds both
hosts' toplevels, and the gate above evaluates them. Prove Nix work in WSL
with that gate before pushing. `switch-to-configuration dry-activate` belongs
to a hand switch: run it first, and read its output against the abort
criteria above.

## Which tenants may be disrupted

The contract can only place a unit in a slice by restarting it (`Slice=`
applies at unit start), so "may this tenant be reconciled?" is really "may its
units bounce?". That is a per-tenant fact, and guessing it wrong is how a
config change becomes an outage:

- **assetto — never, outside a window.** `quiet.drainable = false`, and
  `ac-host-static`'s `ExecStop` is `docker rm -f` on live race servers. Drain
  through `acctl.py` first; the 03:00 window exists for this.
- **arcade — freely.** Standing authority, granted 9 Sep 2026: bouncing
  freeciv, mindustry, smbd, winbindd or rsyncd is acceptable without a window.
  Nothing is mid-race, and the clients are kids' machines that reconnect. This
  is what let `samba-*`/`rsync.service` be pulled into the tenant's `units` at
  all.
- **observability, ci, agent-hub — freely.** All `drainable = true`; a gap in
  a Grafana graph or a re-queued Buildkite job is not an outage. The one
  exception is bouncing `ac-host-ci.service` *from a job running on it* — see
  `modules/ci/default.nix` HAZARD 2, which is a circularity, not a preference.

## A tenant unit outranks an upstream slice

`modules/tenant/resources.nix` emits `Slice=` and `Nice=` at
`lib.mkOverride 90`, deliberately, giving a three-rung ladder:

    upstream nixpkgs module   100
    this contract              90
    a host's own mkForce       50

A plain value here ties with any nixpkgs module that slices itself — nixpkgs'
samba pins `system-samba.slice` — and a tie is an evaluation error, not a
merge. Naming a unit in `homelab.tenants.<name>.units` is therefore an
authoritative claim on where that unit runs. **The cost:** a typo in a `units`
list silently relocates some other module's unit instead of failing loudly.
Keep those lists short, explicit and hand-checked; never derive or glob them.

## Hub

```bash
bash scripts/hub-status.sh        # three-way state: each box vs origin vs WSL trees, ~5s
```

Run it before acting and after landing. It answers what the box runs, what
is on origin, and what is uncommitted here — in one call, so none of it gets
re-derived by hand. Exit 1 prints what is unreconciled; the `homelab-hub`
skill defines each verdict line. A hand-edit on a host is a debugging step,
never a resting state: land it the same session.

Two sessions never share a working tree. Registry checkouts under
`/home/nixos/src/<tree>` are where the supervisor merges and pushes; every
other writer gets a worktree, and `hub-status.sh` reports a worktree branch
main does not contain as unlanded work. `hub-gates.sh <tree> <path>` gates
a worktree; `hub-worktree.sh rm` refuses while dirty and keeps the branch
while unmerged.

Every tree reaches its host through git (ADR 0006); `docs/topology.md`
tabulates the edge for each tree. The one to hold in mind: a green homelab
build stages its sha on arcade-box, and `homelab-deploy` switches to it
within a minute of staging, unless drivers are racing or it is the
03:00–03:30 blackout (ADR 0008); llm-box takes the same sha only by hand
(ADR 0010). A human may apply a staged `ac-host` tree before its
03:00 DOWNTIME build with `scripts/hub-deploy.sh`. `hub/repos.psv` says per
tree whether an agent pushes green work unattended (`yes`) or asks. The
`homelab-land` skill is the procedure.

## Agent skills

The engineering skills (`to-tickets`, `triage`, `to-spec`, `wayfinder`,
`domain-modeling`, …) read their per-repo configuration from `docs/agents/`.

### Issue tracker

`bd` (beads), rooted here, is the single tracker for every tree; GitHub Issues
are not used. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical roles, each label string equal to its name
(`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`,
`wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` at the root is the glossary, `docs/adr/` the
decisions. See `docs/agents/domain.md`.
