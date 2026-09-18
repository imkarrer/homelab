# FloxHub deploy-edge spike — second half (managed environments)

Run 2026-09-18 15:32–15:50 UTC on WSL as user `nixos`, flox 1.14.1-gaad7ad2
(`/nix/var/nix/profiles/default/bin/flox`), logged in as `imkarrer` on
https://hub.flox.dev/. Throwaway environment: `imkarrer/hub-spike-2026-09-18`
(public; four generations pushed). Everything below is what the CLI printed;
the token is never shown. Offline runs use
`unshare -U --map-user=1000 --map-group=100 -n` (checked: `lo DOWN`,
`curl https://hub.flox.dev/` → "Could not connect").

Answers the "needs login" / "unverified" lines of `docs/flox-findings.md`
§1 and §3.

---

## 1. `flox push` → generation 1; `install` + `push` → generation 2

```
$ flox init -n hub-spike-2026-09-18 && flox install hello
$ flox push
✔ hub-spike-2026-09-18 successfully pushed to FloxHub as public
View the environment at: https://hub.flox.dev/imkarrer/hub-spike-2026-09-18
Use this environment from another machine: 'flox activate -r imkarrer/hub-spike-2026-09-18'
Make a copy of this environment: 'flox pull imkarrer/hub-spike-2026-09-18'
```

**The push converts the path environment in place into a managed one.**
`.flox/env.json` went from `{"name":…,"version":1}` to

```json
{"owner":"imkarrer","name":"hub-spike-2026-09-18","floxhub_url":"https://hub.flox.dev/","version":1}
```

and a new file `.flox/env.lock` appeared:

```json
{ "version": 1, "rev": "dad9c9414f9297c3eccd4054c73cd73e06725482", "local_rev": null }
```

```
$ flox generations list
Generation:  1 (live)
Description: imported environment
Created:     2026-09-18 15:37:36 UTC
Last Live:   Now

$ flox generations history
Date:       2026-09-18 15:37:36 UTC
Author:     nixos
Host:       nixos
Generation: 1
Command:    flox push
Summary:    imported environment
```

Generation 2 is created **locally by `flox install`**, before any push;
`flox push` then uploads it:

```
$ flox install cowsay
✔ 'cowsay' installed to environment 'imkarrer/hub-spike-2026-09-18'
$ cat .flox/env.lock
{ "version": 1, "rev": "dad9c94…", "local_rev": "0fb812847f3eae04fcb9c5223ffd9a62297d90a4" }
$ flox generations list          # already shows 2 (live), before push
$ flox push
✔ Updates to hub-spike-2026-09-18 successfully pushed to FloxHub

$ flox generations list
Generation:  2 (live)
Description: installed package 'cowsay (cowsay)'
Created:     2026-09-18 15:38:09 UTC
Last Live:   Now

Generation:  1
Description: imported environment
Created:     2026-09-18 15:37:36 UTC
Last Live:   2026-09-18 15:38:09 UTC

$ flox generations history
Date:       2026-09-18 15:38:09 UTC
Author:     nixos
Host:       nixos
Generation: 2
Command:    flox install cowsay
Summary:    installed package 'cowsay (cowsay)'

Date:       2026-09-18 15:37:36 UTC
Author:     nixos
Host:       nixos
Generation: 1
Command:    flox push
Summary:    imported environment
```

Oddity: after the second push the *editing* checkout's `env.lock` kept
`rev: dad9c94 / local_rev: 0fb8128` (it did not fold `local_rev` into
`rev`). A fresh pull of the same env gets `rev: 0fb8128 / local_rev: null`.
So `local_rev != null` means "this checkout has commits upstream may not",
not necessarily "unpushed".

### What FloxHub records — the floxmeta repo

Generations are a **bare git repo per owner**, cloned to
`$XDG_DATA_HOME/flox/meta/<owner>` (`~/.local/share/flox/meta/imkarrer`),
remote `https://api.flox.dev/git/imkarrer/floxmeta` (auth required even for
`ls-remote`; flox injects the token itself via a `credential.helper`).
One branch per environment, plus one branch per local checkout named
`<env>.<8-hex registry hash of the checkout dir>`:

