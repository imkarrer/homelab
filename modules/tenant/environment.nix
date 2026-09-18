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
# A FLOXHUB TENANT'S STUB IS PINNED TO A GENERATION (homelab-158.5). With
# `environment.source.kind = "floxhub"` the environment at <dir> is flox's
# own tracking checkout of owner/name, and "which generation runs" is a
# run-time fact the pull unit decides -- so the ExecStart is a wrapper that
# reads the generation the pull unit pinned (one line of digits in
# <homelab.environments.stateDir>/pinned-environment-<tenant>, written
# after the warm and BEFORE the restart, which is what lets the restart
# activate the new generation while the applied record still waits on the
# restart's outcome) and execs `flox activate -d <dir> -g <N> -- <command>`.
# Pinned rather than the checkout's live generation because a tracking
# checkout's live links follow whatever `flox pull` last fetched, and a
# pull by hand must not move what the unit runs; `-g N` activates the
# generation's own links (.flox/run/<system>.<name>.genN-run) instead. It
# is offline the same way (docs/flox-findings.md 3: ~150 ms) as long as
# the store paths AND the tenant user's floxmeta clone
# ($HOME/.local/share/flox/meta/<owner>) are present -- both the pull's
# doing. No pin file, or a malformed one, is a refusal (exit 1): the
# first-switch order in environment-pull.nix's header is what keeps that
# from being reached.
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
{
  config,
  lib,
  pkgs,
  ...
}:

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
        kind = t.environment.source.kind;
        inContract = builtins.elem unit t.units;
      }) t.environment.units
    ) enabledTenants
  );

  # The pin the pull unit writes for a floxhub tenant (header). The path is
  # environment-pull.nix's option, read lazily: a host that imports only
  # this module and declares no floxhub tenant never evaluates it.
  pinFile =
    tenantName:
    if config.homelab ? environments then
      "${toString config.homelab.environments.stateDir}/pinned-environment-${tenantName}"
    else
      throw "homelab.tenants.${tenantName}.environment.source.kind = \"floxhub\" needs modules/tenant/environment-pull.nix imported beside environment.nix: it writes the pin this stub reads.";

  activate = s: [
    "${flox}/bin/flox"
    "activate"
    "-d"
    (toString s.dir)
  ];

  # kind = tree: the activation itself, one line. kind = floxhub: the
  # wrapper, which refuses to guess a generation. `read` is a builtin, so
  # the wrapper needs nothing on PATH before flox. The wrapper is handed to
  # serviceConfig as the DERIVATION, not its path: NixOS renders any value
  # with toString (systemd-lib.nix toOption), so the unit file is the same
  # either way, and tests/eval-environment.nix can read the wrapper's
  # `.text` at evaluation instead of building it.
  execStart =
    s:
    if s.kind == "floxhub" then
      (pkgs.writeShellScript "${lib.removeSuffix ".service" s.unit}-activate" ''
        set -eu
        pin=${lib.escapeShellArg (pinFile s.tenantName)}
        gen=""
        if [ -r "$pin" ]; then
          read -r gen < "$pin" || true
        fi
        case "$gen" in
          "" | *[!0-9]* | 0*)
            echo "${s.unit}: no generation pinned at $pin (${s.tenantName}-environment-pull has not applied one) -- refusing to activate an unpinned environment" >&2
            exit 1
            ;;
        esac
        exec ${lib.escapeShellArgs (activate s)} -g "$gen" -- ${lib.escapeShellArgs s.stub.command}
      '')
    else
      lib.escapeShellArgs (activate s ++ [ "--" ] ++ s.stub.command);

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
        serviceConfig.ExecStart = mkForce (execStart s);
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
