# Minimal stand-in for the option surface modules/deploy/default.nix writes
# to: systemd.services / .timers / .paths / .tmpfiles.rules, plus the two
# facts it reads back out of the rest of the system -- homelab.host (name and
# the maintenance window the schedule arithmetic is derived from),
# config.nix.package and config.system.build.nixos-rebuild, which are
# runtimeInputs of the deploy script.
#
# Self-contained rather than shared with modules/ci/tests/stub-systemd.nix or
# modules/tenant/tests/stub-*.nix: each models the subset its own module
# touches, and this is the only one that needs timers and paths. Same spirit
# as those two, and the same reason -- a stub that grows to model all of
# systemd stops being a stub and starts being a second NixOS.
{ lib, pkgs, ... }:
let
  unitFile = lib.types.attrsOf lib.types.unspecified;
in
{
  options = {
    systemd.services = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            description = lib.mkOption { type = lib.types.str; default = ""; };
            after = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
            wants = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
            restartIfChanged = lib.mkOption { type = lib.types.bool; default = true; };
            path = lib.mkOption { type = lib.types.listOf lib.types.unspecified; default = [ ]; };
            serviceConfig = lib.mkOption { type = unitFile; default = { }; };
          };
        }
      );
      default = { };
    };

    systemd.timers = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            description = lib.mkOption { type = lib.types.str; default = ""; };
            wantedBy = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
            timerConfig = lib.mkOption { type = unitFile; default = { }; };
          };
        }
      );
      default = { };
    };

    systemd.paths = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            description = lib.mkOption { type = lib.types.str; default = ""; };
            wantedBy = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
            pathConfig = lib.mkOption { type = unitFile; default = { }; };
          };
        }
      );
      default = { };
    };

    systemd.tmpfiles.rules = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };

    homelab.host = lib.mkOption {
      type = lib.types.submodule {
        options = {
          name = lib.mkOption { type = lib.types.str; default = "test-box"; };
          maintenance.window = lib.mkOption { type = lib.types.str; default = "03:00"; };
        };
      };
      default = { };
    };

    # The deploy script's runtimeInputs. Any derivation will do -- the
    # harness never runs the script, it reads the text and the unit shape --
    # so these are the cheapest stand-ins that still make `lib.getExe` and
    # writeShellApplication evaluate.
    nix.package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.coreutils;
    };

    system.build.nixos-rebuild = lib.mkOption {
      type = lib.types.package;
      default = pkgs.coreutils;
    };
  };
}
