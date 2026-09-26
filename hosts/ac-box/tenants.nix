# The one tenant on ac-box since the cutover (ADR 0010, docs/runbook-arcade-
# box-cutover.md 4.2): agent-hub. The other five -- assetto, bot, arcade,
# observability, ci -- moved to hosts/arcade-box/tenants.nix, verbatim, the
# day the lobbies did; this file's history has every survey note they carried.
# The Z840 is llm-box in everything but name, and the rename (homelab-ygc.9)
# is where this file moves to hosts/llm-box/.
#
# Takes `config` for agent-hub's metrics.address, which must be a REFERENCE
# to homelab.host.networks.lan.address, never a literal -- the same way
# configuration.nix feeds services.agent-hub.lanAddress. A literal passes
# today and fails evaluation the day the box's address moves, which the
# cutover is.
{ config, lib, ... }:

{
  homelab.tenants = {

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
      # configuration.nix's homelab.tiers block -- background now holds 0.81
      # of memory and the bulk of the cores -- not by moving the tenant into
      # the tier that opts out of resource control entirely.
      tier = "background";

      # nginx: the landing page in front of llama-swap (services.agent-hub
      # .llm.landingPage in configuration.nix). Nothing else on this box runs
      # nginx; if something ever does, this claim relocates it -- see the
      # AGENTS.md note on `units` being an authoritative claim.
      #
      # qdrant: the vector store beside the model server (services.agent-hub
      # .vectors in configuration.nix), nixpkgs' own unit. Same pairing rule
      # as nginx: this claim and vectors.enable flip together.
      units = [
        "agent-hub-llm.service"
        "nginx.service"
        "qdrant.service"
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
        # Qdrant's upstream HTTP port, kept because every client library
        # defaults to it; nothing else here is near it. gRPC (6334) is off
        # in the module, so there is no second claim.
        vectors = {
          number = 6333;
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

      # /var/lib/qdrant is where nixpkgs' qdrant unit keeps its store
      # (StateDirectory, a DynamicUser's -- not movable under agent-hub's
      # own dir without overriding the unit). The vectors in it are
      # re-derivable from the trees at the cost of re-embedding, which is
      # CPU on this box; small enough that backing it up is cheaper.
      state = {
        dirs = [
          "/var/lib/agent-hub"
          "/var/lib/qdrant"
        ];
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

  };
}
