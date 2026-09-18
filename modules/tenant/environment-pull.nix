# The pull unit for a flox tenant: the applying half of ADR 0009's deploy
# edge, mirroring modules/deploy (ADR 0006) exactly one layer down.
#
#   closure   CI stages a rev in pending-closure.json       -> homelab-deploy switches
#   tenant    CI stages a sha in pending-environment-<t>.json -> <t>-environment-pull checks
#   (tree)    it out, warms it, restarts the stub
#   tenant    CI stages a GENERATION of owner/name           -> <t>-environment-pull pulls
#   (floxhub) in the same file                                the tracking checkout, warms
#                                                             that generation pinned, restarts
#
# Which of the two a tenant is: environment.source.kind (schema.nix).
#
# For every enabled tenant that DECLARES a stub (environment.units != {}),
# whether or not environment.enable is on:
#
#   systemd.services.<tenant>-environment-pull   oneshot, in the tenant's slice
#   systemd.paths.<tenant>-environment-pull      fires on the staged file's rename
#   systemd.timers.<tenant>-environment-pull     retries a deferred or failed pull
#   environment.etc."homelab/environments.json"  what hub-status reads
#   assertions                                   the tree is in hub/repos.psv
#
# and nothing for a tenant without a stub -- the same inert-by-default
# discipline as environment.nix and modules/deploy, with the same proof (an
# unchanged stamp-stripped toplevel drvPath for a host with no stub).
#
# --------------------------------------------------------------------------
# WHY THE PULL EXISTS WITH THE STUB OFF -- the first-switch order
# --------------------------------------------------------------------------
# environment.enable replaces the stub unit's ExecStart with `flox activate
# -d <dir> -- <command>` (environment.nix). A switch that carries that AND
# an empty <dir> restarts the unit into an activation that cannot succeed:
# Restart=on-failure loops it, and nothing stages a sha to fix it. There is
# no eval-time guard for a run-time fact and a ConditionPathExists on the
# stub would only turn "failed" into "not running". So the checkout is
# established FIRST, by this unit, on a closure where the stub is still the
# module's:
#
#   1. switch A: flox (modules/platform/flox.nix), this pull unit, enable
#      = false. The stub unit is untouched. The pull fires on its boot
#      timer, finds nothing staged, exits 0.
#   2. the tenant's pipeline goes green on main and triggers homelab with
#      HOMELAB_STAGE_ENVIRONMENT (scripts/hub-queue-environment.sh writes
#      the pending file); the path unit runs this pull: clone, checkout,
#      one online activation, applied record. enable is off, so it
#      restarts nothing.
#   3. hub-status shows `<tenant> env: staged X / applied X (run ...)`.
#   4. switch B: enable = true, a SEPARATE push. The stub's ExecStart
#      changes, the switch restarts the unit, the activation is offline
#      and ~80 ms against the warmed checkout (docs/flox-findings.md 1).
#
# The invariant is that the stub unit never fails to start because of this
# module; the order above is what guarantees it, and it is why the
# condition below is "has a stub declared", not "has the stub enabled".
#
# --------------------------------------------------------------------------
# WHAT THE PULL DOES, and what it refuses
# --------------------------------------------------------------------------
# Reads the staged sha; exits 0 if it is the applied one and the checkout
# is intact. Refuses (exit 1, a failed unit, the timer retries) a sha that
# is not 40 hex, a record whose `tree` is not the remote this closure was
# built against (a sha of the wrong tree is not checked out), an
# unreadable inventory (the quiet policy is not optional, ADR 0006), and a
# directory at `dir` that exists and is not a git checkout (never
# overwrites state it did not create).
#
# A tracked file changed in place inside the checkout -- a flox re-lock
# run there by hand, say -- makes the next pull refuse, loudly, before it
# checks anything out, and that is correct: the checkout is the tree at a
# sha, and a working copy that drifted is a hand-edit to land, not state
# to keep. (git's own refusal is not relied on: it fires only when the
# target commit touches the changed file.)
#
# The checkout is the tenant's: cloned and fetched as the stub unit's
# User=, because `flox activate` writes .flox/run, .flox/cache and
# .flox/log inside it and the stub activates as that user. The clone is
# from the registry's https remote -- public repos, no credential on the
# box -- and every later run is `fetch <sha>` + `checkout --detach`.
#
# ONE ONLINE ACTIVATION, here and nowhere else. `flox activate -d <dir> --
# true` as the tenant user realises the environment's store paths and
# registers .flox/run as a GC root; after it the stub's own activation
# needs no network (docs/flox-findings.md 1). This is the one step that may
# reach github.com, cache.flox.dev and api.flox.dev, and it FAILS SOFT: a
# non-zero exit leaves the pending record in place, the unit failed, and
# the path unit (next write) or the timer (retryInterval) tries again. The
# 03:00 restart depends on flox.dev exactly as much as the closure's
# depends on cache.nixos.org: not at all.
#
# The restart is under the tenant's quiet policy, read from
# /etc/homelab/tenants.json at RUN time like modules/deploy does, and it
# asks only THIS tenant -- the pull bounces one tenant's units, not the
# box. drainable = true restarts. drainable = false with a busyCheck asks
# it and defers while busy or unanswerable (exit 126/127 is a deferral,
# not a "no" -- the same fail-closed rule deploy learned on 15 Sep 2026).
# drainable = false with NO busyCheck defers unconditionally: that tenant
# has said bouncing it needs a human, and there is no way to ask, so the
# checkout is left warmed and the record unwritten, which hub-status shows
# as staged != applied. This is stricter than deploy's loop, which skips a
# non-drainable tenant that has no check; deploy is asking "is anyone
# busy" before touching everything, this is asking one tenant "may I".
#
# The applied record is written AFTER the restart, so a deferred or failed
# restart leaves staged != applied and the next firing retries; the fetch
# and the warm are idempotent and cost milliseconds the second time.
#
# --------------------------------------------------------------------------
# KIND = FLOXHUB (homelab-158.5): a generation of a public FloxHub environment
# --------------------------------------------------------------------------
# The staged record is {tenant, env: "owner/name", generation: N, ...}.
# Refused: an env that is not source.env, a generation that is not a
# positive integer, a dir that has a .git (a checkout of the other kind), a
# dir whose .flox/env.json is not a tracking checkout of source.env, and a
# checkout that has diverged (.flox/env.lock's local_rev is not null: a
# `flox install` run there by hand forked the generation numbering -- the
# floxhub kind's version of the tree kind's dirty guard; a tracking
# checkout has no .flox/.gitignore, so `git status` is not the tool).
#
# The shape, chosen on WSL against imkarrer/hub-spike-2026-09-18 with the
# pinned flox 1.14.0 (the box's; scratchpad spike-floxhub/findings.md):
#
#   1. substitute-only, BEFORE anything flox does. `flox pull` builds the
#      live generation and `flox activate -g N` builds generation N, so a
#      path no trusted cache has would be compiled by either. FloxHub's
#      record is a bare git repo (https://api.flox.dev/git/<owner>/floxmeta,
#      one branch per environment, <N>/env/manifest.lock per generation,
#      metadata.json naming the live one); it is readable anonymously the
#      way flox itself reads it -- HTTP basic auth, user `oauth`, EMPTY
#      password (a request with no credential is a 401, which is why a
#      plain `git ls-remote` hangs on a prompt). A shallow single-branch
#      clone into a scratch dir, as the tenant user, gives generation N's
#      lock and the live one's; both are realised --max-jobs 0. N not on
#      that branch is a refusal (pushed later than it was staged?).
#   2. `flox pull -d <dir> owner/name` the first time; `flox pull -d <dir>`
#      after (exit 0, "already up to date", when nothing moved; the form
#      with the ref refuses an existing checkout). The pull fetches the
#      owner's floxmeta into $XDG_DATA_HOME/flox/meta/<owner> under the
#      tenant's HOME, writes .flox/{env.json,env.lock,env/} and builds and
#      GC-roots the LIVE generation's links. NOT `flox pull -g N --copy`:
#      that yields a detached path environment with no trace of owner or
#      generation in .flox/ (findings 3), and a pull by hand into it later
#      is indistinguishable from ours. A tracking checkout keeps flox's own
#      record (env.json's owner, env.lock's upstream commit) beside ours.
#   3. `flox activate -d <dir> -g N -- true`: the warm, pinned. Makes
#      .flox/run/<system>.<name>.genN-{dev,run}, GC-rooted, beside the
#      live links, and is the same command the stub runs. A later pull that
#      moves the live generation leaves N's links and N's entry in the
#      floxmeta clone alone, so a failed or half-done pull never leaves the
#      unit without the generation it is pinned to -- no <dir>.new swap.
#   4. the pin: <stateDir>/pinned-environment-<tenant>, one line, N,
#      written AFTER the warm and BEFORE the restart. The stub's wrapper
#      (environment.nix) reads it at every start; the applied record is
#      still written after the restart, so staged != applied on a deferred
#      or failed restart, as for the tree kind.
#
# What is offline-safe afterwards, measured: `flox activate -d <dir> -g N`
# in ~150 ms with the network dead -- as long as the store paths AND the
# tenant user's floxmeta clone exist. Without the clone even a plain
# activation of a tracking checkout tries to re-clone from api.flox.dev and
# fails (WSL, 18 Sep 2026). So $HOME/.local/share/flox/meta/<owner> is
# load-bearing state for the stub: hub-backup.sh excludes it (it is
# re-fetched by the pull), and "already applied; nothing to do" here checks
# for it as well as for N's run link, so a restore re-pulls rather than
# leaving a stub that needs the network at 03:00. HOME and the three XDG_*
# dirs are set explicitly to the tenant's own so nothing lands under root's.
#
# Never `flox gc` here (it is a full nix store GC under a flox name) and
# never `flox activate -r` (needs -t when unauthenticated, caches under
# $XDG_CACHE_HOME/flox/remote, and never refreshes).
#
# No credential. Pulling and activating a PUBLIC environment needs none
# (verified logged-out, 1.14.0 and 1.14.1); FLOX_FLOXHUB_TOKEN is CI's
# for `flox push` (modules/platform/secrets.nix's ci-env) and never
# reaches this unit. A private environment would be a platform decision,
# not a flag here.
#
# --------------------------------------------------------------------------
# WHERE IT RUNS
# --------------------------------------------------------------------------
# In the tenant's slice (Slice= at plain priority: this is our own unit,
# nobody else defines it), because a clone and a warm are the tenant's CPU
# and memory, not the platform's. Note the limit of that: the store paths
# an activation needs are BUILT by nix-daemon, in nix-daemon's cgroup, not
# here. Substituted paths are cheap; a flake package with no binary in a
# cache the box trusts is compiled on the box, unfenced, and that is a
# platform fact (modules/platform/nix.nix's substituters) this unit cannot
# change and the handoff of homelab-158.3 records.
#
# restartIfChanged = false, for ADR 0006's reason one level in: a closure
# switch that changes this unit while it is mid-clone or mid-warm would
# otherwise kill it; the new unit file applies at its next firing.
{ config, lib, pkgs, ... }:

