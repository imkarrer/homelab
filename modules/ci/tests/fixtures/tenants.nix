# The `ci` tenant as hosts/ac-box/tenants.nix declares it, for the ci
# harness: the same conditional `units` (the two new stub names join the
# list only with native on -- a stub outside `units` is environment.nix's
# refusal, and an unconditional list would change the inventory with
# native off), the same port claims the module's minio addresses must
# match, the same tier. Kept in step with the host's entry by hand.
{ config, lib, ... }:
{
  homelab.tenants.ci = {
    description = "Self-hosted Buildkite agent (Flox sandbox) with a loopback MinIO Nix binary cache.";
    tier = "batch";
    units = [
      "ac-host-ci.service"
    ]
    ++ lib.optionals config.homelab.ci.native.enable [
      "ac-host-ci-minio.service"
      "ac-host-ci-minio-init.service"
    ];
    ports = {
      minio-api = {
        number = 9000;
        proto = [ "tcp" ];
        scope = "local";
      };
      minio-console = {
        number = 9001;
        proto = [ "tcp" ];
        scope = "local";
      };
    };
    needsDocker = true;
    metrics = null;
  };
}
