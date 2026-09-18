# agent-hub on ac-box: everything the tenant's NixOS module used to
# contribute that is NOT the model server's unit -- the user and group, its
# directories, the nginx landing page in front of llama-swap, and qdrant
# beside it -- plus the host facts hosts/ac-box/configuration.nix reads to
# fill the unit stub (homelab.tenants.agent-hub.environment).
#
# Moved here from agent-hub's modules/agent-hub.nix on 18 Sep 2026
# (homelab-158.11), verbatim where it is not dead, when that module left the
# closure: ADR 0009's end state is that a tenant author writes no Nix, so
# what a tenant needs from the HOST -- an identity, directories, a reverse
# proxy, a vector store from nixpkgs -- is the host composition's to say.
# The unit itself (agent-hub-llm.service) is the stub's whole, rendered by
# modules/tenant/environment.nix from configuration.nix's declaration;
# nothing here declares it. Proven byte-identical on the move: every unit,
# user, tmpfiles rule and firewall port compared equal between the closure
# with the module and this one.
#
# Kept as an option set under the module's old name, services.agent-hub,
# because that is what configuration.nix already sets and reads
# (llm.threads, llm.contextSize, llm.port, llm.backendPort, llm.landingPage,
# lanAddress, dataDir, stateDir, vectors.port, the models' kind and
# description) -- one spelling per value, so the stub and the page cannot
# drift. This file is host-local: it is imported by hosts/ac-box only, and
# a second host composing this tenant writes its own.
#
# Gone with the move, because nothing reads them: the module's llama-swap
# table fields (engine, extraArgs, concurrent, a model's modelPath / vae /
# textEncoder / aliases / extraArgs / contextSize -- the table is
# llama-swap.yaml in the tenant tree), llm.modelPath (single-model mode,
# retired with the module's ExecStart), the runner (services.agent-hub
# .runner: off everywhere, a Docker image the tenant tree builds; its
# DOCKER-USER egress chain returns as a host firewall fact when the runner
# is switched on), and the module's own firewall lines for llm.port and
# vectors.port -- the contract already opens both from the tenant's port
# claims in tenants.nix (modules/tenant/ports.nix), and the module's copy
# was a duplicate the firewall's port canonicalisation folded away.
#
# Never bind anything here past the LAN interface: this box is not a
# public host, and a model server that answers the internet is a bigger
# target than arcade-hub.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.agent-hub;

  multi = cfg.llm.models != { };

  # What the landing page says beside a model. The UI lists every model on
  # every playground tab and cannot know a model's kind; the description is
  # where a person learns which tab. The same text llama-swap.yaml carries
  # per model, so the page and /v1/models agree.
  modelDescription =
    name: m:
    if m.description != "" then
      m.description
    else if m.kind == "image" then
      "image generation -- use the Images tab (or /upstream/${name}/); it has no chat endpoint"
    else if m.kind == "embedding" then
      "embeddings -- POST /v1/embeddings; it has no chat endpoint and no UI"
    else
      "text -- use the Chat tab";

  # ./agent-hub/index.html is the tenant tree's nix/index.html, copied
  # byte-for-byte so the store path (content-addressed: same name, same
  # bytes) and with it nginx's config are unchanged by the move. The page
  # is tenant content living in the host tree, which is the one duplicate
  # this move creates; serving it from the checkout at
  # <environment.dir>/nix/index.html instead is the follow-up that returns
  # it to the tenant (a nginx.conf change, so not this bead's byte-identical
  # proof).
  landingDir = pkgs.runCommand "agent-hub-landing" { } ''
    mkdir -p $out
    cp ${./agent-hub/index.html} $out/index.html
    cp ${
      pkgs.writeText "models.json" (
        builtins.toJSON (
          lib.mapAttrs (name: m: {
            inherit (m) kind;
            description = modelDescription name m;
          }) cfg.llm.models
        )
      )
    } $out/models.json
  '';
