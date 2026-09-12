#!/usr/bin/env bash
# Stage the system-closure revision this pipeline has just proven green, so
# the box applies it in the maintenance window. The staging half of ADR 0006.
#
# Writes exactly one file, /var/lib/homelab/pending-closure.json, and bounces
# nothing -- which is what makes it safe to run as a Buildkite step on an
# agent that is itself a unit of the closure being deployed (modules/ci,
# HAZARD 2). The applying half is modules/deploy's systemd unit, on the box,
# and it is the ONLY thing that may call nixos-rebuild. This script must never.
#
# Mirrors ac-host's scripts/ci_queue_prod.py one layer up: same shape, same
# "skip rather than fail when not on the box" posture, same last-wins
# semantics. A later green build overwrites an earlier one; the deploy unit
# applies whatever is staged when the timer fires.
#
# Deliberately does NOT pre-build the closure here. Building is the applying
# half's job, against the box's own store -- a build failure should surface
# there, not pass a green CI badge to a machine that cannot realise it.
set -euo pipefail

STATE="${HOMELAB_DEPLOY_STATE:-/var/lib/homelab}"
PENDING="$STATE/pending-closure.json"
FLAKE="${HOMELAB_DEPLOY_FLAKE:-github:imkarrer/homelab}"

# Only main is ever staged. A green build on any other branch is a green
# build, not a deploy candidate -- the deploy unit switches to whatever rev
# is in this file without asking which branch it came from.
BRANCH="${BUILDKITE_BRANCH:-}"
if [ "$BRANCH" != "main" ]; then
  echo "skip queue-closure: branch is '${BRANCH:-unset}', only main is staged"
  exit 0
fi

REV="${BUILDKITE_COMMIT:-}"
if ! [[ "$REV" =~ ^[0-9a-f]{40}$ ]]; then
  # A short or missing sha is refused, not guessed. The deploy unit switches
  # to github:imkarrer/homelab/<rev>, and a bare `github:` ref is cached for
  # tarball-ttl (3600s on ac-box) -- staging anything but a full sha would
  # reintroduce the exact cache-stale no-op switch seen on 12 Sep 2026.
  echo "refuse queue-closure: BUILDKITE_COMMIT is not a full 40-hex sha ('${REV}')" >&2
  exit 1
fi

# Not on the box (or the agent lacks the mount): skip, do not fail. The
# agent gained this mount in ac-host 2c5e9a0, but the running container only
# picks it up when recreated, and the same pipeline also runs on developer
# machines. A green homelab build must stay green either way; the message is
# the signal that staging did not happen.
if [ ! -d "$STATE" ] || [ ! -w "$STATE" ]; then
  echo "skip queue-closure: $STATE is not a writable directory here"
  echo "  (agent not on ac-box, or ac-host-ci has not been recreated with the mount)"
  exit 0
fi

# Atomic: write beside, then rename, so the deploy unit never reads a
# half-written file if the timer fires mid-write.
TMP="$PENDING.tmp.$$"
printf '{"rev":"%s","flake":"%s","queued_at":"%s","build":"%s","branch":"%s","source":"buildkite"}\n' \
  "$REV" "$FLAKE" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${BUILDKITE_BUILD_URL:-}" "$BRANCH" \
  > "$TMP"
mv -f "$TMP" "$PENDING"

echo "queued closure ${REV:0:7} -> $PENDING"
echo "applies at the next maintenance window via homelab-deploy.timer (if homelab.deploy.enable is on)"
