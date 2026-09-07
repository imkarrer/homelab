# Otherwise clean (agent-hub at 8100, no collision) but assetto opens a
# forwarded port with no justification -- must fail on that alone.
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
