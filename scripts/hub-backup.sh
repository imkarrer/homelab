#!/usr/bin/env bash
# Row 22: back every host's DECLARED state up, onto this machine, every night.
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
# TWO HOSTS (26 Sep 2026, homelab-ygc.4)
# ---------------------------------------------------------------------------
# flake.nix declares ac-box and arcade-box, and after the cutover
# (docs/runbook-arcade-box-cutover.md, phase 4) every tenant but agent-hub
# lives on arcade-box. Everything above is therefore PER HOST, and the host
# list is never typed here (scripts/lib/hosts.sh reads the flake's
# nixosConfigurations; HOMELAB_BOX narrows to one host, HOMELAB_HOSTS lists):
#
#   which directories   that host's own config -- `homelab.tenants.<n>.state`
#                       where backup = true AND the tenant is enabled THERE.
#                       assetto is declared on both hosts and enabled on one,
#                       so its /var/lib/ac-host is pulled from the host that
#                       runs the lobbies and from nowhere else; the flip in
#                       hosts/*/configuration.nix at the cutover moves the
#                       backup with it, and this file does not change.
#   from where          root@<that host's homelab.host.networks.lan.address>,
#                       from the same eval. Not the ssh alias: this runs as
#                       root from a timer, where ~/.ssh/config does not exist
#                       (the key and known_hosts are named absolutely below for
#                       the same reason). The address in git follows the
#                       machines through the cutover (D2), so the pull does too.
#   to where            /home/nixos/backup/<host>/<the host's absolute path>.
#                       ac-box's tree is exactly where it has been since 14 Sep
#                       2026 -- docs/runbook-restore.md and every restic
#                       snapshot name that layout -- and arcade-box's is a
#                       sibling, so /var/lib/arcade from each host is a
#                       different directory here, as it should be.
#   restic              one snapshot per host, `--host <host> --tag <host>`,
#                       which is byte-for-byte the call ac-box always got and
#                       gives each host its own forget group (restic groups by
#                       host and paths), so ac-box's history runs on unbroken
#                       and arcade-box's ages out on its own 7/4/6.
#   failure             a host that is down or whose pull breaks fails ITS
#                       snapshot and the run's verdict (LAST_RESULT names it),
#                       but not the other host's snapshot -- arcade-box being
#                       off for a night must not cost ac-box's copy. The
#                       status file carries a RESULT_<host> line per host.
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
# READ-ONLY -- rsync's sender never writes. Nothing here can damage a host.
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
# here once for the shape rather than again for each instance. Per host,
# like the directories: a stub declared on one host excludes nothing on the
# other.
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
#   sudo bash scripts/hub-backup.sh            # the nightly run, every host
#   bash scripts/hub-backup.sh --list          # what the contract says to back
#                                              # up, "<host> <tenant> <dir>"
#                                              # (no root, no network, no run)
# Environment: HOMELAB_BOX (one host), HOMELAB_HOSTS (a list; lib/hosts.sh),
#              HUB_BACKUP_ROOT, HOMELAB_BOX_SSH (the target for the ONE host
#              HOMELAB_BOX names -- refused for a list), HOMELAB_OPERATOR_KEY,
#              HOMELAB_KNOWN_HOSTS, HUB_BACKUP_SKIP_CHECK=1.
# Exit: 0 every host backed up and verified, 1 a step or a host failed,
#       2 misuse/preconditions.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_ROOT="${HUB_BACKUP_ROOT:-/home/nixos/backup}"
# The staging tree is $BACKUP_ROOT/<host>, mirroring that host's absolute
# paths (header: "TWO HOSTS"); stage_of names it in one place.
REPO="$BACKUP_ROOT/restic"
STATUS="$BACKUP_ROOT/status"         # KEY=VALUE, one per line; hub-status.sh greps it
# One key does both jobs: it is the operator's box key AND (via ssh-to-age) the
# sops identity. Named absolutely because this runs as root from a timer, where
# $HOME is /root and ~/.ssh/config does not exist.
KEY="${HOMELAB_OPERATOR_KEY:-/home/nixos/.ssh/id_ed25519_ac-host}"
KNOWN="${HOMELAB_KNOWN_HOSTS:-/home/nixos/.ssh/known_hosts}"
SSH_OPTS=(-i "$KEY" -o BatchMode=yes -o ConnectTimeout=10
          -o UserKnownHostsFile="$KNOWN" -o StrictHostKeyChecking=yes)

