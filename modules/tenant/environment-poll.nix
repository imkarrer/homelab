# The poll: a flox tenant's deploy edge on a host that has NO CI agent --
# an AMENDMENT to ADR 0010 (homelab-ygc.14, 26 Sep 2026).
#
# ADR 0009's edge is split in two halves. The tenant's pipeline proves a
# sha green and triggers homelab's queue-environment step, which writes
# pending-environment-<tenant>.json on the host the CI agent runs on; the
# pull unit (environment-pull.nix) on that same host applies it. Since the
# cutover (ADR 0010) the only agent is arcade-box's and agent-hub runs on
# the Z840, so a push to agent-hub main is proven green on arcade-box and
# staged THERE, where no agent-hub stub exists, while the Z840's pull unit
# sits armed on a file nothing writes. ADR 0010 accepted that as "no
# machinery" for llm-box -- a hand pull. This module is the amendment: the
# operator asked for parity with the old edge (push -> box, no hand step),
# and a host without an agent gets it by asking GitHub itself.
#
# For every enabled tenant with a stub declared AND environment.poll = true:
#
#   systemd.services.<tenant>-environment-poll   oneshot, in the tenant's slice, as root
#   systemd.timers.<tenant>-environment-poll     OnBootSec=5min, OnUnitActiveSec=10min
#   assertions                                   poll is for the tree kind, with a stub,
#                                                of a github.com remote
#
# and nothing for any other tenant -- inert by default, like every module
# here (tests/eval-environment.nix `pollOff`; arcade-box's stamp-stripped
# toplevel drvPath unchanged by this module's import).
#
# --------------------------------------------------------------------------
# WHAT ONE TICK DOES
# --------------------------------------------------------------------------
# Two unauthenticated GET requests to api.github.com: the tree's main HEAD
# (/repos/<owner>/<repo>/commits/main -> .sha), and -- only if that sha is
# neither staged nor applied here already -- that commit's COMBINED STATUS
# (/commits/<sha>/status), read for the ONE context the tenant's own
# Buildkite pipeline publishes, `buildkite/<slug>` (hub/pipelines/
# <tree>.json: slug, publish_commit_status) -- never the combined `.state`,
# which any app or token with statuses:write could turn green. That
# context's "success" means every step was green; anything else is "not green yet":
# one log line, exit 0, ask again next tick. A green sha is written to
# pending-environment-<tenant>.json in EXACTLY the tree-kind record
# scripts/hub-queue-environment.sh writes -- {tenant, sha, tree, queued_at,
# build, branch, source}, in that order, `tree` the registry's remote
# VERBATIM because the pull unit refuses any other -- with source =
# "github-poll" in place of "buildkite", so the record says which edge
# staged it. Written beside and renamed into place, so the pull's path unit
# fires on the rename exactly as it does for the queue script. From there
# the pull unit does what it always did: checkout, warm, restart under the
# tenant's quiet policy.
#
# What it does NOT do: touch the checkout, run flox or git, restart
# anything, write anywhere but the pending file. It is the staging half of
# the edge and only that, as the queue script is; the split is the point
# (environment-pull.nix's header). Only `main` is staged, a short sha is
# never resolved, and the registry is read through the same option the
# pull unit reads (homelab.environments.registry), so the remote written is
# the remote the pull compares against -- tests/eval-environment.nix holds
# the two scripts' strings equal.
#
# --------------------------------------------------------------------------
# A FAILURE IS A RETRY, NOT A FAILED UNIT
# --------------------------------------------------------------------------
# A curl failure (no network, a 5xx, the rate limit's 403), a body that is
# not JSON, a sha that is not 40 hex: one journal line, exit 0, and the
# next tick asks again. The pull's failed unit is a verdict on something
# staged; here nothing has been staged, and there is nothing for a human to
# do about weather. Two things ARE a failed unit, because they are
# configuration: a state directory that is not a writable directory, and a
# pending record already there that cannot be parsed (the pull is refusing
# it too; both should say so rather than one silently replacing it).
#
# NOT GREEN IS TWO DIFFERENT THINGS, and the log line says which. A
# combined status of "pending" WITH statuses on it is a build still
# running: patience. "pending" with total_count 0 is a commit no status
# was ever published for -- which on 26 Sep 2026 is every agent-hub main
# commit: the pipeline object claims publish_commit_status, builds 1-29
# went green, and GitHub holds no status for any of them (nor for homelab
# or home-arcade; only ac-host and bead-loop, whose pipelines are connected
# through Buildkite's GitHub App, carry one). That is a Buildkite setting
# to fix, not a sha to guess about: this module cannot tell a green commit
# from an unreported one and stages neither.
#
# RATE. GitHub allows 60 unauthenticated requests per hour per address.
# Six ticks an hour at two requests each is 12 at most, and the steady
# state -- HEAD already applied -- is 6, since the status request is
# skipped once the sha is known. No token on the box, as for every other
# read the box makes of a public remote.
#
# WHERE IT RUNS: the tenant's slice at plain priority, as the pull unit
# does (the same sliceable rule), and as root, because /var/lib/homelab is
# root's and the record is the box's deploy record, not the tenant's state.
# Nothing here runs as the tenant user or touches the tenant's dir.
# restartIfChanged = false, as for the pull unit: a closure switch that
# changes this unit mid-tick would kill a curl for nothing; the new unit
# file applies at the next firing.
{ config, lib, pkgs, ... }:

