# Same mgmt claim as mgmt-no-address.nix, but this fixture also brings the
# mgmt interface up (overriding stub-host.nix's default) -- must evaluate
# cleanly.
{
  homelab.host.networks.mgmt.address = "10.0.0.2";

  homelab.tenants.observability = {
    description = "test";
    tier = "background";
    ports.node-exporter = {
      number = 9100;
      scope = "mgmt";
    };
  };
}
