# Bootloader, boot-time/system hygiene, and the GPU driver stack — carried
# over verbatim from ac-box's configuration.nix. journald's caps land here
# too: none of the six platform modules is a natural fit for log retention,
# and it's the same kind of general system housekeeping as boot.tmp.cleanOnBoot.
#
# hardware-configuration.nix is NOT imported here. It was tempting to resolve
# hosts/<homelab.host.name>/hardware-configuration.nix dynamically so this
# module stayed host-agnostic, but NixOS's module system cannot make
# `imports` depend on `config` — every module's `imports` list has to be
# known before the config fixed point exists, so referencing
# `config.homelab.host.name` there is a genuine infinite recursion, not a
# style nit (confirmed: `nix eval` on this exact pattern fails with
# "infinite recursion encountered ... if you reference config in imports").
# ac-host's own configuration.nix sidesteps this by hardcoding the import at
# its own top level, next to the file. The same thing lives in this repo's
# per-host composition, hosts/ac-box/configuration.nix, which already knows its
# own host name and imports
#   hosts/ac-box/hardware-configuration.nix   (fetched read-only, TRACKED)
# — tracked, not gitignored, because a flake copies only git-tracked files into
# the store; see .gitignore's NOTE. It does NOT fall back to
# hosts/ac-box/hardware-configuration.nix.example the way ac-host's does: that
# fallback is silent, and a silent substitution of a stub that will not boot a
# real machine is what gate 1 caught. A missing hardware file throws there.
#
# hardware.graphics / hardware.nvidia are gated on homelab.host.gpu rather
# than left unconditional, so a future non-nvidia host doesn't inherit a
# driver stack it doesn't have. For ac-box, gpu = "nvidia", so the effective
# config is identical to what configuration.nix sets unconditionally today.
{ config, lib, pkgs, ... }:

let
  cfg = config.homelab.host;
in
{
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 5;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.tmp.cleanOnBoot = true;

  services.journald.extraConfig = ''
    SystemMaxUse=200M
    MaxRetentionSec=14day
  '';

  hardware.graphics.enable = lib.mkIf (cfg.gpu == "nvidia") true;
  services.xserver.videoDrivers = lib.mkIf (cfg.gpu == "nvidia") [ "nvidia" ];
  hardware.nvidia = lib.mkIf (cfg.gpu == "nvidia") {
    modesetting.enable = true;
    powerManagement.enable = true;
    open = false;
    package = config.boot.kernelPackages.nvidiaPackages.stable;
  };
}
