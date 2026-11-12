# The ONLY file in this repo containing literals specific to this machine.
# Adapting to another box is a new hosts/<name>/host.nix plus a tenant choice.
# Values below were surveyed live on ac-box, 7 Sep 2026.
{ ... }:

{
  homelab.host = {
    name = "llm-box";
    timezone = "America/Chicago";

    networks = {
      lan = {
        # eno1 since 12 Nov 2026 (homelab-cyt); enp8s0 until then. The Dream
        # Router was replaced by a Cloud Gateway Fiber on 11 Nov, the Z840 was
        # re-cabled into this port, and the operator set the new router's fixed
        # IP on this port's MAC, c8:d3:ff:b9:28:0a. Read live on 12 Nov: eno1
        # leased 192.168.1.51 from 192.168.1.1 while the firewall still opened
        # 8100/6333/9100 on enp8s0 only, so all three timed out from the LAN
        # with every service active. The operator could not get UniFi to move
        # .51 to enp8s0's MAC, so the declaration moved to the port instead.
        # Both onboard ports linked at 1000 Mbps that day (kernel log);
        # nothing but the name changed.
        interface = "eno1";
        # 192.168.1.50 went to arcade-box at the cutover
        # (docs/runbook-arcade-box-cutover.md 4.1, decision D2) with the
        # lobbies, the forwards, the stations' SMB path and Grafana's URL that
        # name it; .51 was the pool's lowest free address beside it on 26 Sep
        # 2026 and the new router's fixed IP keeps it.
        address = "192.168.1.51";
        prefixLength = 24;
      };
      # The port with no cable: enp8s0, MAC c8:d3:ff:b9:28:0b, the LAN port
      # until 12 Nov 2026. What would move to a second port is ADR 0007's
      # decision (nothing). Nothing may be scoped to it until it has an
      # address, and it cannot have one until it has a link.
      mgmt = {
        interface = "enp8s0";
        address = null;
      };
    };

    # The UniFi gateway: a Cloud Gateway Fiber since 11 Nov 2026, the Dream
    # Router before, at the same address. It is this LAN's default route AND
    # its controller
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
