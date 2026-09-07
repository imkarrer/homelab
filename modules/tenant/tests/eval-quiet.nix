# Eval harness for modules/tenant/quiet.nix.
#
# Not a flake -- this repo doesn't have one yet -- so this runs against
# whatever <nixpkgs> resolves to on the machine, same as tests/eval.nix
# (ports.nix's harness). quiet.nix is pure over homelab.tenants (no host
# facts -- see quiet.nix's own header for why it deliberately does not read
# homelab.host.maintenance.window even though modules/platform/host-options.nix
# now declares it), so only the one leaf it writes to is stubbed:
# environment.etc (tests/stub-etc.nix).
#
# Usage:
#   nix --extra-experimental-features "nix-command flakes" eval \
#     -f modules/tenant/tests/eval-quiet.nix checked
#   nix --extra-experimental-features "nix-command flakes" eval --json \
#     -f modules/tenant/tests/eval-quiet.nix tenantsJson
{ lib ? (import <nixpkgs> { }).lib }:

let
  schema = ../schema.nix;
  quiet = ../quiet.nix;
  stubEtc = ./stub-etc.nix;
  tenants = ./fixtures/metrics-quiet-tenants.nix;

  evaluated = lib.evalModules {
    modules = [
      stubEtc
      schema
      quiet
      tenants
    ];
  };

  etcFile = evaluated.config.environment.etc."homelab/tenants.json";
  tenantsJson = builtins.fromJSON etcFile.text;
  byName = lib.listToAttrs (map (t: lib.nameValuePair t.name t) tenantsJson.tenants);

  checks = [
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

  failed = lib.filter (c: !c.assertion) checks;
in
{
  inherit tenantsJson;
  mode = etcFile.mode;
  ok = failed == [ ];
  messages = map (c: c.message) failed;
  checked =
    if failed == [ ] then
      "OK: all checks passed"
    else
      throw (lib.concatStringsSep "\n" (map (c: c.message) failed));
}
