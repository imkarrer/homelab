#!/usr/bin/env bash
# Three-way state: the hosts (deployed) vs origin (git) vs the WSL checkouts.
# Answers "what is actually where" in one call, so nothing has to re-derive it.
# Exit 0 = reconciled, 1 = something needs attention.
set -uo pipefail

HUB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REG="${HUB_REGISTRY:-$HUB/hub/repos.psv}"
PROBLEMS=()
# A verdict recorded inside a host's sections names the host: BOX is set by the
# per-host loop below and empty before it (the DEV and CI sections are about
# this machine and origin, not about a host).
BOX=""
note() { PROBLEMS+=("${BOX:+$BOX: }$1"); }
# shellcheck source=scripts/lib/hosts.sh
. "$HUB/scripts/lib/hosts.sh"
# The hosts this report walks: flake.nix's nixosConfigurations (lib/hosts.sh,
# ~0.05 s; HOMELAB_BOX=<host> narrows to one). Discovery failing is a verdict
# -- the report then covers ac-box alone and says so -- not a crash: every
# section below still answers for the host it can reach.
if ! HOSTS=$(hub_hosts "$HUB"); then
  HOSTS=ac-box
  note "host discovery failed (nix eval of $HUB#nixosConfigurations) - this report covers ac-box only; scripts/hub-gates.sh homelab says why"
fi
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

# The backup lives HERE, not on a box. scripts/hub-backup.sh pulls every host's
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
  bhosts=$(grep '^HOSTS=' "$BSTATUS" | cut -d= -f2-)   # per host since 26 Sep 2026; absent in older files
  bepoch=$(grep '^LAST_SUCCESS_EPOCH=' "$BSTATUS" | cut -d= -f2-)
  bsnaps=$(grep '^SNAPSHOTS=' "$BSTATUS" | cut -d= -f2-)
  bsize=$(grep '^REPO_SIZE=' "$BSTATUS" | cut -d= -f2-)
  bresult=$(grep '^LAST_RESULT=' "$BSTATUS" | cut -d= -f2-)
  bdays=$(( ( $(date +%s) - ${bepoch:-0} ) / 86400 ))
  printf "%-18s last success %s (%s snapshots, %s)%s\n" "backup" "${bwhen:-never}" "${bsnaps:-0}" "${bsize:-?}" "${bhosts:+ - hosts: $bhosts}"
  if [ -z "$bepoch" ]; then
    note "backup: scripts/hub-backup.sh has never completed - the restic repo has no usable snapshot"
  elif [ "$bdays" -gt 3 ]; then
    note "backup: last success was $bdays day(s) ago ($bwhen) - the nightly pull is not running (systemctl status hub-backup.timer; journalctl -u hub-backup)"
  fi
  case "$bresult" in ok|'') ;; *) note "backup: last attempt $bresult" ;; esac
else
  note "backup: no status file at $BSTATUS - hub-backup.timer is not installed here (docs/runbook-restore.md)"
fi

