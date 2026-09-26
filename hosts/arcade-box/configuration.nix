# Per-host composition for arcade-box (ADR 0010): the Lenovo M920q that takes
# assetto, bot, arcade, observability and ci off ac-box.
#
# docs/runbook-arcade-box-cutover.md is the sequence this file is switched
# through. Every flag marked BUILD-UP below is deliberately the pre-cutover
# value; runbook phase 4 (4.2) is the one push that flips them together with
# hosts/ac-box's mirror image, and until then this host runs beside ac-box
# on a second address with nothing that would double up: no lobbies, no
# bot, no Buildkite agent.
#
# Same two reasons as hosts/ac-box/configuration.nix for what lives here:
# the hardware import (a literal path -- `imports` cannot read `config`),
# and the wiring of tenant options to host facts.
{ config, lib, ... }:

let
  # Fetched read-only from the box on 26 Sep 2026 and TRACKED (README's
  # pinned convention; .gitignore's NOTE). A missing file throws rather than
  # substituting the .example stub that will not boot a real machine.
  hardwarePath =
    if builtins.pathExists ./hardware-configuration.nix then
      ./hardware-configuration.nix
    else
      throw ''
        hosts/arcade-box/hardware-configuration.nix is missing.

        It is tracked in git, so a clean checkout always has it -- if it is
        gone, this working tree deleted it. Restore it; do not substitute
        hardware-configuration.nix.example:

          git checkout -- hosts/arcade-box/hardware-configuration.nix

        or re-fetch it read-only from the box:

          scp arcade-box:/etc/nixos/hardware-configuration.nix hosts/arcade-box/
      '';

  lan = config.homelab.host.networks.lan;
