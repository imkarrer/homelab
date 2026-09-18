# LIVE on ac-box since generation 31, 12 Sep 2026. Imported by flake.nix
# (f461509, proven a no-op while inert) and enabled by
# hosts/ac-box/configuration.nix (4257aea), after a human ran the HAZARD 1
# adoption sequence below from a plain SSH session. It was drafted as a
# post-cutover sketch (beads homelab-bqo.19); it is not a sketch any more.
# The two HAZARD sections are permanent, not migration notes: HAZARD 2 is
# the structural reason the closure's deploy path is a systemd unit
# (modules/deploy, ADR 0006) and not a pipeline step.
#
# --------------------------------------------------------------------------
# WHY THIS EXISTS
# --------------------------------------------------------------------------
# hosts/ac-box/tenants.nix declares the `ci` tenant with `units = []`,
# because today nothing wraps the CI stack in systemd -- a human runs
#
#   cd /var/lib/ac-host/src/compose
#   docker compose -f docker-compose.buildkite.yml --env-file .env.buildkite \
#     up -d --build
#
# by hand. modules/tenant/resources.nix assigns tier -> slice by walking
# each tenant's `units` list, so an empty list means the batch slice
# (CPUWeight 0.05, IOWeight 10, nice 19 -- see resources.nix's tierDefaults)
# has nothing to actually put the Buildkite agent's Nix build under. The
# workload most likely to consume all 56 threads (a `nix build` inside the
# Flox sandbox) is exactly the one the tier system does not yet reach. This
# module is the fix in waiting: give the stack a systemd unit so a future,
# separate change to hosts/ac-box/tenants.nix can add its name to `ci.units`
# and let resources.nix do its job.
#
# --------------------------------------------------------------------------
# WHAT WAS CAPTURED FROM THE REAL BOX (read-only: cat/ls/docker inspect,
# never a write) -- 7 Sep 2026
# --------------------------------------------------------------------------
# compose/docker-compose.buildkite.yml (name: ac-host-ci) defines three
# services: `minio` (MinIO server, loopback-only 9000/9001), `minio-init`
# (a one-shot `mc` container that provisions the cache bucket + a dedicated
# S3 user, depends_on minio, restart: "no"), and `agent` (built from
# imkarrer/flox-buildkite-plugin, depends_on minio-init's completion).
#
# `docker inspect ac-host-ci-agent-1` confirms, live:
#   - Binds: /var/lib/ac-host:/var/lib/ac-host (rw), the host Docker socket
#     (rw, no --privileged), plus two named volumes: buildkite-builds at
#     /buildkite/builds and buildkite-nix at /nix.
#   - NetworkMode ac-host-ci_default (an isolated bridge, not host
#     networking) -- no overlap with assetto's network_mode: host services.
#   - RestartPolicy unless-stopped; User 0:0 (root in the container, needed
#     for the Docker-socket-using recycle jobs acctl.py triggers).
#   - Env carries AC_STATE/AC_CONTENT/AC_SRC/AC_BUILD (mirrors the paths
#     services.ac-host already uses), BUILDKITE_AGENT_TAGS=queue=self,
#     BUILDKITE_AGENT_NAME=ac-box, AWS_EC2_METADATA_DISABLED=true, and the
#     live secrets (BUILDKITE_AGENT_TOKEN, AWS_ACCESS_KEY_ID/SECRET_ACCESS_KEY,
#     S3_CACHE_SIGNING_KEY) that compose/.env.buildkite supplies. None of
#     those values are reproduced here, in a fixture, or anywhere else this
#     module touches -- see CREDENTIALS below.
#
# `docker inspect ac-host-ci-minio-1` confirms: PortBindings publish
# 127.0.0.1:9000->9000 and 127.0.0.1:9001->9001 only (matches
# hosts/ac-box/tenants.nix's ci.ports, both scope = "local"), single named
# volume `minio-data` at /data, MINIO_ROOT_USER/MINIO_ROOT_PASSWORD supplied
# the same way.
#
# --------------------------------------------------------------------------
# HAZARD 1 -- ADOPTION IS A BEHAVIOUR CHANGE, NOT A NO-OP
# --------------------------------------------------------------------------
# Bringing these containers under systemd means something else must NOT
# also be running them: `docker compose up` a second time against the same
# project name reuses the same containers, but if the hand-started stack is
# still up when this unit's ExecStart fires, `docker compose` will try to
# recreate containers that already own 127.0.0.1:9000/9001 and the
# ac-host-ci_default network -- a port/network collision, not a clean
# takeover. A human must, in this exact order, from a plain SSH session
# (see HAZARD 2 -- not as a Buildkite step):
#
#   1. Confirm nothing is mid-build: `docker ps` should show ac-host-ci-agent-1
#      idle (Buildkite agents poll when idle; check the Buildkite dashboard
#      or `docker logs ac-host-ci-agent-1 --tail 20` for "waiting for work").
#   2. Stop the hand-started stack WITHOUT removing volumes:
#        cd /var/lib/ac-host/src/compose
#        docker compose -f docker-compose.buildkite.yml \
#          --env-file .env.buildkite down
#      (no `-v` -- see VOLUMES below; `down -v` would destroy the Nix store
#      and binary-cache data this whole exercise is trying to preserve.)
#   3. Verify the three named volumes still exist:
#        docker volume ls | grep ac-host-ci
#   4. Verify the ports are actually free:
#        ss -tulnp | grep -E ':(9000|9001)\b'
#   5. Only then flip homelab.ci.enable = true for this host in
#      hosts/ac-box/configuration.nix and run the switch. (Done, 12 Sep
#      2026, generation 31. Kept as the record of the order it had to
#      happen in, and because a second host would repeat it.)
#   6. After the switch, confirm `systemctl status ac-host-ci.service` is
#      active, `docker ps` shows the same container names attached to the
#      SAME volumes (`docker inspect --format '{{json .Mounts}}'` should
#      still show /var/lib/docker/volumes/ac-host-ci_*), and that a trivial
#      Buildkite build round-trips before treating the hand-run `docker
#      compose up -d` workflow as retired.
#
# --------------------------------------------------------------------------
# HAZARD 2 -- THE BOOTSTRAP HAZARD
# --------------------------------------------------------------------------
# ac-host-ci-agent-1 is the Buildkite agent that builds and deploys ac-box
# itself (that is the entire point of this stack). Any change that stops or
# restarts that agent -- a `nixos-rebuild switch` that touches this unit, a
# plain `systemctl restart ac-host-ci`, anything -- MUST NEVER be shipped as
# a step in a Buildkite pipeline that runs ON this agent: doing so kills the
# very process running the job partway through, which can leave the job
# orphaned, the switch half-applied, and (worst case) no agent left alive to
# pick up a retry. Restarting the thing that is currently restarting you is
# not a recoverable state to discover by accident.
#
# Concretely: adopting this module, and every future `nixos-rebuild switch`
# that changes systemd.services.ac-host-ci, is applied from a plain
# interactive SSH session on ac-box -- never from a `.buildkite` pipeline
# step, never triggered by a CI job. This is the same class of constraint
# this task itself operates under (never write to ac-box; every
# nixos-rebuild is a human action from a real terminal).
#
# --------------------------------------------------------------------------
# VOLUMES THAT MUST SURVIVE ADOPTION
# --------------------------------------------------------------------------
# Compose project name is `ac-host-ci` (the `name:` key in
# docker-compose.buildkite.yml), so today's named volumes, confirmed via
# `docker volume ls` and each container's `docker inspect .Mounts`, are:
#
#   ac-host-ci_buildkite-nix     -> agent's /nix (the Nix store used to run
#                                    every build+substitute; losing this
#                                    means re-fetching/rebuilding the ENTIRE
#                                    Nix closure from scratch on the next job)
#   ac-host-ci_buildkite-builds  -> agent's /buildkite/builds (per-job
#                                    checkouts and build scratch; losing this
#                                    just costs one re-clone, not catastrophic)
#   ac-host-ci_minio-data        -> minio's /data (the actual Flox binary
#                                    cache objects backing the S3 substituter;
#                                    losing this means every consumer of the
#                                    cache falls back to building from source)
#
# All three live under /var/lib/docker/volumes/<name>/_data on the host.
# `docker compose down` (no `-v`) leaves them untouched; `docker compose up`
# against the same project name reattaches to them by name. The adoption
# sequence above depends on this: as long as the project name stays
# `ac-host-ci` and nobody passes `-v`, the systemd-managed stack picks up
# exactly where the hand-run one left off -- warm cache, warm Nix store.
#
# --------------------------------------------------------------------------
# CREDENTIALS
# --------------------------------------------------------------------------
# The env file holds a live BUILDKITE_AGENT_TOKEN, MINIO_ROOT_PASSWORD, the
# S3 cache access/secret/signing keys and GITHUB_STATUS_TOKEN. This module
# never reads that file's contents, never inlines a value from it, and never
# prints one -- it only carries the PATH (`homelab.ci.envFile`, below) into
# systemd's own EnvironmentFile= and into `docker compose --env-file`,
# exactly the two places the file is consumed. No fixture or test under
# tests/ contains a real or realistic-looking secret value; they check
# argv/serviceConfig shape only.
#
# Where the file comes from is not this module's concern, and since 14 Sep
# 2026 it is not a hand-placed file either: modules/platform/secrets.nix
# renders it from sops (sops.templates.ci-env, at /run/secrets/rendered/
# ci-env) and sets homelab.ci.envFile to that path. The option's default
# below is the pre-sops location under the tenant tree, kept so a host
# without the secrets module still has a working shape; on ac-box it is
# overridden. Both readers are on the host, so the rendered file is used in
# place -- no symlink, no copy unit (secrets.nix's header, "the third
# shape"). A changed render does NOT restart this unit: restartIfChanged =
# false below stands, for HAZARD 2, and the operator bounces it by hand
# from ssh once the agent is idle.
#
# --------------------------------------------------------------------------
# NATIVE: THE TENANT AS A FLOX ENVIRONMENT (ADR 0009 step 3, homelab-158.6)
# --------------------------------------------------------------------------
# homelab.ci.native.enable = true replaces the compose unit above with one
# stub per process (modules/tenant/environment.nix renders them; docs/
# flox-findings.md 2 is why it is one unit per process and not
# `--start-services`), run from the ci flox environment -- homelab's own
# `.flox/` at the repo root, checked out at a sha under
# homelab.tenants.ci.environment.dir by ci-environment-pull.service:
#
#   ac-host-ci.service             flox activate -d <env> -- buildkite-agent start
#   ac-host-ci-minio.service       flox activate -d <env> -- minio server <state>/minio
#   ac-host-ci-minio-init.service  flox activate -d <env> -- bash <env>/hub/ci/minio-init.sh
#                                  (oneshot; the bucket, its anonymous-download
#                                  policy and the flox-cache user)
#
# The name ac-host-ci.service is pinned (README) and is kept for the
# agent: the process that matters, and the one every "never bounce it from
# a job" sentence in this file is about. The two new names are free.
# Default false, and with it false NOTHING here changes: the compose unit
# is declared exactly as before, no stub, no pull unit, no tmpfiles rule,
# no hosts entry (modules/ci/tests/eval.nix's `nativeOffIsCompose` case, and
# homelab-158.6's handoff proved the stamp-stripped toplevel drvPath equal).
# True: the compose unit is NOT declared, so the switch that carries it
# STOPS it (`docker compose down`: the containers go, the named volumes
# stay) -- which is why the cutover is a runbook and not a push:
# docs/runbook-ci-native-cutover.md.
#
# WHAT CHANGES FOR A JOB, and what does not.
#
#   root, still. The container's agent ran as uid 0 (compose: `user:
#   "0:0"`, "needed for the Docker-socket-using recycle jobs"), and the
#   stubs run as root for three reasons that are each sufficient: the
#   assetto tenant's state is root's (/var/lib/ac-host is 0750 root:root
#   with a 0600 .env, and ac-host's queue-prod, DOWNTIME and pages steps
#   write pending-src, pending-deploy.json, dist/ and leaderboard.json
#   there -- as root, today); the docker socket is root-equivalent anyway
#   (the containerize and compose steps); and the store is opened
#   directly (next paragraph), which needs write access to /nix/var/nix.
#   A non-root agent is an ownership migration of the racing tenant's
#   state plus a secrets.nix change (ac-host-env's 0600 copy), and is
#   out of scope here -- named in the handoff, not papered over. The
#   privileged container is gone: a root process on the host needs no
#   capability to make the namespaces the sandbox is made of.
#
#   NIX_REMOTE=local: the builds are the unit's, and so is the fence.
#   The hazard the brief named -- "the stub's Slice= fences the agent but
#   nix-daemon builds run in nix-daemon's cgroup" -- is real for a
#   non-root client: nix-daemon.service is in system.slice with
#   MemoryMax=infinity, and SCHED_BATCH + idle IO (modules/platform/
#   nix.nix) is not a CPU fence. It is not what happens here. nix's
#   default store is `auto`, which opens the LOCAL store in-process when
#   the caller can write /nix/var/nix -- root can -- and the builders it
#   forks (sandboxed, as nixbld users) are children of the client, in the
#   client's cgroup. That is what the container did (its root agent never
#   used the daemon its entrypoint started), and it is why the ik_llama
#   compile of 17 Sep hit batch.slice's MemoryMax exactly: the build WAS
#   in batch.slice. Proven again on WSL for this change (18 Sep 2026):
#   `systemd-run -p Slice=batch.slice --setenv=NIX_REMOTE=local nix build`
#   of a probe derivation that cats /proc/self/cgroup from inside the
#   sandbox printed /batch.slice/<unit>.service, uid 1000 in the userns,
#   a chroot with /bin /build /dev /etc /nix /proc /tmp; the same probe as
#   an unprivileged user printed /system.slice/nix-daemon.service. So:
#   NIX_REMOTE=local is set explicitly on the agent (not left to `auto`,
#   so a future User= change fails loudly instead of quietly moving every
#   build into the daemon's unfenced cgroup), and every `nix build`,
#   `flox activate` and `nix copy` a job runs is in ac-host-ci.service,
#   under batch.slice's AllowedCPUs and MemoryMax. sandbox = true and
#   sandbox-fallback = false are the box's nix.conf already (verified on
#   ac-box); the file NIX_USER_CONF_FILES names below repeats them beside
#   cores = 2 and max-jobs = 2 -- the CPU FENCING paragraph of the compose
#   header, made explicit: a build gets the two physical cores batch owns,
#   and max-jobs is no longer `auto` (56 on this host; the container's
#   nproc was 4).
#
#   The daemon is still the answer for everyone else. The pull units'
#   warms as tenant users, and any non-root client, build through
#   nix-daemon unfenced (environment-pull.nix's header records it). The
#   platform fix is one line -- systemd.services.nix-daemon.serviceConfig
#   .Slice = "batch.slice" in modules/platform/nix.nix -- and it is a
#   platform decision (it fences the deploy's own substitutions and every
#   operator build too), not this module's; the handoff proposes it.
#
#   The store is the host's. No separate /nix volume: what a job builds
#   lands in the box's store, and the box no longer needs to substitute
#   from MinIO what it built itself. The MinIO push (the plugin's
#   post-command, S3_CACHE_PUSH) is still wanted: it is how the pull
#   units' substitute-only warms find agent-hub's flake packages (they
#   exist in no other cache), how a rebuilt box would, and how a second
#   machine would. What goes away: the 27 GB ac-host-ci_buildkite-nix
#   volume and the cold-volume seeding dance in the plugin's environment
#   hook (flox is pre-installed, `flox --version` short-circuits it).
#
#   flox is the box's. The manifest does not install flox; the unit's PATH
#   carries /run/current-system/sw, so `flox` in a job is modules/platform/
#   flox.nix's build of flake.nix's pin -- the same binary that reads every
#   tenant's lock on the box. That closes the hand-kept third copy
#   docs/flox-findings.md 6 names (the container's FLOX_VERSION arg; the
#   live container still reported 1.14.0 on 18 Sep, a rebuild behind the
#   box's 1.16.0). nix, docker and git in a job are likewise the host's.
#
#   Jobs inherit the agent's activation. The agent runs inside `flox
#   activate -d <env>`, so a job's own `flox activate -d <checkout>` is a
#   nested (layered) activation: the inner FLOX_ENV wins, the outer bin
#   stays on PATH (buildkite-agent, mc). Verified on WSL with the ci
#   environment over ac-host's: inner FLOX_ENV is ac-host's, `cd $FLOX_ENV
#   && pwd -P` (the plugin's push target) is ac-host's store path.
#   INVOCATION_ID is the one inherited variable that must NOT reach a job
#   (agent-hub's manifest reads it as "under a unit"); hub/ci/hooks/
#   environment unsets it, and assembles what compose used to interpolate
#   (AWS_* from S3_CACHE_*, the inquire-platform GIT_CONFIG_* rewrite from
#   BUILDKITE_CLONE_TOKEN) -- a unit's Environment= expands nothing.
#
#   `minio` still resolves. Every tenant pipeline hardcodes
#   S3_CACHE_ENDPOINT=http://minio:9000 (the compose network's name; five
#   files across ac-host, agent-hub and home-arcade), and a pipeline's env
#   overrides the agent's. networking.hosts maps the name to loopback so
#   nothing has to move in lockstep; dropping those lines is each tree's
#   cleanup afterwards, not a prerequisite.
#
#   The plugin's nix.conf write. imkarrer/flox-buildkite-plugin's
#   environment hook appends the S3 substituter to /etc/nix/nix.conf,
#   which on NixOS is a read-only symlink into the store, and exits 1
#   when it cannot. FLOX_NIX_CONF points it at a file under the state dir
#   instead; NIX_USER_CONF_FILES lists that file first so what the plugin
#   writes (s3://... with the AWS credential) is read, then the closure's
#   own settings file. The box's nix.conf already carries the same bucket
#   as http://127.0.0.1:9000/... with both public keys (the substituter
#   this module sets in either shape), so the plugin's line is belt and
#   braces, not the only read path.
#
#   Secrets: EnvironmentFile= is the same sops render as before
#   (homelab.ci.envFile), on all three units, read by PID 1. minio and its
#   init see the agent's token and the push tokens too, which the compose
#   file did not give them; one file, one uid, and the narrower render is
#   a secrets.nix change the handoff lists. A changed render still
#   restarts nothing (restartIfChanged = false stands on every stub, for
#   HAZARD 2 -- the cutover and every later change to these units is a
#   runbook step from ssh when the agent is idle).
#
#   ConditionPathExists on every stub: the environment's lock at <dir>.
#   The first-switch order every other tenant follows (environment-pull
#   .nix's header: pull and warm on a closure where the stub is still the
#   module's, THEN switch the stub on) is not available to ci, because the
#   stub and the compose unit share a name -- there is no closure with
#   both, and a closure with the stub off is a box with no agent to build
#   the push that turns it on. So the switch carries native.enable and
#   environment.enable together, the stubs start with no checkout at
#   <dir>, and the condition makes that "skipped", not a Restart=
#   on-failure loop into the start limit; the pull unit's restart, once
#   the checkout is warmed, is what starts them. The runbook has the
#   order.
#
# What this module does NOT do yet: stage its own environment. Nothing
# writes pending-environment-ci.json -- the pipeline step that would
# (hub-queue-environment.sh ci $BUILDKITE_COMMIT, HOMELAB_STAGE_TREE=
# homelab, from homelab's own build on green) would have the pull restart
# the agent from a job on the agent, HAZARD 2 by a new road. The answer is
# the ci tenant's quiet policy (drainable = false with a busyCheck that
# asks whether the agent has a job's child process), which also makes the
# deploy loop wait for an idle agent; that is a tenants.nix decision the
# handoff raises. Until it lands, a change to the ci environment reaches
# the box the way the cutover does: a record written from ssh when idle,
# and the pull unit started by hand.
{ config, lib, pkgs, ... }:

