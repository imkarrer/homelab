# Migration-phase kill switches for the tenant contract's derivations.
#
# Each of ports.nix, resources.nix, metrics.nix and quiet.nix turns
# homelab.tenants (schema.nix) into a real system effect: firewall rules,
# systemd slices, prometheus scrapeConfigs, /etc/homelab/tenants.json. Phase 1
# of the ac-box migration requires the new NixOS closure to be provably
# identical to what ac-box already runs (`nix store diff-closures`) -- and
# none of those four effects exist on ac-box today, so turning all four on at
# once would fail that gate on day one.
#
# The contract's ASSERTIONS (port collisions, forwarded justification, mgmt
# address, the 0.9 memory budget) cost nothing in the closure -- they run at
# evaluation time only -- so they are NOT gated by anything here and ship
# unconditionally in the four modules. Only derivations that touch `config`
# outside `homelab.*` are gated, one switch per module, so each effect can be
# turned on in its own small, independently-verifiable step instead of one
# flag day-onning all four at once.
#
# Declared in its own file rather than folded into schema.nix: schema.nix's
# header pins it to vocabulary only ("Do not add derivation logic here"), and
# these flags aren't part of the per-tenant shape a tenant flake declares --
# they're platform-side migration knobs consumed by the four modules that
# already read the schema. A tenant author should never need to look here;
# whoever composes ac-box's config does.
#
# Every consumer (ports.nix, resources.nix, metrics.nix, quiet.nix) reads
# `config.homelab.enforce.*` without importing this file itself, the same way
# they read `config.homelab.tenants.*` without importing schema.nix -- the
# composing module list (today: each tests/eval*.nix harness; eventually the
# real host config) is responsible for including this module alongside them.
{ lib, ... }:

let
  inherit (lib) mkOption types;
in
{
  options.homelab.enforce = {
    firewall = mkOption {
      type = types.bool;
      default = false;
      description = ''
        ports.nix emits networking.firewall.interfaces rules derived from the
        tenant port registry. Off by default: firewall rules are a closure
        change, and ac-box's current firewall is hand-configured outside this
        repo until this is turned on for real.
      '';
    };

    slices = mkOption {
      type = types.bool;
      default = false;
      description = ''
        resources.nix emits systemd.slices and per-unit Slice=/Nice= derived
        from homelab.tiers, plus the activation-time capacity drift check
        that validates the assumptions those slices are built on. Off by
        default: none of it exists on ac-box today.
      '';
    };

    scrape = mkOption {
      type = types.bool;
      default = false;
      description = ''
        metrics.nix emits services.prometheus.scrapeConfigs derived from each
        tenant's metrics declaration. Off by default: ac-box's Prometheus is
        currently hand-configured (monitoring.nix) outside this repo.
      '';
    };

    inventory = mkOption {
      type = types.bool;
      default = false;
      description = ''
        quiet.nix writes /etc/homelab/tenants.json, the machine-readable
        surface boxctl reads. Off by default: the file doesn't exist on
        ac-box today, and creating it is a closure change.
      '';
    };
  };
}
