#!/usr/bin/env bash
# Three-way state: ac-box (deployed) vs origin (git) vs the WSL checkouts.
# Answers "what is actually where" in one call, so nothing has to re-derive it.
# Exit 0 = reconciled, 1 = something needs attention.
set -uo pipefail

HUB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REG="${HUB_REGISTRY:-$HUB/hub/repos.psv}"
BOX="${HOMELAB_BOX:-ac-box}"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=8 "$BOX")
PROBLEMS=()
note() { PROBLEMS+=("$1"); }
ago() {  # ago <epoch> -> "47 min" / "6 h" / "3 d": the age the operator reads
  local s=$(( $(date +%s) - ${1:-0} ))
  if [ "$s" -lt 3600 ]; then echo "$(( s / 60 )) min"
  elif [ "$s" -lt 172800 ]; then echo "$(( s / 3600 )) h"
  else echo "$(( s / 86400 )) d"; fi
}
# origin/main per tree, as the DEV loop fetches it: what CI should have built.
declare -A OHEAD OHEADT; TREES=()

# Paths rsync never copies (pending_deploy.RSYNC_EXCLUDES + PRESERVE_LOCAL),
# so they are not drift when they differ. Kept as an array: no eval, no quoting trap.
FIND_PRUNE=(
  -not -path "*/.git/*" -not -path "*/__pycache__/*" -not -name "*.pyc"
  -not -name ".env" -not -name ".env.*"
  -not -path "*/_extract/*" -not -path "*/dist/*"
  -not -path "*/_local_wipe_backup/*"
  -not -path "*/.flox/cache/*" -not -path "*/.flox/run/*" -not -path "*/.flox/log/*"
  -not -name "hardware-configuration.nix" -not -name "ssh-keys.local.nix"
)
# The same list as one string for the remote shell.
REMOTE_PRUNE=$(printf '%q ' "${FIND_PRUNE[@]}")

echo "===== DEV: WSL checkouts ====="
printf "%-18s %-24s %5s %5s %s\n" REPO BRANCH DIRTY UNTRK "VS ORIGIN"
while IFS='|' read -r name path remote deploy push; do
  case "$name" in ''|\#*) continue ;; esac
  [ -d "$path/.git" ] || { printf "%-18s %s\n" "$name" "(missing)"; continue; }
  br=$(git -C "$path" branch --show-current 2>/dev/null || echo '?')
  dirty=$(git -C "$path" diff --name-only 2>/dev/null | wc -l)
  untrk=$(git -C "$path" ls-files --others --exclude-standard 2>/dev/null | wc -l)
  if [ "$remote" != none ]; then
    git -C "$path" fetch -q origin 2>/dev/null
    OHEAD[$name]=$(git -C "$path" rev-parse origin/main 2>/dev/null)
    OHEADT[$name]=$(git -C "$path" log -1 --format=%ct origin/main 2>/dev/null)
    TREES+=("$name")
  fi
  ub=$(git -C "$path" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null)
  if [ -n "$ub" ]; then
    ah=$(git -C "$path" rev-list --count "$ub..HEAD" 2>/dev/null || echo 0)
    bh=$(git -C "$path" rev-list --count "HEAD..$ub" 2>/dev/null || echo 0)
    rel="ahead $ah behind $bh"
    [ "$ah" != 0 ] && note "$name: $ah commit(s) unpushed - CI has never seen them"
    [ "$bh" != 0 ] && note "$name: $bh commit(s) behind origin"
  else
    rel="no upstream"
  fi
  [ "$dirty" != 0 ] && note "$name: $dirty uncommitted change(s)"
  [ "$untrk" != 0 ] && note "$name: $untrk untracked file(s)"
  printf "%-18s %-24s %5s %5s %s\n" "$name" "$br" "$dirty" "$untrk" "$rel"
  # Worker worktrees (hub-worktree.sh) sit outside this tree, so the counts
  # above do not see them. A branch main does not contain is unlanded work
  # in the same sense as an unpushed commit: nothing has gated it.
  # Process substitution, not a pipe: note() must run in this shell.
  while read -r wpath wbr; do
    wah=$(git -C "$path" rev-list --count "main..$wbr" 2>/dev/null || echo 0)
    wdirty=$(git -C "$wpath" status --porcelain 2>/dev/null | wc -l)
    [ "$wah" != 0 ] && note "$name: worktree $wbr has $wah commit(s) main does not - gate and merge, or drop it"
    [ "$wdirty" != 0 ] && note "$name: worktree $wbr has $wdirty uncommitted change(s)"
    printf "%-18s %-24s %5s %5s %s\n" "  ↳ worktree" "$wbr" "$wdirty" "" "ahead of main $wah"
  done < <(git -C "$path" worktree list --porcelain 2>/dev/null | awk '
    /^worktree /{w=$2} /^branch /{b=$2; sub("refs/heads/","",b)}
    /^$/{ i++; if (i>1 && b!="") print w " " b; w=""; b="" }
    END{ if (w!="" && b!="") { i++; if (i>1) print w " " b } }')
done < "$REG"

# The backup lives HERE, not on the box. scripts/hub-backup.sh pulls ac-box's
# declared state onto this machine nightly (hub/systemd/hub-backup.timer) and
# leaves a KEY=VALUE status file behind; every other line in this script asks
# the box or asks git, so nothing else can see whether it ran. A backup that
# quietly stopped is invisible until the day it is needed -- which is the whole
# failure mode row 22 exists to close -- so its age is a verdict, not a display.
# Three days: a laptop off over a long weekend is normal (Persistent=true fires
# the run at the next boot), four nights of nothing is not.
BSTATUS="${HUB_BACKUP_STATUS:-/home/nixos/backup/status}"
if [ -r "$BSTATUS" ]; then
  bwhen=$(grep '^LAST_SUCCESS=' "$BSTATUS" | cut -d= -f2-)
  bepoch=$(grep '^LAST_SUCCESS_EPOCH=' "$BSTATUS" | cut -d= -f2-)
  bsnaps=$(grep '^SNAPSHOTS=' "$BSTATUS" | cut -d= -f2-)
  bsize=$(grep '^REPO_SIZE=' "$BSTATUS" | cut -d= -f2-)
  bresult=$(grep '^LAST_RESULT=' "$BSTATUS" | cut -d= -f2-)
  bdays=$(( ( $(date +%s) - ${bepoch:-0} ) / 86400 ))
  printf "%-18s last success %s (%s snapshots, %s)\n" "backup" "${bwhen:-never}" "${bsnaps:-0}" "${bsize:-?}"
  if [ -z "$bepoch" ]; then
    note "backup: scripts/hub-backup.sh has never completed - the restic repo has no usable snapshot"
  elif [ "$bdays" -gt 3 ]; then
    note "backup: last success was $bdays day(s) ago ($bwhen) - the nightly pull is not running (systemctl status hub-backup.timer; journalctl -u hub-backup)"
  fi
  case "$bresult" in ok|'') ;; *) note "backup: last attempt $bresult" ;; esac
