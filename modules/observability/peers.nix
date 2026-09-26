# The peer half of this module's scrape config, as a pure function of facts
# the module already holds -- no `config`, no `pkgs` -- so that what it
# REFUSES can be proven in tests/eval-peers.nix against fixtures, without
# evaluating a whole host (check.nix's harness contract). default.nix calls
# it once and splices the two outputs in; nothing else imports it.
#
# What this host scrapes on OTHER homelab hosts is homelab.host.peers, an L0
# fact (modules/platform/host-options.nix). Each peer's endpoints are
# flattened to one entry per endpoint with the peer's name and address on
# it. Empty on a host that names no peer, in which case `scrapeConfigs` is
# the local list unchanged and `assertions` is [].
{
  lib,
  # homelab.host.peers: name -> { address; metrics = [ { job; port; interval; path; keep; } ]; loadHigh; }
  peers,
  # this host's own scrape configs, in Prometheus's shape (job_name, static_configs, ...)
  localScrapeConfigs,
  # every address homelab.host.networks.* gives this host; a peer must not be one
  hostAddresses,
  # the global scrape interval: what a local job without its own falls back to
  scrapeInterval,
}:
let
  peerEntries = lib.concatLists (
    lib.mapAttrsToList (
      peer: p:
      map (
        m:
        m
        // {
          inherit peer;
          inherit (p) address;
        }
      ) p.metrics
    ) peers
  );
  peerTarget = e: {
    targets = [ "${e.address}:${toString e.port}" ];
    labels.host = e.peer;
  };

  # The rule, in two halves. A peer endpoint whose job is one this host
  # scrapes locally (node, today) becomes a second target of THAT job: same
  # job_name, same interval, same curation, one more instance -- which is
  # what lets a dashboard keyed on job="node" show both machines without
  # knowing there are two. Any other peer job is a scrape config of its own,
  # from the entries' interval/path/keep (agent-hub, today), with every
  # peer that declares that job as a target of it.
  localJobNames = map (c: c.job_name) localScrapeConfigs;
  localByJob = lib.listToAttrs (map (c: lib.nameValuePair c.job_name c) localScrapeConfigs);
  isLocalJob = e: lib.elem e.job localJobNames;
  mergedEntries = lib.filter isLocalJob peerEntries;
  peerOnlyByJob = lib.groupBy (e: e.job) (lib.filter (e: !isLocalJob e) peerEntries);

  # Curation is per job in Prometheus, not per target, so a merged entry's
  # interval/path/keep cannot be honoured separately from the local job's.
  # They are asserted equal instead (below), so hosts/<name>/host.nix tells
  # the whole truth about what is scraped from the peer and cannot drift
  # from what actually is. These read the local job's values back.
  intervalOf = c: c.scrape_interval or scrapeInterval;
  pathOf = c: c.metrics_path or "/metrics";
  keepOf =
    c:
    let
      ks = lib.filter (
        r: (r.action or "") == "keep" && (r.source_labels or [ ]) == [ "__name__" ]
      ) (c.metric_relabel_configs or [ ]);
    in
    if ks == [ ] then null else (lib.head ks).regex;

  scrapeConfigsWithPeers = map (
    c:
    c
    // {
      static_configs =
        c.static_configs ++ map peerTarget (lib.filter (e: e.job == c.job_name) mergedEntries);
    }
  ) localScrapeConfigs;

  peerScrapeConfigs = lib.mapAttrsToList (
    job: es:
    let
      e = lib.head es;
    in
    {
      job_name = job;
      scrape_interval = e.interval;
      static_configs = map peerTarget es;
    }
    // lib.optionalAttrs (e.path != "/metrics") { metrics_path = e.path; }
    // lib.optionalAttrs (e.keep != null) {
      metric_relabel_configs = [
        {
          source_labels = [ "__name__" ];
          regex = e.keep;
          action = "keep";
        }
      ];
    }
  ) peerOnlyByJob;

  # Peers whose node exporter this host scrapes: each needs its own
  # HostLoadHigh line (default.nix renders one rule per machine), because a
  # collector cannot read a peer's capacity and "half the threads" is not
  # every machine's line -- see loadHigh in host-options.nix.
  nodePeers = lib.filterAttrs (_: p: lib.any (m: m.job == "node") p.metrics) peers;

  show = k: if k == null then "null" else k;

  assertions =
    # A peer is another machine: the inverse of metrics.nix's rule, which
    # says a tenant endpoint must be HERE.
    lib.mapAttrsToList (name: p: {
      assertion = p.address != "127.0.0.1" && !(lib.elem p.address hostAddresses);
      message = "homelab.host.peers.${name}.address = \"${p.address}\" is this host (loopback or one of homelab.host.networks.*.address). A peer is another machine; this host's own exporters are the local jobs in modules/observability/default.nix.";
    }) peers
    ++ map (
      e:
      let
        c = localByJob.${e.job};
      in
      {
        assertion = e.interval == intervalOf c && e.path == pathOf c && e.keep == keepOf c;
        message = "homelab.host.peers.${e.peer}.metrics: job \"${e.job}\" is one this host scrapes locally, so the peer's target joins that job and takes its interval (${intervalOf c}), path (${pathOf c}) and keep regex (${show (keepOf c)}); the entry says interval ${e.interval}, path ${e.path}, keep ${show e.keep}. Curation is per job, not per target: make them equal, or give the peer's endpoint a job of its own.";
      }
    ) mergedEntries
    ++ lib.mapAttrsToList (
      job: es:
      let
        e = lib.head es;
      in
      {
        assertion = lib.all (x: x.interval == e.interval && x.path == e.path && x.keep == e.keep) es;
        message = "homelab.host.peers: job \"${job}\" is declared by more than one peer (${lib.concatMapStringsSep ", " (x: x.peer) es}) with differing interval/path/keep; one job has one curation.";
      }
    ) peerOnlyByJob
    ++ lib.mapAttrsToList (name: p: {
      assertion = p.loadHigh != null;
      message = "homelab.host.peers.${name} declares the node job and no loadHigh: HostLoadHigh fires per machine above a line only that machine's owner can set, and this host cannot read the peer's capacity. Set loadHigh -- hosts/arcade-box/host.nix imports the peer's host.nix for it.";
    }) nodePeers;
in
{
  scrapeConfigs = scrapeConfigsWithPeers ++ peerScrapeConfigs;
  inherit assertions nodePeers;
}