let
  inherit (lib) mkOption mkIf types;

  cfg = config.homelab.environments;
  flox = config.homelab.flox.package;

  # hub/repos.psv: name|path|remote|deploy|agent-push, '#' comments, read at
  # evaluation time so a tenant naming a tree the hub does not coordinate
  # is an eval error, not a clone of nothing at 03:00.
  registry =
    let
      lines = lib.splitString "\n" (builtins.readFile cfg.registry);
      rows = builtins.filter (l: l != "" && !(lib.hasPrefix "#" l)) lines;
    in
    map (
      l:
      let
        f = lib.splitString "|" l;
        at = i: if builtins.length f > i then builtins.elemAt f i else "";
      in
      {
        name = at 0;
        remote = at 2;
      }
    ) rows;

  remoteFor = tree: (lib.findFirst (e: e.name == tree) { remote = ""; } registry).remote;

  # The registry spells remotes for a developer's ssh key; the box has
  # none and clones the public repo over https.
  httpsRemote =
    r: if lib.hasPrefix "git@github.com:" r then "https://github.com/${lib.removePrefix "git@github.com:" r}" else r;

  # "Has an environment": a stub is declared. Not `environment.enable` --
  # see the header. The tenant itself must be enabled, as everywhere.
  pullTenants = lib.filterAttrs (_: t: t.enable && t.environment.units != { }) config.homelab.tenants;

  mkPull =
    name: t:
    let
      env = t.environment;
      kind = env.source.kind;
      sourceEnv = if env.source.env == null then "" else env.source.env;
      # Already resolved: environment.nix supplies the derived default at
      # the submodule level (null only where that module is not imported,
      # which the assertion below names rather than re-deriving here).
      dir = if env.dir == null then "" else toString env.dir;
      # The registry is the tree kind's concern; for floxhub `tree` is
      # provenance (schema.nix) and resolves to nothing here.
      registryRemote = if kind == "tree" then remoteFor env.tree else "";
      remote = httpsRemote registryRemote;
      stubs = builtins.attrNames env.units;

      # The checkout's owner: whoever the stub unit runs as, read off the
      # unit the tenant's module declares. A declared unit with no User=
      # runs as root; a stub outside the tenant's `units`, or whose unit
      # nobody declares, is environment.nix's assertion to make, not a
      # user to guess, so it is left out here.
      declaredStubs = builtins.filter (
        u: builtins.elem u t.units && config.systemd.services ? ${lib.removeSuffix ".service" u}
      ) stubs;
      unitUsers =
        let
          users = lib.unique (
            map (u: config.systemd.services.${lib.removeSuffix ".service" u}.serviceConfig.User or "root") declaredStubs
          );
        in
        if users == [ ] then [ "root" ] else users;
      user = builtins.head unitUsers;

      # With the stub off, the checkout is kept warm and nothing is
      # restarted: the module's ExecStart does not read it, and a bounce
      # would be a bounce for nothing.
      restartUnits = if env.enable then stubs else [ ];

      pending = "${toString cfg.stateDir}/pending-environment-${name}.json";
      applied = "${toString cfg.stateDir}/last-applied-environment-${name}.json";
      # The floxhub kind's pin, read by environment.nix's wrapper (its
      # header); "" for the tree kind, which has no such file.
      pinned = if kind == "floxhub" then "${toString cfg.stateDir}/pinned-environment-${name}" else "";

      sliceable = config.homelab.enforce.slices && t.tier != "critical" && t.quiet.drainable;

      script = pkgs.writeShellApplication {
        name = "${name}-environment-pull";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.jq
          pkgs.git
          pkgs.gnugrep
          pkgs.util-linux
          pkgs.systemd
          # nix-store for the substitute-only realisation: the host's nix,
          # so it talks to the same daemon and trusts the same caches the
          # activation will.
          config.nix.package
        ];
        text = ''
          tenant=${lib.escapeShellArg name}
          kind=${lib.escapeShellArg kind}
          sourceEnv=${lib.escapeShellArg sourceEnv}
          pending=${lib.escapeShellArg pending}
          applied=${lib.escapeShellArg applied}
          pinned=${lib.escapeShellArg pinned}
          inventory=${lib.escapeShellArg (toString cfg.inventoryFile)}
          dir=${lib.escapeShellArg dir}
          user=${lib.escapeShellArg user}
          remote=${lib.escapeShellArg remote}
          registryRemote=${lib.escapeShellArg registryRemote}
          flox=${lib.escapeShellArg "${flox}/bin/flox"}
          # Empty when environment.enable is off: warm, do not bounce.
          restartUnits=${lib.escapeShellArg (lib.concatStringsSep " " restartUnits)}

          log() { echo "$tenant-environment-pull: $*"; }
          refuse() { log "$*" >&2; exit 1; }

          if [ ! -e "$pending" ]; then
            log "nothing staged at $pending; nothing to do."
            exit 0
          fi

          # THE STAGED UNIT, by kind: a sha of the tree, or a generation of
          # the FloxHub environment. `what` names it in every line below.
          sha=""; gen=""
          if [ "$kind" = tree ]; then
            sha=$(jq -r '.sha // empty' "$pending")
            if ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
              refuse "$pending has no full sha ('$sha') -- refusing to guess."
            fi
            # A record for another tree is refused, not checked out. The
            # queue script writes the registry's remote verbatim; this unit
            # was built against the same registry.
            tree=$(jq -r '.tree // empty' "$pending")
            if [ "$tree" != "$registryRemote" ]; then
              refuse "$pending is for tree '$tree', this unit pulls '$registryRemote' -- refusing."
            fi
            what="$sha"
          else
            gen=$(jq -r '.generation // empty' "$pending")
            if ! [[ "$gen" =~ ^[1-9][0-9]*$ ]]; then
              refuse "$pending has no positive-integer generation ('$gen') -- refusing to guess."
            fi
            # A record for another environment is refused, not pulled:
            # this unit was built for source.env and pins nothing else.
            recEnv=$(jq -r '.env // empty' "$pending")
            if [ "$recEnv" != "$sourceEnv" ]; then
              refuse "$pending is for environment '$recEnv', this unit pulls '$sourceEnv' -- refusing."
            fi
            owner=''${sourceEnv%%/*}
            envName=''${sourceEnv#*/}
            what="generation $gen of $sourceEnv"
          fi

          # Already applied, and the checkout is intact? For the tree kind
          # the lock is the proof. For floxhub it is generation N's run
          # link AND the floxmeta clone the activation reads (header: a
          # tracking checkout without it goes to the network), so a
          # restore that brought back <dir> but not the clone re-pulls.
          if [ -e "$applied" ]; then
            if [ "$kind" = tree ]; then
              if [ "$sha" = "$(jq -r '.sha // empty' "$applied")" ] && [ -e "$dir/.flox/env/manifest.lock" ]; then
                log "$sha already applied; nothing to do."
                exit 0
              fi
            else
              appliedGen=$(jq -r '.generation // empty' "$applied")
              appliedEnv=$(jq -r '.env // empty' "$applied")
              meta=$(getent passwd "$user" | cut -d: -f6)/.local/share/flox/meta/$owner
              if [ "$gen" = "$appliedGen" ] && [ "$sourceEnv" = "$appliedEnv" ] \
                 && [ -L "$dir/.flox/run/$(uname -m)-linux.$envName.gen$gen-run" ] \
                 && [ "$(cat "$pinned" 2>/dev/null)" = "$gen" ] \
                 && git --git-dir="$meta" rev-parse --verify --quiet "refs/heads/$envName" >/dev/null 2>&1; then
                log "$what already applied; nothing to do."
                exit 0
              fi
            fi
          fi

          # FAIL CLOSED, as modules/deploy does: no inventory, no restart
          # decision, no pull. Checked before the clone so a box without a
          # quiet policy does not accumulate a checkout it will never
          # switch to.
          if [ ! -r "$inventory" ]; then
            refuse "cannot read $inventory -- the quiet policy is not optional."
          fi

          home=$(getent passwd "$user" | cut -d: -f6)
          if [ -z "$home" ]; then
            refuse "user $user has no home directory; flox needs one to activate as $user."
          fi
          group=$(id -gn "$user")
          # Drop to the tenant user for everything that touches the
          # checkout. --init-groups: supplementary groups from the user db,
          # as the stub unit gets. HOME is set explicitly because setpriv
          # leaves the environment alone (and --reset-env would also reset
          # PATH, taking git and flox with it). The XDG_* trio likewise, to
          # flox's own defaults under that HOME: the floxmeta clone the
          # floxhub kind's stub reads at every start lands under
          # XDG_DATA_HOME, and it must be where the stub (HOME from
          # systemd, no XDG_*) will look.
          as_user() {
            setpriv --reuid "$user" --regid "$group" --init-groups -- \
              env HOME="$home" XDG_DATA_HOME="$home/.local/share" XDG_CACHE_HOME="$home/.cache" XDG_CONFIG_HOME="$home/.config" "$@"
          }
          # git that can never ask anyone anything: no terminal prompt, no
          # global or system config (a credential manager configured there
          # would be consulted on a 401 -- on WSL that is a desktop dialog),
          # and the helper list reset. Every network-facing git call in
          # this script goes through here; a public remote answers or the
          # call fails, exit 128, and the timer retries.
          git_noprompt() {
            as_user env GIT_TERMINAL_PROMPT=0 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
              git -c credential.helper= "$@"
          }

          # The lock files whose outputs are realised substitute-only
          # below, one per line. The tree kind's is the checkout's; the
          # floxhub kind's come from FloxHub's record, read before flox
          # touches anything (header, step 1).
          locks=""
          scratch=""
          cleanup() { [ -n "$scratch" ] && rm -rf "$scratch"; }
          trap cleanup EXIT

          if [ "$kind" = tree ]; then
            if [ ! -d "$dir/.git" ]; then
              if [ -e "$dir" ] && [ -n "$(ls -A "$dir")" ]; then
                refuse "$dir exists and is not a git checkout -- refusing to overwrite it."
              fi
              install -d -o "$user" -g "$group" -m 0755 "$dir"
              log "cloning $remote into $dir as $user"
              git_noprompt clone --quiet --no-checkout "$remote" "$dir"
            fi
            as_user git -C "$dir" remote set-url origin "$remote"

            # Fetch only what is not already local, so a deferred restart
            # retried with the network down does not fail at the fetch. By
            # sha first (GitHub serves any reachable object), the whole
            # remote as the fallback for a server that does not. No
            # credential prompt: the remote is public or the fetch fails.
            if ! as_user git -C "$dir" cat-file -e "$sha^{commit}" 2>/dev/null; then
              log "fetching $sha from $remote"
              git_noprompt -C "$dir" fetch --quiet origin "$sha" \
                || git_noprompt -C "$dir" fetch --quiet origin
              if ! as_user git -C "$dir" cat-file -e "$sha^{commit}"; then
                refuse "$sha is not reachable from $remote -- staged from the wrong tree, or not pushed?"
              fi
            fi
            # A tracked file changed in place -- a `flox upgrade`/re-lock run
            # inside the checkout, say -- is refused, loudly, before the
            # checkout: git itself only refuses when the target commit touches
            # that file and otherwise carries the edit over silently, and a
            # drifted lock activated at the next sha is the drift this whole
            # edge exists to prevent. Untracked files (.flox/run, cache, log)
            # are the environment's own and not looked at. Only once there IS
            # a checkout: a fresh `clone --no-checkout` has HEAD and an empty
            # worktree, which `status` reports as every tracked file deleted,
            # and the first pull on the box (18 Sep 2026, 08:33) refused
            # itself on exactly that. Nothing can have been edited in place
            # before anything was checked out.
            dirty=""
            if as_user git -C "$dir" rev-parse --verify --quiet HEAD >/dev/null \
               && [ -n "$(as_user git -C "$dir" ls-files 2>/dev/null | head -1)" ]; then
              dirty=$(as_user git -C "$dir" status --porcelain --untracked-files=no)
            fi
            if [ -n "$dirty" ]; then
              refuse "$dir has tracked files changed in place (a hand edit or re-lock; land it or discard it):
          $dirty"
            fi
            as_user git -C "$dir" checkout --quiet --detach "$sha"
            if [ ! -f "$dir/.flox/env/manifest.toml" ]; then
              refuse "$dir at $sha has no .flox/env/manifest.toml -- not a flox environment."
            fi
            locks="$dir/.flox/env/manifest.lock"
          else
            # A checkout of the other kind, or a path environment, or a
            # tracking checkout of some other environment: never pulled
            # over. Only a dir that is empty/absent or already OUR tracking
            # checkout passes.
            if [ -d "$dir/.git" ]; then
              refuse "$dir is a git checkout (the tree kind's); refusing to pull a FloxHub environment over it."
            fi
            if [ -e "$dir/.flox/env.json" ]; then
              have=$(jq -r '"\(.owner // "")/\(.name // "")"' "$dir/.flox/env.json")
              if [ "$have" != "$sourceEnv" ]; then
                refuse "$dir/.flox/env.json is '$have', not a tracking checkout of $sourceEnv -- refusing to pull over it."
              fi
              if [ "$(jq -r '.local_rev' "$dir/.flox/env.lock" 2>/dev/null)" != null ]; then
                refuse "$dir has diverged from $sourceEnv (.flox/env.lock local_rev is set: a flox install/edit run there by hand). Push it from a dev checkout or remove $dir; not pulling over it."
              fi
            elif [ -e "$dir" ] && [ -n "$(ls -A "$dir")" ]; then
              refuse "$dir exists and is not a flox checkout -- refusing to overwrite it."
            fi
            # FloxHub's record, anonymously (header, step 1): generation
            # N's lock and the live generation's, since the pull builds the
            # live one and the activation builds N. Shallow, one branch,
            # as the tenant user, into scratch that the trap removes. The
            # one helper git gets is scoped to api.flox.dev and answers
            # user `oauth`, empty password -- a request with no
            # Authorization header at all is a 401, one with that pair is
            # a 200 (curl, 18 Sep 2026); flox's own logged-out git does
            # the same. Nothing else can be asked (git_noprompt).
            scratch=$(as_user mktemp -d -t "$tenant-floxmeta.XXXXXX")
            log "reading $sourceEnv's generations from FloxHub"
            if ! git_noprompt -c 'credential.https://api.flox.dev/git.helper=!f(){ echo username=oauth; echo password=; }; f' \
                 clone --quiet --bare --depth 1 --single-branch --branch "$envName" \
                 "https://api.flox.dev/git/$owner/floxmeta" "$scratch/floxmeta" </dev/null; then
              refuse "could not read $owner's floxmeta for '$envName' from api.flox.dev (no network, or the environment does not exist / is not public); leaving $pending staged for the next firing."
            fi
            metaGit() { as_user git --git-dir="$scratch/floxmeta" "$@"; }
            live=$(metaGit show "$envName:metadata.json" | jq -r '.history[-1].current_generation // empty')
            if ! metaGit cat-file -e "$envName:$gen/env/manifest.lock" 2>/dev/null; then
              refuse "generation $gen of $sourceEnv is not on FloxHub (live is ''${live:-unknown}); staged before it was pushed? leaving $pending staged."
            fi
            metaGit show "$envName:$gen/env/manifest.lock" > "$scratch/gen$gen.lock"
            locks="$scratch/gen$gen.lock"
            if [ -n "$live" ] && [ "$live" != "$gen" ]; then
              metaGit show "$envName:$live/env/manifest.lock" > "$scratch/gen$live.lock"
              locks="$locks
          $scratch/gen$live.lock"
            fi
          fi

          # THE WARM NEVER COMPILES. The tenant user's nix goes through
          # nix-daemon, which builds in system.slice at nice 0 on every
          # core; a lock naming a path no trusted cache has (agent-hub's
          # two flake packages live in CI's MinIO bucket) would turn this
          # step into an unfenced compile of llama.cpp on the box. So every
          # output the lock names for this system is realised
          # SUBSTITUTE-ONLY first (--max-jobs 0: fetch or fail, never
          # build), and a miss is a refusal that names the cause and leaves
          # the record staged for the next firing -- a cache fixed later
          # (the MinIO substituter, ac-box's nix.nix) is then all it takes.
          # Not put on `flox activate` itself: that also refuses flox's own
          # manifest.drv/environment.drv, which are tiny and must build.
          # EVERY output, not only outputs-to-install: flox realises the
          # whole derivation, and a derivation builds all its outputs at
          # once, so one output absent from every cache is a full compile.
          # That is what happened on the first pull on the box (18 Sep
          # 2026, 08:53): stable-diffusion-cpp's `out` was in MinIO and its
          # `dev` was not (the plugin pushed the environment's closure,
          # which links only `out`), and sd.cpp compiled for three minutes
          # at SCHED_BATCH while this step reported success. The plugin now
          # pushes every lock output too; this side demands them. For the
          # floxhub kind this runs BEFORE `flox pull`, which would build.
          log "substituting the store paths the lock(s) name (never building them)"
          # shellcheck disable=SC2086  # $locks is newline-separated paths, split on purpose
          if ! jq -r --arg s "$(uname -m)-linux" '
                .packages[] | select(.system == $s) | .outputs[]
              ' $locks | sort -u \
              | as_user xargs nix-store --realise --max-jobs 0 >/dev/null; then
            refuse "a store path the lock names is in no substituter this box trusts (cache.flox.dev, MinIO); refusing to compile it here; leaving $pending staged."
          fi

          # THE ONE ONLINE ACTIVATION. With every package path present flox
          # builds only its buildenv and evaluates no flake ref. Fails soft:
          # exit 1, the record is not written, the timer retries.
          # FLOX_DISABLE_METRICS as the stub sets it; nothing here phones
          # home either.
          if [ "$kind" = tree ]; then
            log "activating $dir once, online, as $user (pins the GC roots)"
            if ! as_user env FLOX_DISABLE_METRICS=true "$flox" activate -d "$dir" -- true; then
              refuse "flox activate failed at $sha; leaving $pending staged for the next firing."
            fi
          else
            # The pull (header, step 2): first time with the ref, after
            # that without. Both need api.flox.dev; both fail soft.
            if [ ! -e "$dir/.flox/env.json" ]; then
              install -d -o "$user" -g "$group" -m 0755 "$dir"
              log "pulling $sourceEnv into $dir as $user (tracking checkout)"
              if ! as_user env FLOX_DISABLE_METRICS=true "$flox" pull -d "$dir" "$sourceEnv" </dev/null; then
                refuse "flox pull of $sourceEnv failed; leaving $pending staged for the next firing."
              fi
            else
              log "updating the $sourceEnv checkout at $dir"
              if ! as_user env FLOX_DISABLE_METRICS=true "$flox" pull -d "$dir" </dev/null; then
                refuse "flox pull in $dir failed; leaving $pending staged for the next firing."
              fi
            fi
            if [ "$(jq -r '.local_rev' "$dir/.flox/env.lock" 2>/dev/null)" != null ]; then
              refuse "$dir has diverged from $sourceEnv after the pull (local_rev set); not pinning it."
            fi
            # What the pulled copy says is live, for the journal: flox's
            # own generation record (docs/flox-findings.md 3), read offline
            # from the checkout. `-g N` below pins N whatever this says.
            pulledLive=$(as_user "$flox" generations list -d "$dir" --json </dev/null 2>/dev/null \
              | jq -r 'to_entries[] | select(.value.last_live == null) | .key' | head -1)
            log "pulled $sourceEnv at upstream $(jq -r '.rev' "$dir/.flox/env.lock" | cut -c1-7) (live generation ''${pulledLive:-unknown}); pinning $gen"
            # The pinned warm (header, step 3): the stub's own command.
            log "activating generation $gen of $sourceEnv at $dir once, as $user (pins its GC roots)"
            if ! as_user env FLOX_DISABLE_METRICS=true "$flox" activate -d "$dir" -g "$gen" -- true </dev/null; then
              refuse "flox activate -g $gen failed; leaving $pending staged for the next firing."
            fi
            # The pin (header, step 4): what the stub activates from now
            # on, before the restart that makes it so.
            tmp="$pinned.tmp.$$"
            printf '%s\n' "$gen" > "$tmp"
            chmod 0644 "$tmp"
            mv -f "$tmp" "$pinned"
          fi

          # The content stamp (docs/flox-findings.md 3): the store path
          # .flox/run/<system>.<name>-run (the tree kind) or
          # .flox/run/<system>.<name>.genN-run (floxhub) resolves to.
          # Recorded so hub-status can tell two checkouts of different
          # content apart even at the same sha or generation. The link is
          # named from .flox/env.json's `name`, not the directory.
          runName=$(jq -r '.name // empty' "$dir/.flox/env.json")
          if [ "$kind" = tree ]; then
            runLink="$dir/.flox/run/$(uname -m)-linux.$runName-run"
          else
            runLink="$dir/.flox/run/$(uname -m)-linux.$runName.gen$gen-run"
          fi
          runPath=""
          if [ -L "$runLink" ]; then
            runPath=$(readlink "$runLink")
          else
            log "warning: $runLink is not a symlink after activation; recording no run path." >&2
          fi

          if [ -z "$restartUnits" ]; then
            log "environment.enable is off for $tenant: $what warmed at $dir, no unit restarted."
          else
            # THIS tenant's quiet policy only. busyCheck's contract
            # (schema.nix): exit 0 means BUSY; 126/127 means the question
            # could not be asked, which is a deferral.
            drainable=$(jq -r --arg t "$tenant" '.tenants[] | select(.name == $t) | .quiet.drainable' "$inventory")
            case "$drainable" in
              true) ;;
              false)
                check=$(jq -r --arg t "$tenant" '.tenants[] | select(.name == $t) | .quiet.busyCheck // empty' "$inventory")
                if [ -z "$check" ]; then
                  log "$tenant is not drainable and has no busyCheck; a human restarts it. $what is warmed; deferring."
                  exit 0
                fi
                if sh -c "$check"; then rc=0; else rc=$?; fi
                if [ "$rc" -eq 0 ]; then
                  log "$tenant is busy; deferring the restart to $what."
                  exit 0
                elif [ "$rc" -eq 126 ] || [ "$rc" -eq 127 ]; then
                  log "$tenant's busyCheck could not run (exit $rc: $check); deferring rather than guessing." >&2
                  exit 0
                fi
                ;;
              *)
                refuse "$tenant is not in $inventory -- refusing to restart a tenant the box does not know."
                ;;
            esac
            for unit in $restartUnits; do
              log "restarting $unit from $dir at $what"
              systemctl restart "$unit"
            done
          fi

          # After the restart, never before: a failed or deferred restart
          # must leave staged != applied.
          tmp="$applied.tmp.$$"
          if [ "$kind" = tree ]; then
            jq -cn \
              --arg sha "$sha" \
              --arg run "$runPath" \
              --arg dir "$dir" \
              --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
              --arg units "$restartUnits" \
              '{sha: $sha, run_path: (if $run == "" then null else $run end), dir: $dir, applied_at: $at, restarted: ($units | split(" ") | map(select(. != "")))}' \
              > "$tmp"
          else
            jq -cn \
              --arg env "$sourceEnv" \
              --argjson gen "$gen" \
              --arg run "$runPath" \
              --arg dir "$dir" \
              --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
              --arg units "$restartUnits" \
              '{env: $env, generation: $gen, run_path: (if $run == "" then null else $run end), dir: $dir, applied_at: $at, restarted: ($units | split(" ") | map(select(. != "")))}' \
              > "$tmp"
          fi
          mv -f "$tmp" "$applied"
          log "applied $what (run ''${runPath:-unknown})"
        '';
      };
    in
    {
      inherit
        name
        t
        env
        kind
        sourceEnv
        dir
        pinned
        registryRemote
        remote
        stubs
        unitUsers
        user
        restartUnits
        pending
        applied
        sliceable
        script
        ;
    };

  pulls = lib.mapAttrs mkPull pullTenants;

  unitName = name: "${name}-environment-pull";