# shellcheck source=scripts/lib/hosts.sh
. "$ROOT/scripts/lib/hosts.sh"

export NIX_CONFIG="experimental-features = nix-command flakes"
START=$(date +%s)

say()  { printf '%s\n' "$*"; }
step() { printf '\n== %s ==\n' "$*"; }
stage_of() { printf '%s/%s' "$BACKUP_ROOT" "$1"; }

# ---------------------------------------------------------------------------
# 1. WHAT TO BACK UP -- from the contract, not from here.
# ---------------------------------------------------------------------------
# Evaluated against THIS tree (the repo this script ships in), not against the
# box: the declaration is a fact about the configuration, and reading it here
# means a change to a tenant's `state` is picked up the moment it is committed,
# without waiting for a deploy. One evaluation covers every host (~7s for two,
# the same eval the gate runs); lib/hosts.sh runs it as the checkout's owner
# when this is root, because Nix refuses a repository another user owns.
#
# One line per fact, tagged by its first word so no parser is needed:
#   ssh <host> root@<lan address>       where to pull from
#   dir <host> <tenant> <dir>           a directory to back up, tenant enabled
#                                       on that host and state.backup = true
#   env <host> <tenant> <dir> <home>    an environment tenant (ADR 0009): its
#                                       checkout and its user's HOME, read from
#                                       the same JSON the closure installs as
#                                       /etc/homelab/environments.json so this
#                                       script and hub-status.sh agree on what
#                                       an environment IS; empty on a host
#                                       without a stub (the etc entry is not
#                                       defined then, and this must not fail)
# Raw text rather than JSON because a state path is an absolute path with no
# spaces (the contract's dirSet is types.path), and if that ever stops being
# true the reads below break loudly rather than quietly mis-splitting.
contract_lines() {
  local h nixhosts=""
  for h in $HOSTS; do nixhosts="$nixhosts \"$h\""; done
  # shellcheck disable=SC2016  # ${h}, ${n} and ${u} are Nix syntax, not shell expansions
  hub_nix_eval "$ROOT" --raw "$ROOT#nixosConfigurations" --apply '
    cs:
      let
        hosts = [ '"$nixhosts"' ];
        forHost = h:
          let
            c      = cs.${h}.config;
            ts     = c.homelab.tenants;
            wanted = builtins.filter (n: ts.${n}.enable && ts.${n}.state.backup) (builtins.attrNames ts);
            dirs   = builtins.concatLists
                       (map (n: map (d: "dir " + h + " " + n + " " + toString d) ts.${n}.state.dirs) wanted);
            etc    = c.environment.etc;
            envs   = if etc ? "homelab/environments.json"
                     then (builtins.fromJSON etc."homelab/environments.json".text).environments
                     else { };
            home   = u: toString (c.users.users.${u}.home or "");
            envl   = map (n: "env " + h + " " + n + " " + envs.${n}.dir + " " + home envs.${n}.user)
                         (builtins.attrNames envs);
          in [ ("ssh " + h + " root@" + c.homelab.host.networks.lan.address) ] ++ dirs ++ envl;
      in builtins.concatStringsSep "\n" (builtins.concatLists (map forHost hosts))
  '
}
# Readers of $CONTRACT, per host. host_dirs: "<tenant> <dir>" per line, in the
# order the contract's attribute names sort -- the order the pull runs in.
host_ssh()  { awk -v h="$1" '$1=="ssh" && $2==h {print $3; exit}' <<< "$CONTRACT"; }
host_dirs() { awk -v h="$1" '$1=="dir" && $2==h {print $3, $4}' <<< "$CONTRACT"; }
host_envs() { awk -v h="$1" '$1=="env" && $2==h {print $3, $4, $5}' <<< "$CONTRACT"; }

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
  # caller from host_envs for the host being pulled; unset (a direct call)
  # means no excludes.
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

# Per-host outcome of this run, filled by pull_host and snapshot_host and
# written out by write_status. A host with a HOST_FAIL entry failed.
declare -A HOST_FAIL HOST_SNAP HOST_ADDED HOST_DIRS HOST_ABSENT

