# arcade on arcade-box: everything the tenant's NixOS module used to contribute
# that is NOT a game server's unit -- the arcade user and group, the library
# and state directories, the SMB and rsync exports of /srv/arcade and the
# unit that keeps the Samba password -- plus the host facts
# hosts/arcade-box/configuration.nix reads to fill the two unit stubs
# (homelab.tenants.arcade.environment).
# Since 1 Oct 2026 also one thing that module never had: arcade-library-sync,
# which copies home-arcade main's station files into /srv/arcade
# (homelab-786).
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
# imported by hosts/arcade-box only.
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

  # arcade-library-sync's tick; the unit's comment below says why it is
  # shaped this way.
  librarySyncScript = pkgs.writeShellApplication {
    name = "arcade-library-sync";
    runtimeInputs = [
      pkgs.git
      pkgs.rsync
      pkgs.coreutils
    ];
    text = ''
      remote=${lib.escapeShellArg cfg.librarySync.remote}
      clone=${lib.escapeShellArg "${toString cfg.stateDir}/home-arcade"}
      library=${lib.escapeShellArg (toString cfg.dataDir)}
      # The station files, and the only paths under the library this writes.
      dirs=(catalog www metadata shaders windows)

      log() { echo "arcade-library-sync: $*"; }
      retry() { log "$*; retrying next tick."; exit 0; }
      refuse() { log "$*" >&2; exit 1; }
      git_noprompt() { git -c credential.helper= "$@"; }

      if [ ! -d "$library" ] || [ ! -w "$library" ]; then
        refuse "$library is not a writable directory here -- nowhere to copy into."
      fi

      if [ ! -d "$clone/.git" ]; then
        if [ -e "$clone" ]; then
          refuse "$clone exists and is not a git checkout -- refusing to overwrite it."
        fi
        git_noprompt clone --quiet --single-branch --branch main --no-checkout "$remote" "$clone" \
          || retry "could not clone $remote (git exit $?)"
      fi
      git -C "$clone" remote set-url origin "$remote"
      git_noprompt -C "$clone" fetch --quiet origin +refs/heads/main:refs/remotes/origin/main \
        || retry "could not fetch main from $remote (git exit $?)"
      git -C "$clone" reset --quiet --hard origin/main
      git -C "$clone" clean --quiet -ffdx
      sha=$(git -C "$clone" rev-parse HEAD)

      for d in "''${dirs[@]}"; do
        if [ ! -d "$clone/$d" ]; then
          log "main $sha has no $d/; leaving $library/$d as it is."
          continue
        fi
        # -rlt: contents, symlinks as symlinks (--safe-links drops any that
        # point outside the tree), mtimes. No --delete: see the unit.
        changed=$(rsync -rlt --safe-links --out-format='%n' "$clone/$d/" "$library/$d/")
        if [ -n "$changed" ]; then
          log "$d/ from main $sha: $(tr '\n' ' ' <<<"$changed")"
        fi
      done
    '';
  };
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

    librarySync.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        arcade-library-sync: keep the station files in dataDir (the five
        directories named in the unit below) in step with home-arcade's
        `main`, from a private clone under stateDir, every ten minutes.
      '';
    };

    librarySync.remote = lib.mkOption {
      type = lib.types.str;
      default = "https://github.com/imkarrer/home-arcade";
      description = ''
        Where the clone fetches from: hub/repos.psv's home-arcade remote over
        anonymous https. The repository is public, so the box holds no key
        or token for it, as for every other read it makes of a public
        remote.
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

    # The station files' deploy edge (homelab-786, 1 Oct 2026). Stations
    # robocopy this share (home-arcade windows/sync.ps1) and, since
    # home-arcade arc-0qy/arc-df4, install their launcher scripts from
    # ${dataDir}/windows/ every time Home Arcade opens -- so a home-arcade
    # change reaches a kid only once it is HERE, and until this unit nothing
    # put it here: catalog/games.json was still the 6 Sep copy on 1 Oct.
    # home-arcade's CI promises never to touch the share (arc-2g0), which
    # is why the edge is the host's. The flox environment's edge
    # (arcade-environment-pull) carries the game servers, not these files.
    #
    # One tick: fetch main into a private clone under stateDir and make the
    # checkout exactly main (reset --hard, clean -ffdx: nothing writes there
    # but this unit), then `rsync -rlt` each of the five directories into
    # dataDir. Every merge to main is copied, green or not: home-arcade's
    # bead-loop merges only on green, so main is the green line, and the
    # commit status the environment poll reads is unobserved for this tree
    # (docs/architecture.md row 35).
    #
    # NO --delete, on purpose. The five directories hold files that are not
    # in git -- on 1 Oct catalog/games.json's GoldenEye entry was a
    # hand-edit (arc-k4a puts it in git) -- and nothing here may remove what
    # it did not put there. The cost, accepted: a file deleted from git
    # lingers in the share until someone removes it by hand. A file that IS
    # in git is overwritten by git's copy, hand-edits and all. Nothing
    # outside the five is named, so roms/, cores/, apps/, saves/ and
    # hub.json are never read or written; no -o/-g/-p, so what lands is
    # owned by arcade (the unit's user) and keeps the modes it already had.
    #
    # Weather is a retry, not a failed unit (environment-poll.nix's rule): a
    # fetch that fails is one journal line and the next tick asks again.
    # Configuration is a failed unit: a library that is not a writable
    # directory, or a clone path that is something other than a clone.
    #
    # Named in homelab.tenants.arcade.units (tenants.nix), so it runs in the
    # tenant's slice; it bounces freely, like everything arcade owns.
    systemd.services.arcade-library-sync = lib.mkIf cfg.librarySync.enable {
      description = "Copy home-arcade main's station files into ${toString cfg.dataDir}";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      # A switch that changes the unit mid-tick would kill a fetch for
      # nothing; the new unit applies at the next firing.
      restartIfChanged = false;
      # git that can never ask anyone anything, as environment-pull's.
      environment.GIT_TERMINAL_PROMPT = "0";
      serviceConfig = {
        Type = "oneshot";
        User = "arcade";
        Group = "arcade";
        UMask = "0022";
        ExecStart = lib.getExe librarySyncScript;
        ProtectSystem = "strict";
        ReadWritePaths = [
          (toString cfg.stateDir)
          (toString cfg.dataDir)
        ];
        PrivateTmp = true;
        NoNewPrivileges = true;
      };
    };

    systemd.timers.arcade-library-sync = lib.mkIf cfg.librarySync.enable {
      description = "Copy home-arcade main's station files into the arcade share";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        # Soon after boot, then every ten minutes: a merge reaches the
        # share within ten, and a station picks it up at its next launch.
        OnBootSec = "2min";
        OnUnitActiveSec = "10min";
      };
    };

    assertions = [
      {
        assertion = cfg.lanAddress != "0.0.0.0";
        message = "services.arcade-hub.lanAddress must be the LAN IP, not 0.0.0.0.";
      }
    ];
  };
}
