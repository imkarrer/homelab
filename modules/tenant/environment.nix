# The unit stub for a flox tenant (ADR 0009). Consumes
# homelab.tenants.<name>.environment (schema.nix) and homelab.flox.package
# (modules/platform/flox.nix) to produce, for every stub unit of every
# enabled tenant whose environment is enabled:
#
#   systemd.services.<unit>.serviceConfig.ExecStart   (mkForce, see below)
#   systemd.services.<unit>.environment               (the tenant's host facts)
#   assertions                                        (every stub is a contract unit)
#
# and NOTHING for a tenant whose environment.enable is false -- the default.
# That is load-bearing the same way modules/deploy's inert default is: the
# stub is imported into the closure before any tenant runs from it, and the
# proof that importing changed nothing is an unchanged toplevel drvPath
# (homelab-158.2 recorded it; tests/eval-environment.nix's `disabled` case
# keeps it).
#
# WHAT THE STUB REPLACES, AND WHAT IT KEEPS. Only ExecStart and the
# variables. The unit's name (README: never renamed), its Slice= and Nice=
# from resources.nix, restartIfChanged, User=/Group=, After=/Wants=,
# Restart=, TimeoutStopSec=, the host's own AllowedCPUs/NUMAPolicy -- all
# of it stays exactly what the NixOS module and hosts/<name>/*.nix made it,
# because this file writes to none of those keys. Step 1 of the ADR runs
# the tenant's module and the stub SIDE BY SIDE: the module still declares
# the unit, the stub only redirects what it executes. When the module goes,
# the stub becomes the whole unit and this file grows the fifteen lines the
# ADR promises; not before.
#
# mkForce, and where that sits on the ladder in resources.nix (upstream
# 100, contract 90, host 50). The stub is declared BY the host -- the
# values in hosts/ac-box/configuration.nix are the host's facts about its
# own unit -- so it takes the host's rung. A tenant module's ExecStart is
# the upstream default the ADR is retiring; there is no third party that
# should be able to out-argue "this unit runs from its environment" short
# of turning `enable` off, which is the lever.
#
# THE UNIT NEVER FETCHES. `flox activate -d <dir>` against an environment
# that has been activated once online is offline and ~80 ms; against one
# that has only a lock it reaches GitHub and fails without a network
# (docs/flox-findings.md section 1). Putting the environment at <dir> and
# activating it there once is the pull unit's job (homelab-158.3), before
# this unit is restarted. Nothing here would make a restart at 03:00 depend
# on flox.dev, and nothing here should.
#
# FLOX_DISABLE_METRICS: activation forks a metrics POST otherwise. It fails
# soft, but a production unit has no business phoning home, and this is the
# same variable hub-gates.sh sets for the CI reproduction.
#
# environment.dir's DEFAULT is derived here, not in schema.nix. The schema
# says `null = derived` and stays config-free (vocabulary only, its header);
# this file, which already reads the host, supplies the value with mkDefault
# at the submodule level -- `<first state dir>/env`, else
# `<homelab.host.paths.state>/<tenant>/env`, the same derivation dirSet
# documents for the state dir itself. A submodule-level definition rather
# than a `homelab.tenants = mapAttrs ...` over config.homelab.tenants,
# because the latter derives the attribute NAMES from the option being
# defined and is an infinite recursion. Unconditional on purpose: the
# resolved path must be readable (hosts/ac-box/configuration.nix builds the
# stub's -config path from it) whether or not the stub is on, and an option
# value on homelab.tenants reaches nothing in the closure by itself.
{ config, lib, ... }:

let
  inherit (lib) mkDefault mkForce mkIf types;

  hostPaths = config.homelab.host.paths;

  flox = config.homelab.flox.package;

  enabledTenants = lib.filterAttrs (_: t: t.enable && t.environment.enable) config.homelab.tenants;

  # One entry per stub unit, carrying its tenant so the assertion and the
  # ExecStart can both name their source.
  stubs = lib.flatten (
    lib.mapAttrsToList (
      tenantName: t:
      lib.mapAttrsToList (unit: stub: {
        inherit tenantName unit stub;
        dir = t.environment.dir;
        inContract = builtins.elem unit t.units;
      }) t.environment.units
    ) enabledTenants
  );

  # systemd.services is keyed by BARE name; the contract spells units with
  # their suffix (resources.nix has the history of getting this wrong:
  # phantom *.service.service units, and a slice guarantee that was inert).
  # Only .service units run a process, so only those can be stubs; the
  # assertion below rejects anything else rather than silently keying a
  # unit systemd would never start.
  services = lib.listToAttrs (
    map (
      s:
      lib.nameValuePair (lib.removeSuffix ".service" s.unit) {
        serviceConfig.ExecStart = mkForce (
          lib.escapeShellArgs (
            [
              "${flox}/bin/flox"
              "activate"
              "-d"
              (toString s.dir)
              "--"
            ]
            ++ s.stub.command
          )
        );
        environment = s.stub.environment // {
          FLOX_DISABLE_METRICS = "true";
        };
      }
    ) (builtins.filter (s: lib.hasSuffix ".service" s.unit) stubs)
  );
in
{
  options.homelab.tenants = lib.mkOption {
    type = types.attrsOf (
      types.submodule (
        { name, config, ... }:
        {
          config.environment.dir = mkDefault (
            if config.state.dirs != [ ] then
              "${toString (lib.head config.state.dirs)}/env"
            else
              "${toString hostPaths.state}/${name}/env"
          );
        }
      )
    );
  };

  # mkIf on the whole block: with no enabled environment this contributes
  # no key at all to systemd.services, not an empty override -- the
  # difference between "drvPath unchanged" and "drvPath unchanged, probably".
  config = mkIf (stubs != [ ]) {
    assertions = map (s: {
      assertion = s.inContract;
      message = ''
        homelab.tenants.${s.tenantName}.environment.units."${s.unit}" is a
        stub for a unit that homelab.tenants.${s.tenantName}.units does not
        name. The contract assigns slices by that list; a stub outside it
        would run from the environment but outside the tenant's tier.
        Add "${s.unit}" to units, or remove the stub.
      '';
    }) stubs
    ++ map (s: {
      assertion = lib.hasSuffix ".service" s.unit;
      message = ''
        homelab.tenants.${s.tenantName}.environment.units."${s.unit}": only a
        .service unit runs a process, so only a .service can be run from an
        environment. Spell the name with its suffix, exactly as `units` does.
      '';
    }) stubs;

    systemd.services = services;
  };
}