let
  inherit (lib) mkOption mkIf mkMerge types;

  cfg = config.homelab.ci;
  composeDir = "${cfg.repoDir}/compose";

  native = cfg.native;
  # Read lazily: only a host with native on evaluates the tenant's
  # environment (the compose-only harness cases carry a `ci` tenant too,
  # because the module names homelab.tenants.ci and the option must exist).
  envDir = toString config.homelab.tenants.ci.environment.dir;
  stateDir = toString native.stateDir;

  # The settings a job's nix reads (NIX_USER_CONF_FILES, header). The box's
  # nix.conf has the first two already; they are repeated so the file says
  # what a build under this agent is allowed to be, in one place. A file,
  # not NIX_CONFIG: settings are newline-separated and a unit's Environment=
  # cannot carry a newline.
  jobNixConf = pkgs.writeText "ci-job-nix.conf" ''
    sandbox = true
    sandbox-fallback = false
    cores = 2
    max-jobs = 2
  '';
  pluginNixConf = "${stateDir}/plugin-nix.conf";

  bucketUrl = "http://${native.minio.address}/${cfg.cacheBucket}";
  publicKeys = [
    "flox-binary-cache-1:pSpP6x540XtBh+IMvmW8XrRHJDtIi+b31uvvIA0PyR0="
    "flox-binary-cache-2:ESa71iIsMeX6Wu7EBiXXZlJraWI0HF4xdOF/ivG4UTo="
  ];

  # Every stub is root (header), never bounced by a switch (HAZARD 2), and
  # skipped rather than failed while the environment is not there yet.
  stubCommon = {
    restartIfChanged = false;
    stopIfChanged = false;
    unitConfig.ConditionPathExists = "${envDir}/.flox/env/manifest.lock";
    # The path, never the contents -- CREDENTIALS above. Read by PID 1.
    serviceConfig.EnvironmentFile = cfg.envFile;
  };