let
  inherit (lib) mkOption mkIf types;

  cfg = config.homelab.environments;

  # hub/repos.psv, read as environment-pull.nix reads it: the same option,
  # the same row format (name|path|remote|deploy|agent-push, '#' comments).
  # A second copy of a twelve-line parse rather than a shared file: the two
  # modules are the two halves of one edge and the harness holds their
  # outputs equal; a third reader is the moment to lift it.
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

  # The API's <owner>/<repo> from the registry's remote, either spelling
  # GitHub has; "" for anything that is not github.com, which the assertion
  # below refuses (there is no api.github.com for another forge).
  ownerRepoOf =
    r:
    lib.removeSuffix ".git" (
      if lib.hasPrefix "git@github.com:" r then
        lib.removePrefix "git@github.com:" r
      else if lib.hasPrefix "https://github.com/" r then
        lib.removePrefix "https://github.com/" r
      else
        ""
    );

  # Every enabled tenant that asks to poll -- the assertions speak to all
  # of them -- and, of those, the ones a unit is emitted for: a stub
  # declared (or there is no pull unit to apply what is staged) and the
  # tree kind (a FloxHub generation is not a fact GitHub holds).
  pollAsked = lib.filterAttrs (_: t: t.enable && t.environment.poll) config.homelab.tenants;
  pollTenants = lib.filterAttrs (
    _: t: t.environment.units != { } && t.environment.source.kind == "tree"
  ) pollAsked;

  mkPoll =
    name: t:
    let
      env = t.environment;
      registryRemote = remoteFor env.tree;
      ownerRepo = ownerRepoOf registryRemote;
      # The tenant's pipeline slug, from the object hub-pipeline.sh
      # converges (hub/pipelines/<tree>.json), for the status context
      # `buildkite/<slug>`. Read, not spelled: a tree that polls must have
      # a pipeline, and a missing file fails evaluation naming the path.
      pipelineSlug = (builtins.fromJSON (builtins.readFile (../../hub/pipelines + "/${env.tree}.json"))).slug;
      stateDir = toString cfg.stateDir;
      # The same two expressions environment-pull.nix bakes, so the file
      # this writes is the file that pull reads and its path unit watches.
      pending = "${stateDir}/pending-environment-${name}.json";
      applied = "${stateDir}/last-applied-environment-${name}.json";

      sliceable = config.homelab.enforce.slices && t.tier != "critical" && t.quiet.drainable;

      script = pkgs.writeShellApplication {
        name = "${name}-environment-poll";
        runtimeInputs = [
          pkgs.curl
          pkgs.jq
          pkgs.coreutils
        ];
        text = ''
          tenant=${lib.escapeShellArg name}
          # The registry's remote verbatim: what the record carries as
          # `tree`, and what the pull unit compares against.
          tree=${lib.escapeShellArg registryRemote}
          ownerRepo=${lib.escapeShellArg ownerRepo}
          # The one status context that vouches for a sha: the tenant's own
          # Buildkite pipeline (hub/pipelines/<tree>.json, slug). Combined
          # `state` is the AND over every context anyone posts, so reading it
          # would let any app or token with statuses:write green a sha; the
          # review of homelab-ygc.14 reproduced that. ADR 0009's edge trusts
          # Buildkite alone, and so does this one.
          context=${lib.escapeShellArg "buildkite/${pipelineSlug}"}
          branch=main
          defaultStateDir=${lib.escapeShellArg stateDir}
          # Quoted by hand, not escapeShellArg: a bare name-with-hyphens.json
          # reads as arithmetic to shellcheck (SC2100).
          pendingName="${baseNameOf pending}"
          appliedName="${baseNameOf applied}"

          # Three knobs, none of them set on the box's unit. Where the
          # records live (HOMELAB_DEPLOY_STATE, the name hub-queue-
          # environment.sh and hub-queue-closure.sh already answer to);
          # whether to print the record instead of writing it
          # (POLL_DRY_RUN=1); and which API to ask (POLL_API_BASE), so a
          # canned server can stand in for api.github.com and a dry run
          # exercises the whole path without a request leaving the machine.
          stateDir="''${HOMELAB_DEPLOY_STATE:-$defaultStateDir}"
          api="''${POLL_API_BASE:-https://api.github.com}"
          dryRun="''${POLL_DRY_RUN:-}"
          pending="$stateDir/$pendingName"
          applied="$stateDir/$appliedName"

          log() { echo "$tenant-environment-poll: $*"; }
          # Weather: one line, exit 0, the timer asks again in ten minutes.
          retry() { log "$*; retrying next tick."; exit 0; }
          # Configuration: a failed unit, so somebody sees it.
          refuse() { log "$*" >&2; exit 1; }

          if [ ! -d "$stateDir" ] || [ ! -w "$stateDir" ]; then
            refuse "$stateDir is not a writable directory here -- nowhere to stage into."
          fi

          # What the box already knows: the staged and the applied sha.
          # Absent files are the first-run state. A pending record that is
          # not JSON is refused rather than written over -- the pull unit is
          # refusing it too, and both should say so.
          staged=""
          appliedSha=""
          if [ -e "$pending" ]; then
            staged=$(jq -r '.sha // empty' "$pending" 2>/dev/null) || refuse "$pending is not JSON; not writing over it."
          fi
          if [ -e "$applied" ]; then
            appliedSha=$(jq -r '.sha // empty' "$applied" 2>/dev/null) || appliedSha=""
          fi

          # One request that can never ask anyone anything: no credential,
          # a User-Agent (GitHub refuses a request without one), a bounded
          # wait. -f makes any 4xx/5xx a non-zero exit, which is a retry.
          ask() {
            curl -fsS --max-time 20 \
              -H 'Accept: application/vnd.github+json' \
              -H 'X-GitHub-Api-Version: 2022-11-28' \
              -H "User-Agent: homelab-environment-poll/$tenant" \
              "$api/repos/$ownerRepo/$1"
          }

          headJson=$(ask "commits/$branch") || retry "could not read $ownerRepo $branch from $api (curl exit $?)"
          sha=$(jq -r '.sha // empty' <<<"$headJson" 2>/dev/null) || sha=""
          if ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
            retry "$api answered for $ownerRepo $branch without a full sha ('$sha')"
          fi

          # Nothing new -- the usual tick. Silent, so the journal is not six
          # lines an hour of "still applied".
          if [ "$sha" = "$staged" ] || [ "$sha" = "$appliedSha" ]; then
            exit 0
          fi

          status=$(ask "commits/$sha/status") || retry "could not read the combined status of $sha from $api (curl exit $?)"
          count=$(jq -r '.total_count // 0' <<<"$status" 2>/dev/null) || count=0
          # Only $context's own state and link, never the combined `.state`
          # (see the note at `context=` above). The combined endpoint already
          # keeps one status per context, the newest.
          vouch=$(jq -r --arg ctx "$context" \
            '[.statuses[]? | select(.context == $ctx)] | first // empty | "\(.state) \(.target_url // "")"' \
            <<<"$status" 2>/dev/null) || vouch=""
          state=''${vouch%% *}
          build=''${vouch#* }
          if [ "$state" != success ]; then
            if [ "$count" = 0 ]; then
              log "$branch HEAD $sha has no commit status at all (total_count 0): its build has not started, or Buildkite is not publishing statuses for $ownerRepo (hub/pipelines says it should; check the pipeline's GitHub connection). Not green; not staging."
            elif [ -z "$state" ]; then
              log "$branch HEAD $sha has $count status(es) and none from $context; only the tenant's own pipeline vouches for a sha. Not staging."
            else
              log "$branch HEAD $sha is '$state' at $context; not green yet, not staging."
            fi
            exit 0
          fi

          # The record, in hub-queue-environment.sh's tree-kind shape and
          # key order, `source` naming this edge. jq builds it so nothing
          # GitHub returned is spliced into JSON by hand.
          record=$(jq -cn \
            --arg tenant "$tenant" \
            --arg sha "$sha" \
            --arg tree "$tree" \
            --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            --arg build "$build" \
            --arg branch "$branch" \
            '{tenant: $tenant, sha: $sha, tree: $tree, queued_at: $at, build: $build, branch: $branch, source: "github-poll"}')

          if [ -n "$dryRun" ]; then
            log "dry run: would stage the record below at $pending"
            printf '%s\n' "$record"
            exit 0
          fi

          # Atomic: beside, then rename, so the path unit fires once on the
          # rename and never reads a half-written file.
          tmp="$pending.tmp.$$"
          printf '%s\n' "$record" > "$tmp"
          mv -f "$tmp" "$pending"
          log "staged $sha of $ownerRepo ($branch, green''${build:+: $build}) -> $pending; $tenant-environment-pull applies it."
        '';
      };
    in
    {
      inherit
        name
        t
        env
        registryRemote
        ownerRepo
        stateDir
        pending
        applied
        sliceable
        script
        ;
    };

  polls = lib.mapAttrs mkPoll pollTenants;

  unitName = name: "${name}-environment-poll";
in
{
  options.homelab.environments.poll = mkOption {
    type = types.attrsOf types.package;
    readOnly = true;
    default = lib.mapAttrs (_: p: p.script) polls;
    defaultText = lib.literalMD "the generated <tenant>-environment-poll script per tenant with environment.poll = true";
    description = ''
      Read-only: the script each poll unit runs, so what is baked into it
      at evaluation -- the owner/repo asked, the remote the record carries,
      the state directory -- can be read without a box and asserted by
      tests/eval-environment.nix. homelab.environments.pull's shape.
    '';
  };

  config = mkIf (pollAsked != { }) {
    assertions =
      lib.flatten (
        lib.mapAttrsToList (name: t: [
          {
            assertion = t.environment.source.kind == "tree";
            message = ''
              homelab.tenants.${name}.environment.poll = true with source.kind =
              "${t.environment.source.kind}": the poll asks GitHub for a sha of
              the tree, and a floxhub tenant is deployed by a generation its CI
              pushes -- a commit status says nothing about which generation that
              is. Tree-kind sources only; drop poll or change the kind.
            '';
          }
          {
            assertion = t.environment.units != { };
            message = ''
              homelab.tenants.${name}.environment.poll = true with no stub
              declared (environment.units = {}): there is no
              ${name}-environment-pull unit on this host to apply what the poll
              would stage. Declare the stub, or drop poll.
            '';
          }
        ]) pollAsked
      )
      ++ lib.mapAttrsToList (name: p: {
        assertion = p.ownerRepo != "";
        message = ''
          homelab.tenants.${name}.environment.tree = "${p.env.tree}" resolves to
          remote "${p.registryRemote}" in ${toString cfg.registry}, which is not
          a github.com remote (git@github.com:owner/repo or
          https://github.com/owner/repo). The poll asks api.github.com and has
          nowhere else to ask.
        '';
      }) polls;

    systemd.services = lib.mapAttrs' (
      name: p:
      lib.nameValuePair (unitName name) {
        description = "Ask GitHub for a green ${name} main sha and stage it (this host has no CI agent)";

        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];

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
    ) polls;

    systemd.timers = lib.mapAttrs' (
      name: _:
      lib.nameValuePair (unitName name) {
        description = "Poll GitHub for a green ${name} main sha to stage";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          # Five minutes after boot (the network is up, the pull's own boot
          # firing has had its turn), then every ten: 12 requests an hour
          # at most against GitHub's 60, and a push reaches the box within
          # the ~15 minutes the old edge took. Persistent = false is stated
          # although a monotonic timer never catches up: the decision is
          # modules/deploy's (a missed firing waits; nothing fires at boot
          # because it was missed) and a reader should find it here too.
          OnBootSec = "5min";
          OnUnitActiveSec = "10min";
          Persistent = false;
          AccuracySec = "1min";
        };
      }
    ) polls;
  };
}
