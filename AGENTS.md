# Agent instructions — homelab

This repo is the hub for four source trees (`hub/repos.psv`), the platform
layer of `ac-box`, and the single `bd` tracker for work landing in any of
them. `README.md`'s **Pinned conventions** are binding: namespace, tenant
names, port scopes, unit-name stability, tier semantics, state paths,
nixpkgs ownership and the public/private boundary are decided; a module does
not re-litigate them.

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
  (changes drafted by agent-hub's model on ac-box — the `homelab-route` skill
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
| What the box runs, every service classified | `docs/current-state.md` |
| How code reaches the box, and the delta to the target | `docs/architecture.md` (Part III rows carry bead ids) |
| What to do at the box, step by step | `docs/runbook-*.md` |
| Why CI is shaped the way it is, and what must never bounce | `modules/ci/default.nix` HAZARD 1 and 2 |
| What is actionable now | `bd ready` — the one open-work list |
| What a word means — box, tree, closure, window, bead | `CONTEXT.md`, the glossary; use its term, not a synonym |

## ac-box is read-only

Never hand-edit ac-box. Read-only SSH inspection is always fine. Migration
exception, until ADR 0006's timer has been watched firing: an agent may apply
a pushed revision with `nixos-rebuild switch --flake
github:imkarrer/homelab/<full-sha>#ac-box`, and may run box-side steps a
runbook in `docs/` spells out verbatim. Two conditions: the sha must already
be on origin, and the agent must stop — not judge — at a runbook's abort
criteria. `ac-host-static.service` or `docker.service` under stop/restart in
`dry-activate` is an abort, full stop.

The closure gates (`diff-closures`, `switch-to-configuration dry-activate`)
run on the box, by `modules/deploy` in the window. Prove Nix work in WSL with
the gate above.

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
bash scripts/hub-status.sh        # three-way state: box vs origin vs WSL trees, ~2s
```

Run it before acting and after landing. It answers what the box runs, what
is on origin, and what is uncommitted here — in one call, so none of it gets
re-derived by hand. Exit 1 prints what is unreconciled; the `homelab-hub`
skill defines each verdict line. A hand-edit on ac-box is a debugging step,
never a resting state: land it the same session.

Two sessions never share a working tree. Registry checkouts under
`/home/nixos/src/<tree>` are where the supervisor merges and pushes; every
other writer gets a worktree, and `hub-status.sh` reports a worktree branch
main does not contain as unlanded work. `hub-gates.sh <tree> <path>` gates
a worktree; `hub-worktree.sh rm` refuses while dirty and keeps the branch
while unmerged.

Every tree reaches the box through git (ADR 0006): a green `homelab` build
stages its sha in `/var/lib/homelab/pending-closure.json` and
`homelab-deploy.timer` switches at 03:30; `ac-host` stages through
`queue-prod` and the bot's DOWNTIME build applies it at 03:00 (a human may
apply early with `scripts/hub-deploy.sh`); module-only trees arrive by
bumping `flake.lock`. `hub/repos.psv` says per tree whether an agent pushes green
work unattended (`yes`) or asks. The `homelab-land` skill is the procedure.

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
