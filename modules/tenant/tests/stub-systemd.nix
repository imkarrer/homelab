# Minimal stand-in for the slice of NixOS's own option surface resources.nix
# (and, since 17 Sep 2026, environment.nix and environment-pull.nix) writes
# to: systemd.slices, systemd.services.<name>.{serviceConfig,environment}
# plus the unit-level keys the pull unit sets (description, after, wants,
# restartIfChanged, path), systemd.paths, systemd.timers,
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
            # environment.nix (ADR 0009) sets a stub unit's variables here;
            # nothing else in this directory reads or writes it.
            environment = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = { };
            };
            # environment-pull.nix's own unit sets these; the stub unit
            # never does (that is one of the things the harness asserts).
            description = lib.mkOption {
              type = lib.types.str;
              default = "";
            };
            after = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
            };
            wants = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
            };
            restartIfChanged = lib.mkOption {
              type = lib.types.bool;
              default = true;
            };
            path = lib.mkOption {
              type = lib.types.listOf lib.types.unspecified;
              default = [ ];
            };
          };
        }
      );
      default = { };
    };

    # The pull's trigger and its retry (environment-pull.nix), the same two
    # shapes modules/deploy/tests/stub-systemd.nix models for homelab-deploy.
    systemd.paths = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            description = lib.mkOption {
              type = lib.types.str;
              default = "";
            };
            wantedBy = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
            };
            pathConfig = lib.mkOption {
              type = lib.types.attrsOf lib.types.anything;
              default = { };
            };
          };
        }
      );
      default = { };
    };

    systemd.timers = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            description = lib.mkOption {
              type = lib.types.str;
              default = "";
            };
            wantedBy = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
            };
            timerConfig = lib.mkOption {
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
