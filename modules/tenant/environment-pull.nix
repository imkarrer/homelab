# The pull unit for a flox tenant: the applying half of ADR 0009's deploy
# edge, mirroring modules/deploy (ADR 0006) exactly one layer down.
#
#   closure   CI stages a rev in pending-closure.json       -> homelab-deploy switches
#   tenant    CI stages a sha in pending-environment-<t>.json -> <t>-environment-pull checks
#             it out, warms it, restarts the stub
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
      # Already resolved: environment.nix supplies the derived default at
      # the submodule level (null only where that module is not imported,
      # which the assertion below names rather than re-deriving here).
      dir = if env.dir == null then "" else toString env.dir;
      registryRemote = remoteFor env.tree;
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
        ];
        text = ''
          tenant=${lib.escapeShellArg name}
          pending=${lib.escapeShellArg pending}
          applied=${lib.escapeShellArg applied}
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

          appliedSha=""
          if [ -e "$applied" ]; then
            appliedSha=$(jq -r '.sha // empty' "$applied")
          fi
          if [ "$sha" = "$appliedSha" ] && [ -e "$dir/.flox/env/manifest.lock" ]; then
            log "$sha already applied; nothing to do."
            exit 0
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
          # PATH, taking git and flox with it).
          as_user() {
            setpriv --reuid "$user" --regid "$group" --init-groups -- env HOME="$home" "$@"
          }

          if [ ! -d "$dir/.git" ]; then
            if [ -e "$dir" ] && [ -n "$(ls -A "$dir")" ]; then
              refuse "$dir exists and is not a git checkout -- refusing to overwrite it."
            fi
            install -d -o "$user" -g "$group" -m 0755 "$dir"
            log "cloning $remote into $dir as $user"
            as_user git clone --quiet --no-checkout "$remote" "$dir"
          fi
          as_user git -C "$dir" remote set-url origin "$remote"

          log "fetching $sha from $remote"
          # By sha first (GitHub serves any reachable object), the whole
          # remote as the fallback for a server that does not.
          as_user git -C "$dir" fetch --quiet origin "$sha" \
            || as_user git -C "$dir" fetch --quiet origin
          if ! as_user git -C "$dir" cat-file -e "$sha^{commit}"; then
            refuse "$sha is not reachable from $remote -- staged from the wrong tree, or not pushed?"
          fi
          as_user git -C "$dir" checkout --quiet --detach "$sha"
          if [ ! -f "$dir/.flox/env/manifest.toml" ]; then
            refuse "$dir at $sha has no .flox/env/manifest.toml -- not a flox environment."
          fi

          # THE ONE ONLINE ACTIVATION. Fails soft: exit 1, the record is not
          # written, the timer retries. FLOX_DISABLE_METRICS as the stub
          # sets it; nothing here phones home either.
          log "activating $dir once, online, as $user (warms the store, pins the GC roots)"
          if ! as_user env FLOX_DISABLE_METRICS=true "$flox" activate -d "$dir" -- true; then
            refuse "flox activate failed at $sha; leaving $pending staged for the next firing."
          fi

          # The content stamp (docs/flox-findings.md 3): the store path
          # .flox/run/<system>.<name>-run resolves to. Recorded so
          # hub-status can tell two checkouts of different content apart
          # even at the same sha.
          envName=$(jq -r '.name // empty' "$dir/.flox/env.json")
          runLink="$dir/.flox/run/$(uname -m)-linux.$envName-run"
          runPath=""
          if [ -L "$runLink" ]; then
            runPath=$(readlink "$runLink")
          else
            log "warning: $runLink is not a symlink after activation; recording no run path." >&2
          fi

          if [ -z "$restartUnits" ]; then
            log "environment.enable is off for $tenant: checkout at $sha warmed, no unit restarted."
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
                  log "$tenant is not drainable and has no busyCheck; a human restarts it. Checkout at $sha is warmed; deferring."
                  exit 0
                fi
                if sh -c "$check"; then rc=0; else rc=$?; fi
                if [ "$rc" -eq 0 ]; then
                  log "$tenant is busy; deferring the restart to $sha."
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
              log "restarting $unit from $dir at $sha"
              systemctl restart "$unit"
            done
          fi

          # After the restart, never before: a failed or deferred restart
          # must leave staged != applied.
          tmp="$applied.tmp.$$"
          jq -cn \
            --arg sha "$sha" \
            --arg run "$runPath" \
            --arg dir "$dir" \
            --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            --arg units "$restartUnits" \
            '{sha: $sha, run_path: (if $run == "" then null else $run end), dir: $dir, applied_at: $at, restarted: ($units | split(" ") | map(select(. != "")))}' \
            > "$tmp"
          mv -f "$tmp" "$applied"
          log "applied $sha (run ''${runPath:-unknown})"
        '';
      };
    in
    {
      inherit
        name
        t
        env
        dir
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
          assertion = p.registryRemote != "";
          message = ''
            homelab.tenants.${name}.environment.tree = "${p.env.tree}" names
            no tree in ${toString cfg.registry} (or one without a remote).
            The pull unit clones the registry's remote; a tree the hub does
            not coordinate has nothing to pull from.
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

    # What the running closure says about its environments, for hub-status
    # (which reads the pending/applied pair beside it) and for anyone at the
    # box: which tenants have one, where, from which tree, and whether the
    # stub is on -- the last being the fact that decides whether a restart
    # from the checkout is what the unit does today.
    environment.etc."homelab/environments.json" = {
      mode = "0444";
      text = builtins.toJSON {
        generated = "modules/tenant/environment-pull.nix";
        environments = lib.mapAttrs (name: p: {
          tree = p.env.tree;
          remote = p.registryRemote;
          dir = p.dir;
          enable = p.env.enable;
          units = p.stubs;
          user = p.user;
          pending = p.pending;
          applied = p.applied;
          unit = "${unitName name}.service";
        }) pulls;
      };
    };
  };
}
