# Runbook: the ci tenant from its flox environment (cutover)

ADR 0009 step 3, bead `homelab-158.6`. Replaces the two containers of
`ac-host-ci.service` (ac-host's `compose/docker-compose.buildkite.yml`:
agent + MinIO, plus the one-shot `minio-init`) with three unit stubs run
from homelab's own `.flox/` at `/var/lib/ci/env`. The module is
`modules/ci/default.nix` (its NATIVE header is the design; read it first);
the flag is `homelab.ci.native.enable` in `hosts/ac-box/configuration.nix`.

Every step below marked **human** is done from a plain ssh session on
ac-box, as root, with the agent idle. None is a pipeline step: the thing
being replaced is the process that runs pipeline steps (HAZARD 2).

## Why one push and not the two-switch order

Every other flox tenant lands in two switches (pull unit first, stub on
later -- `environment-pull.nix`'s header). ci cannot: the stub and the
compose unit share the pinned name `ac-host-ci.service`, so no closure
holds both, and a closure with the compose unit gone and the stub off is a
box with no agent to build the push that turns the stub on. So the flip is
**one push** carrying `native.enable = true` (the module sets
`environment.enable` with it). The switch that applies it:

- removes the compose unit, which `switch-to-configuration` STOPS --
  `docker compose down`: both containers gone, the three named volumes
  kept (no `-v`);
- declares and starts the three stubs, each with
  `ConditionPathExists=/var/lib/ci/env/.flox/env/manifest.lock`, so with no
  checkout yet they are *skipped*, not failed;
- declares `ci-environment-pull.service` (+ its path unit and timer),
  which is what clones, warms and starts them.

The switch is `homelab-deploy`'s, within a minute of the green build
(`schedule = continuous`), after the job that staged it has finished --
or yours, by hand, from ssh. Either is a unit on the box, never a job.
Between the switch and step 5 below CI has no agent; expect ~10 minutes.

## 0. Before the push -- human, ssh, agent idle

```bash
# idle: the agent container has no job child; nothing queued on Buildkite
docker logs ac-host-ci-agent-1 --tail 5          # "waiting for work"
docker ps --format '{{.Names}} {{.Status}}' | grep ac-host-ci
docker volume ls | grep ac-host-ci                # the three volumes exist
ss -tlnp | grep -E ':(9000|9001)\b'               # the container's, today
systemctl status ac-host-ci homelab-deploy.path --no-pager | head -20
```

Abort criteria: a job running; `hub-status.sh` showing anything
unreconciled for homelab; the box's `/run/secrets/rendered/ci-env`
missing (`ls -l`; never `cat`).

### MinIO data: bulk copy while the container still serves

The native minio serves `/var/lib/ci/minio`; the container's data is the
docker volume. Copy it now (2.1 GB on 18 Sep 2026; the second pass after
the stop is the delta), including `.minio.sys/` -- IAM (the `flox-cache`
user, the anonymous-download policy) lives there and the newer server
(`RELEASE.2025-10-15` in the lock, vs the container's `2025-09-07`) reads
the older format.

```bash
mkdir -p /var/lib/ci/minio
rsync -a --info=progress2 /var/lib/docker/volumes/ac-host-ci_minio-data/_data/ /var/lib/ci/minio/
du -sh /var/lib/ci/minio
```

## 1. The push -- supervisor, WSL

In `hosts/ac-box/configuration.nix`: `homelab.ci.native.enable = true;`.
Gate (`hub-gates.sh homelab`), commit ("ci: cut the tenant over to its
flox environment -- runbook step 1"), push via `homelab-land`. The push's
homelab build runs on the **compose** agent (still up), goes green,
stages the rev. Watch:

```bash
bash scripts/hub-status.sh                        # staged rev == the flip commit
ssh ac-box journalctl -u homelab-deploy -f        # "building", "switching", "applied"
```

## 2. The switch -- happens on its own; watch from ssh

```bash
docker ps | grep ac-host-ci || echo "containers gone (expected)"
docker volume ls | grep ac-host-ci                # still three
systemctl status ac-host-ci ac-host-ci-minio ac-host-ci-minio-init --no-pager
# each: "inactive (dead)" with "Condition check resulted in ... being skipped"
systemctl list-units 'ci-environment-pull*'       # service, path, timer present
getent hosts minio                                # 127.0.0.1 minio
```

Abort: the switch failed (`journalctl -u homelab-deploy`), or a stub is
`failed` rather than skipped. Rollback is section 6.

### MinIO data: the delta -- human

The container is down, nothing writes the volume any more:

```bash
rsync -a --delete /var/lib/docker/volumes/ac-host-ci_minio-data/_data/ /var/lib/ci/minio/
```

## 3. Stage and pull the environment -- human

The pull reads a staged record. Nothing writes one for ci yet (the
module's header says why); write the flip commit's record by hand -- the
same JSON `scripts/hub-queue-environment.sh` writes -- and start the pull:

```bash
sha=<the flip commit, full 40 hex>
printf '{"tenant":"ci","sha":"%s","tree":"git@github.com:imkarrer/homelab","queued_at":"%s","build":"","branch":"main","source":"runbook"}\n' \
  "$sha" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > /var/lib/homelab/pending-environment-ci.json.tmp
mv /var/lib/homelab/pending-environment-ci.json.tmp /var/lib/homelab/pending-environment-ci.json
# the path unit fires on the rename; or start it yourself and watch:
systemctl start ci-environment-pull.service
journalctl -u ci-environment-pull -n 40 --no-pager
```

Expected lines: `cloning https://github.com/imkarrer/homelab into
/var/lib/ci/env as root`, `substituting the store paths the lock(s) name`,
`activating /var/lib/ci/env once, online`, `restarting ac-host-ci-minio
-init.service ...`, `restarting ac-host-ci.service ...`, `applied <sha>`.
The one online step (github.com, cache.flox.dev, MinIO is down at that
moment -- expect one substituter warning) fails soft: the record stays,
the timer retries every 10 min, `journalctl` names the cause.

## 4. Proof -- human

```bash
systemctl status ac-host-ci-minio ac-host-ci-minio-init ac-host-ci --no-pager
journalctl -u ac-host-ci-minio-init -n 10 --no-pager   # "minio cache bucket flox-binary-cache ready"
journalctl -u ac-host-ci -n 20 --no-pager              # registered, "Waiting for work"
ss -tlnp | grep -E ':(9000|9001)\b'                    # minio, 127.0.0.1 only
curl -fsI http://127.0.0.1:9000/flox-binary-cache/nix-cache-info   # anonymous read works
systemctl show ac-host-ci -p ControlGroup -p MemoryMax # /batch.slice/ac-host-ci.service
```

Buildkite: the agent `ac-box` in the Default cluster with `queue=self`
(`scripts/hub-cluster-token.sh` / the dashboard); the old registration
disappears after its heartbeat lapses. Then the acceptance criteria, one
job each, none of which touches these units:

1. **homelab, an empty commit to main.** `nix flake check` green;
   `queue-closure` writes `/var/lib/homelab/pending-closure.json` (the
   agent is root: no mount, no ACL); the deploy applies it (a no-op
   switch). Inside the job, `journalctl -u ac-host-ci` shows the plugin's
   hook printing `Using pre-installed flox (1.16.0...)` -- the box's.
2. **ac-host, a push to main.** The containerize step reaches the daemon
   (`docker images ac-host-env`), the compose steps read
   `/var/lib/ac-host/.env` (root), `queue-prod` writes `pending-src`.
   `S3_CACHE_ENDPOINT=http://minio:9000` in its pipeline resolves to
   loopback: the post-command push logs `pushing ... to
   s3://flox-binary-cache`, and `ls /var/lib/ci/minio/flox-binary-cache |
   wc -l` grows.
3. **The sandbox.** In any job's log a build line shows the derivation
   building, not `this system does not support the kernel namespaces` --
   `sandbox-fallback = false` (the box's nix.conf and the job's
   `NIX_USER_CONF_FILES`) makes a sandbox that cannot engage a failure,
   never a silent unsandboxed build. `ls /homeless-shelter` on the box
   must stay `No such file`. To see the fence: while a build runs,
   `systemd-cgls /batch.slice` shows the `nixbld` builders under
   `ac-host-ci.service`.
4. **agent-hub or home-arcade, a push.** Their `trigger: homelab` build
   stages the tenant's environment (`hub-status` shows the pair), which
   is the queue-environment step writing `/var/lib/homelab` from the new
   agent.

## 5. Retire what the compose stack owned -- human, after a green week

```bash
docker volume rm ac-host-ci_buildkite-nix ac-host-ci_buildkite-builds   # 27 GB, 182 MB
docker volume rm ac-host-ci_minio-data                                   # only after step 4.2 pushed to the native bucket
docker rmi ac-host-buildkite-agent:flox
```

Then in ac-host (a second tree, its own bead): delete
`compose/docker-compose.buildkite.yml`, `compose/minio-init.sh`,
`compose/env.buildkite.example`, and drop `S3_CACHE_ENDPOINT:
http://minio:9000` from its three pipeline files (agent-hub's and
home-arcade's too); then `networking.hosts`'s `minio` line in modules/ci
can go. Until then the compose file is what rollback needs -- keep it.

## 6. Rollback -- human

A push with `native.enable = false` cannot build if the native agent is
what is broken. Switch by hand, from ssh, to the generation before the
flip (or the pushed rollback commit once something can build it):

```bash
ls -l /nix/var/nix/profiles/ | tail -3            # the previous generation's number
/nix/var/nix/profiles/system-<N-1>-link/bin/switch-to-configuration switch
# or: nixos-rebuild switch --flake github:imkarrer/homelab/<rollback sha>#ac-box
```

That closure declares the compose unit again: the switch stops the three
stubs (they are removed) and starts `ac-host-ci`, whose `docker compose
up -d --build` reattaches to the three named volumes by name -- warm
store, warm cache, the same image (`docker rmi` above not yet run). If the
native minio received pushes in between, copy them back first:
`rsync -a /var/lib/ci/minio/ /var/lib/docker/volumes/ac-host-ci_minio-data/_data/`
with both minios stopped. `/var/lib/ci` and `/var/lib/homelab/*-environment-ci*`
can stay; nothing reads them with the flag off.

## Not in this runbook, decided elsewhere

- **Staging ci's own environment from CI** (a homelab push reaching
  `/var/lib/ci/env` without step 3 by hand): needs the ci tenant's quiet
  policy to become `drainable = false` with a busyCheck, or the pull's
  restart is HAZARD 2 from a job. modules/ci's header; the handoff.
- **The daemon's slice** (`nix-daemon.service` in `batch.slice`, for
  every non-root client's builds): a platform line in
  `modules/platform/nix.nix`, not this cutover.
