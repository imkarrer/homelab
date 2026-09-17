# Eval harness for modules/tenant/environment.nix -- ADR 0009's unit stub.
#
# What it is for. The stub's whole contract is "off: the unit is its
# module's; on: only ExecStart and the variables change, and the slice the
# contract gave the unit is still there". The host config can prove only
# the first half (ac-box has it off), and `nix flake check` on the toplevel
# says nothing about which keys a module touched. So: the same fixture,
# once with the stub off and once on, and the exact keys compared -- plus
# the two things the module must REJECT (a stub outside the tenant's
# `units`, a stub that is not a .service), which no real host has.
#
# Usage:
#   nix --extra-experimental-features "nix-command flakes" eval \
#     -f modules/tenant/tests/eval-environment.nix enabled.summary --json
#
# Same shape as the other harnesses: pinned lib/pkgs, stubs for the option
# surface the modules write to, the REAL schema/enforce/resources/
# environment modules and the REAL modules/platform/flox.nix (with a fake
# package for homelab.flox.package, so the ExecStart prefix under test is a
# path this harness chose and not whatever flox happens to be), one
# attribute per case with `.checked` and `.messages`, and an `expected` map
# check.nix reads.
{
  lib ? (import ./pinned-nixpkgs.nix).lib,
  pkgs ? (import ./pinned-nixpkgs.nix).pkgs,
}:

let
  hostOptions = ../../platform/host-options.nix;
  hostFacts = ../../../hosts/ac-box/host.nix;
  floxModule = ../../platform/flox.nix;
  schema = ../schema.nix;
  enforce = ../enforce.nix;
  resources = ../resources.nix;
  environment = ../environment.nix;
  stubSystemd = ./stub-systemd.nix;
  stubNix = ./stub-nix.nix;
  tenants = ./fixtures/environment-tenants.nix;

  # Never built; only its store path is read. A runCommand rather than a
  # real package so the prefix asserted below is unmistakably the
  # harness's and could not be satisfied by a flox from anywhere else.
  floxStub = pkgs.runCommand "flox-stub" { } "mkdir -p $out/bin; touch $out/bin/flox";

  # The module's ExecStart, verbatim from the fixture -- the "off" answer.
  moduleExecStart = (import tenants).systemd.services.agent-hub-llm.serviceConfig.ExecStart;

  sevenVars = [
    "AGENT_HUB_MODELS"
    "AGENT_HUB_THREADS"
    "AGENT_HUB_CTX"
    "AGENT_HUB_LISTEN"
    "AGENT_HUB_BACKEND_PORT"
    "AGENT_HUB_SWAP_CONFIG"
    "AGENT_HUB_ASSETS"
  ];

  mkCase =
    {
      extraModules ? [ ],
      checks ? (_: [ ]),
    }:
    let
      evaluated = lib.evalModules {
        specialArgs = { inherit pkgs; };
        modules = [
          stubSystemd
          stubNix
          hostOptions
          hostFacts
          floxModule
          { homelab.flox.package = floxStub; }
          schema
          enforce
          resources
          environment
          tenants
          # Slices on, so `Slice` is a real answer and not an absent key.
          { homelab.enforce.slices = true; }
        ]
        ++ extraModules;
      };

      cfg = evaluated.config;

      failedAssertions = lib.filter (a: !a.assertion) cfg.assertions;
      failedChecks = lib.filter (c: !c.assertion) (checks cfg);
      failedMessages = map (a: a.message) failedAssertions ++ map (c: c.message) failedChecks;

      unit = cfg.systemd.services.agent-hub-llm;
    in
    {
      inherit (evaluated) config;
      ok = failedMessages == [ ];
      messages = failedMessages;

      summary = {
        execStart = unit.serviceConfig.ExecStart or null;
        slice = unit.serviceConfig.Slice or null;
        user = unit.serviceConfig.User or null;
        environment = unit.environment;
        dir = cfg.homelab.tenants.agent-hub.environment.dir;
      };

      checked =
        if failedMessages == [ ] then
          "OK: no failed assertions/checks"
        else
          throw (lib.concatStringsSep "\n" failedMessages);
    };

  on = extra: [ { homelab.tenants.agent-hub.environment.enable = true; } ] ++ extra;

  # What every enabled case must show, whatever else it checks: the unit
  # is still the contract's (slice, nice), still the module's (User,
  # Restart), and runs from the environment.
  keptByStub = cfg: [
    {
      assertion = (cfg.systemd.services.agent-hub-llm.serviceConfig.Slice or null) == "background.slice";
      message = ''
        the stub must not touch Slice=. resources.nix put agent-hub-llm in
        background.slice (mkOverride 90) from the tenant's tier, and the
        stub writes only ExecStart and the variables; a unit that changed
        slice when it changed ExecStart would leave the tier model behind.
      '';
    }
    {
      assertion = (cfg.systemd.services.agent-hub-llm.serviceConfig.User or null) == "agent-hub";
      message = "the stub must leave User= (the module's) in place";
    }
    {
      assertion = (cfg.systemd.services.agent-hub-llm.serviceConfig.Restart or null) == "on-failure";
      message = "the stub must leave Restart= (the module's) in place";
    }
  ];
