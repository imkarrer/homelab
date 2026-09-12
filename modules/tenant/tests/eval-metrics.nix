# Eval harness for modules/tenant/metrics.nix.
#
# Not a flake target -- a plain lib.evalModules fixture invoked with
# `nix eval -f`, same as tests/eval.nix (ports.nix's harness) -- but `lib`
# comes from ./pinned-nixpkgs.nix (flake.lock's revision) rather than from
# <nixpkgs>/NIX_PATH, as of 9 Sep 2026; see that file for why, and for the
# finding (F7) it closes.
#
# metrics.nix reads homelab.tenants plus one host fact,
# homelab.host.networks.*.address (since 12 Sep 2026, for the
# metricsEndpoint.address assertion), and writes two leaves:
# services.prometheus.scrapeConfigs (stubbed by tests/stub-prometheus.nix)
# and `assertions` (declared inline below). The host side is NOT
# tests/stub-host.nix: that stub is ports.nix's, its `lan` submodule has no
# `address` leaf, and it is a closed submodule type so a fixture cannot add
# one. Rather than grow a second stub, this harness imports the real L0
# option module, modules/platform/host-options.nix -- options only, no
# config, the same file flake.nix composes -- and sets the facts in
# fixtures/metrics-host.nix. Folding stub-host.nix onto host-options.nix the
# same way is a reasonable follow-up for eval.nix; it is not this change.
#
# The two expected job_name/target pairs below are transcribed verbatim from
# ac-box:/var/lib/ac-host/src/modules/monitoring.nix's "node" and
# "docker-names" jobs. This task's ask is that renaming a job must be
# possible via `metrics.job`, and that the reproduced job_name/target be
# byte-identical to what's hand-written there today; metric_relabel_configs
# is curation outside this module's contract (schema.nix's metricsEndpoint
# has no such field) and is deliberately not reproduced. Since the address
# field landed, those two pins are ALSO the proof that the default is
# loopback: neither fixture entry mentions an address, and both must still
# come out 127.0.0.1:<port>.
#
# homelab.enforce.scrape (modules/tenant/enforce.nix) gates the scrapeConfigs
# effect only. The address assertion is unconditional, like every assertion
# in the contract, so the cases are: the on/off split for the effect, plus
# the assertion checked both with the switch on (addressNotOnHost) and off
# (allFalseAddressStillAsserted).
#
# Usage:
#   nix --extra-experimental-features "nix-command flakes" eval \
#     -f modules/tenant/tests/eval-metrics.nix allTrue.checked
#   nix --extra-experimental-features "nix-command flakes" eval --json \
#     -f modules/tenant/tests/eval-metrics.nix allTrue.scrapeConfigs
#   nix --extra-experimental-features "nix-command flakes" eval \
#     -f modules/tenant/tests/eval-metrics.nix allFalse.checked
#   nix --extra-experimental-features "nix-command flakes" eval \
#     -f modules/tenant/tests/eval-metrics.nix addressNotOnHost.messages
# No <nixpkgs> fallback, deliberately: an unpinned run must fail loudly.
{ lib ? (import ./pinned-nixpkgs.nix).lib }:

let
  schema = ../schema.nix;
  enforce = ../enforce.nix;
  metrics = ../metrics.nix;
  hostOptions = ../../platform/host-options.nix;
  stubPrometheus = ./stub-prometheus.nix;
  tenants = ./fixtures/metrics-quiet-tenants.nix;
  hostFacts = ./fixtures/metrics-host.nix;

  # Real NixOS declares this in nixos/modules/misc/assertions.nix; metrics.nix
  # only writes to it. stub-host.nix declares the same leaf for eval.nix but
  # cannot be imported here (see header), so it is declared once more, as
  # narrowly.
  stubAssertions =
    { lib, ... }:
    {
      options.assertions = lib.mkOption {
        type = lib.types.listOf lib.types.unspecified;
        default = [ ];
      };
    };

  mkCase =
    { extraModules ? [ ], checks ? (_: _: [ ]) }:
    let
      evaluated = lib.evalModules {
        modules = [
          stubPrometheus
          stubAssertions
          hostOptions
          schema
          enforce
          metrics
          tenants
          hostFacts
        ]
        ++ extraModules;
      };

      cfg = evaluated.config;
      scrapeConfigs = cfg.services.prometheus.scrapeConfigs;

      # Module assertions first, then this harness's own checks -- same
      # ordering as eval.nix, so `checked` behaves the way a real NixOS build
      # does and throws on a failed assertion.
      failedAssertions = lib.filter (a: !a.assertion) cfg.assertions;
      failedChecks = lib.filter (c: !c.assertion) (checks cfg scrapeConfigs);
      failedMessages = map (a: a.message) failedAssertions ++ map (c: c.message) failedChecks;
    in
    {
      inherit scrapeConfigs;
      ok = failedMessages == [ ];
      messages = failedMessages;
      checked =
        if failedMessages == [ ] then
          "OK: all checks passed"
        else
          throw (lib.concatStringsSep "\n" failedMessages);
    };
