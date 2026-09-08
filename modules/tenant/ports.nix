# The port registry. Consumes modules/tenant/schema.nix; declares no new
# options of its own beyond what NixOS already provides (assertions,
# networking.firewall.interfaces).
#
# What this module does, in order:
#
#   1. Expands every tenant's `portRanges` into individual claims (one per
#      slot in the range) and flattens them alongside `ports` into one list.
#      A range claim named "http" with start=8081/count=16 becomes claims
#      labelled "http[0]".."http[15]", numbered 8081..8096.
#
#   2. Fans each claim out once per declared protocol (a claim can declare
#      proto = [ "tcp" "udp" ]) and groups the result by "<proto>/<number>"
#      across EVERY tenant. Any key with more than one claimant is a
#      double-booking and becomes a failing assertion naming all claimants.
#      This intentionally also catches a single tenant clobbering itself.
#
#   3. Derives networking.firewall purely from `scope`, per-interface:
#        local      never touches the firewall (bound to loopback only)
#        lan        opened on homelab.host.networks.lan.interface
#        forwarded  opened on the SAME lan interface -- forwarding happens at
#                   the router (unifi_pf.py), the box still only ever sees it
#                   arrive on the LAN NIC -- but requires `justification`
#        mgmt       opened on homelab.host.networks.mgmt.interface, and only
#                   once that interface actually has an address
#      Global networking.firewall.allowedTCPPorts/allowedUDPPorts is never
#      touched -- every opening is scoped to the interface it arrives on.
{ config, lib, ... }:

