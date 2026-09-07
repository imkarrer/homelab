# Eval harness for modules/tenant/resources.nix.
#
# Not a flake -- this repo doesn't have one yet -- so this runs against
# whatever <nixpkgs> resolves to on the machine, same as tests/eval.nix
# (ports.nix's harness). Uses the REAL modules/platform/host-options.nix and
# the REAL hosts/ac-box/host.nix (56 threads / 251 GiB) rather than a capacity
# stub, since both now exist in this repo -- only the systemd-shaped options
# resources.nix writes to (systemd.slices, systemd.services.*.serviceConfig,
# system.activationScripts) are stubbed, in tests/stub-systemd.nix.
#
# Usage:
#   nix --extra-experimental-features "nix-command flakes" eval \
#     -f modules/tenant/tests/eval-resources.nix <case>.<field>
#
# `good.checked` and `brokenBudget.checked` are the ones that behave the way
# a real NixOS build does: throw (evaluation FAILS) if any assertion failed,
# clean return otherwise.
{ lib ? (import <nixpkgs> { }).lib, pkgs ? import <nixpkgs> { } }:

let
  hostOptions = ../../platform/host-options.nix;
  hostFacts = ../../../hosts/ac-box/host.nix;
  schema = ../schema.nix;
  resources = ../resources.nix;
  stubSystemd = ./stub-systemd.nix;
  tenants = ./fixtures/resources-tenants.nix;

  mkCase = extraModules:
    let
      evaluated = lib.evalModules {
        specialArgs = { inherit pkgs; };
        modules = [
          stubSystemd
          hostOptions
          hostFacts
          schema
          resources
          tenants
        ] ++ extraModules;
      };

      failed = lib.filter (a: !a.assertion) evaluated.config.assertions;
      messages = map (a: a.message) failed;

      cfg = evaluated.config;
    in
    {
      inherit (evaluated) config;
      ok = failed == [ ];
      inherit messages;

      # The headline numbers this task asks to be proven, pulled out flat so
      # `nix eval -f ... good.summary` is one readable call.
      summary = {
        capacity = cfg.homelab.host.capacity;
        tiers = lib.mapAttrs (_: t: {
          memoryShare = t.memoryShare;
          cpuShare = t.cpuShare;
        }) cfg.homelab.tiers;
        slices = lib.mapAttrs (_: s: s.sliceConfig) cfg.systemd.slices;
        assettoUnit = cfg.systemd.services."ac-host-static".serviceConfig;
        arcadeUnit = cfg.systemd.services."arcade-freeciv".serviceConfig;
        agentHubUnit = cfg.systemd.services."agent-hub-llm".serviceConfig;
        observabilityUnit = cfg.systemd.services."prometheus".serviceConfig;
      };

      checked =
        if failed == [ ] then "OK: no failed assertions"
        else throw (lib.concatStringsSep "\n" messages);
    };
in
{
  # Real ac-box facts (56 threads / 251 GiB) with resources.nix's own tier
  # defaults (background trimmed to 0.30, see resources.nix's comment) --
  # must evaluate cleanly, and is where the derived MemoryMax/AllowedCPUs
  # numbers are checked against hand computation.
  good = mkCase [ ];

  # Same, but background.memoryShare forced back to the literal 0.35 first
  # suggested -- sum becomes 0.95 > 0.9 -- must fail the budget assertion.
  brokenBudget = mkCase [ ./fixtures/resources-broken-budget.nix ];
}
