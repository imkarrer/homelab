# The one virtualisation option modules/ci reads: virtualisation.docker
# .package, whose CLI ExecStartPre loads the two images with (IMAGES in
# the module's header). NixOS's docker module declares it as
# mkPackageOption pkgs "docker"; this models that and nothing else, the
# way stub-nix.nix models nix.package for environment-pull.nix. Any
# derivation would do for the harness -- it compares the ExecStartPre
# strings against the same package -- but the real one keeps the asserted
# line recognisable in a failure message.
{ lib, pkgs, ... }:
{
  options.virtualisation.docker.package = lib.mkOption {
    type = lib.types.package;
    default = pkgs.docker;
  };
}
