# L2 shared service: Prometheus, Alertmanager, Grafana and the box's exporters.
#
# Lifted here from ac-host/modules/monitoring.nix in phase 8. That was the last
# layering violation left standing: a service every tenant depends on, owned by
# the repo of one tenant -- so disabling the racing stack took the metrics with
# it, and a dashboard change went through the racing tenant's release cycle.
#
# It stayed there through phases 1-7 for a concrete reason rather than inertia:
# the module reads two exporter scripts by relative path, so it could not be
# consumed as a flake output without them, and phase 1 needed a byte-identical
# closure while moving files necessarily changes store paths. Both scripts have
# come with it now, along with their tests and the Grafana dashboard, and the
# references changed from ../scripts/ to ./scripts/. Both are stdlib-only, so
# nothing else had to follow.
#
# Deliberately not bundled with moving the file: this used to declare its own
# Grafana firewall rule alongside homelab.tenants' identical one (beads
# homelab-bqo.30, fixed below) -- the observability tenant in
# hosts/ac-box/tenants.nix already knows every port this module opens or
# binds, so the contract is the single source of truth for what gets a
# firewall rule; this module's job is only to actually run the services at
# the addresses/ports the contract already knows about.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Unchanged, and deliberately NOT derived from homelab.host.paths: these are
  # the paths the consumers below read (the Grafana admin password and secret
  # key, the unifi-poller password, the Discord webhook). Hand-placed from
  # 3 Sep 2026 until 14 Sep; since then modules/platform/secrets.nix installs
  # each as a symlink at the same path, root:monitoring 0640, from
  # secrets/ac-box.yaml. The paths are still named here because the consumers
  # are here -- $__file{}, UNIFI_PASS_FILE, webhook_url_file and the two
  # ConditionPathExists all follow a symlink (os.ReadFile and access(2) both
  # do), and every reader runs on the host, where /run/secrets is visible.
  # Renaming the directory would be a data migration for no benefit -- the
  # same reasoning ADR 0003 applies to /var/lib/ac-host.
  # The dashboard binds the LAN address rather than 0.0.0.0, and now takes it
  # from the one place this repo keeps machine literals.
  grafanaAddr = config.homelab.host.networks.lan.address;
  grafanaPort = 3000;

  # The host's name, for the target labels below. Until 26 Sep 2026
  # (homelab-ygc.3, the second host) the alert rules carried "ac-box" as the
  # group name, as four alert-name prefixes and in three summaries, and
  # `node_load5 > 28` with "(56 threads)" beside it; from then until
  # homelab-ygc.10 the same day they carried THIS host's name and half its
  # thread count from homelab.host instead -- right while every node series
  # came from the host running Prometheus, wrong the moment a peer's did.
  # The rules now name no host at all (see them below); the name is a label.
  host = config.homelab.host;

  # Every target this Prometheus scrapes carries host=<machine>. `instance`
  # stopped saying which machine when a second host appeared: "127.0.0.1:9100"
  # is whichever box Prometheus runs on, and after ADR 0010's cutover
  # arcade-box's node series CONTINUED ac-box's under exactly that label,
  # because the TSDB came over by rsync. A label set is a series identity,
  # so adding the label ends those series and starts new ones once, at the
  # switch that carries it; nothing keyed on job -- the dashboard's panels,
  # the alert expressions -- notices, and a legend may now say {{host}}.
  localTarget = port: {
    targets = [ "127.0.0.1:${toString port}" ];
    labels.host = host.name;
  };

  # One global interval, named once because the peer merge below has to
  # know what a local job without its own scrape_interval actually runs at.
  scrapeInterval = "30s";

  # What this host scrapes on its own loopback. A `let` rather than the
  # option's literal so the peer machinery below can read the job names and
  # curation off the same list it extends -- a second spelling of the names
  # would be a duplicate job_name, which Prometheus refuses at startup, the
  # first time somebody added a local job and forgot the other list.
  localScrapeConfigs = [
    {
      job_name = "node";
      static_configs = [ (localTarget 9100) ];
      metric_relabel_configs = [
        {
          source_labels = [ "__name__" ];
          regex = "up|node_cpu_seconds_total|node_memory_MemTotal_bytes|node_memory_MemAvailable_bytes|node_filesystem_avail_bytes|node_filesystem_size_bytes|node_load1|node_load5|node_load15|node_systemd_unit_state";
          action = "keep";
        }
      ];
    }
    {
      job_name = "cadvisor";
      static_configs = [ (localTarget 9102) ];
      metric_relabel_configs = [
        {
          source_labels = [ "__name__" ];
          regex = "up|container_cpu_usage_seconds_total|container_memory_working_set_bytes";
          action = "keep";
        }
        {
          source_labels = [ "cpu" ];
          regex = "[0-9]+";
          action = "drop";
        }
        {
          regex = "container_label_.*";
          action = "labeldrop";
        }
      ];
    }
    # The two UniFi jobs poll the Dream Router's Network application, a Java
    # process sharing 2 GB with everything else on the router. In Prometheus
    # mode unpoller fetches from the controller ON EVERY SCRAPE, so this
    # interval IS the load we put on it: at 30s it was ~2,900 fetches/day of
    # ~270 KB each (~2.5s of controller time per fetch, ~8% of wall-clock),
    # and controller response time crept up ~0.15s/day alongside its memory
    # until the app wedged on 10 Sep 2026 (see UnifiGatewayMemTrend below).
    #
    # 2m, not 5m: Prometheus's staleness lookback is 5m, so a 5m interval
    # leaves instant selectors (`up == 0`, the dashboard gauges) empty
    # between samples and silently resets alert `for:` timers. 2m is 4x less
    # load and still well inside the lookback. The dashboard's rate() windows
    # over these series are [10m] for the same reason.
    #
    # scrape_timeout is raised from the 10s default because a controller that
    # takes 12s to answer is degraded, not down, and "up" should say so;
    # UnifiControllerSlow is the alert that reads the duration.
    {
      job_name = "unpoller";
      scrape_interval = "2m";
      scrape_timeout = "45s";
      static_configs = [ (localTarget 9130) ];
      metric_relabel_configs = [
        {
          source_labels = [ "__name__" ];
          # uptime is kept so a router reboot is a visible counter reset,
          # not something inferred from a gap in the graph.
          regex = "up|unpoller_device_cpu_utilization_ratio|unpoller_device_memory_utilization_ratio|unpoller_device_uptime_seconds|unpoller_device_wan_.*";
          action = "keep";
        }
      ];
    }
    # udr-fw-exporter polls the controller on its own timer (UDR_FW_POLL_SECONDS
    # in its unit, below) and serves the last result from memory, so this
    # scrape is a cache read and its interval does not touch the router.
    {
      job_name = "udr-fw";
      scrape_interval = "2m";
      static_configs = [ (localTarget 9131) ];
    }
    {
      job_name = "docker-names";
      scrape_interval = "30s";
      static_configs = [ (localTarget 9132) ];
    }
  ];

  # ---- peers -------------------------------------------------------------
  # What this host scrapes on OTHER homelab hosts: homelab.host.peers, an L0
  # fact (modules/platform/host-options.nix), flattened to one entry per
  # endpoint with the peer's name and address on it. Empty on a host that
  # names no peer, in which case the scrape config is the local list alone
  # and peerAssertions is []. The merge and its refusals are ./peers.nix, a
  # pure function, so tests/eval-peers.nix can prove the refusals.
  peers = config.homelab.host.peers;
  hostAddresses = lib.filter (a: a != null) (lib.mapAttrsToList (_: n: n.address) host.networks);
  peerSet = import ./peers.nix {
    inherit
      lib
      peers
      localScrapeConfigs
      hostAddresses
      scrapeInterval
      ;
  };
  peerAssertions = peerSet.assertions;

  # One HostLoadHigh per machine, each with its own line, selected by the
  # host= label every target carries. This host: half its threads, the
  # "sustained, not peak" line the rule has always had (6 on the Tiny). A
  # peer: its loadHigh from homelab.host.peers, because the same formula is
  # wrong for the Z840 -- its one tenant runs 28 generation threads by design
  # (homelab-ygc.13), so node_load5 sits at 28-30 through every long model
  # session, exactly the old line; the review of homelab-ygc.10 caught it.
  # A literal per machine here would be a second spelling of a host fact.
  # Rendered at the rules string's own indentation: `- alert:` at six.
  loadLines = [
    {
      name = host.name;
      line = host.capacity.cpuThreads / 2;
    }
  ]
  ++ lib.mapAttrsToList (name: p: {
    inherit name;
    line = p.loadHigh;
  }) peerSet.nodePeers;
  # Explicit indentation per line, not an indented '' string: Nix strips a
  # ''-string's own common indentation, which put the first rendering of
  # this at column 0 of the rules file.
  loadRules = lib.concatMapStrings (
    { name, line }:
    let
      l = toString line;
    in
    lib.concatMapStrings (s: "      ${s}\n") [
      "- alert: HostLoadHigh"
      "  expr: node_load5{host=\"${name}\"} > ${l}"
      "  for: 10m"
      "  labels:"
      "    severity: warning"
      "  annotations:"
      "    summary: \"{{ $labels.host }} ({{ $labels.instance }}) 5m load is {{ $value | printf \\\"%.1f\\\" }}, over its line of ${l}\""
    ]
  ) loadLines;

  # The UniFi controller the two exporters below poll -- read from the host for
  # the same reason grafanaAddr is, three lines up. Until 9 Sep 2026 this module
  # did both at once: it derived the Grafana bind correctly and then hardcoded
  # "https://192.168.1.1" twice, in unpoller's controller url and in
  # udr-fw-exporter's UNIFI_HOST. That was finding F6 in docs/current-state.md,
  # and the last machine literal left in code anywhere under modules/.
  #
  # An ASSERTION, not a silent skip, and the distinction was thought about.
  # A gate ("null means this host has no UniFi gear, so build no poller") is
  # the nicer shape and is what a second host will eventually want -- but this
  # module enables unpoller and udr-fw-exporter UNCONDITIONALLY today, and
  # ships Prometheus alert rules that page when `up{job="unpoller"} == 0`. It
  # already assumes the gear exists. Making that conditional is a real change
  # to what the module builds; F6 was only ever about where the address comes
  # from. Widening the one into the other is how a provable no-op stops being
  # provable.
  #
  # So: assert, following the precedent in ports.nix's mgmt check, and leave
  # the gate to whoever adds the second host. Without the assertion the failure
  # is `"https://${null}"`, which throws deep inside string interpolation with
  # no mention of the option that is actually unset.
  #
  # The scheme stays here rather than in the host fact: "https" plus
  # verify_ssl = false is how one talks to a UniFi controller (self-signed cert
  # on a private LAN), not a fact about this network. See the option's
  # description in modules/platform/host-options.nix.
  unifiAddr = config.homelab.host.unifi.address;
  unifiPolled = unifiAddr != null;
  unifiUrl = "https://${unifiAddr}";

  secretsDir = "/var/lib/monitoring/secrets";
  grafanaAdminFile = "${secretsDir}/grafana-admin";
  grafanaSecretFile = "${secretsDir}/grafana-secret-key";
  unpollerPassFile = "${secretsDir}/unpoller.pass";
  discordWebhookFile = "${secretsDir}/discord-webhook";
  dashboardsDir = ./grafana-dashboards;
