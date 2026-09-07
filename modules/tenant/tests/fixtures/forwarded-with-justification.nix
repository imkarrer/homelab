# Same as forwarded-missing-justification.nix but the forwarded claim carries
# a justification -- must evaluate cleanly.
{
  homelab.tenants.assetto = {
    description = "test";
    tier = "critical";
    portRanges.http = {
      start = 8081;
      count = 16;
    };
    ports.public-web = {
      number = 9443;
      scope = "forwarded";
      justification = "AC lobby browser needs to reach the web UI directly; unifi_pf.py forwards this port per README.";
    };
  };

  homelab.tenants.agent-hub = {
    description = "test";
    tier = "interactive";
    ports.llm = {
      number = 8100;
    };
  };
}
