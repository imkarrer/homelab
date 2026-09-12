# Host facts for tests/eval-metrics.nix: the two interfaces ac-box declares in
# hosts/ac-box/host.nix, with the same addresses -- lan up at 192.168.1.50,
# mgmt cabled but down (address = null). Declared against the REAL L0 option
# module (modules/platform/host-options.nix), which the harness imports the
# way flake.nix does, so the shape metrics.nix's address assertion reads is
# the production one rather than a stub's approximation.
#
# Kept apart from metrics-quiet-tenants.nix on purpose: that fixture is
# shared with tests/eval-quiet.nix, and quiet.nix's header pins that it reads
# nothing under homelab.host.*. Putting host facts in the shared fixture
# would make that harness carry an L0 module it has no reason to import.
#
# The literal 192.168.1.50 here is what metrics-quiet-tenants.nix's agent-hub
# entry must match -- see the comment there for why a fixture may write the
# literal while hosts/ac-box/tenants.nix must not.
{ ... }:
{
  homelab.host.networks = {
    lan = {
      interface = "enp8s0";
      address = "192.168.1.50";
      prefixLength = 24;
    };
    mgmt = {
      interface = "eno1";
      address = null;
    };
  };
}
