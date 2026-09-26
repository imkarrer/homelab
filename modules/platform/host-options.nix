# The `homelab.host` option contract. Every literal fact about the physical
# machine — name, timezone, NIC/address, declared capacity, base paths,
# maintenance window, GPU, the UniFi controller it polls — is declared here and
# set exactly once, in hosts/<name>/host.nix. No other module may hardcode any
# of it.
#
# Shape is pinned against the hosts/<name>/host.nix files (ac-box and
# arcade-box) — do not add a field no host sets, and do not change the shape
# of one a host does set without updating that file in lockstep.
{ lib, ... }:

let
  inherit (lib) mkOption types;

  # One named interface's facts. attrsOf-keyed (lan, mgmt, ...) rather than a
  # fixed set of fields, because the tenant contract already refers to them
  # that way: "opened on host.networks.lan.interface" / ".mgmt.interface".
  networkFacts = types.submodule {
    options = {
      interface = mkOption {
        type = types.str;
        description = "NIC device name, e.g. enp8s0. The only place this is a literal.";
      };

      address = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          IPv4 address on this interface, or null when the interface carries
          none yet (mgmt is cabled but down until the dual-NIC runbook brings
          it up). Nothing may be scoped to an interface whose address is null.
        '';
      };

      prefixLength = mkOption {
        type = types.nullOr (types.ints.between 0 32);
        default = null;
        description = "CIDR prefix length. Left null alongside a null address.";
      };
    };
  };

  # One endpoint this host scrapes on a peer. A list on the peer rather than
  # an attrset keyed by job, because a peer's job may share its name with a
  # job this host scrapes locally (node) -- modules/observability/default.nix
  # then appends the target to the local job -- and that merge rule belongs
  # to the reader, not to the option's key.
  peerMetrics = types.submodule {
    options = {
      job = mkOption {
        type = types.str;
        description = ''
          The Prometheus job the target is scraped under. Deliberately the
          name the peer's OWN Prometheus used for the same endpoint before
          ADR 0010 moved observability to one host: a dashboard keyed on
          job="node" then sees both machines as instances of one job, and
          agent-hub's llamacpp:* series keep the job label their history
          carries. A job this host also scrapes locally gains the peer as a
          second target; any other name is a job of its own.
        '';
      };

      port = mkOption {
        type = types.port;
        description = "The port on the peer's address the endpoint listens on.";
      };

      path = mkOption {
        type = types.str;
        default = "/metrics";
        description = "metrics_path; the default is Prometheus's own.";
      };

      interval = mkOption {
        type = types.str;
        default = "30s";
        description = "scrape_interval; the default is the collector's global one.";
      };

      keep = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          A metric_relabel `keep` regex over __name__ -- the curation the
          collecting host applies -- or null to keep everything the endpoint
          serves. Curation is per job, not per target, so for a job this
          host also scrapes locally this must equal the local job's regex;
          modules/observability/default.nix asserts it rather than silently
          preferring one.
        '';
      };
    };
  };

  peerFacts = types.submodule {
    options = {
      address = mkOption {
        type = types.str;
        description = ''
          The peer's LAN address: THAT host's homelab.host.networks.lan
          .address, read from its own hosts/<name>/host.nix (the one file
          that holds its literals) -- never typed a second time, never
          guessed. hosts/arcade-box/host.nix shows the import.
        '';
      };

      metrics = mkOption {
        type = types.listOf peerMetrics;
        default = [ ];
        description = "The endpoints this host's Prometheus scrapes on the peer.";
      };
    };
  };

