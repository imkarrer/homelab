# Hostname and timezone, derived from homelab.host — never a second literal
# spelling of what hosts/<name>/host.nix already declares.
#
# This module deliberately does NOT configure networking.interfaces or a
# static address for homelab.host.networks.*: ac-box's current configuration.nix
# does not either (networkmanager + the box's own DHCP reservation own the
# address). homelab.host.networks exists so modules/platform/docker.nix's
# neighbours — the tenant contract's port scoping and observability's
# per-interface firewall rules — have one non-literal place to read
# `interface` / `address` from; it is not consumed here because there is
# nothing for the platform layer to set today. Reproducing ac-box exactly
# means not inventing networking config it doesn't already have.
{ config, ... }:

let
  cfg = config.homelab.host;
in
{
  networking.hostName = cfg.name;
  networking.networkmanager.enable = true;
  time.timeZone = cfg.timezone;
}
