# The five tenants sharing ac-box, declared against modules/tenant/schema.nix.
# Every field here was verified live on the box (ss -tulnp, docker ps,
# systemctl list-units, and the tenants' own source) on 7 Sep 2026 — see the
# beads homelab-bqo.4 report for the full port table and the discrepancies
# found along the way (mindustry not actually bound despite "active", the
# observability state dir being /var/lib/monitoring not /var/lib/observability,
# freeciv's real LAN-announce UDP port being 4555 not 5556).
{ ... }:

{
  homelab.tenants = {

    # Assetto Corsa lobby host. Internet-facing on purpose: unifi_pf.py opens
    # a UniFi Dream Router forward per lobby slot so drivers off the LAN can
    # join. Gated by the ac-host-auth sidecar, not by network obscurity.
    assetto = {
      description = "Assetto Corsa practice/race lobby host (Docker + auth sidecar + static lobbies).";
      tier = "critical";

      units = [
        "ac-host-static.service"
        "ac-host-nightly.service"
        "ac-host-nightly.timer"
        "ac-host-dev.service"
      ];

      portRanges = {
        # acServer opens a second UDP socket at gamePort + 1600 per slot; live
        # on 11200/11201/11202/11208 for the four running lobbies. Nothing
        # firewalls or forwards these — ac-host.nix never mentions them and
        # unifi_pf.py only forwards game/http/details — so they are effectively
        # host-local despite binding on all interfaces.
        #
        # Declared anyway, and this is precisely why the registry exists: these
        # sixteen port numbers ARE occupied on this host, so leaving them out
        # means the collision assertion would let another tenant claim 11200 and
        # nobody would find out until runtime. Found by cross-checking
        # `ss -ulnp` against the declarations, because no config file mentions
        # them at all.
        pluginUdp = {
          start = 11200;
          count = 16;
          proto = [ "udp" ];
          scope = "local";
        };

        game = {
          start = 9600;
          count = 16;
          proto = [ "tcp" "udp" ];
          scope = "forwarded";
          justification = ''
            unifi_pf.py opens an "ac-{env}-s{slot}-game" TCP+UDP forward per
            lobby slot on the Dream Router. Reachable from the internet by
            design, but every connecting Steam ID still has to pass the
            ac-host-auth sidecar (authOpen=false, requiredRole="ac-practice")
            before the lobby accepts them.
          '';
        };
        http = {
          start = 8081;
          count = 16;
          proto = [ "tcp" ];
          scope = "forwarded";
          justification = ''
            unifi_pf.py opens an "ac-{env}-s{slot}-http" TCP forward per lobby
            slot (Content Manager reads server details over this). Same
            ac-host-auth sidecar gate as the game port: authOpen=false,
            requiredRole="ac-practice".
          '';
        };
        details = {
          start = 8181;
          count = 16;
          proto = [ "tcp" ];
          scope = "forwarded";
          justification = ''
            unifi_pf.py opens an "ac-{env}-s{slot}-details" TCP forward per
            lobby slot (the /api/details endpoint Content Manager's server
            list reads). Same ac-host-auth sidecar gate: authOpen=false,
            requiredRole="ac-practice".
          '';
        };
      };

      # Preserved, not derived: /var/lib/ac-host predates this repo and holds
      # the whitelist, race/series history and generated content. Renaming it
      # is a data migration, not a config change (README, "State paths").
      state = {
        dirs = [ "/var/lib/ac-host" ];
        backup = true;
      };

      needsDocker = true;

      quiet = {
        drainable = false;
        # server_health.py's read_flag() treats a MISSING maintenance.json as
        # "up" (potentially serving real drivers) and a present one as
        # "down"/"maintenance". Exit 0 = BUSY, so: busy iff not drained yet.
        busyCheck = "test ! -e /var/lib/ac-host/maintenance.json";
        drain = "python3 /var/lib/ac-host/src/scripts/acctl.py --env prod drain";
        resume = "python3 /var/lib/ac-host/src/scripts/acctl.py --env prod resume";
      };

      metrics = null;
    };

    # Kid arcade hub: LAN-only game servers plus a Samba/rsync export of the
    # ROM library. Never touches Docker or the AC firewall (arcade-hub.nix).
    arcade = {
      description = "LAN arcade hub: Freeciv/Mindustry dedicated servers, SMB + rsync ROM library export.";
      tier = "interactive";

      units = [
        "arcade-freeciv.service"
        "arcade-mindustry.service"
      ];

      ports = {
        freeciv = {
          number = 5556;
          proto = [ "tcp" "udp" ];
          scope = "lan";
        };
        mindustry = {
          number = 6567;
          proto = [ "tcp" "udp" ];
          scope = "lan";
        };
        smb = {
          number = 445;
          proto = [ "tcp" ];
          scope = "lan";
        };
        smb-netbios = {
          number = 139;
          proto = [ "tcp" ];
          scope = "lan";
        };
        rsync = {
          number = 873;
          proto = [ "tcp" ];
          scope = "lan";
        };
      };

      state = {
        dirs = [ "/var/lib/arcade" ];
        backup = true;
      };

      data = {
        # ROMs: huge, and every one of them is re-obtainable. Not worth a
        # backup slot.
        dirs = [ "/srv/arcade" ];
        backup = false;
      };

      secrets = [ "arcade-smb-password" ];

      metrics = null;
    };

    # Phase 1 of the local coding-agent host: llama.cpp model server only,
    # LAN-bound. Runner phase (repo access, PR creation) is not enabled yet.
    agent-hub = {
      description = "LAN-only llama.cpp model server for the local coding agent (phase 1: serving only).";
      tier = "background";

      units = [ "agent-hub-llm.service" ];

      ports = {
        # NOT the module's own default (8091) -- that falls inside assetto's
        # reserved http range (8081-8096). 8100 is the first free port past
        # every assetto/arcade/observability/ci claim in this file.
        llm = {
          number = 8100;
          proto = [ "tcp" ];
          scope = "lan";
        };
      };

      metrics = null;
    };

    # Prometheus/Alertmanager/Grafana plus the box's own exporters. Every
    # collector binds loopback-only; Grafana is the one deliberately LAN port.
    observability = {
      description = "Prometheus, Alertmanager and Grafana, plus node/cadvisor/UniFi/docker-name exporters for ac-box.";
      tier = "interactive";

      units = [
        "prometheus.service"
        "alertmanager.service"
        "grafana.service"
        "prometheus-node-exporter.service"
        "cadvisor.service"
        "unifi-poller.service"
        "docker-name-exporter.service"
        "udr-fw-exporter.service"
      ];

      ports = {
        prometheus = {
          number = 9090;
          proto = [ "tcp" ];
          scope = "local";
        };
        alertmanager = {
          number = 9093;
          proto = [ "tcp" ];
          scope = "local";
        };
        # Alertmanager's gossip/mesh port. Bound on all interfaces by the
        # binary's own default (no listenAddress knob in the NixOS module),
        # but never opened in the firewall -- so it stays "local" here: the
        # scope describes what the platform exposes, not the bind address.
        alertmanager-mesh = {
          number = 9094;
          proto = [ "tcp" "udp" ];
          scope = "local";
        };
        node = {
          number = 9100;
          proto = [ "tcp" ];
          scope = "local";
        };
        cadvisor = {
          number = 9102;
          proto = [ "tcp" ];
          scope = "local";
        };
        unpoller = {
          number = 9130;
          proto = [ "tcp" ];
          scope = "local";
        };
        udr-fw = {
          number = 9131;
          proto = [ "tcp" ];
          scope = "local";
        };
        docker-names = {
          number = 9132;
          proto = [ "tcp" ];
          scope = "local";
        };
        grafana = {
          number = 3000;
          proto = [ "tcp" ];
          scope = "lan";
        };
      };

      # /var/lib/monitoring, not the derived default (/var/lib/observability):
      # it holds the Discord webhook and unifi-poller password files, which
      # are hand-placed and not regenerated by the activation script the way
      # the Grafana admin/secret files are. Preserve it like assetto's dir.
      state = {
        dirs = [ "/var/lib/monitoring" ];
        backup = true;
      };

      needsDocker = true;

      metrics = null;
    };

    # Self-hosted Buildkite agent for the ac-host repo, plus a loopback-only
    # MinIO acting as a Nix binary cache for the flox build environment.
    # Started by hand via docker compose today -- no systemd unit wraps it.
    ci = {
      description = "Self-hosted Buildkite agent (Flox sandbox) with a loopback MinIO Nix binary cache.";
      tier = "batch";

      ports = {
        minio-api = {
          number = 9000;
          proto = [ "tcp" ];
          scope = "local";
        };
        minio-console = {
          number = 9001;
          proto = [ "tcp" ];
          scope = "local";
        };
      };

      needsDocker = true;

      secrets = [
        "buildkite-agent-token"
        "minio-root-password"
        "s3-cache-access-key-id"
        "s3-cache-secret-access-key"
        "s3-cache-signing-key"
      ];

      metrics = null;
    };

  };
}
