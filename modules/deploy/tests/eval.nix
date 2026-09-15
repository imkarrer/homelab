# Eval harness for modules/deploy/default.nix -- ADR 0006's applying half and
# ADR 0008's schedule.
#
# What it is for. This module's whole job is deciding WHEN a closure switch
# happens, and every interesting branch is one nobody sees until it is wrong
# on a live box: a timer that fires at the wrong minute, a path unit that
# exists under the window schedule, a blackout string that is empty when it
# should not be, a serviceConfig that lets the build compete with a race. The
# host config alone cannot prove any of it -- ac-box picks one schedule, and
# `nix flake check` only ever evaluates that one.
#
# Usage:
#   nix --extra-experimental-features "nix-command flakes" eval \
#     -f modules/deploy/tests/eval.nix continuous.summary --json
#
# Same shape as the other harnesses (modules/ci/tests/eval.nix,
# modules/tenant/tests/eval-*.nix): pinned lib/pkgs, a stub for the option
# surface the module writes to, one attribute per case with `.checked` and
# `.messages`, and an `expected` map check.nix reads to turn these into flake
# checks.
{
  lib ? (import ../../tenant/tests/pinned-nixpkgs.nix).lib,
  pkgs ? (import ../../tenant/tests/pinned-nixpkgs.nix).pkgs,
}:

let
  deploy = ../default.nix;
  stubSystemd = ./stub-systemd.nix;

  # The script text, through the module's own readOnly scriptPackage. The
  # blackout and the two busy questions are decisions taken at evaluation time
  # and baked into a string, so this is the only place a test can see them --
  # the alternative is finding out at 03:05 on a night someone is racing.
  # Taken as functions of cfg so a case's `checks` can use them: they are
  # written outside mkCase precisely because that is where cfg is in scope.
  scriptText = cfg: cfg.homelab.deploy.scriptPackage.text or "";
  has = cfg: needle: lib.hasInfix needle (scriptText cfg);
  countOccurrences =
    cfg: needle: (builtins.length (builtins.split (lib.escapeRegex needle) (scriptText cfg)) - 1) / 2;

  mkCase =
    {
      extraModules ? [ ],
      checks ? (_: [ ]),
    }:
    let
      evaluated = lib.evalModules {
        specialArgs = { inherit pkgs; };
        modules = [ stubSystemd deploy ] ++ extraModules;
      };

      cfg = evaluated.config;

      failedChecks = lib.filter (c: !c.assertion) (checks cfg);
      failedMessages = map (c: c.message) failedChecks;

      # Guarded lookups throughout: with enable = false the module contributes
      # nothing at all, so a plain cfg.systemd.timers.homelab-deploy would
      # throw "attribute missing" rather than read as absent -- which is the
      # very thing the inert case is asserting.
      unit = kind: (cfg.systemd.${kind}.homelab-deploy or null);
    in
    {
      inherit (evaluated) config;
      ok = failedMessages == [ ];
      messages = failedMessages;

      summary = {
        hasService = (unit "services") != null;
        hasTimer = (unit "timers") != null;
        hasPath = (unit "paths") != null;
        timerConfig = (unit "timers").timerConfig or null;
        pathConfig = (unit "paths").pathConfig or null;
        serviceConfig = (unit "services").serviceConfig or null;
        blackoutLine = lib.findFirst (lib.hasPrefix "blackoutStart=") "<none>" (lib.splitString "\n" (scriptText cfg));
        busyChecks = countOccurrences cfg "busy && exit 0";
      };

      checked =
        if failedMessages == [ ] then
          "OK: no failed checks"
        else
          throw (lib.concatStringsSep "\n" failedMessages);
    };

  # The module is inert by default and that is load-bearing (its header: the
  # import must be provably a no-op), so every case that wants units must say
  # so, and one case proves the default.
  enabled = extra: [ { homelab.deploy.enable = true; } ] ++ extra;
