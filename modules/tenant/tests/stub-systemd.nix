# Minimal stand-in for the slice of NixOS's own option surface resources.nix
# writes to: systemd.slices, systemd.services.<name>.serviceConfig,
# system.activationScripts, and the assertions/warnings pair
# nixos/modules/misc/assertions.nix normally declares.
#
# This is intentionally NOT the real nixos/modules/system/boot/systemd.nix --
# pulling that in (or the full <nixpkgs/nixos> module list, which is what
# actually declares these) works too (spot-checked with `nix eval --impure
# --expr '(import <nixpkgs/nixos> { configuration = {}; }).config.systemd.slices'`,
# see the report), but drags in every other NixOS module's own assertions
# (missing fileSystems, no bootloader, ...), which would drown out the one
# assertion this test suite actually cares about. This stub keeps the eval
# scoped to resources.nix's own logic, the same way tests/stub-host.nix does
# for ports.nix.
{ lib, ... }:
{
  options = {
    assertions = lib.mkOption {
      type = lib.types.listOf lib.types.unspecified;
      default = [ ];
    };
    warnings = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };

    systemd.slices = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            description = lib.mkOption {
              type = lib.types.str;
              default = "";
            };
            sliceConfig = lib.mkOption {
              type = lib.types.attrsOf lib.types.anything;
              default = { };
            };
          };
        }
      );
      default = { };
    };

    systemd.services = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            serviceConfig = lib.mkOption {
              type = lib.types.attrsOf lib.types.anything;
              default = { };
            };
          };
        }
      );
      default = { };
    };

    system.activationScripts = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            text = lib.mkOption {
              type = lib.types.lines;
              default = "";
            };
            deps = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
            };
          };
        }
      );
      default = { };
    };
  };
}