else
  note "backup: no status file at $BSTATUS - hub-backup.timer is not installed here (docs/runbook-restore.md)"
fi

echo
echo "===== CI: newest main build per pipeline, against origin's HEAD ====="
# What Buildkite did with the push origin holds. Until 16 Sep 2026 the only
# CI fact here was the exit status of the last job in the agent's docker log,
# and that line cannot tell apart the three cases that each want a different
# action: NO build was created (the webhook did not fire -- nine hours of
# pushes on 14 Sep, architecture.md row 34, and this script said "wait for
# HEAD's build" the whole time), a build is RUNNING (wait), the build FAILED
# (nothing can stage; push again all you like). So each is its own line,
# read from the API: the newest build on main per pipeline, its commit held
# against origin/main as the DEV loop just fetched it. Origin's HEAD with no
# build is the verdict that would have caught 14 Sep in one run; a build in
# flight is a state, printed as one. ac-host-ops is the tenant tree's apply
# path (the bot's DOWNTIME=1 build, BOX section) and is shown with the tree;
# its commit is whatever was pending at 03:00, not HEAD, so it is compared
# to nothing and only its result is a verdict -- a failed apply was
# invisible before this. The token is lib/buildkite-token.sh's (three
# sources, sops last); without one the section is a line, not a failure,
# because nothing below needs it. Cost: the token read plus five requests in
# parallel inside one nix shell (jq): 0.8 s measured 16 Sep, next to the
# ssh round trip and the git fetches that make up the rest of the ~2 s.
# shellcheck source=scripts/lib/buildkite-token.sh
. "$HUB/scripts/lib/buildkite-token.sh"
BKLOG=$(mktemp)
if TOKEN=$(buildkite_token 2>"$BKLOG"); then
  BKSRC=$(tail -1 "$BKLOG")
  SLUGS=()
  for t in "${TREES[@]}"; do SLUGS+=("$t"); [ "$t" = ac-host ] && SLUGS+=(ac-host-ops); done
  # One nix shell, the requests backgrounded inside it, one line per slug
  # out: slug|http|number|state|commit|created|finished|url. The header goes
  # in on stdin (-H @-) and the token in the environment, never in argv.
  # shellcheck disable=SC2016  # the quoted script is for the child bash
  BKTXT=$(TOKEN="$TOKEN" NIX_CONFIG="experimental-features = nix-command flakes" \
    nix shell nixpkgs#jq -c bash -c '
      set -u
      d=$(mktemp -d); trap "rm -rf \"$d\"" EXIT
      for s in "$@"; do
        printf "Authorization: Bearer %s\n" "$TOKEN" |
          curl -sS -m 8 -H @- -o "$d/$s.json" -w "%{http_code}" \
            "https://api.buildkite.com/v2/organizations/isaac-karrer/pipelines/$s/builds?branch=main&per_page=1" \
            > "$d/$s.code" 2>/dev/null &
      done
      wait
      for s in "$@"; do
        printf "%s|%s|%s\n" "$s" "$(cat "$d/$s.code")" \
          "$(jq -r ".[0] | [.number, .state, .commit, .created_at, .finished_at, .web_url] | map(. // \"\") | join(\"|\")" "$d/$s.json" 2>/dev/null)"
      done
    ' _ "${SLUGS[@]}")
  printf "%-18s %-22s %s\n" PIPELINE "NEWEST MAIN BUILD" "VS ORIGIN HEAD"
  while IFS='|' read -r s code num state commit created finished url; do
    [ -n "$s" ] || continue
    tree="$s"; [ "$s" = ac-host-ops ] && tree=ac-host
    h="${OHEAD[$tree]:-}"; hs="${h:0:7}"; hage=$(ago "${OHEADT[$tree]:-}")
    if [ "$code" != 200 ]; then
      printf "%-18s %-22s %s\n" "$s" "HTTP ${code:-none}" "build state unknown"
      case "$code" in
        404) note "$s: no Buildkite pipeline - nothing builds this tree (scripts/hub-pipeline.sh $s creates it and its webhook)" ;;
        # One token, one verdict: a refusal is the same fact for every slug.
        401|403) [ -n "${BKREFUSED:-}" ] || note "Buildkite refuses the token (HTTP $code; $BKSRC) - build state of every pipeline unknown, not fine"; BKREFUSED=1 ;;
        *) note "$s: Buildkite answered HTTP ${code:-nothing} - build state unknown, not fine" ;;
      esac
      continue
    fi
    when=$([ -n "$finished" ] && echo "finished $(ago "$(date -d "$finished" +%s 2>/dev/null)") ago" \
         || echo "$state since $(ago "$(date -d "$created" +%s 2>/dev/null)") ago")
    if [ "$s" = ac-host-ops ]; then
      if [ -z "$num" ]; then printf "%-18s %-22s %s\n" "$s" "none" "no DOWNTIME apply has ever run"; continue; fi
      printf "%-18s %-22s %s\n" "$s" "build $num $state" "DOWNTIME apply of ${commit:0:7}, $when"
      case "$state" in failed|canceled|waiting_failed)
        note "ac-host-ops: DOWNTIME build $num $state for ${commit:0:7} - the pending tree was not applied; the box still runs the one before ($url)" ;;
      esac
      continue
    fi
    if [ -z "$h" ]; then
      printf "%-18s %-22s %s\n" "$s" "build ${num:-none} $state" "origin HEAD unknown (no checkout here)"
    elif [ -z "$num" ]; then
      printf "%-18s %-22s %s\n" "$s" "none" "origin HEAD $hs (committed $hage ago) has NO build"
      note "$s: push did not build - origin HEAD $hs (committed $hage ago) has no build on main, ever; the webhook did not fire (scripts/hub-pipeline.sh $s converges it and prints GitHub's deliveries; then a new push, or a build started by hand)"
    elif [ "$commit" != "$h" ]; then
      printf "%-18s %-22s %s\n" "$s" "build $num $state" "for ${commit:0:7}; origin HEAD $hs (committed $hage ago) has NO build"
      note "$s: push did not build - origin HEAD $hs (committed $hage ago) has no build; the newest is $num for ${commit:0:7}; the webhook did not fire (scripts/hub-pipeline.sh $s converges it and prints GitHub's deliveries; then a new push, or a build started by hand)"
    else
      printf "%-18s %-22s %s\n" "$s" "build $num $state" "for origin HEAD $hs, $when"
      case "$state" in
        failed|canceled|waiting_failed)
          note "$s: build $num $state for origin HEAD $hs - nothing downstream runs (no stage, no bump-lock) until a build of this tree passes ($url)" ;;
        # passed needs no line; running, scheduled, creating, blocked, failing
        # are states, printed above, and a verdict only once they settle.
      esac
    fi
  done <<< "$BKTXT"
