{
  description = "Platform layer for the homelab hosts (ac-box, arcade-box): host facts, a tenant contract, and the tenants as environments";

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

    # No agent-hub or home-arcade input since 18 Sep 2026 (homelab-158.11,
    # ADR 0009's end state): those tenants are flox environments, deployed
    # through their own edge (a sha or a FloxHub generation staged by their
    # CI, applied by modules/tenant/environment-pull.nix), and their units
    # are the stubs hosts/ac-box/configuration.nix declares. What the box
    # owes them -- a user, directories, nginx, qdrant, samba, rsyncd -- is
    # hosts/ac-box/tenants/agent-hub.nix and hosts/arcade-box/tenants/arcade.nix. ac-host is the one
    # tenant still composed as an input, and bump-lock is for it alone.

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
    #
    # v1.16.0 (homelab-158.15, 18 Sep 2026): /nix/store/hrrd0sda...-flox-1.16.0-g3ed8295,
    # 109 paths / 378 MB on cache.flox.dev, substituted in 2 s on WSL. Read
    # docs/flox-upgrade-1.16.md before moving this again. One trap from
    # v1.16.0 on: flox's OWN flake spells its substituter
    # "https://cache.flox.dev?priority=50", which an untrusted nix user's
    # trusted-substituters (the bare URL) does not match, so
    # `nix build --accept-flake-config <this pin>` -- what
    # scripts/hub-gates.sh does on WSL -- silently compiles flox unless
    # cache.flox.dev is also passed as --extra-substituters or the WSL
    # nix.conf lists the ?priority=50 spelling. root (the box, CI) is a
    # trusted user and unaffected.
    flox.url = "github:flox/flox/v1.16.0";
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
  #
  # An edit to this block is a PLATFORM change, reviewed like
  # modules/platform/nix.nix. homelab-deploy runs `nix build` as root against
  # the local store, where a trusted user has no filter on which settings a
  # flake may set, and --accept-flake-config applies every setting here --
  # this flake's only, never an input's (verified: flox's own nixConfig is
  # not applied through ours) -- on the box and in CI. A substituter or key
  # added here reaches the store the next time either builds.
  nixConfig = {
    extra-substituters = [ "https://cache.flox.dev" ];
    extra-trusted-public-keys = [ "flox-cache-public-1:7F4OyH7ZCnFhcze3fJdfyXYLQw/aV7GEed86nQ7IsOs=" ];
  };

  outputs =
    { self, nixpkgs, ac-host, sops-nix, flox }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      # Everything both hosts share: the revision stamp, the contract (L1)
      # and the platform (L0) with flox and sops -- in THIS order, the order
      # ac-box had on 25 Sep 2026 as one flat list. List-typed options merge
      # in module order (system-path, imports), so reordering these is a
      # closure change even when the set of modules is not; the split into
      # a shared prefix was proven a no-op for ac-box by its stamp-stripped
      # toplevel drvPath (homelab-ygc.3). A host is this prefix followed by
      # its L2 services, its deploy edge, its tenants and its own files.
      commonModules = [
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
        # Since homelab-158.11 the stub is the whole unit: agent-hub-llm,
        # arcade-freeciv and arcade-mindustry exist in this closure only
        # because hosts/ac-box/configuration.nix declares them under
        # homelab.tenants.<n>.environment.units, and this module renders
        # each from its skeleton fields. Emits nothing for a host that
        # declares no stub.
        ./modules/tenant/environment.nix
        # ADR 0009's deploy edge, applying half: for every tenant with a
        # stub declared, a path/timer-driven unit that checks the staged
        # sha out, activates it once online and restarts the stub under
        # the tenant's quiet policy. Emits nothing for a host without a
        # stub declared; with one declared and enable = false it adds the
        # pull units and /etc/homelab/environments.json and touches no
        # other unit (homelab-158.3's drvPath proof).
        ./modules/tenant/environment-pull.nix

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
        # sops and modules/platform/secrets.nix are NOT here: they are per host
        # since the cutover (ADR 0010). arcade-box holds every secret the six
        # tenants declare; the Z840 runs agent-hub alone and needs none, and
        # secrets.nix reads options of modules the Z840 no longer imports
        # (homelab.ci.envFile, services.ac-host.enable).
      ];
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
        modules = commonModules ++ [
          # ADR 0010, the cutover (docs/runbook-arcade-box-cutover.md 4.2): the
          # Z840 is llm-box in everything but name. What left with the lobbies,
          # the arcade, observability and ci: modules/observability, modules/ci,
          # sops + modules/platform/secrets.nix, the ac-host input and the arcade
          # host-side file -- all on arcade-box now. Docker leaves with them (no
          # tenant here declares needsDocker). modules/deploy stays and idles: the
          # CI agent that stages a closure writes on the host it runs on, which is
          # arcade-box, so this host is switched by hand from now on (ADR 0010,
          # "no machinery"); the rename to llm-box is homelab-ygc.9.
          ./modules/deploy

          # L3: the one tenant. agent-hub is a flox environment (ADR 0009); its
          # unit is the stub hosts/ac-box/configuration.nix declares, rendered by
          # modules/tenant/environment.nix, and what the host owes it -- identity,
          # directories, nginx, qdrant -- is the file below.
          ./hosts/ac-box/tenants/agent-hub.nix

          # This host.
          ./hosts/ac-box/host.nix
          ./hosts/ac-box/tenants.nix
          ./hosts/ac-box/configuration.nix
        ];
      };

      # arcade-box (ADR 0010, docs/runbook-arcade-box-cutover.md): the Lenovo
      # M920q that takes every tenant but agent-hub off ac-box. The same
      # prefix, the same L2 services and deploy edge, the same ac-host input
      # and the same arcade host-side file (it moved here from hosts/ac-box/
      # tenants/ and ac-box imports it from its new place until the cutover
      # drops it) -- and no agent-hub. Which of its tenants are live today is
      # hosts/arcade-box/configuration.nix to say (its BUILD-UP markers, all ON
      # since the cutover, runbook 4.2).
      nixosConfigurations.arcade-box = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = commonModules ++ [
          # The secrets: every one the tenants declare lives here since the cutover.
          sops-nix.nixosModules.sops
          ./modules/platform/secrets.nix
          ./modules/observability
          ./modules/ci
          ./modules/deploy
          ac-host.nixosModules.ac-host
          ./hosts/arcade-box/tenants/arcade.nix
          ./hosts/arcade-box/host.nix
          ./hosts/arcade-box/tenants.nix
          ./hosts/arcade-box/configuration.nix
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
        arcade-box = self.nixosConfigurations.arcade-box.config.system.build.toplevel;
      }
      // (import ./modules/tenant/tests/check.nix {
        inherit pkgs;
        lib = nixpkgs.lib;
      }).checks;
    };
}
