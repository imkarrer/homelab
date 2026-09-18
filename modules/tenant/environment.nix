# The unit stub for a flox tenant (ADR 0009). Consumes
# homelab.tenants.<name>.environment (schema.nix) and homelab.flox.package
# (modules/platform/flox.nix) to produce, for every stub unit of every
# enabled tenant:
#
#   systemd.services.<unit>                           (the whole unit, see below)
#   assertions                                        (every stub is a contract unit)
#
# and NOTHING for a tenant with no stub declared. That is load-bearing the
# same way modules/deploy's inert default is: a host that declares no
# environment gets no key at all from this file (tests/eval-environment.nix's
# `dirDerivedFromHostPaths` case keeps a tenant without a stub unit-less).
#
# THE STUB IS THE WHOLE UNIT (homelab-158.11). Until then a tenant's NixOS
# module (agent-hub's modules/agent-hub.nix, home-arcade's
# modules/arcade-hub.nix) declared the unit and this file mkForce'd only
# ExecStart and the variables onto it. Those modules have left the closure;
# what they supplied -- Description=, User=/Group=, WorkingDirectory=,
# Restart=/RestartSec=, TimeoutStopSec=, After=/Wants=, WantedBy=, and for
# mindustry the StandardInputText= lines -- is now the stub's skeleton
# fields (schema.nix, environmentUnit), rendered here. Two things are still
# not this file's: Slice= and Nice= are resources.nix's from the tenant's
# tier (the ladder in its header), and a host's own facts about its own
# unit (agent-hub-llm's AllowedCPUs= and NUMA policy) are a plain
# systemd.services definition in the host's configuration, merged by the
# module system. The proof that the move changed nothing on the box was
# every affected unit's `systemd.units.<u>.text` equal between the closure
# with the modules and the closure without (homelab-158.11's handoff).
#
# WHAT `enable` DECIDES: only what the unit executes. On, ExecStart is the
# activation of <dir> and the variables are set. Off -- the default, and
# the state a stub is landed in first, so the pull unit (environment-pull.nix)
# can put the environment at <dir> and warm it before anything runs from it
# -- ExecStart is a placeholder that exits 1 naming the flag. Both retired
# modules made that same choice for their skeletons: a declared unit that
# is not yet switched on fails loudly in the journal (Restart=on-failure
# retries it into systemd's start limit, then it sits failed), never
# serves some other way, and never leaves resources.nix's Slice= on a
# unit with no process behind it. Off is also the rollback for a tenant
# whose environment has gone bad: the unit stops running it, and the
# checkout stays.
#
# Plain priority for every key. There is no upstream definition to
# out-argue any more (the mkForce this file carried existed for the
# module's ExecStart), so a second definition of ExecStart from anywhere
# is a conflict at evaluation -- loud, which is right -- and a host that
# wants a key different from the stub's says so with mkForce on its own
# rung (resources.nix: upstream 100, contract 90, host 50).
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
  inherit (lib) mkDefault mkIf types;

  hostPaths = config.homelab.host.paths;

  flox = config.homelab.flox.package;

  # Every enabled tenant with a stub declared -- enable on or off, since
  # the unit exists either way (header).
  declaringTenants = lib.filterAttrs (
    _: t: t.enable && t.environment.units != { }
  ) config.homelab.tenants;

  # One entry per stub unit, carrying its tenant so the assertion and the
  # ExecStart can both name their source.
  stubs = lib.flatten (
    lib.mapAttrsToList (
      tenantName: t:
      lib.mapAttrsToList (unit: stub: {
        inherit tenantName unit stub;
        dir = t.environment.dir;
        kind = t.environment.source.kind;
        on = t.environment.enable;
        inContract = builtins.elem unit t.units;
      }) t.environment.units
    ) declaringTenants
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

  # enable = false: refuse, and say which flag. Never `true` (a unit
  # "active" with nothing on its port), never a server from somewhere else.
  placeholder =
    s:
    pkgs.writeShellScript "${lib.removeSuffix ".service" s.unit}-unstubbed" ''
      echo "${s.unit}: homelab.tenants.${s.tenantName}.environment.enable is false -- this unit runs from the tenant's flox environment at ${toString s.dir} and nothing else (homelab ADR 0009); it is declared but not switched on" >&2
      exit 1
    '';

  # kind = tree: the activation itself, one line. kind = floxhub: the
  # wrapper, which refuses to guess a generation. `read` is a builtin, so
  # the wrapper needs nothing on PATH before flox. The wrapper is handed to
  # serviceConfig as the DERIVATION, not its path: NixOS renders any value
  # with toString (systemd-lib.nix toOption), so the unit file is the same
  # either way, and tests/eval-environment.nix can read the wrapper's
  # `.text` at evaluation instead of building it.
  execStart =
    s:
    if !s.on then
      placeholder s
    else if s.kind == "floxhub" then
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

  # The derived defaults schema.nix leaves null (its header: vocabulary
  # only, the consumer derives).
  user = s: if s.stub.user != null then s.stub.user else s.tenantName;
  group = s: if s.stub.group != null then s.stub.group else user s;
  description =
    s:
    if s.stub.description != null then
      s.stub.description
    else
      "${s.tenantName}: ${lib.removeSuffix ".service" s.unit} (from its flox environment)";

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
        description = description s;
        inherit (s.stub) after wants wantedBy;
        serviceConfig = {
          User = user s;
          Group = group s;
          ExecStart = execStart s;
          Restart = s.stub.restart;
          RestartSec = s.stub.restartSec;
        }
        // lib.optionalAttrs (s.stub.workingDirectory != null) {
          WorkingDirectory = toString s.stub.workingDirectory;
        }
        // lib.optionalAttrs (s.stub.timeoutStopSec != null) {
          TimeoutStopSec = s.stub.timeoutStopSec;
        }
        // lib.optionalAttrs (s.on && s.stub.stdin != [ ]) {
          StandardInputText = s.stub.stdin;
        };
        # The variables only with the stub on: off, nothing is running that
        # would read them, and a placeholder with the host's facts in its
        # environment reads as a unit that meant to run.
        environment = lib.optionalAttrs s.on (
          s.stub.environment
          // {
            FLOX_DISABLE_METRICS = "true";
            # flox 1.16.0 prints "! You are not logged in to FloxHub" once per
            # start for a logged-out user (every tenant user is); a unit has no
            # login to offer, so the notice is noise in the journal.
            FLOX_AUTH_NOTIFICATIONS = "false";
          }
        );
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

  # mkIf on the whole block: with no stub declared this contributes no key
  # at all to systemd.services, not an empty override -- the difference
  # between "drvPath unchanged" and "drvPath unchanged, probably".
  config = mkIf (stubs != [ ]) {
    assertions =
      map (s: {
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