let
  inherit (lib)
    mkIf
    mkMerge
    concatMap
    concatLists
    concatStringsSep
    filter
    length
    range
    groupBy
    mapAttrsToList
    optionals
    ;

  tenants = config.homelab.tenants;
  netCfg = config.homelab.host.networks;
  enforceFirewall = config.homelab.enforce.firewall;

  # A single explicit `ports.<name>` claim, unpacked to the shape the rest of
  # this file works with. `proto` stays a list here; it's fanned out later.
  explodeClaim =
    tenantName: claimName: claim:
    [
      {
        label = "${tenantName}.${claimName}";
        inherit (claim) number proto scope justification;
      }
    ];

  # A `portRanges.<name>` block, unpacked into `count` individual claims.
  # Index 0 is `start` itself, so "web[10]" is port `start + 10`.
  explodeRange =
    tenantName: claimName: r:
    map (i: {
      label = "${tenantName}.${claimName}[${toString i}]";
      number = r.start + i;
      inherit (r) proto scope justification;
    }) (range 0 (r.count - 1));

  # `enabled` rides along on every claim because the two consumers below want
  # DIFFERENT populations, and conflating them was a live bug:
  #
  #   - collision / justification / mgmt assertions read every claim, enabled
  #     or not. A disabled tenant's numbers are still spoken for (agent-hub's
  #     8100 was moved off 8091 precisely because the registry caught the
  #     clash while the tenant was disabled), so filtering here would let a
  #     second tenant claim a port and nobody would find out until runtime.
  #
  #   - the firewall effect must read ONLY enabled tenants. It did not, and
  #     the consequence was live on ac-box: with homelab.tenants.agent-hub
  #     .enable = false, `iptables -S` still showed
  #     `-A nixos-fw -i enp8s0 -p tcp --dport 8100 -j nixos-fw-accept` with
  #     nothing listening behind it. resources.nix and quiet.nix both filter
  #     on enable (enabledTenants / the tenants.json inventory, which
  #     correctly had no agent-hub entry); this file was the outlier, and
  #     tenants.nix's comment claiming enable=false held the port shut was
  #     describing an intention the code did not implement.
  claimsOfTenant =
    tenantName: tenant:
    map (c: c // { inherit (tenant) enable; }) (
      concatLists (mapAttrsToList (explodeClaim tenantName) tenant.ports)
      ++ concatLists (mapAttrsToList (explodeRange tenantName) tenant.portRanges)
    );

  # One entry per claim, across every tenant. `proto` is still the list from
  # the schema at this point.
  allClaims = concatLists (mapAttrsToList claimsOfTenant tenants);

  # Fan each claim out to one row per protocol it declares, so a claim on
  # proto = [ "tcp" "udp" ] is checked -- and opened -- independently on both.
  perProto = concatMap (c: map (p: c // { proto = p; }) c.proto) allClaims;

  keyOf = c: "${c.proto}/${toString c.number}";

  collisions = lib.filterAttrs (_: cs: length cs > 1) (groupBy keyOf perProto);

  collisionAssertions = mapAttrsToList (key: cs: {
    assertion = false;
    message = "${key} claimed by ${concatStringsSep ", " (map (c: c.label) cs)}";
  }) collisions;

  forwardedClaims = filter (c: c.scope == "forwarded") allClaims;

  forwardedAssertions = map (c: {
    assertion = c.justification != null;
    message = "${c.label} (${concatStringsSep "+" c.proto}/${toString c.number}): scope = \"forwarded\" requires a justification -- being internet-facing is a decision, not a default.";
  }) forwardedClaims;

  mgmtClaims = filter (c: c.scope == "mgmt") allClaims;

  mgmtAssertions = optionals (mgmtClaims != [ ]) [
    {
      assertion = netCfg.mgmt.address != null;
      message = "homelab.host.networks.mgmt has no address, but ${concatStringsSep ", " (
        map (c: c.label) mgmtClaims
      )} declare scope = \"mgmt\". Nothing may be scoped to mgmt until that interface is up.";
    }
  ];

  # `c.enable` here, unlike everywhere else in this file: a rule is only
  # emitted for a tenant that is actually turned on. See claimsOfTenant.
  portsOn =
    scope: proto:
    map (c: c.number) (filter (c: c.enable && c.scope == scope && c.proto == proto) perProto);

  lanIface = netCfg.lan.interface;
  mgmtIface = netCfg.mgmt.interface;

  lanTcp = portsOn "lan" "tcp" ++ portsOn "forwarded" "tcp";
  lanUdp = portsOn "lan" "udp" ++ portsOn "forwarded" "udp";
  mgmtTcp = portsOn "mgmt" "tcp";
  mgmtUdp = portsOn "mgmt" "udp";
in
{
  config = mkMerge [
    # Assertions are evaluation-time only -- they cost nothing in the closure
    # -- so they run unconditionally, independent of homelab.enforce.firewall
    # (declared in enforce.nix). This is what lets the contract ship before
    # any of its effects are turned on: the collision, forwarded-justification
    # and mgmt-address checks all still fire with the switch off.
    {
      assertions = collisionAssertions ++ forwardedAssertions ++ mgmtAssertions;
    }

    # The actual firewall effect. Wrapped in mkIf rather than left
    # unconditional with empty lists when off: an mkIf false contributes
    # NOTHING to networking.firewall.interfaces -- not an entry with empty
    # allowedTCPPorts/allowedUDPPorts -- which matters because even an empty
    # per-interface block is a definition the real firewall module has to
    # process. See tests/eval.nix's allFalse case, which asserts the
    # attribute is entirely absent from config.
    (mkIf enforceFirewall {
      # Two separate fragments merged through the option system (rather than
      # a single `//`-built attrset) so this doesn't blow up if lanIface and
      # mgmtIface were ever the same string.
      networking.firewall.interfaces = mkMerge [
        {
          ${lanIface} = {
            allowedTCPPorts = lanTcp;
            allowedUDPPorts = lanUdp;
          };
        }
        {
          ${mgmtIface} = {
            allowedTCPPorts = mgmtTcp;
            allowedUDPPorts = mgmtUdp;
          };
        }
      ];
    })
  ];
}
