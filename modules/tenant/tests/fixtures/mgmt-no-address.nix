# A tenant scopes a claim to mgmt while the mgmt interface (stub-host.nix,
# matching llm-box's real unplugged port today) still has address = null -- must fail.
{
  homelab.tenants.observability = {
    description = "test";
    tier = "background";
    ports.node-exporter = {
      number = 9100;
      scope = "mgmt";
    };
  };
}