write_status() {
  # $1 ok|failed  $2 detail. LAST_SUCCESS is carried forward from the previous
  # file on a failure: "when did this last WORK" is the question hub-status.sh
  # asks, and a failed run must not be able to answer it with today's date.
  # "Work" means every host: a night that snapshotted ac-box and lost
  # arcade-box is a failure here and an ok on its RESULT_ac-box line.
  local state="$1" detail="$2" prev_ts prev_epoch prev_snap prev_n tmp h snaps="" added=""
  prev_ts=$(grep '^LAST_SUCCESS=' "$STATUS" 2>/dev/null | cut -d= -f2-)
  prev_epoch=$(grep '^LAST_SUCCESS_EPOCH=' "$STATUS" 2>/dev/null | cut -d= -f2-)
  prev_snap=$(grep '^SNAPSHOT=' "$STATUS" 2>/dev/null | cut -d= -f2-)
  prev_n=$(grep '^SNAPSHOTS=' "$STATUS" 2>/dev/null | cut -d= -f2-)
  for h in $HOSTS; do
    [ -z "${HOST_SNAP[$h]:-}" ] || snaps="$snaps ${HOST_SNAP[$h]}"
    [ -z "${HOST_ADDED[$h]:-}" ] || added="$added + ${HOST_ADDED[$h]}"
  done
  if [ "$state" = ok ]; then
    prev_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ); prev_epoch=$(date +%s)
    prev_snap="${snaps# }"; prev_n="$SNAPSHOTS"
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
    echo "ADDED=${added# + }"
    echo "REPO_SIZE=${REPO_SIZE:-}"
    # Per host, since 26 Sep 2026: what was pulled, what was declared but not
    # there, which snapshot it became, and whether the host succeeded. The
    # keys above keep their meaning for hub-status.sh (LAST_SUCCESS,
    # SNAPSHOTS, REPO_SIZE, LAST_RESULT); DIRS= and ABSENT= moved down here
    # because /var/lib/arcade on two hosts is two directories, not one.
    echo "HOSTS=$HOSTS"
    for h in $HOSTS; do
      echo "RESULT_$h=${HOST_FAIL[$h]:+failed: }${HOST_FAIL[$h]:-ok}"
      echo "SNAPSHOT_$h=${HOST_SNAP[$h]:-}"
      echo "ADDED_$h=${HOST_ADDED[$h]:-}"
      echo "DIRS_$h=${HOST_DIRS[$h]:-}"
      echo "ABSENT_$h=${HOST_ABSENT[$h]:-}"
    done
  } > "$tmp" && mv "$tmp" "$STATUS" && chmod 0644 "$STATUS"
  # Readable by the operator: hub-status.sh runs unprivileged and this file
  # holds no secret -- sizes, dates and a snapshot id.
}

# A run-wide failure. The status file is written only once the run has
# started (RUNNING): --list and the preconditions have nothing to record and
# no right to touch it (they may not even be root).
RUNNING=0
die() { say "FAILED: $*"; [ "$RUNNING" = 1 ] && write_status failed "$*"; exit 1; }

HOSTS=$(hub_hosts "$ROOT") || {
  say "cannot discover the hosts: nix eval of $ROOT#nixosConfigurations failed"
  say "(scripts/hub-gates.sh homelab says why; HOMELAB_HOSTS=\"ac-box arcade-box\" names them by hand)"
  exit 2
}

# --list answers "what does the contract say?" without root, ssh or restic --
# the question a reviewer of a tenant change actually has.
if [ "${1:-}" = "--list" ]; then
  CONTRACT=$(contract_lines 2>/dev/null) || { say "FAILED: nix eval failed for hosts: $HOSTS"; exit 2; }
  [ -n "$(awk '$1=="dir"' <<< "$CONTRACT")" ] || { say "no enabled tenant on any host ($HOSTS) declares state.backup = true"; exit 1; }
  # "<host> <tenant> <dir>" per line; excludes on an indented line under the
  # directory they apply to, so `grep -v '^ '` still yields the bare list.
  for h in $HOSTS; do
    ENVIRONMENTS=$(host_envs "$h")
    while read -r tenant dir; do
      [ -n "${dir:-}" ] || continue
      say "$h $tenant $dir"
      ex=$(excludes_for "$dir" | tr '\n' ' ')
      [ -z "$ex" ] || say "  excluding ${ex% }"
    done <<< "$(host_dirs "$h")"
  done
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
# One override, one host: a single target pulled twice and staged under two
# names would be two copies of one machine labelled as two machines.
if [ -n "${HOMELAB_BOX_SSH:-}" ] && [ "$(wc -w <<< "$HOSTS")" != 1 ]; then
  say "HOMELAB_BOX_SSH names one ssh target but the run has hosts: $HOSTS -- pair it with HOMELAB_BOX=<host>"
  exit 2