in
{
  options.homelab.environments = {
    stateDir = mkOption {
      type = types.path;
      default = "/var/lib/homelab";
      description = ''
        Holds pending-environment-<tenant>.json (written by the tenant's
        CI through scripts/hub-queue-environment.sh) and
        last-applied-environment-<tenant>.json (written here). The same
        directory as homelab.deploy.stateDir, beside the closure's pair,
        because both are the box's deploy records; declared here rather
        than read from modules/deploy so this module stands without it.
      '';
    };

    inventoryFile = mkOption {
      type = types.path;
      default = "/etc/homelab/tenants.json";
      description = ''
        The tenant inventory quiet.nix writes; the tenant's quiet policy is
        read from it at RUN time. Same option, same reason, as
        homelab.deploy.inventoryFile.
      '';
    };

    registry = mkOption {
      type = types.path;
      default = ../../hub/repos.psv;
      description = ''
        hub/repos.psv, the trees this hub coordinates. A tenant's
        environment.tree must name one, and its remote is what the pull
        clones. An option only so the refusal can be exercised against a
        fixture.
      '';
    };

    retryInterval = mkOption {
      type = types.str;
      default = "10min";
      description = ''
        How often a pull that was deferred (tenant busy) or failed (no
        network for the one online activation) is retried, and how long
        a firing missed across a reboot waits. The path unit applies an
        ordinary stage the moment CI writes it; this is the retry only,
        the same shape as homelab.deploy.retryInterval.
      '';
    };

    pull = mkOption {
      type = types.attrsOf types.package;
      readOnly = true;
      default = lib.mapAttrs (_: p: p.script) pulls;
      defaultText = lib.literalMD "the generated <tenant>-environment-pull script per tenant with a stub declared";
      description = ''
        Read-only: the script each pull unit runs, so the decisions baked
        into it at evaluation time -- the remote, the owner, whether the
        stub is restarted -- can be read without a box, and asserted by
        tests/eval-environment.nix. homelab.deploy.scriptPackage's shape.
      '';
    };
  };

  config = mkIf (pulls != { }) {
    assertions = lib.flatten (
      lib.mapAttrsToList (name: p: [
        {
          assertion = p.kind != "tree" || p.registryRemote != "";
          message = ''
            homelab.tenants.${name}.environment.tree = "${p.env.tree}" names
            no tree in ${toString cfg.registry} (or one without a remote).
            The pull unit clones the registry's remote; a tree the hub does
            not coordinate has nothing to pull from.
          '';
        }
        {
          # `env` iff kind = floxhub -- schema.nix's rule, enforced here.
          assertion = (p.kind == "floxhub") == (p.env.source.env != null);
          message = ''
            homelab.tenants.${name}.environment.source: kind = "${p.kind}"
            ${
              if p.kind == "floxhub" then
                "needs `env` (\"owner/name\", the FloxHub environment to pull)"
              else
                "does not take `env` (\"${toString p.env.source.env}\"); set kind = \"floxhub\" or drop it"
            }.
          '';
        }
        {
          assertion =
            p.kind != "floxhub"
            || p.env.source.env == null
            || builtins.match "[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+" p.sourceEnv != null;
          message = ''
            homelab.tenants.${name}.environment.source.env = "${p.sourceEnv}"
            is not "owner/name". The pull unit splits it on the one slash
            to reach https://api.flox.dev/git/<owner>/floxmeta and the
            <name> branch there.
          '';
        }
        {
          assertion = p.dir != "";
          message = ''
            homelab.tenants.${name}.environment.dir is null: the derived
            default is supplied by modules/tenant/environment.nix, which is
            not imported here. Import it beside environment-pull.nix.
          '';
        }
        {
          assertion = builtins.length p.unitUsers == 1;
          message = ''
            homelab.tenants.${name}.environment.units run as different
            users (${lib.concatStringsSep ", " p.unitUsers}); one checkout
            has one owner. Split them into two tenants or align User=.
          '';
        }
      ]) pulls
    );

    systemd.services = lib.mapAttrs' (
      name: p:
      lib.nameValuePair (unitName name) {
        description = "Pull the staged ${name} environment: checkout, warm once online, restart the stub";

        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];

        # The tenant's busyCheck is written for the box's shell (deploy's
        # 15 Sep 2026 lesson: a unit's PATH has no sh); the system profile
        # is the PATH it was written against.
        path = [ "/run/current-system/sw" ];

        restartIfChanged = false;

        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe p.script;
          SuccessExitStatus = [ 0 ];
        }
        // lib.optionalAttrs p.sliceable {
          Slice = "${p.t.tier}.slice";
          Nice = config.homelab.tiers.${p.t.tier}.nice;
        };
      }
    ) pulls;

    # Apply the moment CI stages one. PathChanged fires on the rename
    # hub-queue-environment.sh ends with.
    systemd.paths = lib.mapAttrs' (
      name: p:
      lib.nameValuePair (unitName name) {
        description = "Watch for a newly staged ${name} environment";
        wantedBy = [ "paths.target" ];
        pathConfig = {
          PathChanged = p.pending;
          Unit = "${unitName name}.service";
        };
      }
    ) pulls;

    # The retry: a deferred restart (nothing rewrites the file when the
    # tenant goes idle), a soft-failed warm, a firing missed over a reboot.
    systemd.timers = lib.mapAttrs' (
      name: _:
      lib.nameValuePair (unitName name) {
        description = "Retry a deferred or failed ${name} environment pull";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = cfg.retryInterval;
          OnUnitActiveSec = cfg.retryInterval;
          AccuracySec = "1min";
        };
      }
    ) pulls;

    # The state directory exists before the path units arm on files inside
    # it -- a host with a stub and homelab.deploy off would otherwise watch
    # a directory nothing creates. Same rule modules/deploy carries; the
    # duplicate line on a host with both is a tmpfiles warning, not an
    # error.
    systemd.tmpfiles.rules = [ "d ${toString cfg.stateDir} 0755 root root -" ];

    # What the running closure says about its environments, for hub-status
    # (which reads the pending/applied pair beside it), hub-backup.sh (dir
    # and user) and anyone at the box: which tenants have one, where, of
    # which source kind, and whether the stub is on -- the last being the
    # fact that decides whether a restart from the checkout is what the
    # unit does today. One line of JSON with flat keys (`source` is the
    # kind, `env` the FloxHub environment or null), because hub-status
    # reads it with grep over ssh and the box has no jq on its path.
    environment.etc."homelab/environments.json" = {
      mode = "0444";
      text = builtins.toJSON {
        generated = "modules/tenant/environment-pull.nix";
        environments = lib.mapAttrs (name: p: {
          source = p.kind;
          env = if p.kind == "floxhub" then p.sourceEnv else null;
          tree = p.env.tree;
          remote = if p.kind == "tree" then p.registryRemote else null;
          dir = p.dir;
          enable = p.env.enable;
          units = p.stubs;
          user = p.user;
          pending = p.pending;
          applied = p.applied;
          pinned = if p.kind == "floxhub" then p.pinned else null;
          unit = "${unitName name}.service";
        }) pulls;
      };
    };
  };
}
