# Eval harness for modules/ci/default.nix.
#
# The module is live on ac-box (generation 31, 12 Sep 2026), so the real
# composition IS evaluated -- by `nix flake check`'s ac-box toplevel. This
# harness is the other half: it is not a full system evaluation and does not
# try to be. It only proves the module's own logic evaluates cleanly and
# produces the expected shape against a stub of the systemd option surface
# it touches -- same spirit as modules/tenant/tests/eval-resources.nix
# proving resources.nix against tests/stub-systemd.nix rather than the real
# nixos/modules/system/boot/systemd.nix.
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
  stubSystemd = ./stub-systemd.nix;
  # modules/ci writes nix.settings too (the MinIO substituter, since
  # cb28593); the tenant harness's stub models exactly that subset.
  stubNix = ../../tenant/tests/stub-nix.nix;

  mkCase =
    {
      extraModules ? [ ],
      checks ? (_: _: [ ]),
    }:
    let
      evaluated = lib.evalModules {
        specialArgs = { inherit pkgs; };
        modules = [ stubSystemd stubNix ci ] ++ extraModules;
      };
      cfg = evaluated.config;
      svc = cfg.systemd.services.ac-host-ci or null;
      summary =
        if svc == null then
          null
        else
          {
            inherit (svc) after wants requires restartIfChanged stopIfChanged;
            inherit (svc.serviceConfig) Type RemainAfterExit WorkingDirectory EnvironmentFile ExecStart ExecStop;
          };

      # This module declares no `assertions`, so unlike the tenant harnesses
      # there is nothing to read back from the module itself; `checks` is the
      # whole verdict.
      failed = lib.filter (c: !c.assertion) (checks cfg summary);
    in
    {
      inherit (evaluated) config;
      inherit summary;
      hasUnit = svc != null;
      unit = svc;
      ok = failed == [ ];
      messages = map (c: c.message) failed;
      checked =
        if failed == [ ] then
          "OK: all checks passed"
        else
          throw (lib.concatStringsSep "\n" (map (c: c.message) failed));
    };
in
{
  # Default: homelab.ci.enable = false (the module's own default). Must
  # contribute NOTHING to systemd.services -- not an empty/disabled unit,
  # no unit key at all -- proving this draft is inert until a host opts in.
  disabledByDefault = mkCase {
    checks = cfg: _: [
      {
        assertion = cfg.systemd.services == { };
        message = "homelab.ci.enable = false (default): systemd.services must be {} -- no ac-host-ci key, not even an empty one";
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

  # Case name -> whether `<case>.checked` must evaluate cleanly. None of these
  # three fixtures are invalid configs -- unlike modules/tenant/tests, this
  # module has no assertions to reject -- so every case is expected to
  # succeed. Read by modules/ci/scripts/run-eval-tests.sh and by
  # modules/tenant/tests/check.nix (the flake `checks`). Until 12 Sep 2026
  # this harness had no `.checked`: the runner special-cased it by forcing
  # the whole case with `nix eval --json`, and the properties the case
  # comments above describe were asserted by nobody. They are the `checks`
  # now, and `.checked` is the one shape every harness in this repo shares.
  expected = {
    disabledByDefault = true;
    enabledDefaults = true;
    enabledCustomPaths = true;
  };
}