fi
mkdir -p "$BACKUP_ROOT" || { say "cannot create $BACKUP_ROOT"; exit 2; }
RUNNING=1

step "contract: which directories declare state.backup = true, per host ($HOSTS)"
CONTRACT=$(contract_lines 2>/tmp/hub-backup-eval.$$) || {
  tail -5 /tmp/hub-backup-eval.$$ | sed 's/^/  /'; rm -f /tmp/hub-backup-eval.$$
  die "nix eval of the contract failed for hosts: $HOSTS (is each a nixosConfigurations attribute of $ROOT?)"
}
rm -f /tmp/hub-backup-eval.$$
for h in $HOSTS; do
  say "$h (${HOMELAB_BOX_SSH:-$(host_ssh "$h")}):"
  d=$(host_dirs "$h")
  if [ -n "$d" ]; then say "$d" | sed 's/^/  /'; else say "  (no enabled tenant declares state.backup = true here)"; fi
  e=$(host_envs "$h")
  [ -z "$e" ] || { say "  environments (checkout kept, its .git and flox/nix caches excluded):"; say "$e" | sed 's/^/    /'; }
done
[ -n "$(awk '$1=="dir"' <<< "$CONTRACT")" ] || die "no enabled tenant on any host declares state.backup = true (did the eval return an empty set?)"

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

# Pull one host's declared directories into its staging tree. Returns 1 with
# the reason in HOST_FAIL[host]; the caller goes on to the next host.
pull_host() {
  local host="$1" stage target tenant dir attrs duid dgid dmode done="" absent=""
  stage=$(stage_of "$host")
  target="${HOMELAB_BOX_SSH:-$(host_ssh "$host")}"
  step "pull $host: rsync from $target (read-only on the far side)"
  # One round trip before the loop, so a host that is off tonight says so
  # instead of reporting every directory as DECLARED BUT ABSENT.
  if ! ssh -n "${SSH_OPTS[@]}" "$target" true 2>/dev/null; then
    HOST_FAIL[$host]="unreachable at $target"; return 1
  fi
  mkdir -p "$stage" || { HOST_FAIL[$host]="cannot create $stage"; return 1; }
  ENVIRONMENTS=$(host_envs "$host")
  while read -r tenant dir; do
    [ -n "${dir:-}" ] || continue
    case " $done $absent " in
      *" $dir "*) say "  $dir: already pulled (declared by more than one tenant)"; continue ;;
    esac
    # stat, not test -d: one round trip answers "does it exist?" and hands back
    # the directory's OWN owner/group/mode, which the rsync below cannot carry.
    # shellcheck disable=SC2029  # $dir is meant to expand here, on the client
    # -n is load-bearing: without it ssh reads this loop's stdin -- the list of
    # declared directories -- and the loop silently ends after ONE of them.
    # Found 14 Sep 2026 by a run that backed up /var/lib/agent-hub and nothing
    # else, and reported success.
    attrs=$(ssh -n "${SSH_OPTS[@]}" "$target" "stat -c '%u %g %a' $dir" 2>/dev/null)
    if [ -z "$attrs" ]; then
      # A declared directory the box does not have. Not a failure of the backup:
      # the contract is a statement of intent, and /var/lib/qdrant was declared
      # by agent-hub before qdrant had ever written to it (14 Sep 2026). It IS
      # reported, here and in the status file, so "declared and never backed up"
      # cannot hide.
      say "  $dir ($tenant): DECLARED BUT ABSENT on $host - skipped"
      absent="$absent $dir"
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
    mkdir -p "$stage$dir" || { HOST_FAIL[$host]="cannot create $stage$dir"; return 1; }
    # --delete so the staging tree is a mirror and a file deleted on the box
    # stops being re-uploaded forever; the HISTORY lives in restic's snapshots,
    # which is where deleted-file recovery comes from.
    if ! rsync -a --numeric-ids --delete --stats \
          -e "ssh ${SSH_OPTS[*]}" ${EX[@]+"${EX[@]}"} \
          "$target:$dir/" "$stage$dir/" > /tmp/hub-backup-rsync.$$ 2>&1; then
      tail -5 /tmp/hub-backup-rsync.$$ | sed 's/^/    /'
      rm -f /tmp/hub-backup-rsync.$$
      HOST_FAIL[$host]="rsync of $dir failed"; return 1
    fi
    chown "$duid:$dgid" "$stage$dir" || { HOST_FAIL[$host]="cannot chown $stage$dir to $duid:$dgid"; return 1; }
    chmod "$dmode" "$stage$dir" || { HOST_FAIL[$host]="cannot chmod $stage$dir to $dmode"; return 1; }
    grep -E "^(Number of regular files transferred|Total transferred file size)" \
      /tmp/hub-backup-rsync.$$ | sed 's/^/    /'
    rm -f /tmp/hub-backup-rsync.$$
    done="$done $dir"
  done <<< "$(host_dirs "$host")"
  HOST_DIRS[$host]="${done# }"; HOST_ABSENT[$host]="${absent# }"
  [ -n "${done# }" ] || { HOST_FAIL[$host]="nothing was pulled; every declared directory was absent"; return 1; }
  say "staged: $(du -sh "$stage" | cut -f1) in $stage"
}

