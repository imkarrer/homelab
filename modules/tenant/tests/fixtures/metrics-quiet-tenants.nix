# Shared homelab.tenants fixture for tests/eval-metrics.nix and
# tests/eval-quiet.nix. One fixture rather than two near-duplicates because
# both modules are pure functions of the same `homelab.tenants` shape and
# this exercises both at once: default job-name-from-tenant, an explicit
# `job` override that reproduces an existing ac-box exporter's job/target
# (see monitoring.nix), a non-default metrics path, a tenant with no metrics
# endpoint at all, quiet-policy variety (drainable, busyCheck, neither), port
# claims, and a disabled tenant that must be excluded from BOTH modules'
# output.
{ ... }:
{
  homelab.tenants = {
    assetto = {
      description = "Assetto Corsa race servers";
      tier = "critical";
      units = [
        "ac-host-static.service"
        "docker.service"
      ];
      quiet = {
        drainable = false;
        busyCheck = "/run/current-system/sw/bin/true";
      };
      ports.web = {
        number = 8090;
        scope = "lan";
      };
      portRanges.lobbies = {
        start = 9600;
        count = 20;
        proto = [
          "udp"
          "tcp"
        ];
        scope = "forwarded";
        justification = "AC lobbies are internet-facing by design; unifi_pf.py forwards per slot.";
      };
      # Reproduces the hand-written "docker-names" job from monitoring.nix:
      # same job_name, same target, even though the tenant is "assetto".
      metrics = {
        port = 9132;
        job = "docker-names";
      };
    };

    arcade = {
      description = "Kid arcade hub";
      tier = "interactive";
      units = [
        "arcade-freeciv.service"
        "arcade-mindustry.service"
      ];
      quiet.drainable = true;
      # No metrics endpoint declared at all.
    };

    agent-hub = {
      description = "CPU-only LLM server";
      tier = "background";
      units = [ "agent-hub-llm.service" ];
      quiet.drainable = true;
      # job omitted -> defaults to the tenant name "agent-hub". Non-default
      # path exercises the metrics_path branch.
      metrics = {
        port = 9200;
        path = "/v1/metrics";
      };
    };

    observability = {
      description = "Prometheus/Grafana stack";
      tier = "critical";
      units = [
        "prometheus.service"
        "grafana.service"
      ];
      quiet = {
        drainable = false;
        busyCheck = null;
      };
      # Reproduces the hand-written "node" job from monitoring.nix.
      metrics = {
        port = 9100;
        job = "node";
      };
    };

    ci = {
      enable = false;
      description = "Buildkite runner (disabled in this fixture)";
      tier = "batch";
      units = [ "buildkite-agent.service" ];
      quiet.drainable = true;
      # Even though this looks like a real exporter, a disabled tenant must
      # not appear in scrapeConfigs or tenants.json.
      metrics = {
        port = 9999;
        job = "should-not-appear";
      };
    };
  };
}
