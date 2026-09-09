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

  deployScript = pkgs.writeShellApplication {
    name = "homelab-deploy";
    runtimeInputs = [
      pkgs.jq
      pkgs.coreutils
      config.system.build.nixos-rebuild
    ];
    text = ''
      pending=${lib.escapeShellArg pendingFile}
      applied=${lib.escapeShellArg appliedFile}
      inventory=${lib.escapeShellArg inventory}
      flake=${lib.escapeShellArg cfg.flake}
      host=${lib.escapeShellArg host.name}

      if [ ! -e "$pending" ]; then
        echo "homelab-deploy: nothing staged at $pending; nothing to do."
        exit 0
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
      while IFS=$'\t' read -r name check; do
        [ -n "$name" ] || continue
        if sh -c "$check"; then
          echo "homelab-deploy: $name is busy; deferring $rev to the next window."
          exit 0
        fi
      done < <(
        jq -r '
          .tenants[]
          | select(.quiet.drainable == false)
          | select(.quiet.busyCheck != null)
          | "\(.name)\t\(.quiet.busyCheck)"
        ' "$inventory"
      )

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
      };
    };

    systemd.timers.homelab-deploy = {
      description = "Apply the staged homelab system closure, in the window";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* ${host.maintenance.window}:00";

        # Persistent = false, deliberately. Persistent fires a missed timer at
        # boot, which is the one moment guaranteed NOT to be inside the
        # maintenance window -- and a switch outside the window is the exact
        # thing the window exists to prevent. A missed night simply waits for
        # the next one; the staged revision does not expire.
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
