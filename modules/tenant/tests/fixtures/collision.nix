# assetto's slot 10 (8081 + 10 = 8091) collides with agent-hub's llm port.
{
  homelab.tenants.assetto = {
    description = "test";
    tier = "critical";
    portRanges.http = {
      start = 8081;
      count = 16;
    };
  };

  homelab.tenants.agent-hub = {
    description = "test";
    tier = "interactive";
    ports.llm = {
      number = 8091;
    };
  };
}
