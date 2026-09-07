# ADR 0005: Docker-based tenants must set cgroup_parent themselves

**Status:** Accepted
**Date:** 7 September 2026

## Context

Phase 6 turned on `enforce.slices`, which assigns systemd units to a tier slice
carrying derived `MemoryMax`, `CPUWeight` and — for `background` and `batch` — an
`AllowedCPUs` fence keeping them off the cores `critical` uses.

Verifying it at runtime rather than in unit files showed that only half the
tenancy was covered:

| Fenced | Not fenced |
| --- | --- |
| arcade — 2 native systemd units | assetto — 13 Docker containers |
| observability — 8 native systemd units | ci — 2 Docker containers |

`assetto` being unfenced is deliberate: it is `critical`, which is defined as
yielding to nothing. `ci` being unfenced was not deliberate, and it is the
workload most likely to consume the whole machine — a `nix build` in the
Buildkite agent, whose effective cpuset measured `0-55`.

The plan of record said the fix was to bring the CI stack under systemd so the
contract could assign it to `batch.slice`. That plan does not work.

## The mechanism

Container cgroup placement is decided by **dockerd**, not by the cgroup of
whoever invoked `docker`. The evidence was already on the box: the CI containers
are started by a human from an SSH session, which lives in `user.slice`, yet they
sit in `system.slice/docker-<id>.scope`. Container scopes are **siblings** of any
invoking unit, not children of its slice.

So wrapping a compose stack in a systemd unit and slicing *that unit* fences
nothing. Confirmed alongside it: `daemon.json` sets no `cgroup-parent` (dockerd
defaults to `system.slice`), no container sets `CgroupParent` or `CpusetCpus`, and
no compose file used `cgroup_parent`, `cpuset`, `cpu_shares` or `cpus`.

## Decision

A Docker-based tenant fences its own containers, by setting
`cgroup_parent: <tier>.slice` on each compose service. The slice already carries
the tier's derived limits, so the container inherits them rather than restating
them.

Verified on ac-box before adopting it (systemd cgroup driver, cgroup v2):

```
docker run --rm --cgroup-parent=batch.slice alpine \
  cat /sys/fs/cgroup/cpuset.cpus.effective    ->  28-55
docker run --rm                        alpine \
  cat /sys/fs/cgroup/cpuset.cpus.effective    ->  0-55
```

Rejected alternatives:

- **`cpuset:` per service.** Works, but hardcodes a CPU range in a tenant repo,
  duplicating what the tier already derives from host capacity. It would silently
  go stale the moment shares or the host changed — the exact failure mode the
  shares-not-absolutes decision in ADR 0002 exists to prevent.
- **`dockerd --cgroup-parent`.** Global, so it would fence *every* container on
  the box including the race servers. Wrong for a host whose critical tenant is
  containerised.

`resources.nix` warns when a tenant declares `needsDocker` and sits in a fenced
tier, naming it. A warning rather than an assertion, because the contract cannot
see another repo's compose file: it can flag the risk honestly but must not claim
to know whether the tenant handled it.

## Consequences

`cgroup_parent` applies at container **creation**. Existing containers keep their
placement until recreated, so adopting this is a behaviour change, not a config
change — and recreating the Buildkite agent kills the process that deploys this
box, so it must be applied from a plain SSH session rather than through a
pipeline step running on the agent.

The tier model's guarantee is therefore narrower than first described, and the
plan artifact overstated it: **slices constrain systemd services; containers are
constrained only where their tenant opts in.** Any future containerised tenant
inherits this obligation, which is why the warning names tenants rather than
living only in this document.

`batch.slice` also imposes `MemoryMax` (~25 GiB on ac-box). If a CI build ever
OOMs, the number to revisit is the tier share in `hosts/<host>/host.nix`, not a
literal in the compose file.
