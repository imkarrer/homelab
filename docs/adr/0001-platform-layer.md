# ADR 0001: Platform Layer Sits Above Tenants

**Status:** Accepted

## Context

Before this repo existed, the host configuration lived inside the oldest workload — the Assetto Corsa racing tenant. That tenant owned the NICs, the Docker daemon, the boot configuration, the Nix toolchain, and the sshd instance. Six workloads depended on decisions made inside that one tenant's flake.

This tight coupling makes it hard to:
- Reason about what is platform-critical versus what is workload-specific.
- Add or remove tenants without touching host code.
- Share resources (network, CPU, memory, secrets) with a clear ownership model.
- Verify that removing one tenant does not break the others.

## Decision

Platform code (hardware, NICs, identity, boot, Nix, sshd, the Docker daemon itself) moves into `modules/platform/` in this repo. Tenants move into layer 3 as flake inputs. The new homelab repo becomes layer 0, the single source of truth for what runs on the box.

The layering is strict and one-way:
- L0 (`modules/platform/`) owns hardware and services. It knows nothing about tenants.
- L1 (`modules/tenant/`) declares the contract (port claims, resource limits, state paths, metrics endpoints). It has no derivation logic.
- L2 (`modules/observability/`, `modules/ci/`) consumes the contract; both are in this repo.
- L3 (flake inputs: `assetto`, `arcade`, `agent-hub`) declare their needs against the contract without knowing their neighbors.

Dependency direction is one-way downward. L0 never imports L1-L3. L1 is always imported before L2 and L3.

## Consequences

**Positive:**
- The platform is portable. Adapting to a different box is a new `hosts/<name>/host.nix` and a tenant choice, with no wholesale rewrites.
- Resources are allocated fairly. All tenants speak the same language: port claims, tier declarations, and metrics paths.
- The racing tenant no longer owns the host. The Assetto flake is smaller and easier to reason about.
- CI and observability can read the tenant declarations without being deep-copied into every tenant's flake.

**Negative:**
- This repo becomes the coordination point. Merging changes requires understanding how they affect all six tenants.
- Every change to L0 or L1 must be validated against all downstream tenants. Testing is local (nix flake check, nix build) but deployment is atomic.
- The first system cutover is complex (see `docs/runbook-cutover.md`). You cannot gradually migrate; the system closure flips all at once.

**Migration burden:**
- The Assetto flake loses ownership of the host but keeps ownership of the racing platform logic, the race database, and the Discord bot.
- The Arcade and LLM tenants move their systemd services and Nix code into declarations here.
- The CI and observability modules move from Assetto into this repo as L2.
