---
name: homelab-supervise
description: Run a homelab work session as the supervisor - pick beads, dispatch workers into worktrees, merge and land what comes back.
disable-model-invocation: true
---

# Supervising a homelab session

You are the **supervisor**: the one session that owns the tracker, the
merges and the pushes. Workers own branches. The loop below is the session;
each step's completion is checkable, and the session is not done until the
last one is.

## 1. Baseline

`bash scripts/hub-status.sh`. Reconcile before adding: unlanded work from a
previous session — an unpushed commit, a dirty tree, a worktree branch main
does not contain — is the first bead of this one, whatever `bd ready` says.

## 2. Pick

`bd ready`, then `bd show <id>` for the candidates. Pick by priority, then by
what unblocks the most. State the pick and what done looks like in one line
before dispatching — that line becomes the worker's brief.

If the bead is bigger than one tree or one concern, decompose here: one
child bead per worker (`bd create --parent=<id>`), each landable alone.

## 3. Dispatch

One worktree, then one worker, per bead. Which worker is a routing
decision — the [`homelab-route`](../homelab-route/SKILL.md) skill: a bounded,
gate-verifiable task whose prompt fits in ~6k tokens goes to
`homelab-local-worker` (agent-hub's model on ac-box: free, private, slow);
everything else goes to `homelab-worker`. Route local in the background and
keep working; a local task is minutes, not seconds.

The worktree is what lets workers run in parallel — each has its own
index, so no worker's commit can
sweep up another's half-finished edit, and nothing touches the registry
checkout until you merge.

```bash
bash scripts/hub-worktree.sh add <tree> <bead-id>     # prints the path; branch wt/<bead-id>
```

Dispatch in the background with this brief. Everything a worker needs that
is not in `AGENTS.md` goes in it; a worker starts cold.

```
Bead: <id> — <title>
Tree: <homelab | ac-host | agent-hub | home-arcade>
Worktree: <path from hub-worktree.sh>   Branch: wt/<id>
Done when: <the one line from step 2>
Context: <the bd show description, verbatim; the docs row or ADR it touches;
          any decision already made that the worker would otherwise re-open>
Return the handoff block from your agent definition.
```

Workers that only need a fact, not a change, are `homelab-inspector`
dispatches: cheaper, and they need no worktree.

## 4. Collect

Read each handoff. The gate line is the worker's claim; re-run it yourself
against the worktree — `bash scripts/hub-gates.sh <tree> <worktree>` — and
read the diff: `git -C <registry path> diff main..wt/<id>`. A handoff with
`Open:` items is a decision for you or the human, not a reason to dispatch
the same worker again with the same brief.

For a change that touches a tenant, a unit, a port or a delivery path,
dispatch `homelab-reviewer` on `main..wt/<id>` before merging. Its verdict
is **land** / **land after fixes** / **stop**.

## 5. Land

Merge into the registry checkout, gate it there, then the
[`homelab-land`](../homelab-land/SKILL.md) skill: push per `hub/repos.psv`,
confirm the staging file moved.

```bash
git -C <registry path> merge --ff-only wt/<id>     # or --no-ff when two branches landed together
bash scripts/hub-gates.sh <tree>
bash scripts/hub-worktree.sh rm <tree> <id>        # refuses while dirty; keeps the branch while unmerged
```

If `--ff-only` refuses, another branch landed first: `git -C <worktree>
rebase main`, re-gate the worktree, merge again. A worker's branch is never
force-pushed anywhere, so a rebase costs nothing.

## 6. Record

The only step where `bd` is written:

```bash
bd close <id> --reason="<sha>: <why>"
bd remember "<the non-obvious thing this bead taught>"   # only if there is one
```

Then `bash scripts/hub-status.sh` once more. The session ends on exit 0, or
on a verdict every line of which is named in the handoff to the human.
