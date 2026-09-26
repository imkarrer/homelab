# The tenant contract. PINNED — every other module in this repo, and every
# tenant flake, is written against these exact option paths and types.
#
# Do not add derivation logic here. This file declares the vocabulary only;
# ports.nix, resources.nix, metrics.nix, quiet.nix and environment.nix
# consume it (environment.nix also supplies environment.dir's derived
# default, by mkDefault -- the vocabulary says "null = derived", the
# consumer derives).
{ lib, ... }:

let
  inherit (lib) mkOption types;

  # A single port claim. `scope` decides how the platform opens it, and is the
  # only thing a tenant is allowed to say about the network.
  #
  #   local      bound to 127.0.0.1, never opened in the firewall
  #   lan        opened on host.networks.lan.interface only
  #   forwarded  same as lan, PLUS reachable from the internet because the
  #              router forwards it (ac-host/scripts/unifi_pf.py does this per
  #              lobby slot). Requires `justification` — being internet-facing
  #              is a decision, not a default.
  #   mgmt       opened on host.networks.mgmt.interface (eno1, currently down)
  portScope = types.enum [ "local" "lan" "forwarded" "mgmt" ];

  portClaim = types.submodule {
    options = {
      number = mkOption {
        type = types.port;
        description = "The port itself. Protocol-level fact, never derived from capacity.";
      };
      proto = mkOption {
        type = types.listOf (types.enum [ "tcp" "udp" ]);
        default = [ "tcp" ];
      };
      scope = mkOption { type = portScope; default = "lan"; };
      justification = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Required when scope = \"forwarded\". What gates it, and why it is public.";
      };
    };
  };

  # Contiguous block, for tenants that allocate per-slot (assetto).
  portRange = types.submodule {
    options = {
      start = mkOption { type = types.port; };
      count = mkOption { type = types.ints.positive; };
      proto = mkOption {
        type = types.listOf (types.enum [ "tcp" "udp" ]);
        default = [ "tcp" ];
      };
      scope = mkOption { type = portScope; default = "lan"; };
      justification = mkOption { type = types.nullOr types.str; default = null; };
    };
  };

  dirSet = types.submodule {
    options = {
      dirs = mkOption {
        type = types.listOf types.path;
        default = [ ];
        description = ''
          Absolute paths. Leave empty to accept the derived default
          (host.paths.state/<tenant> or host.paths.data/<tenant>). Set
          explicitly only to preserve history — assetto keeps /var/lib/ac-host
          because renaming a state directory is a data migration, not a config
          change.
        '';
      };
      backup = mkOption { type = types.bool; default = false; };
    };
  };

  quietPolicy = types.submodule {
    options = {
      drainable = mkOption {
        type = types.bool;
        default = true;
        description = "May its units restart at any time? false = needs a maintenance window.";
      };
      busyCheck = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Command; exit 0 means BUSY. The closure switch (modules/deploy) consults it only when drainable = false; a tenant's environment pull (modules/tenant/environment-pull.nix) consults it whenever set, so drainable = true with a check means \"any hour, but not mid-job\".";
      };
      drain = mkOption { type = types.nullOr types.str; default = null; };
      resume = mkOption { type = types.nullOr types.str; default = null; };
    };
  };

  metricsEndpoint = types.submodule {
    options = {
      port = mkOption { type = types.port; };
      # Added 12 Sep 2026 (docs/architecture.md delta row 12). Until then
      # this submodule had no address and metrics.nix hardcoded 127.0.0.1:
      # every exporter on ac-box binds loopback, so "scrape over loopback"
      # was the convention and metrics.nix's header pinned it as one. The
      # first tenant it could not describe was agent-hub: llama-server runs
      # with `--host 192.168.1.50 --metrics` because being reachable from
      # other machines is the whole point of the service, and it does NOT
      # also listen on loopback -- `curl http://127.0.0.1:8100/metrics` on
      # the box is connection refused (curl exit 7) while the LAN address
      # serves eleven `llamacpp:*` series. A 127.0.0.1 scrape job for it
      # would be a permanent `up == 0`.
      #
      # The default is loopback, deliberately and load-bearingly: every
      # declaration that predates this field must produce a byte-identical
      # `static_configs` entry, because the whole reason `job` can be
      # overridden is that Grafana dashboards are keyed on job/target and a
      # reshaped job orphans them. tests/eval-metrics.nix pins the
      # 127.0.0.1:9100 / 127.0.0.1:9132 reproductions for exactly that.
      #
      # A free string, constrained by an assertion in metrics.nix rather
      # than by a type here, because the constraint is a HOST fact this file
      # is not allowed to know: the address must be loopback, or one of
      # homelab.host.networks.<name>.address that is non-null. That rules
      # out "0.0.0.0" (a bind wildcard, not somewhere Prometheus can connect
      # to), a hostname (a DNS dependency smuggled into a scrape config), and
      # a literal that stops being true when the box's address changes. It
      # also mirrors ports.nix's rule for scope = "mgmt": nothing may point
      # at an interface that has no address. Write the value as a REFERENCE
      # -- `config.homelab.host.networks.lan.address`, the way
      # hosts/ac-box/configuration.nix already feeds services.agent-hub
      # .lanAddress -- never as a literal; a literal passes today and fails
      # evaluation the day the address moves, which is the assertion doing
      # its job, but late and by surprise.
      address = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = ''
          IPv4 address Prometheus connects to for this endpoint. Default is
          loopback, which is where every exporter on this host binds. Set it
          only for a service that binds a non-loopback address and does not
          also listen on 127.0.0.1 -- and set it by reference to
          homelab.host.networks.<name>.address, not as a literal. metrics.nix
          asserts the value is loopback or an address the host actually has.
        '';
      };
      path = mkOption { type = types.str; default = "/metrics"; };
      interval = mkOption { type = types.str; default = "30s"; };
      job = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Prometheus job_name. Defaults to the tenant name. Changing it orphans dashboards.";
      };
    };
  };

  # ADR 0009: a tenant whose contents are a flox environment keeps a unit
  # stub per process in the closure -- the pinned unit name, the slice its
  # tier gives it, and an ExecStart of `flox activate -d <dir> -- <command>`
  # in place of whatever a NixOS module would have run. This is the shape
  # of one such stub. Added 17 Sep 2026 (homelab-158.2); until then the
  # contract had no vocabulary for HOW a tenant's unit is run, only for what
  # the host owes it, and ADR 0009 makes "from an environment, at this
  # path" a host fact about a tenant in the same sense a state path is.
  #
  # Since homelab-158.11 the stub is the WHOLE unit. Until then a tenant's
  # NixOS module (agent-hub's modules/agent-hub.nix, home-arcade's
  # modules/arcade-hub.nix) declared the unit -- description, User=,
  # WorkingDirectory=, Restart=, After=/Wants=, WantedBy= -- and the stub
  # replaced only ExecStart and the variables; those modules have left the
  # closure, so the skeleton they supplied is spelled here, per unit, with
  # the defaults a LAN-bound service under systemd wants. The unit's Slice=
  # and Nice= are still resources.nix's from the tier, never a field here.
  #
  # `command` runs with the environment's bin on PATH and the manifest's
  # hook already sourced; its first word is a package the manifest
  # installs, not a store path. `environment` is every host fact the
  # manifest's hook defaults (`: "${X:=...}"`), set explicitly by the unit
  # so a default in the manifest is never load-bearing on the box --
  # docs/flox-findings.md, "Beyond the six": `[vars]` clobbers the caller,
  # so the hook is the only channel, and a value the unit does not set is a
  # value the tenant tree chose for it.
  #
  # What is deliberately NOT a field: a host's own facts about its own unit
  # that are not the skeleton -- agent-hub-llm's AllowedCPUs= and NUMA
  # policy on ac-box -- stay a plain `systemd.services.<unit>.serviceConfig`
  # definition in the host's configuration, which the module system merges
  # with what environment.nix emits. A second spelling of serviceConfig
  # here would be exactly the kind of duplicate the README forbids.
  environmentUnit = types.submodule {
    options = {
      command = mkOption {
        type = types.listOf types.str;
        description = ''
          argv after `flox activate -d <dir> --`. The first word resolves
          on the environment's PATH (a package the manifest installs);
          the rest are its flags. Not a store path: which build runs is
          the environment's decision, which is the point.
        '';
      };
      environment = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = ''
          Variables the unit exports before activation, one per host fact
          the manifest's hook would otherwise default. Set every one the
          hook names; a missing one is a tenant-tree default running on
          the box unreviewed.
        '';
      };

      # -- The skeleton (homelab-158.11). ------------------------------
      # Every default below is what both retired modules set for every
      # unit they declared, so a stub that names only `command` gets the
      # unit they would have made. null means "derived by environment.nix"
      # (this file computes nothing, its header), and the derivation is
      # the obvious one: the tenant's name.

      description = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          The unit's Description=. null derives "<tenant>: <unit> (from
          its flox environment)"; set it to keep a description the box
          already shows (`systemctl status` and the journal are keyed on
          the unit NAME, never on this, so changing it is free).
        '';
      };

      user = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          User= the process runs as. null derives the tenant's name, which
          is what both retired modules used (agent-hub, arcade). Must own
          `environment.dir`: `flox activate` writes there, and the pull
          unit checks the environment out as this user.
        '';
      };

      group = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Group= for the process. null derives the same name as `user`.";
      };

      workingDirectory = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          WorkingDirectory=, when the process writes relative to its cwd
          (Mindustry writes config/ under it). null leaves it unset, which
          systemd resolves to / for a system service.
        '';
      };

      restart = mkOption {
        type = types.enum [ "no" "always" "on-success" "on-failure" "on-abnormal" "on-abort" "on-watchdog" ];
        default = "on-failure";
        description = "Restart=. on-failure is what every tenant unit on ac-box carries.";
      };

      restartSec = mkOption {
        type = types.ints.unsigned;
        default = 5;
        description = "RestartSec=, seconds.";
      };

      timeoutStopSec = mkOption {
        type = types.nullOr types.ints.unsigned;
        default = null;
        description = ''
          TimeoutStopSec=, seconds; null leaves systemd's default (90 s
          on NixOS). Set it where the process supervises children of its
          own that need time to die -- llama-swap stopping a model
          mid-load.
        '';
      };

      after = mkOption {
        type = types.listOf types.str;
        default = [ "network-online.target" ];
        description = ''
          After=. The default is what a unit that binds the LAN address
          needs: at boot the address does not exist until
          network-online.target, and a unit ordered after network.target
          alone dies with "Cannot assign requested address" (rsyncd and
          qdrant both did, 12 and 16 Sep 2026).
        '';
      };

      wants = mkOption {
        type = types.listOf types.str;
        default = [ "network-online.target" ];
        description = "Wants=. Paired with `after` by default; the ordering alone does not pull the target in.";
      };

      wantedBy = mkOption {
        type = types.listOf types.str;
        default = [ "multi-user.target" ];
        description = ''
          WantedBy=. multi-user.target is what makes the unit start at
          boot; environment-pull.nix's applied record lists the units it
          restarted by these names, so a stub that is not wanted by
          anything is one the pull starts and nothing else does.
        '';
      };

      stdin = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Lines fed to the process on standard input at start, one
          StandardInputText= each (systemd appends a newline to every
          line). For a server that takes its startup commands on its
          console -- Mindustry's `config port N` and `host <map> <mode>` --
          which is where a host fact goes when it is neither argv nor a
          variable the manifest's hook reads.
        '';
      };
    };
  };
