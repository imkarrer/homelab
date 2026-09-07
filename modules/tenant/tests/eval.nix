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
# throws (evaluation FAILS) if any assertion failed, and otherwise returns
# cleanly. `ok`/`messages` are non-throwing ways to inspect the same result.
{ lib ? (import <nixpkgs> { }).lib }:

let
  schema = ../schema.nix;
  ports = ../ports.nix;
  stubHost = ../tests/stub-host.nix;

  mkCase =
    fixture:
    let
      evaluated = lib.evalModules {
        modules = [
          stubHost
          schema
          ports
          fixture
        ];
      };

      failed = lib.filter (a: !a.assertion) evaluated.config.assertions;
      messages = map (a: a.message) failed;
    in
    {
      inherit (evaluated) config;
      ok = failed == [ ];
      inherit messages;
      firewall = evaluated.config.networking.firewall.interfaces;
      checked = if failed == [ ] then "OK: no failed assertions" else throw (lib.concatStringsSep "\n" messages);
    };
in
{
  # assetto slot 10 (8081+10) vs agent-hub.llm both on 8091 -- must fail.
  collision = mkCase ./fixtures/collision.nix;

  # Same fixture, agent-hub moved to 8100 -- must evaluate cleanly.
  clean = mkCase ./fixtures/clean.nix;

  # forwarded claim with no justification -- must fail.
  forwardedMissingJustification = mkCase ./fixtures/forwarded-missing-justification.nix;

  # Same, with justification supplied -- must evaluate cleanly.
  forwardedWithJustification = mkCase ./fixtures/forwarded-with-justification.nix;

  # mgmt claim while homelab.host.networks.mgmt.address is null -- must fail.
  mgmtNoAddress = mkCase ./fixtures/mgmt-no-address.nix;

  # Same, mgmt interface brought up -- must evaluate cleanly.
  mgmtWithAddress = mkCase ./fixtures/mgmt-with-address.nix;
}