else
  # The lib's whole stderr, one line: the specific cause first, the three
  # sources last. Not a verdict: the token is this section's, not the box's.
  echo "skipped (build state per pipeline unknown): $(paste -sd';' "$BKLOG" | sed 's/;/; /g')"
fi
rm -f "$BKLOG"

echo
echo "===== BOX: $BOX ====="
# One round trip, one KEY=VALUE per line: robust to any JSON contents.
BOXTXT=$("${SSH[@]}" '
  s=/var/lib/ac-host
  echo "APPLIED=$(grep -oE "[0-9a-f]{40}" $s/last-applied.json 2>/dev/null | head -1)"
  echo "PENDING=$(grep -oE "[0-9a-f]{40}" $s/pending-deploy.json 2>/dev/null | head -1)"
  echo "FAILED=$(systemctl --failed --no-legend 2>/dev/null | wc -l)"
  echo "CONTAINERS=$(docker ps -q 2>/dev/null | wc -l)"
  echo "DISK=$(df -h / | awk "NR==2{print \$5}")"
  echo "LOAD=$(cut -d" " -f1-3 /proc/loadavg)"
  # Whether the 03:00 DOWNTIME=1 build has something to queue it. bot/downtime.py
  # posts it at mark 0 (ac-host bot/bot.py, fire_downtime_mark); with the bot
  # down at 02:59 a queued tree waits, and nothing says so. `docker ps` rather
  # than the unit: the container is what holds the countdown.
  echo "BOT=$(docker ps --filter name=^ac-host-bot-1$ --format {{.Status}} 2>/dev/null | head -1)"
  # Whether that build actually RAN. The bot only asks Buildkite for it, and on
  # 13 Sep 2026 the bot was up, mark 0 fired, and the trigger came back HTTP 401
  # (dead BUILDKITE_API_TOKEN in .env) -- in docker logs only. last-downtime.json
  # is the one record: ac-host scripts/ci_downtime.py writes it at the start of
  # every DOWNTIME build, "date" box-local (America/Chicago), "sha" empty when
  # nothing was pending. Its date is the heartbeat of the build; bot uptime is not.
  echo "DOWNTIME=$(grep -E "^ *\"date\"" $s/last-downtime.json 2>/dev/null | grep -oE "[0-9]{4}-[0-9]{2}-[0-9]{2}" | head -1)"
  # The date whose 03:00 has most recently passed, box-local, with an hour for
  # the agent to pick the build up: what DOWNTIME should read right now. Before
  # 04:00 that is yesterday, after it today -- so "older than yesterday" is
  # always stale, and "yesterday" is stale once the window this morning has gone.
  echo "DOWNTIMEDUE=$(date -d "-4 hours" +%F)"
  p=/nix/var/nix/profiles/system
  echo "SYS=$(readlink -f /run/current-system)"
  echo "SYSBOOTED=$(readlink -f /run/booted-system)"
  echo "SYSGEN=$(readlink $p 2>/dev/null | grep -oE "[0-9]+" | tail -1)"
  # lstat, not stat -L: the mtime we want is when the "system" symlink was last
  # re-pointed (i.e. the last switch), not when its store target was created.
  # /run/current-system is deliberately NOT the timestamp source -- it is
  # recreated at every boot, so a reboot would silently reset drift to zero.
  echo "SYSTIME=$(stat -c %Y $p 2>/dev/null)"
  echo "SYSREV=$(nixos-version --configuration-revision 2>/dev/null)"
  echo "BOXCLOCK=$(date +%s)"
  # The CLOSURE deploy pair (ADR 0006), distinct from the tenant tree pair
  # above. queue-closure (Buildkite) writes pending; modules/deploy writes
  # applied after a successful switch. Same grep shape as the tenant tree.
  h=/var/lib/homelab
  echo "CLPENDING=$(grep -oE "[0-9a-f]{40}" $h/pending-closure.json 2>/dev/null | head -1)"
  echo "CLAPPLIED=$(grep -oE "[0-9a-f]{40}" $h/last-applied-closure.json 2>/dev/null | head -1)"
  echo "CLTIMER=$(systemctl is-enabled homelab-deploy.timer 2>/dev/null)"
  echo "CLPATH=$(systemctl is-enabled homelab-deploy.path 2>/dev/null)"
