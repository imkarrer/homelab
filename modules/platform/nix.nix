# Nix daemon and store settings, carried over verbatim from ac-box's
# configuration.nix. trusted-users is left as the literal list ac-box sets
# today (root, nixosuser, ac) rather than derived from modules/platform/identity.nix's
# user set — deriving it would be a behaviour-preserving refactor in spirit,
# but this layer's job is a clean no-op closure diff, not a tidier equivalent.
{ config, lib, ... }:

{
  nixpkgs.config.allowUnfree = true;

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
  nix.settings.trusted-users = [
    "root"
    "nixosuser"
    "ac"
  ];
  nix.settings.auto-optimise-store = true;

  # Every build the daemon runs -- and it runs every build a NON-trusted
  # user asks for, in nix-daemon.service, system.slice, on every core --
  # yields to the box's real work. Belt and braces under ADR 0009: the
  # tenant's pull unit realises its locked paths substitute-only
  # (modules/tenant/environment-pull.nix) precisely so the daemon never
  # compiles a tenant's package on the box; this is the floor if something
  # else asks it to. The deploy unit's own closure build is root, local
  # store, its own Nice=19/idle -- unaffected. Changes nix-daemon.service
  # (CPUSchedulingPolicy=batch, IOSchedulingClass=idle): intended.
  nix.daemonCPUSchedPolicy = "batch";
  nix.daemonIOSchedClass = "idle";
  # ...and the daemon's builds under the batch tier's ceiling, not merely
  # its scheduling class. Everything a non-root client builds -- a tenant
  # user's warm (never a compile by design, but the floor is here), an
  # operator's `nix build` over ssh -- runs in nix-daemon.service's cgroup,
  # and until 18 Sep 2026 that was system.slice: unfenced cores, no memory
  # ceiling, beside the race servers. Root clients (homelab-deploy, the
  # native CI agent with NIX_REMOTE=local) build in their own units and
  # are unaffected. batch.slice exists whenever enforce.slices is on.
  systemd.services.nix-daemon.serviceConfig.Slice =
    lib.mkIf config.homelab.enforce.slices "batch.slice";
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 7d";
  };
  nix.optimise.automatic = true;
}