in
{
  options.homelab.ci = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Bring the hand-started Buildkite agent + MinIO cache stack under
        systemd. Defaults to false: this is a draft for a post-cutover phase
        (beads homelab-bqo.19) and must not go true until a human has run
        the adoption sequence documented at the top of this file, from a
        plain SSH session on ac-box (never from a Buildkite pipeline step --
        see the bootstrap-hazard comment above).
      '';
    };

    repoDir = mkOption {
      type = types.path;
      default = "/var/lib/ac-host/src";
      description = ''
        Git checkout containing compose/docker-compose.buildkite.yml, same
        default as services.ac-host.repoDir in the ac-host flake -- it is
        the same checkout, not a separate one.
      '';
    };

    envFile = mkOption {
      type = types.path;
      default = "${composeDir}/.env.buildkite";
      description = ''
        Path to the env file holding BUILDKITE_AGENT_TOKEN,
        MINIO_ROOT_PASSWORD and the S3 cache keys. Referenced by path only --
        passed straight through to systemd's EnvironmentFile= and to
        `docker compose --env-file`. Never read, inlined, or logged by this
        module or its tests. The default is the hand-placed, gitignored
        location under the tenant tree; modules/platform/secrets.nix sets
        it to the sops-rendered file (/run/secrets/rendered/ci-env) on any
        host that imports it, which ac-box does.
      '';
    };

    projectName = mkOption {
      type = types.str;
      default = "ac-host-ci";
      description = ''
        Must match the `name:` key in docker-compose.buildkite.yml. This is
        what ties the systemd-managed stack to the SAME named volumes
        (ac-host-ci_buildkite-nix, ac-host-ci_buildkite-builds,
        ac-host-ci_minio-data) the hand-started one already created --
        changing it would make `docker compose up` create a fresh,
        empty set instead of adopting the existing cache.
      '';
    };

    composeFile = mkOption {
      type = types.str;
      default = "docker-compose.buildkite.yml";
      description = "Relative to repoDir/compose (this is also WorkingDirectory, matching minio-init.sh's own ./minio-init.sh relative mount).";
    };

    cacheBucket = mkOption {
      type = types.str;
      default = "flox-binary-cache";
      description = ''
        The MinIO bucket that is the Nix binary cache: the path of the
        substituter this module adds in either shape, and S3_CACHE_BUCKET
        on the native agent. Fixed by the compose env and every pipeline's
        `S3_CACHE_BUCKET`; one spelling here.
      '';
    };

    native = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Run the ci tenant from its flox environment -- one stub per
          process (ac-host-ci, ac-host-ci-minio, ac-host-ci-minio-init) --
          instead of the compose unit. False, the default, declares the
          compose unit exactly as before and nothing of this. True is the
          cutover: docs/runbook-ci-native-cutover.md, from ssh, when the
          agent is idle (NATIVE in this file's header).
        '';
      };

      stateDir = mkOption {
        type = types.path;
        default = "/var/lib/ci";
        description = ''
          The ci tenant's state: minio/ (the bucket's objects, the docker
          volume's successor), builds/ (per-job checkouts), plugins/ (what
          the agent clones), plugin-nix.conf (what the flox plugin's hook
          appends). The environment checkout is beside them at
          homelab.tenants.ci.environment.dir (<stateDir>/env by derivation).
          README's derived default, <paths.state>/<tenant>.
        '';
      };

      minio = {
        address = mkOption {
          type = types.str;
          default = "127.0.0.1:9000";
          description = "minio's --address: the S3 API, loopback only (tenants.nix's minio-api claim, scope local).";
        };
        consoleAddress = mkOption {
          type = types.str;
          default = "127.0.0.1:9001";
          description = "minio's --console-address, loopback only (tenants.nix's minio-console claim).";
        };
      };

      jobEnvironment = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = ''
          Variables the agent forwards to every job beyond this module's
          own: another tenant's host facts that its pipeline reads on the
          box (ac-host's AC_STATE, AC_SRC, ... -- the paths compose used to
          spell). Set by the host, which owns those facts; never a secret
          (those are the EnvironmentFile's).
        '';
      };
    };
  };

  config = mkMerge [
    (mkIf cfg.enable {
      # The cache CI fills is a substituter for the box itself. ADR 0009's
      # deploy edge warms a flox tenant's environment on the box with one
      # activation; agent-hub's flake packages (the ik_llama.cpp fork,
      # stable-diffusion.cpp) exist in no cache but this one, so without this
      # the first activation compiles them through nix-daemon -- unfenced, in
      # system.slice, on 56 threads beside the race servers. MinIO is loopback
      # only (127.0.0.1:9000, header above), the bucket is anonymous-download
      # since ac-host 141280e (minio-init.sh), and the two keys are the public
      # halves of the signing pairs already listed in every pipeline's
      # S3_CACHE_PUBLIC_KEY. Ordered after cache.nixos.org and cache.flox.dev
      # (mkOrder 1600 in modules/platform/flox.nix): a miss there is a
      # connection to loopback, and while ac-host-ci is down nix logs one
      # warning per query and moves on -- the same behaviour as any
      # unreachable substituter. The bucket path is fixed by ac-host's
      # compose env (S3_CACHE_BUCKET); the name is repeated here rather than
      # read, because the closure cannot read a tenant's env file.
      nix.settings = {
        substituters = lib.mkOrder 1700 [ bucketUrl ];
        trusted-public-keys = publicKeys;
      };
    })

    # NOT set here: virtualisation.docker.enable. The platform layer
    # (modules/platform/docker.nix) turns the daemon on the moment any
    # tenant declares needsDocker = true, and hosts/ac-box/tenants.nix's `ci`
    # entry already does. This module assumes that ownership rather than
    # duplicating it -- see docker.nix's own header on why the daemon has
    # exactly one owner.
    (mkIf (cfg.enable && !native.enable) {
      systemd.services.ac-host-ci = {
        description = "Self-hosted Buildkite agent + MinIO Nix binary cache (ac-host-ci compose project)";

        # Deliberately NOT wantedBy multi-user.target here. Whether this
        # starts at boot is a decision for whoever wires this module in
        # (hosts/ac-box/configuration.nix, not touched by this draft); leaving
        # it off keeps `nix eval` against a fixture from implying an opinion
        # this module hasn't been asked to hold yet.
        after = [ "docker.service" "network-online.target" ];
        wants = [ "network-online.target" ];
        requires = [ "docker.service" ];

        # git: the agent image's build context in docker-compose.buildkite.yml
        # is a git URL (flox-buildkite-plugin.git#main), which compose fetches
        # by shelling out to git. `path` replaces PATH wholesale, so the system
        # profile's git is invisible here; the first switch that actually ran
        # this unit (12 Sep 2026) died with "unable to find 'git'" at the build
        # step, leaving the already-running containers untouched.
        path = [ pkgs.docker-compose pkgs.docker pkgs.git pkgs.coreutils ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          WorkingDirectory = composeDir;

          # The path, never the contents -- see CREDENTIALS above.
          EnvironmentFile = cfg.envFile;

          ExecStart = "${pkgs.docker-compose}/bin/docker-compose -f ${cfg.composeFile} --env-file ${cfg.envFile} -p ${cfg.projectName} up -d --build";

          # No `-v`: this must never remove ac-host-ci_buildkite-nix,
          # ac-host-ci_buildkite-builds or ac-host-ci_minio-data. See VOLUMES
          # above -- losing buildkite-nix in particular means rebuilding the
          # entire Nix store cache from scratch.
          ExecStop = "${pkgs.docker-compose}/bin/docker-compose -f ${cfg.composeFile} --env-file ${cfg.envFile} -p ${cfg.projectName} down";
        };

        # Same rationale as ac-host-static's identical pair (modules/ac-host.nix
        # in the ac-host flake): a plain `nixos-rebuild switch` must never
        # implicitly bounce this unit. For ac-host-static that's about not
        # dropping live races; for this unit it's the bootstrap hazard above --
        # an activation that restarts its own Buildkite agent mid-job.
        restartIfChanged = false;
        stopIfChanged = false;
      };
    })

    (mkIf (cfg.enable && native.enable) {
      assertions = [
        {
          assertion = config.homelab.tenants ? ci && config.homelab.tenants.ci.enable;
          message = "homelab.ci.native.enable needs the `ci` tenant declared and enabled (hosts/<host>/tenants.nix): the stubs are its, and a disabled tenant renders none of them.";
        }
      ];

      # The stubs. environment.nix renders the units, resources.nix puts them
      # in the tenant's slice, environment-pull.nix keeps the checkout; this
      # is the declaration the host would otherwise write, and the module
      # writes it because the commands and the variables are the tenant's,
      # not the host's. environment.enable goes with native.enable (header:
      # a closure with the stubs off is a box with no agent).
      homelab.tenants.ci.environment = {
        enable = true;
        # The environment is this repo's own .flox/ (its manifest header says
        # why): the tree kind, of the tree named homelab in hub/repos.psv.
        tree = "homelab";
        units = {
          "ac-host-ci.service" = {
            description = "Buildkite agent for every tree in this hub (from the ci flox environment)";
            user = "root";
            group = "root";
            workingDirectory = stateDir;
            # minio-init's completion is wanted, not required: an agent
            # without its cache is a slower agent, not a broken one, and
            # docker is the jobs' (compose, containerize), not the agent's.
            after = [ "network-online.target" "docker.service" "ac-host-ci-minio-init.service" ];
            wants = [ "network-online.target" "docker.service" "ac-host-ci-minio-init.service" ];
            command = [ "buildkite-agent" "start" ];
            environment = native.jobEnvironment // {
              # The agent's own layout. Token, name and tags come from the
              # EnvironmentFile (BUILDKITE_AGENT_TOKEN/NAME/TAGS in the
              # ci-env render); hooks from the checkout, so a hook change is
              # a pull, not a switch.
              BUILDKITE_BUILD_PATH = "${stateDir}/builds";
              BUILDKITE_HOOKS_PATH = "${envDir}/hub/ci/hooks";
              BUILDKITE_PLUGINS_PATH = "${stateDir}/plugins";
              # A plugin checkout is cached by ref and reused across jobs;
              # the container had a fresh cache at every recreate, this unit
              # keeps ${stateDir}/plugins. `imkarrer/flox#main` is a moving
              # ref, and the first native build (18 Sep 2026) ran a cached
              # copy whose hooks said #!/bin/bash on a host that has none.
              # Clone fresh per job: a few seconds against github.com, and
              # a plugin fix is live at the next job rather than the next
              # rm -rf by hand.
              BUILDKITE_AGENT_PLUGINS_ALWAYS_CLONE_FRESH = "true";
              # The store, opened in-process (header). Explicit, not `auto`.
              NIX_REMOTE = "local";
              NIX_USER_CONF_FILES = "${pluginNixConf}:${jobNixConf}";
              FLOX_NIX_CONF = pluginNixConf;
              # Non-secret cache identity, the plugin's fallback when a
              # pipeline does not repeat it. The endpoint is loopback; the
              # compose network's `minio` name resolves there too
              # (networking.hosts below) for the pipelines that still say it.
              S3_CACHE_BUCKET = cfg.cacheBucket;
              S3_CACHE_ENDPOINT = "http://${native.minio.address}";
              S3_CACHE_REGION = "us-east-1";
              S3_CACHE_PUBLIC_KEY = lib.concatStringsSep " " publicKeys;
              S3_CACHE_PUSH = "true";
              AWS_EC2_METADATA_DISABLED = "true";
            };
          };

          "ac-host-ci-minio.service" = {
            description = "MinIO: the Nix binary cache CI fills and the box substitutes from (loopback only)";
            user = "root";
            group = "root";
            command = [
              "minio"
              "server"
              "${stateDir}/minio"
              "--address"
              native.minio.address
              "--console-address"
              native.minio.consoleAddress
            ];
          };

          "ac-host-ci-minio-init.service" = {
            description = "Provision the MinIO cache bucket, its anonymous-download policy and the flox-cache user";
            user = "root";
            group = "root";
            # A oneshot (Type= below): runs to completion at every start of
            # this unit, which is every boot and every rotation bounce.
            restart = "no";
            after = [ "ac-host-ci-minio.service" ];
            wants = [ "ac-host-ci-minio.service" ];
            command = [ "bash" "${envDir}/hub/ci/minio-init.sh" ];
            environment = {
              MINIO_ENDPOINT = "http://${native.minio.address}";
              S3_CACHE_BUCKET = cfg.cacheBucket;
            };
          };
        };
      };

      systemd.services = {
        # The unit's PATH: the system profile, so a job finds the host's
        # nix, docker, git and the box's flox (header). environment.nix does
        # not set `path`; this merges with NixOS's default (coreutils...).
        ac-host-ci = stubCommon // {
          path = [ "/run/current-system/sw" ];
        };
        ac-host-ci-minio = stubCommon;
        ac-host-ci-minio-init = stubCommon // {
          serviceConfig = stubCommon.serviceConfig // {
            Type = "oneshot";
            RemainAfterExit = true;
          };
        };
      };

      systemd.tmpfiles.rules = [
        "d ${stateDir} 0755 root root -"
        "d ${stateDir}/minio 0750 root root -"
        "d ${stateDir}/builds 0755 root root -"
        "d ${stateDir}/plugins 0755 root root -"
      ];

      # The compose network's name for the cache, kept resolvable (header).
      networking.hosts."127.0.0.1" = [ "minio" ];
    })
  ];
}
