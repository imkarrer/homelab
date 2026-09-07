# Generates `services.prometheus.scrapeConfigs` from each tenant's `metrics`
# declaration (schema.nix). Pure function of `homelab.tenants.*` — it does not
# reach into any other tenant's or layer's state, per the one-way dependency
# rule in README.md ("L1 knows only the schema").
#
# `job` defaults to the tenant name (schema.nix, metricsEndpoint.job). Set it
# explicitly to preserve an existing Prometheus job name when it differs from
# the tenant name — renaming a job orphans the Grafana dashboards built on it.
# The hand-written jobs in ac-box:/var/lib/ac-host/src/modules/monitoring.nix
# ("node", "cadvisor", "unpoller", "udr-fw", "docker-names") are the reason
# this override exists: whichever tenant ends up owning one of those
# exporters must be able to declare `metrics.job = "<old name>";` and get
# byte-identical `job_name` and `static_configs` out of this module.
#
# Convention: a tenant's metrics endpoint is always scraped over loopback.
# schema.nix's `metricsEndpoint` deliberately has no address field — every
# exporter in monitoring.nix today binds 127.0.0.1 (Prometheus itself listens
# on 127.0.0.1 there too), and nothing in the contract needs a tenant to
# expose metrics off-box. If that ever changes it's a schema change, not a
# metrics.nix change.
{ config, lib, ... }:

let
  inherit (lib) filterAttrs mapAttrsToList optionalAttrs;

  tenants = config.homelab.tenants;

  # Only enabled tenants that opted into a metrics endpoint at all.
  tenantsWithMetrics = filterAttrs (_: t: t.enable && t.metrics != null) tenants;

  toScrapeConfig =
    name: t:
    let
      m = t.metrics;
    in
    {
      job_name = if m.job != null then m.job else name;
      scrape_interval = m.interval;
      static_configs = [ { targets = [ "127.0.0.1:${toString m.port}" ]; } ];
    }
    # Match monitoring.nix's existing style: only mention metrics_path when
    # it's not Prometheus' own default, so tenants that don't customize it
    # produce the same minimal scrapeConfig shape as the hand-written jobs.
    // optionalAttrs (m.path != "/metrics") { metrics_path = m.path; };

in
{
  config.services.prometheus.scrapeConfigs = mapAttrsToList toScrapeConfig tenantsWithMetrics;
}