' 2>/dev/null)

get() { echo "$BOXTXT" | grep "^$1=" | head -1 | cut -d= -f2-; }
if [ -z "$BOXTXT" ]; then
  echo "UNREACHABLE"; note "box $BOX unreachable - its state is unknown, not clean"
  APPLIED=""
else
  APPLIED=$(get APPLIED); PENDING=$(get PENDING)
  echo "applied    : ${APPLIED:-none}"
  echo "pending    : ${PENDING:-none}"
  echo "failed=$(get FAILED) containers=$(get CONTAINERS) disk=$(get DISK) load=$(get LOAD)"
  [ "$(get FAILED)" != 0 ] && note "box has $(get FAILED) failed systemd unit(s)"
  # Queued-but-not-applied is a STATE while the bot is up: it queues the
  # DOWNTIME=1 build at 03:00 (ac-host bot/downtime.py, mark 0) and that build
  # applies the tree and recycles the lobbies once. Until 13 Sep 2026 this
  # line said "needs ops pipeline DOWNTIME=1" as if a human had to start it;
  # last-downtime.json on the box showed it had been running nightly, unattended,
  # the whole time. It is a PROBLEM when nothing will queue it -- or when
  # something did and the build still did not run: the bot being up is
  # necessary, not sufficient (13 Sep: up, and a 401 from Buildkite at mark 0).
  # The last build's date sits next to the bot's uptime so the two are read
  # together, and a date behind the window that should have applied the tree
  # is a verdict, not a state.
  BOT=$(get BOT); DOWNTIME=$(get DOWNTIME); DOWNTIMEDUE=$(get DOWNTIMEDUE)
  if [ -n "$PENDING" ] && [ "$PENDING" != "$APPLIED" ]; then
    if [ -n "$BOT" ]; then
      echo "             tree ${PENDING:0:7} is queued; the bot's 03:00 DOWNTIME=1 build applies it (bot: $BOT; last DOWNTIME build: ${DOWNTIME:-unknown})"
      if [ -z "$DOWNTIME" ]; then
        note "deploy queued (${PENDING:0:7}) but /var/lib/ac-host/last-downtime.json is unreadable - whether the DOWNTIME build runs is unknown, not fine"
      elif [[ "$DOWNTIME" < "$DOWNTIMEDUE" ]]; then
        note "DOWNTIME build has not run since $DOWNTIME (the $DOWNTIMEDUE 03:00 has passed); the pending tree ${PENDING:0:7} is not being applied - the bot is up, so it is the trigger: docker logs ac-host-bot-1, a 401 means BUILDKITE_API_TOKEN in .env is dead"
      fi
    else
      note "deploy queued (${PENDING:0:7}) but ac-host-bot-1 is not running - nothing will queue DOWNTIME=1 at 03:00"
    fi
  fi
