# ADR 0011: CI Jobs Run In A Container; The Agent's Delivery Is Not The Job's Sandbox

**Status:** Accepted, 19 Sep 2026. Amends ADR 0009 row 3. Implemented as
`homelab.ci.native.enable = false` on ac-box (the compose unit, declared
exactly as before the 18 Sep cutover), pending a container-per-job shape.

## Context

ADR 0009 made every tenant a Flox environment and, in row 3, moved the
Buildkite agent from its container to a native `ac-host-ci.service`
(`flox activate -d /var/lib/ci/env -- buildkite-agent start`), cut over on
18 Sep 2026 (`homelab-158.6`). The reasoning was delivery: one manifest is
the developer's shell, the CI gate and what runs on the box, and the
container was one more Dockerfile to retire.

The `ci` tenant's container was doing a second job the ADR never named. It
was the **sandbox every CI job ran in**: its own filesystem (with
`/bin/bash`), UTC, a checkout that went with the container, processes that
died with a cancelled job, and a boundary between one job's leftovers and
the next. That role went away with the packaging, silently, and showed up
within hours:

- Every job in every pipeline pinned to `imkarrer/flox#v1.0.0` died in one
  second: the plugin's hooks began `#!/bin/bash`, which NixOS does not have
  (inquire-platform builds 50–53). Fixed forward in the plugin (`a218a63`).
- inquire-platform's memory-transport smoke fails only on the native agent
  (inquire `inq-29g`): the Gateway accepts the submission, the relay logs
  `started {leader:true, listening:false}` and never drains the outbox, and
  the smoke times out at 180 s. The same commit, with CI's exact
  environment, passes on the WSL box on a fresh database, on a reused one,
  and under `TZ=America/Chicago`; the persisted `.env` equals
  `.env.example`; no orphaned processes or held ports on the box. What is
  left is the job's surroundings on the host — the nested activation
  `docs/flox-findings.md` already records as behaving differently under a
  systemd-started outer activation, root under `batch.slice`, a checkout
  that persists across builds.

The operator's rule, 19 Sep: **a CI job is not a deployment to the box, so
it runs in a container.** Delivery and sandbox are orthogonal — a natively
delivered agent can run each job in a container, and a containerised agent
is delivered from the same manifest via `flox containerize` (ADR 0009's own
image path, row 4) — but they were fused in one object, and removing the
object removed both.

## Decision

1. **Jobs run in a container.** Until a container-per-job shape exists
   (Buildkite's `docker` plugin or a `systemd-run` scope wrapped around the
   flox plugin's command hook are the candidates), that means the agent's
   container: `homelab.ci.native.enable = false`, which the module
   guarantees declares the compose unit exactly as before the cutover.
2. **The agent's delivery stays ADR 0009's problem**, not this one's.
   Row 3 is amended, not reverted: the native stubs, the pull unit and the
   ci flox environment stay in the module behind the flag, and the way back
   to native is "jobs get a sandbox first", never the flag alone.
3. **Nothing hand-edited on ac-box.** The flip is a push (ADR 0008); the
   cutover runbook's section 6 is the rollback and names the one optional
   box-side step (copying the native minio's cache pushes back into the
   compose volume with both stopped). Skipping it costs a colder cache
   that refills.

## Consequences

- The `/bin/bash`, timezone, persistent-checkout and orphan-process
  differences disappear together, because the sandbox is back, not because
  each was fixed. `inq-29g` is expected to pass without a code change; if
  it does not, the cause was never the native agent and the bead reopens
  with that fact.
- HAZARD 1 in `modules/ci/default.nix` applies in reverse: the switch that
  carries `false` stops the three stubs and starts `ac-host-ci`, which
  reattaches to the named volumes by name. The queue should be drained
  before the push, as the cutover asked.
- `homelab-158.6`'s native shape is preserved, unexercised, behind the
  flag. The next attempt at it starts from "what sandbox does a job get",
  which this ADR leaves open on purpose.
