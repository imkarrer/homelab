# The ONLY file in this repo containing literals specific to this machine.
# Adapting to another box is a new hosts/<name>/host.nix plus a tenant choice.
# Values below were surveyed live on ac-box, 7 Sep 2026.
{ ... }:

{
  homelab.host = {
    name = "ac-box";
    timezone = "America/Chicago";

    networks = {
      lan = {
        interface = "enp8s0";
        address = "192.168.1.50";
        prefixLength = 24;
      };
      # Cabled but DOWN. The dual-NIC runbook brings this up as management.
      # Nothing may be scoped to it until it has an address.
      mgmt = {
        interface = "eno1";
        address = null;
      };
    };

    # The UniFi Dream Router. It is this LAN's default route AND its controller
    # API, but only the second is what reads this field -- see the option's
    # description for why it is not networks.lan.gateway. Surveyed live on
    # ac-box 9 Sep 2026: `ip route` -> "default via 192.168.1.1 dev enp8s0",
    # and the running unpoller.json -> controller url "https://192.168.1.1".
    # Until today both observability consumers carried this literal themselves.
    unifi.address = "192.168.1.1";

    # HP Z840. Verified against /proc at activation — copying this file to a
    # smaller machine without editing it is the classic portability bug, so the
    # platform warns rather than silently overcommitting.
    capacity = {
      cpuThreads = 56;
      # Dual Xeon E5-2680 v4: 2 sockets x 14 cores x 2 threads. So 28 physical
      # cores, and CPUs 28-55 are the SMT siblings of 0-27 -- see
      # host-options.nix's threadsPerCore for why the fence math needs this.
      threadsPerCore = 2;
      memoryGiB = 251;
    };

    paths = {
      data = "/srv";
      state = "/var/lib";
    };

    # The 03:00 ritual the Discord community already understands. Read by the
    # drain policy; not reinvented.
    maintenance.window = "03:00";

    gpu = "nvidia";
  };
}
