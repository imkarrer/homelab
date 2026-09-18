# arcade on ac-box: everything the tenant's NixOS module used to contribute
# that is NOT a game server's unit -- the arcade user and group, the library
# and state directories, the SMB and rsync exports of /srv/arcade and the
# unit that keeps the Samba password -- plus the host facts
# hosts/ac-box/configuration.nix reads to fill the two unit stubs
# (homelab.tenants.arcade.environment).
#
# Moved here from home-arcade's modules/arcade-hub.nix on 18 Sep 2026
# (homelab-158.11), verbatim where it is not dead, when that module left the
# closure: ADR 0009's end state is that a tenant author writes no Nix, so
# what a tenant needs from the HOST -- an identity, directories, a file
# share from nixpkgs -- is the host composition's to say. The units
# themselves (arcade-freeciv.service, arcade-mindustry.service) are the
# stubs' whole, rendered by modules/tenant/environment.nix from
# configuration.nix's declaration; nothing here declares them. Proven
# byte-identical on the move: every unit, user, tmpfiles rule and firewall
# port compared equal between the closure with the module and this one.
#
# Kept as an option set under the module's old name, services.arcade-hub,
# because that is what configuration.nix already sets and reads
# (lanAddress, stateDir, freeciv.port, mindustry.port/map/mode) -- one
# spelling per value, so the stubs and the exports cannot drift. Host-local:
# imported by hosts/ac-box only.
#
# Gone with the move, because nothing reads them: freeciv.enable and
# mindustry.enable (declaring the stub is the enable now), the
# lobby/mitm/minetest/mumble port options (never enabled; they only fed the
# module's firewall block), freeciv.announcePort and mindustry.multicastPort
# (the same block; the contract claims 4555 and 20151 in tenants.nix, with
# the history of each), and the module's whole firewall block -- every port
# in it is a claim in tenants.nix, which modules/tenant/ports.nix opens on
# the LAN interface, and the module's copy was a duplicate the firewall's
# port canonicalisation folded away.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.arcade-hub;
in
{
  options.services.arcade-hub = {
    enable = lib.mkEnableOption ''
      the arcade tenant's host side: the arcade user, /srv/arcade and
      /var/lib/arcade, the LAN SMB and rsync exports. The game servers'
      units are homelab.tenants.arcade.environment's stubs. Touches neither
      Docker nor the Assetto Corsa lobby stack
    '';

    lanAddress = lib.mkOption {
      type = lib.types.str;
      description = ''
        Game/LAN address arcade services bind to. Not 0.0.0.0. A host
        fact, set from homelab.host.networks.lan.address in
        configuration.nix: the arcade-freeciv stub passes it as `--bind`,
        and the samba/rsync export below binds it. The environment carries
        no LAN address (home-arcade's manifest header); this option is
        where the box's reaches the server.
      '';
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/srv/arcade";
      description = "Library: roms, metadata, shaders, saves. Never AC content.";
    };

    stateDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/arcade";
      description = ''
        Hub state: saves, the Samba secret, the environment. Not
        /var/lib/ac-host. The stubs read it: arcade-freeciv's `--saves
        <stateDir>/freeciv --log <stateDir>/freeciv/server.log`, and both
        units' WorkingDirectory (Mindustry writes config/ under its cwd,
        <stateDir>/mindustry). The flox environment lives under it too, at
        <stateDir>/env, which the pull unit creates.
      '';
    };

    rsync.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Optional rsyncd. Windows spokes use SMB; Nix stations can still rsync.";
    };

    smb.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "LAN SMB share of /srv/arcade. Windows spokes robocopy this; no WSL.";
    };

    freeciv.port = lib.mkOption {
      type = lib.types.port;
      default = 5556;
      description = ''
        TCP game port, passed by the arcade-freeciv stub as `--port`. The
        firewall hole is the contract's, from tenants.nix's `freeciv`
        claim; the server's UDP LAN-announce socket is a different port
        (4555, the `freeciv-announce` claim there).
      '';
    };

    mindustry.port = lib.mkOption {
      type = lib.types.port;
      default = 6567;
      description = ''
        Port the server listens on, fed by the arcade-mindustry stub as
        its `config port` console line (the unit's stdin). It has to be
        sent: the server otherwise sits on its built-in 6567, so before
        the console line existed changing this option silently did nothing
        to the service. The firewall hole is the contract's (tenants.nix's
        `mindustry` claim, and `mindustry-multicast` for the discovery
        socket on 20151, a compile-time constant of the server).
      '';
    };

    mindustry.map = lib.mkOption {
      type = lib.types.str;
      default = "Islands";
      description = ''
        Built-in map to host, the first word of the stub's `host <map>
        <mode>` console line. The server's own help reads `host [mapname]
        [mode]`, so the first argument is a MAP, not a mode -- which is why
        "host sandbox" failed with "No map with name 'sandbox' found" and
        the server sat loaded but never opened a port.

        Valid built-in names come from the server's `maps all` command and are
        underscore-separated: Ancient_Caldera, Archipelago, Debris_Field,
        Domain, Fork, Fortress, Glacier, Islands, Labyrinth, Maze, Molten_Lake,
        Mud_Flats, Passage, Shattered, Tendrils, Triad, Veins, Wasteland.
        Custom maps would live in ${"\${stateDir}"}/mindustry/config/maps, which is empty.
      '';
    };

    mindustry.mode = lib.mkOption {
      type = lib.types.enum [
        "survival"
        "sandbox"
        "attack"
        "pvp"
      ];
      default = "sandbox";
      description = ''
        Gamemode, the second word of the stub's `host <map> <mode>` line.
        sandbox has no enemy waves, which is the point for the kids' arcade
        -- survival (the server's default when nothing is specified) attacks
        them.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups.arcade = { };
    users.users.arcade = {
      isSystemUser = true;
      group = "arcade";
      home = cfg.stateDir;
      createHome = true;
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0755 arcade arcade -"
      "d ${cfg.dataDir}/roms 0755 arcade arcade -"
      "d ${cfg.dataDir}/roms/snes 0755 arcade arcade -"
      "d ${cfg.dataDir}/roms/n64 0755 arcade arcade -"
      "d ${cfg.dataDir}/roms/genesis 0755 arcade arcade -"
      "d ${cfg.dataDir}/roms/dos 0755 arcade arcade -"
      "d ${cfg.dataDir}/metadata 0755 arcade arcade -"
      "d ${cfg.dataDir}/metadata/crops 0755 arcade arcade -"
      "d ${cfg.dataDir}/shaders 0755 arcade arcade -"
      "d ${cfg.dataDir}/saves 0775 arcade arcade -"
      "d ${cfg.stateDir} 0750 arcade arcade -"
      "d ${cfg.stateDir}/secrets 0700 arcade arcade -"
      "d ${cfg.stateDir}/freeciv 0750 arcade arcade -"
      "d ${cfg.stateDir}/mindustry 0750 arcade arcade -"
      "d ${cfg.dataDir}/apps 0755 arcade arcade -"
      "d ${cfg.dataDir}/apps/windows 0755 arcade arcade -"
    ];

    services.samba = lib.mkIf cfg.smb.enable {
      enable = true;
      openFirewall = false;
      nmbd.enable = false;
      settings = {
        global = {
          "workgroup" = "WORKGROUP";
          "server string" = "arcade";
          "interfaces" = "${cfg.lanAddress}/24";
          "bind interfaces only" = "yes";
          "security" = "user";
          "map to guest" = "Bad User";
          "guest account" = "arcade";
          "hosts allow" = "192.168.1. 127.0.0.1";
          "hosts deny" = "0.0.0.0/0";
        };
        arcade = {
          path = cfg.dataDir;
          "browseable" = "yes";
          "read only" = "yes";
          "guest ok" = "yes";
          "force user" = "arcade";
          "force group" = "arcade";
        };
      };
    };

    # Win10/11 Pro refuse guest SMB. Keep a real samba user; password lives
    # only in /var/lib/arcade/secrets/smb-password (not in git).
    systemd.services.arcade-smb-password = lib.mkIf cfg.smb.enable {
      description = "Ensure Samba password for arcade user";
      after = [ "samba-smbd.service" ];
      wants = [ "samba-smbd.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [
        pkgs.samba
        pkgs.openssl
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail
        secret=${cfg.stateDir}/secrets/smb-password
        umask 077
        mkdir -p ${cfg.stateDir}/secrets
        [ -s "$secret" ] || openssl rand -hex 8 > "$secret"
        chown arcade:arcade "$secret"
        chmod 600 "$secret"
        pass=$(tr -d '\n' < "$secret")
        printf '%s\n%s\n' "$pass" "$pass" | smbpasswd -a -s arcade
      '';
    };

    services.rsyncd = lib.mkIf cfg.rsync.enable {
      enable = true;
      socketActivated = false;
      settings = {
        globalSection = {
          address = cfg.lanAddress;
          "use chroot" = true;
          "max connections" = 8;
        };
        sections = {
          arcade-lib = {
            path = cfg.dataDir;
            comment = "Arcade library (read-only: roms, metadata, shaders)";
            "read only" = true;
            uid = "arcade";
            gid = "arcade";
          };
          arcade-saves = {
            path = "${cfg.dataDir}/saves";
            comment = "Arcade profile saves (read-write)";
            "read only" = false;
            uid = "arcade";
            gid = "arcade";
          };
        };
      };
    };

    # rsyncd binds cfg.lanAddress, so like every other LAN-bound unit here
    # it must wait for that address to EXIST -- and nixpkgs' rsyncd module
    # orders only after network.target, which is satisfied before DHCP has
    # handed out anything. The two stubs carry this pair by default
    # (schema.nix's `after`/`wants`); rsyncd was the one LAN-bound unit
    # without it, because it comes from a nixpkgs module.
    #
    # Found on ac-box's first reboot in a week, 12 Sep 2026: rsyncd started at
    # 12:37:34 and died with "bind() failed: Cannot assign requested address",
    # while samba-smbd -- same address, but nixpkgs' samba module orders after
    # network-online.target -- started six seconds later and was fine. On the
    # previous boot (5 Sep) rsyncd's first start was an hour after boot, from a
    # nixos-rebuild switch, so this had never actually been tested at boot.
    #
    # The unit is `rsync.service`, not rsyncd -- nixpkgs names it that way and
    # carries rsyncd.service only as an alias.
    systemd.services.rsync = lib.mkIf cfg.rsync.enable {
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      # Second layer, independent of the first. The ordering above fixes the
      # cause; this fixes the consequence if the cause ever recurs in a form
      # ordering does not catch. nixpkgs' rsyncd.nix sets `RestartSec = 1`
      # and NO `Restart=` -- a retry delay for a retry that never happens --
      # so a failed bind left the unit dead until a human noticed, which on
      # 12 Sep 2026 was the operator reading Grafana. Two arcade stations
      # (192.168.1.146, 192.168.1.21) pull the ROM library over this; the
      # export being down is a kid's machine failing to sync, not a log line.
      #
      # Only Restart= is set here. RestartSec is inherited from upstream's 1s
      # rather than overridden: with the ordering fix the address exists
      # before the first start, so this is belt-and-braces, and a plain
      # `RestartSec = 5` here is a conflicting definition against upstream's
      # value (hub-gates caught exactly that). Fighting nixpkgs over a number
      # that no longer matters is not worth a mkForce.
      serviceConfig.Restart = "on-failure";
    };

    assertions = [
      {
        assertion = cfg.lanAddress != "0.0.0.0";
        message = "services.arcade-hub.lanAddress must be the LAN IP, not 0.0.0.0.";
      }
    ];
  };
}
