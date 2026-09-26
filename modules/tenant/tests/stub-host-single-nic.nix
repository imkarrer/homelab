# The single-NIC variant of stub-host.nix: a host that declares ONLY a lan
# network -- no `mgmt` attribute at all, not one with a null address. That is
# arcade-box's real shape (hosts/arcade-box/host.nix: the M920q has one wired
# port), and it is a different case from stub-host.nix's "mgmt declared,
# address null" (ac-box's eno1): before homelab-ygc.3, ports.nix read
# networks.mgmt.interface unconditionally and a host without the attribute
# failed evaluation with "attribute 'mgmt' missing" -- an error naming no
# option and no tenant. tests/eval.nix's singleNicNoMgmt case swaps this in
# for stub-host.nix.
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

    assertions = lib.mkOption {
      type = lib.types.listOf lib.types.unspecified;
      default = [ ];
    };
    warnings = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };
  };

  config.homelab.host.networks.lan.interface = lib.mkDefault "eno2";
}
