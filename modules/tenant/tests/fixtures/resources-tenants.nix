# Fixture tenants for resources.nix's eval harness. Real, pinned tenant
# names (README: "Tenant names are exactly...") and real, pinned unit names
# (README: "Unit and container names never change") for the ones the README
# already names; "observability" doesn't have a named unit in README.md yet,
# so it gets a plausible placeholder here -- this is test-only data, not a
# production tenant declaration, so inventing a unit name for it doesn't
# collide with the stability rule.
{
  homelab.tenants = {
    assetto = {
      description = "AC race servers";
      tier = "critical";
      units = [ "ac-host-static" ];
    };

    arcade = {
      description = "Kid arcade hub";
      tier = "background";
      units = [ "arcade-freeciv" "arcade-mindustry" ];
    };

    agent-hub = {
      description = "CPU-only LLM server";
      tier = "batch";
      units = [ "agent-hub-llm" ];
    };

    observability = {
      description = "Prometheus/Grafana stack";
      tier = "interactive";
      units = [ "prometheus" ];
    };
  };
}
