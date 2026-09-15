---
name: homelab-hub
description: Establish the true three-way state of the home server - what ac-box actually runs, what is on origin, what is uncommitted in the WSL trees. Use before touching ac-host, homelab, agent-hub or home-arcade; when asked what is deployed, live, or up; to find drift; and before landing, pushing, or deploying anything.
---

# homelab hub

`homelab` is the hub for four source trees. It owns the registry
(`hub/repos.psv`) and the tooling; the other trees are coordinated from it,
and `bd` (rooted in homelab) is the single tracker for work landing in any of
them.

## Establish state first

Never infer the three-way state by hand. One call answers it:

```bash
bash /home/nixos/src/homelab/scripts/hub-status.sh
```

Exit 0 means reconciled; exit 1 prints a numbered verdict of what is not. It
takes ~2s. Reading the verdict is the whole survey — re-derive with
`git status`, `ssh ac-box`, or `docker ps` only what the verdict points you at.

## Reading the verdict

Each line names a distinct failure, and they are not interchangeable:

- **uncommitted / untracked** — work exists only on this machine. CI cannot see
  it and it will be lost by any tree operation.
- **unpushed** — committed but origin has never seen it, so **no build ever
  ran on it**. A green CI badge for the branch says nothing about these commits.
- **worktree `wt/<name>` has N commit(s) main does not** — a worker's branch
  (`scripts/hub-worktree.sh`) that was never merged. Unlanded in the same
  sense as unpushed: nothing has gated it on `main`. Merge it or drop it;
  `hub-worktree.sh rm` keeps the branch until main contains it.
- **deploy queued but not applied** — `ac-host`'s `queue-prod` staged a sha
  the box has not taken. It applies only through the ops pipeline
  (`DOWNTIME=1`), which the Discord bot queues at 03:00 unattended
  (`bot/downtime.py`, mark 0); a human may start it early with
  `scripts/hub-deploy.sh`. It is a verdict only when `ac-host-bot-1` is not
  running — otherwise the BOX section prints it as a state with a schedule.
- **DOWNTIME build has not run since \<date\>** — a tree is pending and
  `/var/lib/ac-host/last-downtime.json` (written at the start of every
  DOWNTIME build, box-local date) predates the 03:00 that should have applied
  it. The bot is up, so the trigger is what failed: on 13 Sep 2026 that was
  HTTP 401 from a dead `BUILDKITE_API_TOKEN` in `.env`, visible only in
  `docker logs ac-host-bot-1`.
- **last-downtime.json is unreadable** — a tree is pending and the file is
  missing or has no `date`; whether the build runs at all is unknown, which is
  not the same as fine.
- **last CI job exited non-zero** — `queue-prod` and `queue-closure` both sit
  behind `wait: ~`, so a red test or lint gate blocks **every** deploy in that
  tree. Nothing reaches the box until it is green, however many times you push.
- **box tree differs from its own sha** — someone edited `/var/lib/ac-host/src`
  by hand. Those edits exist nowhere else; an rsync deploy destroys them.
- **system closure N commits behind homelab HEAD** — the platform layer has
  its own path (ADR 0006): a green homelab build stages the sha in
  `/var/lib/homelab/pending-closure.json`, and `homelab-deploy.path`
  switches to it within minutes (ADR 0008), deferring while anyone is racing
  and retrying every 10 minutes; 03:00–03:30 is a blackout for the DOWNTIME
  build. The `deploy` line
  above the verdict says what is queued and what was last applied. *Behind
  and nothing staged* means HEAD's build never reached `queue-closure`:
  unpushed, a red gate, or the CI agent lacking its `/var/lib/homelab` mount.
  Green here means only that no commit is newer than the last switch, which
  is consistent with current, not proof of it — `HUB_STATUS_EXACT=1` proves
  it by comparing store paths, for ~7s instead of ~2s.
- **switched since boot** — the closure was activated but not rebooted into, so
  `systemctl` reflects the new config while the kernel and initrd are still the
  old one. A kernel or boot-parameter change looks applied and is not.

## The standing rules

- Treat ac-box as **read-only**. Inspect with ssh; change it by landing in git
  and letting the pipeline carry it. The migration exception and its two
  conditions are in `AGENTS.md`.
- A hand-edit on the box is a debugging step, never a resting state. Land it in
  git the same session, then deploy — the box is not a place work lives.
- The supervisor writes `bd`; workers report. One owner keeps the tracker
  coherent.
- To carry a change through, use [`homelab-land`](../homelab-land/SKILL.md).
