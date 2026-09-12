# Generates `services.prometheus.scrapeConfigs` from each tenant's `metrics`
# declaration (schema.nix). A function of `homelab.tenants.*` plus ONE host
# fact, `homelab.host.networks.*.address`, read only to check that a declared
# scrape address is somewhere this host actually is -- the same L1-reads-L0
# relationship ports.nix has with `homelab.host.networks.*.interface` and
# resources.nix has with `homelab.host.capacity`. It still reaches into no
# other tenant's state, per the one-way dependency rule in README.md ("L1
# knows only the schema").
#
# `job` defaults to the tenant name (schema.nix, metricsEndpoint.job). Set it
# explicitly to preserve an existing Prometheus job name when it differs from
# the tenant name -- renaming a job orphans the Grafana dashboards built on it.
# The hand-written jobs in ac-box:/var/lib/ac-host/src/modules/monitoring.nix
# ("node", "cadvisor", "unpoller", "udr-fw", "docker-names") are the reason
# this override exists: whichever tenant ends up owning one of those
# exporters must be able to declare `metrics.job = "<old name>";` and get
# byte-identical `job_name` and `static_configs` out of this module.
#
# Address. Until 12 Sep 2026 this header pinned "a tenant's metrics endpoint
# is always scraped over loopback" as the convention and the target was
# hardcoded 127.0.0.1:<port>; schema.nix's metricsEndpoint had no address
# field and this comment said adding one was a schema change, not a
# metrics.nix change. That change has now been made (delta row 12,
# docs/architecture.md), for agent-hub: llama-server binds the LAN address
# only (`--host 192.168.1.50 --metrics`, ExecStart of agent-hub-llm.service,
# generation 32) and refuses on loopback, so no loopback job could ever
# scrape it. Two things are preserved from the old convention:
#
#   - loopback is still the DEFAULT (schema.nix), so every declaration that
#     never mentions an address produces exactly the target it always did.
#     tests/eval-metrics.nix pins the node and docker-names reproductions.
#
#   - a non-loopback address must be one the host declares
#     (homelab.host.networks.<name>.address, non-null). That is the
#     assertion below, and it is the metrics analogue of ports.nix's rule
#     that nothing may be scoped to mgmt until mgmt has an address: a
#     scrape target is a place Prometheus CONNECTS to, so "0.0.0.0" (a bind
#     wildcard), a hostname, or an address belonging to some other box are
#     all declarations that would evaluate fine and then fail on every
#     scrape interval. The assertion runs over every tenant that declares
#     an endpoint, enabled or not, for the same reason ports.nix checks
#     disabled tenants' claims: a wrong declaration should fail when it is
#     written, not on the day the tenant is switched on.
{ config, lib, ... }:

let
  inherit (lib)
    filterAttrs
    mapAttrsToList
    optionalAttrs
    mkIf
    mkMerge
    filter
    elem
    concatStringsSep
    ;

  tenants = config.homelab.tenants;

  loopback = "127.0.0.1";

  # Every tenant that declares an endpoint at all, enabled or not -- the
  # population the address assertion reads. See the header for why disabled
  # tenants are included here but excluded from the scrape output.
  tenantsDeclaringMetrics = filterAttrs (_: t: t.metrics != null) tenants;

  # Only enabled tenants that opted into a metrics endpoint at all.
  tenantsWithMetrics = filterAttrs (_: t: t.enable) tenantsDeclaringMetrics;

  # The addresses this host actually has. mgmt's is null on ac-box today
  # (eno1 cabled but down, hosts/ac-box/host.nix), so it is filtered out here
  # rather than compared against -- a tenant referencing
  # homelab.host.networks.mgmt.address would already fail schema.nix's
  # `types.str` on the null, but a literal of what mgmt WILL be must fail
  # too, and this is where.
  hostAddresses = filter (a: a != null) (
    mapAttrsToList (_: n: n.address) config.homelab.host.networks
  );

  addressAssertions = mapAttrsToList (name: t: {
    assertion = t.metrics.address == loopback || elem t.metrics.address hostAddresses;
    message = "homelab.tenants.${name}.metrics.address = \"${t.metrics.address}\" is neither loopback (${loopback}) nor an address this host declares in homelab.host.networks (${
      if hostAddresses == [ ] then "none with an address" else concatStringsSep ", " hostAddresses
    }). A scrape target is somewhere Prometheus connects to; set it by reference to homelab.host.networks.<name>.address, not as a literal.";
  }) tenantsDeclaringMetrics;

  toScrapeConfig =
    name: t:
    let
      m = t.metrics;
    in
    {
      job_name = if m.job != null then m.job else name;
      scrape_interval = m.interval;
      static_configs = [ { targets = [ "${m.address}:${toString m.port}" ]; } ];
    }
    # Match monitoring.nix's existing style: only mention metrics_path when
    # it's not Prometheus' own default, so tenants that don't customize it
    # produce the same minimal scrapeConfig shape as the hand-written jobs.
    // optionalAttrs (m.path != "/metrics") { metrics_path = m.path; };

in
{
  config = mkMerge [
    # Evaluation-time only, so unconditional -- independent of
    # homelab.enforce.scrape, the same way ports.nix's collision and mgmt
    # checks run with enforce.firewall off (see enforce.nix's header). A bad
    # address is rejected whether or not the scrape effect is switched on.
    { assertions = addressAssertions; }

    # mkIf, not an unconditional list that happens to be empty when off: an
    # mkIf false contributes NOTHING to services.prometheus.scrapeConfigs --
    # not a [] entry merged in alongside whatever else sets it -- see
    # tests/eval-metrics.nix's allFalse case, which asserts scrapeConfigs is
    # [] with the switch off even though three fixture tenants declare real
    # endpoints, and its allFalseAddressStillAsserted case, which proves the
    # assertion above fires regardless.
    (mkIf config.homelab.enforce.scrape {
      services.prometheus.scrapeConfigs = mapAttrsToList toScrapeConfig tenantsWithMetrics;
    })
  ];
}
