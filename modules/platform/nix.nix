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
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 7d";
  };
  nix.optimise.automatic = true;
}