in
{
  # ADR 0006's schedule, unchanged by ADR 0008: one firing, at the window plus
  # its offset, and nothing watching for a staged file.
  window = mkCase {
    extraModules = enabled [ { homelab.deploy.schedule = "window"; } ];
    checks = cfg: [
      {
        assertion = (cfg.systemd.timers.homelab-deploy.timerConfig.OnCalendar or null) == "*-*-* 03:30:00";
        message = "window schedule: the timer must fire at the window (03:00) plus the 30 minute offset, i.e. 03:30";
      }
      {
        assertion = (cfg.systemd.timers.homelab-deploy.timerConfig.Persistent or null) == false;
        message = ''
          window schedule: Persistent must stay false. Persistent fires a
          missed timer at boot, and boot is the one moment guaranteed not to
          be inside the window -- the exact switch the window exists to stop.
        '';
      }
      {
        assertion = !(cfg.systemd.paths ? homelab-deploy);
        message = ''
          window schedule: there must be NO path unit. Watching the staged
          file is what makes a switch happen off the clock, which is the
          whole difference between the two schedules.
        '';
      }
      {
        assertion = !(cfg.systemd.services.homelab-deploy.serviceConfig ? Nice);
        message = ''
          window schedule: the build runs at 03:30 with the box to itself, so
          it is not niced. Nicing it here would be cargo -- the resource
          guards belong to the schedule that put the build in the daytime.
        '';
      }
      {
        assertion = has cfg "blackoutStart=''";
        message = ''
          window schedule: the blackout must be EMPTY. The single firing is
          already outside the tenant tree's window by construction, and a
          blackout here would be a second, redundant spelling of the offset
          -- and one that could disagree with it.
        '';
      }
    ];
  };

  # ADR 0008's schedule: apply on the staged-file event, retry on a short
  # timer for the deferred case, and yield to everything while building.
  continuous = mkCase {
    extraModules = enabled [ { homelab.deploy.schedule = "continuous"; } ];
    checks = cfg: [
      {
        assertion = (cfg.systemd.paths.homelab-deploy.pathConfig.PathChanged or null) == "/var/lib/homelab/pending-closure.json";
        message = "continuous schedule: the path unit must watch the pending-closure file CI writes";
      }
      {
        assertion = (cfg.systemd.paths.homelab-deploy.pathConfig.Unit or null) == "homelab-deploy.service";
        message = "continuous schedule: the path unit must start the deploy service";
      }
      {
        assertion = !(cfg.systemd.timers.homelab-deploy.timerConfig ? OnCalendar);
        message = ''
          continuous schedule: no OnCalendar. A calendar firing here would
          reintroduce the window as a second, silent schedule -- the timer's
          only job now is retrying a deferral and covering a reboot.
        '';
      }
      {
        assertion = (cfg.systemd.timers.homelab-deploy.timerConfig.OnUnitActiveSec or null) == "10min";
        message = "continuous schedule: the retry interval must reach the timer";
      }
      {
        assertion = (cfg.systemd.timers.homelab-deploy.timerConfig.OnBootSec or null) == "10min";
        message = ''
          continuous schedule: a firing must follow a reboot. Under the window
          schedule a missed night simply waits; here the staged revision is
          meant to land as soon as the box can, and nothing else will write
          the pending file again to wake the path unit.
        '';
      }
      {
        assertion = (cfg.systemd.services.homelab-deploy.serviceConfig.Nice or null) == 19;
        message = ''
          continuous schedule: the build happens while people may be racing or
          using the model server, so it must yield. ADR 0008's Consequences.
        '';
      }
      {
        assertion = !(cfg.systemd.services.homelab-deploy.serviceConfig ? Slice);
        message = ''
          continuous schedule: the unit must NOT be put in batch.slice. Its
          MemoryMax on ac-box is 12.5 GiB and a toplevel build under it would
          be OOM-killed mid-deploy -- a resource guard that becomes an outage.
          Nice and IO class slow the build down; a ceiling ends it.
        '';
      }
      {
        # Bare, not quoted: lib.escapeShellArg quotes only what needs it, and
        # "03:00" does not. The empty string in the window case does, which is
        # why that assertion looks different rather than wrong.
        assertion = has cfg "blackoutStart=03:00" && has cfg "blackoutEnd=03:30";
        message = ''
          continuous schedule: the tenant tree's window must be a blackout,
          from the window itself to the window plus the offset. Without it the
          closure switch can land in the middle of the DOWNTIME build -- and
          the drain that build performs is exactly what makes busyCheck answer
          "not busy" at the moment the box is least idle.
        '';
      }
      {
        assertion = countOccurrences cfg "busy && exit 0" == 2;
        message = ''
          continuous schedule: the busy question must be asked TWICE -- once
          before the build and once in the last moment before the switch. The
          build can take minutes at 19:00, and "nobody was racing when this
          started" is not the question the operator answered.
        '';
      }
      {
        assertion = (cfg.systemd.services.homelab-deploy.restartIfChanged or true) == false;
        message = ''
          continuous schedule: restartIfChanged must stay false. It matters
          more here, not less -- switches now happen at any hour, so the
          chance of one changing this very unit mid-run is no longer confined
          to a nightly firing.
        '';
      }
    ];
  };

  # A retry interval the operator chose, reaching both timer fields; proves
  # the option is plumbed rather than the default being read twice.
  continuousCustomInterval = mkCase {
    extraModules = enabled [
      {
        homelab.deploy.schedule = "continuous";
        homelab.deploy.retryInterval = "2min";
      }
    ];
    checks = cfg: [
      {
        assertion = (cfg.systemd.timers.homelab-deploy.timerConfig.OnUnitActiveSec or null) == "2min";
        message = "retryInterval must reach OnUnitActiveSec";
      }
      {
        assertion = (cfg.systemd.timers.homelab-deploy.timerConfig.OnBootSec or null) == "2min";
        message = "retryInterval must reach OnBootSec";
      }
    ];
  };

  # The arithmetic that turns window + offset into a time has to carry past
  # midnight, and both schedules read it -- the window's only firing and the
  # continuous schedule's blackout end are the same expression. 23:50 + 30 is
  # 00:20 the next day, not 24:20.
  windowWrapsMidnight = mkCase {
    extraModules = enabled [
      {
        homelab.deploy.schedule = "window";
        homelab.host.maintenance.window = "23:50";
      }
    ];
    checks = cfg: [
      {
        assertion = (cfg.systemd.timers.homelab-deploy.timerConfig.OnCalendar or null) == "*-*-* 00:20:00";
        message = "window + offset must wrap past midnight: 23:50 + 30min is 00:20, not 24:20";
      }
    ];
  };

  # The racing gate, on either schedule. Found failing OPEN on 15 Sep 2026:
  # the unit's PATH had no `sh`, so `sh -c "$check"` exited 127, and the
  # `if` read 127 as "not busy" and switched. These are the two halves of
  # the fix, and each is a fact only the unit shape or the script text holds.
  busyCheckCanRunAndFailsClosed = mkCase {
    extraModules = enabled [ ];
    checks = cfg: [
      {
        assertion = builtins.elem "/run/current-system/sw" cfg.systemd.services.homelab-deploy.path;
        message = ''
          the unit must carry the system profile on its PATH. A tenant's
          busyCheck is written for the box's shell (assetto's needs sh and
          python3), and a NixOS unit's default PATH has neither -- which is
          how the check silently never ran.
        '';
      }
      {
        assertion = has cfg "-eq 126 ]" && has cfg "-eq 127 ]" && has cfg "could not run";
        message = ''
          a busyCheck that cannot run (126, 127) must DEFER, not switch. An
          unanswered question is not a "no", and this is the only brake the
          continuous schedule has.
        '';
      }
    ];
  };

  # The import is a no-op until someone flips enable. Same discipline
  # modules/ci was imported under, and the same proof: nothing in the closure.
  inert = mkCase {
    checks = cfg: [
      {
        assertion = cfg.systemd.services == { };
        message = "enable = false (default): no service may be emitted -- importing this module must be a no-op";
      }
      {
        assertion = cfg.systemd.timers == { };
        message = "enable = false (default): no timer may be emitted";
      }
      {
        assertion = cfg.systemd.paths == { };
        message = "enable = false (default): no path unit may be emitted";
      }
      {
        assertion = cfg.systemd.tmpfiles.rules == [ ];
        message = "enable = false (default): no tmpfiles rule may be emitted";
      }
    ];
  };

  # Case name -> whether `<case>.checked` must evaluate cleanly. Every case
  # here is expected to pass: unlike the tenant contract, this module has no
  # "must reject" fixture -- its bad inputs are caught by the option types
  # (schedule is an enum, windowOffsetMinutes is a bounded int).
  expected = {
    window = true;
    continuous = true;
    continuousCustomInterval = true;
    windowWrapsMidnight = true;
    busyCheckCanRunAndFailsClosed = true;
    inert = true;
  };
}
