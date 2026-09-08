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
    # repo+task->PR runner. Declared in hosts/ac-box/tenants.nix but not yet
    # enabled there (homelab.tenants.agent-hub.enable = false) -- importing
    # the module here is the no-op half of turning it on; a human still has
    # to flip services.agent-hub.enable, set llm.modelPath, and switch.
    agent-hub = {
      url = "github:imkarrer/agent-hub";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { self, nixpkgs, ac-host, home-arcade, agent-hub }:
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
      };

      nixosConfigurations.ac-box = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          # L1: the contract. Assertions run unconditionally; every effect is
          # gated behind homelab.enforce.*, all of which default false. That is
          # what lets this configuration be a no-op on the first switch.
          ./modules/tenant/schema.nix
          ./modules/tenant/enforce.nix
          ./modules/tenant/ports.nix
          ./modules/tenant/resources.nix
          ./modules/tenant/metrics.nix
          ./modules/tenant/quiet.nix

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

          # L2: shared services that cross tenants. Lifted out of ac-host in
          # phase 8 -- see modules/observability/default.nix for why it lived
          # inside a tenant repo until now.
          ./modules/observability

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
      checks.${system}.ac-box = self.nixosConfigurations.ac-box.config.system.build.toplevel;
    };
}
