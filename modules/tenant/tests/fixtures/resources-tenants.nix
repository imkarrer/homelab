# Fixture tenants for resources.nix's eval harness. Real, pinned tenant names
# (README: "Tenant names are exactly...") and real unit names (README: "Unit and
# container names never change").
#
# Unit names carry their `.service` / `.timer` suffix, exactly as
# hosts/ac-box/tenants.nix declares them and exactly as systemctl shows them.
#
# This matters, and it is why this file has a long comment. This fixture used to
# declare BARE names ("arcade-freeciv"), which production never does. resources.nix
# keyed systemd.services with whatever it was given, so against the fixture it
# produced systemd.services."arcade-freeciv" -- correct -- and against the real
# declarations it produced systemd.services."arcade-freeciv.service", which NixOS
# silently renders as a unit named "arcade-freeciv.service.service".
#
# The result on the box: ten phantom *.service.service units, not one real unit
# assigned to any slice, and a dry-activate that reported no restarts because
# nothing real had changed. The slices existed, so it looked like it worked, while
# the entire tiering guarantee was inert. The test passed throughout, because it
# was asserting against a format reality never used.
#
# Keep these suffixed. A fixture that does not match the production declaration
# format is worse than no fixture: it manufactures confidence.
{
  homelab.tenants = {
    assetto = {
      description = "AC race servers";
      tier = "critical";
      # A .timer is included deliberately: timers run no processes, so Slice=
      # cannot apply to them, and resources.nix must report rather than silently
      # drop them.
      units = [ "ac-host-static.service" "ac-host-nightly.timer" ];
    };

    arcade = {
      description = "Kid arcade hub";
      tier = "background";
      units = [ "arcade-freeciv.service" "arcade-mindustry.service" ];
    };

    agent-hub = {
      description = "CPU-only LLM server";
      tier = "batch";
      units = [ "agent-hub-llm.service" ];
    };

    observability = {
      description = "Prometheus/Grafana stack";
      tier = "interactive";
      units = [ "prometheus.service" ];
    };
  };
}