in
{
  imports = [ hardwarePath ];

  # ---------------------------------------------------------------------------
  # Enforcement on from the first switch. ac-box flipped these one phase at a
  # time because each had to be proven a no-op against a running machine;
  # this host has nothing to be a no-op against, and the four effects are
  # what its first closure is for.
  # ---------------------------------------------------------------------------
  homelab.enforce = {
    firewall = true;
    inventory = true;
    scrape = true;
    slices = true;
  };

  # ---------------------------------------------------------------------------
  # ci: the Buildkite agent and MinIO, the same compose unit ac-box runs.
  #
  # BUILD-UP: off, tenant and unit both. Every pipeline says `queue: self`,
  # so a second agent here would take jobs that stage state on THIS host
  # (queue-closure, queue-prod, the image step's docker load) while ac-box
  # is still the one that should receive them. The tenant is disabled with
  # it because resources.nix would otherwise write Slice= for a unit that
  # does not exist and manufacture an empty ac-host-ci.service. Runbook
  # phase 3 builds the agent image and starts MinIO by hand without this;
  # 4.2 flips both to true and the queue moves whole.
  # ---------------------------------------------------------------------------
  homelab.ci.enable = false;
  homelab.tenants.ci.enable = false;
  systemd.services.ac-host-ci = lib.mkIf config.homelab.ci.enable {
    wantedBy = [ "multi-user.target" ];
  };

  # As on ac-box (ADR 0011): jobs run in the agent's container; the native
  # stubs stay behind the flag. jobEnvironment is the paths ac-host's
  # pipeline reads, spelled from the tenant's own options.
  homelab.ci.native.enable = false;
  homelab.ci.native.jobEnvironment =
    let
      ac = config.services.ac-host;
      state = toString ac.stateDir;
    in
    {
      AC_STATE = state;
      AC_CONTENT = "${state}/content";
      AC_SRC = toString ac.repoDir;
      AC_BUILD = "${state}/build";
      AC_SERVE_CONTENT = "${state}/content";
      AC_PAGES_CHECKOUT = "";
      GITHUB_STATUS_BRANCH = "main";
    };

  # ---------------------------------------------------------------------------
  # The closure deploys itself (ADR 0006, ADR 0008): on from the first
  # switch, and idle until the agent is local -- nothing writes
  # /var/lib/homelab/pending-closure.json on this host before 4.2, so the
  # path unit watches an absent file and the timer's retry finds nothing
  # staged. Enabling it now means the cutover switch is the last hand switch
  # this host ever gets, the same property ac-box reached at generation 34.
  # ---------------------------------------------------------------------------
  homelab.deploy.enable = true;
  homelab.deploy.schedule = "continuous";

  # ---------------------------------------------------------------------------
  # assetto and bot: the lobbies, the sidecars, the Discord bot, the 03:00
  # recycle.
  #
  # BUILD-UP: off, module and tenants alike, because they are live on ac-box:
  # a second bot would post to Discord twice and queue DOWNTIME twice, and
  # three more lobbies would be three more forwards' worth of confusion.
  # With the tenants disabled the contract opens no lobby port on eno2 and
  # writes no assetto entry to the inventory, so homelab-deploy's busy check
  # does not consult a script that is not here yet. 4.2 flips all four.
  #
  # lanInterface is set even while off, and it is the one line ac-box never
  # needed: the module's default is `enp8s0`, which is ac-box's NIC name and
  # nobody else's. Read from the host fact, never repeated.
  # ---------------------------------------------------------------------------
  services.ac-host = {
    enable = false;
    repoDir = "/var/lib/ac-host/src";
    stateDir = "/var/lib/ac-host";
    authOpen = false;
    requiredRole = "ac-practice";
    lanInterface = lan.interface;
  };
  services.ac-host-dev = {
    enable = false;
    stateDir = "/var/lib/ac-host-dev";
  };
  homelab.tenants.assetto.enable = false;
  homelab.tenants.bot.enable = false;

  # ---------------------------------------------------------------------------
  # arcade: the host side (hosts/arcade-box/tenants/arcade.nix -- the user,
  # the directories, the SMB and rsync exports on the LAN address) and the
  # two game servers as stubs from home-arcade's flox environment, exactly
  # as hosts/ac-box/configuration.nix declares them.
  #
  # environment.enable follows modules/tenant/environment-pull.nix's
  # first-switch order and is the one BUILD-UP flag that flips BEFORE the
  # cutover: false on the first switch (the stubs fail with the placeholder
  # message, on purpose), then the pull unit clones, pulls generation 2 of
  # imkarrer/arcade and warms it (runbook phase 3), then true in its own
  # push. Running from an empty dir is the failure the order exists to
  # prevent.
  # ---------------------------------------------------------------------------
  services.arcade-hub = {
    enable = true;
    lanAddress = lan.address;
    rsync.enable = true;
  };

  homelab.tenants.arcade.environment =
    let
      hub = config.services.arcade-hub;
      state = toString hub.stateDir;
    in
    {
      enable = false;
      source = {
        kind = "floxhub";
        env = "imkarrer/arcade";
      };
      tree = "home-arcade";
      units."arcade-freeciv.service" = {
        description = "Arcade Freeciv dedicated server (LAN only)";
        workingDirectory = "${state}/freeciv";
        command = [
          "freeciv-server"
          "--bind"
          hub.lanAddress
          "--port"
          (toString hub.freeciv.port)
          "--saves"
          "${state}/freeciv"
          "--log"
          "${state}/freeciv/server.log"
        ];
      };
      units."arcade-mindustry.service" = {
        description = "Arcade Mindustry dedicated server (LAN only)";
        workingDirectory = "${state}/mindustry";
        command = [ "mindustry-server" ];
        environment.JAVA_TOOL_OPTIONS = "-Xms256M -Xmx1G";
        stdin = [
          "config name Arcade"
          "config port ${toString hub.mindustry.port}"
          "host ${hub.mindustry.map} ${hub.mindustry.mode}"
        ];
      };
    };

  # ---------------------------------------------------------------------------
  # Tier shares for a 6-core, 31 GiB host with no background tenant
  # (runbook 5.3). Shares of declared capacity, as ADR 0002 requires; the
  # ceilings they produce today are in the comments so the next reader does
  # not redo the arithmetic.
  #
  # NO cpuset fence (ADR 0010: "tier -> slice without the cpuset fence").
  # On ac-box the fence exists so a Nix build or the model server cannot
  # reach the cores the lobbies run on -- with 28 physical cores there are
  # cores to spare. Here resources.nix would carve one or two of six cores
  # for every CI build and leave them idle the rest of the day. CPUWeight is
  # the whole story on this host: 500 for the lobby containers against 300
  # for a build, consulted only under contention, and MemoryMax still puts
  # a ceiling under a runaway job (batch is what OOMs, not a lobby).
  # ---------------------------------------------------------------------------
  homelab.tiers = {
    critical = {
      # ~6.2 GiB for the lobby containers, sidecars and bot via cgroup_parent
      # (2.5 GiB peak on ac-box). critical is never sliced by the contract;
      # this ceiling reaches the containers through the compose file.
      memoryShare = 0.20;
      cpuShare = 0.50;
    };
    interactive = {
      # ~6.2 GiB for arcade (Mindustry -Xmx1G), samba, rsync and the eight
      # observability units (1.3 GiB peak on ac-box).
      memoryShare = 0.20;
      cpuShare = 0.20;
    };
    background = {
      # No tenant. A small nonzero ceiling rather than 0 so the slice, which
      # resources.nix creates for every tier, is never a MemoryMax=0 trap.
      memoryShare = 0.05;
      cpuShare = 0.05;
      fence = false;
    };
    batch = {
      # ~14 GiB for the agent, MinIO and nix-daemon (modules/platform/nix.nix
      # slices the daemon here). ac-box's 12.5 GiB has held every build so
      # far at cores = 2; --spawn stays 1 until this host has numbers.
      memoryShare = 0.45;
      cpuShare = 0.30;
      fence = false;
    };
  };

  # The installer wrote 26.05; copied, not chosen.
  system.stateVersion = "26.05";
}
