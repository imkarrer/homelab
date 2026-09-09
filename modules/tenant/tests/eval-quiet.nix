# Eval harness for modules/tenant/quiet.nix.
#
# Not a flake target -- a plain lib.evalModules fixture invoked with
# `nix eval -f`, same as tests/eval.nix (ports.nix's harness) -- but `lib`
# comes from ./pinned-nixpkgs.nix (flake.lock's revision) rather than from
# <nixpkgs>/NIX_PATH, as of 9 Sep 2026; see that file for why, and for the
# finding (F7) it closes. quiet.nix is pure over homelab.tenants (no host
# facts -- see quiet.nix's own header for why it deliberately does not read
# homelab.host.maintenance.window even though modules/platform/host-options.nix
# now declares it), so only the one leaf it writes to is stubbed:
# environment.etc (tests/stub-etc.nix).
#
# homelab.enforce.inventory (modules/tenant/enforce.nix) gates the whole
# /etc/homelab/tenants.json effect; there are no assertions in quiet.nix to
# keep unconditional, so the two cases below are a straight on/off split.
#
# Usage:
#   nix --extra-experimental-features "nix-command flakes" eval \
#     -f modules/tenant/tests/eval-quiet.nix allTrue.checked
#   nix --extra-experimental-features "nix-command flakes" eval --json \
#     -f modules/tenant/tests/eval-quiet.nix allTrue.tenantsJson
#   nix --extra-experimental-features "nix-command flakes" eval \
#     -f modules/tenant/tests/eval-quiet.nix allFalse.checked
# No <nixpkgs> fallback, deliberately: an unpinned run must fail loudly.
{ lib ? (import ./pinned-nixpkgs.nix).lib }:

let
  schema = ../schema.nix;
  enforce = ../enforce.nix;
  quiet = ../quiet.nix;
  stubEtc = ./stub-etc.nix;
  tenants = ./fixtures/metrics-quiet-tenants.nix;

  mkCase =
    { extraModules ? [ ], checks }:
    let
      evaluated = lib.evalModules {
        modules = [
          stubEtc
          schema
          enforce
          quiet
          tenants
        ]
        ++ extraModules;
      };

      cfg = evaluated.config;
      hasFile = cfg.environment.etc ? "homelab/tenants.json";

      failed = lib.filter (c: !c.assertion) (checks cfg hasFile);
    in
    {
      ok = failed == [ ];
      messages = map (c: c.message) failed;
      checked =
        if failed == [ ] then
          "OK: all checks passed"
        else
          throw (lib.concatStringsSep "\n" (map (c: c.message) failed));
    }
    // lib.optionalAttrs hasFile (
      let
        etcFile = cfg.environment.etc."homelab/tenants.json";
      in
      {
        mode = etcFile.mode;
        tenantsJson = builtins.fromJSON etcFile.text;
      }
    );
in
{
  # enforce.inventory = true: behaviour unchanged from what this harness
  # always asserted -- same checks, just moved under this case name.
  allTrue = mkCase {
    extraModules = [ { homelab.enforce.inventory = true; } ];
    checks =
      cfg: hasFile:
      let
        etcFile = cfg.environment.etc."homelab/tenants.json";
        tenantsJson = builtins.fromJSON etcFile.text;
        byName = lib.listToAttrs (map (t: lib.nameValuePair t.name t) tenantsJson.tenants);
      in
      [
        {
          assertion = hasFile;
          message = "enforce.inventory = true: /etc/homelab/tenants.json must be written";
        }
        {
          assertion = etcFile.mode == "0444";
          message = "tenants.json must be world-readable, not writable -- it's boxctl's read-only input";
        }
        {
          assertion = lib.length tenantsJson.tenants == 4;
          message = "expected exactly 4 tenants (assetto, arcade, agent-hub, observability) -- the disabled ci tenant must be excluded entirely";
        }
        {
          assertion = !(byName ? ci);
          message = "a disabled tenant must not appear in tenants.json at all";
        }
        {
          assertion = byName.assetto.quiet == {
            drainable = false;
            busyCheck = "/run/current-system/sw/bin/true";
            drain = null;
            resume = null;
          };
          message = "quiet policy must pass through unchanged (drainable + busyCheck, plus drain/resume)";
        }
        {
          assertion = byName.assetto.units == [
            "ac-host-static.service"
            "docker.service"
          ];
          message = "units must be reproduced verbatim, in declared order, unrenamed";
        }
        {
          assertion = byName.assetto.ports.web.number == 8090 && byName.assetto.ports.web.scope == "lan";
          message = "explicit port claims must be included";
        }
        {
          assertion =
            byName.assetto.portRanges.lobbies.start == 9600 && byName.assetto.portRanges.lobbies.count == 20;
          message = "port ranges must be included";
        }
        {
          assertion = byName.observability.quiet.drainable == false && byName.observability.quiet.busyCheck == null;
          message = "a tenant with drainable = false and no busyCheck must still round-trip (busyCheck: null)";
        }
        {
          assertion = byName.arcade.quiet.drainable == true;
          message = "a drainable tenant's policy must round-trip too";
        }
        {
          assertion = !(tenantsJson ? maintenanceWindow);
          message = "tenants.json must NOT embed homelab.host.maintenance.window -- that's an L0 fact, out of scope for a module that only knows the tenant schema (see quiet.nix's header)";
        }
      ];
  };

  # enforce.inventory left at its default (false): the same tenants fixture
  # (real units, ports, quiet policies) must NOT produce
  # /etc/homelab/tenants.json at all -- not a present-but-empty file, no key
  # named "homelab/tenants.json" in environment.etc whatsoever -- proving
  # quiet.nix contributes NOTHING when off.
  allFalse = mkCase {
    checks = cfg: hasFile: [
      {
        assertion = !hasFile;
        message = "enforce.inventory = false (default): environment.etc must not contain \"homelab/tenants.json\" at all, even though the fixture declares real tenants/units/ports";
      }
    ];
  };

  # Case name -> whether `<case>.checked` must evaluate cleanly. Both cases
  # here are positive (on/off behaviour), neither is a rejected-bad-config
  # fixture. Read by modules/ci/scripts/run-eval-tests.sh.
  expected = {
    allTrue = true;
    allFalse = true;
  };
}