fi

echo
echo "===== DEPLOYED TREE vs THE SHA IT CLAIMS ====="
AC=$(awk -F'|' '$1=="ac-host"{print $2}' "$REG")
if [ -z "$APPLIED" ]; then
  echo "skipped (no applied sha)"
elif ! git -C "$AC" cat-file -e "${APPLIED}^{commit}" 2>/dev/null; then
  echo "applied sha ${APPLIED:0:7} not in local history"
  note "applied sha ${APPLIED:0:7} unknown locally - box tree unverifiable"
else
  T=$(mktemp -d); trap 'rm -rf "$T" "$T.g" "$T.b"' EXIT
  git -C "$AC" archive "$APPLIED" | tar -x -C "$T"
  # The whole pipeline runs inside $T: sha256sum resolves find's relative paths
  # against its own cwd, so hashing outside the subshell silently hashes
  # whatever the caller happened to be sitting in.
  ( cd "$T" && find . -type f "${FIND_PRUNE[@]}" -print0 | xargs -0 sha256sum 2>/dev/null ) \
    | sed 's|  \./|  |' | sort -k2 > "$T.g"
  "${SSH[@]}" "cd /var/lib/ac-host/src && find . -type f $REMOTE_PRUNE -print0 | xargs -0 sha256sum 2>/dev/null" \
    | sed 's|  \./|  |' | sort -k2 > "$T.b"
  if [ ! -s "$T.g" ] || [ ! -s "$T.b" ]; then
    echo "could not build both manifests"; note "box tree comparison failed"
  else
    D=$(join -j2 <(sort -k2 "$T.b") <(sort -k2 "$T.g") | awk '$2!=$3{print $1}')
    OB=$(comm -23 <(awk '{print $2}' "$T.b"|sort) <(awk '{print $2}' "$T.g"|sort))
    OG=$(comm -13 <(awk '{print $2}' "$T.b"|sort) <(awk '{print $2}' "$T.g"|sort))
    if [ -z "$D$OB$OG" ]; then
      echo "CLEAN - box tree matches ${APPLIED:0:7} exactly"
    else
      [ -n "$D" ]  && { echo "EDITED ON BOX (not in git):";  echo "$D"  | sed 's/^/  /'; note "box tree differs from its own sha - hand-edits are unlanded"; }
      [ -n "$OB" ] && { echo "EXTRA ON BOX:";   echo "$OB" | head -20 | sed 's/^/  /'; }
      [ -n "$OG" ] && { echo "MISSING ON BOX:"; echo "$OG" | head -20 | sed 's/^/  /'; }
    fi
  fi
