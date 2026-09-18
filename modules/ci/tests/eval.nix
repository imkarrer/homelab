# Eval harness for modules/ci/default.nix.
#
# The module is live on ac-box (generation 31, 12 Sep 2026), so the real
# composition IS evaluated -- by `nix flake check`'s ac-box toplevel. This
# harness is the other half: it is not a full system evaluation and does not
# try to be. It proves the module's own logic evaluates cleanly and produces
# the expected shape against stubs of the option surface it touches -- and,
# since the native shape (homelab-158.6) declares the ci tenant's unit stubs
# through the tenant contract, against the REAL schema/enforce/resources/
# environment/environment-pull modules, the way modules/tenant/tests/
# eval-environment.nix composes them: pinned lib/pkgs, the tenant harness's
# stubs (stub-systemd, stub-nix, stub-etc), a fake flox package, the
# host's own facts file, and a `ci` tenant fixture that mirrors
# hosts/ac-box/tenants.nix's entry.
#
# Usage:
#   nix --extra-experimental-features "nix-command flakes" eval \
#     -f modules/ci/tests/eval.nix <case>.<field>
#
# No fixture here contains, or needs, a real secret: homelab.ci.envFile is
# checked as a STRING PATH only (it must equal the fixture's chosen path),
# never opened or interpolated into an expected value.
#
# `lib`/`pkgs` come from the revision flake.lock pins, not from
# <nixpkgs>/NIX_PATH -- finding F7, closed 9 Sep 2026. The helper lives under
# modules/tenant/tests/ because that is where the other four harnesses are and
# a pin must have exactly one home; L2 reaching into L1 is the permitted
# direction (README's "Layers"), and the file's own header says where it
# should move if this repo ever grows a neutral lib/ or a flake `checks`
# output. There is deliberately no <nixpkgs> fallback: an unpinned run must
# fail loudly rather than quietly succeed against the wrong lib.
{
  lib ? (import ../../tenant/tests/pinned-nixpkgs.nix).lib,
  pkgs ? (import ../../tenant/tests/pinned-nixpkgs.nix).pkgs,
}:

let
  ci = ../default.nix;

  tenantTests = ../../tenant/tests;
  stubSystemd = tenantTests + "/stub-systemd.nix";
  stubNix = tenantTests + "/stub-nix.nix";
  stubEtc = tenantTests + "/stub-etc.nix";
  stubNetwork = ./stub-network.nix;
  hostOptions = ../../platform/host-options.nix;
  hostFacts = ../../../hosts/ac-box/host.nix;
  floxModule = ../../platform/flox.nix;
  schema = ../../tenant/schema.nix;
  enforce = ../../tenant/enforce.nix;
  resources = ../../tenant/resources.nix;
  environment = ../../tenant/environment.nix;
  environmentPull = ../../tenant/environment-pull.nix;
  tenants = ./fixtures/tenants.nix;

  # Never built; only its store path is read (eval-environment.nix's
  # reasoning: the ExecStart prefix asserted below is unmistakably the
  # harness's).
  floxStub = pkgs.runCommand "flox-stub" { } "mkdir -p $out/bin; touch $out/bin/flox";

  noCtx = builtins.unsafeDiscardStringContext;

  mkCase =
    {
      extraModules ? [ ],
      checks ? (_: _: [ ]),
    }:
    let
      evaluated = lib.evalModules {
        specialArgs = { inherit pkgs; };
        modules = [
          stubSystemd
          stubNix
          stubEtc
          stubNetwork
          hostOptions
          hostFacts
          floxModule
          { homelab.flox.package = floxStub; }
          schema
          enforce
          resources
          environment
          environmentPull
          tenants
          { homelab.enforce.slices = true; }
          ci
        ]
        ++ extraModules;
      };
      cfg = evaluated.config;
      svc = cfg.systemd.services.ac-host-ci or null;
      # The compose unit's shape, as the pre-native cases read it. Null
      # when the unit is absent; the native cases read the unit directly.
      summary =
        if svc == null then
          null
        else
          {
            inherit (svc) after wants requires restartIfChanged stopIfChanged;
            inherit (svc.serviceConfig) Type RemainAfterExit WorkingDirectory EnvironmentFile ExecStart ExecStop;
          };

      # The contract's assertions (environment.nix, environment-pull.nix,
      # resources.nix) and the module's own, plus this case's checks.
      failedAssertions = lib.filter (a: !a.assertion) cfg.assertions;
      failed = lib.filter (c: !c.assertion) (checks cfg summary);
      messages = map (a: a.message) failedAssertions ++ map (c: c.message) failed;
    in
    {
      inherit (evaluated) config;
      inherit summary;
      hasUnit = svc != null;
      unit = svc;
      ok = messages == [ ];
      inherit messages;
      checked =
        if messages == [ ] then
          "OK: all checks passed"
        else
          throw (lib.concatStringsSep "\n" messages);
    };

  # The keys the compose shape has and the native shape must not, and the
  # other way round -- so "the compose unit is not declared" is a check
  # on its ExecStart, not on the unit name (the agent stub keeps it).
  isCompose = unit: lib.hasInfix "docker-compose" (noCtx (unit.serviceConfig.ExecStart or ""));