```
$ git --git-dir=~/.local/share/flox/meta/imkarrer for-each-ref
0fb8128… commit refs/heads/hub-spike-2026-09-18
0fb8128… commit refs/heads/hub-spike-2026-09-18.c89f91b7
$ git --git-dir=… log --format='%H %s' hub-spike-2026-09-18
0fb8128… Create generation 2
dad9c94… Create generation 1
5404c1f… Initialize generations branch for environment 'hub-spike-2026-09-18'
$ git --git-dir=… ls-tree -r --name-only hub-spike-2026-09-18
1/env/manifest.lock
1/env/manifest.toml
2/env/manifest.lock
2/env/manifest.toml
metadata.json
$ git --git-dir=… show hub-spike-2026-09-18:metadata.json
{"version":2,"history":[
  {"kind":"import","author":"nixos","hostname":"nixos","command":["flox","push"],
   "timestamp":1789745856,"current_generation":"1","previous_generation":null},
  {"kind":"install","targets":["cowsay (cowsay)"],"author":"nixos","hostname":"nixos",
   "command":["flox","install","cowsay"],"timestamp":1789745889,
   "current_generation":"2","previous_generation":"1"}],
 "total_generations":2}
```

So a generation is `<N>/env/manifest.{toml,lock}` in a git tree; the `rev`
in `env.lock` is the floxmeta commit; the live generation is
`.history[-1].current_generation` in that commit's `metadata.json`. No
store paths are recorded upstream — only the lock.

---

## 2. `flox pull owner/env` into a fresh dir (tracking)

```
$ mkdir pull-track && cd pull-track && flox pull imkarrer/hub-spike-2026-09-18
⚡︎ Pulled imkarrer/hub-spike-2026-09-18 from https://hub.flox.dev/.
$ find .flox | sort
.flox
.flox/env
.flox/env.json
.flox/env.lock
.flox/env/manifest.lock
.flox/env/manifest.toml
.flox/run
.flox/run/x86_64-linux.hub-spike-2026-09-18-dev
.flox/run/x86_64-linux.hub-spike-2026-09-18-run
```

Note what is **not** there compared with a path env: no `.gitignore`, no
`telemetry_id`. And what **is** there without any activation: `.flox/run/*`
already point at built store paths, and both are already registered under
`/nix/var/nix/gcroots/auto/`. **`flox pull` builds (substitutes) the
environment and pins its GC roots; it is the warm.** (§1's "pulled, never
activated fails offline" was produced with `flox lock-manifest`, which is
not what a real pull leaves behind — see item 5.)

The two identity files:

```
$ cat .flox/env.json
{ "owner": "imkarrer", "name": "hub-spike-2026-09-18", "floxhub_url": "https://hub.flox.dev/", "version": 1 }
$ cat .flox/env.lock
{ "version": 1, "rev": "0fb812847f3eae04fcb9c5223ffd9a62297d90a4", "local_rev": null }
$ grep -i generation .flox/env/manifest.lock
(nothing)
```

**Is there a machine-readable file naming current generation + owner/env?
Partly.** `env.json` names owner/env/hub; `env.lock` names the floxmeta
*commit*, not the generation number. The generation number is derivable two
ways, both offline once the floxmeta clone exists:

```
$ flox generations list --json
{
  "1": { "parent": null, "created": "2026-09-18T15:37:36Z",
         "last_live": "2026-09-18T15:38:09Z", "description": "imported environment" },
  "2": { "parent": "1",  "created": "2026-09-18T15:38:09Z",
         "last_live": null, "description": "installed package 'cowsay (cowsay)'" }
}
```

(the live one is the entry with `"last_live": null` — the JSON has no
explicit `live` flag, the text output does), or exactly:

```
$ REV=$(jq -r .rev .flox/env.lock)
$ git --git-dir=$XDG_DATA_HOME/flox/meta/imkarrer show $REV:metadata.json \
    | jq -r '.history[-1].current_generation'
2
```

Also `flox envs` shows the link:
`hub-spike-2026-09-18  /…/pull-track (https://hub.flox.dev/imkarrer/hub-spike-2026-09-18)`.

**ADR 0009 question 3 for managed envs:** flox does record identity —
`env.json` (owner/env) + `env.lock.rev` (floxmeta commit) — and the
generation is one `jq` away via `generations list --json` or the floxmeta
clone. But it records the *tracking* state, and a pinned deploy (item 3)
throws it away, so our own record file is still needed for the shape we
deploy.

---

## 3. `flox pull -g 1 --copy` → detached path env, no generation record

