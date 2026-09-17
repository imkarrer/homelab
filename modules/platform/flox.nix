# flox on the box (ADR 0009). The one version of flox this hub runs anywhere
# is the `flox` input of flake.nix; this module installs that build and
# tells the nix daemon where to fetch it pre-built.
#
# Why a platform module and not a tenant's concern. ADR 0009 makes a
# tenant's contents a flox environment and keeps a unit stub per tenant in
# the closure whose ExecStart is `flox activate -d <env> -- <command>`
# (modules/tenant/environment.nix). Every such stub needs the same binary,
# and "which flox" is a host fact the ADR's Consequences say must be
# declared once: hub-gates.sh pins it for CI, the CI agent container carries
# it, and the box runs it. flake.nix's `flox` input is that one place; this
# module is the box's reader of it.
#
# THE SUBSTITUTER IS A NEW TRUST DECISION for the platform, stated plainly.
# nix.settings below adds https://cache.flox.dev and its signing key to the
# daemon's configuration: from the first switch that carries this module,
# any path signed by flox's key is accepted into the store without a local
# build, and every miss on cache.nixos.org is also asked of cache.flox.dev.
# The alternative is compiling flox -- a Rust program that bundles its own
# nix -- on the box in the deploy window, which is what happens when the
# key is absent (flox's flake is not in nixpkgs at this closure's pin, and
# its output exists only in flox's cache: flake.nix's input comment has the
# measurement). The same key already lives in this hub's WSL nix.conf and in
# the CI agent container's /etc/nix/flox.conf; the box is the last of the
# three to trust it.
#
# The order: cache.nixos.org first (NixOS's own definition is mkAfter, i.e.
# order 1500), flox's cache after it (1600), so the common case -- a nixpkgs
# path -- never waits on a second cache's miss.
{ config, lib, ... }:

let
  inherit (lib) mkOption types;
in
{
  options.homelab.flox = {
    package = mkOption {
      type = types.package;
      description = ''
        The flox this host runs, and the one every unit stub's ExecStart
        resolves to. flake.nix sets it from the `flox` input; there is no
        default on purpose, because a default that reached for nixpkgs'
        flox (absent at this pin) or for a PATH lookup would be a second,
        silent version of the pin.
      '';
    };
  };

  config = {
    environment.systemPackages = [ config.homelab.flox.package ];

    nix.settings = {
      substituters = lib.mkOrder 1600 [ "https://cache.flox.dev" ];
      trusted-public-keys = [ "flox-cache-public-1:7F4OyH7ZCnFhcze3fJdfyXYLQw/aV7GEed86nQ7IsOs=" ];
    };
  };
}
