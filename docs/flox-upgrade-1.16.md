# Flox 1.14.0 -> 1.16.0: what changes for this hub

Read for `homelab-158.15`, 18 Sep 2026, from flox/flox's GitHub release
notes for v1.14.1, v1.15.0 and v1.16.0 (the repo has no CHANGELOG.md; the
release notes are the changelog) and from the source at the two tags where
the notes were silent. Every claim below is either **changed** (with the
release that changed it), **not mentioned** (nothing in three releases of
notes, and the source shows no change), or **verified** (run on WSL with the
`nix build` of v1.16.0 against copies of the box's two live layouts --
`docs/flox-findings.md` §6 has the method). Hop 2 of the bead (the box) is
decided by the verified section.

## Verdicts, by the thing this hub does

| This hub does | 1.14.0 -> 1.16.0 |
| --- | --- |
| Reads `lockfile-version` | **Not changed.** Still `1`; `Lockfile.version` is `Version<1>` at both tags. |
| Writes `schema-version = "1.14.0"` in three manifests | **Changed, compatibly.** 1.15.0 and 1.16.0 each mint a manifest schema (`hook.on-deactivate`; `[services.<n>.depends-on]`, `shutdown.timeout-seconds`, `shutdown.signal`). 1.16.0 migrates 1.14.0 in memory on read and does **not** write the new version back: a re-lock (`flox install`, `upgrade`) under 1.16.0 keeps `schema-version = "1.14.0"` on disk and in the lock (verified, home-arcade copy). 1.14.0 refuses `"1.15.0"`/`"1.16.0"` outright (`InvalidSchemaVersion`, `parsed/common.rs`), so compatibility is lost only when someone bumps the field by hand -- hop 5, last. |
| `flox activate -d <dir> -- <cmd>` (the stubs) | **Not mentioned as changed; verified unchanged.** 1.14.1 removed `sbin` from `PATH` (`--add-sbin` to opt in): `llama-swap`, `freeciv-server`, `mindustry-server` are all `bin/`, verified. `--` still skips `[profile]`, `-c` still sources it (no change in three releases of notes). |
| `flox activate -g N` (the floxhub stub wrapper) | **Not mentioned; verified working.** Rebuilds the generation's run link under the new version (below). |
| `flox pull` (first with ref, then bare) | **Not mentioned; verified: output byte-identical** to 1.14.0 on `imkarrer/hub-spike-2026-09-18`, `env.json` and `env.lock` identical. 1.16.0 adds a "you may need to run 'flox auth login'" hint to the *not found* error only. |
| `flox generations list --json` (the pull's live-generation read) | **Not mentioned; verified byte-identical** (`created`, `description`, `last_live`, `parent`; `last_live: null` marks live). |
| `env.lock` (`rev`, `local_rev`) | **Not mentioned; verified unchanged** by pull and by activation. |
| `.flox/env.json` | **Changed for new environments only.** 1.16.0's `flox init` writes an `env_id` (metrics id) into `env.json`. Existing files are not rewritten by pull or activate (verified: md5 unchanged on all three layouts). 1.16.0 also stops `flox edit --name` resetting `env.json` to owner-only permissions. |
| `flox push` from a path env, `flox edit --sync` (home-arcade `ci_push.sh`) | **Not changed in shape.** 1.15.0: push works with editor temp files present; 1.14.1: push no longer reports unsynced changes after upgrading an older-created environment. Not re-run here (push mutates FloxHub); 1.14.1 is proven by build 6 already. |
| `FLOX_FLOXHUB_TOKEN` | **Not mentioned as changed.** Still the non-interactive credential; the new NixOS module passes it the same way. 1.16.0's `flox auth token` now prints opaque PATs (the CI kind) instead of "not logged in"; `flox auth status` shows expiry; `auth login` does server discovery. |
| `flox containerize` (ac-host's image) | **Not mentioned;** no commits to `commands/containerize.rs` between the tags beyond the auth-warning plumbing. Not re-run here. |
| The activation's upgrade check (POST to `/catalog/resolve`) | **Not changed.** Still spawned on every activation, including `-- <cmd>`; `upgrade_notifications` gates only the *message* (`activate.rs`). |
| `.flox/log` writes | **Not changed.** Every activation still writes `executive.<pid>.log.<date>` and `upgrade-check.<ts>.log`; the executive's hourly GC (3 days / last 5) is unchanged since 1.14. |
| `[vars]` clobbering the caller | **Still true**, and 1.15.0 made it stricter (a pre-set variable is re-set by `[vars]` on a second activation). Our manifests keep `[vars]` empty. |

## The product asks in `docs/flox-findings.md`

- **Read-only activation (§5): not landed.** `chmod -R a-w .flox` then
  `flox activate -- true` under 1.16.0: `Permission denied (os error 13)`,
  exit 1. Flox's own new NixOS module works around it with
  `ReadWritePaths = [ workingDirectory "/nix/var/nix/daemon-socket" ]`.
- **`[services]` exit-on-failure (§2): not landed.** 1.16.0 adds
  `depends-on` and `shutdown.{timeout-seconds,signal}`; the
  `flox_never_exit` sentinel is still there. The NixOS module's "Services"
  method runs `flox activate --start-services -- flox services logs
  --follow`, so its unit outlives a died service exactly as §2 measured.
- **Hook exit code pass-through (§5): not landed.** `on-activate = "exit 7"`
  under 1.16.0: `Running hook.on-activate failed`, exit 1.
- **`.flox/log` on every activation (§5): not landed** (table above).

## New since 1.14.0 that this hub should know

- **A Flox NixOS module** (1.16.0, `modules/nixos/`, `nixosModules.flox`):
  `services.flox.activations.<n>` (the `--start-services` shape) or
  `systemd.services.<n>.flox.{environment, execStart}` (an `ExecStart`
  override: `flox activate -d <dir> -- <cmd>`, the same shape as
  `modules/tenant/environment.nix`), with a `flox-pull@<n>` unit that pulls
  on first start and, by default, **on every service start**
  (`pullAtServiceStart = true`), plus an optional timer and
  restart-on-new-generation. It is the upstream answer to the same problem
  ADR 0009 solves, with the opposite network posture (§1: this hub's stub
  never fetches). Whether to adopt any of it is a decision for the epic,
  not this bead; it is not imported here.
- **Catalog auth gating is coming** (1.15.0). A logged-out *resolve* now
  warns `Resolving packages will require authentication to FloxHub in an
  upcoming release` (verified with `lock-manifest` under a scratch HOME).
  The box never resolves -- `pull` builds from the lock, activation reads
  it -- and CI carries `FLOX_FLOXHUB_TOKEN`; the one place a re-lock runs
  logged out is a fresh WSL. When gating lands, hop 5's re-locks need a
  token wherever they run.
- **The "not logged in" reminder** (1.14.1) prints `! You are not logged in
  to FloxHub. Run 'flox auth login' to log in.` once per *process* on
  stderr -- for a stub, once per unit start into the journal, since the
  tenant users are logged out. `FLOX_AUTH_NOTIFICATIONS=false` (1.15.0)
  silences it (verified); the stubs and the pull unit do not set it yet.
- **1.15.0 asks that current activations be exited after installing**
  (activation state moved into `state.json`). On the box the switch stops
  every stub before starting it under the new flox, so nothing lingers;
  on WSL, exit any open `flox activate` shell before hop 4.
- **`cache.flox.dev?priority=50`** (1.16.0): flox's flake now spells its
  substituter with a priority so cache.nixos.org wins for shared paths.
  For an *untrusted* nix user that spelling no longer matches
  `trusted-substituters = https://cache.flox.dev` and is dropped with a
  warning, so `nix build --accept-flake-config github:flox/flox/<rev>#…`
  -- `scripts/hub-gates.sh`'s `find_flox` on WSL -- **compiles flox**
  (observed: 10 min into building `flox-activations` and `flox-nix-plugins`
  before being killed). Passing `--extra-substituters https://cache.flox.dev`
  beside `--accept-flake-config` substitutes in 2 s. root (the box, CI's
  agent) is trusted and unaffected. `modules/platform/flox.nix`'s
  `mkOrder 1600` comment assumes list order decides; nix decides by
  priority, and cache.flox.dev advertises none -- the `?priority=50`
  spelling is the real fix, a platform decision for the supervisor.

## Verified on WSL: the new flox against the box's two layouts

Method: the `nix build` of v1.16.0 (`hrrd0sda…`, 109 paths / 378 MB from
cache.flox.dev) and the pinned 1.14.0 (`rq6g47dw…`), run against a fresh
clone of agent-hub `main` (`33c3b83`, the sha the box has applied) warmed by
1.14.0, and a 1.14.0 `flox pull` of `imkarrer/arcade` in a scratch HOME
pinned at generation 1 -- both of which produced *the box's own run store
paths* (`vm5w4jch…-environment-run`, `zj4s9i2k…-environment-run`, read from
`last-applied-environment-*.json` on ac-box), so the copies are exact.

| Case | Result |
| --- | --- |
| agent-hub, 1.16.0 `activate -d -- llama-swap -config … -listen …`, `AGENT_HUB_*` set as the stub does | Serves; `git status` clean; `env.json`, `manifest.toml`, `manifest.lock` md5-identical; run links **unchanged** (`vm5w4jch…`). |
| agent-hub, 1.16.0 then 1.14.0 then 1.16.0 `-- true` | 50 / 53 / 48 ms, exit 0, files identical. Reverse direction holds. |
| agent-hub, 1.16.0 offline (`unshare -U -n`) | 51 ms, exit 0. |
| agent-hub, `rm .flox/run/*` then 1.16.0 | Rebuilds to a **new** path (`9897js1x…`: the run output embeds flox's `activate` script and `flox-activations`, now the envtrace bash); 1.14.0 then activates that link fine. A plain `-d` activation reuses whatever link exists. |
| arcade, 1.16.0 `activate -d -g 1 -- freeciv-server --version` | `Freeciv version 3.2.2`; `env.json`, `env.lock`, both manifests identical; **gen1 run link moves** `zj4s9i2k…` -> `5zsv74i6…` (`-g` always rebuilds under the running version; 1.14.0 moves it back). |
| arcade, 1.16.0 `-g 1` offline with the run path deleted from the store | Rebuilds in 821 ms, exit 0, no network -- the 03:00 restart shape holds. `mindustry-server` resolves too. |
| pull unit's calls on `imkarrer/hub-spike-2026-09-18`, 1.14.0 vs 1.16.0 | `pull` (first and bare), `generations list --json`, `env.json`, `env.lock`, `manifest.lock`: byte-identical. `activate -g 2` 139 vs 269 ms. |
| lock written by 1.16.0 (`flox install hello` on the home-arcade copy) | `schema-version` stays `1.14.0`; 1.14.0 activates and `list`s it. Both versions drop the comment block above `schema-version` on a manifest rewrite -- not a regression, but hop 5's header fix must be a hand edit made *after* any `flox install`-style rewrite. |

**Consequence for hub-status:** after the switch, arcade's live gen1 link is
a 1.16.0-built path while `last-applied-environment-arcade.json` still
records the 1.14.0 one; `hub-status` prints the record and compares
nothing against the live link, so this is cosmetic until the next pull
re-records it. agent-hub's record stays exact (link reused).

## The switch (hop 2)

`flake.nix`'s `flox` input at `v1.16.0`; `flake.lock`'s flox node
`fbdabf6` -> `3ed8295`, no other node moved;
`homelab.flox.package` evaluates to `hrrd0sda…`, the path on
cache.flox.dev. Units whose text changes: `agent-hub-llm`,
`arcade-freeciv`, `arcade-mindustry` (`ExecStart` path; `restartIfChanged =
true` -- they restart), `agent-hub-environment-pull` and
`arcade-environment-pull` (script path; `restartIfChanged = false`, and
inactive). `system-path` moves (the `flox` on `PATH`). Nothing else in the
closure references flox. On the box at reading time: 0 game connections,
llama-swap with no model loaded (`/running` empty); all three drainable
under AGENTS.md.