fi

echo
echo "===== SYSTEM CLOSURE vs homelab HEAD ====="
# The blind spot this section closes. Sections 2 and 3 only ever look at the
# TENANT tree -- /var/lib/ac-host/src and the sha in last-applied.json -- because
# that is the only thing Buildkite carries. But homelab owns
# nixosConfigurations.ac-box: the platform layer, the tenant contract, every
# systemd unit, slice and firewall rule. When this section was written (9 Sep
# 2026) hub/repos.psv registered homelab
# deploy=none, so NO pipeline carried it; the only path from a green build to
# the box was a human running `nixos-rebuild switch --flake`. (ADR 0006 has
# since given it one: queue-closure stages, homelab-deploy.timer applies at
# 03:30 -- so "behind HEAD" is now a state with a schedule when the timer is
# enabled and the rev is staged, and a problem only otherwise; the notes below
# say which.) Nothing compared
# HEAD to what actually built /run/current-system, so on 9 Sep 2026 the script
# printed "reconciled" over 15 commits of undeployed system configuration --
# including 45f67ab (turns the agent-hub model server on) and 4257aea (sets
# homelab.ci.enable). Live consequences at that moment: agent-hub-llm.service
# did not exist as a unit at all, background.slice was inactive with no members,
# and tcp/8100 was accepted on enp8s0 with nothing listening behind it.
#
# HOW WE CORRELATE A RUNNING CLOSURE WITH A GIT SHA. Three options, in
# decreasing order of rigour; we use whichever is available, cheapest last:
#
#  1. The stamped revision. `nixos-version --configuration-revision` returns the
#     sha baked in by system.configurationRevision. This is exact and free --
#     but on 9 Sep 2026 it returns EMPTY, and `nixos-rebuild list-generations`
#     shows "Configuration Revision: Unknown" for every generation back to 1,
#     because flake.nix never sets it. The code below prefers it anyway so this
#     check silently upgrades itself the day someone does. Setting it is a
#     CLOSURE change and is deliberately not made here: it would give every
#     commit a different toplevel store path, which is exactly the technique
#     flake.nix uses twice to prove an import is a no-op ("verified by comparing
#     nixosConfigurations.ac-box's toplevel store path before/after this line").
#     That trade is a human call, not an agent's.
#
#  2. Evaluate the toplevel here and compare store paths (HUB_STATUS_EXACT=1).
#     Exact, needs no closure change, proves drift outright: a store path is the
#     hash of the whole build recipe. Rejected as the DEFAULT purely on cost --
#     measured 6.8s warm / 11s cold in WSL against this script's documented ~2s
#     and its "safe to run constantly" contract. Evaluating is cheap; note we
#     only ever ask for .outPath, never build it. Off by default, on by env var.
#
#  3. Timestamp heuristic (the default). Compare the mtime of
#     /nix/var/nix/profiles/system -- the last switch -- against homelab's
#     committer dates. What this CAN prove: every commit made after the switch
#     is provably not in the running closure, so the count is a hard LOWER BOUND
#     on drift. What it CANNOT prove: that a zero count means current. The box
#     may have been switched from an older checkout, a dirty tree, or another
#     machine entirely; "no newer commits" is consistent with being current, not
#     proof of it, and the output says so rather than claiming clean. It also
#     assumes the two clocks agree, so we fetch the box's clock in the same
#     round trip and refuse to draw a conclusion if they have drifted apart.
#     Validated 9 Sep 2026 against ground truth: the heuristic named 5fc6c90 as
#     the newest commit that could have built generation 29, and evaluating that
#     commit in a scratch worktree reproduced the box's exact store path
#     2a6qm0bvk5mhrphf9zakgwhwhwbbci9a -- boundary commit and count both right.
HL=$(awk -F'|' '$1=="homelab"{print $2}' "$REG"); HL="${HL:-$HUB}"
SYS=$(get SYS); SYSTIME=$(get SYSTIME); SYSREV=$(get SYSREV); SYSGEN=$(get SYSGEN)
HEADSHA=$(git -C "$HL" rev-parse HEAD 2>/dev/null)
if [ -z "$BOXTXT" ] || [ -z "$SYS" ]; then
  echo "skipped (box closure unknown)"
  [ -n "$BOXTXT" ] && note "could not read $BOX's system closure - drift is unknown, not zero"
