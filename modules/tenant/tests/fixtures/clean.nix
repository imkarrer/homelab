# Same shape as collision.nix, but agent-hub moved to 8100 -- no overlap with
# assetto's 8081-8096 range. Also carries one `local`-scope claim (arcade's
# redis) to prove local claims never reach the firewall.
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
      number = 8100;
    };
  };

  homelab.tenants.arcade = {
    description = "test";
    tier = "interactive";
    ports.redis = {
      number = 6379;
      scope = "local";
    };
  };
}
