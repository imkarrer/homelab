# The Docker daemon, owned by the platform.
#
# THE ONE DELIBERATE MOVE in this extraction: on ac-box today,
# services.ac-host (the AC racing tenant) sets virtualisation.docker.enable
# and virtualisation.docker.autoPrune.enable directly — see
# ac-box:/var/lib/ac-host/src/modules/ac-host.nix. That means the racing
# tenant owns a daemon that it does not exclusively use: CI's Buildkite
# runner, cAdvisor (observability), and the Discord bot (an assetto compose
# profile, but still just a docker consumer) all need `docker.service` up
# regardless of whether the AC lobby stack itself is enabled. Leaving the
# daemon behind in the tenant module means disabling assetto silently takes
# out CI and metrics too.
#
# So the platform owns the daemon here, and enables it the moment ANY tenant
# declares `needsDocker = true` (see modules/tenant/schema.nix). Tenants keep
# asking for Docker; they no longer get to independently decide whether it
# runs.
{ config, lib, ... }:

let
  inherit (lib) any attrValues;

  anyTenantNeedsDocker = any (t: t.enable && t.needsDocker) (attrValues config.homelab.tenants);
in
{
  virtualisation.docker.enable = anyTenantNeedsDocker;
  virtualisation.docker.autoPrune.enable = anyTenantNeedsDocker;
}