elif [ -z "$HEADSHA" ]; then
  echo "skipped (homelab checkout not readable at $HL)"
  note "homelab checkout unreadable - closure drift unverifiable"
else
  when=$([ -n "$SYSTIME" ] && date -u -d "@$SYSTIME" '+%Y-%m-%d %H:%M UTC' 2>/dev/null)
  echo "running    : ${SYS##*/} (generation ${SYSGEN:-?}, switched ${when:-unknown})"
  BOOTED=$(get SYSBOOTED)
  if [ -n "$BOOTED" ] && [ "$BOOTED" != "$SYS" ]; then
    echo "booted     : ${BOOTED##*/}"
    # Not closure drift, but the same class of lie: `systemctl status` reflects
    # the switched closure while the kernel, initrd and modules are still the
    # booted one, so a kernel or boot-parameter change looks applied and is not.
    note "box switched since boot - kernel/initrd are still generation-at-boot, a reboot is owed"
  fi
  echo "config rev : ${SYSREV:-(unstamped - system.configurationRevision is not set)}"
  CLPENDING=$(get CLPENDING); CLAPPLIED=$(get CLAPPLIED); CLTIMER=$(get CLTIMER); CLPATH=$(get CLPATH)
  # ADR 0008: with the path unit enabled the schedule is continuous -- a staged
  # rev lands within minutes, or when the lobbies clear -- and the timer is only
  # its retry. Without it, ADR 0006's one firing at the window.
  if [ "$CLPATH" = enabled ]; then CLWHEN="within minutes, or when the lobbies clear (ADR 0008)"; else CLWHEN="at the next window"; fi
  # "Behind HEAD" means three different things depending on what will move it,
  # and the verdict has to name the right one or the operator does the wrong
  # thing (a hand switch over a staged rev is how the cache-stale no-op of
  # 12 Sep happened). $1 is the measured gap; the tail says who closes it.
  closure_behind() {
    if [ "$CLTIMER" != "enabled" ]; then
      note "system closure is $1 - homelab-deploy.timer is ${CLTIMER:-absent}, so only a human nixos-rebuild switch moves it"
    elif [ -n "$CLPENDING" ] && [ "$CLPENDING" = "$HEADSHA" ]; then
      echo "  HEAD is staged; homelab-deploy applies it $CLWHEN (nothing to do)"
    elif [ -n "$CLPENDING" ] && [ "$CLPENDING" != "$CLAPPLIED" ]; then
      note "system closure is $1 - ${CLPENDING:0:7} is staged, HEAD is not: push, or wait for HEAD's build to stage it"
    else
      note "system closure is $1 and nothing is staged - HEAD's build has not run queue-closure (unpushed? red gate? agent lacks the /var/lib/homelab mount?)"
    fi
  }
  case "$CLTIMER" in
    enabled) echo "deploy     : homelab-deploy.timer enabled$( [ "$CLPATH" = enabled ] && echo ", path enabled (ADR 0008 continuous)" || echo " (ADR 0006 window)") - queued ${CLPENDING:-none}, applied ${CLAPPLIED:-none}" ;;
    *)       echo "deploy     : homelab-deploy.timer ${CLTIMER:-absent} - queued ${CLPENDING:-none}, applied ${CLAPPLIED:-none}" ;;
  esac
  # Queued-but-not-applied is a state, not a failure, while the timer exists:
  # it means "will land at the next window". It IS a problem when the timer is
  # not enabled, because then nothing will ever apply it -- the closure's
  # version of "deploy queued but not applied - needs DOWNTIME=1" above.
  if [ -n "$CLPENDING" ] && [ "$CLPENDING" != "$CLAPPLIED" ]; then
    if [ "$CLTIMER" = "enabled" ]; then
      echo "             closure ${CLPENDING:0:7} is staged; homelab-deploy applies it $CLWHEN"
    else
      note "closure ${CLPENDING:0:7} is staged but homelab-deploy.timer is ${CLTIMER:-absent} - nothing will apply it"
    fi
  fi
  # A stamped running rev that disagrees with what was last APPLIED by the
  # deploy unit means someone switched by hand since. Not wrong, but worth a
  # line: the applied record no longer describes the running system.
  if [ -n "$SYSREV" ] && [ -n "$CLAPPLIED" ] && [ "${SYSREV%-dirty}" != "$CLAPPLIED" ]; then
    echo "             running rev ${SYSREV:0:7} != last deploy-unit apply ${CLAPPLIED:0:7} - a hand switch happened since"
  fi
  echo "homelab    : HEAD ${HEADSHA:0:7}$([ "$(git -C "$HL" status --porcelain 2>/dev/null | wc -l)" != 0 ] && echo ' (+ uncommitted changes)')"

  if [ -n "$SYSREV" ]; then
    if [ "$SYSREV" = "$HEADSHA" ]; then
      echo "CLEAN - box closure was built from HEAD (stamped revision matches)"
    elif git -C "$HL" cat-file -e "${SYSREV}^{commit}" 2>/dev/null; then
      n=$(git -C "$HL" rev-list --count "$SYSREV..$HEADSHA" 2>/dev/null)
      echo "DRIFT - box built from ${SYSREV:0:7}, $n commit(s) behind HEAD:"
      git -C "$HL" log --format='  %h %s' "$SYSREV..$HEADSHA" 2>/dev/null | head -8
      closure_behind "$n commit(s) behind homelab HEAD"
    else
      echo "DRIFT - box stamped ${SYSREV:0:7}, which is not in local history"
      note "box closure sha ${SYSREV:0:7} unknown locally - system config unverifiable"
    fi
  elif [ "${HUB_STATUS_EXACT:-0}" = 1 ]; then
    echo -n "exact check: evaluating .#nixosConfigurations.ac-box ... "
    want=$(NIX_CONFIG="experimental-features = nix-command flakes" \
      nix eval --raw "$HL#nixosConfigurations.ac-box.config.system.build.toplevel" 2>/dev/null)
    if [ -z "$want" ]; then
      echo "FAILED"; note "toplevel eval failed - closure drift unverifiable (try scripts/hub-gates.sh homelab)"
    elif [ "$want" = "$SYS" ]; then
      echo; echo "CLEAN - this tree builds exactly what the box runs"
    else
      echo; echo "would build: ${want##*/}"
      echo "DRIFT - this tree and the box are different closures"
      closure_behind "differs from this tree's build"
    fi
  else
    BOXCLOCK=$(get BOXCLOCK)
    skew=$(( ${BOXCLOCK:-0} - $(date +%s) )); [ "$skew" -lt 0 ] && skew=$(( -skew ))
    if [ -z "$SYSTIME" ]; then
      echo "cannot date the switch - drift unknown"
      note "box switch time unreadable - closure drift unverifiable"
    elif [ "$skew" -gt 300 ]; then
      echo "clocks differ by ${skew}s - timestamp heuristic refused"
      note "box clock is ${skew}s off this host - closure drift unverifiable without HUB_STATUS_EXACT=1"
    else
      n=$(git -C "$HL" rev-list --count --since="@$SYSTIME" HEAD 2>/dev/null)
      base=$(git -C "$HL" rev-list -1 --until="@$SYSTIME" HEAD 2>/dev/null)
      if [ "${n:-0}" -gt 0 ]; then
        echo "DRIFT - $n commit(s) committed AFTER that switch, so none of them can be in it:"
        git -C "$HL" log --since="@$SYSTIME" --format='  %h %s' 2>/dev/null | head -8
        [ "$n" -gt 8 ] && echo "  ... and $((n - 8)) more"
        echo "newest commit that could have built it: ${base:0:7} $(git -C "$HL" log -1 --format=%s "$base" 2>/dev/null)"
        closure_behind ">= $n commit(s) behind homelab HEAD"
      else
        echo "no commit is newer than that switch - CONSISTENT with current, not proof of it"
        echo "  (the box may still have switched from an older or dirty tree;"
        echo "   run HUB_STATUS_EXACT=1 bash scripts/hub-status.sh to prove it, ~7s)"
      fi
    fi
  fi
fi

echo
if [ ${#PROBLEMS[@]} -eq 0 ]; then echo "===== VERDICT: reconciled ====="; exit 0; fi
echo "===== VERDICT: ${#PROBLEMS[@]} item(s) need attention ====="
printf '  - %s\n' "${PROBLEMS[@]}"
exit 1
