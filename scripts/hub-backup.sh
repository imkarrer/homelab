#!/usr/bin/env bash
# Row 22: back ac-box's DECLARED state up, onto this machine, every night.
#
# Four tenants set `homelab.tenants.<n>.state.backup = true` and, until this
# script existed, nothing read it: docs/architecture.md row 22 called it the
# largest remaining gap. A dead disk in the Z840 lost races, series, the
# whitelist, the arcade saves and the monitoring secrets. So:
#
#   1. ask the CONTRACT which directories to back up (nix eval, below) --
#      never a list typed into this file, because a list typed here is a
#      second spelling of the declaration and is free to drift out of
#      agreement with it. Adding `backup = true` to a tenant is the whole
#      change needed to get that tenant backed up.
#   2. rsync -a --numeric-ids --delete each one into a staging tree here.
#   3. restic backup that staging tree into a local repo, forget+prune to the
#      retention policy, and verify a sample of the data it just wrote.
#   4. write a status file, because a backup nobody can see fail is not one
#      (hub-status.sh reads it; a run older than three days is a verdict).
#
# ---------------------------------------------------------------------------
# THE SHAPE, AND WHY IT IS LOCAL AND PULL-BASED
# ---------------------------------------------------------------------------
# LOCAL ONLY, on this WSL machine: the operator chose it on 14 Sep 2026. It is
# a real backup of the one thing that has no other copy -- box state -- and it
# is not an offsite backup: a fire, a theft or a ransomed Windows account takes
# both machines. An offsite repo is a later bead, and restic's repo format is
# already what makes that a `restic copy` rather than a rewrite.
#
# PULL, not push: the WSL distro sits behind Windows' NAT with no sshd exposed
# into it, and exposing one is precisely what this avoids. The box never learns
# this machine exists; every connection is outbound from here, with the key the
# operator already uses (~/.ssh/id_ed25519_ac-host), and the far side is
# READ-ONLY -- rsync's sender never writes. Nothing here can damage ac-box.
#
# ROOT, here, and why: the state is owned by five different service accounts
# on the box (root:root under /var/lib/ac-host, arcade:arcade, agent-hub,
# grafana:grafana at 0700 and prometheus:prometheus at 0700). Only root can
# reproduce those owners locally, and --numeric-ids keeps them as UIDs rather
# than resolving them against THIS machine's passwd, where uid 993 is somebody
# else entirely. A backup that silently flattens ownership restores a service
# that cannot read its own state. We ssh AS root to the box because that is the
# account the operator's key already has there (~/.ssh/config:
# root@192.168.1.50), so no `sudo rsync` on the far side is needed; verified
# read-only before this script was written.
#
# NOT ATOMIC, and it says so rather than pretending: rsync copies a live tree.
# A file written during the copy is captured mid-write. The state here is JSON
# and small files rewritten by hand or by a bot between races -- not a database
# under constant write -- so the exposure is one nightly instant, and the cost
# of quiescing the box (a window, a drain of live race servers) is far higher
# than the risk. If a tenant ever grows a real database, it gets a dump hook
# and this comment gets a sibling.
#
# The sibling (16 Sep 2026, homelab-bqo.58): observability now declares two
# real databases, and neither gets a dump hook yet. Grafana's is one sqlite
# file (data/grafana.db, ~2 M) written on dashboard saves, logins and alert
# state changes -- at 04:30 that is nearly idle, a torn copy needs a write to
# land inside the ~1 s the file takes to read, and the previous night's
# snapshot is the fallback. Prometheus' TSDB is append-only in the way that
# suits this: the
# two-hour blocks under data/ are immutable once cut, and only wal/ and
# chunks_head/ are live; Prometheus repairs or truncates a torn WAL segment at
# startup, so the worst case is the last <2 h of samples, not the 14 d. The
# proper hooks -- `sqlite3 .backup` for Grafana, the TSDB snapshot API for
# Prometheus -- are the day either of those exposures stops being acceptable.
#
# ---------------------------------------------------------------------------
# WHAT IS DELIBERATELY NOT COPIED, and what deliberately IS
# ---------------------------------------------------------------------------
# Measured on the box with `du -sh /var/lib/ac-host/*` on 14 Sep 2026:
#
#   src           3.9G   the deployed tenant tree -- a checkout of ac-host at
#                        the sha in last-applied.json. git has it; hub-status.sh
#                        exists to prove the box's copy matches git file by file.
#   dist          3.4G   build output
#   build         634M   build scratch
#   pending-src   1.7M   the next tree, staged by queue-prod; git has it too
#   _local_wipe_backup 472K  a previous wipe's leftovers, already excluded from
#                        every rsync the deploy path does
#   ------------------
#   7.9G of the 12G, every byte of it either in git or rebuildable from it.
#
#   content       4.0G   INCLUDED, on purpose. 3.6G tracks + 429M cars, and it
#                        is NOT reproducible: some of it is mods whose upstream
#                        may be gone. restic stores it once (content-addressed
#                        chunks) and a nightly re-run of an unchanged 4G adds
#                        essentially nothing, so the recurring cost of keeping
#                        it is the read, not the space.
#
# So the excludes are not "big things" -- they are things whose LOSS costs
# nothing, because another copy is authoritative. That is the test to apply
# before adding one.
#
# ADR 0009 environment tenants (homelab-158.9, measured 18 Sep 2026 with
# `du -sb` on the box, the day agent-hub first ran from its environment).
# The pull unit (modules/tenant/environment-pull.nix) keeps a git checkout of
# the tenant tree at `environment.dir` -- for agent-hub, /var/lib/agent-hub/env,
# INSIDE the declared state dir -- and activates it as the tenant user, whose
# HOME is that same state dir. Of /var/lib/agent-hub's 516,958 bytes:
#
#   env/.git/*           154,052  the clone. Every byte is on GitHub. Grows
#                                 with every fetched sha. Only .git/HEAD (41
#                                 bytes, the detached sha) is kept, so the
#                                 mirror names the tree the box ran without
#                                 /var/lib/homelab's applied record, which
#                                 no tenant declares as state.
#   env/.flox/run            118  two symlinks into /nix/store, re-made by
#                                 every `flox activate`; dangling anywhere else
#   env/.flox/cache       16,417  upgrade-checks.json -- flox's own scratch
#   env/.flox/log         22,978  one file per activation and upgrade check
#   .cache/flox           27,212  flox's per-process scratch under $HOME
#   .cache/nix           124,131  eval/fetcher/tarball caches from the pull
#                                 unit's `nix` calls as the tenant user
#   .local/share/flox        295  flox's user data (metrics id, no state)
#   ------------------
#   345,203 of 516,958 (67%) today. Small -- the number matters less than the
#   shape: all of it is regrown by one run of the pull unit from the recorded
#   sha, and .git, .flox/log and the caches are the parts that GROW, so left
#   in they would become most of the tenant's snapshot for no recovery value.
#
#   env/ itself (manifest.toml, manifest.lock, llama-swap.yaml, the tree's
#   files: ~150 K) is KEPT: it is the exact tree the box ran, and a restore
#   wants to diff it against the sha the record names.
#
# These are not typed per tenant. excludes_for reads the contract's
# environments (the same set /etc/homelab/environments.json on the box lists)
# and derives them for every tenant whose environment.dir or whose user's
# HOME lies inside a backed-up state directory -- declaring a stub on a
# second tenant gets that tenant's checkout excluded the same way, measured
# here once for the shape rather than again for each instance.
#
# ---------------------------------------------------------------------------
# THE SECRET
# ---------------------------------------------------------------------------
# The restic repo password is `restic-repo-password` in secrets/ac-box.yaml,
# read through lib/sops-secret.sh with the operator's ssh key derived to an age
# identity in memory. It reaches restic in this process's ENVIRONMENT and
# nowhere else: not argv (`ps` shows argv to every user), not a file, not a log.
# Losing both this repo password and the ability to decrypt secrets/ac-box.yaml
# means the backups are unreadable -- which is why the password lives in the
# same git-tracked, two-recipient sops file as everything else rather than in a
# file on this disk that no other machine has.
#
# Usage:
#   sudo bash scripts/hub-backup.sh            # the nightly run
#   bash scripts/hub-backup.sh --list          # what the contract says to back
#                                              # up (no root, no network, no run)
# Environment: HUB_BACKUP_ROOT, HOMELAB_BOX_SSH, HOMELAB_OPERATOR_KEY,
#              HOMELAB_KNOWN_HOSTS, HUB_BACKUP_SKIP_CHECK=1.
# Exit: 0 backed up and verified, 1 a step failed, 2 misuse/preconditions.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_ROOT="${HUB_BACKUP_ROOT:-/home/nixos/backup}"
STAGE="$BACKUP_ROOT/ac-box"          # mirrors the box's absolute paths
REPO="$BACKUP_ROOT/restic"
STATUS="$BACKUP_ROOT/status"         # KEY=VALUE, one per line; hub-status.sh greps it
BOX_SSH="${HOMELAB_BOX_SSH:-root@192.168.1.50}"
# One key does both jobs: it is the operator's box key AND (via ssh-to-age) the
# sops identity. Named absolutely because this runs as root from a timer, where
# $HOME is /root and ~/.ssh/config does not exist.
KEY="${HOMELAB_OPERATOR_KEY:-/home/nixos/.ssh/id_ed25519_ac-host}"
KNOWN="${HOMELAB_KNOWN_HOSTS:-/home/nixos/.ssh/known_hosts}"
SSH_OPTS=(-i "$KEY" -o BatchMode=yes -o ConnectTimeout=10
          -o UserKnownHostsFile="$KNOWN" -o StrictHostKeyChecking=yes)

