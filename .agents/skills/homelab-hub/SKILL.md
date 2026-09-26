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
takes ~5s for the two hosts (`HOMELAB_BOX=<host>` asks about one). Reading
the verdict is the whole survey — re-derive with `git status`, `ssh <host>`,
or `docker ps` only what the verdict points you at.

## Reading the verdict

The BOX, tenant-tree and closure sections run once per host declared in
`flake.nix`, and every line from inside them starts with the host's name.
Each line names a distinct failure, and they are not interchangeable:

- **\<host\>: unreachable** — that host did not answer; its sections are
  skipped and its state is unknown, which is not clean. The other host's
  report is still complete.
- **\<host\>: runs \<sha\>, which homelab HEAD does not contain (UNMERGED)** —
  the box was switched from a branch (a hand switch during a build-up, as
  arcade-box was on 26 Sep 2026). Land the branch; a box is not where work
  lives.
- **\<host\>: the ssh alias reached a machine calling itself \<hostname\>** —
  `~/.ssh/config` points the alias at the wrong machine. The cutover swaps
  `192.168.1.50` between the two hosts and nothing else would notice; fix
  the alias before believing any other line for that host.
- **\<host\>: nothing is staged — no CI agent on this host** — a state line,
  not a failure: a host whose inventory has no `ci` tenant has no agent to
  write `pending-closure.json`, so only a hand switch moves its closure
  (arcade-box before the cutover, the Z840 after it, ADR 0010).

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
- **push did not build** — origin's HEAD for that tree has no Buildkite build
  on `main`: the newest build (the CI section names it) is for an older
  commit, or there has never been one. The webhook did not fire, and no
  amount of waiting changes that — on 14 Sep 2026 this looked like a slow
  build for nine hours. `scripts/hub-pipeline.sh <tree>` converges the hook
  and prints GitHub's deliveries; then a new push, or a build started by
  hand. A build that is *running* is not this: the CI section prints it as a
  state (`build N running`), and it is a verdict only once it settles.
- **build N failed for origin HEAD** — `queue-prod`, `queue-closure` and the
  tenants' `trigger: homelab` step all sit behind `wait: ~`, so a red test or
  lint gate blocks **every** deploy and lock bump in that tree. Nothing
  reaches the box until a build passes, however many times you push. The
  `ac-host-ops` line is the DOWNTIME apply itself: failed there means the
  pending tree was not applied and the box still runs the one before.
- **Buildkite refuses the token / no Buildkite pipeline** — the CI section
  could not read a state, which is unknown, not fine. A 401 names the token's
  source (`scripts/lib/buildkite-token.sh`, three sources); a 404 is a
  registry tree with no pipeline object, which `hub-pipeline.sh <tree>`
  creates. No token source at all skips the section in one line and is not a
  verdict.
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
  it by comparing store paths, for ~7s more per host.
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
