# Cutover Runbook: ac-box System Plane Migration

This runbook covers the atomic migration of ac-box's system plane onto the homelab platform repo. The operation is all-or-nothing by design; the first rebuild must change nothing, and that must be proven before execution.

## Governing Constraint

A NixOS host has exactly one system closure at any moment. The entry-point switch is atomic: every file, service, module, and closure reference either all activate together or none do. There is no partial rollout and no "just restart the affected units" escape hatch. Therefore:

- The first switch must not alter any observable behavior.
- The first switch must change nothing that can be detected.
- Both must be proven with closure diffs and dry-run reports before the human presses enter.

If the first switch changes anything — a dropped service, a restarted container, a changed firewall rule, a different Prometheus scrape interval — and then a subsequent rebuild introduces a bug, you cannot unwind to "the state before we started this cutover." You are already cut over.

## Three Sequential Gates

All three gates must pass in order. If any gate fails, abort immediately using the abort ladder below. Do not proceed to the next gate.

### Gate 1: Equivalence

Prove that the homelab config generates an identical closure to the current system.

**Command:**
```bash
nix build .#nixosConfigurations.ac-box.config.system.build.toplevel
```

**Comparison:**
```bash
nix store diff-closures /run/current-system ./result
```

> **WARNING — gate 1 alone is not sufficient, and gives false confidence.**
> `diff-closures` compares *package sets*: what was added, removed, or changed
> version. It does **not** compare file contents. Run live on 7 Sep 2026 it
> reported **completely clean output** while seventeen files differed between the
> two systems — including `ac-host-static.service`, the one unit whose restart
> runs `docker rm -f` and destroys the race containers.
>
> A clean gate 1 means "no packages changed". It does not mean "nothing changed".
> Never switch on gate 1 alone; gate 2 is the gate that actually protects you.
> To see file-level differences, compare the trees directly:
>
> ```bash
> diff -rq /run/current-system/etc <new-system>/etc
> ```

**Acceptance criterion:** no *substantive* differences. Expect literally zero output in the ideal case, but the following are permissible and do not block:

- the NixOS version label / `configurationRevision`, which embeds the flake revision and therefore always differs once the config comes from a different repo;
- the system derivation's own name.

Anything else blocks. In particular, a changed store path for `docker`, `containerd`, any `acServer` image reference, any unit file, or any package version means the two configurations are not equivalent. Do not proceed. Investigate which modules or options diverge, reconcile them in the repo, rebuild, and rerun the diff.

Do not weaken this criterion to make a window happen. "Zero differences" is not the bar because it is unachievable; "nothing that changes a running service" is the bar, and it is achievable.

The most common divergences: missing modules (L0 or L2), dropped ports, or a nixpkgs mismatch between the host channel (`nixos-26.05`) and what a tenant flake dragged in — see the `follows` rule in README.md.

### Gate 2: Blast Radius

Prove that the switch will not restart or stop any critical services.

**Command (from a plain SSH session, NOT through Buildkite):**
```bash
sudo ./result/bin/switch-to-configuration dry-activate
```

**Acceptance criteria:**

- `docker.service` must NOT appear in the activation summary's "stopping" or "restarting" list. If it does, the operation will tear down all 13 running containers, including the Buildkite agent itself.
- `ac-host-static.service` must NOT appear in the activation summary's "stopping" or "restarting" list. This is a oneshot unit with an `ExecStop` that runs `docker rm -f`. Restarting it deletes the three live race server containers (Assetto Corsa lobby instances). A human can restart races manually post-cutover if needed, but this is not a service that should restart during a system transition.

If either service appears in the stopping or restarting list, abort. Do not run the actual switch. The dry-activate output tells you exactly which module or option is causing the restart; fix it, rebuild, and rerun dry-activate.

**Why not use Buildkite for this step?** The Buildkite agent runs inside a Docker container on ac-box. If the dry-activate reports that docker.service will restart, running the actual switch through the same agent would be executing the very failure you are testing to prevent. Run this from a plain SSH session to the box.

### Gate 3: Observable Surface

Prove that the observable system surface has not changed before or after the switch. Capture key metrics before, capture them after, and compare.