export NIX_CONFIG="experimental-features = nix-command flakes"
START=$(date +%s)

say()  { printf '%s\n' "$*"; }
step() { printf '\n== %s ==\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. WHAT TO BACK UP -- from the contract, not from here.
# ---------------------------------------------------------------------------
# Evaluated against THIS tree (the repo this script ships in), not against the
# box: the declaration is a fact about the configuration, and reading it here
# means a change to a tenant's `state` is picked up the moment it is committed,
# without waiting for a deploy. ~7s, the same eval the gate runs.
contract_eval() {
  # $1 attribute path under nixosConfigurations.ac-box.config (may be
  # empty: the whole config), $2 the --apply.
  # The unit runs this script as root, but the checkout belongs to the
  # operator, and Nix (libgit2) refuses a git repository "not owned by current
  # user" -- the 16 Sep run failed here before touching anything. Evaluation
  # needs no privilege, so it runs as the checkout's owner; the nix-daemon
  # serves any user. Everything after this point still needs root (owners).
  local owner; owner=$(stat -c %U "$ROOT")
  local -a as_owner=()
  if [ "$(id -u)" = 0 ] && [ "$owner" != root ]; then
    as_owner=(runuser -u "$owner" -- env "NIX_CONFIG=$NIX_CONFIG" "HOME=$(getent passwd "$owner" | cut -d: -f6)")
  fi
  "${as_owner[@]}" nix eval --raw "$ROOT#nixosConfigurations.ac-box.config${1:+.$1}" --apply "$2" 2>/dev/null
}

# One line per directory, "<tenant> <dir>". Emitted as raw text rather than
# JSON so no parser is needed: a state path is an absolute path with no spaces
# (the contract's dirSet is types.path), and if that ever stops being true the
# read below breaks loudly rather than quietly mis-splitting.
declared_dirs() {
  # shellcheck disable=SC2016  # the ${n} below is Nix syntax, not a shell expansion
  contract_eval homelab.tenants '
    ts:
      let
        wanted = builtins.filter (n: ts.${n}.state.backup) (builtins.attrNames ts);
        lines  = builtins.concatLists (map (n: map (d: n + " " + d) ts.${n}.state.dirs) wanted);
      in builtins.concatStringsSep "\n" lines
  '
}

# The environment tenants (ADR 0009), one line each: "<tenant> <dir> <home>".
# Read from the same JSON the closure installs as /etc/homelab/environments.json
# -- which tenants keep a checkout, where, and as which user -- so this script
# and hub-status.sh agree on what an environment IS without a second
# derivation of it here; the user's HOME is what flox's own caches hang off.
# Empty when no tenant declares a stub (the etc entry is not defined then,
# and this must not fail on a tree without environments).
environment_dirs() {
  # shellcheck disable=SC2016  # ${n} and ${u} are Nix syntax
  contract_eval '' '
    c:
      let
        etc  = c.environment.etc;
        envs = if etc ? "homelab/environments.json"
               then (builtins.fromJSON etc."homelab/environments.json".text).environments
               else { };
        home = u: toString (c.users.users.${u}.home or "");
      in builtins.concatStringsSep "\n"
           (map (n: n + " " + envs.${n}.dir + " " + home envs.${n}.user) (builtins.attrNames envs))
  '
}

# rsync excludes for one directory. Keyed on the path, with the measurement
# that justifies each one in the header above -- the list is short and every
# entry has a reason, which is the only thing that keeps it from growing into
# "whatever was big last time somebody looked". Anchored (leading /): the
# tenant tree's own src/, not any nested one.
excludes_for() {
  local dir="$1" tenant envdir home rel
  case "$dir" in
    /var/lib/ac-host)
      printf '%s\n' --exclude=/src --exclude=/dist --exclude=/build \
                    --exclude=/pending-src --exclude=/_local_wipe_backup
      ;;
  esac
  # Environment tenants, derived rather than listed (header: "ADR 0009").
  # A checkout inside $dir loses its .git (bar HEAD) and flox's run/cache/log; a tenant
  # HOME inside (or equal to) $dir loses flox's and nix's user caches. The
  # worktree files under <envdir> are kept. $ENVIRONMENTS is set by the
  # caller from environment_dirs; unset (a direct call) means no excludes.
  while read -r tenant envdir home; do
    [ -n "${envdir:-}" ] || continue
    case "$envdir" in
      "$dir"|"$dir"/*)
        rel="${envdir#"$dir"}"
        # .git/HEAD is kept, and it is the bare sha (the pull unit checks out
        # --detach): 41 bytes that let the mirror itself say which tree the
        # box ran, since the applied record lives in /var/lib/homelab, which
        # no tenant declares. Include before exclude: rsync takes the first
        # matching rule, and .git/* excludes every other child unexpanded.
        printf '%s\n' "--include=$rel/.git/HEAD" "--exclude=$rel/.git/*" \
                      "--exclude=$rel/.flox/run" "--exclude=$rel/.flox/cache" \
                      "--exclude=$rel/.flox/log"
        ;;
    esac
    case "${home:-}" in
      "$dir"|"$dir"/*)
        rel="${home#"$dir"}"
        printf '%s\n' "--exclude=$rel/.cache/flox" "--exclude=$rel/.cache/nix" \
                      "--exclude=$rel/.local/share/flox"
        ;;
    esac
  done <<< "${ENVIRONMENTS:-}"
}

write_status() {
  # $1 ok|failed  $2 detail. LAST_SUCCESS is carried forward from the previous
  # file on a failure: "when did this last WORK" is the question hub-status.sh
  # asks, and a failed run must not be able to answer it with today's date.
  local state="$1" detail="$2" prev_ts prev_epoch prev_snap prev_n tmp
  prev_ts=$(grep '^LAST_SUCCESS=' "$STATUS" 2>/dev/null | cut -d= -f2-)
  prev_epoch=$(grep '^LAST_SUCCESS_EPOCH=' "$STATUS" 2>/dev/null | cut -d= -f2-)
  prev_snap=$(grep '^SNAPSHOT=' "$STATUS" 2>/dev/null | cut -d= -f2-)
  prev_n=$(grep '^SNAPSHOTS=' "$STATUS" 2>/dev/null | cut -d= -f2-)
  if [ "$state" = ok ]; then
    prev_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ); prev_epoch=$(date +%s)
    prev_snap="$SNAPSHOT"; prev_n="$SNAPSHOTS"
  fi
  tmp="$STATUS.tmp"
  {
    echo "LAST_SUCCESS=${prev_ts:-}"
    echo "LAST_SUCCESS_EPOCH=${prev_epoch:-}"
    echo "SNAPSHOT=${prev_snap:-}"
    echo "SNAPSHOTS=${prev_n:-}"
    echo "LAST_ATTEMPT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "LAST_RESULT=$state${detail:+: $detail}"
    echo "SECONDS=$(( $(date +%s) - START ))"
    echo "ADDED=${ADDED:-}"
    echo "REPO_SIZE=${REPO_SIZE:-}"
    echo "DIRS=${DIRS_DONE:-}"
    echo "ABSENT=${DIRS_ABSENT:-}"
  } > "$tmp" && mv "$tmp" "$STATUS" && chmod 0644 "$STATUS"
  # Readable by the operator: hub-status.sh runs unprivileged and this file
  # holds no secret -- sizes, dates and a snapshot id.
}

die() { say "FAILED: $*"; write_status failed "$*"; exit 1; }

# --list answers "what does the contract say?" without root, ssh or restic --
# the question a reviewer of a tenant change actually has.
if [ "${1:-}" = "--list" ]; then
  d=$(declared_dirs) || die "nix eval failed"
  [ -n "$d" ] || { say "no tenant declares state.backup = true"; exit 1; }
  ENVIRONMENTS=$(environment_dirs) || die "nix eval of the environments failed"
  # "<tenant> <dir>" per line, as before; excludes on an indented line under
  # the directory they apply to, so `grep -v '^ '` still yields the bare list.
  while read -r tenant dir; do
    say "$tenant $dir"
    ex=$(excludes_for "$dir" | tr '\n' ' ')
    [ -z "$ex" ] || say "  excluding ${ex% }"
  done <<< "$d"
  exit 0
fi
[ $# -eq 0 ] || { say "usage: sudo bash $0 [--list]"; exit 2; }

[ "$(id -u)" = 0 ] || {
  say "must run as root: the box's state is owned by root, arcade, agent-hub and"
  say "root:monitoring, and only root can reproduce those owners locally."
  say "  sudo bash $0"
  exit 2
}
[ -r "$KEY" ] || { say "no operator key at $KEY (set HOMELAB_OPERATOR_KEY)"; exit 2; }
mkdir -p "$BACKUP_ROOT" || { say "cannot create $BACKUP_ROOT"; exit 2; }

step "contract: which directories declare state.backup = true"
DECLARED=$(declared_dirs) || die "nix eval failed"
[ -n "$DECLARED" ] || die "no tenant declares state.backup = true (did the eval return an empty set?)"
say "$DECLARED" | sed 's/^/  /'
ENVIRONMENTS=$(environment_dirs) || die "nix eval of the environments failed"
[ -z "$ENVIRONMENTS" ] || { say "environments (checkout kept, its .git and flox/nix caches excluded):"; say "$ENVIRONMENTS" | sed 's/^/  /'; }

step "restic repo password"
# shellcheck source=scripts/lib/sops-secret.sh
. "$ROOT/scripts/lib/sops-secret.sh"
export HOMELAB_SOPS_SSH_KEY="$KEY"
RESTIC_PASSWORD=$(hub_sops_secret restic-repo-password) \
  || die "could not read restic-repo-password from secrets/ac-box.yaml"
export RESTIC_PASSWORD
export RESTIC_REPOSITORY="$REPO"
# restic keeps an index cache under $XDG_CACHE_HOME or $HOME; a systemd
# service has neither (16 Sep, the first run under the timer stopped here).
# Beside the repo, so it lives with the thing it caches and is never in /root.
export RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-$BACKUP_ROOT/.restic-cache}"
say "read (sha256 $(printf '%s' "$RESTIC_PASSWORD" | sha256sum | cut -c1-8), never printed)"

step "tools"
# restic comes from nixpkgs on demand, like every other tool a hub script uses;
# nothing is installed and nothing here is part of ac-box's closure, so README's
# "nixpkgs is owned here" (the host channel, nixos-26.05) is not in play -- this
# resolves through the running user's flake registry, which for root is the
# unstable channel. The repo FORMAT is what has to stay readable, not this
# binary: any restic new enough opens a repo any other restic wrote.
RESTIC=$(nix build --no-link --print-out-paths nixpkgs#restic 2>/dev/null | tail -1)/bin/restic
[ -x "$RESTIC" ] || die "could not get restic from nixpkgs"
say "restic $("$RESTIC" version | awk '{print $2}'), rsync $(rsync --version | awk 'NR==1{print $3}')"

step "pull: rsync from $BOX_SSH (read-only on the far side)"
mkdir -p "$STAGE" || die "cannot create $STAGE"
DIRS_DONE=""; DIRS_ABSENT=""
while read -r tenant dir; do
  [ -n "${dir:-}" ] || continue
  case " $DIRS_DONE $DIRS_ABSENT " in
    *" $dir "*) say "  $dir: already pulled (declared by more than one tenant)"; continue ;;
  esac
  # stat, not test -d: one round trip answers "does it exist?" and hands back
  # the directory's OWN owner/group/mode, which the rsync below cannot carry.
  # shellcheck disable=SC2029  # $dir is meant to expand here, on the client
  # -n is load-bearing: without it ssh reads this loop's stdin -- the list of
  # declared directories -- and the loop silently ends after ONE of them.
  # Found 14 Sep 2026 by a run that backed up /var/lib/agent-hub and nothing
  # else, and reported success.
  attrs=$(ssh -n "${SSH_OPTS[@]}" "$BOX_SSH" "stat -c '%u %g %a' $dir" 2>/dev/null)
  if [ -z "$attrs" ]; then
    # A declared directory the box does not have. Not a failure of the backup:
    # the contract is a statement of intent, and /var/lib/qdrant was declared
    # by agent-hub before qdrant had ever written to it (14 Sep 2026). It IS
    # reported, here and in the status file, so "declared and never backed up"
    # cannot hide.
    say "  $dir ($tenant): DECLARED BUT ABSENT on the box - skipped"
    DIRS_ABSENT="$DIRS_ABSENT $dir"
    continue
  fi
  read -r duid dgid dmode <<< "$attrs"
  EX=(); while read -r x; do EX+=("$x"); done < <(excludes_for "$dir")
  say "  $dir ($tenant, $duid:$dgid $dmode)${EX[0]:+ excluding ${EX[*]}}"
  # Two things rsync will not do for us, both found by running it (14 Sep 2026):
  #   - it creates the last component of the destination, not missing PARENTS,
  #     and exits 11 ("mkdir ... No such file or directory") when they are gone;
  #   - `src/ -> dst/` says nothing about DST'S OWN attributes, so the leaf
  #     directory's owner and mode -- /var/lib/arcade is 0700 arcade:arcade,
  #     /var/lib/ac-host 0750 root:root -- would silently become root 0755 and
  #     a restore would hand a service a directory it cannot open.
  # So: create the path, sync into it, then stamp the leaf from the box's stat.
  mkdir -p "$STAGE$dir" || die "cannot create $STAGE$dir"
  # --delete so the staging tree is a mirror and a file deleted on the box
  # stops being re-uploaded forever; the HISTORY lives in restic's snapshots,
  # which is where deleted-file recovery comes from.
  if ! rsync -a --numeric-ids --delete --stats \
        -e "ssh ${SSH_OPTS[*]}" ${EX[@]+"${EX[@]}"} \
        "$BOX_SSH:$dir/" "$STAGE$dir/" > /tmp/hub-backup-rsync.$$ 2>&1; then
    tail -5 /tmp/hub-backup-rsync.$$ | sed 's/^/    /'
    rm -f /tmp/hub-backup-rsync.$$
    die "rsync of $dir failed"
  fi
  chown "$duid:$dgid" "$STAGE$dir" || die "cannot chown $STAGE$dir to $duid:$dgid"
  chmod "$dmode" "$STAGE$dir" || die "cannot chmod $STAGE$dir to $dmode"
  grep -E "^(Number of regular files transferred|Total transferred file size)" \
    /tmp/hub-backup-rsync.$$ | sed 's/^/    /'
  rm -f /tmp/hub-backup-rsync.$$
  DIRS_DONE="$DIRS_DONE $dir"
done <<< "$DECLARED"
DIRS_DONE="${DIRS_DONE# }"; DIRS_ABSENT="${DIRS_ABSENT# }"
[ -n "$DIRS_DONE" ] || die "nothing was pulled; every declared directory was absent"
say "staged: $(du -sh "$STAGE" | cut -f1) in $STAGE"

step "restic: snapshot the staging tree into $REPO"
if [ ! -f "$REPO/config" ]; then
  say "  initialising a new repo"
  "$RESTIC" init || die "restic init failed"
fi
"$RESTIC" backup "$STAGE" --tag ac-box --tag hub-backup --host ac-box > /tmp/hub-backup-restic.$$ 2>&1 \
  || { tail -10 /tmp/hub-backup-restic.$$ | sed 's/^/    /'; rm -f /tmp/hub-backup-restic.$$; die "restic backup failed"; }
grep -E "^(Added to the repo|processed|Files:|Dirs:)" /tmp/hub-backup-restic.$$ | sed 's/^/  /'
SNAPSHOT=$(grep -oE "snapshot [0-9a-f]{8} saved" /tmp/hub-backup-restic.$$ | tail -1 | cut -d' ' -f2)
ADDED=$(grep -oE "Added to the repo[^:]*: [0-9.]+ [KMGT]?i?B" /tmp/hub-backup-restic.$$ | tail -1 | sed 's/.*: //')
rm -f /tmp/hub-backup-restic.$$
[ -n "$SNAPSHOT" ] || die "restic backup produced no snapshot id"
say "  snapshot $SNAPSHOT"

step "restic: forget + prune (7 daily, 4 weekly, 6 monthly)"
# The retention the operator chose: a week of dailies covers "I deleted it
# yesterday", the weeklies and monthlies cover "it has been wrong for a while
# and nobody noticed". --prune is in the same call so space is actually
# reclaimed rather than merely unreferenced.
"$RESTIC" forget --prune --keep-daily 7 --keep-weekly 4 --keep-monthly 6 \
  --tag hub-backup > /tmp/hub-backup-forget.$$ 2>&1 \
  || { tail -10 /tmp/hub-backup-forget.$$ | sed 's/^/    /'; rm -f /tmp/hub-backup-forget.$$; die "restic forget/prune failed"; }
grep -E "keep [0-9]+ snapshots|remove [0-9]+ snapshots|^Applying" /tmp/hub-backup-forget.$$ | sed 's/^/  /'
rm -f /tmp/hub-backup-forget.$$

if [ "${HUB_BACKUP_SKIP_CHECK:-0}" != 1 ]; then
  step "restic: check, with 5% of the data actually re-read"
  # Structure alone (`restic check`) proves the index agrees with itself. It
  # does NOT prove the packs can still be decrypted and hash to what the index
  # claims -- silent disk rot does not break the index. 5% per night reads the
  # whole repo over a few weeks for a few seconds a night.
  "$RESTIC" check --read-data-subset=5% > /tmp/hub-backup-check.$$ 2>&1 \
    || { tail -10 /tmp/hub-backup-check.$$ | sed 's/^/    /'; rm -f /tmp/hub-backup-check.$$; die "restic check failed - THE REPO IS SUSPECT"; }
  tail -2 /tmp/hub-backup-check.$$ | sed 's/^/  /'
  rm -f /tmp/hub-backup-check.$$
fi

SNAPSHOTS=$("$RESTIC" snapshots --json 2>/dev/null | grep -o '"short_id"' | wc -l)
REPO_SIZE=$("$RESTIC" stats --mode raw-data 2>/dev/null | awk -F': *' '/Total Size/{print $2}')
write_status ok ""
step "done in $(( $(date +%s) - START ))s"
say "snapshot $SNAPSHOT, $SNAPSHOTS snapshot(s), repo $REPO_SIZE, status in $STATUS"
say "restore: docs/runbook-restore.md"
