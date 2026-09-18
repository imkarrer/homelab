# Fixture for eval-environment.nix's floxhub cases: the arcade tenant as
# hosts/ac-box/tenants.nix declares it (tier, the two game units, no
# state.dirs -- so dir derives to /var/lib/arcade/env) with the stubs
# hosts/ac-box/configuration.nix carries (homelab-158.5, whole units since
# .11): source.kind = floxhub, two stubs from one environment, the values
# the box's services.arcade-hub computes written as literals -- the
# descriptions and WorkingDirectory the retired modules/arcade-hub.nix used
# to set, mindustry's three console lines as `stdin`, and User/Group,
# Restart, After/Wants, WantedBy from schema.nix's defaults. enable is left
# at its default (false) here as there; the cases that need it on say so.
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
      units."arcade-freeciv.service" = {
        description = "Arcade Freeciv dedicated server (LAN only)";
        workingDirectory = "/var/lib/arcade/freeciv";
        command = [
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
      };
      units."arcade-mindustry.service" = {
        description = "Arcade Mindustry dedicated server (LAN only)";
        workingDirectory = "/var/lib/arcade/mindustry";
        command = [ "mindustry-server" ];
        environment.JAVA_TOOL_OPTIONS = "-Xms256M -Xmx1G";
        stdin = [
          "config name Arcade"
          "config port 6567"
          "host Islands sandbox"
        ];
      };
    };
  };
}