in
{
  # enable = false, the default and what ac-box carries: the stub is
  # declared in full and contributes NOTHING -- the unit's ExecStart is the
  # module's, and it has no variables. This is the harness's copy of the
  # unchanged-drvPath proof.
  disabled = mkCase {
    checks = cfg: [
      {
        assertion = cfg.systemd.services.agent-hub-llm.serviceConfig.ExecStart == moduleExecStart;
        message = ''
          environment.enable = false: ExecStart must be exactly the
          module's. The stub is declared in the fixture with a command and
          seven variables; none of it may reach the unit until enable.
        '';
      }
      {
        assertion = cfg.systemd.services.agent-hub-llm.environment == { };
        message = "environment.enable = false: no variable may be set on the unit";
      }
      {
        assertion = (cfg.systemd.services.agent-hub-llm.serviceConfig.Slice or null) == "background.slice";
        message = "environment.enable = false: the slice is the contract's regardless";
      }
    ];
  };

  # enable = true: ExecStart begins with THE flox (homelab.flox.package,
  # from modules/platform/flox.nix) activating the tenant's dir, and the
  # seven variables plus FLOX_DISABLE_METRICS are on the unit.
  enabled = mkCase {
    extraModules = on [ ];
    checks =
      cfg:
      keptByStub cfg
      ++ [
        {
          assertion = lib.hasPrefix "${floxStub}/bin/flox activate -d /var/lib/agent-hub/env -- llama-swap " cfg.systemd.services.agent-hub-llm.serviceConfig.ExecStart;
          message = ''
            environment.enable = true: ExecStart must be
            `<homelab.flox.package>/bin/flox activate -d <dir> -- <command>`,
            with dir defaulted to <state dir>/env, got
            "${cfg.systemd.services.agent-hub-llm.serviceConfig.ExecStart}".
          '';
        }
        {
          assertion = lib.hasSuffix " -listen 127.0.0.1:8100" cfg.systemd.services.agent-hub-llm.serviceConfig.ExecStart;
          message = "environment.enable = true: the command's flags must follow `--` in order";
        }
        {
          assertion = lib.all (v: cfg.systemd.services.agent-hub-llm.environment ? ${v}) sevenVars;
          message = ''
            environment.enable = true: every one of the seven AGENT_HUB_*
            variables must be on the unit, so no default in the manifest's
            hook is load-bearing on the box.
          '';
        }
        {
          assertion = (cfg.systemd.services.agent-hub-llm.environment.FLOX_DISABLE_METRICS or null) == "true";
          message = "environment.enable = true: FLOX_DISABLE_METRICS must be set; a unit does not phone home";
        }
        {
          assertion = builtins.elem floxStub cfg.environment.systemPackages;
          message = "modules/platform/flox.nix must install homelab.flox.package";
        }
        {
          assertion = builtins.elem "https://cache.flox.dev" (cfg.nix.settings.substituters or [ ]);
          message = "modules/platform/flox.nix must add flox's cache, or the box compiles flox";
        }
      ];
  };

  # An explicit dir reaches ExecStart; the default is a default, not a
  # constant.
  enabledCustomDir = mkCase {
    extraModules = on [ { homelab.tenants.agent-hub.environment.dir = "/srv/agent-hub/checkout"; } ];
    checks = cfg: [
      {
        assertion = lib.hasPrefix "${floxStub}/bin/flox activate -d /srv/agent-hub/checkout -- " cfg.systemd.services.agent-hub-llm.serviceConfig.ExecStart;
        message = "environment.dir must reach `flox activate -d`";
      }
    ];
  };

  # A tenant with no declared state dir gets <homelab.host.paths.state>/
  # <tenant>/env -- the same derivation schema.nix's dirSet documents for
  # state itself. host.nix says /var/lib.
  dirDerivedFromHostPaths = mkCase {
    extraModules = [
      {
        homelab.tenants.arcade = {
          description = "Kid arcade hub";
          tier = "interactive";
          units = [ "arcade-freeciv.service" ];
        };
      }
    ];
    checks = cfg: [
      {
        assertion = cfg.homelab.tenants.arcade.environment.dir == "/var/lib/arcade/env";
        message = "environment.dir with no state.dirs must derive from homelab.host.paths.state/<tenant>, got ${toString cfg.homelab.tenants.arcade.environment.dir}";
      }
      {
        assertion = cfg.homelab.tenants.agent-hub.environment.dir == "/var/lib/agent-hub/env";
        message = "environment.dir with state.dirs must be <first state dir>/env";
      }
    ];
  };

  # The tenant itself disabled: environment.enable is moot, nothing is
  # emitted, the unit is the module's.
  tenantDisabled = mkCase {
    extraModules = on [ { homelab.tenants.agent-hub.enable = false; } ];
    checks = cfg: [
      {
        assertion = cfg.systemd.services.agent-hub-llm.serviceConfig.ExecStart == moduleExecStart;
        message = "a disabled tenant's stub must not run; ExecStart must be the module's";
      }
      {
        assertion = cfg.systemd.services.agent-hub-llm.environment == { };
        message = "a disabled tenant's stub must set no variables";
      }
    ];
  };

  # MUST THROW: a stub for a unit the contract does not list. resources.nix
  # assigns slices by `units`; this stub would run from the environment and
  # outside the tenant's tier -- the AGENTS.md hazard, seen from the other
  # side. The message must be environment.nix's own (check.nix requires a
  # non-empty `.messages` for a negative case).
  stubOutsideContract = mkCase {
    extraModules = on [
      {
        homelab.tenants.agent-hub.environment.units."agent-hub-extra.service" = {
          command = [ "true" ];
        };
      }
    ];
  };

  # MUST THROW: only a .service can be run from an environment.
  stubNotAService = mkCase {
    extraModules = on [
      {
        homelab.tenants.agent-hub.units = [ "agent-hub-llm.timer" ];
        homelab.tenants.agent-hub.environment.units."agent-hub-llm.timer" = {
          command = [ "true" ];
        };
      }
    ];
  };

  expected = {
    disabled = true;
    enabled = true;
    enabledCustomDir = true;
    dirDerivedFromHostPaths = true;
    tenantDisabled = true;
    stubOutsideContract = false;
    stubNotAService = false;
  };
}
