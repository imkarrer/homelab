# Eval harness for the DRAFT modules/ci/default.nix.
#
# Nothing imports modules/ci/ into hosts/ac-box (deliberately -- see the
# module's own header), so this is not, and cannot be, a full system
# evaluation. It only proves the module's own logic evaluates cleanly and
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
{
  lib ? (import <nixpkgs> { }).lib,
  pkgs ? import <nixpkgs> { },
}:

let
  ci = ../default.nix;
  stubSystemd = ./stub-systemd.nix;

  mkCase =
    { extraModules ? [ ] }:
    let
      evaluated = lib.evalModules {
        specialArgs = { inherit pkgs; };
        modules = [ stubSystemd ci ] ++ extraModules;
      };
      cfg = evaluated.config;
      svc = cfg.systemd.services.ac-host-ci or null;
    in
    {
      inherit (evaluated) config;
      hasUnit = svc != null;
      unit = svc;
      summary =
        if svc == null then
          null
        else
          {
            inherit (svc) after wants requires restartIfChanged stopIfChanged;
            inherit (svc.serviceConfig) Type RemainAfterExit WorkingDirectory EnvironmentFile ExecStart ExecStop;
          };
    };
in
{
  # Default: homelab.ci.enable = false (the module's own default). Must
  # contribute NOTHING to systemd.services -- not an empty/disabled unit,
  # no unit key at all -- proving this draft is inert until a host opts in.
  disabledByDefault = mkCase { };

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
  };
}
