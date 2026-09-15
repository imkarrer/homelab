---
name: homelab-land
description: Carry a change into the home server through git rather than by hand - run CI's real gates locally, commit, push, and confirm the pipeline actually queued it. Use when landing, shipping, pushing or deploying work in ac-host, homelab, agent-hub or home-arcade, and when reconciling a hand-edit made on ac-box back into git.
---

# Landing a change

Git is the only way work reaches ac-box. Land it and let the pipeline carry
it; editing the box directly leaves work that exists nowhere else.

## 1. Establish the baseline

```bash
bash /home/nixos/src/homelab/scripts/hub-status.sh
```

Reconcile what it reports **before** adding to it. Landing onto an unclean
baseline mixes your change with someone else's unlanded work, and you will not
be able to tell them apart afterwards.

If it reports **box tree differs from its own sha**, those hand-edits are the
change to land first — recover them from the box, commit them, and only then
start new work.

## 2. Run the gates CI will run

The [`homelab-verify`](../homelab-verify/SKILL.md) skill: `hub-gates.sh
<repo>`, green is the literal PASS line. A red gate blocks **every** deploy
in that tree, not just yours — the pipeline stayed stalled 13 hours the day
this skill was written.

## 3. Commit what belongs together

Land coupled changes in one push. Two changes are coupled when either alone
leaves the system worse: fixing a red gate re-enables the `pages` step, so a
stale `site/` template must land in the same push or the next green build
publishes it over the live page. A change to a delivery path, tenant, port or
unit and the `docs/` row it invalidates are coupled the same way.

Split by concern, not by file count — one commit per reason, each message
saying **why**, since the diff already says what.

## 4. Push, then verify the pipeline took it

`hub/repos.psv` carries the policy per tree: `agent-push=yes` means push
green work without asking; `ask` means ask first. Holding green work back
only grows the unlanded pile the hub exists to prevent. Pushing to `main` is
what triggers a build; staging runs only on `main`.

```bash
git push origin main
```

Then confirm the staging step moved the file it owns. A green build that did
not move it means the deploy did not queue, and the box keeps running the old
code however green the badge looks.

| Tree | Staged by | Confirm with |
| --- | --- | --- |
| `ac-host` | `queue-prod` | `ssh ac-box 'cat /var/lib/ac-host/pending-deploy.json'` |
| `homelab` | `queue-closure` | `ssh ac-box 'cat /var/lib/homelab/pending-closure.json'` |
| `home-arcade`, `agent-hub` | nothing — module-only | the tenant's green build triggers homelab's `bump-lock` step, which moves `flake.lock` and pushes homelab; then as `homelab` above |

`bash scripts/hub-status.sh` reads both files into its `deploy` line.

## 5. Applying is a separate step

- `ac-host`: the ops pipeline (`DOWNTIME=1`), started by a human, recycles
  the practice lobbies. Ask before triggering it, and check nobody is driving.
- `homelab`: `homelab-deploy.path` on the box switches to the staged sha
  within minutes of CI staging it (ADR 0008), deferring while anyone is
  racing and retrying every 10 minutes until they leave; between 03:00 and
  03:30 it stays out of the tenant tree's DOWNTIME build. So a green push is
  live before you have finished reading the build log. Check:
  `ssh ac-box 'journalctl -u homelab-deploy --since "-1h" --no-pager'`,
  then `HUB_STATUS_EXACT=1 bash scripts/hub-status.sh`. A `deferring` line
  is a race in progress, not a failure. There is no longer a reason to
  switch by hand; the migration exception in `AGENTS.md` is for a box whose
  path unit is broken, not for impatience.
