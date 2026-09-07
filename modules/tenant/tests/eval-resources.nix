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
# homelab.enforce.slices (modules/tenant/enforce.nix) gates systemd.slices,
# the per-unit Slice=/Nice= overrides, AND the activation-time capacity check
# (bundled with slices -- see resources.nix's config block for why: it has no
# enforce flag of its own, and validates the same capacity math the slices
# are built on). The 0.9 memoryShare budget assertion is evaluation-time only
# and is NOT gated, so `brokenBudget` below still fires it with the switch at
# its default (false).
#
# Usage:
#   nix --extra-experimental-features "nix-command flakes" eval \
#     -f modules/tenant/tests/eval-resources.nix <case>.<field>
#
# `good.checked` and `brokenBudget.checked` are the ones that behave the way
# a real NixOS build does: throw (evaluation FAILS) if any assertion or extra
# check failed, clean return otherwise.
{
  lib ? (import <nixpkgs> { }).lib,
  pkgs ? import <nixpkgs> { },
}:

let
  hostOptions = ../../platform/host-options.nix;
  hostFacts = ../../../hosts/ac-box/host.nix;
  schema = ../schema.nix;
  enforce = ../enforce.nix;
  resources = ../resources.nix;
  stubSystemd = ./stub-systemd.nix;
  tenants = ./fixtures/resources-tenants.nix;

  mkCase =
    {
      extraModules ? [ ],
      checks ? (_: [ ]),
    }:
    let
      evaluated = lib.evalModules {
        specialArgs = { inherit pkgs; };
        modules = [
          stubSystemd
          hostOptions
          hostFacts
          schema
          enforce
          resources
          tenants
        ]
        ++ extraModules;
      };

      cfg = evaluated.config;

      failedAssertions = lib.filter (a: !a.assertion) cfg.assertions;
      failedChecks = lib.filter (c: !c.assertion) (checks cfg);
      failedMessages = map (a: a.message) failedAssertions ++ map (c: c.message) failedChecks;

      # Guarded lookups: with enforce.slices = false, systemd.services has no
      # per-unit keys at all (resources.nix contributes nothing), so a plain
      # `cfg.systemd.services."x".serviceConfig` would throw "attribute
      # missing" rather than reading as empty.
      unitConfig = name: (cfg.systemd.services.${name} or { }).serviceConfig or null;
    in
    {
      inherit (evaluated) config;
      ok = failedMessages == [ ];
      messages = failedMessages;

      # The headline numbers this task asks to be proven, pulled out flat so
      # `nix eval -f ... good.summary` is one readable call.
      summary = {
        capacity = cfg.homelab.host.capacity;
        tiers = lib.mapAttrs (_: t: {
          memoryShare = t.memoryShare;
          cpuShare = t.cpuShare;
        }) cfg.homelab.tiers;
        slices = lib.mapAttrs (_: s: s.sliceConfig) cfg.systemd.slices;
        assettoUnit = unitConfig "ac-host-static";
        arcadeUnit = unitConfig "arcade-freeciv";
        agentHubUnit = unitConfig "agent-hub-llm";
        observabilityUnit = unitConfig "prometheus";
      };

      checked =
        if failedMessages == [ ] then
          "OK: no failed assertions/checks"
        else
          throw (lib.concatStringsSep "\n" failedMessages);
    };
in
{
  # Real ac-box facts (56 threads / 251 GiB) with resources.nix's own tier
  # defaults (background trimmed to 0.30, see resources.nix's comment), and
  # enforce.slices flipped on -- must evaluate cleanly, and is where the
  # derived MemoryMax/AllowedCPUs numbers are checked against hand
  # computation. This is the "all-true: behaviour unchanged" case.
  good = mkCase { extraModules = [ { homelab.enforce.slices = true; } ]; };

  # Same tenants/capacity, but homelab.enforce.slices left at its default
  # (false): systemd.slices, every per-unit serviceConfig, AND the
  # activation-time capacity check must be completely absent from config --
  # not present with empty sliceConfig/serviceConfig attrsets -- while the
  # budget assertion (evaluation-time only) still runs and still passes.
  allFalseNoSlicesEmitted = mkCase {
    checks = cfg: [
      {
        assertion = cfg.systemd.slices == { };
        message = "enforce.slices = false (default): systemd.slices must be {} -- resources.nix must contribute nothing at all";
      }
      {
        assertion = cfg.systemd.services == { };
        message = "enforce.slices = false (default): systemd.services must be {} -- no per-unit Slice=/Nice= may be emitted";
      }
      {
        assertion = !(cfg.system.activationScripts ? homelabCapacityCheck);
        message = "enforce.slices = false (default): system.activationScripts.homelabCapacityCheck must not exist -- it's a closure change bundled with the slices effect";
      }
    ];
  };

  # Same as brokenBudget below but explicit about the point of this task:
  # background.memoryShare forced back to 0.35 (sum 0.95 > 0.9) with
  # enforce.slices left at its default (false) -- the budget assertion must
  # STILL fail evaluation (assertions are unconditional), and on top of that
  # systemd.slices must still be completely empty, proving the assertion and
  # the effect are independent switches.
  brokenBudget = mkCase {
    extraModules = [ ./fixtures/resources-broken-budget.nix ];
    checks = cfg: [
      {
        assertion = cfg.systemd.slices == { };
        message = "enforce.slices = false (default): systemd.slices must stay {} even when the budget assertion is also failing";
      }
    ];
  };
}
