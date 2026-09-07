# Eval harness for modules/tenant/metrics.nix.
#
# Not a flake -- this repo doesn't have one yet -- so this runs against
# whatever <nixpkgs> resolves to on the machine, same as tests/eval.nix
# (ports.nix's harness). metrics.nix is pure over homelab.tenants (no host
# facts), so only the one leaf it writes to is stubbed:
# services.prometheus.scrapeConfigs (tests/stub-prometheus.nix).
#
# The two expected job_name/target pairs below are transcribed verbatim from
# ac-box:/var/lib/ac-host/src/modules/monitoring.nix's "node" and
# "docker-names" jobs. This task's ask is that renaming a job must be
# possible via `metrics.job`, and that the reproduced job_name/target be
# byte-identical to what's hand-written there today; metric_relabel_configs
# is curation outside this module's contract (schema.nix's metricsEndpoint
# has no such field) and is deliberately not reproduced.
#
# Usage:
#   nix --extra-experimental-features "nix-command flakes" eval \
#     -f modules/tenant/tests/eval-metrics.nix checked
#   nix --extra-experimental-features "nix-command flakes" eval --json \
#     -f modules/tenant/tests/eval-metrics.nix scrapeConfigs
{ lib ? (import <nixpkgs> { }).lib }:

let
  schema = ../schema.nix;
  metrics = ../metrics.nix;
  stubPrometheus = ./stub-prometheus.nix;
  tenants = ./fixtures/metrics-quiet-tenants.nix;

  evaluated = lib.evalModules {
    modules = [
      stubPrometheus
      schema
      metrics
      tenants
    ];
  };

  scrapeConfigs = evaluated.config.services.prometheus.scrapeConfigs;

  byJob = lib.listToAttrs (map (c: lib.nameValuePair c.job_name c) scrapeConfigs);

  checks = [
    {
      assertion =
        (byJob.node or null) != null
        && byJob.node.static_configs == [ { targets = [ "127.0.0.1:9100" ]; } ];
      message = ''job "node" (observability's override) must reproduce monitoring.nix's target 127.0.0.1:9100 exactly'';
    }
    {
      assertion =
        (byJob."docker-names" or null) != null
        && byJob."docker-names".static_configs == [ { targets = [ "127.0.0.1:9132" ]; } ];
      message = ''job "docker-names" (assetto's override) must reproduce monitoring.nix's target 127.0.0.1:9132 exactly'';
    }
    {
      assertion = (byJob."agent-hub" or null) != null;
      message = "a tenant with no `job` override must default job_name to its own tenant name";
    }
    {
      assertion = (byJob."agent-hub".metrics_path or null) == "/v1/metrics";
      message = "a non-default metrics.path must appear as metrics_path";
    }
    {
      assertion = !(lib.hasAttr "metrics_path" byJob.node);
      message = "a default metrics.path (/metrics) must NOT add a metrics_path key, matching monitoring.nix's own minimal style";
    }
    {
      assertion = lib.length scrapeConfigs == 3;
      message = "expected exactly 3 scrapeConfigs (assetto, agent-hub, observability) -- arcade (no metrics) and the disabled ci tenant must be excluded";
    }
    {
      assertion = !(lib.any (c: c.job_name == "should-not-appear") scrapeConfigs);
      message = "a disabled tenant's metrics declaration must not produce a scrapeConfig at all";
    }
  ];

  failed = lib.filter (c: !c.assertion) checks;
in
{
  inherit scrapeConfigs;
  ok = failed == [ ];
  messages = map (c: c.message) failed;
  checked =
    if failed == [ ] then
      "OK: all checks passed"
    else
      throw (lib.concatStringsSep "\n" (map (c: c.message) failed));
}
