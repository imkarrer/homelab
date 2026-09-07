# Writes /etc/homelab/tenants.json — the machine-readable surface `boxctl`
# (pkgs/boxctl) reads to know which units belong to which tenant, what tier
# and quiet policy govern them, and what ports they claim.
#
# Pure function of `homelab.tenants.*`, same rule as metrics.nix: this file
# does not read homelab.host.* or anything else outside the tenant schema
# (README.md: "L1 knows only the schema"). In particular it does NOT embed
# `homelab.host.maintenance.window` — even though modules/platform/
# host-options.nix now declares it, that's still an L0 fact, not part of the
# tenant contract, and this module has no business reaching across layers for
# it. boxctl takes the maintenance window as its own parameter (default
# matches hosts/ac-box/host.nix's current "03:00") instead of round-tripping
# it through this file.
{ config, lib, ... }:

let
  inherit (lib) filterAttrs mapAttrsToList mkIf;

  tenants = config.homelab.tenants;

  # Disabled tenants own no units right now; boxctl has nothing to plan
  # around for them.
  enabledTenants = filterAttrs (_: t: t.enable) tenants;

  toEntry = name: t: {
    inherit name;
    tier = t.tier;
    units = t.units;
    # quietPolicy is already a flat { drainable, busyCheck, drain, resume }
    # attrset once evaluated — pass it straight through rather than
    # re-deriving a shape that would just have to be kept in sync by hand.
    quiet = t.quiet;
    ports = t.ports;
    portRanges = t.portRanges;
  };

in
{
  # mkIf, not an unconditional environment.etc entry: an mkIf false
  # contributes NOTHING to environment.etc -- the "homelab/tenants.json" key
  # is entirely absent, not present with empty/placeholder content -- see
  # tests/eval-quiet.nix's allFalse case.
  config = mkIf config.homelab.enforce.inventory {
    environment.etc."homelab/tenants.json" = {
      mode = "0444";
      text = builtins.toJSON {
        generated = "modules/tenant/quiet.nix";
        tenants = mapAttrsToList toEntry enabledTenants;
      };
    };
  };
}
