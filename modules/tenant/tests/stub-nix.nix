# Minimal stand-in for the two NixOS options modules/platform/flox.nix
# writes to -- environment.systemPackages and nix.settings -- so
# eval-environment.nix can import the REAL flox.nix (and so prove that
# homelab.flox.package is what a stub's ExecStart resolves to) without the
# real nix module's own defaults and assertions. Same spirit as
# stub-systemd.nix: the subset one module touches, and no more.
{ lib, ... }:
{
  options = {
    environment.systemPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
    };
    nix.settings = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      default = { };
    };
  };
}
