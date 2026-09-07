# ADR 0003: State Paths Are Preserved Across Renames

**Status:** Accepted

## Context

Renaming is handled differently depending on what is being renamed:

1. **Code:** `ac-host` is the Assetto Corsa racing tenant. The flake, the modules, the code might be renamed to `assetto` for clarity. This is a commit.
2. **State:** `/var/lib/ac-host` is where races are stored, series are stored, player whitelists are stored, and transient race data is kept. This is where the platform calls home.

If you rename the code from `ac-host` to `assetto` but move `/var/lib/ac-host` to `/var/lib/assetto`, you break continuity. Old races are now invisible. The player whitelist is lost. The database schema in the old location is orphaned.

Data migrations are not atomic. You cannot roll back by switching a NixOS generation. Moving the directory requires a separate operational window: stopping races, migrating the data, verifying the new location is readable and consistent, then bringing services back online. If the migration fails partway through, you need the old location intact as a fallback.

## Decision

State paths stay pinned to their current locations even if the code is renamed.

The tenant contract allows explicit path configuration. The default state path is `${homelab.host.paths.state}/<tenant-name>` (e.g., `/var/lib/assetto`), but the Assetto tenant explicitly claims `/var/lib/ac-host`. This declaration stays in place.

If the code is renamed from `ac-host` to `assetto`, the configuration still specifies `homelab.tenants.assetto.state = { dirs = ["/var/lib/ac-host"]; };`. The code changes, the path does not.

## Consequences

**Positive:**
- State survives code refactors. Renaming the module or the flake input does not lose history.
- Rollbacks work correctly. If you activate an old generation, the old code still knows where to find the state because the path is explicit.
- Data migrations are deliberate. You do not accidentally break continuity because a code change renamed a reference.

**Negative:**
- The state path may not match the current code name. This is confusing at first but becomes clear when you understand that state is kept, not tidied.
- Renaming a directory requires a separate operational window with explicit steps: stop the workload, migrate the data, verify the new location works, resume. It is not a config change that can be included in a system cutover.

**Process for moving state:**
1. Announce the data migration window separately from any system changes.
2. Stop the affected tenant with `systemctl isolate rescue.target` or by stopping its slice.
3. Migrate the data: `rsync -avz /var/lib/ac-host /srv/assetto/` or `mv /var/lib/ac-host /var/lib/assetto` depending on filesystem boundaries.
4. Update the configuration to point to the new path: `homelab.tenants.assetto.state = { dirs = ["/var/lib/assetto"]; };`.
5. Rebuild and activate: `sudo nixos-rebuild switch`.
6. Verify the tenant can read the data in the new location.
7. Once stable, remove the old path if desired.

This is a separate task from system cutovers. Do not combine them.
