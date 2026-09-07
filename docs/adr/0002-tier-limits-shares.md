# ADR 0002: Tier Limits Are Shares of Declared Capacity

**Status:** Accepted

## Context

Resource limits can be expressed in two ways:

1. **Absolute:** "This tenant gets 32 GB of RAM and 8 CPU cores." The limit is a hard number independent of the machine.
2. **Share-based:** "This tenant gets 20% of the declared capacity." The limit scales with the machine's actual resources.

Share-based limits are portable. If the configuration declares "critical tier gets 50% of capacity," it works on an HP Z840 with 56 threads and 251 GB, and it also works if you move the system to a smaller machine — you only edit `hosts/<new-name>/host.nix` to declare the new capacity, and all the shares re-scale automatically.

Absolute limits require editing the tier configuration every time you move the host or upgrade hardware. If you copy `hosts/ac-box/host.nix` to a smaller machine and forget to update the CPU and memory fields, you overcommit and the platform silently fails.

## Decision

Tiers are always expressed as shares of `homelab.host.capacity`. This repo declares `capacity.cpuThreads = 56` and `capacity.memoryGiB = 251` for ac-box. Tier configuration expresses limits relative to these totals, not as absolute values.

The primary mechanism for CPU shares is systemd `CPUWeight`. This parameter sets the proportion of CPU time a slice receives when the system is busy, while still allowing idle capacity to be used by any tenant. A slice with `CPUWeight=100` and a slice with `CPUWeight=400` get CPU time in a 1:4 ratio when both are running, but if one is idle, the other can burst and use the free cores.

The `AllowedCPUs` parameter is used only to fence `background` and `batch` tiers *away from* the cores that `critical` tier uses. It is not used to hard-cap any tier's CPU. A limit like `AllowedCPUs=0-31` says "don't run on cores 32-55," not "you get cores 0-31 exclusively and nothing more." Other tiers can still use cores 0-31 when critical is not using them.

Memory limits are set using systemd `MemoryLimit` and `MemoryHigh`, also expressed as shares of declared capacity, never as absolute gigabytes.

## Consequences

**Positive:**
- The configuration survives a hardware upgrade. You edit only `hosts/ac-box/host.nix` and everything re-scales.
- You can test the configuration on a smaller machine (or in a VM) by editing the capacity fields. No other changes needed.
- Fair allocation is explicit. Reading the tier config tells you exactly what proportion of resources each workload receives.

**Negative:**
- You must remember to edit `hosts/ac-box/host.nix` accurately. If the capacity values are wrong (too high), systemd does not warn you — it trusts your numbers and overcommits.
- CPU bursting is less predictable than hard caps. In peak load, a tenant with a low weight may get unpredictably starved. If a tenant has hard CPU requirements, this model may not fit.
- There is no per-container memory hard-cap today. Docker's `memory` limit is set at the compose file level, but the overall `interactive` tier shares its allocation across multiple containers. One container cannot accidentally exhaust the tier.

**Validation:**
- Before activation, `nixos-rebuild` warns if the capacity values fall below the configured tier limits. A tier sum exceeding 100% of capacity is a configuration error.
- After activation, `systemctl show -p CPUWeight,AllowedCPUs,MemoryLimit <unit>` shows what each slice received.
