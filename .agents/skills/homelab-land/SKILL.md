---
name: homelab-land
description: Carry a change into the home server through git rather than by hand - run CI's real gates locally, commit, push, and confirm the pipeline actually queued it. Use when landing, shipping, pushing or deploying work in ac-host, homelab, agent-hub or home-arcade, and when reconciling a hand-edit made on arcade-box or llm-box back into git.
---

# Landing a change

Git is the only way work reaches either host. Land it and let the pipeline carry
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
| `ac-host` | `queue-prod` on arcade-box's agent | `ssh arcade-box 'cat /var/lib/ac-host/pending-deploy.json'` |
| `homelab` | `queue-closure` on arcade-box's agent — arcade-box's closure only; nothing stages llm-box's (§5) | `ssh arcade-box 'cat /var/lib/homelab/pending-closure.json'` |
| `home-arcade` | `queue-environment` on arcade-box's agent, a FloxHub generation (ADR 0009) | `ssh arcade-box 'cat /var/lib/homelab/pending-environment-arcade.json'` |
| `agent-hub` | llm-box's own poll of GitHub, every 10 minutes, once the build's status is green (`homelab-ygc.14`) | `ssh llm-box 'cat /var/lib/homelab/pending-environment-agent-hub.json'` |

`bash scripts/hub-status.sh` reads these records into each host's section:
the `deploy` line for the closure, a `<tenant> env` line per environment tenant.

## 5. Applying is a separate step

- `ac-host`: the ops pipeline (`DOWNTIME=1`), started by a human, recycles
  the practice lobbies. Ask before triggering it, and check nobody is driving.
- `homelab`: `homelab-deploy.path` on arcade-box switches to the staged sha
  within minutes of CI staging it (ADR 0008), deferring while anyone is
  racing and retrying every 10 minutes until they leave; between 03:00 and
  03:30 it stays out of the tenant tree's DOWNTIME build. So a green push is
  live on arcade-box before you have finished reading the build log. Check:
  `ssh arcade-box 'journalctl -u homelab-deploy --since "-1h" --no-pager'`,
  then `HUB_STATUS_EXACT=1 bash scripts/hub-status.sh`. A `deferring` line
  is a race in progress, not a failure. There is no reason to switch
  arcade-box by hand; the migration exception in `AGENTS.md` is for a host
  whose path unit is broken, not for impatience. llm-box is the other case:
  nothing stages there, so the same push reaches it only as the hand switch
  `AGENTS.md` describes (`#llm-box` at the pushed sha), and until then
  `hub-status.sh` counts it behind HEAD.
