# The tenant contract. PINNED — every other module in this repo, and every
# tenant flake, is written against these exact option paths and types.
#
# Do not add derivation logic here. This file declares the vocabulary only;
# ports.nix, resources.nix, metrics.nix and quiet.nix consume it.
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
        description = "Command; exit 0 means BUSY. Consulted only when drainable = false.";
      };
      drain = mkOption { type = types.nullOr types.str; default = null; };
      resume = mkOption { type = types.nullOr types.str; default = null; };
    };
  };

  metricsEndpoint = types.submodule {
    options = {
      port = mkOption { type = types.port; };
      path = mkOption { type = types.str; default = "/metrics"; };
      interval = mkOption { type = types.str; default = "30s"; };
      job = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Prometheus job_name. Defaults to the tenant name. Changing it orphans dashboards.";
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
      };
    }));
  };
}
