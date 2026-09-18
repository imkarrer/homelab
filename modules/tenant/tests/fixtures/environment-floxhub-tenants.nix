# Fixture for eval-environment.nix's floxhub cases: the arcade tenant as
# hosts/ac-box/tenants.nix declares it (tier, the two game units, no
# state.dirs -- so dir derives to /var/lib/arcade/env) with the stub
# hosts/ac-box/configuration.nix carries (homelab-158.5): source.kind =
# floxhub, two stubs from one environment, the values the box's
# services.arcade-hub computes written as literals. enable is left at its
# default (false) here as there; the cases that need it on say so.
#
# The two units are stand-ins for what home-arcade's modules/arcade-hub.nix
# makes of them today (User=arcade, Restart=, an ExecStart at plain
# priority), the way environment-tenants.nix stands in for agent-hub's.
{
  homelab.tenants.arcade = {
    description = "LAN arcade hub";
    tier = "interactive";
    units = [
      "arcade-freeciv.service"
      "arcade-mindustry.service"
    ];
    environment = {
      source = {
        kind = "floxhub";
        env = "imkarrer/arcade";
      };
      tree = "home-arcade";
      units."arcade-freeciv.service".command = [
        "freeciv-server"
        "--bind"
        "192.168.1.50"
        "--port"
        "5556"
        "--saves"
        "/var/lib/arcade/freeciv"
        "--log"
        "/var/lib/arcade/freeciv/server.log"
      ];
      units."arcade-mindustry.service" = {
        command = [ "mindustry-server" ];
        environment.JAVA_TOOL_OPTIONS = "-Xms256M -Xmx1G";
      };
    };
  };

  systemd.services.arcade-freeciv.serviceConfig = {
    ExecStart = "/nix/store/0000000000000000000000000000000-freeciv-3.2.2/bin/freeciv-server --bind 192.168.1.50 --port 5556 --saves /var/lib/arcade/freeciv --log /var/lib/arcade/freeciv/server.log";
    User = "arcade";
    Restart = "on-failure";
  };
  systemd.services.arcade-mindustry.serviceConfig = {
    ExecStart = "/nix/store/0000000000000000000000000000000-arcade-mindustry";
    User = "arcade";
    Restart = "on-failure";
  };
}
