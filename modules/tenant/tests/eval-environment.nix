# Eval harness for modules/tenant/environment.nix -- ADR 0009's unit stub --
# and modules/tenant/environment-pull.nix, the pull unit beside it.
#
# What it is for. The stub is the whole unit (homelab-158.11): its
# contract is "declared: the unit exists with the skeleton the stub spells
# and schema.nix defaults, in the slice the contract gives it; off: its
# ExecStart refuses, naming the flag, and no variable is set; on: ExecStart
# is the activation and the variables are on the unit, and nothing else
# changes". `nix flake check` on the toplevel says nothing about which keys
# a module touched. So: the same fixture, once with the stub off and once
# on, and the exact keys compared -- plus the two things the module must
# REJECT (a stub outside the tenant's `units`, a stub that is not a
# .service), which no real host has.
#
# The pull unit's contract is the first-switch order in its header: it
# EXISTS whenever a stub is declared (enable on or off), it is a oneshot in
# the tenant's slice with the path unit on the pending file and the timer
# for retries, it restarts the stub only when enable is on, and it refuses
# a tree the registry does not carry. The restart decision is baked into
# the script at evaluation time, so the script text is read the way
# modules/deploy/tests/eval.nix reads homelab-deploy's.
#
# Usage:
#   nix --extra-experimental-features "nix-command flakes" eval \
#     -f modules/tenant/tests/eval-environment.nix enabled.summary --json
#
# Same shape as the other harnesses: pinned lib/pkgs, stubs for the option
# surface the modules write to, the REAL schema/enforce/resources/
# environment/environment-pull modules and the REAL modules/platform/
# flox.nix (with a fake package for homelab.flox.package, so the ExecStart
# prefix under test is a path this harness chose and not whatever flox
# happens to be), one attribute per case with `.checked` and `.messages`,
# and an `expected` map check.nix reads.
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
  environmentPull = ../environment-pull.nix;
  stubSystemd = ./stub-systemd.nix;
  stubNix = ./stub-nix.nix;
  stubEtc = ./stub-etc.nix;
  tenants = ./fixtures/environment-tenants.nix;
  # A registry with one tree that has a remote and one that has none, so
  # both refusals are reachable; the real hub/repos.psv has no bare row.
  registry = ./fixtures/environment-registry.psv;

  # Never built; only its store path is read. A runCommand rather than a
  # real package so the prefix asserted below is unmistakably the
  # harness's and could not be satisfied by a flox from anywhere else.
  floxStub = pkgs.runCommand "flox-stub" { } "mkdir -p $out/bin; touch $out/bin/flox";

  # The "off" answer: environment.nix's placeholder, a derivation whose
  # text names the flag and exits 1. Read at evaluation, never built;
  # contexts dropped because lib.hasInfix is a builtins.match.
  noCtx = builtins.unsafeDiscardStringContext;
  isPlaceholder =
    unit: tenant: v:
    lib.isDerivation v
    && lib.hasSuffix "-unstubbed" v.name
    && lib.hasInfix "homelab.tenants.${tenant}.environment.enable is false" (noCtx v.text)
    && lib.hasInfix "exit 1" (noCtx v.text);

  # The pull script's text, through the module's own readOnly `pull` map;
  # the remote, the owner and the restart set are decided at evaluation
  # and only visible here.
  pullScript = cfg: name: (cfg.homelab.environments.pull.${name} or null);
  pullText = cfg: name: (pullScript cfg name).text or "";
  pullHas = cfg: name: needle: lib.hasInfix needle (pullText cfg name);

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
          stubEtc
          hostOptions
          hostFacts
          floxModule
          { homelab.flox.package = floxStub; }
          schema
          enforce
          resources
          environment
          environmentPull
          { homelab.environments.registry = registry; }
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
      pull = cfg.systemd.services.agent-hub-environment-pull or null;
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
        pull = {
          exists = pull != null;
          serviceConfig = if pull == null then null else pull.serviceConfig;
          restartIfChanged = if pull == null then null else pull.restartIfChanged;
          pathConfig = (cfg.systemd.paths.agent-hub-environment-pull or { }).pathConfig or null;
          timerConfig = (cfg.systemd.timers.agent-hub-environment-pull or { }).timerConfig or null;
          restartUnitsLine = lib.findFirst (lib.hasPrefix "restartUnits=") "<none>" (lib.splitString "\n" (pullText cfg "agent-hub"));
          remoteLine = lib.findFirst (lib.hasPrefix "remote=") "<none>" (lib.splitString "\n" (pullText cfg "agent-hub"));
          environmentsJson =
            if cfg.environment.etc ? "homelab/environments.json" then
              builtins.fromJSON cfg.environment.etc."homelab/environments.json".text
            else
              null;
        };
      };

      checked =
        if failedMessages == [ ] then
          "OK: no failed assertions/checks"
        else
          throw (lib.concatStringsSep "\n" failedMessages);
    };

  on = extra: [ { homelab.tenants.agent-hub.environment.enable = true; } ] ++ extra;

  # What every enabled case must show, whatever else it checks: the unit
  # is still the contract's (slice, nice), its skeleton is the stub's
  # (User, Restart -- the retired module's values, now schema.nix's
  # defaults), and it runs from the environment.
  keptByStub = cfg: [
    {
      assertion = (cfg.systemd.services.agent-hub-llm.serviceConfig.Slice or null) == "background.slice";
      message = ''
        the stub must not touch Slice=. resources.nix put agent-hub-llm in
        background.slice (mkOverride 90) from the tenant's tier; the stub
        renders every other key of the unit and none of the slice's, so a
        unit that changed slice when it changed ExecStart would leave the
        tier model behind.
      '';
    }
    {
      assertion = (cfg.systemd.services.agent-hub-llm.serviceConfig.User or null) == "agent-hub";
      message = "User= must be the tenant's name (schema.nix's derived default)";
    }
    {
      assertion = (cfg.systemd.services.agent-hub-llm.serviceConfig.Restart or null) == "on-failure";
      message = "Restart= must be on-failure (schema.nix's default, the retired module's value)";
    }
  ];
  # What the pull unit must look like whenever a stub is DECLARED, enable
  # on or off: the shape environment-pull.nix's header promises. `restart`
  # is the one thing enable changes -- the units the script bounces.
  pullShape =
    cfg: restart:
    let
      pull = cfg.systemd.services.agent-hub-environment-pull or null;
      pathUnit = cfg.systemd.paths.agent-hub-environment-pull or null;
      timer = cfg.systemd.timers.agent-hub-environment-pull or null;
      text = pullText cfg "agent-hub";
      envs = builtins.fromJSON cfg.environment.etc."homelab/environments.json".text;
    in
    [
      {
        assertion = pull != null;
        message = "a tenant with a stub declared must have agent-hub-environment-pull.service, enable on or off (the first-switch order)";
      }
      {
        assertion = (pull.serviceConfig.Type or null) == "oneshot";
        message = "the pull unit must be a oneshot";
      }
      {
        assertion = (pull.serviceConfig.ExecStart or null) == lib.getExe (pullScript cfg "agent-hub");
        message = "the pull unit must run homelab.environments.pull.agent-hub, the script the harness reads";
      }
      {
        assertion = (pull.serviceConfig.Slice or null) == "background.slice";
        message = "the pull runs in the tenant's slice: a clone and a warm are the tenant's CPU, got ${toString (pull.serviceConfig.Slice or null)}";
      }
      {
        assertion = (pull.restartIfChanged or null) == false;
        message = "the pull unit must be restartIfChanged = false (ADR 0006: a switch must not kill it mid-clone)";
      }
      {
        assertion = pathUnit != null && (pathUnit.pathConfig.PathChanged or null) == "/var/lib/homelab/pending-environment-agent-hub.json";
        message = "the path unit must watch pending-environment-agent-hub.json under homelab.environments.stateDir";
      }
      {
        assertion = (pathUnit.pathConfig.Unit or null) == "agent-hub-environment-pull.service";
        message = "the path unit must trigger the pull service";
      }
      {
        assertion = timer != null && (timer.timerConfig.OnUnitActiveSec or null) == "10min" && (timer.timerConfig.OnBootSec or null) == "10min";
        message = "the retry timer must fire every retryInterval and after boot";
      }
      {
        assertion = lib.hasInfix "\nremote=https://github.com/imkarrer/agent-hub\n" text;
        message = "the script must clone the registry's remote over https, got ${lib.findFirst (lib.hasPrefix "remote=") "<none>" (lib.splitString "\n" text)}";
      }
      {
        assertion = lib.hasInfix "\nregistryRemote=git@github.com:imkarrer/agent-hub\n" text;
        message = "the script must carry the registry's remote verbatim, to refuse a record for another tree";
      }
      {
        assertion = lib.hasInfix "\nuser=agent-hub\n" text;
        message = "the checkout's owner must be the stub unit's User=";
      }
      {
        assertion = lib.hasInfix "\nrestartUnits=${lib.escapeShellArg (lib.concatStringsSep " " restart)}\n" text;
        message = "the restart set must be ${builtins.toJSON restart}, got ${lib.findFirst (lib.hasPrefix "restartUnits=") "<none>" (lib.splitString "\n" text)}";
      }
      {
        # Equality on the line rather than hasInfix: the needle carries a
        # store-path context, and lib.hasInfix is a builtins.match, which
        # refuses strings with context.
        assertion =
          lib.hasInfix "\"$flox\" activate -d \"$dir\" -- true" text
          && lib.findFirst (lib.hasPrefix "flox=") "" (lib.splitString "\n" text) == "flox=${floxStub}/bin/flox";
        message = "the script must activate once with homelab.flox.package -- the same flox the stub runs";
      }
      {
        assertion = lib.hasInfix "\ndir=/var/lib/agent-hub/env\n" text;
        message = "the pull's dir must be the stub's environment.dir";
      }
      {
        # Split on the realise line: the activation must not appear before it.
        assertion =
          lib.hasInfix "nix-store --realise --max-jobs 0" text
          && !(lib.hasInfix "activate -d \"$dir\" -- true" (lib.head (lib.splitString "nix-store --realise --max-jobs 0" text)));
        message = "the warm must substitute-only every locked path BEFORE the activation, never compile on the box";
      }
      {
        assertion = builtins.elem "d /var/lib/homelab 0755 root root -" cfg.systemd.tmpfiles.rules;
        message = "the state directory must be created by tmpfiles so the path unit does not arm on a missing directory";
      }
      {
        assertion = envs.environments.agent-hub.enable == (restart != [ ]) && envs.environments.agent-hub.units == [ "agent-hub-llm.service" ];
        message = "/etc/homelab/environments.json must say whether the stub is on and which units it covers";
      }
    ];
  # ---------------------------------------------------------------------
  # source.kind = floxhub (homelab-158.5): arcade, two stubs, a generation
  # of imkarrer/arcade as the deploy unit. fixtures/environment-floxhub-
  # tenants.nix is the host's declaration; agent-hub (tree kind) stays in
  # every case beside it, so "the tree kind is unchanged" is asserted by
  # the same evaluation rather than assumed.
  # ---------------------------------------------------------------------
  floxhubFixture = ./fixtures/environment-floxhub-tenants.nix;
  arcadeOn = extra: [
    floxhubFixture
    { homelab.tenants.arcade.environment.enable = true; }
  ]
  ++ extra;

  # What the floxhub pull must look like, enable on or off -- the header of
  # environment-pull.nix, "KIND = FLOXHUB".
  floxhubPullShape =
    cfg: restart:
    let
      pull = cfg.systemd.services.arcade-environment-pull or null;
      text = pullText cfg "arcade";
      envs = builtins.fromJSON cfg.environment.etc."homelab/environments.json".text;
      beforePull = lib.head (lib.splitString "\"$flox\" pull -d" text);
    in
    [
      {
        assertion = pull != null && (pull.serviceConfig.Type or null) == "oneshot" && (pull.serviceConfig.Slice or null) == "interactive.slice";
        message = "arcade must have arcade-environment-pull.service, a oneshot in interactive.slice, enable on or off";
      }
      {
        assertion = lib.hasInfix "\nkind=floxhub\n" text && lib.hasInfix "\nsourceEnv=imkarrer/arcade\n" text;
        message = "the script must carry the source kind and the FloxHub environment it was built for, to refuse any other record";
      }
      {
        assertion = lib.hasInfix "\nregistryRemote=''\n" text && lib.hasInfix "\nremote=''\n" text;
        message = "a floxhub tenant clones no tree: the registry remote must be empty (tree defaults to the tenant's name, which the registry does not carry, and that must NOT be an error for this kind)";
      }
      {
        assertion = lib.hasInfix "\npinned=/var/lib/homelab/pinned-environment-arcade\n" text && lib.hasInfix "\ndir=/var/lib/arcade/env\n" text && lib.hasInfix "\nuser=arcade\n" text;
        message = "the pin, the dir and the owner must be the stub's";
      }
      {
        assertion = lib.hasInfix "nix-store --realise --max-jobs 0" beforePull && lib.hasInfix "api.flox.dev/git/$owner/floxmeta" beforePull;
        message = "the substitute-only guard (fed from FloxHub's floxmeta record) must run BEFORE `flox pull`, which builds";
      }
      {
        assertion = lib.hasInfix "\"$flox\" activate -d \"$dir\" -g \"$gen\" -- true" text;
        message = "the warm must be the pinned activation, the stub's own command";
      }
      {
        assertion = !(lib.hasInfix "FLOXHUB_TOKEN" text) && !(lib.hasInfix "flox auth" text) && !(lib.hasInfix "flox gc" text) && !(lib.hasInfix "activate -r" text);
        message = "no credential, no `flox auth`, no `flox gc`, no `activate -r` in the pull unit";
      }
      {
        assertion = !(lib.hasInfix "pull -g" text) && !(lib.hasInfix "--copy" text);
        message = "the pull must be a tracking pull, never `pull -g N --copy` (a detached path environment with no record of owner or generation)";
      }
      {
        assertion = lib.hasInfix "\nrestartUnits=${lib.escapeShellArg (lib.concatStringsSep " " restart)}\n" text;
        message = "the restart set must be ${builtins.toJSON restart}";
      }
      {
        assertion =
          envs.environments.arcade.source == "floxhub"
          && envs.environments.arcade.env == "imkarrer/arcade"
          && envs.environments.arcade.remote == null
          && envs.environments.arcade.pinned == "/var/lib/homelab/pinned-environment-arcade"
          && envs.environments.arcade.enable == (restart != [ ])
          && envs.environments.agent-hub.source == "tree"
          && envs.environments.agent-hub.env == null;
        message = "/etc/homelab/environments.json must carry the source kind and env per tenant, flat, with agent-hub still the tree kind";
      }
      {
        assertion = (cfg.systemd.paths.arcade-environment-pull.pathConfig.PathChanged or null) == "/var/lib/homelab/pending-environment-arcade.json";
        message = "the path unit must watch pending-environment-arcade.json";
      }
    ];

