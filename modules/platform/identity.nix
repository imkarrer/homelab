# Human accounts and the base admin toolset. Carried over verbatim from
# ac-box's configuration.nix: same two interactive users, same groups, same
# wheelNeedsPassword, same systemPackages list.
#
# SSH keys: the pre-flake configuration.nix read a host-local
# `ssh-keys.local.nix` next to itself, because public keys are per-box
# operational data, not a secret, but also not something a generic platform
# module should hardcode. We keep that exact convention —
# hosts/<name>/ssh-keys.local.nix — but resolve `<name>` from
# homelab.host.name instead of writing a host's name here, so this module
# stays host-agnostic.
#
# That file is TRACKED, not gitignored. The .gitignore pattern was inherited
# from ac-host and gate 1 proved it wrong here: a flake copies only git-tracked
# files, so the ignored file was absent from the source fetched by revision and
# the `[]` fallback this module then had silently emptied authorizedKeys for
# root, nixosuser and ac. See .gitignore's NOTE and commit daac96f. Do not
# re-ignore it.
#
# A missing file THROWS (homelab-ygc.9), the way each host's hardware import
# in its configuration.nix already does. The `[]` fallback was only ever safe
# while every host's name matched a directory, and a rename is exactly what
# breaks that: measured 28 Sep 2026 on a scratch copy, `name = "llm-box"`
# without the `git mv` of its hosts/ directory evaluated, built
# nixos-system-llm-box-…, and gave root, nixosuser and ac ZERO keys. sshd is
# key-only (ssh.nix), so switching that closure locks every account out and
# the physical console is the only way back. No host is meant to have no
# keys, so there is nothing for a fallback to be right about; an evaluation
# error is the one place that mistake costs nothing.
{ config, lib, pkgs, ... }:

let
  hostDir = ../../hosts + "/${config.homelab.host.name}";
  keysPath = hostDir + "/ssh-keys.local.nix";
  sshKeys =
    if builtins.pathExists keysPath then
      import keysPath
    else
      throw ''
        hosts/${config.homelab.host.name}/ssh-keys.local.nix is missing.

        modules/platform/identity.nix reads root's, nixosuser's and ac's
        authorized keys from hosts/<homelab.host.name>/ssh-keys.local.nix;
        this host's homelab.host.name is "${config.homelab.host.name}".

        Without that file the host would build with ZERO authorized keys, and
        sshd is key-only: switching it would lock every account out, with the
        console the only way back. So this is an error, never an empty list.

        The file is tracked in git. If homelab.host.name was just changed, the
        host's directory moves in the same commit:

          git mv hosts/<old-name> hosts/${config.homelab.host.name}

        If this working tree deleted the file, restore it:

          git checkout -- hosts/${config.homelab.host.name}/ssh-keys.local.nix

        For a NEW host, create it -- a list of public key strings -- and track it.
      '';
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