in
{
  options.services.agent-hub = {
    enable = lib.mkEnableOption ''
      the agent-hub tenant's host side, LAN-only: the agent-hub user, its
      directories, the landing page and the vector store. The model
      server's unit is homelab.tenants.agent-hub.environment's stub
    '';

    lanAddress = lib.mkOption {
      type = lib.types.str;
      description = ''
        LAN address the tenant's ports bind to. Not 0.0.0.0. A host fact,
        set from homelab.host.networks.lan.address in configuration.nix:
        the stub builds AGENT_HUB_LISTEN from it (with `llm.port`, unless
        `llm.landingPage` puts nginx on it and llama-swap on loopback);
        nginx and qdrant bind it directly.
      '';
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/srv/agent-hub";
      description = ''
        Model weights and caches. Large GGUF files live here, never in git.
        The stub sets AGENT_HUB_MODELS = <dataDir>/models, the directory
        llama-swap.yaml's `''${models}` macro names; this file creates it.
      '';
    };

    stateDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/agent-hub";
      description = ''
        Runtime state. <stateDir>/env is the tenant's checked-out flox
        environment (modules/tenant/environment.nix derives the stub's
        `dir` from the tenant's first state dir), so this is also where
        AGENT_HUB_SWAP_CONFIG (<env>/llama-swap.yaml) and AGENT_HUB_ASSETS
        (<env>/nix) point.
      '';
    };

    llm = {
      enable = lib.mkEnableOption ''
        the model server's host side: the landing page (with
        `landingPage`) and the facts below. The unit itself is the stub's
      '';

      port = lib.mkOption {
        type = lib.types.port;
        # A shared-host allocation, not a free choice: assetto reserves the
        # contiguous HTTP block 8081-8096 (8081 + 16 lobby slots), and the
        # tenant's own old default, 8091, sat inside it. 8100 is the first
        # free port past every claim in tenants.nix, which is where the
        # registry checks it.
        default = 8100;
        description = ''
          The LAN port. The stub builds AGENT_HUB_LISTEN from it (see
          `lanAddress`); with `landingPage`, nginx binds it. The firewall
          hole is the contract's, from tenants.nix's `llm` claim.
        '';
      };

      backendPort = lib.mkOption {
        type = lib.types.port;
        default = 18100;
        description = ''
          Where llama-swap's loopback backends start (llama-swap.yaml's
          `startPort`, one port per model upward). Not a LAN allocation, so
          not in the port registry; chosen away from anything else on
          127.0.0.1. The stub passes it as AGENT_HUB_BACKEND_PORT.
        '';
      };

      contextSize = lib.mkOption {
        type = lib.types.int;
        default = 8192;
        description = ''
          KV cache context length for the chat models. The stub passes it
          as AGENT_HUB_CTX (llama-swap.yaml's `ctx` macro; the embedding
          model has its own 8192 there).
        '';
      };

      threads = lib.mkOption {
        type = lib.types.int;
        # A conservative placeholder, never llama.cpp's own auto-detect
        # (which on this box is all 56 threads, starving the race servers).
        # configuration.nix sets it to the physical cores background.slice's
        # fence actually grants -- never the host's total thread count.
        default = 4;
        description = ''
          CPU threads for inference, passed by the stub as
          AGENT_HUB_THREADS (llama-swap.yaml's `threads` macro, every
          backend). Must match the CPU allowance the tenant's tier grants
          this unit (resources.nix's AllowedCPUs fence), not a guess.
        '';
      };

      landingPage = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Multi-model mode only. Put nginx on `lanAddress`:`port` serving
          ./agent-hub/index.html at / -- chat models and image models
          listed apart, each linking to its backend's own UI -- and
          proxying everything else to llama-swap, which then listens on
          127.0.0.1:`port` instead. The stub reads it to decide
          AGENT_HUB_LISTEN (loopback with nginx in front, the LAN address
          without). llama-swap's own /ui stays reachable; it just is not
          the front door, because it lists every model on every playground
          tab. Adds nginx.service to the host; tenants.nix names it in the
          tenant's `units` so it lives in the tenant's slice.
        '';
      };

      models = lib.mkOption {
        default = { };
        description = ''
          The models behind the one port, by name. Two things are live: the
          set being non-empty (the unit's description says how many, and
          TimeoutStopSec gives llama-swap time to stop a backend), and each
          model's `kind` and `description`, from which the landing page's
          models.json is built so index.html can list chat models and image
          models apart. Everything else a model is -- the GGUF, the
          pipeline files, flags, aliases -- is the table's, and the table
          is llama-swap.yaml in the tenant tree. Names here must match the
          names there for the landing page to link to the right backend;
          nothing checks that.
        '';
        type = lib.types.attrsOf (
          lib.types.submodule {
            options = {
              kind = lib.mkOption {
                type = lib.types.enum [
                  "llama"
                  "image"
                  "embedding"
                ];
                default = "llama";
                description = ''
                  "llama": a chat model (llama-server). "image": a
                  diffusion model (stable-diffusion.cpp's sd-server, the
                  same OpenAI images API llama-swap routes). "embedding":
                  /v1/embeddings and nothing else. Read by the landing
                  page, which puts each kind on its own tab.
                '';
              };

              description = lib.mkOption {
                type = lib.types.str;
                default = "";
                description = "Shown beside the model on the landing page. Empty means a per-kind default that says which playground tab the model belongs on. llama-swap.yaml carries the same text for /v1/models.";
              };
            };
          }
        );
      };
    };

    vectors = {
      enable = lib.mkEnableOption ''
        Qdrant beside the model server: the vector store an embedding model
        (llm.models.<name>.kind = "embedding") writes into and agents search.
        nixpkgs' services.qdrant, bound to lanAddress on `port` like the
        model server and nothing wider; gRPC stays off, so one port. Adds
        qdrant.service to the host, with its state in /var/lib/qdrant (the
        module's StateDirectory); tenants.nix names both. Memory is where it
        spends: the HNSW index lives in RAM, the vectors and payloads on disk
      '';

      port = lib.mkOption {
        type = lib.types.port;
        default = 6333;
        description = "Qdrant's HTTP port on lanAddress. Its upstream default; tenants.nix claims it.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups.agent-hub = { };
    users.users.agent-hub = {
      isSystemUser = true;
      group = "agent-hub";
      home = cfg.stateDir;
      createHome = true;
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 agent-hub agent-hub -"
      "d ${cfg.dataDir}/models 0750 agent-hub agent-hub -"
      "d ${cfg.stateDir} 0750 agent-hub agent-hub -"
    ];

    services.nginx = lib.mkIf (cfg.llm.enable && cfg.llm.landingPage) {
      enable = true;
      recommendedProxySettings = true;
      virtualHosts."agent-hub" = {
        listen = [
          {
            addr = cfg.lanAddress;
            port = cfg.llm.port;
          }
        ];
        # The page plus a models.json saying which model is which kind,
        # from the same options the stub's description comes from.
        locations."= /" = {
          root = landingDir;
          tryFiles = "/index.html =404";
        };
        locations."= /models.json" = {
          root = landingDir;
          extraConfig = "default_type application/json;";
        };
        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString cfg.llm.port}";
          proxyWebsockets = true;
          # Answers stream (chat tokens, llama-swap's SSE at /api/events)
          # and take minutes (an image is minutes of CPU; a 32k prompt is
          # minutes of prefill): no buffering, and timeouts that outlast
          # any single request. Image edits upload an image.
          extraConfig = ''
            proxy_buffering off;
            proxy_request_buffering off;
            proxy_read_timeout 3600s;
            proxy_send_timeout 3600s;
            client_max_body_size 64m;
          '';
        };
      };
    };

    services.qdrant = lib.mkIf cfg.vectors.enable {
      enable = true;
      settings.service = {
        host = cfg.lanAddress;
        http_port = cfg.vectors.port;
        # null is how qdrant's own config.yaml spells "no gRPC listener";
        # the NixOS module defaults it to 6334, which would be a second
        # LAN port nothing here speaks.
        grpc_port = null;
      };
      # The module's other defaults stand: state under /var/lib/qdrant,
      # HNSW in RAM, payloads on disk, telemetry off, and qdrant-web-ui at
      # /dashboard on the same port for looking at collections by hand.
    };

    # Binding lanAddress means waiting for it: nixpkgs' unit orders after
    # network.target only, and at boot on 16 Sep 2026 qdrant hit its start
    # limit in 200 ms with "Cannot assign requested address" before
    # NetworkManager had the address up. Every earlier switch had found the
    # address already there. Same two lines the stub's skeleton defaults to.
    systemd.services.qdrant = lib.mkIf cfg.vectors.enable {
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
    };

    assertions = [
      {
        assertion = cfg.llm.landingPage -> multi;
        message = "services.agent-hub.llm.landingPage needs models (multi-model mode); with one model llama-server's own UI is the front door.";
      }
      {
        assertion = cfg.lanAddress != "0.0.0.0";
        message = "services.agent-hub.lanAddress must be the LAN IP, not 0.0.0.0.";
      }
      {
        assertion = cfg.vectors.enable -> cfg.llm.enable;
        message = "services.agent-hub.vectors is the store for llm's embedding model; it makes no sense without llm.enable.";
      }
    ];
  };
}
