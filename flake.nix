{
  description = "Platform layer for ac-box: host facts, a tenant contract, and the tenants as inputs";

  inputs = {
    # This repo owns nixpkgs, and a tenant must not drag its own copy into the
    # closure -- hence the follows below.
    #
    # Pinned to the EXACT revision ac-box is running, not to the nixos-26.05
    # branch. `nixos-version --json` on the box reports
    # nixpkgsRevision c5c4a43b0e8056328ec4529f735cabdb8f1942bb; tracking the
    # branch instead resolved six days newer and renamed the system derivation
    # from ...20260829.c5c4a43 to ...20260906.c257840, which would have made
    # phase 1's diff-closures show hundreds of unrelated package differences and
    # buried any real one. Advancing this pin is a deliberate, separate change
    # with its own window -- never a side effect of composing.
    nixpkgs.url = "github:NixOS/nixpkgs/c5c4a43b0e8056328ec4529f735cabdb8f1942bb";

    # The Assetto Corsa tenant, and (for now) the observability stack, which
    # still lives inside that repo. Lifting monitoring to L2 is a later phase;
    # phase 1 consumes it unchanged so the closure stays identical.
    ac-host = {
      url = "github:imkarrer/ac-host";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # The arcade tenant. Module-only flake with no inputs of its own, so there
    # is nothing to make follow.
    home-arcade.url = "github:imkarrer/home-arcade";

    # The local coding-agent tenant: llama.cpp model serving plus a sandboxed
    # repo+task->PR runner. Declared in hosts/ac-box/tenants.nix and ON since
    # 45f67ab (llm only; the runner waits on a sops-backed githubTokenFile).
    # Live on ac-box since generation 31, 12 Sep 2026: llama-server on
    # 192.168.1.50:8100, alone in background.slice.
    agent-hub = {
      url = "github:imkarrer/agent-hub";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Secrets. README has said "credentials go to sops-nix" since the repo
    # began; as of 12 Sep 2026 one does (arcade's SMB password, the proof),
    # and the rest are hand-placed files whose NAMES the tenants declare in
    # homelab.tenants.<name>.secrets. See modules/platform/secrets.nix for
    # the key model -- no new key material anywhere: the box decrypts with
    # its ssh host key, the operator with theirs.
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # flox, at ONE version for dev, CI and the box (ADR 0009, question 6).
    # This tag is the version; flake.lock pins its rev, and that lock node is
    # what scripts/hub-gates.sh builds to reproduce CI's environment locally
    # and what modules/platform/flox.nix installs on ac-box. The CI agent
    # container carries its own flox (1.14.0 today, from ac-host's compose
    # file) and must agree with this tag by hand until that container is
    # itself built from this pin.
    #
    # Deliberately NOT `inputs.nixpkgs.follows = "nixpkgs"`, and this is the
    # one input in this file that breaks that rule. The rule exists so a
    # TENANT cannot drag its own nixpkgs into the closure; flox is not a
    # tenant, its nixpkgs (github:flox/nixpkgs/stable) builds exactly one
    # package -- flox itself, ~380 MB with its bundled nix -- and nothing of
    # it enters the module composition. Measured 17 Sep 2026 before deciding:
    #
    #   as pinned      /nix/store/rq6g47dw...-flox-1.14.0-gfbdabf6  in cache.flox.dev
    #   with follows   /nix/store/3fcakfrz...-flox-1.14.0           in no cache
    #
    # Following would mean compiling a Rust program and a second nix on the
    # box in the deploy window, every time this pin moves. The cost of not
    # following is the lock carrying flox's inputs (crane, fenix, its
    # nixpkgs) and the closure carrying a second glibc/nix -- accepted.
    flox.url = "github:flox/flox/v1.14.0";
  };

  # flox's own flake declares these same two settings, and hub-gates.sh
  # passes --accept-flake-config for them. Repeated here so a build of THIS
  # flake can substitute flox too: the first closure to carry it is built by
  # CI's agent (its own /nix, where cache.flox.dev is trusted but not a
  # default substituter) and then by homelab-deploy on the box under the
  # nix.conf of the closure BEFORE this one -- the one without
  # modules/platform/flox.nix's substituter. Both run as root, so
  # `--accept-flake-config` is enough there; an untrusted user (WSL) gets a
  # warning and cache.nixos.org, which is what it had. Once the switch has
  # happened the box's nix.conf carries the substituter permanently and this
  # block is redundant on the box.
  nixConfig = {
    extra-substituters = [ "https://cache.flox.dev" ];
    extra-trusted-public-keys = [ "flox-cache-public-1:7F4OyH7ZCnFhcze3fJdfyXYLQw/aV7GEed86nQ7IsOs=" ];
  };

  outputs =
    { self, nixpkgs, ac-host, home-arcade, agent-hub, sops-nix, flox }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      # The contract and the platform, offered separately so another host can
      # take the layer without taking ac-box's tenants.
      nixosModules = {
        tenantContract = ./modules/tenant;
        platform = ./modules/platform;
        # L2, exported so a second host can take the shared services without
        # taking ac-box's tenants. observability was lifted out of a tenant
        # repo precisely to be shareable; leaving it consumable only as an
        # inline path in the module list below was that job half-done
        # (docs/current-state.md F4).
        observability = ./modules/observability;
        ci = ./modules/ci;
        deploy = ./modules/deploy;
      };

      nixosConfigurations.ac-box = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          # Stamp the closure with the git revision that built it, so the
          # running system is self-identifying: `nixos-version
          # --configuration-revision` on the box answers "which commit is
          # this?" exactly, with no evaluation and no heuristic.
          #
          # Why now. On 12 Sep 2026 a `nixos-rebuild switch --flake
          # github:imkarrer/homelab#ac-box` resolved to a rev nix had CACHED
          # an hour earlier (tarball-ttl = 3600), built the identical closure,
          # and applied a no-op while reporting success and refreshing the
          # generation timestamp. hub-status.sh's timestamp heuristic read
          # that as "consistent with current". A stamped revision would have
          # said c97cbbe against HEAD 0f87e07 instantly. It prefers this
          # stamp when present; this is what makes that branch live.
          #
          # The cost, and how it is paid. Every commit now yields a different
          # toplevel store path, which retires "compare drvPath before/after"
          # as a proof that an import is a no-op -- the technique this file's
          # own comments cite three times. The proof survives with one
          # override on both sides:
          #
          #   (nixosConfigurations.ac-box.extendModules {
          #     modules = [ { system.configurationRevision = lib.mkForce null; } ];
          #   }).config.system.build.toplevel.drvPath
          #
          # That strips the stamp and compares what is left, which is what
          # the technique was always actually comparing.
          #
          # `self.rev` exists only for a clean tree; `dirtyRev` carries the
          # base rev plus "-dirty" so a switch from an uncommitted checkout is
          # labelled as one rather than passing as its base commit.
          { system.configurationRevision = self.rev or self.dirtyRev or "unknown"; }

          # L1: the contract. Assertions run unconditionally; every effect is
          # gated behind homelab.enforce.*, all of which default false. That is
          # what lets this configuration be a no-op on the first switch.
          ./modules/tenant/schema.nix
          ./modules/tenant/enforce.nix
          ./modules/tenant/ports.nix
          ./modules/tenant/resources.nix
          ./modules/tenant/metrics.nix
          ./modules/tenant/quiet.nix
          # ADR 0009: the unit stub for a tenant that is a flox environment.
          # Inert until a tenant sets environment.enable (none does yet);
          # proven a no-op on import by an unchanged toplevel drvPath.
          ./modules/tenant/environment.nix

          # L0: the platform. Reproduces what ac-box already runs, deliberately
          # without improving it.
          #
          # Phase 7: platform/docker.nix is now imported, so the daemon is owned
          # here rather than by the racing tenant. ac-host.nix still sets
          # virtualisation.docker.enable = true itself, and that is fine rather
          # than a conflict: NixOS merges two definitions of the same bool
          # silently when they AGREE, and both evaluate true while assetto
          # declares needsDocker. Verified experimentally before relying on it.
          #
          # It stops being fine the moment they disagree -- if assetto were ever
          # disabled, or its needsDocker cleared, this becomes a hard eval error
          # rather than a silent divergence. Removing the line from ac-host.nix is
          # the cleanup that closes that window; it is not required for the daemon
          # to change hands.
          ./modules/platform/docker.nix
          ./modules/platform/host-options.nix
          ./modules/platform/network.nix
          ./modules/platform/identity.nix
          ./modules/platform/nix.nix
          ./modules/platform/ssh.nix
          ./modules/platform/boot.nix
          # flox on the box, at the version the flox input pins -- one pin for
          # dev (hub-gates.sh reads the same lock node), CI and the box. The
          # module declares the option; the package is handed in here because
          # this is the only place the flake input is in scope.
          ./modules/platform/flox.nix
          { homelab.flox.package = flox.packages.${system}.flox; }
          sops-nix.nixosModules.sops
          ./modules/platform/secrets.nix

          # L2: shared services that cross tenants. Lifted out of ac-host in
          # phase 8 -- see modules/observability/default.nix for why it lived
          # inside a tenant repo until now.
          ./modules/observability

          # modules/ci: the Buildkite agent + MinIO cache under systemd.
          # Imported inert in f461509 (proven by unchanged toplevel drvPath),
          # enabled in 4257aea, and LIVE since generation 31, 12 Sep 2026,
          # after a human ran the module header's HAZARD 1 adoption sequence
          # from a plain SSH session. HAZARD 2 stands permanently: a
          # nixos-rebuild that bounces this unit can never be shipped as a
          # step run BY the Buildkite agent this unit is -- which is why the
          # closure's deploy path is a systemd unit (modules/deploy) and not a
          # pipeline step.
          ./modules/ci

          # modules/deploy: imported but inert (ADR 0006's applying half).
          # homelab.deploy.enable defaults false and nothing sets it, so this
          # contributes nothing to the composed config -- same discipline, and
          # same proof, as modules/ci above and agent-hub below.
          #
          # Flipping it makes ac-box self-switching, which is ADR 0006's
          # deliberate choice and NOT a side effect of importing the module.
          # Do not flip it from an agent-authored change: the module's header
          # documents the gate it is waiting on (every tree reaching the box
          # needs a real evaluation gate, and agent-hub's composed eval is
          # still thin because its enable flag defaults false), and it must
          # not go true before the CI adoption sequence has been run by a
          # human -- the same ordering modules/ci's HAZARD 1 describes.
          ./modules/deploy

          # L3: the tenants, as inputs rather than vendored copies. arcade-hub
          # comes from home-arcade's canonical module -- not the drifted,
          # mojibake copy that used to live in the ac-host tree.
          ac-host.nixosModules.ac-host
          home-arcade.nixosModules.arcade-hub

          # agent-hub: imported but inert. services.agent-hub.enable defaults
          # false (mkEnableOption) and nothing below sets it, so this
          # contributes nothing to the composed config yet -- verified by
          # comparing nixosConfigurations.ac-box's toplevel store path
          # before/after this line was added. Turning the tenant on is a
          # separate, later change: flip services.agent-hub.enable (and
          # .llm.enable) in hosts/ac-box/configuration.nix with a real
          # llm.modelPath, matching how services.ac-host/arcade-hub are
          # wired just below.
          agent-hub.nixosModules.agent-hub

          # This host.
          ./hosts/ac-box/host.nix
          ./hosts/ac-box/tenants.nix
          ./hosts/ac-box/configuration.nix
        ];
      };

      formatter.${system} = pkgs.nixfmt-rfc-style;

      packages.${system}.boxctl = pkgs.callPackage ./pkgs/boxctl { };

      # `nix flake check` evaluates the host configuration, which is the cheap
      # gate that catches a port collision or a budget overrun before anyone
      # opens a maintenance window.
      #
      # It cannot, on its own, prove the contract still REJECTS a bad config:
      # ac-box has no collision and no overrun to reject. That proof is the
      # eval harnesses (modules/*/tests/eval*.nix), which since 12 Sep 2026
      # are checks here too -- one derivation per harness, evaluated against
      # this flake's own nixpkgs rather than a re-read of flake.lock. Each is
      # eval-only (seconds, not the toplevel's minutes): the verdicts are
      # computed while `nix flake check` evaluates and the build merely
      # records them. modules/tenant/tests/check.nix owns the inversion that
      # lets a fixture expected to THROW be a check that must SUCCEED, and
      # discovers the harnesses by the same eval*.nix glob the runner used to
      # walk. run-eval-tests.sh is now a front-end that builds these same
      # checks and prints their per-case reports.
      checks.${system} = {
        ac-box = self.nixosConfigurations.ac-box.config.system.build.toplevel;
      }
      // (import ./modules/tenant/tests/check.nix {
        inherit pkgs;
        lib = nixpkgs.lib;
      }).checks;
    };
}
