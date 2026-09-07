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
  inherit (lib) mkOption types mkDefault;

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

  # Every (unit, tier) pair a tenant declares, flattened so unit names can be
  # turned into systemd.services.<unit>.serviceConfig entries. Unit names are
  # taken verbatim from homelab.tenants.<name>.units — this file assigns them
  # to a slice, it never renames them (README: "Unit and container names
  # never change").
  tenantUnitTiers = lib.flatten (lib.mapAttrsToList
    (_: tenantCfg: map (unit: { inherit unit; tier = tenantCfg.tier; }) tenantCfg.units)
    enabledTenants);

  unitServiceConfigs = lib.listToAttrs (map
    (u: lib.nameValuePair u.unit {
      serviceConfig = {
        Slice = "${u.tier}.slice";
        Nice = cfg.tiers.${u.tier}.nice;
      };
    })
    tenantUnitTiers);

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

  config = {
    homelab.tiers = lib.mapAttrs (_: v: {
      memoryShare = mkDefault v.memoryShare;
      cpuShare = mkDefault v.cpuShare;
      ioWeight = mkDefault v.ioWeight;
      nice = mkDefault v.nice;
    }) tierDefaults;

    systemd.slices = lib.mapAttrs mkSlice cfg.tiers;

    systemd.services = unitServiceConfigs;

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

    system.activationScripts.homelabCapacityCheck = {
      text = capacityCheckText;
      # Read-only check; doesn't need to run relative to any other script.
      deps = [ ];
    };
  };
}
