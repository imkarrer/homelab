# The system closure's deploy path: the applying half of ADR 0006.
#
# Read docs/adr/0006-closure-deploy-path.md before changing anything here.
# The short version, because it is the whole reason this file exists rather
# than a Buildkite step:
#
#   ac-host-ci-agent-1 -- the Buildkite agent that would otherwise run the
#   switch -- is a container ON ac-box, and once homelab.ci.enable lands it is
#   a systemd unit owned by the very closure being switched. A `nixos-rebuild
#   switch` step running on that agent kills the process running the job
#   partway through. See modules/ci/default.nix's HAZARD 2. That is a
#   circularity, not a risk to be managed, so the applying step must run
#   OUTSIDE the agent, as something systemd owns. This unit is that.
#
# CI's half is to stage a revision into pending-closure.json and stop. It
# writes a file and bounces nothing, so it is immune to the hazard above. This
# unit reads that file, checks the quiet policy, and switches.
#
# --------------------------------------------------------------------------
# INERT BY DEFAULT, deliberately
# --------------------------------------------------------------------------
# homelab.deploy.enable defaults false and nothing sets it, so importing this
# module contributes nothing to the closure -- the same discipline modules/ci
# was imported under, and provable the same way (compare
# nixosConfigurations.ac-box's toplevel drvPath before and after the import).
#
# Turning it true makes ac-box self-switching: a merge to main changes the
# running system with nobody present. That is the chosen design, not an
# accident of it (ADR 0006, "Consequences"), but it is a separate, deliberate
# flip and it has a precondition that is not satisfied yet -- see the gate
# below.
#
# --------------------------------------------------------------------------
# GATE -- do not flip enable until this is true
# --------------------------------------------------------------------------
# Every tree that reaches the box must have a real evaluation gate, because
# once this unit is on, those gates are the only thing between a merge and a
# live system. scripts/hub-gates.sh now evaluates module-only trees through
# the host that composes them, which closed the case where home-arcade,
# ac-host and agent-hub had no Nix gate at all.
#
# What is still open: a composed eval proves what is REACHABLE from ac-box's
# config, not a whole module. agent-hub is imported with
# services.agent-hub.enable defaulting false, so its gate proves its option
# declarations compose and very little of its config body. That is fine while
# a human runs the switch. It is thinner than it looks when nobody does.
{ config, lib, pkgs, ... }:

let
  inherit (lib) mkOption mkIf types;

  cfg = config.homelab.deploy;
  host = config.homelab.host;

  pendingFile = "${cfg.stateDir}/pending-closure.json";
  appliedFile = "${cfg.stateDir}/last-applied-closure.json";

  inventory = cfg.inventoryFile;

  # "03:00" + 30 -> "03:30". One arithmetic, two consumers: the window
  # schedule's OnCalendar (the only firing) and the continuous schedule's
  # blackout end (the moment ordinary firing resumes). They are the same
  # instant for the same reason, so they are the same expression.
  windowEnd =
    let
      parts = lib.splitString ":" host.maintenance.window;
      h = lib.toIntBase10 (builtins.elemAt parts 0);
      m = lib.toIntBase10 (builtins.elemAt parts 1);
      total = h * 60 + m + cfg.windowOffsetMinutes;
      hh = lib.fixedWidthNumber 2 ((total / 60) - 24 * (total / 1440));
      mm = lib.fixedWidthNumber 2 (total - 60 * (total / 60));
    in
    "${hh}:${mm}";

  deployScript = pkgs.writeShellApplication {
    name = "homelab-deploy";
    runtimeInputs = [
      pkgs.jq
      pkgs.coreutils
      config.nix.package
      config.system.build.nixos-rebuild
    ];
    text = ''
      pending=${lib.escapeShellArg pendingFile}
      applied=${lib.escapeShellArg appliedFile}
      inventory=${lib.escapeShellArg inventory}
      flake=${lib.escapeShellArg cfg.flake}
      host=${lib.escapeShellArg host.name}
      # Empty under the window schedule: the timer already fires only once,
      # after the window, so there is nothing for a blackout to exclude.
      blackoutStart=${lib.escapeShellArg (if cfg.schedule == "continuous" then host.maintenance.window else "")}
      blackoutEnd=${lib.escapeShellArg windowEnd}

      if [ ! -e "$pending" ]; then
        echo "homelab-deploy: nothing staged at $pending; nothing to do."
        exit 0
      fi

      # The one time of day this unit stays out of: the tenant tree's own
      # deploy. At the window's start the bot queues DOWNTIME=1, and that
      # build drains the lobbies, applies the tree, recycles the lobbies and
      # resumes -- minutes of docker work. Under ADR 0006's single firing the
      # offset kept the two apart by construction; under the continuous
      # schedule nothing does, and the drain is precisely what makes
      # busyCheck say "not busy" while the box is at its most occupied.
      # So the window is a blackout, and the offset that used to be the only
      # firing time is now the moment the blackout lifts.
      if [ -n "$blackoutStart" ]; then
        now=$(date +%H:%M)
        if [ "$now" ">" "$blackoutStart" ] || [ "$now" = "$blackoutStart" ]; then
          if [ "$now" "<" "$blackoutEnd" ]; then
            echo "homelab-deploy: $now is inside the tenant tree's window ($blackoutStart-$blackoutEnd); deferring."
            exit 0
          fi
        fi
      fi

      rev=$(jq -r '.rev // empty' "$pending")
      if [ -z "$rev" ]; then
        echo "homelab-deploy: $pending has no .rev -- refusing to guess." >&2
        exit 1
      fi

      appliedRev=""
      if [ -e "$applied" ]; then
        appliedRev=$(jq -r '.rev // empty' "$applied")
      fi

      if [ "$rev" = "$appliedRev" ]; then
        echo "homelab-deploy: $rev already applied; nothing to do."
        exit 0
      fi

      # FAIL CLOSED. An unreadable inventory means the quiet policy cannot be
      # consulted, and a switch that cannot consult it is a switch that might
      # `docker rm -f` three live race servers. Refusing is the safe answer and
      # a non-zero exit is the loud one -- this is the single most important
      # branch in the file (ADR 0006: "It must defer, not drain, and it must
      # fail closed if /etc/homelab/tenants.json is unreadable").
      if [ ! -r "$inventory" ]; then
        echo "homelab-deploy: cannot read $inventory -- refusing to switch." >&2
        echo "  The quiet policy is not optional. Is homelab.enforce.inventory on?" >&2
        exit 1
      fi

      # Defer, never drain. A tenant that declares drainable = false has said
      # that bouncing it needs a human decision; running its own `drain`
      # command here would be this unit making that decision unasked. So the
      # only question asked is "are you busy?", and a busy tenant postpones the
      # switch to the next firing.
      #
      # busyCheck's contract (schema.nix): exit 0 means BUSY.
      #
      # A function, not a straight-line loop, because it is asked TWICE: once
      # before the build and once in the last moment before the switch. Under
      # ADR 0008's continuous schedule the build can run at 19:00 and take
      # minutes, and "nobody was racing when this started" is not the question
      # -- "nobody is racing now" is.
      busy() {
        local name check rc
        while IFS=$'\t' read -r name check; do
          [ -n "$name" ] || continue
          # Exit 0 is busy. Everything else used to be "not busy", which is
          # how `sh: command not found` (127) switched a box on 15 Sep 2026
          # without ever asking the lobbies. A check that could not RUN --
          # 126 (not executable) or 127 (not found) -- is an unanswered
          # question, and an unanswered question is a deferral, not a
          # switch. The same fail-closed rule as the inventory check above.
          if sh -c "$check"; then rc=0; else rc=$?; fi
          if [ "$rc" -eq 0 ]; then
            echo "homelab-deploy: $name is busy; deferring $rev."
            return 0
          elif [ "$rc" -eq 126 ] || [ "$rc" -eq 127 ]; then
            echo "homelab-deploy: $name's busyCheck could not run (exit $rc: $check); deferring $rev rather than guessing." >&2
            return 0
          fi
        done < <(
          jq -r '
            .tenants[]
            | select(.quiet.drainable == false)
            | select(.quiet.busyCheck != null)
            | "\(.name)\t\(.quiet.busyCheck)"
          ' "$inventory"
        )
        return 1
      }

      busy && exit 0

      # Build first, switch second, and ask again in between.
      #
      # `nixos-rebuild switch` would do both in one step, and under ADR 0006's
      # single 03:30 firing that was right: the lobbies were empty for the
      # whole of it. Under the continuous schedule the build is the long part
      # (minutes, if MinIO does not already have the closure) and it is exactly
      # when someone can join a lobby. Splitting them means the race between
      # the check and the switch is a `switch-to-configuration` against a warm
      # store -- seconds -- instead of a whole build.
      #
      # --no-link: nothing here should own a gcroot. The store path lives
      # until the next GC, and the switch below re-resolves it in seconds
      # rather than trusting a path this script passed along.
      echo "homelab-deploy: building $rev"
      nix build --no-link "$flake/$rev#nixosConfigurations.$host.config.system.build.toplevel"

      busy && exit 0

      echo "homelab-deploy: switching to $rev"
      nixos-rebuild switch --flake "$flake/$rev#$host"

      # Written only after a successful switch, so a failed one leaves the
      # pending record intact and the next firing retries it rather than
      # recording a lie.
      printf '{"rev":%s,"applied_at":%s}\n' \
        "$(jq -Rn --arg v "$rev" '$v')" \
        "$(jq -Rn --arg v "$(date -Is)" '$v')" \
        > "$applied"

      echo "homelab-deploy: applied $rev"
    '';
  };
