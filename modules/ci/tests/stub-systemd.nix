# Minimal stand-in for the slice of NixOS's own option surface
# modules/ci/default.nix writes to: systemd.services.<name>.{description,
# after, wants, requires, path, serviceConfig, restartIfChanged,
# stopIfChanged}. Deliberately self-contained (not shared with
# modules/tenant/tests/stub-systemd.nix, which models a different subset --
# systemd.slices/system.activationScripts -- that this module never touches)
# so modules/ci/ stays a standalone draft, same spirit as
# modules/tenant/tests/stub-host.nix scoping ports.nix's harness.
{ lib, ... }:
{
  options.systemd.services = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          description = lib.mkOption { type = lib.types.str; default = ""; };
          after = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
          wants = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
          requires = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
          path = lib.mkOption { type = lib.types.listOf lib.types.unspecified; default = [ ]; };
          restartIfChanged = lib.mkOption { type = lib.types.bool; default = true; };
          stopIfChanged = lib.mkOption { type = lib.types.bool; default = true; };
          serviceConfig = lib.mkOption { type = lib.types.attrsOf lib.types.unspecified; default = { }; };
        };
      }
    );
    default = { };
  };
}