```
$ flox pull -g 1 imkarrer/hub-spike-2026-09-18
✘ ERROR: The --generation option can only be used when pulling with --copy
$ flox pull -g 1 --copy imkarrer/hub-spike-2026-09-18
⚡︎ Created path environment from imkarrer/hub-spike-2026-09-18.
$ find .flox | sort
.flox/.gitignore
.flox/env/manifest.lock
.flox/env/manifest.toml
.flox/env.json
.flox/run/x86_64-linux.hub-spike-2026-09-18-dev
.flox/run/x86_64-linux.hub-spike-2026-09-18-run
.flox/telemetry_id
$ cat .flox/env.json
{"name":"hub-spike-2026-09-18","version":1}
$ cat .flox/env.lock
cat: .flox/env.lock: No such file or directory
$ grep -A1 '^\[install\]' .flox/env/manifest.toml
[install]
hello.pkg-path = "hello"            # gen 1: no cowsay — correct generation
$ flox generations list
✘ ERROR: Generations are only available for environments pushed to floxhub.
The environment hub-spike-2026-09-18 is a local only environment.
```

Confirmed: §3's --help reading holds. **Nothing in `.flox/` says which
generation or which owner/env it came from.** The env name is kept (so the
run link is `<system>.<upstream-name>-run`, not the directory name — same
as §3 already notes). One residue: the pull still clones/updates floxmeta
under `$XDG_DATA_HOME/flox/meta/<owner>`, whose `refs/heads/<env>` is the
*live* rev at pull time, not the pinned generation — do not read it as the
deployed generation. Also: it was built and GC-rooted by the pull, and
activates offline without ever having been activated online (item 5).

---

## 4. `flox activate -r owner/env` twice, second offline

```
$ cd /some/dir/without/.flox
$ time flox activate -r imkarrer/hub-spike-2026-09-18 -- sh -c 'echo ${PATH%%:*}; which cowsay'
/home/nixos/.cache/flox/remote/imkarrer/hub-spike-2026-09-18/.flox/run/x86_64-linux.hub-spike-2026-09-18-dev/bin
/home/nixos/.cache/flox/remote/imkarrer/hub-spike-2026-09-18/.flox/run/x86_64-linux.hub-spike-2026-09-18-dev/bin/cowsay
real 0m0.853s      exit 0
```

**Cache path: `$XDG_CACHE_HOME/flox/remote/<owner>/<env>/.flox/`** — a full
managed checkout (env.json, env.lock, env/, run/, cache/, log/), plus a
floxmeta branch `<env>.37c42409` for it.

```
$ unshare -U --map-user=1000 --map-group=100 -n sh -c \
    'time flox activate -r imkarrer/hub-spike-2026-09-18 -- sh -c "which cowsay"'
/home/nixos/.cache/flox/remote/imkarrer/hub-spike-2026-09-18/.flox/run/x86_64-linux.hub-spike-2026-09-18-dev/bin/cowsay
real 0m0.160s      exit 0
$ unshare … 'time flox activate -r imkarrer/hub-spike-2026-09-18 -- true'
real 0m0.143s      exit 0
```

**Yes: the man-page claim is true; `-r` activates from cache with the
network dead, 143–160 ms, exit 0.** Two things the man page does not say:

- **`activate -r` never refreshes the cache.** After gen 3 was pushed,
  an *online* `activate -r` still ran gen 2 (`which figlet` → not found;
  the cached `env.lock` stayed at `0fb8128`). `flox pull -r owner/env`
  is what advances the cached copy (it did: `rev` → `31dc446`). So `-r`
  is "pinned to whatever you first cached until you `pull -r`", which is
  actually the deploy-friendly behaviour, just undocumented.
- **`activate -r -g N` exists and works offline** once the store paths
  are present: `flox activate -r … -g 1 -- …` created
  `…/.flox/run/x86_64-linux.hub-spike-2026-09-18.gen1-{dev,run}` beside
  the live links; offline `-g 1` 163 ms, offline `-g 2` (never activated
  through `-r`, but floxmeta + store paths present locally) 203 ms, exit 0.
  `flox activate -d <dir> -g 1` also works on a tracking checkout (160 ms
  offline), adding the same `.gen1-*` links.
- **Trust.** With no token (fresh XDG dirs) and stdin closed:
  `flox activate -r imkarrer/… -- true` → exit 1,
  `✘ ERROR: The environment imkarrer/hub-spike-2026-09-18 is not trusted.`
  `flox activate -t -r … -- true` → exit 0. Envs owned by the logged-in
  user are auto-trusted; a box running as a tenant user with no login must
  pass `-t` (or set `trusted_environments."imkarrer/<env>" = "trust"` in
  flox.toml). `flox pull` + `flox activate -d` does **not** prompt for trust
  (path/managed checkouts in a dir are trusted).