in
{
  # enforce.scrape = true: behaviour unchanged from what this harness always
  # asserted -- same checks, just moved under this case name -- plus the
  # address checks added with the field.
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
          message = ''job "node" (observability's override) must reproduce monitoring.nix's target 127.0.0.1:9100 exactly -- and, since address exists, prove its default is loopback'';
        }
        {
          assertion =
            (byJob."docker-names" or null) != null
            && byJob."docker-names".static_configs == [ { targets = [ "127.0.0.1:9132" ]; } ];
          message = ''job "docker-names" (assetto's override) must reproduce monitoring.nix's target 127.0.0.1:9132 exactly -- and, since address exists, prove its default is loopback'';
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
          assertion =
            (byJob."agent-hub".static_configs or null) == [ { targets = [ "192.168.1.50:9200" ]; } ];
          message = "a non-loopback metrics.address that the host declares (fixtures/metrics-host.nix lan) must become the scrape target verbatim: 192.168.1.50:9200";
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

  # --- metricsEndpoint.address coverage (12 Sep 2026, delta row 12) ---

  # The bind wildcard. It is the most likely wrong answer -- it is what a
  # service that "listens on all interfaces" says about itself -- and it is
  # not somewhere Prometheus can connect to. Must fail the address
  # assertion; enforce.scrape is on so that the failure is demonstrably the
  # assertion, not a missing scrape job.
  addressNotOnHost = mkCase {
    extraModules = [
      {
        homelab.enforce.scrape = true;
        homelab.tenants.agent-hub.metrics.address = "0.0.0.0";
      }
    ];
  };

  # A literal for the address mgmt WILL have once the dual-NIC runbook brings
  # eno1 up. mgmt.address is null today (fixtures/metrics-host.nix, matching
  # hosts/ac-box/host.nix), so this is an address the host does not have
  # yet, and must fail -- the metrics analogue of eval.nix's mgmtNoAddress.
  addressOnDownInterface = mkCase {
    extraModules = [
      {
        homelab.enforce.scrape = true;
        homelab.tenants.agent-hub.metrics.address = "10.0.0.2";
      }
    ];
  };

  # Same wildcard, but with enforce.scrape at its default (false): the
  # assertion is evaluation-time only and ungated, so it must STILL fail,
  # even though the scrape effect contributes nothing. Mirrors eval.nix's
  # allFalseCollisionStillFails.
  allFalseAddressStillAsserted = mkCase {
    extraModules = [ { homelab.tenants.agent-hub.metrics.address = "0.0.0.0"; } ];
    checks = cfg: scrapeConfigs: [
      {
        assertion = scrapeConfigs == [ ];
        message = "enforce.scrape = false: scrapeConfigs must stay [] even on a fixture with a rejected address";
      }
    ];
  };

  # A disabled tenant with a bad address: excluded from scrapeConfigs, but
  # its declaration is still checked -- metrics.nix asserts over every
  # tenant that declares an endpoint, enabled or not, for the same reason
  # ports.nix checks a disabled tenant's port claims. Must fail.
  disabledTenantStillAsserted = mkCase {
    extraModules = [
      {
        homelab.enforce.scrape = true;
        homelab.tenants.ci.metrics.address = "0.0.0.0";
      }
    ];
  };

  # Case name -> whether `<case>.checked` must evaluate cleanly. The on/off
  # cases are positive; the four address cases exist to prove a bad address
  # is rejected. Read by modules/ci/scripts/run-eval-tests.sh.
  expected = {
    allTrue = true;
    allFalse = true;
    addressNotOnHost = false;
    addressOnDownInterface = false;
    allFalseAddressStillAsserted = false;
    disabledTenantStillAsserted = false;
  };
}
