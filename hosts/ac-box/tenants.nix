# The one tenant on ac-box since the cutover (ADR 0010, docs/runbook-arcade-
# box-cutover.md 4.2): agent-hub. The other five -- assetto, bot, arcade,
# observability, ci -- moved to hosts/arcade-box/tenants.nix, verbatim, the
# day the lobbies did; this file's history has every survey note they carried.
# The Z840 is llm-box in everything but name, and the rename (homelab-ygc.9)
# is where this file moves to hosts/llm-box/.
#
# Took `config` for agent-hub's metrics.address until homelab-ygc.10 moved
# the scrape to arcade-box's peers entry; the header keeps the module's
# shape so the day a tenant here needs a host fact again it is a REFERENCE
# to homelab.host, never a literal -- a literal passes today and fails
# evaluation the day the box's address moves, which the cutover was.
{ lib, ... }:

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

      # Still "background", and on this host the word is inert: since
      # homelab-ygc.13 (26 Sep 2026) configuration.nix sets
      # homelab.enforce.slices = false, so no slice, ceiling or fence is
      # derived from it -- the model server runs in system.slice with the
      # whole machine (ADR 0010: llm-box has no tiers). The tier stays
      # declared because the contract requires one and because it is the
      # right word if this tenant ever shares a host again: background is
      # the tier that CAN be fenced and capped, critical the one that is
      # never sliced at all (resources.nix's sliceableTenants).
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

      # No local scrape: this host runs no Prometheus since the cutover. The
      # model server's /metrics (llamacpp:* and llamaswap_* through nginx on
      # the LAN port) is scraped by arcade-box as a PEER endpoint --
      # hosts/arcade-box/host.nix, peers.<this host>.metrics, job "agent-hub"
      # (homelab-ygc.10) -- which is the one place the port and address are
      # spelled for that purpose. From 12 to 26 Sep 2026 this was
      # `metrics = { port = 8100; address = <lan>; }` and the box's own
      # Prometheus scraped it; with services.prometheus off, that declaration
      # rendered nothing and was a third spelling of 8100.
      metrics = null;
    };

  };
}
