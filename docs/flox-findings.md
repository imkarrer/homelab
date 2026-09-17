# Flox findings

The dogfooding record for ADR 0009: one section per open question, filled in
from what each step of epic `homelab-158` actually did, with the commands and
their output — not from the pitch. A question is **answered** when the box
runs on the answer, **partial** when a WSL experiment settled part of it, and
**open** when nothing has been tried. Where a docs claim could not be
verified it is marked as such rather than repeated as fact.

Environment for the WSL experiments: flox `1.14.1-gaad7ad2` (bundled nix
2.31.5, process-compose 1.94.0), 17 Sep 2026, **not logged in to FloxHub** —
so every `-r` / `push` / `pull` / `generations` behaviour on a managed
environment is either untested or a docs claim until an operator runs
`flox auth login` on this machine. The network was cut with
`unshare -U --map-user=1000 --map-group=100 -n` (proven: no interfaces, curl
exit 7, nix "could not resolve github.com"); `unshare -rn` maps to uid 0 and
sends flox looking in `/root`, so it is not a usable cut.

## 1. Deploy-time network dependency — partial

**Activation is offline-safe once the environment's store paths exist
locally; it is not offline-safe from a lock alone.**

- An environment activated once online activates again with the network dead
  in 52–88 ms, exit 0 — also after `rm .flox/run/*` (flox rebuilds the link
  from the lock without fetching).
