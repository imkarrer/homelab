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
# homelab.enforce.scrape (modules/tenant/enforce.nix) gates the whole
# scrapeConfigs effect; there are no assertions in metrics.nix to keep
# unconditional, so the two cases below are a straight on/off split.
#
# Usage:
#   nix --extra-experimental-features "nix-command flakes" eval \
#     -f modules/tenant/tests/eval-metrics.nix allTrue.checked
#   nix --extra-experimental-features "nix-command flakes" eval --json \
#     -f modules/tenant/tests/eval-metrics.nix allTrue.scrapeConfigs
#   nix --extra-experimental-features "nix-command flakes" eval \
#     -f modules/tenant/tests/eval-metrics.nix allFalse.checked
{ lib ? (import <nixpkgs> { }).lib }:

let
  schema = ../schema.nix;
  enforce = ../enforce.nix;
  metrics = ../metrics.nix;
  stubPrometheus = ./stub-prometheus.nix;
  tenants = ./fixtures/metrics-quiet-tenants.nix;

  mkCase =
    { extraModules ? [ ], checks }:
    let
      evaluated = lib.evalModules {
        modules = [
          stubPrometheus
          schema
          enforce
          metrics
          tenants
        ]
        ++ extraModules;
      };

      cfg = evaluated.config;
      scrapeConfigs = cfg.services.prometheus.scrapeConfigs;

      failed = lib.filter (c: !c.assertion) (checks cfg scrapeConfigs);
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
    };
in
{
  # enforce.scrape = true: behaviour unchanged from what this harness always
  # asserted -- same checks, just moved under this case name.
  allTrue = mkCase {
    extraModules = [ { homelab.enforce.scrape = true; } ];
    checks =
      cfg: scrapeConfigs:
      let
        byJob = lib.listToAttrs (map (c: lib.nameValuePair c.job_name c) scrapeConfigs);
      in
      [
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
  };

  # enforce.scrape left at its default (false): the same tenants fixture
  # (assetto/agent-hub/observability all declare real metrics endpoints)
  # must produce a completely empty scrapeConfigs -- not a list padded with
  # nothing, an actual [] contributed by nobody -- proving metrics.nix
  # contributes NOTHING to services.prometheus.scrapeConfigs when off.
  allFalse = mkCase {
    checks = cfg: scrapeConfigs: [
      {
        assertion = scrapeConfigs == [ ];
        message = "enforce.scrape = false (default): services.prometheus.scrapeConfigs must be [] even though assetto/agent-hub/observability all declare metrics endpoints";
      }
    ];
  };
}