in
{
  options.homelab.tenants = mkOption {
    default = { };
    description = "Everything sharing this host, declared. One entry per tenant.";
    type = types.attrsOf (types.submodule ({ name, ... }: {
      options = {
        enable = mkOption { type = types.bool; default = true; };

        description = mkOption { type = types.str; };

        tier = mkOption {
          type = types.enum [ "critical" "interactive" "background" "batch" ];
          description = ''
            How this tenant loses. critical yields to nothing; batch yields to
            everything. Resolved against homelab.tiers, which is expressed as
            shares of homelab.host.capacity so it survives a move to another
            machine.
          '';
        };

        units = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = ''
            systemd units this tenant owns, by their CURRENT names. The platform
            assigns them to a slice; it never renames them. Unit and container
            names are load-bearing — docker_name_exporter maps them and the
            Grafana dashboards are built on that mapping.
          '';
        };

        ports = mkOption { type = types.attrsOf portClaim; default = { }; };
        portRanges = mkOption { type = types.attrsOf portRange; default = { }; };

        state = mkOption { type = dirSet; default = { }; };
        data = mkOption { type = dirSet; default = { }; };

        secrets = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "sops secret names. Never values, and never a literal here.";
        };

        metrics = mkOption { type = types.nullOr metricsEndpoint; default = null; };

        quiet = mkOption { type = quietPolicy; default = { }; };

        needsDocker = mkOption {
          type = types.bool;
          default = false;
          description = ''
            The platform owns the daemon and enables it if any tenant asks.
            Today this is inverted: services.ac-host sets
            virtualisation.docker.enable, so the racing tenant owns the daemon
            that CI and cAdvisor depend on.
          '';
        };

        flake = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Upstream flake ref, for provenance and drift reporting.";
        };

        # ADR 0009: this tenant's contents as a flox environment, and the
        # unit stubs that run it. Declaring a stub under `units` is what
        # puts the unit in the closure at all (since homelab-158.11 no
        # NixOS module declares it): modules/tenant/environment.nix emits
        # the whole unit from the stub's skeleton fields, and `enable`
        # decides what it EXECUTES. With it true, ExecStart is `flox
        # activate -d <dir> -- <command>` and the variables are set. With
        # it false -- the default, and the first-switch state (the pull
        # unit keeps the checkout warm before anything runs from it) --
        # ExecStart is a placeholder that exits 1 naming this flag, so a
        # declared stub that is not yet switched on is a failed unit in
        # the journal saying why, never a unit quietly serving some other
        # way and never a phantom with a slice and no process. The unit
        # never fetches: the environment at `dir` must have been activated
        # once online by whoever put it there (the pull unit,
        # homelab-158.3), after which activation is offline and ~80 ms
        # (docs/flox-findings.md section 1).
        environment = mkOption {
          type = types.submodule {
            options = {
              enable = mkOption {
                type = types.bool;
                default = false;
                description = "Run this tenant's stub units from the flox environment at `dir`. false: the units exist as their skeletons and their ExecStart refuses, naming this flag.";
              };

              dir = mkOption {
                type = types.nullOr types.path;
                # null means derived: `<first state dir>/env`, else
                # `<homelab.host.paths.state>/<tenant>/env`. The derivation
                # lives in environment.nix (a mkDefault on this option), the
                # way every other derived value in this contract lives in a
                # consumer -- this file reads no host fact and computes
                # nothing. Readers see the resolved path wherever
                # environment.nix is imported; null only where it is not.
                #
                # The root of a CHECKOUT, `.flox/` inside it, whichever kind
                # `source` names. For kind = tree it is the tenant tree at a
                # sha: `<dir>/<file>` is anything the tenant reads at run
                # time (agent-hub's llama-swap.yaml and nix/sd-ui.html),
                # which a FloxHub generation -- manifest and lock only --
                # would leave with no home. For kind = floxhub it is flox's
                # own tracking checkout of `owner/name` (`.flox/env.json`
                # names the owner, `.flox/env.lock` the upstream commit),
                # with nothing beside `.flox/`. Under the tenant's state
                # path because it is state: written by the pull unit, read
                # by the stub, owned by the tenant's user, and not worth a
                # backup slot on its own (it is a sha or a generation).
                default = null;
                description = ''
                  Where the environment lives on the host: the root of a
                  checkout (of the tenant tree, or flox's of the FloxHub
                  environment), `.flox/` inside it. The
                  tenant's user must own it, because `flox activate`
                  writes `.flox/run`, `.flox/cache` and `.flox/log` there.
                '';
              };

              units = mkOption {
                type = types.attrsOf environmentUnit;
                default = { };
                description = ''
                  Stub units, keyed by unit name WITH its suffix
                  ("agent-hub-llm.service"), exactly as `units` above
                  spells them. Every key must also appear in `units`:
                  a stub the contract does not know about would run
                  outside the tenant's slice. environment.nix asserts it.

                  Declaring one is what puts the unit in the closure
                  (environment.nix emits it whole, from the skeleton
                  fields and their defaults) and the environment ON the
                  box: environment-pull.nix keeps a checkout of `tree` at
                  `dir` for every tenant with a stub declared, whether or
                  not `enable` is on -- so the checkout is pulled and
                  warmed BEFORE the stub is switched to it, which is the
                  only order in which flipping `enable` cannot break the
                  unit (environment-pull.nix's header has the sequence).
                '';
              };

              # Where the environment comes from -- the deploy unit CI
              # stages into <stateDir>/pending-environment-<tenant>.json
              # and the pull unit applies. Two kinds (ADR 0009, "What is
              # staged depends on what the environment needs at run time"):
              #
              #   tree     a git sha of `tree` (hub/repos.psv), checked out
              #            at `dir`; for a tenant whose environment reads
              #            files from its tree at run time (agent-hub:
              #            llama-swap.yaml, nix/sd-ui.html -- docs/
              #            flox-findings.md, "Beyond the six").
              #   floxhub  a generation of the FloxHub environment `env`
              #            (`owner/name`), kept as a tracking checkout at
              #            `dir` and activated pinned to that generation;
              #            for a tenant whose runtime is entirely packages
              #            (arcade, homelab-158.5). A public environment:
              #            no credential on the box.
              #
              # This file is vocabulary only: the consistency rule (`env`
              # set iff kind == floxhub) is environment-pull.nix's
              # assertion, beside the registry check it makes for `tree`.
              source = {
                kind = mkOption {
                  type = types.enum [
                    "tree"
                    "floxhub"
                  ];
                  default = "tree";
                  description = "What CI stages for this tenant: a sha of `tree` (tree) or a generation of `env` (floxhub).";
                };
                env = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  example = "imkarrer/arcade";
                  description = ''
                    The FloxHub environment, `owner/name`, for kind =
                    floxhub; null otherwise. The pull unit refuses a
                    staged record naming any other environment.
                  '';
                };
              };

              tree = mkOption {
                type = types.str;
                default = name;
                defaultText = lib.literalMD "the tenant's name";
                description = ''
                  The registry name (hub/repos.psv, first column) of the
                  tree whose checkout is this environment. Defaults to
                  the tenant's name, right for agent-hub; arcade's tree is
                  home-arcade. For source.kind = tree, environment-pull.nix
                  reads the tree's remote from the registry at evaluation
                  time and refuses a name the registry does not carry. For
                  kind = floxhub it is provenance only -- the tree whose
                  CI pushes the generation -- and hub-status holds that
                  tree's origin HEAD against the staged record's `rev`.
                '';
              };

              # homelab-ygc.14 (26 Sep 2026), an amendment to ADR 0010. The
              # deploy edge's staging half runs on the CI agent and writes
              # on the host the agent runs on; since the cutover the only
              # agent is arcade-box's, so a tenant on a host without one
              # (agent-hub on the Z840) never sees its green sha staged.
              # This flag gives that host the staging half itself:
              # modules/tenant/environment-poll.nix's timer asks GitHub for
              # the tree's main HEAD and that commit's combined status,
              # and stages a green sha exactly as queue-environment would.
              # Only for source.kind = tree (a FloxHub generation is not a
              # fact GitHub holds); environment-poll.nix asserts it, this
              # file being vocabulary only.
              poll = mkOption {
                type = types.bool;
                default = false;
                description = ''
                  This host has no CI agent to stage this tenant, so it
                  asks GitHub itself: the tree's main HEAD and that
                  commit's combined status; a green sha is staged exactly
                  as queue-environment would stage it, and the pull unit
                  applies it. Tree-kind sources only.
                '';
              };
            };
          };
          default = { };
        };
      };
    }));
  };
}