in
{
  # Default: homelab.ci.enable = false (the module's own default). Must
  # contribute NOTHING to systemd.services -- not an empty/disabled unit,
  # no unit key at all -- proving this draft is inert until a host opts in.
  disabledByDefault = mkCase {
    checks = cfg: _: [
      {
        # resources.nix puts Slice=/Nice= on every unit the tenant fixture
        # names, so the key exists; the module itself must add nothing to it.
        assertion = !(cfg.systemd.services.ac-host-ci.serviceConfig ? ExecStart) && !(cfg.systemd.services.ac-host-ci.serviceConfig ? EnvironmentFile);
        message = "homelab.ci.enable = false (default): the module must contribute nothing to systemd.services.ac-host-ci -- no ExecStart, no EnvironmentFile";
      }
    ];
  };

  # Explicitly enabled with the module's own defaults (repoDir/envFile/
  # projectName/composeFile all default). Checks:
  #   - the unit exists, is a oneshot with RemainAfterExit, never bounced by
  #     activation (restartIfChanged/stopIfChanged both false -- the
  #     bootstrap-hazard mitigation)
  #   - EnvironmentFile is the DEFAULT envFile PATH (repoDir/compose/
  #     .env.buildkite), never a literal secret
  #   - ExecStart/ExecStop both reference the default project name
  #     (ac-host-ci) and composeFile, and ExecStop carries no `-v`
  #   - requires/after include docker.service, matching every other
  #     Docker-backed unit in this repo's convention (ac-host.nix)
  enabledDefaults = mkCase {
    extraModules = [ { homelab.ci.enable = true; } ];
    checks = _: summary: [
      {
        assertion = summary != null;
        message = "homelab.ci.enable = true: systemd.services.ac-host-ci must exist";
      }
      {
        assertion = summary.Type == "oneshot" && summary.RemainAfterExit == true;
        message = "ac-host-ci must be Type=oneshot with RemainAfterExit=true";
      }
      {
        assertion = summary.restartIfChanged == false && summary.stopIfChanged == false;
        message = "ac-host-ci must never be bounced by activation: restartIfChanged and stopIfChanged must both be false (HAZARD 2)";
      }
      {
        assertion = summary.EnvironmentFile == "/var/lib/ac-host/src/compose/.env.buildkite";
        message = "EnvironmentFile must be the DEFAULT envFile path (repoDir/compose/.env.buildkite), passed through as a path";
      }
      {
        assertion = summary.WorkingDirectory == "/var/lib/ac-host/src/compose";
        message = "WorkingDirectory must be repoDir/compose";
      }
      {
        assertion =
          lib.hasInfix " -p ac-host-ci " summary.ExecStart
          && lib.hasInfix " -f docker-compose.buildkite.yml " summary.ExecStart;
        message = "ExecStart must name the default project (ac-host-ci) and composeFile (docker-compose.buildkite.yml)";
      }
      {
        assertion =
          lib.hasInfix " -p ac-host-ci " summary.ExecStop
          && lib.hasInfix " -f docker-compose.buildkite.yml " summary.ExecStop;
        message = "ExecStop must name the default project (ac-host-ci) and composeFile (docker-compose.buildkite.yml)";
      }
      {
        assertion = lib.hasSuffix " down" summary.ExecStop && !(lib.hasInfix " -v" summary.ExecStop);
        message = "ExecStop must be a plain `down` with no -v: the MinIO cache volume must survive a stop";
      }
      {
        assertion = lib.elem "docker.service" summary.requires && lib.elem "docker.service" summary.after;
        message = "ac-host-ci must require and order after docker.service, like every other Docker-backed unit in this repo";
      }
    ];
  };

  # Enabled with every path option overridden, proving the module actually
  # threads repoDir/envFile/projectName/composeFile through rather than
  # hardcoding ac-host's defaults -- exercises the same knobs a differently
  # laid-out host would need.
  enabledCustomPaths = mkCase {
    extraModules = [
      {
        homelab.ci = {
          enable = true;
          repoDir = "/srv/example-ci-src";
          envFile = "/run/secrets/example-ci.env";
          projectName = "example-ci";
          composeFile = "compose.ci.yml";
        };
      }
    ];
    checks = _: summary: [
      {
        assertion = summary != null;
        message = "homelab.ci.enable = true with custom paths: systemd.services.ac-host-ci must exist";
      }
      {
        assertion = summary.EnvironmentFile == "/run/secrets/example-ci.env";
        message = "EnvironmentFile must be the overridden envFile, not ac-host's default";
      }
      {
        assertion = summary.WorkingDirectory == "/srv/example-ci-src/compose";
        message = "WorkingDirectory must follow the overridden repoDir";
      }
      {
        assertion =
          lib.hasInfix " -p example-ci " summary.ExecStart
          && lib.hasInfix " -f compose.ci.yml " summary.ExecStart
          && lib.hasInfix " --env-file /run/secrets/example-ci.env " summary.ExecStart;
        message = "ExecStart must thread projectName, composeFile and envFile through verbatim";
      }
      {
        assertion =
          lib.hasInfix " -p example-ci " summary.ExecStop
          && lib.hasInfix " -f compose.ci.yml " summary.ExecStop;
        message = "ExecStop must thread projectName and composeFile through verbatim";
      }
    ];
  };

  # native.enable = false (the default) beside enable = true: the compose
  # shape and NOTHING of the native one -- no stub declared on the tenant,
  # so no pull unit, no tmpfiles rule, no hosts entry, and the tenant's
  # `units` is the one name it had. This is the harness half of "nothing
  # changes with the flag off"; the toplevel drvPath is the other half.
  nativeOffIsCompose = mkCase {
    extraModules = [ { homelab.ci.enable = true; } ];
    checks = cfg: summary: [
      {
        assertion = summary != null && isCompose cfg.systemd.services.ac-host-ci;
        message = "native off: ac-host-ci must be the docker-compose unit";
      }
      {
        assertion = cfg.homelab.tenants.ci.environment.units == { } && !cfg.homelab.tenants.ci.environment.enable;
        message = "native off: no stub may be declared on homelab.tenants.ci.environment, and enable must stay false";
      }
      {
        assertion = builtins.attrNames cfg.systemd.services == [ "ac-host-ci" ];
        message = "native off: systemd.services must hold exactly the compose unit (no minio stubs, no ci-environment-pull); got ${builtins.toJSON (builtins.attrNames cfg.systemd.services)}";
      }
      {
        assertion = cfg.systemd.tmpfiles.rules == [ ] && cfg.networking.hosts == { } && cfg.systemd.paths == { };
        message = "native off: no tmpfiles rule, no networking.hosts entry, no path unit";
      }
      {
        assertion = cfg.homelab.tenants.ci.units == [ "ac-host-ci.service" ];
        message = "native off: the tenant's units list must be the compose unit alone";
      }
    ];
  };

  # native.enable = true: the compose unit is gone, the three stubs are
  # rendered by environment.nix from the module's declaration, each root,
  # each in batch.slice, each with the env file, never bounced by a switch,
  # skipped while the checkout is absent; the agent's variables carry the
  # host's fencing decisions (NIX_REMOTE=local, the conf file); the pull
  # unit exists for the tenant and clones the homelab remote; the tenant's
  # units list names all three; `minio` resolves to loopback.
  nativeOn = mkCase {
    extraModules = [
      {
        homelab.ci.enable = true;
        homelab.ci.native.enable = true;
        homelab.ci.native.jobEnvironment.AC_STATE = "/var/lib/ac-host";
      }
    ];
    checks =
      cfg: _:
      let
        s = cfg.systemd.services;
        agent = s.ac-host-ci;
        minio = s.ac-host-ci-minio;
        init = s.ac-host-ci-minio-init;
        stubs = [ agent minio init ];
        env = agent.environment;
        dir = toString cfg.homelab.tenants.ci.environment.dir;
        execOf = u: noCtx (toString u.serviceConfig.ExecStart);
        pull = cfg.homelab.environments.pull.ci or null;
      in
      [
        {
          assertion = !(isCompose agent);
          message = "native on: ac-host-ci must not be the docker-compose unit";
        }
        {
          assertion = lib.sort builtins.lessThan (builtins.attrNames s) == [ "ac-host-ci" "ac-host-ci-minio" "ac-host-ci-minio-init" "ci-environment-pull" ];
          message = "native on: exactly the three stubs and the pull unit; got ${builtins.toJSON (builtins.attrNames s)}";
        }
        {
          assertion = dir == "/var/lib/ci/env";
          message = "native on: environment.dir must derive to /var/lib/ci/env (README's <paths.state>/<tenant>); got ${dir}";
        }
        {
          assertion = lib.hasPrefix "${floxStub}/bin/flox activate -d ${dir} -- buildkite-agent start" (execOf agent);
          message = "native on: the agent's ExecStart must be the activation of <dir> running `buildkite-agent start`; got ${execOf agent}";
        }
        {
          assertion = lib.hasPrefix "${floxStub}/bin/flox activate -d ${dir} -- minio server /var/lib/ci/minio --address 127.0.0.1:9000 --console-address 127.0.0.1:9001" (execOf minio);
          message = "native on: minio's ExecStart must serve <stateDir>/minio on the two loopback addresses; got ${execOf minio}";
        }
        {
          assertion = execOf init == "${floxStub}/bin/flox activate -d ${dir} -- bash ${dir}/hub/ci/minio-init.sh";
          message = "native on: the init's ExecStart must run hub/ci/minio-init.sh from the checkout; got ${execOf init}";
        }
        {
          assertion = lib.all (u: u.serviceConfig.User == "root" && u.serviceConfig.Slice == "batch.slice") stubs;
          message = "native on: every stub must run as root (the header's three reasons) in batch.slice (the tenant's tier)";
        }
        {
          assertion = lib.all (
            u: !u.restartIfChanged && !u.stopIfChanged && u.serviceConfig.EnvironmentFile == cfg.homelab.ci.envFile
          ) stubs;
          message = "native on: every stub must carry restartIfChanged = stopIfChanged = false (HAZARD 2) and the env file PATH";
        }
        {
          assertion = lib.all (u: u.unitConfig.ConditionPathExists == "${dir}/.flox/env/manifest.lock") stubs;
          message = "native on: every stub must be conditioned on the checkout's lock, so the cutover switch skips rather than fails them";
        }
        {
          assertion = init.serviceConfig.Type == "oneshot" && init.serviceConfig.RemainAfterExit && init.serviceConfig.Restart == "no";
          message = "native on: the init must be a oneshot that stays 'active' and never restarts";
        }
        {
          assertion = lib.elem "ac-host-ci-minio-init.service" agent.after && lib.elem "ac-host-ci-minio.service" init.after;
          message = "native on: agent after init after minio";
        }
        {
          assertion = env.NIX_REMOTE == "local" && env.FLOX_NIX_CONF == "/var/lib/ci/plugin-nix.conf" && lib.hasPrefix "/var/lib/ci/plugin-nix.conf:/nix/store/" env.NIX_USER_CONF_FILES;
          message = "native on: the agent must open the store in-process (NIX_REMOTE=local) and point the plugin's nix.conf write at the state dir, read before the closure's own settings file";
        }
        {
          assertion = env.BUILDKITE_HOOKS_PATH == "${dir}/hub/ci/hooks" && env.BUILDKITE_BUILD_PATH == "/var/lib/ci/builds" && env.BUILDKITE_PLUGINS_PATH == "/var/lib/ci/plugins";
          message = "native on: hooks from the checkout, builds and plugins under the state dir";
        }
        {
          assertion = env.S3_CACHE_ENDPOINT == "http://127.0.0.1:9000" && env.S3_CACHE_BUCKET == "flox-binary-cache" && env.AC_STATE == "/var/lib/ac-host";
          message = "native on: the cache endpoint is loopback, the bucket is the module's one spelling, and jobEnvironment reaches the agent";
        }
        {
          assertion = !(env ? BUILDKITE_AGENT_TOKEN) && !(env ? MINIO_ROOT_PASSWORD) && !(env ? S3_CACHE_SIGNING_KEY);
          message = "native on: no secret-bearing name may be set as a plain variable; those are the EnvironmentFile's";
        }
        {
          assertion = lib.elem "/run/current-system/sw" agent.path;
          message = "native on: the agent's PATH must carry the system profile (nix, docker, git, the box's flox)";
        }
        {
          assertion = lib.elem "http://127.0.0.1:9000/flox-binary-cache" cfg.nix.settings.substituters && lib.elem "flox-binary-cache-2:ESa71iIsMeX6Wu7EBiXXZlJraWI0HF4xdOF/ivG4UTo=" cfg.nix.settings.trusted-public-keys;
          message = "the substituter must be the same URL in the native shape as in the compose one";
        }
        {
          assertion = pull != null && lib.hasInfix "https://github.com/imkarrer/homelab" (noCtx pull.text) && lib.hasInfix "restartUnits='ac-host-ci-minio-init.service ac-host-ci-minio.service ac-host-ci.service'" (noCtx pull.text);
          message = "native on: ci-environment-pull must clone the homelab remote and restart all three stubs (enable is on)";
        }
        {
          assertion = cfg.homelab.tenants.ci.units == [ "ac-host-ci.service" "ac-host-ci-minio.service" "ac-host-ci-minio-init.service" ];
          message = "native on: the tenant's units must name all three stubs";
        }
        {
          assertion = cfg.networking.hosts."127.0.0.1" == [ "minio" ];
          message = "native on: `minio` (the compose network's name every pipeline still says) must resolve to loopback";
        }
        {
          assertion = lib.elem "d /var/lib/ci/minio 0750 root root -" cfg.systemd.tmpfiles.rules;
          message = "native on: the minio data directory must be created under the state dir";
        }
      ];
  };

  # native on without a `ci` tenant: refused by the module's own assertion,
  # not by a missing-attribute error somewhere in environment.nix.
  nativeWithoutTenant = mkCase {
    extraModules = [
      {
        homelab.ci.enable = true;
        homelab.ci.native.enable = true;
        # The fixture's tenant, disabled: the contract filters disabled
        # tenants out of every consumer, so there is no ci to stub.
        homelab.tenants.ci.enable = false;
      }
    ];
    checks = cfg: _: [
      {
        assertion = cfg.homelab.tenants.ci.enable == false;
        message = "fixture: the tenant must be disabled for this case";
      }
    ];
  };

  # Case name -> whether `<case>.checked` must evaluate cleanly. Read by
  # modules/ci/scripts/run-eval-tests.sh and by modules/tenant/tests/
  # check.nix (the flake `checks`). Until 12 Sep 2026 this harness had no
  # `.checked`: the runner special-cased it by forcing the whole case with
  # `nix eval --json`, and the properties the case comments above describe
  # were asserted by nobody. They are the `checks` now, and `.checked` is
  # the one shape every harness in this repo shares.
  expected = {
    disabledByDefault = true;
    enabledDefaults = true;
    enabledCustomPaths = true;
    nativeOffIsCompose = true;
    nativeOn = true;
    nativeWithoutTenant = false;
  };
}
