# Minimal stand-in for the slice of NixOS's `services.prometheus` option
# surface metrics.nix writes to. Real `nixos/modules/services/monitoring/
# prometheus/default.nix` has a much richer `scrapeConfigs` submodule type;
# this only needs `listOf attrs` because metrics.nix never reads the value
# back, it only ever constructs and appends whole scrapeConfig attrsets --
# same scoping rationale as tests/stub-host.nix and tests/stub-systemd.nix.
{ lib, ... }:
{
  options.services.prometheus.scrapeConfigs = lib.mkOption {
    type = lib.types.listOf lib.types.attrs;
    default = [ ];
  };
}