in
{
  # enable = false, the default and what ac-box carries: the stub is
  # declared in full and contributes NOTHING -- the unit's ExecStart is the
  # module's, and it has no variables. This is the harness's copy of the
  # unchanged-drvPath proof. The pull unit, by contrast, IS present: it
  # keeps the checkout warm so the flip to enable finds it, and restarts
  # nothing.
  disabled = mkCase {
    checks =
      cfg:
      pullShape cfg [ ]
      ++ [
        {
          assertion = isPlaceholder "agent-hub-llm.service" "agent-hub" cfg.systemd.services.agent-hub-llm.serviceConfig.ExecStart;
          message = ''
            environment.enable = false: ExecStart must be the placeholder
            that exits 1 naming the flag. The stub is declared in the
            fixture with a command and seven variables; none of it may
            reach the unit until enable, and the unit must not be a
            phantom either.
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
        {
          assertion = cfg.systemd.services.agent-hub-llm.restartIfChanged;
          message = "environment.enable = false: the pull module must not touch the stub unit's own keys";
        }
        {
          # The skeleton is there with the stub off: that is what makes a
          # declared-but-not-switched-on unit a failed unit with a slice
          # and a user, rather than nothing.
          assertion =
            cfg.systemd.services.agent-hub-llm.description == "agent-hub model server: llama-swap over 6 models (LAN only)"
            && (cfg.systemd.services.agent-hub-llm.serviceConfig.User or null) == "agent-hub"
            && (cfg.systemd.services.agent-hub-llm.serviceConfig.TimeoutStopSec or null) == 90
            && cfg.systemd.services.agent-hub-llm.wantedBy == [ "multi-user.target" ];
          message = "environment.enable = false: the skeleton (description, User, TimeoutStopSec, WantedBy) is rendered regardless";
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
      ++ pullShape cfg [ "agent-hub-llm.service" ]
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
      {
        assertion = pullHas cfg "agent-hub" "\ndir=/srv/agent-hub/checkout\n";
        message = "environment.dir must reach the pull's checkout too -- one resolved value (environment.nix's mkDefault), two consumers";
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
      {
        assertion = !(cfg.systemd.services ? arcade-environment-pull) && !(cfg.homelab.environments.pull ? arcade);
        message = "a tenant with no stub declared has no environment to pull: no arcade-environment-pull unit";
      }
    ];
  };

  # The tenant itself disabled: environment.enable is moot, nothing is
  # emitted, the unit is the module's.
  tenantDisabled = mkCase {
    extraModules = on [ { homelab.tenants.agent-hub.enable = false; } ];
    checks = cfg: [
      {
        assertion = !(cfg.systemd.services ? agent-hub-llm);
        message = "a disabled tenant's stub must emit no unit at all (and resources.nix no slice for it)";
      }
      {
        assertion = !(cfg.systemd.services ? agent-hub-environment-pull) && !(cfg.environment.etc ? "homelab/environments.json");
        message = "a disabled tenant has no pull unit and no entry to describe";
      }
    ];
  };

  # MUST THROW: a tree the registry does not carry. The pull clones the
  # registry's remote; with no row there is nothing to clone and the
  # module says so at evaluation rather than at the first firing.
  treeNotInRegistry = mkCase {
    extraModules = [ { homelab.tenants.agent-hub.environment.tree = "no-such-tree"; } ];
  };

  # MUST THROW: a registry row with an empty remote column. The fixture
  # registry has one; hub/repos.psv does not, which is why this needs the
  # fixture.
  treeWithoutRemote = mkCase {
    extraModules = [ { homelab.tenants.agent-hub.environment.tree = "bare"; } ];
  };

  # The real hub/repos.psv, not the fixture: agent-hub's default tree
  # resolves against the registry the box is built with. If a rename there
  # ever orphans the tenant, this is the case that says so.
  realRegistry = mkCase {
    extraModules = [ { homelab.environments.registry = lib.mkForce ../../../hub/repos.psv; } ];
    checks = cfg: [
      {
        assertion = pullHas cfg "agent-hub" "\nremote=https://github.com/imkarrer/agent-hub\n";
        message = "hub/repos.psv must resolve agent-hub to github.com/imkarrer/agent-hub";
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

  # The host's state: declared, enable off. Both game units are byte-for-
  # byte the module's, the pull unit exists and restarts nothing, and
  # agent-hub is untouched.
  floxhubDisabled = mkCase {
    extraModules = [ floxhubFixture ];
    checks =
      cfg:
      floxhubPullShape cfg [ ]
      ++ pullShape cfg [ ]
      ++ [
        {
          assertion =
            isPlaceholder "arcade-freeciv.service" "arcade" cfg.systemd.services.arcade-freeciv.serviceConfig.ExecStart
            && isPlaceholder "arcade-mindustry.service" "arcade" cfg.systemd.services.arcade-mindustry.serviceConfig.ExecStart
            && cfg.systemd.services.arcade-freeciv.environment == { }
            && cfg.systemd.services.arcade-mindustry.environment == { }
            && !(cfg.systemd.services.arcade-mindustry.serviceConfig ? StandardInputText);
          message = "enable = false: arcade-freeciv and arcade-mindustry must refuse -- the placeholder ExecStart, no variable, no stdin";
        }
        {
          assertion = (cfg.systemd.services.arcade-freeciv.serviceConfig.Slice or null) == "interactive.slice";
          message = "the slice is the contract's regardless";
        }
      ];
  };

  # enable = true: each stub's ExecStart is the wrapper that reads the pin
  # and execs `flox activate -d <dir> -g <N> -- <command>`; the variables
  # are on the unit; User/Restart/Slice untouched.
  floxhubEnabled = mkCase {
    extraModules = arcadeOn [ ];
    checks =
      cfg:
      let
        freeciv = cfg.systemd.services.arcade-freeciv;
        mindustry = cfg.systemd.services.arcade-mindustry;
        # The wrapper is the derivation itself (environment.nix says why);
        # its text is read at evaluation, never built. Contexts dropped on
        # both sides because lib.hasInfix is a builtins.match, which
        # refuses a needle with a store-path context.
        wrapperText = u: noCtx cfg.systemd.services.${u}.serviceConfig.ExecStart.text;
        freecivWrapper = wrapperText "arcade-freeciv";
        mindustryWrapper = wrapperText "arcade-mindustry";
        floxBin = noCtx "${floxStub}/bin/flox";
      in
      floxhubPullShape cfg [
        "arcade-freeciv.service"
        "arcade-mindustry.service"
      ]
      ++ [
        {
          assertion = lib.isDerivation freeciv.serviceConfig.ExecStart && lib.hasPrefix "/nix/store/" (toString freeciv.serviceConfig.ExecStart);
          message = "a floxhub stub's ExecStart must be the wrapper derivation (one store path once rendered)";
        }
        {
          assertion = lib.hasInfix "pin=/var/lib/homelab/pinned-environment-arcade\n" freecivWrapper && lib.hasInfix "read -r gen < \"$pin\"" freecivWrapper;
          message = "the wrapper must read the generation the pull unit pinned";
        }
        {
          assertion = lib.hasInfix "exec ${floxBin} activate -d /var/lib/arcade/env -g \"$gen\" -- freeciv-server --bind 192.168.1.50 --port 5556 --saves /var/lib/arcade/freeciv --log /var/lib/arcade/freeciv/server.log\n" freecivWrapper;
          message = "the wrapper must exec homelab.flox.package activating the tenant's dir at the pinned generation with the stub's argv in order";
        }
        {
          assertion = lib.hasInfix "exec ${floxBin} activate -d /var/lib/arcade/env -g \"$gen\" -- mindustry-server\n" mindustryWrapper;
          message = "mindustry's wrapper must exec the same activation with its one-word command";
        }
        {
          assertion = lib.hasInfix "exit 1" freecivWrapper && lib.hasInfix "*[!0-9]*" freecivWrapper;
          message = "the wrapper must refuse (exit 1) a missing or malformed pin rather than activate unpinned";
        }
        {
          assertion = (mindustry.environment.JAVA_TOOL_OPTIONS or null) == "-Xms256M -Xmx1G" && (mindustry.environment.FLOX_DISABLE_METRICS or null) == "true" && (freeciv.environment.FLOX_DISABLE_METRICS or null) == "true";
          message = "the stubs' variables must be on the units (JAVA_TOOL_OPTIONS on mindustry, FLOX_DISABLE_METRICS on both)";
        }
        {
          assertion = !(lib.any (n: lib.hasPrefix "ARCADE_" n) (builtins.attrNames freeciv.environment ++ builtins.attrNames mindustry.environment));
          message = "no ARCADE_* variable: the manifest has no hook, every host fact travels in argv or the unit's stdin text";
        }
        {
          assertion = (freeciv.serviceConfig.User or null) == "arcade" && (freeciv.serviceConfig.Restart or null) == "on-failure" && (freeciv.serviceConfig.Slice or null) == "interactive.slice";
          message = "the stub must leave User=, Restart= and Slice= alone";
        }
        {
          # agent-hub, the tree kind, in the same evaluation with its
          # enable at the default: still exactly the module's unit (the
          # `enabled` case has the tree kind on).
          assertion = isPlaceholder "agent-hub-llm.service" "agent-hub" cfg.systemd.services.agent-hub-llm.serviceConfig.ExecStart && cfg.systemd.services.agent-hub-llm.environment == { };
          message = "the tree kind's stub is unchanged by the floxhub kind existing";
        }
        {
          assertion =
            (mindustry.serviceConfig.StandardInputText or null) == [ "config name Arcade" "config port 6567" "host Islands sandbox" ]
            && (mindustry.serviceConfig.WorkingDirectory or null) == "/var/lib/arcade/mindustry"
            && (freeciv.serviceConfig.WorkingDirectory or null) == "/var/lib/arcade/freeciv"
            && !(freeciv.serviceConfig ? StandardInputText)
            && mindustry.description == "Arcade Mindustry dedicated server (LAN only)";
          message = "the skeleton fields must render: mindustry's three stdin lines in order, both WorkingDirectory=, no stdin on freeciv, the descriptions";
        }
      ];
  };

  # ---------------------------------------------------------------------
  # The whole-unit stub (homelab-158.11): the skeleton fields and their
  # defaults. A stub that names only `command` gets exactly the unit the
  # retired modules made; every field set explicitly reaches its key.
  # ---------------------------------------------------------------------

  # Only `command`: every skeleton default -- the tenant's name as
  # User/Group, on-failure/5, network-online After/Wants, multi-user
  # WantedBy, a derived description -- and none of the optional keys
  # (WorkingDirectory, TimeoutStopSec, StandardInputText).
  skeletonDefaults = mkCase {
    extraModules = on [
      {
        homelab.tenants.agent-hub.environment.units."agent-hub-llm.service" = lib.mkForce {
          command = [ "llama-swap" ];
        };
      }
    ];
    checks =
      cfg:
      let
        u = cfg.systemd.services.agent-hub-llm;
        sc = u.serviceConfig;
      in
      [
        {
          assertion = u.description == "agent-hub: agent-hub-llm (from its flox environment)";
          message = "a stub with no description must derive one from the tenant and the unit, got \"${u.description}\"";
        }
        {
          assertion = (sc.User or null) == "agent-hub" && (sc.Group or null) == "agent-hub";
          message = "User= and Group= must default to the tenant's name";
        }
        {
          assertion = (sc.Restart or null) == "on-failure" && (sc.RestartSec or null) == 5;
          message = "Restart=on-failure and RestartSec=5 are the defaults";
        }
        {
          assertion =
            u.after == [ "network-online.target" ]
            && u.wants == [ "network-online.target" ]
            && u.wantedBy == [ "multi-user.target" ];
          message = "After=/Wants=network-online.target and WantedBy=multi-user.target are the defaults";
        }
        {
          assertion = !(sc ? WorkingDirectory) && !(sc ? TimeoutStopSec) && !(sc ? StandardInputText);
          message = "WorkingDirectory=, TimeoutStopSec= and StandardInputText= must be absent when their fields are unset";
        }
        {
          assertion = lib.hasSuffix " -- llama-swap" sc.ExecStart && (u.environment.FLOX_DISABLE_METRICS or null) == "true";
          message = "ExecStart is the activation and FLOX_DISABLE_METRICS is set even with no host variables";
        }
        {
          assertion = (sc.Slice or null) == "background.slice";
          message = "the slice is still the contract's";
        }
      ];
  };

  # Every skeleton field set explicitly: each reaches its key, on and off.
  skeletonFields = mkCase {
    extraModules = on [
      {
        homelab.tenants.agent-hub.environment.units."agent-hub-llm.service" = {
          description = lib.mkForce "the model server";
          user = "llm";
          group = "models";
          workingDirectory = "/var/lib/agent-hub/work";
          restart = "always";
          restartSec = 30;
          timeoutStopSec = lib.mkForce 120;
          after = lib.mkForce [ "qdrant.service" ];
          wants = lib.mkForce [ "qdrant.service" ];
          wantedBy = lib.mkForce [ ];
          stdin = [
            "one"
            "two"
          ];
        };
      }
    ];
    checks =
      cfg:
      let
        u = cfg.systemd.services.agent-hub-llm;
        sc = u.serviceConfig;
        text = pullText cfg "agent-hub";
      in
      [
        {
          assertion =
            u.description == "the model server"
            && sc.User == "llm"
            && sc.Group == "models"
            && sc.WorkingDirectory == "/var/lib/agent-hub/work"
            && sc.Restart == "always"
            && sc.RestartSec == 30
            && sc.TimeoutStopSec == 120
            && u.after == [ "qdrant.service" ]
            && u.wants == [ "qdrant.service" ]
            && u.wantedBy == [ ]
            && sc.StandardInputText == [ "one" "two" ];
          message = "every skeleton field must reach its unit key verbatim";
        }
        {
          # The pull unit reads the checkout's owner off the unit, so a
          # `user` here is who the checkout belongs to.
          assertion = lib.hasInfix "\nuser=llm\n" text;
          message = "the pull's checkout owner must follow the stub's user";
        }
      ];
  };

  # MUST THROW: kind = floxhub with no env. There is nothing to pull.
  floxhubWithoutEnv = mkCase {
    extraModules = [
      floxhubFixture
      { homelab.tenants.arcade.environment.source.env = lib.mkForce null; }
    ];
  };

  # MUST THROW: kind = tree with an env set -- a declaration that
  # contradicts itself is refused rather than half-read.
  treeWithEnv = mkCase {
    extraModules = [ { homelab.tenants.agent-hub.environment.source.env = "imkarrer/agent-hub"; } ];
  };

  # MUST THROW: env that is not owner/name.
  floxhubBadEnv = mkCase {
    extraModules = [
      floxhubFixture
      { homelab.tenants.arcade.environment.source.env = lib.mkForce "arcade"; }
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
    treeNotInRegistry = false;
    treeWithoutRemote = false;
    realRegistry = true;
    floxhubDisabled = true;
    floxhubEnabled = true;
    skeletonDefaults = true;
    skeletonFields = true;
    floxhubWithoutEnv = false;
    treeWithEnv = false;
    floxhubBadEnv = false;
  };
}
