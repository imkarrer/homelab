# Harness for modules/observability/peers.nix: the peer half of the scrape
# config and, above all, what it REFUSES. peers.nix is a pure function of
# facts, so no host is evaluated here -- fixtures in, scrape configs and
# assertions out -- which is what lets the negative cases throw from the
# assertion under test and nothing else (check.nix's warning about merge
# errors masquerading as the refusal does not apply: there is no merge).
#
# Discovered by modules/tenant/tests/check.nix as `eval-observability-peers`.
#
# Usage (manual route; the flake route is `nix flake check`):
#   nix eval --impure --raw -f modules/observability/tests/eval-peers.nix z840.checked
#   nix eval --impure --json -f modules/observability/tests/eval-peers.nix z840.scrapeConfigs
#   nix eval --impure --json -f modules/observability/tests/eval-peers.nix peerIsThisHost.messages
{
  lib ? (import ../../tenant/tests/pinned-nixpkgs.nix).lib,
}:
let
  peersFn = import ../peers.nix;

  # This host, as default.nix would hand it over: two local jobs, one with a
  # keep regex (node) and one without (cadvisor); the global interval; the
  # addresses homelab.host.networks gives it.
  scrapeInterval = "30s";
  nodeKeep = "up|node_cpu_seconds_total|node_load5";
  localScrapeConfigs = [
    {
      job_name = "node";
      static_configs = [
        {
          targets = [ "127.0.0.1:9100" ];
          labels.host = "here";
        }
      ];
      metric_relabel_configs = [
        {
          source_labels = [ "__name__" ];
          regex = nodeKeep;
          action = "keep";
        }
      ];
    }
    {
      job_name = "cadvisor";
      static_configs = [
        {
          targets = [ "127.0.0.1:9102" ];
          labels.host = "here";
        }
      ];
    }
  ];
  hostAddresses = [ "192.168.1.50" ];

  # Peer endpoints, spelled with every field peerMetrics (host-options.nix)
  # would have filled in: the function sees evaluated options, not sugar.
  nodeEndpoint = keep: {
    job = "node";
    port = 9100;
    interval = scrapeInterval;
    path = "/metrics";
    inherit keep;
  };
  ownEndpoint =
    {
      job,
      interval ? "30s",
    }:
    {
      inherit job interval;
      port = 8100;
      path = "/metrics";
      keep = null;
    };

  mkCase =
    {
      peers,
      checks ? (_: [ ]),
    }:
    let
      out = peersFn {
        inherit
          lib
          peers
          localScrapeConfigs
          hostAddresses
          scrapeInterval
          ;
      };
      failedAssertions = lib.filter (a: !a.assertion) out.assertions;
      failedChecks = lib.filter (c: !c.assertion) (checks out);
      messages = map (a: a.message) failedAssertions ++ map (c: c.message) failedChecks;
    in
    {
      inherit messages;
      inherit (out) scrapeConfigs nodePeers;
      checked =
        if messages == [ ] then
          "ok: ${toString (lib.length out.scrapeConfigs)} scrape configs, ${toString (lib.length (lib.attrNames out.nodePeers))} node peer(s)"
        else
          throw (lib.concatStringsSep "\n" messages);
    };

  byJob = cs: job: lib.findFirst (c: c.job_name == job) null cs;
  # nodePeers hands the peer entry back as given; the check compares it whole.
  peersOf = out: name: out.nodePeers.${name};
in
{
  # No peer: the local list, byte for byte, and no node peers.
  noPeers = mkCase {
    peers = { };
    checks = out: [
      {
        assertion = out.scrapeConfigs == localScrapeConfigs;
        message = "with no peers the scrape config must be the local list unchanged";
      }
      {
        assertion = out.nodePeers == { };
        message = "with no peers there are no node peers";
      }
    ];
  };

  # The real shape: one peer whose node exporter joins the local node job as
  # a second instance and whose model server is a job of its own.
  z840 = mkCase {
    peers.z840 = {
      address = "192.168.1.51";
      loadHigh = 56;
      metrics = [
        (nodeEndpoint nodeKeep)
        (ownEndpoint { job = "agent-hub"; })
      ];
    };
    checks =
      out:
      let
        node = byJob out.scrapeConfigs "node";
        own = byJob out.scrapeConfigs "agent-hub";
      in
      [
        {
          assertion =
            node != null
            && map (s: s.targets) node.static_configs == [
              [ "127.0.0.1:9100" ]
              [ "192.168.1.51:9100" ]
            ]
            && map (s: s.labels.host) node.static_configs == [
              "here"
              "z840"
            ];
          message = "the peer's node exporter must join the local node job as a second target with host=z840";
        }
        {
          assertion = node != null && (lib.head node.metric_relabel_configs).regex == nodeKeep;
          message = "joining the node job must not touch its curation";
        }
        {
          assertion =
            own != null
            && own.static_configs == [
              {
                targets = [ "192.168.1.51:8100" ];
                labels.host = "z840";
              }
            ]
            && own.scrape_interval == "30s"
            && !(own ? metric_relabel_configs)
            && !(own ? metrics_path);
          message = "agent-hub must be a job of its own with the peer's one target and no curation";
        }
        {
          assertion = byJob out.scrapeConfigs "cadvisor" == byJob localScrapeConfigs "cadvisor";
          message = "a local job no peer declares must be unchanged";
        }
        {
          assertion = out.nodePeers == { z840 = peersOf out "z840"; } && out.nodePeers.z840.loadHigh == 56;
          message = "the peer that declares node must be the one node peer, with its loadHigh";
        }
      ];
  };

  # A peer at one of this host's own addresses is not a peer.
  peerIsThisHost = mkCase {
    peers.me = {
      address = "192.168.1.50";
      loadHigh = 6;
      metrics = [ (nodeEndpoint nodeKeep) ];
    };
  };

  # Nor is loopback.
  peerIsLoopback = mkCase {
    peers.me = {
      address = "127.0.0.1";
      loadHigh = 6;
      metrics = [ (nodeEndpoint nodeKeep) ];
    };
  };

  # A peer endpoint that joins a local job must agree with that job's
  # curation; a different keep regex is refused, not silently dropped.
  mergedJobCurationDiffers = mkCase {
    peers.z840 = {
      address = "192.168.1.51";
      loadHigh = 56;
      metrics = [ (nodeEndpoint "up|node_load5") ];
    };
  };

  # Two peers declaring one peer-only job with different intervals: one job
  # has one curation.
  twoPeersDisagree = mkCase {
    peers = {
      a = {
        address = "192.168.1.61";
        metrics = [ (ownEndpoint { job = "x"; }) ];
      };
      b = {
        address = "192.168.1.62";
        metrics = [
          (ownEndpoint {
            job = "x";
            interval = "2m";
          })
        ];
      };
    };
  };

  # A node peer without a load line has no HostLoadHigh; refused.
  nodePeerWithoutLoadHigh = mkCase {
    peers.z840 = {
      address = "192.168.1.51";
      loadHigh = null;
      metrics = [ (nodeEndpoint nodeKeep) ];
    };
  };

  expected = {
    noPeers = true;
    z840 = true;
    peerIsThisHost = false;
    peerIsLoopback = false;
    mergedJobCurationDiffers = false;
    twoPeersDisagree = false;
    nodePeerWithoutLoadHigh = false;
  };
}
