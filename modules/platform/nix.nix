# Nix daemon and store settings, carried over verbatim from ac-box's
# configuration.nix. trusted-users is left as the literal list ac-box sets
# today (root, nixosuser, ac) rather than derived from modules/platform/identity.nix's
# user set — deriving it would be a behaviour-preserving refactor in spirit,
# but this layer's job is a clean no-op closure diff, not a tidier equivalent.
{ ... }:

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
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 7d";
  };
  nix.optimise.automatic = true;
}
