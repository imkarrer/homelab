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
{ config, lib, ... }:

let
  cfg = config.homelab.host;
in
{
  networking.hostName = cfg.name;
  networking.networkmanager.enable = true;

  # No wireless hardware on this host -- /sys/class/net on ac-box lists eno1,
  # enp8s0, docker bridges and veths, nothing else -- yet wpa_supplicant.service
  # was running (found 9 Sep 2026, up since the 5th). nixpkgs'
  # networkmanager.nix turns it on as a side effect:
  #
  #     mkIf (!delegateWireless && !enableIwd) { wireless.enable = true; }
  #
  # mkForce is REQUIRED, not stylistic: that upstream definition sits inside a
  # mkIf at normal priority, so a plain `false` here is a conflicting
  # definition and an evaluation error. Proven by extendModules against HEAD
  # before this was written -- mkForce false removes wpa_supplicant.service and
  # the wpa_supplicant user and changes nothing else; NetworkManager.service
  # is unaffected.
  #
  # Declared here rather than disabled by hand on the box, because a hand
  # `systemctl disable` is undone by the next switch and is exactly the kind
  # of resting-state hand-edit AGENTS.md forbids.
  networking.wireless.enable = lib.mkForce false;

  time.timeZone = cfg.timezone;
}
