# The `homelab.host` option contract. Every literal fact about the physical
# machine — name, timezone, NIC/address, declared capacity, base paths,
# maintenance window, GPU — is declared here and set exactly once, in
# hosts/<name>/host.nix. No other module may hardcode any of it.
#
# Shape is pinned against hosts/ac-box/host.nix (the only host that exists
# today) — do not add fields that file does not set, and do not change the
# shape of the ones it does without updating it in lockstep.
{ lib, ... }:

let
  inherit (lib) mkOption types;

  # One named interface's facts. attrsOf-keyed (lan, mgmt, ...) rather than a
  # fixed set of fields, because the tenant contract already refers to them
  # that way: "opened on host.networks.lan.interface" / ".mgmt.interface".
  networkFacts = types.submodule {
    options = {
      interface = mkOption {
        type = types.str;
        description = "NIC device name, e.g. enp8s0. The only place this is a literal.";
      };

      address = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          IPv4 address on this interface, or null when the interface carries
          none yet (mgmt is cabled but down until the dual-NIC runbook brings
          it up). Nothing may be scoped to an interface whose address is null.
        '';
      };

      prefixLength = mkOption {
        type = types.nullOr (types.ints.between 0 32);
        default = null;
        description = "CIDR prefix length. Left null alongside a null address.";
      };
    };
  };

in
{
  options.homelab.host = {
    name = mkOption {
      type = types.str;
      description = ''
        networking.hostName. Also the key used to locate this host's
        gitignored, machine-specific files — hosts/<name>/hardware-configuration.nix
        and hosts/<name>/ssh-keys.local.nix — so platform modules can find
        them without hardcoding a host name.
      '';
    };

    timezone = mkOption {
      type = types.str;
      description = "time.timeZone, e.g. America/Chicago.";
    };

    networks = mkOption {
      type = types.attrsOf networkFacts;
      default = { };
      description = ''
        Named interface facts. Consumed by modules/platform/network.nix and by
        the tenant contract's port scoping (a "lan" or "mgmt" scoped port opens
        on host.networks.<name>.interface; "forwarded" is lan plus a router
        forward). This is the only place NIC names and addresses are literal —
        every other module, including tenants, must read them from here.
      '';
    };

    capacity = mkOption {
      type = types.submodule {
        options = {
          cpuThreads = mkOption {
            type = types.ints.positive;
            description = "Logical CPU threads, verified against /proc at activation.";
          };
          memoryGiB = mkOption {
            type = types.ints.positive;
            description = "Physical RAM in GiB, verified against /proc at activation.";
          };
        };
      };
      description = ''
        Declared capacity. Tiers (homelab.tiers) are expressed as shares of
        this, never absolute gigabytes or CPU indices — copying a host.nix to
        a smaller machine without editing capacity is the classic portability
        bug this field exists to catch.
      '';
    };

    paths = mkOption {
      type = types.submodule {
        options = {
          data = mkOption {
            type = types.path;
            description = "Base directory for tenant data; derived default is <data>/<tenant>.";
          };
          state = mkOption {
            type = types.path;
            description = "Base directory for tenant state; derived default is <state>/<tenant>.";
          };
        };
      };
      description = ''
        Base directories the tenant schema's dirSet derives defaults from.
        A tenant overrides explicitly only to preserve an existing path
        (assetto keeps /var/lib/ac-host) — renaming a state dir is a data
        migration, not a config change.
      '';
    };

    maintenance = mkOption {
      type = types.submodule {
        options = {
          window = mkOption {
            type = types.str;
            description = ''
              Time of day (HH:MM, host's timezone) reserved for
              non-drainable tenants' maintenance work. Read by the quiet/drain
              policy, not reinvented per tenant.
            '';
          };
        };
      };
      description = "The maintenance window.";
    };

    gpu = mkOption {
      type = types.nullOr (types.enum [ "nvidia" ]);
      default = null;
      description = ''
        GPU vendor driver to enable, or null for none. Consumed by
        modules/platform/boot.nix to gate hardware.graphics / hardware.nvidia.
        Only "nvidia" exists today because that's the only value ac-box sets;
        extend the enum when a second vendor shows up rather than widening it
        to a bare string speculatively.
      '';
    };
  };
}
