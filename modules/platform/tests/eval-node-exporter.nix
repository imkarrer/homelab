# Harness for modules/platform/node-exporter.nix: what it emits on a host a
# peer scrapes, and the two things it refuses -- running beside a Prometheus
# (the collector host has its own loopback exporter) and binding an address
# the host does not have. The NixOS options it writes are stubbed to
# `anything` here, the way modules/tenant/tests/stub-*.nix stub theirs: the
# module is the thing under test, not nixpkgs' exporter.
#
# Discovered by modules/tenant/tests/check.nix as `eval-platform-node-exporter`.
#
# Usage:
#   nix eval --impure --raw -f modules/platform/tests/eval-node-exporter.nix onPeerHost.checked
#   nix eval --impure --json -f modules/platform/tests/eval-node-exporter.nix onCollectorHost.messages
{
  lib ? (import ../../tenant/tests/pinned-nixpkgs.nix).lib,
}:
let
  hostOptions = ../host-options.nix;
  nodeExporter = ../node-exporter.nix;

  stubs =
    { lib, ... }:
    {
      options = {
        assertions = lib.mkOption {
          type = lib.types.listOf lib.types.unspecified;
          default = [ ];
        };
        services.prometheus.enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
        };
        services.prometheus.exporters = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };
        systemd.services = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };
        networking.firewall.interfaces = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };
      };
    };

  # A host a peer scrapes: the Z840's shape after the cutover, one LAN
  # interface with an address. mkDefault so a case can take the address
  # away without a conflicting-definition error standing in for the
  # refusal (check.nix's warning).
  hostFacts =
    { lib, ... }:
    {
      homelab.host = {
        name = "peer-box";
        networks.lan = {
          interface = "enp8s0";
          address = lib.mkDefault "192.168.1.51";
          prefixLength = 24;
        };
      };
    };

  mkCase =
    {
      extraModules ? [ ],
      checks ? (_: [ ]),
    }:
    let
      evaluated = lib.evalModules {
        modules = [
          stubs
          hostOptions
          hostFacts
          nodeExporter
        ]
        ++ extraModules;
      };
      cfg = evaluated.config;
      failedAssertions = lib.filter (a: !a.assertion) cfg.assertions;
      failedChecks = lib.filter (c: !c.assertion) (checks cfg);
      messages = map (a: a.message) failedAssertions ++ map (c: c.message) failedChecks;
    in
    {
      inherit messages;
      exporter = cfg.services.prometheus.exporters.node or null;
      firewall = cfg.networking.firewall.interfaces;
      checked =
        if messages == [ ] then
          "ok: exporter ${if cfg.services.prometheus.exporters ? node then "on" else "off"}"
        else
          throw (lib.concatStringsSep "\n" messages);
    };
in
{
  # Off by default: nothing emitted, nothing opened.
  offByDefault = mkCase {
    checks = cfg: [
      {
        assertion = cfg.services.prometheus.exporters == { } && cfg.networking.firewall.interfaces == { };
        message = "disabled, the module must emit no exporter and open no port";
      }
    ];
  };

  # On a host a peer scrapes: bound to the LAN address on 9100, that port
  # open on the LAN interface only, and the unit waiting for the address.
  onPeerHost = mkCase {
    extraModules = [ { homelab.platform.nodeExporter.enable = true; } ];
    checks = cfg: [
      {
        assertion =
          cfg.services.prometheus.exporters.node.enable
          && cfg.services.prometheus.exporters.node.listenAddress == "192.168.1.51"
          && cfg.services.prometheus.exporters.node.port == 9100;
        message = "the exporter must bind homelab.host.networks.lan.address:9100";
      }
      {
        assertion = cfg.networking.firewall.interfaces == {
          enp8s0.allowedTCPPorts = [ 9100 ];
        };
        message = "9100 must open on the LAN interface and nowhere else";
      }
      {
        assertion = lib.elem "network-online.target" cfg.systemd.services.prometheus-node-exporter.after;
        message = "the unit must wait for the DHCP address it binds";
      }
    ];
  };

  # The collector host scrapes itself over loopback (modules/observability);
  # a second exporter there is refused.
  onCollectorHost = mkCase {
    extraModules = [
      {
        homelab.platform.nodeExporter.enable = true;
        services.prometheus.enable = true;
      }
    ];
  };

  # No LAN address, nothing a peer could scrape; refused rather than a
  # null bind.
  noLanAddress = mkCase {
    extraModules = [
      {
        homelab.platform.nodeExporter.enable = true;
        homelab.host.networks.lan.address = lib.mkForce null;
      }
    ];
  };

  expected = {
    offByDefault = true;
    onPeerHost = true;
    onCollectorHost = false;
    noLanAddress = false;
  };
}
