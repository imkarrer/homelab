# Human accounts and the base admin toolset. Carried over verbatim from
# ac-box's configuration.nix: same two interactive users, same groups, same
# wheelNeedsPassword, same systemPackages list.
#
# SSH keys: configuration.nix reads a gitignored, host-local
# `ssh-keys.local.nix` next to itself (falling back to `[]`), because public
# keys are per-box operational data, not a secret, but also not something a
# generic platform module should hardcode. We keep that exact convention —
# hosts/<name>/ssh-keys.local.nix, matching the .gitignore pattern that
# already existed for it — but resolve `<name>` from homelab.host.name
# instead of writing "ac-box" here, so this module stays host-agnostic.
{ config, lib, pkgs, ... }:

let
  hostDir = ../../hosts + "/${config.homelab.host.name}";
  keysPath = hostDir + "/ssh-keys.local.nix";
  sshKeys = if builtins.pathExists keysPath then import keysPath else [ ];
in
{
  users.users.nixosuser = {
    isNormalUser = true;
    description = "Primary Server Operator";
    extraGroups = [
      "networkmanager"
      "wheel"
      "docker"
    ];
    openssh.authorizedKeys.keys = sshKeys;
  };

  users.users.ac = {
    isNormalUser = true;
    extraGroups = [
      "wheel"
      "docker"
    ];
    openssh.authorizedKeys.keys = sshKeys;
  };

  users.users.root.openssh.authorizedKeys.keys = sshKeys;

  security.sudo.wheelNeedsPassword = false;

  environment.systemPackages = [
    pkgs.htop
    pkgs.tmux
    pkgs.curl
    pkgs.rsync
    pkgs.git
  ];
}
