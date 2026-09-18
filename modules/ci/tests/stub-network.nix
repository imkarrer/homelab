# The one networking option modules/ci writes in its native shape:
# networking.hosts (the compose network's `minio` name, mapped to loopback).
# The tenant harness's stub-host.nix models networking.firewall.interfaces
# for ports.nix and nothing else, so this lives beside the ci harness.
{ lib, ... }:
{
  options.networking.hosts = lib.mkOption {
    type = lib.types.attrsOf (lib.types.listOf lib.types.str);
    default = { };
  };
}
