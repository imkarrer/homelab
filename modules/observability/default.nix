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
  # Unchanged, and deliberately NOT derived from homelab.host.paths: this holds
  # hand-placed secrets (the Grafana admin password, the unifi-poller password,
  # the Discord webhook). Renaming it would be a data migration for no benefit --
  # the same reasoning ADR 0003 applies to /var/lib/ac-host.
  # The dashboard binds the LAN address rather than 0.0.0.0, and now takes it
  # from the one place this repo keeps machine literals.
  grafanaAddr = config.homelab.host.networks.lan.address;
  grafanaPort = 3000;

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

  system.activationScripts.monitoring-secrets = ''
    mkdir -p ${secretsDir}
    chmod 0750 ${secretsDir}
    chown root:monitoring ${secretsDir} || true
    if [ ! -s ${grafanaAdminFile} ]; then
      tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 > ${grafanaAdminFile}
      echo "created Grafana admin password in ${grafanaAdminFile}"
    fi
    if [ ! -s ${grafanaSecretFile} ]; then
      tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 > ${grafanaSecretFile}
    fi
    chmod 0640 ${grafanaAdminFile} ${grafanaSecretFile} ${unpollerPassFile} ${discordWebhookFile} 2>/dev/null || true
    chown root:monitoring ${grafanaAdminFile} ${grafanaSecretFile} ${unpollerPassFile} ${discordWebhookFile} 2>/dev/null || true
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
  # gate that builds nothing.
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
  ];

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
    globalConfig.scrape_interval = "30s";
    alertmanagers = [
      {
        static_configs = [
          { targets = [ "127.0.0.1:9093" ]; }
        ];
      }
    ];
    scrapeConfigs = [
      {
        job_name = "node";
        static_configs = [ { targets = [ "127.0.0.1:9100" ]; } ];
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
        static_configs = [ { targets = [ "127.0.0.1:9102" ]; } ];
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
      {
        job_name = "unpoller";
        scrape_interval = "30s";
        static_configs = [ { targets = [ "127.0.0.1:9130" ]; } ];
        metric_relabel_configs = [
          {
            source_labels = [ "__name__" ];
            regex = "up|unpoller_device_cpu_utilization_ratio|unpoller_device_memory_utilization_ratio|unpoller_device_wan_.*";
            action = "keep";
          }
        ];
      }
      {
        job_name = "udr-fw";
        scrape_interval = "30s";
        static_configs = [ { targets = [ "127.0.0.1:9131" ]; } ];
      }
      {
        job_name = "docker-names";
        scrape_interval = "30s";
        static_configs = [ { targets = [ "127.0.0.1:9132" ]; } ];
      }
    ];
    rules = [
      ''
        groups:
          - name: ac-box
            rules:
              - alert: AcBoxDiskHigh
                expr: 100 * (1 - node_filesystem_avail_bytes{mountpoint="/",fstype!="tmpfs"} / node_filesystem_size_bytes{mountpoint="/",fstype!="tmpfs"}) > 80
                for: 10m
                labels:
                  severity: warning
                annotations:
                  summary: "ac-box root disk is {{ $value | printf \"%.0f\" }}% full"

              - alert: AcBoxLoadHigh
                expr: node_load5 > 28
                for: 10m
                labels:
                  severity: warning
                annotations:
                  summary: "ac-box 5m load is {{ $value | printf \"%.1f\" }} (56 threads)"

              - alert: AcBoxMemLow
                expr: node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes < 0.10
                for: 10m
                labels:
                  severity: warning
                annotations:
                  summary: "ac-box has under 10% RAM available"

              - alert: AcBoxExporterDown
                expr: up{job=~"node|cadvisor"} == 0
                for: 5m
                labels:
                  severity: warning
                annotations:
                  summary: "Prometheus scrape {{ $labels.job }} is down"

              - alert: UnpollerDown
                expr: up{job="unpoller"} == 0
                for: 10m
                labels:
                  severity: warning
                annotations:
                  summary: "unpoller is down or cannot reach the Dream Router API"

              - alert: UnifiGatewayCpuHigh
                expr: 100 * max(unpoller_device_cpu_utilization_ratio{type="udm"}) > 80
                for: 5m
                labels:
                  severity: warning
                annotations:
                  summary: "Dream Router CPU is {{ $value | printf \"%.0f\" }}%"

              - alert: UnifiGatewayMemHigh
                expr: 100 * max(unpoller_device_memory_utilization_ratio{type="udm"}) > 85
                for: 5m
                labels:
                  severity: warning
                annotations:
                  summary: "Dream Router RAM is {{ $value | printf \"%.0f\" }}%"

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
