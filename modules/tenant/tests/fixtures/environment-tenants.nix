# Fixture for environment.nix's harness: the agent-hub tenant as
# hosts/ac-box/tenants.nix declares it (tier, unit, state dir -- the facts
# the stub reads), plus a stand-in for what modules/agent-hub.nix makes of
# agent-hub-llm.service today: an ExecStart at plain priority, a User=. The
# stub must leave the second alone and, when enabled, replace only the
# first. Unit names carry their suffix, as tenants.nix spells them and as
# fixtures/resources-tenants.nix explains at length.
#
# The stub declaration is the SAME shape hosts/ac-box/configuration.nix
# carries (enable left at its default there too); the values are the box's,
# written as literals here because this fixture has no services.agent-hub
# to read them from.
{
  homelab.tenants.agent-hub = {
    description = "CPU-only LLM server";
    tier = "background";
    units = [ "agent-hub-llm.service" ];
    state.dirs = [ "/var/lib/agent-hub" ];
    environment.units."agent-hub-llm.service" = {
      command = [
        "llama-swap"
        "-config"
        "/var/lib/agent-hub/env/llama-swap.yaml"
        "-listen"
        "127.0.0.1:8100"
      ];
      environment = {
        AGENT_HUB_MODELS = "/srv/agent-hub/models";
        AGENT_HUB_THREADS = "23";
        AGENT_HUB_CTX = "32768";
        AGENT_HUB_LISTEN = "127.0.0.1:8100";
        AGENT_HUB_BACKEND_PORT = "18100";
        AGENT_HUB_SWAP_CONFIG = "/var/lib/agent-hub/env/llama-swap.yaml";
        AGENT_HUB_ASSETS = "/var/lib/agent-hub/env/nix";
      };
    };
  };

  # What the tenant's NixOS module contributes today, at plain priority.
  systemd.services.agent-hub-llm.serviceConfig = {
    ExecStart = "/nix/store/0000000000000000000000000000000-llama-swap-224/bin/llama-swap -config /nix/store/0000000000000000000000000000000-agent-hub-llama-swap.json -listen 127.0.0.1:8100";
    User = "agent-hub";
    Restart = "on-failure";
  };
}
