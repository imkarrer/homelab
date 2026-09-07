# Minimal stand-in for the slice of NixOS's `environment.etc` option surface
# quiet.nix writes to. Real `nixos/modules/system/etc/etc.nix` supports far
# more (source, user, group, target, ...); quiet.nix only ever sets `text`
# and `mode`, so that's all this models -- same scoping rationale as
# tests/stub-host.nix and tests/stub-systemd.nix.
{ lib, ... }:
{
  options.environment.etc = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          text = lib.mkOption { type = lib.types.str; };
          mode = lib.mkOption {
            type = lib.types.str;
            default = "0444";
          };
        };
      }
    );
    default = { };
  };
}
