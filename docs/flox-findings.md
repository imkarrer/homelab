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

## 1. Deploy-time network dependency — answered (on the box, 18 Sep 2026; managed environments on WSL the same day)

**Managed environments** (FloxHub; full record in
[docs/spike-floxhub-managed-environments.md](spike-floxhub-managed-environments.md)):
a real `flox pull` builds the environment and registers its GC roots itself,
so a tracking pull activates offline at 128–175 ms with *no* prior online
activation — §1's failing "pulled, never activated" case was a
`lock-manifest` simulation, not a pull. `flox activate -r` also works
offline from `$XDG_CACHE_HOME/flox/remote/<owner>/<env>`, but it never
refreshes even online and prompts a non-owner about trust, so it is not a
unit shape. Pulling or activating a **public** environment needs no token.
The consequence for the pull unit: the build now happens *inside* `flox
pull`, so the substitute-only guard must read the generation's lock from
floxmeta (a bare git repo at `api.flox.dev/git/<owner>/floxmeta`, one
`<N>/env/manifest.lock` per generation) before pulling.

**On the box:** the first pull (08:53 CDT) substituted every path the lock
named from MinIO in 2 s, activated once online, and wrote the record; the
stub then started from the warmed checkout with no network. The one thing
the box did that WSL had not shown: flox realises the *whole* derivation of a
flake package, and `stable-diffusion-cpp`'s `-dev` output had never been
pushed (the plugin pushed the environment's closure, which links only
`out`), so nix built the derivation to produce it — three minutes at
`SCHED_BATCH` while the substitute-only step had reported success. Closed
from both sides the same morning: the plugin pushes every lock output
(`flox-buildkite-plugin` `a0cea9b`), the pull demands every lock output
(`a177338`). The product-side note: an environment's closure is not the
set of paths needed to activate it elsewhere; the lock's `outputs` is.

**Activation is offline-safe once the environment's store paths exist
locally; it is not offline-safe from a lock alone.**

- An environment activated once online activates again with the network dead
  in 52–88 ms, exit 0 — also after `rm .flox/run/*` (flox rebuilds the link
  from the lock without fetching).