# The FloxHub token CI pushes generations with (ADR 0009 step 2). Two kinds
# exist: what `flox auth token` prints after a browser login is a 30-day
# Auth0 JWT (docs/flox-findings.md, "Two more"), and what the operator
# issued on hub.flox.dev for CI is an opaque `flox…` token whose lifetime is
# set there. A JWT's expiry is readable from the repo's own encrypted copy
# (base64url payload, `exp` is not a secret) -- decoded here, verdict under
# seven days, because an expired token makes every push step go red only
# AFTER the next tenant push. An opaque token gets a line naming where its
# expiry lives, not a guess. Rotation either way: new token |
# scripts/hub-secret-set.sh floxhub-token; push; agent recreate.
. "$HUB/scripts/lib/sops-secret.sh"
if fhtok=$(hub_sops_secret floxhub-token 2>/dev/null) && [ -n "$fhtok" ]; then
  fhlen=${#fhtok}
  fhpayload=$(printf '%s' "$fhtok" | cut -d. -f2 | tr '_-' '/+')
  case $(( ${#fhpayload} % 4 )) in 2) fhpayload="$fhpayload==";; 3) fhpayload="$fhpayload=";; esac
  fhexp=$(printf '%s' "$fhpayload" | base64 -d 2>/dev/null | grep -oE '"exp": *[0-9]+' | grep -oE '[0-9]+$')
  unset fhtok fhpayload
  if [ -n "$fhexp" ]; then
    fhdays=$(( ( fhexp - $(date +%s) ) / 86400 ))
    printf "%-18s expires %s (%s day(s))\n" "floxhub-token" "$(date -u -d "@$fhexp" +%Y-%m-%dT%H:%MZ)" "$fhdays"
    if [ "$fhdays" -lt 0 ]; then
      note "floxhub-token: EXPIRED $(( -fhdays )) day(s) ago - every flox push step skips or fails until it is rotated (docs/flox-findings.md)"
    elif [ "$fhdays" -lt 7 ]; then
      note "floxhub-token: expires in $fhdays day(s) - rotate now: flox auth login; flox auth token | scripts/hub-secret-set.sh floxhub-token; push; agent recreate"
    fi
  else
    printf "%-18s present (opaque, %s chars) - lifetime is set on hub.flox.dev, not readable here\n" "floxhub-token" "$fhlen"
  fi
else
  printf "%-18s not in secrets/ac-box.yaml - flox tenants cannot push generations\n" "floxhub-token"
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


# ---------------------------------------------------------------------------
# Per host: the BOX section, the tenant tree against the sha it claims, the
# system closure against homelab HEAD. Until 26 Sep 2026 there was one host
# and these three sections ran once against ac-box; flake.nix now declares
# arcade-box too (ADR 0010), and after the cutover (docs/runbook-arcade-box-
# cutover.md phase 4) the lobbies, the bot, arcade and observability are on
# it while agent-hub stays on the Z840 -- so a report that read one machine
# would be reporting on the wrong one for most of what it checks. The hosts
# come from scripts/lib/hosts.sh (the flake's nixosConfigurations; HOMELAB_BOX
# narrows to one, which is the old behaviour exactly). Every verdict a section
# records is prefixed with the host by note() itself, so no line below has to
# remember to. An unreachable host is a verdict and its sections say skipped;
# it does not end the report.
#
# What is per host and what is not: the tenant tree checks (applied/pending,
# the bot, the DOWNTIME build, the file-by-file diff against ac-host's sha)
# belong to the host that runs the assetto tenant, and the box says which one
# that is -- /etc/homelab/tenants.json, the inventory modules/tenant/quiet.nix
# renders from `homelab.tenants.<n>.enable` of the closure the host is
# RUNNING, read in the same round trip as everything else. File presence
# would lie here: phase 3 syncs /var/lib/ac-host to arcade-box weeks before
# assetto is enabled there, so on arcade-box today the tree exists and is
# nobody's. The config in git holds the same fact for the closure the host
# will run next and would cost ~7 s per host against this script's ~2 s.
# The environment lines were per host already: they come from that host's
# /etc/homelab/environments.json.
# ---------------------------------------------------------------------------
AC=$(awk -F'|' '$1=="ac-host"{print $2}' "$REG")
HL=$(awk -F'|' '$1=="homelab"{print $2}' "$REG"); HL="${HL:-$HUB}"
HEADSHA=$(git -C "$HL" rev-parse HEAD 2>/dev/null)
TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT

box_section() {
  echo "===== BOX: $BOX ====="
  BOXTXT=""; APPLIED=""; PENDING=""; TREE=unknown
  # One round trip, one KEY=VALUE per line: robust to any JSON contents.
  BOXTXT=$("${SSH[@]}" '
    s=/var/lib/ac-host
    echo "APPLIED=$(grep -oE "[0-9a-f]{40}" $s/last-applied.json 2>/dev/null | head -1)"
    echo "PENDING=$(grep -oE "[0-9a-f]{40}" $s/pending-deploy.json 2>/dev/null | head -1)"
    echo "FAILED=$(systemctl --failed --no-legend 2>/dev/null | wc -l)"
    echo "CONTAINERS=$(docker ps -q 2>/dev/null | wc -l)"
    echo "DISK=$(df -h / | awk "NR==2{print \$5}")"
    echo "LOAD=$(cut -d" " -f1-3 /proc/loadavg)"
    # Which machine answered, and which tenants it runs (the header above): the
    # alias must be the host, and the tenant tree checks belong to the host
    # whose inventory lists assetto. quiet.nix writes only ENABLED tenants.
    echo "HOSTNAME=$(cat /proc/sys/kernel/hostname 2>/dev/null)"
    echo "INVENTORY=$(test -r /etc/homelab/tenants.json && echo present || echo absent)"
    echo "TENANTS=$(grep -oE "\"name\":\"[A-Za-z0-9_-]+\"" /etc/homelab/tenants.json 2>/dev/null | cut -d\" -f4 | tr "\n" " ")"
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
    # The ENVIRONMENT deploy pairs (ADR 0009), one per flox tenant, beside the
    # closure pair. Which tenants have one is the running closure'"'"'s fact --
    # /etc/homelab/environments.json, written by modules/tenant/
    # environment-pull.nix -- not the presence of a pending file, so a tenant
    # whose pull unit exists and has never been staged still gets a line.
    # queue-environment (Buildkite, via the tenant'"'"'s trigger) writes pending;
    # the pull unit writes applied after the restart. Same grep shape as the
    # closure pair: every record is one line of JSON with known flat keys
    # (the box has no jq on its path). The tenant list is anchored on the
    # "unit" key, whose value names the tenant, rather than on the order
    # toJSON happens to emit keys in (.3'"'"'s review). Two source kinds: tree
    # (a sha) and floxhub (a generation, a JSON number, with the tenant
    # commit that pushed it as "rev"); ENVSOURCE says which, and the staged
    # /applied values are the sha or the generation accordingly.
    e=/etc/homelab/environments.json
    tenants=$(grep -oE "\"unit\":\"[A-Za-z0-9_-]+-environment-pull\.service\"" $e 2>/dev/null | sed -E "s/\"unit\":\"(.*)-environment-pull\.service\"/\1/")
    echo "ENVTENANTS=$(echo "$tenants" | tr "\n" " ")"
    for t in $tenants; do
      p=$h/pending-environment-$t.json; a=$h/last-applied-environment-$t.json
      # This tenant'"'"'s own object: from its opening brace to the "unit" key
      # that names it. Nested values are absent by construction (flat keys).
      obj=$(grep -oE "\"$t\":\{[^{}]*\"unit\":\"$t-environment-pull\.service\"" $e)
      src=$(echo "$obj" | grep -oE "\"source\":\"[a-z]+\"" | cut -d\" -f4)
      echo "ENVSOURCE_$t=$src"
      echo "ENVENV_$t=$(echo "$obj" | grep -oE "\"env\":\"[^\"]*\"" | cut -d\" -f4)"
      echo "ENVSTUB_$t=$(echo "$obj" | grep -oE "\"enable\":(true|false)" | grep -oE "(true|false)$")"
      echo "ENVTREE_$t=$(echo "$obj" | grep -oE "\"tree\":\"[^\"]*\"" | cut -d\" -f4)"
      if [ "$src" = floxhub ]; then
        echo "ENVPENDING_$t=$(grep -oE "\"generation\":[0-9]+" $p 2>/dev/null | grep -oE "[0-9]+" | head -1)"
        echo "ENVPENDINGREV_$t=$(grep -oE "\"rev\":\"[0-9a-f]{40}\"" $p 2>/dev/null | grep -oE "[0-9a-f]{40}" | head -1)"
        echo "ENVAPPLIED_$t=$(grep -oE "\"generation\":[0-9]+" $a 2>/dev/null | grep -oE "[0-9]+" | head -1)"
        echo "ENVPINNED_$t=$(cat $h/pinned-environment-$t 2>/dev/null | grep -oE "^[0-9]+$")"
      else
        echo "ENVPENDING_$t=$(grep -oE "\"sha\":\"[0-9a-f]{40}\"" $p 2>/dev/null | grep -oE "[0-9a-f]{40}" | head -1)"
        echo "ENVAPPLIED_$t=$(grep -oE "\"sha\":\"[0-9a-f]{40}\"" $a 2>/dev/null | grep -oE "[0-9a-f]{40}" | head -1)"
      fi
      echo "ENVQUEUED_$t=$(grep -oE "\"queued_at\":\"[^\"]*\"" $p 2>/dev/null | cut -d\" -f4)"
      echo "ENVRUN_$t=$(grep -oE "\"run_path\":\"[^\"]*\"" $a 2>/dev/null | cut -d\" -f4 | sed "s|^/nix/store/||")"
      echo "ENVAPPLIEDAT_$t=$(grep -oE "\"applied_at\":\"[^\"]*\"" $a 2>/dev/null | cut -d\" -f4)"
      # is-failed prints the state either way; "failed" is the verdict, and
      # the last journal line is why (the script logs its own refusals).
      echo "ENVPULL_$t=$(systemctl is-failed $t-environment-pull.service 2>/dev/null)"
      echo "ENVPATH_$t=$(systemctl is-enabled $t-environment-pull.path 2>/dev/null)"
      echo "ENVLOG_$t=$(journalctl -u $t-environment-pull.service -n1 -o cat --no-pager 2>/dev/null | tail -1)"
    done
  ' 2>/dev/null)

  get() { echo "$BOXTXT" | grep "^$1=" | head -1 | cut -d= -f2-; }
  if [ -z "$BOXTXT" ]; then
    echo "UNREACHABLE"; note "unreachable - its state is unknown, not clean"
  else
    HN=$(get HOSTNAME)
    if [ -n "$HN" ] && [ "$HN" != "$BOX" ]; then
      note "the ssh alias reached a machine calling itself $HN - ~/.ssh/config's address for $BOX is the other host's (the cutover swaps 192.168.1.50: docs/runbook-arcade-box-cutover.md phase 4); everything under this BOX section is about $HN"
    fi
    case "$(get INVENTORY)" in
      present) case " $(get TENANTS) " in *" assetto "*) TREE=yes ;; *) TREE=no ;; esac ;;
      *) TREE=unknown ;;
    esac
    APPLIED=$(get APPLIED); PENDING=$(get PENDING)
    if [ "$TREE" = no ]; then
      # The tree may well be present -- phase 3 syncs /var/lib/ac-host ahead
      # of the flip -- but it is not this host's to report on. APPLIED and
      # PENDING empty is what skips the bot/DOWNTIME lines below and makes
      # tree_section say skipped instead of calling a synced copy drift.
      echo "tenant tree: assetto is not enabled on $BOX (its inventory: $(get TENANTS | sed 's/ $//')) - applied/pending, bot and DOWNTIME are the other host's"
      APPLIED=""; PENDING=""
    else
      [ "$TREE" != unknown ] || echo "(no /etc/homelab/tenants.json on $BOX - which tenants it runs is unknown; tenant tree checks run regardless)"
      echo "applied    : ${APPLIED:-none}"
      echo "pending    : ${PENDING:-none}"
    fi
    echo "failed=$(get FAILED) containers=$(get CONTAINERS) disk=$(get DISK) load=$(get LOAD)"
    [ "$(get FAILED)" != 0 ] && note "$(get FAILED) failed systemd unit(s)"
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
}

