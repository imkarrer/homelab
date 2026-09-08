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
if [ ${#PROBLEMS[@]} -eq 0 ]; then echo "===== VERDICT: reconciled ====="; exit 0; fi
echo "===== VERDICT: ${#PROBLEMS[@]} item(s) need attention ====="
printf '  - %s\n' "${PROBLEMS[@]}"
exit 1