**Before switch (at T−15m):**
```bash
ssh ac-box 'ss -tlnp' > /tmp/ac-box-sockets-before.txt
ssh ac-box 'docker ps' > /tmp/ac-box-docker-before.txt
ssh ac-box 'systemctl list-units --type=service --state=running' > /tmp/ac-box-units-before.txt
ssh ac-box 'curl -s localhost:9090/api/v1/targets' > /tmp/ac-box-prometheus-targets-before.json
```

**After switch (at T+2m):**
```bash
ssh ac-box 'ss -tlnp' > /tmp/ac-box-sockets-after.txt
ssh ac-box 'docker ps' > /tmp/ac-box-docker-after.txt
ssh ac-box 'systemctl list-units --type=service --state=running' > /tmp/ac-box-units-after.txt
ssh ac-box 'curl -s localhost:9090/api/v1/targets' > /tmp/ac-box-prometheus-targets-after.json
```

**Acceptance criterion:** Diff the before and after captures. Expect the output times to differ and perhaps one or two timestamp fields in the Prometheus targets, but expect NO new or missing listening ports, NO new or removed Docker containers, NO new or stopped units, and NO new RED (unhealthy) targets in Prometheus.

If any of these change, the system plane migration has introduced an observable difference despite passing gates 1 and 2. The difference is likely subtle — a changed network namespace, a dropped systemd dependency, a shifted cgroup limit — but it must be investigated before returning to normal operations.

### Gate 3b: Functional Verification

At T+10m, join a lobby and drive a lap. The sidecar auth path is the one thing no closure diff or dry-activate output can verify. This is the only genuine functional test that matters for the racing platform:

- Can you spawn a lobby?
- Can you place a driver in the lobby?
- Can the lap timer record your telemetry?
- Can you quit and end the session without orphaning containers or stranding the instance?

If any of these fail, the auth flow or the container lifecycle has regressed. Investigate and roll back.

## Rollback GC Root: Pinning the Previous Generation

Before making any change, pin the current running system so `nix.gc` does not delete it.

The platform runs `nix.gc` with `--delete-older-than 7d` on a weekly schedule. Without a GC root, the current closure becomes a deletion candidate the moment the new closure is activated. If the new system has a bug and you need to fall back within a week, the old closure is gone and you cannot use the boot menu to rollback.

**Already done** — pinned on 7 Sep 2026, before any of this began:
```bash
nix-store --add-root /nix/var/nix/gcroots/pre-homelab -r $(readlink -f /run/current-system)
```

Note the absence of `--indirect`. A symlink placed *inside* `/nix/var/nix/gcroots/` is a **direct** root, which Nix finds by scanning that directory; `--indirect` is for roots living elsewhere (like a `./result` symlink), which get registered via `gcroots/auto/`. Passing `--indirect` for a path already under `gcroots/` is the wrong form. The command above is the one that was actually run and verified.

Verify a root is real rather than assuming it — creating the symlink is not proof that Nix honours it:
```bash
nix-store --gc --print-roots | grep pre-homelab
```

Currently protecting:
```
/nix/var/nix/gcroots/pre-homelab -> /nix/store/52rfi2kgix05hmyawfz4wj04pngcfn82-nixos-system-ac-box-26.05.20260829.c5c4a43
```

It will survive `nix.gc --delete-older-than 7d` and reboots for as long as the symlink exists.

## Recorded Baseline

Captured 7 Sep 2026 with no races running, into `.cutover/` (gitignored — regenerate per attempt, diff the raw files). The summary is recorded here so the provenance survives even if the raw captures do not:

| | Baseline |
|---|---|
| Closure | `52rfi2kgix05hmyawfz4wj04pngcfn82-nixos-system-ac-box-26.05.20260829.c5c4a43` |
| Containers | 13 |
| Running services | 28 |
| Listening sockets | 46 lines of `ss -tulnp` |
| Prometheus targets | 5, all `up`: cadvisor, docker-names, node, udr-fw, unpoller |
| `NRestarts` | `0` for docker, ac-host-static, arcade-freeciv, arcade-mindustry |

The `NRestarts` row is the load-bearing one. After the switch, those four counters must still read `0` — a non-zero value on `ac-host-static` means its `ExecStop` ran `docker rm -f` and the race servers were destroyed and recreated, which is the exact failure gate 2 exists to prevent.

