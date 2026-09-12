# DRAFT -- belongs to a post-cutover phase. NOT imported by flake.nix or by
# hosts/ac-box/configuration.nix, and must not be until the adoption sequence
# below has been run by hand. Its only purpose right now is to exist as a
# reviewable, `nix eval`-able sketch of what "the CI stack has systemd units"
# looks like (beads homelab-bqo.19).
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
#   5. Only then flip homelab.ci.enable = true for this host (a separate,
#      coordinator-owned change to hosts/ac-box/configuration.nix -- this
#      module is not imported by that file yet) and run the switch.
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
# compose/.env.buildkite (gitignored, mode 0600 on the box, owner root) holds
# a live BUILDKITE_AGENT_TOKEN, MINIO_ROOT_PASSWORD, and the S3 cache
# access/secret/signing keys. This module never reads that file's contents,
# never inlines a value from it, and never prints one -- it only carries the
# PATH (`homelab.ci.envFile`, below) into systemd's own EnvironmentFile= and
# into `docker compose --env-file`, exactly the two places the file is
# already consumed today. No fixture or test under tests/ contains a real or
# realistic-looking secret value; they check argv/serviceConfig shape only.
{ config, lib, pkgs, ... }:

let
  inherit (lib) mkOption mkIf mkEnableOption types;

  cfg = config.homelab.ci;
  composeDir = "${cfg.repoDir}/compose";
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
        Path to the gitignored env file holding BUILDKITE_AGENT_TOKEN,
        MINIO_ROOT_PASSWORD and the S3 cache keys. Referenced by path only --
        passed straight through to systemd's EnvironmentFile= and to
        `docker compose --env-file`. Never read, inlined, or logged by this
        module or its tests.
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
  };

  config = mkIf cfg.enable {
    # NOT set here: virtualisation.docker.enable. The platform layer
    # (modules/platform/docker.nix) turns the daemon on the moment any
    # tenant declares needsDocker = true, and hosts/ac-box/tenants.nix's `ci`
    # entry already does. This module assumes that ownership rather than
    # duplicating it -- see docker.nix's own header on why the daemon has
    # exactly one owner.
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
  };
}
