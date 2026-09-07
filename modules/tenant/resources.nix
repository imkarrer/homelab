# Tier -> cgroup resource control. Consumes the tenant contract
# (homelab.tenants, from schema.nix) and the host's declared capacity
# (homelab.host.capacity, owned by the L0 platform layer) to produce:
#
#   - homelab.tiers.<tier>.{memoryShare,cpuShare,ioWeight,nice}  (new option,
#     declared here because this is where it is derived from — see
#     schema.nix's header: "ports.nix, resources.nix, metrics.nix and
#     quiet.nix consume [the contract]", this file's job is tiers)
#   - systemd.slices.<tier>                    (MemoryMax, CPUWeight, IOWeight,
#                                                AllowedCPUs for background/batch)
#   - systemd.services.<unit>.serviceConfig    (Slice=, Nice=) for every unit
#     a tenant declares, keyed off homelab.tenants.<name>.tier
#   - assertions                                (memoryShare budget)
#   - system.activationScripts                  (capacity drift warning)
#
# Pinned convention (README): tiers are shares of declared capacity, never
# absolute gigabytes or CPU indices — a host swap must only mean editing
# hosts/<name>/host.nix, never this file. CPUWeight is the primary sharing
# mechanism precisely because it lets idle capacity stay usable: a weight is
# only consulted under contention, so critical can burst onto the whole
# machine when interactive/background/batch are quiet. AllowedCPUs is used
# ONLY to fence background/batch away from the low-numbered cores critical
# uses — it must never be used to cap critical itself (that would waste idle
# capacity the moment something background-ish gets busy), and it must never
# stand in for CPUQuota, which would hard-cap critical the same way.
{ config, lib, pkgs, ... }:

let
  inherit (lib) mkOption types mkDefault mkIf mkMerge;

  cfg = config.homelab;
  capacity = cfg.host.capacity;

  tierSubmodule = types.submodule {
    options = {
      memoryShare = mkOption {
        type = types.numbers.between 0.0 1.0;
        description = ''
          Fraction of homelab.host.capacity.memoryGiB this tier's slice may
          use as a hard ceiling (systemd MemoryMax). A share, never a
          gigabyte figure — see README "Pinned conventions".
        '';
      };

      cpuShare = mkOption {
        type = types.numbers.between 0.0 1.0;
        description = ''
          Fraction of the machine expressed as a proportional systemd
          CPUWeight, not a hard cap. Idle capacity above this share is still
          available to the tier when nothing else is contending for it.
        '';
      };

      ioWeight = mkOption {
        type = types.ints.between 1 10000;
        description = "systemd IOWeight for this tier's slice.";
      };

      nice = mkOption {
        type = types.ints.between (-20) 19;
        description = ''
          Scheduling niceness applied to every unit assigned to this tier
          (systemd can't set Nice= on a Slice unit, only on units that run
          processes, so this is propagated to each tenant unit's
          serviceConfig instead).
        '';
      };
    };
  };

  # "Sensible starting values" per the task/rationale doc: critical 0.35/0.50,
  # interactive 0.15/0.20, background 0.35/0.25, batch 0.10/0.05.
  #
  # AMBIGUITY, resolved: those four memoryShare figures sum to 0.95, which
  # exceeds the 0.9 budget this same file is asked to enforce (headroom for
  # the kernel and anything running outside a tenant slice). Shipping a
  # default that fails its own assertion isn't "sensible," so background's
  # memoryShare is trimmed from 0.35 to 0.30 here — the minimal single-tier
  # change that lands the sum exactly on the 0.9 ceiling. background is the
  # one tenant tier explicitly designed to yield (it already matches
  # critical's memory share while getting a smaller CPU share and lower
  # priority everywhere else, which is uneven to begin with); critical is
  # never trimmed because it "yields to nothing", interactive is already the
  # smallest latency-sensitive share, and batch is already the floor. Every
  # value below is `mkDefault`, so a host can still override any one of them
  # (e.g. restore background to 0.35) without needing mkForce.
  tierDefaults = {
    critical    = { memoryShare = 0.35; cpuShare = 0.50; ioWeight = 500; nice = -5;  };
    interactive = { memoryShare = 0.15; cpuShare = 0.20; ioWeight = 300; nice = 0;   };
    background  = { memoryShare = 0.30; cpuShare = 0.25; ioWeight = 100; nice = 10;  };
    batch       = { memoryShare = 0.10; cpuShare = 0.05; ioWeight = 10;  nice = 19;  };
  };

  totalMemoryShare = lib.foldl' (a: b: a + b) 0.0
    (lib.mapAttrsToList (_: t: t.memoryShare) cfg.tiers);

  # MemoryMax is expressed in MiB rather than a plain "<N>G" suffix: capacity
  # is declared in whole GiB, and a share of it is very often fractional
  # (0.30 * 251 GiB = 75.3 GiB). Truncating to whole GiB would either waste
  # ceiling headroom or quietly round up past the intended share depending on
  # direction, so the GiB figure is scaled to MiB before flooring — the
  # boundary is still capacity-derived and still GiB-scale, just expressed at
  # finer granularity so the floor loses at most ~1 MiB instead of ~1 GiB.
  memoryMaxMiB = tierName:
    builtins.floor (cfg.tiers.${tierName}.memoryShare * capacity.memoryGiB * 1024);

  cpuWeight = tierName:
    let w = builtins.floor (cfg.tiers.${tierName}.cpuShare * 1000);
    in if w < 1 then 1 else if w > 10000 then 10000 else w;

  # Cores [0, reservedForCritical) are the ones critical is expected to lean
  # on; background/batch are fenced out of that range via AllowedCPUs. This
  # is a fence, not a cap: critical itself gets no AllowedCPUs restriction at
  # all, so it can still spread onto the fenced-off cores when it needs to.
  reservedForCritical =
    let
      raw = builtins.ceil (cfg.tiers.critical.cpuShare * capacity.cpuThreads);
      # Always leave at least one core outside the fence, even on a tiny or
      # misconfigured host, so background/batch's AllowedCPUs is never empty.
      clamped = if raw >= capacity.cpuThreads then capacity.cpuThreads - 1 else raw;
    in if clamped < 0 then 0 else clamped;

  fencedAllowedCPUs = "${toString reservedForCritical}-${toString (capacity.cpuThreads - 1)}";

  sliceUnitsAreFenced = tierName: tierName == "background" || tierName == "batch";

  mkSlice = tierName: tierCfg: {
    description = "homelab ${tierName} tier";
    sliceConfig = {
      MemoryMax = "${toString (memoryMaxMiB tierName)}M";
      CPUWeight = cpuWeight tierName;
      IOWeight = tierCfg.ioWeight;
    } // lib.optionalAttrs (sliceUnitsAreFenced tierName) {
      AllowedCPUs = fencedAllowedCPUs;
    };
  };

  enabledTenants = lib.filterAttrs (_: t: t.enable) cfg.tenants;

  # A unit only gets Slice= if it can survive the restart required to receive it.
  #
  # Slice= is applied when a unit STARTS; `daemon-reload` will not move a running
  # service between slices. So adding it to an existing unit forces a restart —
  # and for assetto that is unacceptable, because ac-host-static's ExecStop is
  # `docker rm -f`, making "restart" mean deleting three live race servers.
  # Slice membership is also the only resource property that cannot be changed
  # live: MemoryMax, CPUWeight and IOWeight can all be adjusted on a running
  # slice afterwards.
  #
  # Skipping critical costs nothing, because critical never needed a slice to be
  # protected. The guarantee runs the other way round: AllowedCPUs fences
  # background and batch AWAY from the low-numbered cores, so a Nix build or an
  # LLM cannot reach the cores races run on. Confining races was never what
  # delivered that, and critical is deliberately uncapped regardless.
  #
  # Two independent reasons to skip a tenant, both honoured:
  #   tier == "critical"        — yields to nothing, wants no cap
  #   quiet.drainable == false  — bouncing it hurts, whatever its tier
  sliceableTenants = lib.filterAttrs
    (_: t: t.tier != "critical" && t.quiet.drainable)
    enabledTenants;

  # Unit names are taken verbatim from homelab.tenants.<name>.units — this file
  # assigns them to a slice, it never renames them (README: "Unit and container
  # names never change").
  tenantUnitTiers = lib.flatten (lib.mapAttrsToList
    (_: tenantCfg: map (unit: { inherit unit; tier = tenantCfg.tier; }) tenantCfg.units)
    sliceableTenants);

  # Tenants whose real workload is containers, sitting in a tier that carries an
  # AllowedCPUs fence. These are the ones where the tier model looks like it is
  # protecting something and is not.
  dockerTenantsInFencedTiers = lib.mapAttrsToList
    (name: t: "${name} (tier=${t.tier})")
    (lib.filterAttrs (_: t: t.needsDocker && sliceUnitsAreFenced t.tier) enabledTenants);

  # Surfaced as a warning rather than left silent, so "why is ac-host-static not
  # in a slice?" has an answer visible in the built system.
  unsliceableUnits = lib.flatten (lib.mapAttrsToList
    (name: t: map (u: "${u} (tenant ${name}, tier=${t.tier}, drainable=${lib.boolToString t.quiet.drainable})") t.units)
    (lib.filterAttrs (n: _: !(sliceableTenants ? ${n})) enabledTenants));

  # systemd.services is keyed by BARE unit name -- "grafana", not
  # "grafana.service". Tenants declare units with the suffix, because the README
  # requires verbatim names and that is what systemctl shows.
  #
  # Keying systemd.services with the suffix does not error. It silently defines a
  # unit called "grafana.service.service". That is exactly what happened: the
  # built closure carried ten phantom *.service.service units, no real unit
  # referenced any slice, and dry-activate cheerfully reported no restarts --
  # because nothing real had changed. The slices existed, so it looked like it
  # worked. The whole tiering guarantee was inert.
  #
  # Only .service units can take Slice=. A .timer does not run processes, so
  # slicing one is meaningless; those are reported instead of silently dropped.
  sliceableServiceUnits = builtins.filter (u: lib.hasSuffix ".service" u.unit) tenantUnitTiers;
  nonServiceUnits = builtins.filter (u: !(lib.hasSuffix ".service" u.unit)) tenantUnitTiers;

  unitServiceConfigs = lib.listToAttrs (map
    (u: lib.nameValuePair (lib.removeSuffix ".service" u.unit) {
      serviceConfig = {
        Slice = "${u.tier}.slice";
        Nice = cfg.tiers.${u.tier}.nice;
      };
    })
    sliceableServiceUnits);

  # Inline (rather than a separate pkgs.writeShellScript derivation) so this
  # activation check is just one more fragment of the same stitched-together
  # activation bash script every other system.activationScripts.*.text is —
  # nothing here needs its own store path.
  capacityCheckText = ''
    declaredThreads=${toString capacity.cpuThreads}
    declaredMemGiB=${toString capacity.memoryGiB}

    actualThreads=$(${pkgs.coreutils}/bin/nproc --all 2>/dev/null)
    actualMemKiB=$(${pkgs.gawk}/bin/awk '/^MemTotal:/ { print $2 }' /proc/meminfo 2>/dev/null)

    if [ -z "$actualThreads" ] || [ -z "$actualMemKiB" ]; then
      echo "homelab capacity check: could not read /proc; skipping." >&2
    else
      actualMemGiB=$(( actualMemKiB / 1024 / 1024 ))

      if [ "$actualThreads" != "$declaredThreads" ]; then
        echo "WARNING: homelab.host.capacity.cpuThreads is $declaredThreads but this machine reports $actualThreads (nproc). hosts/*/host.nix may have been copied from a different box without updating capacity." >&2
      fi

      # MemTotal excludes some reserved/firmware regions, so allow 2 GiB
      # slack before warning instead of demanding an exact match.
      memDiff=$(( actualMemGiB > declaredMemGiB ? actualMemGiB - declaredMemGiB : declaredMemGiB - actualMemGiB ))
      if [ "$memDiff" -gt 2 ]; then
        echo "WARNING: homelab.host.capacity.memoryGiB is $declaredMemGiB but this machine reports ~$actualMemGiB GiB (/proc/meminfo). hosts/*/host.nix may have been copied from a different box without updating capacity." >&2
      fi
    fi
  '';