- An environment with only `manifest.lock` present (what "pulled, never
  activated" looks like; produced with `flox lock-manifest`) fails offline,
  exit 1: `unable to download https://github.com/flox/nixpkgs/archive/….tar.gz`.
  One online activation fixes it permanently.
- Activation registers `.flox/run/<system>.<name>-{dev,run}` as nix GC roots
  (`/nix/var/nix/gcroots/auto/*`), so a warmed environment survives
  `nix-collect-garbage` while `.flox/run` stays.
- Every activation forks a background upgrade check that POSTs to
  `api.flox.dev/api/v1/catalog/resolve`; forced offline it logs
  `catalog error: Communication Error` and the activation still exits 0.
  Rate-limited through `.flox/cache/upgrade-checks.json`. Whether the
  `upgrade_notifications` config key disables the call is unverified.
- `flox activate -r owner/env` on a second run: needs login. The man page
  says it works from a cached copy; unverified.

**Consequence for the deploy edge (`homelab-158.3`):** the pull and the
activation are two steps. A pull unit fetches the generation *and activates
it once* (warming the store and pinning the GC roots) before the tenant's
stub is restarted; the stub's own `flox activate -- <binary>` then never
needs the network. flox.dev is a dependency of the *pull*, which may fail
soft and retry, and not of the 03:00 restart. This is the same split
`modules/deploy` makes between staging and applying.

## 2. `[services]` under systemd — partial (answered on WSL, not yet on the box)

**`flox activate -- <binary>` is what systemd can supervise. `[services]` is a
dev-shaped process manager.**

Process shape: flox `exec`s into the foreground command; a detached
`flox-activations executive` parents `process-compose`, which parents the
services and always includes a `flox_never_exit: sleep infinity` sentinel.

| Experiment | Result |
| --- | --- |
| `flox activate -- sh -c 'exit 7'` | exit 7; self-`SIGTERM` → 143. Plain passthrough. |
| `kill -TERM <flox pid>` during `--start-services -- sleep 60` | flox exits 143; process-compose and the services are gone within 2 s. |
| foreground command exits 0 under `--start-services` | flox exits 0; the executive tears the services down. |
| a service exits 7 while the activation runs | `flox services status` shows `Completed (7)`; **the activation neither exits nor changes its exit code.** No manifest option makes it. |
| `flox activate --start-services </dev/null`, no command (a unit's shape) | returns in 0 s in "in-place" mode; services start anyway and are reaped ~5 s later when the executive sees the caller gone. Not a usable unit. |

**Consequence for the stubs (`homelab-158.2`, `.5`):** one unit per process,
each `ExecStart=flox activate -d <env> -- <binary>`, several units sharing one
environment where a tenant has several processes (arcade: `arcade-freeciv`
and `arcade-mindustry`, which keeps both names). `Restart=`, exit codes, the
slice and the journal all see the real process. `[services]` stays for the
developer's shell.

**Product gap, stated plainly:** there is no way for a died service to be
visible to whatever started `flox activate --start-services`. An
`exit-on-failure` (or "no sentinel") mode would make `[services]` a
production shape; without it a supervisor cannot use it.

## 3. Which generation is running — partial

- For a **path environment** — which is what `flox pull --copy` produces —
  **nothing** records a generation: `.flox/env.json` is
  `{"name": …, "version": 1}`, `manifest.lock` has no generation field, and
  `flox generations *` refuses (`Generations are only available for
  environments pushed to floxhub`). The only identity is the content: the
  `.flox/run/<system>.<name>-run` store path and the per-package nixpkgs
  `rev` in the lock.
- For a **managed environment** the candidates are `flox generations list`
  and a floxmeta `metadata.json` with `currentGen` (strings in the binary);
  needs login to show.
- `flox pull -g N` exists and **must be paired with `--copy`**, which
  detaches the environment from upstream. `flox activate -g N` exists (docs);
  offline behaviour unverified.

**Consequence for `hub-status` (`homelab-158.4`):** the record of which
generation the box runs is *ours*, written by the pull unit beside the
environment (`generation`, `owner/env`, `pulled_at`, the run store path) the
way `last-applied-closure.json` is — flox does not provide one for the shape
we deploy. The run store path is the exact content check, as the closure's
store path is.

## 4. Secrets — open

## 5. Host facts in the manifest — open

## 6. Version coupling — open

WSL has 1.14.1; `scripts/hub-gates.sh` pins 1.14.0 for CI. Nothing broke in
the experiments above, but no lock written by 1.14.1 has been read by 1.14.0
yet.

## Beyond the six — from `homelab-158.1` (agent-hub as an environment, 17 Sep)

The manifest reproduces the live unit exactly: llama-swap in front of six
backends (three on the ik_llama.cpp fork, three on stable-diffusion.cpp),
same flags in the same order, proven on WSL with the production `embed`
model and a substitute coder. Three things the manifest could not say the
way the NixOS module says them:

- **A custom derivation is installable only as a flake reference or through
  `flox publish`.** `nix/ik-llama-cpp.nix` exists to turn BLAS *off* on a
  CPU host, which the fork's own flake turns on, so the manifest takes
  `ik-llama-cpp.flake = "github:imkarrer/agent-hub#ik-llama-cpp"` — this
  repo's own flake output. A `[build]` target cannot be installed into the
  same environment without publishing. Cost: the lock pins this repo's rev,
  so a change to `nix/*.nix` reaches the environment only after it is on
  GitHub *and* `flox upgrade` re-locks — two commits, in that order. The
  catalog's `llama-cpp` (9190…10408 on offer) was not used because the box
  serves the fork, not mainline.
- **`[vars]` clobbers the caller.** `FOO=caller flox activate` yields
  `FOO=from-vars` (1.14.0). So every host fact the stub must set — models
  dir, threads, ctx, listen address, backend port — lives in the `[hook]` as
  `: "${X:=default}"`, and `[vars]` is empty. Host facts (§5) therefore
  arrive by environment variable from the unit, which is the right
  direction, but the mechanism is a shell idiom rather than a manifest
  feature.
- **A FloxHub generation carries manifest and lock only.** The environment
  needs two repo files at run time (`llama-swap.yaml`, `nix/sd-ui.html`),
  so the box needs a checkout beside the environment, or those paths passed
  in — a decision for `.2`/`.3`. A generation is an environment, not a
  release of the tree.

Also settled: the lock written by flox 1.14.0 is read by 1.14.1 unchanged
(§6, first data point), and the second activation with the network cut took
76 ms and fetched nothing (§1, confirmed on a real environment). The store
path of the fork's `llama-server` differs between the environment and the
closure — same source and options, different nixpkgs `stdenv` — which is a
fact for the generation stamp (§3), not a bug.