One measurement trap worth recording: `before.prometheus.json` is a single line with no trailing newline, so `wc -l` reports `0` on a file that holds 2.6 KB. Check these captures with `wc -c`, not `wc -l`, or you will conclude a capture failed when it did not.

**After a successful cutover,** you can remove the root if you are confident the new system is stable:
```bash
rm /nix/var/nix/gcroots/pre-homelab
```

Do not remove it immediately. Wait at least one week of normal operation before cleaning up. If a regression appears in day 3, you can still rollback to the pinned closure using the abort ladder.

## Timeline: T−7d to T+10m

Cutover happens during the 03:00 maintenance window, a ritual the Discord community already understands. This is the only window when dropping all containers is not a breach of the service contract.

| Time | Actor | Action | Gate |
|------|-------|--------|------|
| T−7d | Operator | Announce cutover in Discord with the standard 03:00 ritual countdown. Reserve calendar time. | |
| T−2d | Operator | Verify gate 1 (equivalence) passes locally in WSL or on the box. | Gate 1 |
| T−1d | Operator | Verify gate 1 passes again. If it fails, cancel the cutover window. Do not proceed past this point if gate 1 does not pass. | Gate 1 |
| T−1h | Operator | Freeze the content plane. No new races, no config changes to tenants, no new Discord bot deployments. Content and system changes do not travel in the same window. | |
| T−15m | Operator | Run `nix-store --add-root` to pin the rollback root. Capture observable surface before. | Gate 3 (before) |
| T−5m | Operator | SSH to ac-box (plain session, not Buildkite). Run `sudo ./result/bin/switch-to-configuration dry-activate`. | Gate 2 |
| T−0 | Operator | Run `sudo nixos-rebuild switch --flake github:imkarrer/homelab#ac-box`. Use `switch`, never `boot` or `reboot`. A reboot drops every tenant and requires console access if boot fails. | |
| T+2m | Operator | Capture observable surface after. Diff before and after. | Gate 3 (after) |
| T+10m | Operator | Join Discord, spawn a lobby, drive a lap. Verify auth and container lifecycle. | Gate 3b |

## Abort Ladder: Three Ways to Undo

If at any point before T+0 you decide to abort, do nothing. The system is unchanged. Cancel the window and reschedule after fixes.

If you discover a problem during gate 2 (dry-activate) or gate 3 (observable surface), abort immediately using the first method:

**Method 1: Immediate rollback (within the cutover window)**
```bash
sudo nixos-rebuild switch --rollback
```

This activates the previous generation without a reboot. You are back to the pre-cutover state in under 30 seconds.

**Method 2: Boot menu rollback (if the switch hangs, or the box boots but does not reach a usable state)**

ac-box uses **systemd-boot**, not GRUB — there is no `e`-to-edit prompt. Reboot, and at the systemd-boot menu use the arrow keys to select an older `NixOS` generation entry, then Enter. `boot.loader.systemd-boot.configurationLimit = 5`, so five generations are listed. This method needs physical or IPMI console access; it is not available over SSH, which is the reason gate 2 exists and the reason T−0 uses `switch` rather than `boot`.

**Method 3: GC root rollback (if the weekly `nix.gc` has already collected the previous generation)**

If days have passed, `nix.gc --delete-older-than 7d` has run, and the immediately-previous generation is gone, the pinned root is still there:
```bash
sudo /nix/var/nix/gcroots/pre-homelab/bin/switch-to-configuration switch
```

The GC root is a symlink directly to the pre-cutover system closure, so nothing needs rebuilding or realising first — activate it in place. Note this activates the old system without registering it as a new generation; follow up with a real `nixos-rebuild switch` against a corrected config once you have one.

## One-Way Doors: Keep These Out of Cutover Night

Do not attempt these changes during the cutover window. They require data migrations or have downstream effects that cannot be undone by closing a generation.