in
{
  options.homelab.tiers = mkOption {
    type = types.attrsOf tierSubmodule;
    default = { };
    description = ''
      Resource shares per tier, as fractions of homelab.host.capacity — never
      absolute gigabytes or CPU indices, so the same config is portable to a
      different host. Resolved into systemd.slices by this file.
    '';
  };

  config = mkMerge [
    {
      # homelab.tiers itself is this module's own option, not a NixOS
      # derivation surface -- setting its defaults doesn't touch the closure,
      # so it (and the assertion computed from it) stays unconditional. This
      # is also what lets the budget assertion below still fire with
      # enforce.slices = false.
      homelab.tiers = lib.mapAttrs (_: v: {
        memoryShare = mkDefault v.memoryShare;
        cpuShare = mkDefault v.cpuShare;
        ioWeight = mkDefault v.ioWeight;
        nice = mkDefault v.nice;
      }) tierDefaults;

      # Evaluation-time only -- costs nothing in the closure -- so it runs
      # unconditionally, independent of homelab.enforce.slices (enforce.nix).
      assertions = [
        {
          assertion = totalMemoryShare <= 0.9;
          message = ''
            homelab.tiers: memoryShare must sum to <= 0.9 across all tiers
            (critical + interactive + background + batch), leaving headroom
            for the kernel and anything running outside a tenant slice. Got
            ${toString totalMemoryShare}.
          '';
        }
      ];
    }

    # The actual slice/scheduling effect, PLUS the activation-time capacity
    # check. The capacity check isn't one of the four named enforce switches,
    # but it writes system.activationScripts.homelabCapacityCheck -- a real
    # closure change (a new script in the activation stitching) that doesn't
    # exist on ac-box today, same as systemd.slices and the per-unit
    # Slice=/Nice= overrides. It exists purely to warn when the capacity
    # figures the slice math is built on (homelab.host.capacity) have drifted
    # from what /proc reports, so it's meaningless without the slices it's
    # validating -- there is no fifth enforce flag for it (the option set is
    # pinned to exactly firewall/slices/scrape/inventory), and bundling it
    # under enforce.slices is a closer fit than either adding a flag or
    # shipping it unconditionally, which would break closure-identity with
    # ac-box before any switch is flipped.
    #
    # mkIf, not an always-present attrset with a conditional body: an mkIf
    # false contributes NOTHING to systemd.slices / systemd.services /
    # system.activationScripts -- not an empty attrset -- see tests/
    # eval-resources.nix's allFalse case.
    (mkIf cfg.enforce.slices {
      systemd.slices = lib.mapAttrs mkSlice cfg.tiers;

      systemd.services = unitServiceConfigs;

      # Deliberately excluded from slice assignment, and said out loud. These
      # units keep running in system.slice; they are protected by background and
      # batch being fenced off their cores, not by being confined themselves.
      # The tier model fences systemd units. It cannot fence Docker containers,
      # and that is not a bug in this file -- container cgroup placement is
      # decided by dockerd, not by the cgroup of whoever invoked docker. A
      # container started from an SSH session (user.slice) still lands in
      # system.slice, a sibling of any invoking unit rather than a child of its
      # slice. So a Docker-based tenant in a fenced tier looks protected here
      # while its actual workload runs unconstrained.
      #
      # The fix lives in the tenant's own compose file, as
      # `cgroup_parent: <tier>.slice` on each service, which makes the container
      # inherit this slice's AllowedCPUs and MemoryMax. Verified on ac-box:
      # --cgroup-parent=batch.slice yields cpuset 28-55, without it 0-55.
      #
      # Warned rather than asserted: the contract cannot see another repo's
      # compose file, so it can flag the risk but must not claim to know whether
      # it was handled.
      warnings = lib.optional (dockerTenantsInFencedTiers != [ ]) ''
        homelab: these tenants declare needsDocker and sit in a CPU-fenced tier,
        but a slice cannot constrain Docker containers on its own:
          ${lib.concatStringsSep "\n          " dockerTenantsInFencedTiers}
        dockerd places container scopes under system.slice regardless of which
        slice started them, so the containers run unfenced unless the tenant's
        own compose file sets `cgroup_parent: <tier>.slice` per service. Slicing
        the unit that runs docker-compose is NOT sufficient.
      '' ++ lib.optional (nonServiceUnits != [ ]) ''
        homelab: these declared units are not .service units, so Slice= cannot
        apply to them and they were skipped:
          ${lib.concatMapStringsSep "\n          " (u: u.unit) nonServiceUnits}
        A .timer runs no processes of its own; the service it activates is what
        needs the slice.
      '' ++ lib.optional (unsliceableUnits != [ ]) ''
        homelab: these units are intentionally NOT assigned a slice, because
        Slice= only takes effect on unit start and restarting them is harmful:
          ${lib.concatStringsSep "\n          " unsliceableUnits}
        They remain in system.slice. The tiering guarantee does not depend on
        confining them -- background and batch are fenced away from the cores
        they use via AllowedCPUs.
      '';

      system.activationScripts.homelabCapacityCheck = {
        text = capacityCheckText;
        # Read-only check; doesn't need to run relative to any other script.
        deps = [ ];
      };
    })
  ];
}
