# The six tenants sharing ac-box, declared against modules/tenant/schema.nix.
# Every field here was verified live on the box (ss -tulnp, docker ps,
# systemctl list-units, and the tenants' own source) on 7 Sep 2026 — see the
# beads homelab-bqo.4 report for the full port table and the discrepancies
# found along the way (mindustry not actually bound despite "active", the
# observability state dir being /var/lib/monitoring not /var/lib/observability,
# freeciv's real LAN-announce UDP port being 4555 not 5556).
#
# Takes `config` for exactly one reason: agent-hub's metrics.address must be
# a REFERENCE to homelab.host.networks.lan.address, never a literal -- the
# same way configuration.nix feeds services.agent-hub.lanAddress. A literal
# passes today and fails evaluation the day the box's address moves.
{ config, ... }:

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
        # on 11200/11201/11202 for the three configured prod lobbies (slots
        # 0-2). 11208 appears only while the dev environment is up -- slot 8
        # is DEV_RESERVED in acctl.py -- and it was up when this was first
        # written (7 Sep) and torn down that night. Nothing
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

        # The OTHER end of the same ACSP conversation. pluginUdp above is
        # acServer's socket (`UDP_PLUGIN_LOCAL_PORT`); this range is the
        # leaderboard sidecar's, the one acServer is told to send events to
        # (`UDP_PLUGIN_ADDRESS=127.0.0.1:<this>`). Two ranges, not one,
        # because both ends are real bound sockets on this host — missing
        # that is how 11300 stayed unregistered while 11200 was declared.
        #
        # start/count are read off the tenant's source, NOT off `ss`.
        # scripts/render_cfg.py, which writes every server_cfg.ini:
        #
        #     GAME_PORT_START = 9600
        #     PLUGIN_LOCAL_START = 11200
        #     PLUGIN_EVENT_START = 11300
        #
        #     def plugin_ports(udp: int) -> tuple[int, int]:
        #         slot = max(0, udp - GAME_PORT_START)
        #         return PLUGIN_LOCAL_START + slot, PLUGIN_EVENT_START + slot
        #
        # sidecar/plugin.py repeats the same constants and binds one socket
        # per slot at `event_port = PLUGIN_EVENT_START + slot`, so the range
        # is one-per-lobby-slot exactly like pluginUdp. The slot space is
        # bounded at 16 by scripts/acctl.py (`SLOT_COUNT = 16`, and
        # next_free_slot() iterates `range(SLOT_COUNT)` before raising "no
        # free race slots (9600–9615)"), which is where game/http/details
        # get their count = 16 too. Hence 11300..11315.
        #
        # Deliberately NOT derived from what was running: `ss -ulnp` on
        # 9 Sep 2026 showed only 11300/11301/11302 bound (pid 198812,
        # `python -u /app/plugin.py` in container ac-host-plugin-1), because
        # only three lobbies were up. Sizing the claim to that would leave
        # 11303-11315 free for another tenant to take and collide the next
        # time a fourth lobby starts — the exact failure this registry is
        # for. Fourth live-listener gap found this way, after the 11200
        # range, the 18080/18081 auth sidecars and arcade's 4555.
        #
        # scope = "local" is the bind address for once, not just the
        # platform's exposure: compose/docker-compose.yml pins
        # `PLUGIN_HOST: 127.0.0.1` on the plugin service and plugin.py binds
        # `self.host`, confirmed live as 127.0.0.1:11300-11302 rather than
        # the `*:11200` acServer shows. ports.nix emits firewall rules only
        # for lan/forwarded/mgmt (`portsOn` is never called with "local"),
        # so this adds no rule — the same way 11200 already gets none.
        pluginEvent = {
          start = 11300;
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

      # The auth sidecars. Both containers run with NetworkMode: host, so they
      # bind the host's loopback directly rather than publishing a mapped port
      # -- which is why they are invisible to `docker port` and were missed on
      # the first pass through this file.
      #
      # Found the same way as the 11200 range: by diffing `ss -tlnp` against
      # these declarations, not by reading a config file. Neither appears in
      # ac-host.nix. They are registered so the collision assertion knows the
      # numbers are taken; scope = "local" means no firewall rule is emitted,
      # matching how they actually bind.
      ports = {
        auth = {
          number = 18080;
          proto = [ "tcp" ];
          scope = "local";
        };
        auth-dev = {
          number = 18081;
          proto = [ "tcp" ];
          scope = "local";
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
        # Exit 0 = BUSY. Asks acServer itself: scripts/drivers_online.py (in
        # the tenant tree, ac-host 501d7e9) GETs every running lobby's
        # /api/details and sums `clients`, the live connected-driver count.
        # Exit 1 = nobody racing; 0 = someone is, or a lobby is listening and
        # will not answer (fail closed).
        #
        # `test $? -ne 1` and not the bare script, so that a MISSING or
        # broken script (exit 2, 127) also reads as BUSY. The one exit code
        # that means "go" is the script saying so.
        #
        # This replaces `test ! -e /var/lib/ac-host/maintenance.json` --
        # "busy unless explicitly drained", which was an interpretation of
        # server_health.py's flag, not a check of race state (bead .34). It
        # was merely conservative until modules/deploy existed; then it became
        # a defect with a schedule. The deploy timer fired at 03:00, the bot's
        # DOWNTIME=1 build that performs the drain is picked up seconds to
        # minutes later, so the unit lost that race and would have deferred
        # every night. Found 12 Sep 2026 while closing the bead, before the
        # first automatic firing.
        busyCheck = "python3 /var/lib/ac-host/src/scripts/drivers_online.py; test $? -ne 1";
        drain = "python3 /var/lib/ac-host/src/scripts/acctl.py --env prod drain";
        resume = "python3 /var/lib/ac-host/src/scripts/acctl.py --env prod resume";
      };

      metrics = null;
    };

    # The Discord bot, its own tenant as of 12 Sep 2026 -- README's "splits out
    # after phase 6" deferral, honoured. It was a compose profile inside
    # assetto because it shares assetto's state (it edits the whitelist) and
    # assetto's compose project; it is a tenant because it has a lifecycle,
    # secrets and a job of its own that assetto's declaration could not say.
    #
    # And the job matters more than a chat bot's usually does: bot/downtime.py
    # runs the 03:00 countdown and, at mark 0, queues DOWNTIME=1 -- the build
    # that applies the tenant tree and recycles the lobbies. It holds
    # BUILDKITE_API_TOKEN for exactly that. If it is not running at 02:59,
    # the tenant tree does not deploy that night. The deploy path for the
    # system closure (modules/deploy) is a systemd timer and does not depend
    # on it; the deploy path for the tenant tree does.
    bot = {
      description = "Discord bot: player whitelist and verification, the status page, and the 03:00 downtime countdown that queues the tenant-tree deploy.";

      # critical, because that is where its container already runs --
      # compose/docker-compose.yml sets cgroup_parent: critical.slice on the
      # bot service -- and phase 6 declares what is, it does not re-tier.
      # interactive would be the honest tier for a Discord client that needs
      # no CPU priority: 0.3 GiB RSS, near-zero CPU, and its one time-critical
      # act is an HTTP POST. Moving it is a one-line cgroup_parent change in
      # ac-host's compose file plus this word; the next ci_downtime `up -d
      # --build bot` recreates the container into the new slice. Left for a
      # deliberate change, not a side effect of naming the tenant.
      tier = "critical";

      # ac-host 8c456cb, same day as this tenant. Until then the bot had NO
      # unit: Docker's `restart: unless-stopped` brought it up at boot and
      # scripts/ci_downtime.py ran `compose --profile bot up -d --build bot`
      # nightly -- two owners, neither systemd, invisible to the unit-based
      # blast-radius gate (bead homelab-bqo.14's gap, one container over).
      # The unit runs the same compose command, so the owners agree by
      # construction and there is one ac-host-bot-1, never two.
      #
      # tier = critical means resources.nix assigns it no Slice= (critical is
      # never sliced) -- correct, since the container's placement comes from
      # cgroup_parent in the compose file, not from the unit. It will appear
      # in the "intentionally NOT assigned a slice" evaluation warning
      # alongside assetto's units; that is the declaration working.
      units = [ "ac-host-bot.service" ];

      # No ports. It is a Discord client: outbound WebSocket and HTTPS only,
      # nothing bound. Verified against `ss -tulnp` -- every socket on the box
      # is accounted for by the other five tenants.

      # assetto's state directory, declared here too, on purpose. The bot's
      # data IS assetto's data -- /data/whitelist.json and steam_requests.json
      # are the files it exists to edit -- and a separate directory would be
      # a lie about where the state lives. Nothing asserts state-dir
      # uniqueness across tenants (schema.nix), and this is the case that
      # shows why it should not: shared state is real and should be declared
      # as shared. backup = false because assetto already backs the directory
      # up; a second true would not back it up twice, but it would make the
      # inventory claim two owners of one backup.
      state = {
        dirs = [ "/var/lib/ac-host" ];
        backup = false;
      };

      # Names only. discord-token and buildkite-api-token arrive as compose
      # env (${DISCORD_TOKEN}, ${BUILDKITE_API_TOKEN} from compose/.env);
      # github-token is a file at /var/lib/ac-host/secrets/github-token.
      # None is provisioned by anything in this repo yet -- README says
      # credentials go to sops-nix, and none do. Declaring the names is what
      # lets that migration know what it is migrating.
      secrets = [
        "discord-token"
        "buildkite-api-token"
        "github-token"
      ];

      needsDocker = true;

      # A bounce is a Discord reconnect, seconds, and the countdown state is
      # recomputed from the clock on start -- so drainable. The one window
      # where a bounce hurts is roughly 02:45-03:05, when a restart could miss
      # the mark-0 DOWNTIME=1 post. Not encoded as a busyCheck: modules/deploy
      # fires at exactly 03:00 and consults busyCheck only for non-drainable
      # tenants, so the honest encoding would either be ignored or would
      # defer every closure deploy forever. Recorded here instead, for the
      # human planning a manual bounce.
      quiet.drainable = true;

      metrics = null;
    };

    # Kid arcade hub: LAN-only game servers plus a Samba/rsync export of the
    # ROM library. Never touches Docker or the AC firewall (arcade-hub.nix).
    arcade = {
      description = "LAN arcade hub: Freeciv/Mindustry dedicated servers, SMB + rsync ROM library export.";
      tier = "interactive";

      # The ROM export is arcade's too, not the platform's. smbd, winbindd and
      # rsyncd all exist solely because services.arcade-hub turns them on
      # (arcade-hub.nix's services.samba / services.rsyncd blocks, gated on
      # cfg.smb.enable and cfg.rsync.enable), and this tenant already declares
      # their ports -- 445, 139 and 873 are right below. Declaring the ports
      # but not the units was half a declaration: the three ran in
      # system.slice, outside interactive.slice, uncapped by the tier they
      # belong to and invisible to drain and to /etc/homelab/tenants.json.
      #
      # Names are verbatim from the box (`systemctl list-unit-files`), per the
      # README's unit-name rule. Note rsync.service, NOT rsyncd.service --
      # NixOS's services.rsyncd generates a unit called rsync.service and
      # carries rsyncd.service only as an alias, so the alias is the wrong
      # string to put here even though the option is spelled rsyncd.
      #
      # Consequence, stated because it is a real one: arcade is sliceable
      # (tier != critical, quiet.drainable defaults true), so resources.nix
      # now emits Slice=interactive.slice and Nice=0 for these three. Slice=
      # applies at unit start, so the next switch RESTARTS them -- open SMB
      # sessions and in-flight rsync transfers drop. That is acceptable here
      # in a way it explicitly is not for assetto: nothing is mid-race, the
      # clients are kids' machines that reconnect, and the alternative is
      # leaving the ROM library permanently outside the tier model.
      units = [
        "arcade-freeciv.service"
        "arcade-mindustry.service"
        "samba-smbd.service"
        "samba-winbindd.service"
        "rsync.service"
      ];

      ports = {
        # TCP only. The server's UDP socket is a different port entirely -- see
        # freeciv-announce below. Declaring udp here claimed 5556/udp, which
        # nothing listens on, and left the real one unregistered.
        freeciv = {
          number = 5556;
          proto = [ "tcp" ];
          scope = "lan";
        };
        # The LAN-discovery socket, verified live on 0.0.0.0:4555. Third set of
        # live ports found by diffing `ss` against these declarations rather than
        # by reading a config file -- after assetto's 11200 range and its 18080
        # auth sidecars.
        freeciv-announce = {
          number = 4555;
          proto = [ "udp" ];
          scope = "lan";
        };
        mindustry = {
          number = 6567;
          proto = [ "tcp" "udp" ];
          scope = "lan";
        };
        # Mindustry's LAN-discovery multicast socket, the second UDP socket on
        # the same java pid as 6567 (`ss -ulnp` 9 Sep 2026: `*:20151` and
        # `*:6567`, both pid 151330 fd=14/fd=13). Fourth undeclared live
        # listener found by that diff.
        #
        # Declared because it is a fixed constant, not a port the JVM picked.
        # That was the whole question: 20151 appears in no config file, in no
        # arcade-mindustry journal line (the service only ever logs "Opened a
        # server on port 6567"), and it binds on all interfaces, which is the
        # shape of an ephemeral source port. It is not one. Two pieces of
        # evidence, since the service cannot be restarted to test:
        #
        #   - It is outside the kernel's ephemeral range. `sysctl
        #     net.ipv4.ip_local_port_range` on ac-box is 32768-60999, so no
        #     bind-to-port-0 could ever land on 20151; something asked for it
        #     by number.
        #   - That something is the shipped jar. In
        #     /var/lib/arcade/mindustry/server-release.jar, mindustry.Vars
        #     carries `public static final int multicastPort = 20151` and
        #     `public static final String multicastGroup = "227.2.7.7"`
        #     (javap -constants), and ArcNetProvider's constructor calls
        #     `arc.net.Server.setMulticast(multicastGroup, multicastPort)`.
        #     Compile-time finals, with no console command and no
        #     services.arcade-hub option behind them. Corroborated live:
        #     /proc/net/igmp lists group 070702E3 -- 227.2.7.7 -- joined on
        #     enp8s0, which is that exact multicastGroup.
        #
        # scope = "lan", because discovery is supposed to work. This started
        # as "local" on the reasoning that scope describes what the platform
        # exposes rather than where a socket binds (the alertmanager-mesh
        # call), and that homelab must not open a hole the tenant module never
        # asked for. Both halves were right; the conclusion was wrong, because
        # the tenant module not asking was itself the bug.
        #
        # arcade-hub.nix opened only cfg.mindustry.port on the game interface,
        # so `iptables -S` had accept rules for 6567/tcp and 6567/udp and
        # nothing for 20151: every multicast discovery packet from a LAN
        # client was dropped, and the only way onto the server was typing its
        # address -- on a hub whose entire purpose is that a kid can find the
        # game without being told an IP. Exactly the failure freeciv had
        # before announcePort was split out, one game later.
        #
        # home-arcade now declares mindustry.multicastPort (default 20151) and
        # opens it alongside the game port, mirroring freeciv.announcePort. So
        # "lan" is no longer homelab reaching past the tenant -- it is the
        # registry agreeing with what the tenant module asks for, which is the
        # only arrangement the contract permits.
        mindustry-multicast = {
          number = 20151;
          proto = [ "udp" ];
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
    # LAN-bound. Runner phase (repo access, PR creation) is not enabled yet --
    # services.agent-hub.runner.enable stays false in configuration.nix.
    agent-hub = {
      # ON as of 8 Sep 2026, in the same change that sets
      # services.agent-hub.enable + .llm.enable with a real llm.modelPath in
      # hosts/ac-box/configuration.nix. That pairing is the rule: this flag
      # and the service's own enable flip together, because either one alone
      # is a lie -- this flag alone opens a firewall port and assigns a slice
      # to a unit that does not exist, and the service alone runs a unit the
      # platform does not know about.
      #
      # Historical note worth keeping: while this was false, the contract
      # STILL opened tcp/8100 on enp8s0 (verified live -- `iptables -S` had
      # the accept rule with nothing listening). ports.nix did not filter on
      # enable the way resources.nix and quiet.nix do; that is fixed now, so
      # the pairing above is enforced by the code rather than by comment.
      enable = true;

      description = "LAN-only llama.cpp model server for the local coding agent (phase 1: serving only).";

      # Deliberately still "background", not a promotion to "critical", even
      # though this box's whole point is now the model server. background is
      # the tier that CAN be fenced and capped; critical is the tier that is
      # never sliced at all (see resources.nix's sliceableTenants). Routing
      # the machine's resources here is done by moving the SHARES in
      # configuration.nix's homelab.tiers block -- background now holds 0.65
      # of memory and the bulk of the cores -- not by moving the tenant into
      # the tier that opts out of resource control entirely.
      tier = "background";

      # nginx: the landing page in front of llama-swap (services.agent-hub
      # .llm.landingPage in configuration.nix). Nothing else on this box runs
      # nginx; if something ever does, this claim relocates it -- see the
      # AGENTS.md note on `units` being an authoritative claim.
      units = [
        "agent-hub-llm.service"
        "nginx.service"
      ];

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

      # Model weights: hundreds of GiB, and every one of them is re-obtainable
      # from Hugging Face. Same call arcade makes about ROMs -- not worth a
      # backup slot.
      data = {
        dirs = [ "/srv/agent-hub" ];
        backup = false;
      };

      state = {
        dirs = [ "/var/lib/agent-hub" ];
        backup = true;
      };

      # Scraped on the LAN address, not loopback -- the first endpoint on this
      # box that is. llama-server runs `--host 192.168.1.50 --metrics`
      # (configuration.nix) because being reachable from other machines is
      # the whole point of the service, and it does NOT also listen on
      # loopback: `curl 127.0.0.1:8100/metrics` on the box is connection
      # refused while the LAN address serves eleven `llamacpp:*` series
      # (verified 12 Sep 2026, generation 32). Until metricsEndpoint gained
      # `address` today this was `metrics = null` with a comment saying why;
      # that comment was right that it needed a schema change, and the schema
      # changed.
      #
      # address is a REFERENCE to the host fact, never the literal. metrics.nix
      # asserts it is loopback or an address homelab.host actually declares,
      # so a literal would pass today and fail the day the address moves --
      # which is the assertion doing its job, but late and by surprise.
      #
      # job defaults to the tenant name, "agent-hub". No dashboard is keyed on
      # it yet, so there is nothing to preserve and no reason to spell it
      # differently from the tenant.
      metrics = {
        port = 8100;
        address = config.homelab.host.networks.lan.address;
      };
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

      # The unit modules/ci creates once homelab.ci.enable is on. Declared
      # here so the inventory (/etc/homelab/tenants.json), drain planning and
      # the reconciliation diff all know the unit belongs to someone -- an
      # empty `units` was the tell that this tenant's lifecycle was unmanaged,
      # and it stayed empty after the module landed, so the unit would have
      # run in no tenant's name. modules/ci's own header names this follow-up.
      #
      # What Slice= does and does not do here. ac-host-ci is Type=oneshot with
      # RemainAfterExit: it runs `docker-compose up -d --build` and exits, so
      # the slice holds a brief supervisor invocation and nothing else. The
      # agent and MinIO containers were already in batch.slice via the compose
      # file's cgroup_parent (ADR 0005) -- that is not what this line changes.
      # It also does not bounce the unit on switch: modules/ci sets
      # restartIfChanged = false and stopIfChanged = false for HAZARD 2, and
      # those hold regardless of Slice=.
      units = [ "ac-host-ci.service" ];

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