tree_section() {
  echo "===== DEPLOYED TREE vs THE SHA IT CLAIMS: $BOX ====="
  if [ "$TREE" = no ]; then
    echo "skipped (assetto is not enabled on $BOX - the tenant tree is the other host's)"
  elif [ -z "$APPLIED" ]; then
    echo "skipped (no applied sha)"
  elif ! git -C "$AC" cat-file -e "${APPLIED}^{commit}" 2>/dev/null; then
    echo "applied sha ${APPLIED:0:7} not in local history"
    note "applied sha ${APPLIED:0:7} unknown locally - box tree unverifiable"
  else
    T="$TMPD/$BOX"; mkdir -p "$T"   # one scratch root for the run, removed at exit
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
}

closure_section() {
  echo "===== SYSTEM CLOSURE vs homelab HEAD: $BOX ====="
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
  SYS=$(get SYS); SYSTIME=$(get SYSTIME); SYSREV=$(get SYSREV); SYSGEN=$(get SYSGEN)
  if [ -z "$BOXTXT" ] || [ -z "$SYS" ]; then
    echo "skipped (box closure unknown)"
    [ -n "$BOXTXT" ] && note "could not read the system closure - drift is unknown, not zero"
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
      elif [ "$(get INVENTORY)" = present ] && [[ " $(get TENANTS) " != *" ci "* ]]; then
        # queue-closure runs on the CI agent and writes the pending record on
        # the host the agent is on; a host whose inventory has no ci tenant has
        # no agent, and nothing will ever stage here (arcade-box until runbook
        # 4.2 moves the agent). Behind, and only a hand switch moves it.
        note "system closure is $1 and nothing is staged - no CI agent on this host (ci is not in its inventory), so nothing stages a closure here until the cutover moves the agent (runbook 4.2); until then only a hand switch moves it (runbook 5.4)"
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
    # One line per flox tenant (ADR 0009): what CI staged against what the
    # pull unit applied, the run store path as the content stamp (docs/
    # flox-findings.md 3), and whether the stub runs from it. Two source
    # kinds, one line shape: a tree tenant's unit is a sha (`staged abc1234`),
    # a floxhub tenant's a generation (`staged g4`, the tenant commit that
    # pushed it in brackets, and the pin the stub reads when it disagrees
    # with what was applied). A staged unit the pull has not landed is a
    # state for ~15 min (the path unit fires at once; the warm can take
    # minutes online) and a verdict after it -- the pull failed soft, the
    # tenant was busy, or nothing is watching. A record with no queued_at
    # (hand-written on the box) has no age: it is reported as staged, never
    # as stale (.3's review: `date -d ""` is midnight today, not unknown). A
    # stub that is on with nothing applied is the one state modules/tenant/
    # environment-pull.nix's first-switch order exists to prevent, and it
    # is named as such. The tenant's origin HEAD is held against the staged
    # sha (tree) or the staged record's rev (floxhub) the way the closure's
    # is: a green push whose trigger did not stage is otherwise invisible
    # (the trigger is async and soft_fail).
    s7() { if [ -n "$1" ]; then echo "${1:0:7}"; else echo none; fi; }
    gN() { if [ -n "$1" ]; then echo "g$1"; else echo none; fi; }
    for t in $(get ENVTENANTS); do
      EP=$(get "ENVPENDING_$t"); EA=$(get "ENVAPPLIED_$t"); ER=$(get "ENVRUN_$t"); ES=$(get "ENVSTUB_$t")
      EPULL=$(get "ENVPULL_$t"); EPATH=$(get "ENVPATH_$t"); ELOG=$(get "ENVLOG_$t"); ET=$(get "ENVTREE_$t")
      ESRC=$(get "ENVSOURCE_$t"); EENV=$(get "ENVENV_$t"); EPREV=$(get "ENVPENDINGREV_$t"); EPIN=$(get "ENVPINNED_$t")
      stub=$([ "$ES" = true ] && echo "stub ON" || echo "stub off")
      if [ "$ESRC" = floxhub ]; then
        disp() { gN "$1"; }
        # What the tree's origin HEAD is compared with: the record's rev.
        staged_rev=$EPREV
        what="$(gN "$EP")${EPREV:+ [${EPREV:0:7}]}"
        echo "$t env    : staged $(gN "$EP") / applied $(gN "$EA")${ER:+ (run ${ER:0:7})} - $EENV, $stub, pull unit ${EPULL:-absent}, path ${EPATH:-absent}"
        # A pin that matches neither record: in flight it equals the staged
        # generation (pinned, restart pending), and the staged verdict below
        # covers that; anything else is a hand edit or a dead pull.
        if [ -n "$EA" ] && [ "$EPIN" != "$EA" ] && [ "$EPIN" != "$EP" ]; then
          note "$t env: the stub is pinned to $(gN "$EPIN") but $(gN "$EA") was applied - the pin file and the applied record disagree (pinned-environment-$t was edited, or the pull died between the pin and the record)"
        fi
      else
        disp() { s7 "$1"; }
        staged_rev=$EP
        what="$(s7 "$EP")"
        echo "$t env    : staged $(s7 "$EP") / applied $(s7 "$EA")${ER:+ (run ${ER:0:7})} - $stub, pull unit ${EPULL:-absent}, path ${EPATH:-absent}"
      fi
      if [ "$EPULL" = failed ]; then
        note "$t env: $t-environment-pull.service failed - ${ELOG:-see journalctl -u $t-environment-pull}"
      fi
      if [ -n "$EP" ] && [ "$EP" != "$EA" ]; then
        EQ=$(get "ENVQUEUED_$t")
        qage=""
        if [ -n "$EQ" ]; then
          qts=$(date -d "$EQ" +%s 2>/dev/null) && qage=$(( $(date +%s) - qts ))
        fi
        if [ "$EPATH" != enabled ]; then
          note "$t env: $what is staged but $t-environment-pull.path is ${EPATH:-absent} - nothing will pull it"
        elif [ -n "$qage" ] && [ "$qage" -gt 900 ]; then
          note "$t env: $what staged $(ago $(( $(date +%s) - qage ))) ago, applied is $(disp "$EA") - the pull has not landed it (${ELOG:-journalctl -u $t-environment-pull})"
        elif [ -z "$qage" ]; then
          echo "             $t env: $what is staged (no queued_at in the record, age unknown); $t-environment-pull applies it within minutes (${ELOG:-no journal line yet})"
        else
          echo "             $t env: $what is staged; $t-environment-pull applies it within minutes (${ELOG:-no journal line yet})"
        fi
      fi
      if [ "$ES" = true ] && [ -z "$EA" ]; then
        note "$t env: the stub is ON and nothing has been applied - its unit activates an empty ${t} environment; stage a ${ESRC:-tree} record now (environment-pull.nix's first-switch order was not followed)"
      fi
      # Only once the edge has carried something: a tenant with no pending
      # and no applied record has never been wired (its pipeline lacks the
      # trigger yet), and that is a line above, not a problem.
      if { [ -n "$EP" ] || [ -n "$EA" ]; } && [ -n "$ET" ] && [ -n "${OHEAD[$ET]:-}" ] && [ "${OHEAD[$ET]}" != "$staged_rev" ] && [ $(( $(date +%s) - ${OHEADT[$ET]:-0} )) -gt 1800 ]; then
        note "$t env: $ET origin HEAD ${OHEAD[$ET]:0:7} ($(ago "${OHEADT[$ET]}") ago) is not staged on the box (staged $(s7 "$staged_rev")) - its build's trigger did not run queue-environment (red gate? trigger missing? HOMELAB_STAGE_ENVIRONMENT not routed?)"
      fi
    done
    echo "homelab    : HEAD ${HEADSHA:0:7}$([ "$(git -C "$HL" status --porcelain 2>/dev/null | wc -l)" != 0 ] && echo ' (+ uncommitted changes)')"

    if [ -n "$SYSREV" ]; then
      if [ "$SYSREV" = "$HEADSHA" ]; then
        echo "CLEAN - box closure was built from HEAD (stamped revision matches)"
      elif git -C "$HL" cat-file -e "${SYSREV}^{commit}" 2>/dev/null; then
        n=$(git -C "$HL" rev-list --count "$SYSREV..$HEADSHA" 2>/dev/null)
        ahead=$(git -C "$HL" rev-list --count "$HEADSHA..$SYSREV" 2>/dev/null)
        if [ "${ahead:-0}" != 0 ]; then
          # The box runs a commit HEAD does not contain: a hand switch from an
          # unmerged branch. arcade-box's build-up switches (runbook 5.4) are
          # exactly this, so it is named as what it is -- unlanded work on a
          # box, like a worktree main lacks -- rather than as "0 behind" with a
          # diagnosis about queue-closure that cannot apply. Before 26 Sep 2026
          # this printed "DRIFT - 0 commit(s) behind HEAD" over an empty log.
          br=$(git -C "$HL" branch --format='%(refname:short)' --contains "$SYSREV" 2>/dev/null | head -3 | paste -sd, -)
          echo "UNMERGED - box built from ${SYSREV:0:7}, which HEAD does not contain ($ahead commit(s) on ${br:-no local branch}$([ "${n:-0}" != 0 ] && echo "; $n of HEAD's not in it")):"
          git -C "$HL" log --format='  %h %s' "$HEADSHA..$SYSREV" 2>/dev/null | head -8
          note "runs ${SYSREV:0:7}, which homelab HEAD does not contain ($ahead unmerged commit(s), ${br:-no local branch}) - land that branch; a box is not where work lives"
        else
          echo "DRIFT - box built from ${SYSREV:0:7}, $n commit(s) behind HEAD:"
          git -C "$HL" log --format='  %h %s' "$SYSREV..$HEADSHA" 2>/dev/null | head -8
          closure_behind "$n commit(s) behind homelab HEAD"
        fi
      else
        echo "DRIFT - box stamped ${SYSREV:0:7}, which is not in local history"
        note "box closure sha ${SYSREV:0:7} unknown locally - system config unverifiable"
      fi
    elif [ "${HUB_STATUS_EXACT:-0}" = 1 ]; then
      echo -n "exact check: evaluating .#nixosConfigurations.$BOX ... "
      want=$(NIX_CONFIG="experimental-features = nix-command flakes" \
        nix eval --raw "$HL#nixosConfigurations.$BOX.config.system.build.toplevel" 2>/dev/null)
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
}

for BOX in $HOSTS; do
  SSH=(ssh -o BatchMode=yes -o ConnectTimeout=8 "$BOX")
  echo; box_section
  echo; tree_section
  echo; closure_section
done
BOX=""
echo
if [ ${#PROBLEMS[@]} -eq 0 ]; then echo "===== VERDICT: reconciled ====="; exit 0; fi
echo "===== VERDICT: ${#PROBLEMS[@]} item(s) need attention ====="
printf '  - %s\n' "${PROBLEMS[@]}"
exit 1
