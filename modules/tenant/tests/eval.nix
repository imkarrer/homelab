# Eval harness for modules/tenant/ports.nix.
#
# Not a flake target -- this is a plain lib.evalModules fixture, invoked with
# `nix eval -f` -- but it is no longer *unpinned* for that reason. The header
# here used to say it ran against "whatever <nixpkgs> resolves to on the
# machine"; as of 9 Sep 2026 `lib` comes from ./pinned-nixpkgs.nix, which
# reads flake.lock and fetches the exact revision flake.nix pins. That
# closes finding F7 (docs/current-state.md): these assertions are the only
# proof a colliding fixture is still rejected, and proving it against a
# different lib than ac-box is built with proves nothing about ac-box. See
# pinned-nixpkgs.nix for the measurement showing the channel and the pin are
# genuinely two different trees on this machine.
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
# `lib` stays an argument so a caller can still inject one (the runner script
# does not, and does not need to), but the DEFAULT is now the pin rather than
# NIX_PATH. There is deliberately no <nixpkgs> fallback: an unpinned run must
# fail loudly, never quietly succeed against the wrong lib.
{ lib ? (import ./pinned-nixpkgs.nix).lib }:

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

  # Case name -> whether `<case>.checked` must evaluate cleanly (true) or
  # throw (false, for the fixtures above that exist to prove a bad config is
  # rejected). Read by modules/ci/scripts/run-eval-tests.sh; every case above
  # still supports the three manual `nix eval` invocations documented at the
  # top of this file, unchanged.
  expected = {
    collision = false;
    clean = true;
    forwardedMissingJustification = false;
    forwardedWithJustification = true;
    mgmtNoAddress = false;
    mgmtWithAddress = true;
    allFalseCollisionStillFails = false;
    allFalseNoFirewallEmitted = true;
    allTrueFirewallEmitted = true;
  };
}