# Snapshot one host's staging tree: its own restic host and tag, so its
# history is its own forget group (header: "TWO HOSTS").
snapshot_host() {
  local host="$1" stage out="/tmp/hub-backup-restic.$$" snap
  stage=$(stage_of "$host")
  step "restic $host: snapshot $stage into $REPO"
  "$RESTIC" backup "$stage" --tag "$host" --tag hub-backup --host "$host" > "$out" 2>&1 \
    || { tail -10 "$out" | sed 's/^/    /'; rm -f "$out"; HOST_FAIL[$host]="restic backup failed"; return 1; }
  grep -E "^(Added to the repo|processed|Files:|Dirs:)" "$out" | sed 's/^/  /'
  snap=$(grep -oE "snapshot [0-9a-f]{8} saved" "$out" | tail -1 | cut -d' ' -f2)
  HOST_ADDED[$host]=$(grep -oE "Added to the repo[^:]*: [0-9.]+ [KMGT]?i?B" "$out" | tail -1 | sed 's/.*: //')
  rm -f "$out"
  [ -n "$snap" ] || { HOST_FAIL[$host]="restic backup produced no snapshot id"; return 1; }
  HOST_SNAP[$host]="$snap"
  say "  snapshot $snap"
}

if [ ! -f "$REPO/config" ]; then
  step "restic: initialising a new repo at $REPO"
  "$RESTIC" init || die "restic init failed"
fi

for h in $HOSTS; do
  if ! { pull_host "$h" && snapshot_host "$h"; }; then
    say "  $h FAILED: ${HOST_FAIL[$h]}"
  fi
done
ANY_SNAPSHOT=0
for h in $HOSTS; do [ -z "${HOST_SNAP[$h]:-}" ] || ANY_SNAPSHOT=1; done
FAILED=""
for h in $HOSTS; do [ -z "${HOST_FAIL[$h]:-}" ] || FAILED="$FAILED; $h: ${HOST_FAIL[$h]}"; done
FAILED="${FAILED#; }"
[ "$ANY_SNAPSHOT" = 1 ] || die "no host was backed up: $FAILED"

step "restic: forget + prune (7 daily, 4 weekly, 6 monthly, per host)"
# The retention the operator chose: a week of dailies covers "I deleted it
# yesterday", the weeklies and monthlies cover "it has been wrong for a while
# and nobody noticed". --prune is in the same call so space is actually
# reclaimed rather than merely unreferenced. restic applies the policy per
# (host, paths) group, so each host keeps its own 7/4/6.
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
if [ -n "$FAILED" ]; then
  write_status failed "$FAILED"
  step "done in $(( $(date +%s) - START ))s, WITH A FAILED HOST"
  say "FAILED: $FAILED"
  say "$SNAPSHOTS snapshot(s), repo $REPO_SIZE, status in $STATUS"
  exit 1
fi
write_status ok ""
step "done in $(( $(date +%s) - START ))s"
for h in $HOSTS; do say "$h: snapshot ${HOST_SNAP[$h]} (${HOST_ADDED[$h]:-?} added)"; done
say "$SNAPSHOTS snapshot(s), repo $REPO_SIZE, status in $STATUS"
say "restore: docs/runbook-restore.md"