in
{
  options.homelab.deploy = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Apply the revision staged in pending-closure.json, inside the
        maintenance window, unattended. Defaults false: flipping it makes this
        box self-switching, which is ADR 0006's deliberate choice but is a
        separate step from importing the module, and is gated on every tree
        that reaches the box having a real evaluation gate. See this file's
        header.
      '';
    };

    flake = mkOption {
      type = types.str;
      default = "github:imkarrer/homelab";
      description = ''
        Flake ref to switch to, WITHOUT a revision -- the revision comes from
        pending-closure.json and is appended at run time. Deliberately not a
        local path: the box building from a checkout it also hosts is how the
        tenant tree's rsync deploy works, and the whole point of the closure
        path is that it is fetched by revision instead.
      '';
    };

    inventoryFile = mkOption {
      type = types.path;
      default = "/etc/homelab/tenants.json";
      description = ''
        The tenant inventory quiet.nix writes, carrying each tenant's
        drainable/busyCheck policy. Read at RUN time, not evaluation time: the
        file that matters is the one on the box when the timer fires, not the
        one this module was built alongside. They are usually the same, and the
        exception is exactly the interesting case -- a switch that is about to
        change the tenant set.

        An option rather than a hardcoded path purely so the defer path can be
        exercised against a fixture. That branch decides whether a switch waits
        for live race servers or bounces them, and a branch that can only be
        tested by being wrong in production is not tested.
      '';
    };

    schedule = mkOption {
      type = types.enum [ "window" "continuous" ];
      default = "window";
      description = ''
        WHEN a staged revision is applied. ADR 0008.

        "window" (ADR 0006, the default): once a night, at
        homelab.host.maintenance.window + windowOffsetMinutes. Everything
        waits for 03:30 -- a firewall rule, a tier share, a dashboard --
        and the operator can say "nothing on this box changes outside the
        window" and be right. Latency from push to live is up to 27 hours.

        "continuous": apply as soon as CI stages it, and defer ONLY while a
        tenant says it is busy. On ac-box that means: switch now unless
        someone is racing, and when the last driver leaves, apply whatever
        is staged by then. The operator decided this 15 Sep 2026, and the
        decision is not about racing -- the lobbies are out of the
        closure's reach either way (ADR 0008's Context) -- but about
        arcade's file share and game servers, and the observability stack,
        being allowed to bounce at any hour rather than at 03:30 only.

        Two things follow, both handled here rather than left to the
        operator: the build now happens while people may be using the box,
        so the unit is niced and the busy question is asked again after it;
        and the tenant tree's own window becomes a blackout, because a
        drained lobby reads as "not busy" exactly when the box is busiest.
      '';
    };

    retryInterval = mkOption {
      type = types.str;
      default = "10min";
      description = ''
        schedule = "continuous" only: how often a deferred revision is
        retried, as a systemd time span. The path unit applies a staged
        revision the moment CI writes it, so this interval is not the
        latency of an ordinary deploy -- it is how long after the last
        driver leaves the lobby that the waiting revision lands, and how
        long a firing missed over a reboot waits.

        Ten minutes rather than one: each firing runs every tenant's
        busyCheck, and assetto's shells out to python against the racing
        tree. A minute would make that a background process on the box
        forever; ten makes it invisible and is still well inside "nobody
        noticed it was waiting".
      '';
    };

    windowOffsetMinutes = mkOption {
      type = types.ints.between 0 120;
      default = 30;
      description = ''
        Minutes after homelab.host.maintenance.window at which the timer
        fires -- and, under schedule = "continuous", the minute at which the
        blackout over that window lifts. Default 30, and not 0, because the
        window is already taken:
        at 03:00 sharp the Discord bot queues DOWNTIME=1, and that build
        drains the lobbies, applies the tenant tree, recycles the lobbies
        once and resumes -- a few minutes of docker work. Firing the
        closure switch into the middle of that is not dangerous (the switch
        never touches ac-host-static; the two do not share units) but it is
        two operators in one room. Thirty minutes later the recycle is done,
        the lobbies are empty, and drivers_online.py says so. Set to 0 only
        on a host with no tenant-tree downtime job of its own.
      '';
    };

    scriptPackage = mkOption {
      type = types.package;
      readOnly = true;
      default = deployScript;
      defaultText = lib.literalMD "the generated homelab-deploy script";
      description = ''
        Read-only: the script the unit runs, so the decisions baked into it
        at evaluation time can be read without switching a box --

          nix eval --raw .#nixosConfigurations.ac-box.config.homelab.deploy.scriptPackage
          cat <that>/bin/homelab-deploy

        Same purpose as agent-hub's llm.swapConfigFile. It is also what lets
        the eval harness assert that the blackout is present under one
        schedule and absent under the other, which is otherwise a fact no
        test can see and no operator can check short of 03:00.
      '';
    };

    stateDir = mkOption {
      type = types.path;
      default = "/var/lib/homelab";
      description = ''
        Holds pending-closure.json (written by CI) and last-applied-closure.json
        (written here). Deliberately NOT /var/lib/ac-host: that is the racing
        tenant's state directory, and the closure's deploy record is a platform
        fact, not a tenant one.
      '';
    };
  };

  config = mkIf cfg.enable {
    systemd.services.homelab-deploy = {
      description = "Apply the staged homelab system closure";

      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      # The busy question is a tenant's own command, written for the box's
      # shell: assetto's is `python3 /var/lib/ac-host/src/scripts/...; test
      # $? -ne 1`. It runs under THIS unit's PATH, and a systemd unit's PATH
      # on NixOS is coreutils, findutils, grep, sed and systemd -- no sh, no
      # python3. Found 15 Sep 2026, in the journal of the first hand-started
      # firing: `line 56: sh: command not found`, exit 127, which the `if`
      # read as "not busy". The racing gate had been failing OPEN since ADR
      # 0006 was written; it never mattered at 03:30 with the lobbies empty,
      # and under ADR 0008 it is the only brake. So the unit gets the system
      # profile, which is the PATH the tenant wrote its command against, and
      # the script refuses (fails closed) if a check cannot be run at all.
      path = [ "/run/current-system/sw" ];

      # The self-reference hazard, one level in from HAZARD 2. A switch that
      # changes this unit would otherwise restart it mid-run -- i.e. kill the
      # `nixos-rebuild` that is doing the switching. Same shape as the
      # Buildkite case, same answer: the thing doing the restarting must not be
      # in the set being restarted.
      restartIfChanged = false;

      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe deployScript;
        # A deferral is a normal outcome, not a failure, and the script exits 0
        # for it -- so any non-zero here is a real problem worth a failed unit
        # and an alert, rather than noise the operator learns to ignore.
        SuccessExitStatus = [ 0 ];
      }
      // lib.optionalAttrs (cfg.schedule == "continuous") {
        # The build has moved into the day (ADR 0008's Consequences), so it
        # yields to everything: races on the unfenced cores, the model server
        # at CPUWeight 700, the kid arcade. Nice and an idle IO class rather
        # than Slice=batch.slice, deliberately -- batch's MemoryMax is 12.5
        # GiB on ac-box and a toplevel build under it would be OOM-killed
        # mid-deploy, turning a resource guard into an outage. Weight and
        # priority slow the build down; a ceiling would end it.
        Nice = 19;
        IOSchedulingClass = "idle";
        CPUWeight = 10;
      };
    };

    # Apply the moment CI stages one, rather than waiting for a clock. The
    # file is written by hub-queue-closure.sh on the agent; PathChanged fires
    # on the rename that replaces it, which is the same event hub-status.sh
    # reads. The service's own guards do the rest -- already-applied, busy,
    # blackout -- so a spurious trigger is a no-op and a log line.
    systemd.paths.homelab-deploy = mkIf (cfg.schedule == "continuous") {
      description = "Watch for a newly staged homelab system closure";
      wantedBy = [ "paths.target" ];
      pathConfig = {
        PathChanged = pendingFile;
        Unit = "homelab-deploy.service";
      };
    };

    systemd.timers.homelab-deploy = {
      description =
        if cfg.schedule == "continuous" then
          "Retry a deferred homelab system closure"
        else
          "Apply the staged homelab system closure, in the window";
      wantedBy = [ "timers.target" ];
      timerConfig =
        if cfg.schedule == "continuous" then
          {
            # The path unit is what applies an ordinary deploy; this timer
            # exists for the two cases a file event cannot cover -- a
            # revision deferred because someone was racing (nothing will
            # write the file again when they leave) and a firing missed
            # across a reboot.
            OnBootSec = cfg.retryInterval;
            OnUnitActiveSec = cfg.retryInterval;
            AccuracySec = "1min";
          }
        else
          {
            # window + offset, computed rather than a second literal.
            OnCalendar = "*-*-* ${windowEnd}:00";

            # Persistent = false, deliberately. Persistent fires a missed timer
            # at boot, which is the one moment guaranteed NOT to be inside the
            # maintenance window -- and a switch outside the window is the exact
            # thing the window exists to prevent. A missed night simply waits for
            # the next one; the staged revision does not expire.
            #
            # Under the continuous schedule this reverses: firing after a
            # reboot is wanted, which is why that branch has no Persistent
            # and an OnBootSec instead.
            Persistent = false;

            # No RandomizedDelaySec: this is one box, there is no thundering herd
            # to spread, and jitter would only blur the window's edges.
            AccuracySec = "1min";
          };
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0755 root root -"
    ];
  };
}
