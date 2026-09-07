# Eval harness for modules/tenant/ports.nix.
#
# Not a flake -- this repo doesn't have one yet -- so this runs against
# whatever <nixpkgs> resolves to on the machine. On ac-box's dev channel that
# is nixos-26.05, matching the README's pinned host channel.
#
# Usage:
#   nix --extra-experimental-features "nix-command flakes" eval \
#     -f modules/tenant/tests/eval.nix <case>.ok
#   nix --extra-experimental-features "nix-command flakes" eval \
#     -f modules/tenant/tests/eval.nix <case>.messages
#   nix --extra-experimental-features "nix-command flakes" eval \
#     -f modules/tenant/tests/eval.nix <case>.checked
#
# `checked` is the one that behaves the way a real NixOS build does: it
# throws (evaluation FAILS) if any assertion OR extra check failed, and
# otherwise returns cleanly. `ok`/`messages` are non-throwing ways to inspect
# the same result.
#
# homelab.enforce.firewall (modules/tenant/enforce.nix) gates the actual
# firewall effect; the port-registry assertions (collision,
# forwarded-justification, mgmt-address) are evaluation-time only and are
# NOT gated, so every existing case below still exercises them with the
# switch at its default (false). The allFalse*/allTrue* cases at the bottom
# are new: they prove (a) with enforce.firewall = false, ports.nix
# contributes NOTHING to networking.firewall.interfaces -- not an empty
# per-interface entry -- even on a fixture with real port claims and even on
# one with a real collision, and (b) with it flipped on, the firewall content
# is exactly what this module has always produced.
{ lib ? (import <nixpkgs> { }).lib }:

let
  schema = ../schema.nix;
  enforce = ../enforce.nix;
  ports = ../ports.nix;
  stubHost = ../tests/stub-host.nix;

  mkCase =
    {
      fixture,
      extraModules ? [ ],
      checks ? (_: [ ]),
    }:
    let
      evaluated = lib.evalModules {
        modules = [
          stubHost
          schema
          enforce
          ports
          fixture
        ]
        ++ extraModules;
      };

      cfg = evaluated.config;

      failedAssertions = lib.filter (a: !a.assertion) cfg.assertions;
      failedChecks = lib.filter (c: !c.assertion) (checks cfg);
      failedMessages = map (a: a.message) failedAssertions ++ map (c: c.message) failedChecks;
    in
    {
      inherit (evaluated) config;
      ok = failedMessages == [ ];
      messages = failedMessages;
      firewall = cfg.networking.firewall.interfaces;
      checked =
        if failedMessages == [ ] then
          "OK: no failed assertions/checks"
        else
          throw (lib.concatStringsSep "\n" failedMessages);
    };
in
{
  # assetto slot 10 (8081+10) vs agent-hub.llm both on 8091 -- must fail.
  collision = mkCase { fixture = ./fixtures/collision.nix; };

  # Same fixture, agent-hub moved to 8100 -- must evaluate cleanly.
  clean = mkCase { fixture = ./fixtures/clean.nix; };

  # forwarded claim with no justification -- must fail.
  forwardedMissingJustification = mkCase { fixture = ./fixtures/forwarded-missing-justification.nix; };

  # Same, with justification supplied -- must evaluate cleanly.
  forwardedWithJustification = mkCase { fixture = ./fixtures/forwarded-with-justification.nix; };

  # mgmt claim while homelab.host.networks.mgmt.address is null -- must fail.
  mgmtNoAddress = mkCase { fixture = ./fixtures/mgmt-no-address.nix; };

  # Same, mgmt interface brought up -- must evaluate cleanly.
  mgmtWithAddress = mkCase { fixture = ./fixtures/mgmt-with-address.nix; };

  # --- homelab.enforce.firewall coverage (beads homelab-bqo.15) ---

  # Default enforce.firewall = false, same colliding fixture as `collision`
  # above: the collision assertion must STILL fail evaluation (assertions are
  # unconditional), and on top of that, networking.firewall.interfaces must
  # be completely empty -- proving the firewall effect is off independently
  # of whether the assertion fires.
  allFalseCollisionStillFails = mkCase {
    fixture = ./fixtures/collision.nix;
    checks = cfg: [
      {
        assertion = cfg.networking.firewall.interfaces == { };
        message = "enforce.firewall = false (default): networking.firewall.interfaces must stay {} even on a fixture with a real collision";
      }
    ];
  };

  # Default enforce.firewall = false, collision-free fixture with real ports
  # declared on both lan and local scope: evaluation must succeed AND
  # networking.firewall.interfaces must be exactly {} -- not present with
  # empty allowedTCPPorts/allowedUDPPorts for enp8s0/eno1. This is the case
  # that would have caught the "empty-but-present" bug: an unconditional
  # `networking.firewall.interfaces.${lanIface} = { allowedTCPPorts = []; ...
  # }` would materialize the enp8s0 key even with nothing to open.
  allFalseNoFirewallEmitted = mkCase {
    fixture = ./fixtures/clean.nix;
    checks = cfg: [
      {
        assertion = cfg.networking.firewall.interfaces == { };
        message = "enforce.firewall = false (default): networking.firewall.interfaces must be {} -- ports.nix must contribute nothing at all";
      }
    ];
  };

  # Same clean fixture, enforce.firewall flipped on: must reproduce exactly
  # the firewall content this module has always produced -- assetto's
  # 8081-8096 range and agent-hub's 8100 on enp8s0 (lan), and arcade's
  # local-scope redis claim (6379) must NOT appear anywhere.
  allTrueFirewallEmitted = mkCase {
    fixture = ./fixtures/clean.nix;
    extraModules = [ { homelab.enforce.firewall = true; } ];
    checks = cfg: [
      {
        assertion = lib.all (
          p: lib.elem p cfg.networking.firewall.interfaces.enp8s0.allowedTCPPorts
        ) (lib.range 8081 8096);
        message = "enforce.firewall = true: enp8s0 allowedTCPPorts must include assetto's whole 8081-8096 range";
      }
      {
        assertion = lib.elem 8100 cfg.networking.firewall.interfaces.enp8s0.allowedTCPPorts;
        message = "enforce.firewall = true: enp8s0 allowedTCPPorts must include agent-hub's 8100";
      }
      {
        assertion = !(lib.elem 6379 cfg.networking.firewall.interfaces.enp8s0.allowedTCPPorts);
        message = "a local-scope claim (arcade redis, 6379) must never reach the firewall, enforce.firewall on or off";
      }
    ];
  };
}