| Change | Why it is a one-way door | When to do it |
|--------|--------------------------|---------------|
| Rename `ac-host` to `assetto` | The Buildkite pipeline slug (`isaac-karrer/ac-host`), its GitHub webhooks, and the CI agent's checkout path all encode the current name. This is the phase 7 rename, and it is code-only — see ADR 0003 on why `/var/lib/ac-host` stays regardless. | After phase 6, in its own change. |
| Move `/var/lib/ac-host` | This is where Assetto races, series, content, and the player whitelist live. Moving the directory requires a data migration: rsync or a custom script that remaps references. Once you cut over, you cannot atomically move the data to a new location and rollback — the new system refers to the new path, and you cannot downgrade the reference. | Plan a data migration window separately, after system stability is proven. |
| Rename the Docker Compose project | Docker orphans the 13 running containers if the project name changes. They continue to consume memory and network resources under the old names. The rebuild orphans them, but you must still `docker rm` them manually or lose disk and network capacity. | Never rename mid-cutover. Document the current project name and keep it stable. If renaming is needed, do it months later after a deprecation period. |
| Rename a Docker container | `docker_name_exporter.py` maps container names to Grafana dashboards. Renaming a container breaks the dashboard until the exporter and Grafana are updated. The new dashboards will show no data, the old dashboards will vanish. | Document the current names (Buildkite already has them). Renaming containers is a data-plane change that can happen after system cutover, but only after the exporter, Prometheus, and Grafana are updated to the new names. |
| Lift the observability module | The `observability` module references `../scripts/docker_name_exporter.py` and `../scripts/udr_fw_exporter.py`. If you lift observability to a separate flake input, those script paths break. The scripts must be migrated with the module, or inlined, or moved to a separate package. | Keep observability in the repo for now. If lifting is needed later, move the scripts first, update the references, then lift the module. |

## Cutover Success Criteria

You have successfully cut over when:

1. `readlink -f /run/current-system` points at the closure you built and diffed in gate 1 — not at something rebuilt from another source. (Comparing `/run/current-system` to `/nix/var/nix/profiles/system` proves nothing after a switch: they are the same thing by definition.)
2. `systemctl show -p NRestarts docker.service` is unchanged from the value you captured before the switch.
3. `ac-host-static.service` is in the same state it was before, and its `ExecStop` has not run — check with `journalctl -u ac-host-static.service --since "-15 min"`, which must show no `docker rm -f`.
4. `docker ps` shows the same 13 container names as `/tmp/ac-box-docker-before.txt`, with uptimes that predate the switch.
5. All Prometheus targets report `up`, matching the before capture.
6. You drove a lap and the telemetry was recorded.

Condition 4 is the one that catches the failure this whole runbook exists to prevent: if the containers came back but their uptimes reset, `ac-host-static` was bounced and the race servers were destroyed and recreated, losing session state.

Do not return to normal operations until all six conditions are met.

## Phase 1 Result — 7 September 2026

Both gates run against `github:imkarrer/homelab` at commit `46500af`+, built on the box.

**Gate 1** (`diff-closures`): clean — and, as the warning above records, misleadingly so.

**Gate 1a** (`diff -rq .../etc`): seventeen files differ. All four significant ones are understood:

| File | Difference | Verdict |
| --- | --- | --- |
| `ac-host-static.service` | `+TimeoutStartSec=15min` | A fix that has been sitting in git while the box ran without it. Desirable. |
| `arcade-mindustry.service` | `ExecStart` store path | The stdin-piping fix. The box's copy passes startup commands as argv, which is why the server reports active and never binds 6567. Desirable. |
| `journald.conf` | leading indentation only | `SystemMaxUse=200M` and `MaxRetentionSec=14day` present in both. Semantically identical. |
| `grafana.service` | unit-script store path | Wrapper path only; no option difference found. |

**Gate 2** (`switch-to-configuration dry-activate`):

```
would stop: arcade-mindustry.service, grafana.service, systemd-tmpfiles-resetup.service
would NOT stop the following changed units: ac-host-static.service
would reload: dbus-broker.service
would restart: systemd-journald.service
would start: arcade-mindustry.service, grafana.service, systemd-tmpfiles-resetup.service
```

Acceptance criteria satisfied:

- `docker.service` — absent from the output entirely. The 13 containers are untouched.
- `ac-host-static.service` — changed, but listed under *would NOT stop*. The module carries `stopIfChanged = false`, which is what its "never bounce this on nixos-rebuild" comment implements. **The race containers survive the switch.**

Actual service impact, all on drainable tenants: Mindustry stops and starts (and begins working for the first time), Grafana blinks, `systemd-tmpfiles-resetup` and a journald restart are routine.

So phase 1 is **proven**, with the caveat that "no-op" is not literally true — two deliberate fixes ride along, both on drainable units. Given no races are running, this is the moment the switch is cheapest.