in
{
  options.homelab.host = {
    name = mkOption {
      type = types.str;
      description = ''
        networking.hostName. Also the key used to locate this host's
        machine-specific files — hosts/<name>/hardware-configuration.nix
        and hosts/<name>/ssh-keys.local.nix — so platform modules can find
        them without hardcoding a host name. Both are tracked in git, not
        gitignored: a flake copies only tracked files into the store. See
        .gitignore's NOTE.
      '';
    };

    timezone = mkOption {
      type = types.str;
      description = "time.timeZone, e.g. America/Chicago.";
    };

    networks = mkOption {
      type = types.attrsOf networkFacts;
      default = { };
      description = ''
        Named interface facts. Consumed by modules/platform/network.nix and by
        the tenant contract's port scoping (a "lan" or "mgmt" scoped port opens
        on host.networks.<name>.interface; "forwarded" is lan plus a router
        forward). This is the only place NIC names and addresses are literal —
        every other module, including tenants, must read them from here.
      '';
    };

    peers = mkOption {
      type = types.attrsOf peerFacts;
      default = { };
      description = ''
        Another homelab host this one scrapes, keyed by that host's
        homelab.host.name. Empty on every host but the one running the
        collector.

        Why a host fact. ADR 0010 put the two boxes on one LAN with one
        Prometheus (arcade-box's, modules/observability), and a target on the
        other machine had no spelling: modules/tenant/metrics.nix admits
        loopback or one of THIS host's addresses, deliberately, because a
        tenant's endpoint is on the host the tenant runs on. A peer is the
        other case -- the machine that runs the collector naming the machine
        it collects from -- which is a fact about the collector host, so it
        lives beside its other machine facts and is read by
        modules/observability/default.nix alone. The Z840's exporter for it
        is modules/platform/node-exporter.nix.
      '';
    };

    unifi = mkOption {
      type = types.submodule {
        options = {
          address = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = ''
              IPv4 address of the UniFi controller API this network's gear is
              polled through, or null when the host has no UniFi gear -- in
              which case modules/observability/default.nix runs no unpoller, no
              udr-fw-exporter, and no scrape jobs for either, the same way
              gpu = null below leaves boot.nix's nvidia block unbuilt.

              No scheme. This is an address, exactly like networks.<name>
              .address is. "https://" and verify_ssl = false are facts about
              how one talks to a UniFi controller (self-signed cert on a
              private LAN), not facts about this network, so they stay at the
              use site.

              Deliberately NOT networks.lan.gateway, even though on ac-box the
              two are the same box at the same address. The consumers --
              unpoller and udr_fw_exporter.py -- speak the UniFi controller
              API; neither cares what the default route is. Surveyed live
              9 Sep 2026: `ip route` gives "default via 192.168.1.1 dev
              enp8s0", and the generated unpoller.json carries controller url
              "https://192.168.1.1" -- one Dream Router wearing both hats. A
              "gateway" field would record that coincidence and go quietly
              wrong the day the controller moves to a Cloud Key or a
              self-hosted container while the route stays put; the polling
              would break and the field would still be telling the truth.
              Add a gateway field when something actually needs the route.
            '';
          };
        };
      };
      default = { };
      description = ''
        The UniFi controller this network's gear is polled through. Read by
        modules/observability/default.nix, which until 9 Sep 2026 hardcoded
        "https://192.168.1.1" twice -- unpoller's controller url and
        udr-fw-exporter's UNIFI_HOST. That was the last machine literal
        standing in the module layer (finding F6 in docs/current-state.md);
        `grep -rnE "192\.168\.|enp8s0|eno1" modules/` returned comments plus
        those two lines and, re-run after this change, returns comments plus
        only the exporter script's own env fallback. Same rule as networks
        above: a module reads host facts from here, it does not guess them.
      '';
    };

    capacity = mkOption {
      type = types.submodule {
        options = {
          cpuThreads = mkOption {
            type = types.ints.positive;
            description = "Logical CPU threads, verified against /proc at activation.";
          };
          threadsPerCore = mkOption {
            type = types.ints.positive;
            default = 1;
            description = ''
              SMT threads per physical core (`lscpu`'s "Thread(s) per core").
              A topology fact, not a share: resources.nix needs it to build a
              correct AllowedCPUs fence, because Linux does NOT enumerate
              logical CPUs core-by-core on an SMT machine. It enumerates every
              first thread first, then every sibling -- so on ac-box (56
              threads, 2 per core) CPUs 0-27 are the 28 PHYSICAL cores and
              28-55 are their siblings, one per core.

              Getting this wrong is silent and expensive: a fence written as
              the naive index range "28-55" reads like "the top half of the
              cores" and is actually "the second thread of every core",
              which fences nothing physically and is close to the worst
              possible CPU set for a memory-bound workload. Default 1 (no
              SMT) is the conservative reading -- the derived fence then
              degenerates to a single contiguous range, which is correct for
              a non-SMT host.

              Verified on ac-box 8 Sep 2026 against `lscpu`: Thread(s) per
              core: 2, NUMA node0 CPU(s) 0-13,28-41, node1 14-27,42-55.
            '';
          };
          memoryGiB = mkOption {
            type = types.ints.positive;
            description = "Physical RAM in GiB, verified against /proc at activation.";
          };
        };
      };
      description = ''
        Declared capacity. Tiers (homelab.tiers) are expressed as shares of
        this, never absolute gigabytes or CPU indices — copying a host.nix to
        a smaller machine without editing capacity is the classic portability
        bug this field exists to catch.
      '';
    };

    paths = mkOption {
      type = types.submodule {
        options = {
          data = mkOption {
            type = types.path;
            description = "Base directory for tenant data; derived default is <data>/<tenant>.";
          };
          state = mkOption {
            type = types.path;
            description = "Base directory for tenant state; derived default is <state>/<tenant>.";
          };
        };
      };
      description = ''
        Base directories the tenant schema's dirSet derives defaults from.
        A tenant overrides explicitly only to preserve an existing path
        (assetto keeps /var/lib/ac-host) — renaming a state dir is a data
        migration, not a config change.
      '';
    };

    maintenance = mkOption {
      type = types.submodule {
        options = {
          window = mkOption {
            type = types.str;
            description = ''
              Time of day (HH:MM, host's timezone) reserved for
              non-drainable tenants' maintenance work. Read by the quiet/drain
              policy, not reinvented per tenant.
            '';
          };
        };
      };
      description = "The maintenance window.";
    };

    gpu = mkOption {
      type = types.nullOr (types.enum [ "nvidia" ]);
      default = null;
      description = ''
        GPU vendor driver to enable, or null for none. Consumed by
        modules/platform/boot.nix to gate hardware.graphics / hardware.nvidia.
        Only "nvidia" exists today because that's the only value ac-box sets;
        extend the enum when a second vendor shows up rather than widening it
        to a bare string speculatively.
      '';
    };
  };
}