in
{
  users.groups.monitoring = { };

  systemd.tmpfiles.rules = [
    "d /var/lib/monitoring 0755 root root -"
    "d ${secretsDir} 0750 root monitoring -"
  ];

  # The directory only. Until 14 Sep 2026 this script also generated the two
  # Grafana values when absent and chmod/chowned all four files; both are
  # gone. The values come from sops now, so a missing one is a build-time
  # error (the sops-nix manifest check) rather than a silently minted
  # password nobody wrote down -- and the four paths are symlinks into
  # /run/secrets, whose mode and owner sops-nix sets from its declaration; a
  # chmod through the link would touch the target, and one at boot, before
  # sops-nix has run, would find the link dangling.
  #
  # Runs before sops-nix's setupSecrets on the first switch and on every
  # boot: activation scripts are ordered by their deps and then by name, and
  # "monitoring-secrets" sorts before "setupSecrets". sops-nix would mkdir the
  # parent itself if it were missing (MkdirAll at the umask mode), so this is
  # what makes the directory 0750 root:monitoring, not a correctness need.
  system.activationScripts.monitoring-secrets = ''
    mkdir -p ${secretsDir}
    chmod 0750 ${secretsDir}
    chown root:monitoring ${secretsDir} || true
  '';

  users.users.unifi-poller.extraGroups = [ "monitoring" ];
  users.users.grafana.extraGroups = [ "monitoring" ];

  # No firewall rule declared here (beads homelab-bqo.30): the observability
  # tenant in hosts/ac-box/tenants.nix already claims grafana as
  # number = 3000, scope = "lan", so modules/tenant/ports.nix derives the
  # identical enp8s0/3000 opening whenever homelab.enforce.firewall is on --
  # this module hardcoding the same rule a second time was pure redundancy,
  # not a second real source of truth. Every other exporter here
  # (prometheus/alertmanager/node/cadvisor/unpoller/udr-fw/docker-names)
  # binds loopback-only and is declared scope = "local" in tenants.nix, so
  # the contract already contributes nothing for them either -- consistent
  # with what this module actually does.
  services.prometheus.exporters.node = {
    enable = true;
    listenAddress = "127.0.0.1";
    port = 9100;
    enabledCollectors = [
      "systemd"
      "filesystem"
    ];
  };

  services.cadvisor = {
    enable = true;
    listenAddress = "127.0.0.1";
    port = 9102;
    extraOptions = [
      "--docker_only=true"
      "--docker=unix:///run/docker.sock"
      "--containerd=/run/docker/containerd/containerd.sock"
      "--containerd-namespace=moby"
    ];
  };

  # See unifiUrl's comment above for why this is an assertion rather than a
  # gate that builds nothing; peerAssertions is defined with the peers.
  assertions = [
    {
      assertion = unifiPolled;
      message = ''
        modules/observability enables unpoller and udr-fw-exporter, and ships
        alert rules that page on up{job="unpoller"} == 0, but
        homelab.host.unifi.address is null. Set it in hosts/<name>/host.nix,
        or make this module's UniFi half conditional -- it is not today.
      '';
    }
  ]
  ++ peerAssertions;

  systemd.services.cadvisor.serviceConfig.SupplementaryGroups = [ "docker" ];

  services.unpoller = {
    enable = true;
    influxdb.disable = true;
    prometheus.http_listen = "127.0.0.1:9130";
    unifi = {
      controllers = [
        {
          url = unifiUrl;
          user = "unpoller";
          pass = unpollerPassFile;
          verify_ssl = false;
          sites = "default";
          save_dpi = false;
          save_ids = false;
          save_events = false;
          save_alarms = false;
          save_anomalies = false;
        }
      ];
    };
  };

  systemd.services.unifi-poller.unitConfig.ConditionPathExists = unpollerPassFile;

  systemd.services.docker-name-exporter = {
    description = "Map cAdvisor container ids to Docker names";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "docker.service" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.python3}/bin/python3 ${./scripts/docker_name_exporter.py}";
      Restart = "always";
      RestartSec = "10s";
      SupplementaryGroups = [ "docker" ];
      Environment = [
        "DOCKER_SOCK=/run/docker.sock"
        "DOCKER_API_VERSION=1.44"
        "DOCKER_NAME_BIND=127.0.0.1:9132"
      ];
    };
  };

  systemd.services.udr-fw-exporter = {
    description = "Dream Router firewall hit exporter";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    unitConfig.ConditionPathExists = unpollerPassFile;
    serviceConfig = {
      ExecStart = "${pkgs.python3}/bin/python3 ${./scripts/udr_fw_exporter.py}";
      Restart = "always";
      RestartSec = "10s";
      User = "unifi-poller";
      Group = "monitoring";
      Environment = [
        "UNIFI_HOST=${unifiUrl}"
        "UNIFI_USER=unpoller"
        "UNIFI_PASS_FILE=${unpollerPassFile}"
        "UDR_FW_BIND=127.0.0.1:9131"
        # How often the exporter itself asks the router, independent of how
        # often Prometheus scrapes it. Firewall hit counters do not need finer
        # than this, and every call is work for the router's 2 GB Network app.
        "UDR_FW_POLL_SECONDS=300"
      ];
    };
  };

  services.prometheus = {
    enable = true;
    listenAddress = "127.0.0.1";
    port = 9090;
    # Size wins if it fills first. 2GB is a hard ceiling; WAL can sit a bit above it.
    retentionTime = "14d";
    extraFlags = [ "--storage.tsdb.retention.size=2GB" ];
    globalConfig.scrape_interval = scrapeInterval;
    alertmanagers = [
      {
        static_configs = [
          { targets = [ "127.0.0.1:9093" ]; }
        ];
      }
    ];
    scrapeConfigs = peerSet.scrapeConfigs;
    rules = [
      ''
        groups:
          - name: homelab
            rules:
              # The host rules read node series from every machine this
              # Prometheus scrapes -- the box it runs on and each peer -- and
              # fire per instance. Renamed with homelab-ygc.10 from
              # <HostTitle>DiskHigh / LoadHigh / MemLow / ExporterDown
              # (ArcadeBoxDiskHigh ... since the cutover, AcBoxDiskHigh ...
              # before it): a prefix that names one host is wrong on a rule
              # that watches two. Alertmanager groups by alertname, so the
              # machine is in the summary and the labels instead; the group
              # was named after the host for the same reason and is not now.
              - alert: HostDiskHigh
                expr: 100 * (1 - node_filesystem_avail_bytes{mountpoint="/",fstype!="tmpfs"} / node_filesystem_size_bytes{mountpoint="/",fstype!="tmpfs"}) > 80
                for: 10m
                labels:
                  severity: warning
                annotations:
                  summary: "{{ $labels.host }} ({{ $labels.instance }}) root disk is {{ $value | printf \"%.0f\" }}% full"

              # One rule per machine (loadRules above): this host at half its
              # threads, each peer at the loadHigh its peers entry carries.
        ${loadRules}
              - alert: HostMemLow
                expr: node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes < 0.10
                for: 10m
                labels:
                  severity: warning
                annotations:
                  summary: "{{ $labels.host }} ({{ $labels.instance }}) has under 10% RAM available"

              # Per instance, so a peer's exporter going away is an alert and
              # not a quiet gap in its graphs. cadvisor is its own rule
              # because it runs on this host alone; the two were one rule
              # (up{job=~"node|cadvisor"}) until the split, with no other change.
              - alert: NodeExporterDown
                expr: up{job="node"} == 0
                for: 5m
                labels:
                  severity: warning
                annotations:
                  summary: "node exporter on {{ $labels.host }} ({{ $labels.instance }}) is down"

              - alert: CadvisorDown
                expr: up{job="cadvisor"} == 0
                for: 5m
                labels:
                  severity: warning
                annotations:
                  summary: "cadvisor on {{ $labels.host }} ({{ $labels.instance }}) is down"

              # The Dream Router rules were rewritten after 10-11 Sep 2026, when
              # the router's Network app ran out of memory over a week and was
              # unresponsive for 12h before a reboot. The old rules (instant
              # value > threshold for 5m) went "pending" 19 times that week and
              # fired zero times: peaks crossed the line, the `for:` timer reset
              # in the troughs. Every rule below reads a window instead of an
              # instant, which also makes them indifferent to the 2m scrape
              # interval above.

              # No successful scrape in 20 minutes. max_over_time rather than a
              # bare `up == 0` so a single slow scrape cannot start the timer.
              - alert: UnpollerDown
                expr: max_over_time(up{job="unpoller"}[10m]) == 0
                for: 10m
                labels:
                  severity: warning
                annotations:
                  summary: "unpoller is down or cannot reach the Dream Router API"

              # The leading indicator. Healthy, the controller answers unpoller in
              # 1.2-1.5s (p95 2-3s); in the week before it wedged the p95 rose
              # ~0.15s/day, and the sick day averaged 4.5s. An hour averaging
              # above 4s is the controller telling us it is struggling, days
              # before memory alone would.
              - alert: UnifiControllerSlow
                expr: avg_over_time(scrape_duration_seconds{job="unpoller"}[1h]) > 4
                for: 30m
                labels:
                  severity: warning
                annotations:
                  summary: "Dream Router API is averaging {{ $value | printf \"%.1f\" }}s per poll (healthy: ~1.5s)"

              # Sustained, not peak. Daily average CPU is ~20% with spikes to
              # 100% that mean nothing; an hourly average above 60% does.
              - alert: UnifiGatewayCpuHigh
                expr: 100 * max(avg_over_time(unpoller_device_cpu_utilization_ratio{type="udm"}[1h])) > 60
                for: 30m
                labels:
                  severity: warning
                annotations:
                  summary: "Dream Router CPU has averaged {{ $value | printf \"%.0f\" }}% for an hour"

              # The app failed with hourly-average RAM around 85%. 80% sustained
              # is the "act today" line; the trend rule below is the "act this
              # week" line.
              - alert: UnifiGatewayMemHigh
                expr: 100 * max(avg_over_time(unpoller_device_memory_utilization_ratio{type="udm"}[1h])) > 80
                for: 30m
                labels:
                  severity: warning
                annotations:
                  summary: "Dream Router RAM has averaged {{ $value | printf \"%.0f\" }}% for an hour"

              # Extrapolate the last two days of RAM three days forward. On the
              # slope seen in Sep 2026 (+1.5-3 points/day from ~70%) this fires
              # around 76-80%, three to four days before the app dies -- time to
              # trim controller features or schedule a reboot in the 03:00
              # window. A reboot inside the 2d window gives a negative slope and
              # clears it, which is the right answer.
              - alert: UnifiGatewayMemTrend
                expr: 100 * max(predict_linear(unpoller_device_memory_utilization_ratio{type="udm"}[2d], 3 * 86400)) > 85
                for: 6h
                labels:
                  severity: warning
                annotations:
                  summary: "Dream Router RAM is on course for {{ $value | printf \"%.0f\" }}% within 3 days"

              - alert: PracticeLobbiesFailed
                expr: node_systemd_unit_state{name="ac-host-static.service",state="failed"} == 1
                for: 2m
                labels:
                  severity: critical
                annotations:
                  summary: "ac-host-static.service is failed — practice lobbies may be down"
      ''
    ];
  };

  services.prometheus.alertmanager = {
    enable = true;
    listenAddress = "127.0.0.1";
    port = 9093;
    configuration = {
      route = {
        receiver = "discord";
        group_by = [ "alertname" ];
        group_wait = "30s";
        group_interval = "5m";
        repeat_interval = "4h";
      };
      receivers = [
        {
          name = "discord";
          discord_configs = [
            {
              webhook_url_file = discordWebhookFile;
              send_resolved = true;
            }
          ];
        }
      ];
    };
  };

  systemd.services.alertmanager.serviceConfig.SupplementaryGroups = [ "monitoring" ];
  systemd.services.alertmanager.unitConfig.ConditionPathExists = discordWebhookFile;

  systemd.services.grafana.wants = [ "network-online.target" ];
  systemd.services.grafana.after = [ "network-online.target" ];
  systemd.services.grafana.serviceConfig.SupplementaryGroups = [ "monitoring" ];

  services.grafana = {
    enable = true;
    settings = {
      # Derived, not literal. These were three separate hardcoded copies of
      # 192.168.1.50 -- a fourth, fifth and sixth alongside the ones that had
      # already drifted between arcade-hub and agent-hub, and exactly what the
      # README's "a module contains no host facts" rule exists to stop.
      #
      # This module can read homelab.host directly because it is L2, owned by this
      # repo. A tenant flake cannot: arcade-hub and agent-hub have to stay usable
      # standalone, so they take the address as a required option and the host
      # composition passes it in. Same rule, different mechanism, because the
      # constraint on them is different.
      server = {
        http_addr = grafanaAddr;
        http_port = grafanaPort;
        domain = grafanaAddr;
        root_url = "http://${grafanaAddr}:${toString grafanaPort}/";
        enable_gzip = true;
      };
      security = {
        admin_user = "admin";
        admin_password = "$__file{${grafanaAdminFile}}";
        secret_key = "$__file{${grafanaSecretFile}}";
        disable_initial_admin_creation = false;
      };
      "auth.anonymous" = {
        enabled = true;
        org_name = "Main Org.";
        org_role = "Viewer";
        hide_version = true;
      };
      analytics = {
        reporting_enabled = false;
        check_for_updates = false;
      };
      users.allow_sign_up = false;
    };
    provision = {
      datasources.settings.datasources = [
        {
          name = "Prometheus";
          type = "prometheus";
          uid = "prometheus";
          access = "proxy";
          url = "http://127.0.0.1:9090";
          isDefault = true;
          editable = false;
        }
      ];
      dashboards.settings.providers = [
        {
          name = "ac-host";
          type = "file";
          allowUiUpdates = true;
          options.path = "${dashboardsDir}";
        }
      ];
    };
  };
}
