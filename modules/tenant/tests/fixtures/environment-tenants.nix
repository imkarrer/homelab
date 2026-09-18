# Fixture for environment.nix's harness: the agent-hub tenant as
# hosts/ac-box/tenants.nix declares it (tier, unit, state dir -- the facts
# the stub reads) and its stub as hosts/ac-box/configuration.nix declares
# it, values written as literals because this fixture has no
# services.agent-hub to read them from. Unit names carry their suffix, as
# tenants.nix spells them and as fixtures/resources-tenants.nix explains at
# length.
#
# Since homelab-158.11 the stub is the whole unit: there is no stand-in
# for a tenant module here any more, because no module declares the unit.
# What the retired modules/agent-hub.nix supplied is the stub's skeleton --
# the description and TimeoutStopSec set explicitly, User/Group, Restart,
# After/Wants, WantedBy from schema.nix's defaults. enable is left at its
# default (false) here as configuration.nix's first-switch state; the
# cases that need it on say so.
{
  homelab.tenants.agent-hub = {
    description = "CPU-only LLM server";
    tier = "background";
    units = [ "agent-hub-llm.service" ];
    state.dirs = [ "/var/lib/agent-hub" ];
    environment.units."agent-hub-llm.service" = {
      description = "agent-hub model server: llama-swap over 6 models (LAN only)";
      timeoutStopSec = 90;
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
}
