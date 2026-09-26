# The platform's own node exporter: for a host a PEER scrapes and that runs
# no collector itself.
#
# Since ADR 0010's cutover the Z840 imports no observability module -- the
# Prometheus that watched it moved to arcade-box with everything else -- and
# so had no node exporter: the machine serving the models was the one machine
# nobody could graph. arcade-box's Prometheus scrapes it over the LAN instead
# (hosts/arcade-box/host.nix, homelab.host.peers.ac-box, read by
# modules/observability/default.nix), which needs an exporter here bound to
# the LAN address and a hole in the firewall for it. Both are this module.
#
# WHY THE OPENING IS DECLARED HERE and not through the port registry. The
# tenant contract's ports (modules/tenant/ports.nix) describe TENANTS: a
# claim is homelab.tenants.<name>.ports.<claim>, and the firewall rule is
# derived from the claim's scope. This exporter is nobody's tenant on this
# host. It is observability's, and observability is a tenant of the host that
# runs the collector, not of the host being collected from. So the one port is
# opened here, on the LAN interface only -- never global allowedTCPPorts, the
# rule ports.nix keeps -- and 9100 is observability's claim on the collector
# host: modules/observability/default.nix binds its own node exporter on
# 127.0.0.1:9100, registered there at scope = "local". The cost of standing
# beside the registry rather than in it: the registry cannot see this port,
# so a tenant on this host that later claimed 9100 at scope lan would pass the
# collision check and lose the bind at runtime. Keep that in mind when a
# tenants.nix for a host with this enabled grows a claim.
#
# The same two collectors as the observability module's exporter, so a node
# series from a peer and one from the collector host have the same shape and
# the keep regex the "node" job applies fits both.
#
# Refuses to coexist with services.prometheus on the same host: that host has
# the observability module and its own loopback exporter on the same port.
# Without the assertion the failure is a conflicting definition of
# services.prometheus.exporters.node.listenAddress, which names two modules
# and neither reason; with it, the message says which of the two to turn off.
{ config, lib, ... }:

let
  inherit (lib) mkOption types mkIf;

  cfg = config.homelab.platform.nodeExporter;
  lan = config.homelab.host.networks.lan;

  # observability's port for a node exporter, on whichever host one runs.
  port = 9100;
in
{
  options.homelab.platform.nodeExporter = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Run prometheus-node-exporter on homelab.host.networks.lan.address:9100
        and open 9100 on the LAN interface, for a peer's Prometheus to scrape
        (that peer names this host under homelab.host.peers). For a host that
        runs no collector of its own; a host with modules/observability has
        its own exporter on loopback and must leave this false.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = !config.services.prometheus.enable;
        message = ''
          homelab.platform.nodeExporter.enable = true on ${config.homelab.host.name}, which also
          runs Prometheus (services.prometheus.enable): modules/observability already binds its
          own node exporter on 127.0.0.1:9100 there. The platform exporter is for a host a PEER
          scrapes; the collector host scrapes itself over loopback. Set one of the two false.
        '';
      }
      {
        assertion = lan.address != null;
        message = ''
          homelab.platform.nodeExporter binds homelab.host.networks.lan.address, which is null
          on ${config.homelab.host.name}. A peer cannot scrape an address this host does not have.
        '';
      }
    ];

    services.prometheus.exporters.node = {
      enable = true;
      listenAddress = lan.address;
      inherit port;
      enabledCollectors = [
        "systemd"
        "filesystem"
      ];
    };

    # The address is DHCP-assigned (network.nix: NetworkManager and the
    # router's reservation own it), and nixpkgs orders an exporter after
    # network.target only. Binding one specific address before it exists is
    # EADDRNOTAVAIL, and Restart=always would then loop through early boot.
    # Wait for the address the way modules/observability orders Grafana,
    # which binds the same kind of address on the collector host.
    systemd.services.prometheus-node-exporter = {
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
    };

    networking.firewall.interfaces.${lan.interface}.allowedTCPPorts = [ port ];
  };
}