---

## 5. Tracking pull: offline activation, and what a later pull changes

Online once, then offline three times, then `-d` from `/`, then after
`rm .flox/run/*`:

```
$ flox activate -- true                         real 0m0.132s
$ unshare … 'time flox activate -- true'        real 0m0.136s / 0.143s / 0.145s   exit 0
$ cd / && unshare … "flox activate -d $D -- true"   real 0m0.137s
$ rm $D/.flox/run/* && unshare … "flox activate -d $D -- true"   real 0m0.175s  (links rebuilt)
```

Same order as the path env (§1 said 52–88 ms on the box; 130–175 ms here on
WSL, where a path env's `flox activate -- true` also measures ~130 ms today).
**And without any online activation**: a fresh `flox pull` followed
immediately by an offline `flox activate -d` → 128 ms, exit 0; the
`--copy` pull likewise (138 ms). The pull is the warm.

Upstream moved (gen 3 pushed from the editing checkout):

```
$ unshare … 'flox pull'
✘ ERROR: Failed to fetch updates for environment: Git failed with: [exit code 128]
  stderr: fatal: unable to access 'https://api.flox.dev/git/imkarrer/floxmeta/': Failed to connect …
Please ensure that you have network connectivity                     exit 1
$ flox pull
✔ Pulled imkarrer/hub-spike-2026-09-18 from https://hub.flox.dev/      exit 0
$ flox pull
! imkarrer/hub-spike-2026-09-18 is already up to date.                 exit 0
```

`.flox/` diff (files + link targets, hashes truncated; `log/` and `cache/`
excluded because they churn on every activation):

```
- .flox/env.lock            9daea306…   {"rev":"0fb8128…","local_rev":null}
- .flox/env/manifest.lock   0f86cfda…
- .flox/env/manifest.toml   26836d82…
- .flox/run/…-dev -> /nix/store/qc78jqmh…-environment-dev
- .flox/run/…-run -> /nix/store/m9qxbr3q…-environment-run
+ .flox/env.lock            5ac90e64…   {"rev":"31dc446…","local_rev":null}
+ .flox/env/manifest.lock   9f5ce871…
+ .flox/env/manifest.toml   c97048a4…
+ .flox/run/…-dev -> /nix/store/3qnfl9nn…-environment-dev
+ .flox/run/…-run -> /nix/store/n17r4xbd…-environment-run
```

**Yes, a dirty check would notice:** `env.lock.rev` changes, both manifest
files change, both run links retarget. The run link's `readlink` is the
content identity exactly as `last-applied-environment-*.json` already
records it. Two guard details:

- A *tracking* checkout has no `.flox/.gitignore`, so a literal
  `git status` inside `.flox` would also see `log/` and `cache/` churn;
  compare `env.lock` + `readlink .flox/run/*-run` instead.
- Local edits set `local_rev` and fork the generation numbering
  (`flox install ripgrep` on the tracker produced a local "Generation 4"
  while upstream's 4 is `jq`); `flox pull` then refuses:
  `✘ ERROR: The environment has diverged from the remote` (exit 1);
  `flox pull --force` overwrites and resets `local_rev: null`. So
  `local_rev == null` is the "checkout untouched" predicate.
- WSL artefact to not over-read: `flox generations list -u` worked offline
  and showed gen 3 because the editing checkout and the tracker share one
  user's floxmeta clone. On the box the tenant user has its own clone.

---

## 6. Push credentials for CI

`~/.config/flox/flox.toml` holds `floxhub_token = "<jwt>"` (mode 0600). With
that file moved aside:

```
$ flox auth status          → ! You are not currently logged in to FloxHub.   exit 1
$ flox pull imkarrer/hub-spike-2026-09-18           (public env)
! You are not logged in to FloxHub. Run 'flox auth login' to log in.
⚡︎ Pulled imkarrer/hub-spike-2026-09-18 from https://hub.flox.dev/.        exit 0
$ flox pull -g 1 --copy imkarrer/hub-spike-2026-09-18                       exit 0
$ flox activate -d <that dir> -- true </dev/null                             exit 0
$ flox push
✘ ERROR: You are not logged in to FloxHub.
To login you can either
* login to FloxHub with 'flox auth login',
* set the 'floxhub_token' field to '<your token>' in your config
* set the '$FLOX_FLOXHUB_TOKEN=<your_token>' environment variable.        exit 1
```

**Pull of a public env needs no token** (only a `!` nag on stderr each
call). **Push does**, and the env var is `FLOX_FLOXHUB_TOKEN`:

```
$ flox install jq                                  (gen 4, local)
$ FLOX_FLOXHUB_TOKEN="$(…from the toml…)" flox push </dev/null
✔ Updates to hub-spike-2026-09-18 successfully pushed to FloxHub          exit 0
$ FLOX_FLOXHUB_TOKEN=… flox auth status
You are logged in as imkarrer on https://hub.flox.dev/
Credential read from the FLOX_FLOXHUB_TOKEN environment variable.
$ ls ~/.config/flox/        → empty; the env var does not write a flox.toml
```

Worked, non-interactively, no `flox.toml` present. flox itself uses the same
variable internally — the `.flox/log/upgrade-check.*.log` shows it running
`env FLOX_FLOXHUB_TOKEN='***' GIT_CONFIG_GLOBAL=/dev/null … git -c
'credential.https://api.flox.dev/git.helper=!f(){ …'` (token redacted in the
log; good).

**The token is an Auth0 JWT, 30-day lifetime** (decoded claims only:
`iss https://auth.flox.dev/`, `aud [hub.flox.dev/api, flox.us.auth0.com/userinfo]`,
`iat 2026-09-18T15:32Z`, `exp 2026-10-18T15:32Z`). `flox auth token`
prints it. There is no visible refresh path; a CI secret set from it expires
in a month and `flox auth login` is a browser device flow. That is a real
operational cost for a push-from-CI design and worth a product note.

---

## 7. Product observations

- `flox auth status` prints
  `! Credential stored in plain text at '/home/nixos/.config/flox/flox.toml'.`
  on every call. The file is 0600, so "plain text" is about at-rest
  encryption, not permissions. The nag has no off switch I found; on a
  server it will appear in every journal line from every flox invocation
  that is logged in. Conversely the logged-*out* nag
  `! You are not logged in to FloxHub. Run 'flox auth login' to log in.`
  prints on every pull/activate of a public env — a tenant unit running
  unauthenticated gets one line of noise per invocation either way.
- `flox delete` on a managed checkout:
  `! Environment 'imkarrer/hub-spike-2026-09-18' is linked with a FloxHub environment.`
  `FloxHub environments cannot yet be deleted.`
  `This command will only delete the local link in '…/.flox'.`
  **The remote copy cannot be removed from the CLI**; `flox delete --help`
  and `man flox-delete` have no remote option, and the API path I probed
  (`/api/v1/catalog/environments/<owner>/<env>`) is 404. `imkarrer/hub-spike-2026-09-18`
  is therefore still on FloxHub (public, four generations: hello, +cowsay,
  +figlet, +jq); remove it from the hub web UI if that offers deletion.
- `activate -r` silently serving a stale generation while online (item 4)
  is the kind of thing that will surprise someone using `-r` as "run the
  latest"; the docs say "cached" without saying "never refreshed".
- The 30-day JWT (item 6) is the only credential shape offered; no
  service/CI token type exists in the CLI.
- `flox pull -g N` requires `--copy`; there is no "pin a tracking checkout
  to N", though `flox activate -g N` on a tracking checkout does the same
  at activation time and keeps `env.lock` intact. That combination
  (`flox pull` tracking + `flox activate -d … -g N`) is the one shape that
  keeps flox's own generation record *and* pins — see the recommendation.
- Fresh XDG dirs get the one-time metrics notice on the first invocation
  (`FLOX_DISABLE_METRICS=true` silences); a unit's first run will log it.
- **`flox gc` runs a full `nix store gc`** (child process
  `nix … store gc --debug`; `man flox-gc`: "runs garbage collection on the
  Nix store"). After deleting seven local checkouts it was still walking
  the store at 4.5 minutes and I interrupted it (nix GC is safe to stop).
  It is a system-wide store GC under a flox-local name: never put it in a
  tenant unit — it would delete every unrooted store path on the box, not
  just the tenant's.

## Cleanup state

Local: all seven checkouts `flox delete -f`'d (env-registry has no
spike-floxhub entries), `~/.cache/flox/remote/imkarrer/…` removed, floxmeta
clone at `~/.local/share/flox/meta/imkarrer` keeps one branch
`hub-spike-2026-09-18` (harmless; `flox gc` would drop it but see above).
Two dangling symlinks remain in `/nix/var/nix/gcroots/auto/` pointing at
deleted scratch paths — nix prunes those itself.
Remote: **`imkarrer/hub-spike-2026-09-18` still exists on FloxHub** (public,
gens 1–4: hello / +cowsay / +figlet / +jq). The CLI cannot delete it.

---

## Summary (one line per item)

1. **Yes** — `flox push` makes gen 1 ("imported environment") and converts the path env in place (adds owner to `env.json`, creates `env.lock`); `flox install` makes gen 2 locally, `push` uploads it; floxmeta is a bare git repo per owner with `<N>/env/manifest.{toml,lock}` + `metadata.json`.
2. **Partly** — a tracking pull has `env.json` (owner/env/hub) and `env.lock` (`rev` = floxmeta commit, `local_rev`); the generation *number* is not in `.flox/` but is `flox generations list --json` / `metadata.json .history[-1].current_generation` at that rev, offline.
3. **Yes** — `pull -g 1 --copy` is a plain path env: `env.json` `{"name",…}`, no `env.lock`, no `.flox` trace of owner or generation, `flox generations` refuses.
4. **Yes** — `activate -r` offline works from `$XDG_CACHE_HOME/flox/remote/<owner>/<env>/.flox`, 143–160 ms exit 0; but it never refreshes online either (`flox pull -r` does), and an unauthenticated non-owner needs `-t`.
5. **Yes** — tracking pull activates offline at 128–175 ms with **no prior online activation** (the pull builds and GC-roots it); a later `flox pull` needs network, rewrites `env.lock.rev`, both manifests and both run links (dirty check sees it); `local_rev != null` = locally diverged and `pull` refuses without `--force`.
6. **Yes** — token lives in `~/.config/flox/flox.toml` `floxhub_token` (0600); `FLOX_FLOXHUB_TOKEN` is honoured by `flox push` non-interactively with no toml; pulling a public env needs no token; the token is a 30-day Auth0 JWT.
7. Noted — plain-text nag on every logged-in call; logged-out nag on every unauthenticated call; **remote env cannot be deleted from the CLI** ("cannot yet be deleted"), so `imkarrer/hub-spike-2026-09-18` is still on FloxHub.

## Commands for the .5 pull unit, `source.kind = "floxhub"`

Two viable shapes; the second keeps flox's own record and is recommended.

**A. Pinned copy (detached; matches today's `sha` shape, record is ours):**
```sh
# as the tenant user, in its slice; DIR owned by the tenant user, must not exist yet
setpriv --reuid=<tenant> --regid=<tenant> --init-groups \
  env HOME=/var/lib/<tenant> XDG_DATA_HOME=/var/lib/<tenant>/.local/share XDG_CACHE_HOME=/var/cache/<tenant> \
      FLOX_DISABLE_METRICS=true \
  flox pull -g "$GEN" --copy -d "$DIR" "$OWNER/$ENV"          # builds + GC-roots; no token for a public env
setpriv … flox activate -d "$DIR" -- true                     # warm/verify; offline-safe from here on
readlink "$DIR/.flox/run/x86_64-linux.$(jq -r .name "$DIR/.flox/env.json")-run"   # -> run_path for our record
```
Record `owner/env`, `generation`, `run_path`, `pulled_at` ourselves — `.flox/` carries none of it.

**B. Tracking checkout, pinned at activation (flox keeps `env.json` + `env.lock`; recommended):**
```sh
setpriv … flox pull -d "$DIR" "$OWNER/$ENV"                    # first time; later runs: flox pull -d "$DIR"  (exit 0, "already up to date" when nothing moved)
setpriv … flox activate -d "$DIR" -g "$GEN" -- true            # pins; makes .flox/run/<system>.<name>.gen$GEN-{dev,run}
readlink "$DIR/.flox/run/x86_64-linux.<name>.gen$GEN-run"     # -> run_path
jq -r .rev "$DIR/.flox/env.lock"                               # -> upstream commit at pull time (dirty check: compare to previous)
```
Guard: refuse to proceed if `jq -r .local_rev "$DIR/.flox/env.lock"` is not `null`. The stub's own line is then `flox activate -d "$DIR" -g "$GEN" -- <binary>` (offline, ~150 ms). Never use `flox activate -r` in the unit: it needs `-t` when unauthenticated, caches under `$XDG_CACHE_HOME/flox/remote`, and does not refresh.
