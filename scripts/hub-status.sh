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
  [ "$remote" != none ] && git -C "$path" fetch -q origin 2>/dev/null
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
done < "$REG"

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
  echo "CIEXIT=$(docker logs --tail 400 ac-host-ci-agent-1 2>&1 | grep -oE "Exit Status: [0-9]+" | tail -1 | grep -oE "[0-9]+$")"
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
  echo "last CI job: exit $(get CIEXIT)"
  [ "$(get FAILED)" != 0 ] && note "box has $(get FAILED) failed systemd unit(s)"
  ce=$(get CIEXIT); [ -n "$ce" ] && [ "$ce" != 0 ] && note "last CI job exited $ce - queue-prod blocked, nothing can deploy"
  [ -n "$PENDING" ] && [ "$PENDING" != "$APPLIED" ] && note "deploy queued (${PENDING:0:7}) but not applied - needs ops pipeline DOWNTIME=1"
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
# systemd unit, slice and firewall rule. hub/repos.psv registers homelab
# deploy=none, so NO pipeline carries it; the only path from a green build to
# the box is a human running `nixos-rebuild switch --flake`. Nothing compared
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
  CLPENDING=$(get CLPENDING); CLAPPLIED=$(get CLAPPLIED); CLTIMER=$(get CLTIMER)
  case "$CLTIMER" in
    enabled) echo "deploy     : homelab-deploy.timer enabled (ADR 0006 live) - queued ${CLPENDING:-none}, applied ${CLAPPLIED:-none}" ;;
    *)       echo "deploy     : homelab-deploy.timer ${CLTIMER:-absent} - queued ${CLPENDING:-none}, applied ${CLAPPLIED:-none}" ;;
  esac
  # Queued-but-not-applied is a state, not a failure, while the timer exists:
  # it means "will land at the next window". It IS a problem when the timer is
  # not enabled, because then nothing will ever apply it -- the closure's
  # version of "deploy queued but not applied - needs DOWNTIME=1" above.
  if [ -n "$CLPENDING" ] && [ "$CLPENDING" != "$CLAPPLIED" ]; then
    if [ "$CLTIMER" = "enabled" ]; then
      echo "             closure ${CLPENDING:0:7} is staged; homelab-deploy.timer applies it at the next window"
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
      note "system closure is $n commit(s) behind homelab HEAD - needs a human nixos-rebuild switch"
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
      note "system closure differs from this tree's build - needs a human nixos-rebuild switch"
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
        note "system closure is >= $n commit(s) behind homelab HEAD - homelab is deploy=none, so only a human nixos-rebuild switch moves it"
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
