# Minimal stand-in for the option surface ports.nix expects from the
# platform layer (modules/platform/, homelab.host.networks.*) and from NixOS
# itself (assertions, networking.firewall.interfaces).
#
# modules/platform/ doesn't exist in this repo yet -- L0 is a separate beads
# task -- so this stub declares only the leaves ports.nix actually reads.
# It is intentionally NOT a copy of the real NixOS firewall module: it models
# just the `allowedTCPPorts`/`allowedUDPPorts` per-interface shape, which is
# the only part of `networking.firewall` this module touches.
{ lib, ... }:
{
  options = {
    homelab.host.networks = lib.mkOption {
      type = lib.types.submodule {
        options = {
          lan = lib.mkOption {
            type = lib.types.submodule {
              options.interface = lib.mkOption { type = lib.types.str; };
            };
          };
          mgmt = lib.mkOption {
            type = lib.types.submodule {
              options = {
                interface = lib.mkOption { type = lib.types.str; };
                address = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                };
              };
            };
          };
        };
      };
    };

    networking.firewall.interfaces = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            allowedTCPPorts = lib.mkOption {
              type = lib.types.listOf lib.types.port;
              default = [ ];
            };
            allowedUDPPorts = lib.mkOption {
              type = lib.types.listOf lib.types.port;
              default = [ ];
            };
          };
        }
      );
      default = { };
    };

    # Real NixOS declares these in nixos/modules/misc/assertions.nix; ports.nix
    # only writes to `assertions`, so that's the only one that needs a value
    # producer -- but both are declared for shape-fidelity.
    assertions = lib.mkOption {
      type = lib.types.listOf lib.types.unspecified;
      default = [ ];
    };
    warnings = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };
  };

  # mkDefault throughout so a fixture (e.g. mgmt-with-address.nix) can
  # override without tripping the "defined both X and Y" conflict that a
  # plain value assignment would hit at the same module priority.
  config.homelab.host.networks = {
    lan.interface = lib.mkDefault "enp8s0";
    mgmt = {
      interface = lib.mkDefault "eno1";
      address = lib.mkDefault null;
    };
  };
}
