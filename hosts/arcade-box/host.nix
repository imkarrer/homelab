# The second file in this repo containing literals specific to one machine
# (hosts/ac-box/host.nix is the first, and its header's rule holds: adapting
# to another box is a new hosts/<name>/host.nix plus a tenant choice).
# Values below were surveyed live on the Lenovo M920q on 26 Sep 2026, over
# the installer's login, read-only: docs/runbook-arcade-box-cutover.md
# section 1 has the transcript's facts and where each came from.
{ ... }:

{
  homelab.host = {
    name = "arcade-box";
    timezone = "America/Chicago";

    networks = {
      # The M920q has one wired port. `eno2` is it (MAC e8:6a:64:f4:81:94);
      # `wlo1` is a Wi-Fi card with no carrier, which network.nix's
      # `wireless.enable = mkForce false` already leaves alone.
      #
      # No `mgmt` entry, on purpose: there is no second port to give the
      # role to. ports.nix reads networks.mgmt only when a host declares it
      # (homelab-ygc.3); ADR 0007 keeps the scope in the contract for the
      # host that has the interface.
      lan = {
        interface = "eno2";
        # Since the cutover (runbook phase 4, decision D2): the address the nine
        # hand-set lobby forwards, the stations' SMB path and Grafana's URL have
        # always named, taken over from ac-box by swapping the two Dream Router
        # reservations (this MAC -> .50). DHCP, pinned by that reservation; the
        # build-up ran on .218 from 26 Sep 2026.
        address = "192.168.1.50";
        prefixLength = 24;
      };
    };

    # The same Dream Router ac-box polls; the two hosts share one LAN and
    # one controller. See hosts/ac-box/host.nix for why this is not a
    # gateway field.
    unifi.address = "192.168.1.1";

    # i7-8700T: one socket, 6 cores x 2 threads (`lscpu`, 26 Sep 2026).
    # ADR 0010's table said i7-9700T 8c/8t until that day; the fence math in
    # resources.nix needs threadsPerCore to be right more than it needs the
    # model name, and on this host the fence is off anyway
    # (configuration.nix, homelab.tiers.<tier>.fence).
    capacity = {
      cpuThreads = 12;
      threadsPerCore = 2;
      # MemTotal 32700632 kB = 31.2 GiB. The activation check compares
      # whole GiB with 2 GiB of slack; 31 is what /proc says.
      memoryGiB = 31;
    };

    paths = {
      data = "/srv";
      state = "/var/lib";
    };

    # The same 03:00 window: the lobbies move here, and with them the
    # community's understanding of when they are recycled.
    maintenance.window = "03:00";

    # Intel UHD 630, unused. null is the option's default; stated so nobody
    # goes looking for an nvidia block that boot.nix will never build here.
    gpu = null;
  };
}