- An environment with only `manifest.lock` present (what "pulled, never
  activated" looks like; produced with `flox lock-manifest`) fails offline,
  exit 1: `unable to download https://github.com/flox/nixpkgs/archive/….tar.gz`.
  One online activation fixes it permanently. For a FloxHub *tracking*
  checkout (`flox pull owner/name`, `.5`) a second thing must be local:
  the owner's floxmeta clone under `$HOME/.local/share/flox/meta/`. With
  it absent, even `flox activate -d` of a checkout whose run links exist
  tries to re-clone from api.flox.dev and fails offline (WSL, 18 Sep 2026,
  1.14.0). The pull unit checks for it before saying "already applied".
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

**Built (`homelab-158.3`, 17 Sep), awaiting the box:** the answer to
question 1 is the split above, implemented. `modules/tenant/environment-pull.nix`
is the pull unit: the tenant's CI stages a sha (not a FloxHub generation —
the environment reads two repo files at run time, "Beyond the six"), the
box checks it out as the tenant's user and runs `flox activate -d <dir> --
true` once, online, in the tenant's slice; the stub is restarted only after
that, and its own activation is the offline ~80 ms one. Three things the
build found that the WSL experiments had not:

- **The warm is a nix build when the box trusts no cache that has the
  path.** ac-box's `nix.conf` substitutes from cache.nixos.org and (since
  `97f0c00`) cache.flox.dev. agent-hub's two `.flake` packages
  (ik_llama.cpp, stable-diffusion.cpp) exist only in CI's MinIO bucket,
  which is loopback-only on the box and refuses anonymous reads
  (`GET /flox-binary-cache/nix-cache-info` → 403). So the first activation
  on the box compiles both through nix-daemon — in nix-daemon's cgroup,
  not the tenant's slice, on every core. Slicing the pull unit bounds the
  clone and the evaluation, not the build. Either the box gets the MinIO
  cache as a substituter (a platform trust decision like cache.flox.dev's)
  or the first warm is a one-time unfenced compile.
- **`flox activate` under a unit warns `Failed to detect shell from
  environment or parent process. Defaulting to bash`** (no `$SHELL`, parent
  is `setpriv`). Harmless; one line of journal noise per pull.
- **`--` with a command runs the hook.** `flox activate -d <dir> -- true`
  as the warm runs the manifest's `[hook]` with no `AGENT_HUB_*` set, so
  the hook's `: "${X:=default}"` lines fill in the tenant tree's defaults
  for that one process. Nothing is written by agent-hub's hook, so this is
  benign; a hook with side effects would run once with unreviewed values.

## 2. `[services]` under systemd — answered (on the box, 18 Sep 2026: arcade runs two stubs from one environment; agent-hub one)

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

## 3. Which generation is running — answered

**Managed environments (FloxHub), verified logged in:** `flox push` converts
a path environment in place — `.flox/env.json` gains `owner` and
`floxhub_url`, `.flox/env.lock` appears with `{"rev": <floxmeta commit>,
"local_rev": null}` — and FloxHub's record is the floxmeta git repo:
`<N>/env/manifest.{toml,lock}` per generation plus `metadata.json` with
`history[].current_generation`. No store paths upstream, only locks. The
generation *number* is not in `.flox/` but is one command away offline:
`flox generations list --json` (the live one has `last_live: null`), or
`git --git-dir=~/.local/share/flox/meta/<owner> show <rev>:metadata.json`.
`flox activate -g N` pins a generation and names its run link
`.flox/run/<system>.<name>.genN-run`, so **the run link carries the
generation**, which is the stamp `hub-status` wants. `local_rev != null`
marks a checkout edited in place (`pull` then refuses without `--force`) —
the managed-environment analogue of the tree kind's dirty guard.

**Path environments (what `pull -g N --copy` produces):**

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

Written as of `homelab-158.3`: `last-applied-environment-<tenant>.json`
carries `sha`, `run_path` (the `readlink` of `.flox/run/<system>.<name>-run`
after the warm), `dir`, `applied_at` and the units restarted, and
`hub-status` prints `staged <sha7> / applied <sha7> (run <hash7>)` per
tenant. One detail the path environment adds: the link is named from
`.flox/env.json`'s `name`, not from the directory, so the pull reads the
name from there rather than guessing it from the tenant.

Written as of `homelab-158.5` (arcade, `source.kind = floxhub`; the
box-side verification is the first generation's pull, WSL proved the
shape with flox 1.14.0 against `imkarrer/hub-spike-2026-09-18`): **the
box runs a tracking checkout pinned at activation, and the generation is
ours to record.** `flox pull owner/name` keeps flox's own identity beside
ours — `.flox/env.json` (owner, name, hub) and `.flox/env.lock` (`rev`,
the floxmeta commit; `local_rev`, null unless someone edited in place) —
and `flox generations list --json` reads the generation table offline
from the owner's floxmeta clone under `$HOME/.local/share/flox/meta/`.
What no file in `.flox/` says is *which generation the unit runs*: the
live links follow the last pull, and `flox pull -g N --copy` (the only
pinned pull) throws the identity away. So the pull unit activates `-d
<dir> -g N`, which makes `.flox/run/<system>.<name>.genN-run` beside the
live links, writes N to `/var/lib/homelab/pinned-environment-<tenant>`
for the stub's wrapper, and records `{env, generation, run_path, ...}`
in `last-applied-environment-<tenant>.json`; hub-status prints `staged
gN / applied gN (run <hash7>)` with the tenant commit that pushed N
beside it. Two facts the shape depends on: the floxmeta clone is
load-bearing (§1 — without it even an offline activation of the tracking
checkout re-clones from api.flox.dev), and FloxHub's floxmeta is readable
without an account the way flox itself reads it, HTTP basic auth as
`oauth` with an empty password (a request with no credential is a 401),
which is what lets the pull unit fetch generation N's lock and run the
substitute-only guard *before* `flox pull` builds anything. The product
asks: a `flox pull --generation N` that keeps the tracking identity, and
a generation number in `.flox/` itself.
## 4. Secrets — answered (nothing changes)

Every secret consumer on this box takes a **path**: Grafana's `$__file{}`,
Alertmanager's `webhook_url_file`, unpoller's `pass`, the exporter's
`UNIFI_PASS_FILE`, agent-hub's future `githubTokenFile`. sops-nix renders
those paths on the host at activation and keeps rendering them; a stub
passes the same paths to the environment as variables (`[vars]` is not
involved — it would clobber the caller, "Beyond the six"), and
`ConditionPathExists=` stays on the unit. The environment never sees a
secret value, only a path the host owns. No manifest feature is needed and
none is missing; the one rule is that a manifest `[hook]` must not source
`/run/secrets` into the process environment, because that turns a path
into a value the tenant's own tools can log. (`.7`, and the agent-hub
stub, which passes seven paths and values, none secret.)

## 5. Host facts in the manifest — answered (correctly out of scope; two product asks)

The `.7` spike ([docs/spike-observability-as-environment.md](spike-observability-as-environment.md))
asked the sharpest form of the question: could the observability tenant —
eight native units whose Prometheus config is *generated from the
contract* — run from an environment? Mechanically yes: a `[hook]` rendered
a `promtool`-checked `prometheus.yml` from a JSON fixture into
`$FLOX_ENV_CACHE` in 128 ms per activation, and `flox activate -- prometheus`
served it. But three things decide against it:

- **`flox activate` writes on every activation** — `.flox/log/executive.<pid>.log`,
  never pruned, and a read-only `.flox/` fails the activation (exit 1,
  `Permission denied`). agent-hub never noticed because `User=agent-hub`
  owns its checkout. observability runs as five identities including
  `DynamicUser=yes` and two `ProtectSystem=strict` sandboxes; an environment
  under them needs a group-writable log dir and `ReadWritePaths=` holes.
- **A hook's exit code is collapsed to 1**, and a hook failure leaves the
  previous rendered file in place, so a bad render is a restart loop on the
  box rather than a red gate — where `metrics.nix`'s address assertion and
  the module's `promtool check` fail at eval today.
- **`/etc/homelab/tenants.json` carries no `metrics`**; the contract's
  scrape derivation lives in Nix, and moving it means a schema addition to
  feed a shell template what a module function reads directly.

So host facts arrive by environment variable from the stub (agent-hub,
arcade), and a host-fact-*derived config file* stays where the derivation
is. That is consistent with flox's contract — an OS someone else configures
— and not a gap. The two asks that are: **an activation that can run
read-only** (no mandatory log write), so an environment can sit under a
hardened supervisor; and **a hook whose exit status passes through**, so a
render failure is attributable.

### Two more, from the managed-environment spike

- **`flox delete` cannot remove a FloxHub environment** ("FloxHub
  environments cannot yet be deleted"); the throwaway
  `imkarrer/hub-spike-2026-09-18` (public, generations 1–4) needs the web
  UI. A CI that pushes on every green build accumulates generations with
  no CLI to prune them.
- **Two token kinds.** What `flox auth token` prints after a browser login
  is a 30-day Auth0 JWT (the spike's, expiring 2026-10-18). What the
  operator issued on hub.flox.dev for CI is an opaque `flox…`-prefixed
  token (61 chars, no JWT structure) — so a CI-shaped token *does* exist,
  correcting this record's first version; its lifetime is set on FloxHub
  and is not readable from the token. `flox push` honours
  `FLOX_FLOXHUB_TOKEN` non-interactively with either (the JWT verified with
  the config file moved aside; the opaque one by home-arcade build 6's
  push), which is how the agent carries it — nothing persisted. `hub-status`
  decodes a JWT's expiry and names the FloxHub setting for the other kind.
  Also: `flox gc` runs a full `nix store gc` — never in a tenant unit.

## 6. Version coupling — partial (answered for the box and dev; CI's copy is by hand)

**The pin is `flake.nix`'s `flox` input; everything else reads the lock.**
From `homelab-158.2`: `modules/platform/flox.nix` installs the package that
input resolves to (`v1.14.0`, substituted from `cache.flox.dev` — 110 paths,
382 MB, 16 s on WSL; *not* built, which is why the input does not
`follows` nixpkgs: with the host's nixpkgs the output is a different store
path that no cache has, and the box would compile flox's Rust and bundled
nix). `scripts/hub-gates.sh` reads the same lock node to reproduce the CI
environment locally, so dev, the gate and the box agree by construction.
What is still a hand-kept copy: the CI agent container's own flox
(`ac-host` compose builds the image with 1.14.0), which `.6` retires when
the agent runs from an environment.

Also known: a lock written by 1.14.0 is read by 1.14.1 unchanged (§ Beyond
the six, `.1`); the reverse has not been exercised.

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

## Beyond the six — from `homelab-ybm` (the bot and sidecar images by `flox containerize`, 17 Sep)

`flox containerize` of ac-host's existing manifest, with the pinned 1.14.0,
produced the image compose now runs for the bot and the three sidecars.
Proven in the image: every entrypoint imports, DejaVu resolves through the
environment's `XDG_DATA_DIRS`, `auth.py` serves `/health` from the committed
compose definition. What the step taught, each verified by the worker and
independently by the reviewer (who containerized the branch a second time):

- **Size.** 2.07 GB uncompressed on disk, 100 layers (Docker Desktop reports
  4.2 GB, double-counting the snapshotter), against `python:3.12-slim` at
  179 MB and the box's previous `ac-host-bot` 539 MB + `ac-host-auth` 177 MB.
  Where it goes: nixpkgs' `discordpy` propagates a full ffmpeg for voice
  (1.0 GB closure — gtk4, pipewire, gstreamer), scipy + numpy + openblas
  ~520 MB, and git/gh/nixfmt ~490 MB ride along because **one manifest
  serves three roles** (dev shell, CI, prod) and a package's optional
  propagated dependencies cannot be dropped from it. Layers are shared per
  lock, so repeated builds cost tags, not disk; the box has 619 GB free.
  Not a blocker here; a real cost for anyone shipping to a registry.
- **Code inclusion is a bind mount.** In 1.14 a `[build]` output reaches an
  environment only through `flox publish` and `flox install` — a network and
  account dependency per commit — and a second `COPY` layer is a Dockerfile.
  So the four services mount the tree at `/repo:ro` (the bot already did) and
  the manifest's `[profile]` derives `PYTHONPATH` from
  `${FLOX_ENV_PROJECT:-${AC_REPO:-/repo}}`. A code change is a tree sync and
  `--force-recreate`; the image changes only when the manifest does.
- **`FLOX_ENV_PROJECT` is empty inside the image**, so a `[profile]` that
  builds paths from it needs the fallback above.
- **`--mode run` drops site-packages from `PYTHONPATH`**: `import discord`
  fails; the image is dev mode, which is also what CI tests under, for a
  4 MB saving foregone.
- **The activation's `bash --noprofile --norc -s` is PID 1** in the
  container. It forwards neither `SIGTERM` (`docker stop` = 10 s, then
  `SIGKILL`, exit 137) nor stdin. `init: true` in compose gives 185 ms and
  exit 143 — python still never sees the signal, it dies with the namespace,
  which is what the old images did too. A manifest `[hook]` cannot `exec`
  the command, so the fix is compose-side. For the CI smoke test, stdin is
  worked around with `docker create` + `docker cp` + `docker start -a`.
- **`flox activate -- cmd` skips `[profile]`; `-c` sources it.** The gate and
  CI both use `-c` for anything that needs `PYTHONPATH`.
- Containerizing a path environment needs no FloxHub login.
- `pillow`/`numpy`/`scipy` are not dev-only: the bot runs
  `generate_series_liveries.py` with `sys.executable` inside its own
  container when the Buildkite trigger is unavailable. They stay.

**Consequence for the tenant tree path:** the image is loaded into the
box's daemon by CI (`image` on every branch before the wait, `promote-image`
on `main` after it, `queue-prod` behind promote); `ci_downtime.py` and
`acctl.py` never build, and a missing image is a loud skip of the sidecars,
never a missing lobby. 03:00 no longer reaches PyPI or Docker Hub.

## Beyond the six — from `homelab-158.5`'s CI half (`flox push` from CI, 18 Sep)

- **A fresh checkout cannot push a new generation.** A CI checkout is a
  *path* environment: `flox push -d .` creates the remote once, then fails
  with "already exists", and `--force` "succeeds" by **replacing the remote
  history** with a fresh generation 1 — a copy that had pulled the old
  generation then errors "can't find rev specified in lockfile". So
  home-arcade's `scripts/ci_push.sh` pulls the live generation into a scratch
  dir, overlays the tree's `manifest.toml` + `manifest.lock`, `flox edit
  --sync`, and pushes; only a missing remote gets `push --owner`. Proven on
  1.14.0 and 1.14.1: first push (gen 1), manifest change (gen N+1), no
  change (nothing pushed). The product shape this implies: an environment's
  generations live in floxmeta, and git is the tree's history, not the
  environment's — a CI that wants "this commit = this generation" has to
  bridge them by hand.
- `flox edit --sync` rewrites the lock with packages reordered, so
  "unchanged" is a canonical comparison the script does; flox compares
  byte-for-byte.
- `flox push` prints no generation number; `flox generations list -d <the
  pushed copy>` does. `-r owner/name` reads `~/.cache/flox/remote/` and
  never refreshes.
- Environments are pushed **public** by default; `imkarrer/arcade` will be
  (its manifest holds no host fact or secret — by construction, "Beyond
  the six" for `.5`). Private is a FloxHub-side setting.
- **floxmeta IS readable without an account, but not without an
  `Authorization` header.** `api.flox.dev/git/<owner>/floxmeta` answers a
  bare request with 401 (`WWW-Authenticate: Basic realm="Login Required"`),
  which is what sent git on this WSL to Windows' credential manager and a
  desktop dialog; the same URL with HTTP basic auth as user `oauth` and an
  **empty password** answers 200, and that pair is exactly what flox's own
  logged-out git sends (its credential helper echoes `username=oauth`,
  `password=$FLOX_FLOXHUB_TOKEN`, empty). Verified 18 Sep 2026 with curl
  (401 / 200) and with a prompt-proof git -- `GIT_TERMINAL_PROMPT=0`,
  global and system config off, helper list reset, one inline helper
  scoped to api.flox.dev answering the empty password -- which cloned
  `--bare --depth 1 --single-branch --branch <env>` in 4 s, exit 0,
  spawning nothing (`.5`). So the pull unit does read generation N's lock
  *before* pulling, carries no token, and runs the "never compiles" guard
  first; a git that is allowed to prompt is the hazard, not the endpoint.
- Two more throwaway environments exist on FloxHub from proving the
  first-push and next-generation paths (`imkarrer/hub-arcade-spike`,
  `imkarrer/hub-arcade-spike-first`), and cannot be removed from the CLI.
