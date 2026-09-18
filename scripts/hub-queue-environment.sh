#!/usr/bin/env bash
# Stage a tenant tree's revision as that tenant's flox ENVIRONMENT on the
# box: the staging half of ADR 0009's deploy edge, one layer down from
# hub-queue-closure.sh (ADR 0006). Usage:
#
#   hub-queue-environment.sh <tenant> <sha>
#
# Writes exactly one file, <state>/pending-environment-<tenant>.json, and
# bounces nothing. The applying half is modules/tenant/environment-pull.nix's
# <tenant>-environment-pull.service on the box, which checks the sha out
# into homelab.tenants.<tenant>.environment.dir, activates it once online
# and restarts the tenant's stub under its quiet policy. This script must
# never touch the checkout, run flox, or restart anything: it runs on the
# CI agent, which is a unit of the box (modules/ci HAZARD 2), and the whole
# reason the edge is split is that the agent only ever writes a file.
#
# WHO CALLS IT. The tenant's own pipeline proves the sha green, then
# `trigger: homelab` with HOMELAB_STAGE_ENVIRONMENT=<tenant> and
# HOMELAB_STAGE_REV=<sha> -- the same edge bump-lock uses, carrying a
# different payload. The trigger build runs in homelab's checkout, so the
# tenant tree needs no copy of this script and no pinned homelab sha to
# curl it from; whatever is on homelab main stages it. .buildkite/
# pipeline.yml routes the trigger to this script and nothing else.
#
# Same posture as queue-closure: only main is staged, a short sha is
# refused, and "not on the box" is a skip with a message rather than a
# failure. Last-wins: a later green build overwrites an earlier one.
set -euo pipefail

HUB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REG="${HUB_REGISTRY:-$HUB/hub/repos.psv}"
STATE="${HOMELAB_DEPLOY_STATE:-/var/lib/homelab}"

TENANT="${1:-}"
REV="${2:-}"
# The registry name of the tenant's tree. The same as the tenant for
# agent-hub; a tenant whose tree is named differently (arcade: home-arcade)
# passes it explicitly. Must agree with homelab.tenants.<tenant>
# .environment.tree, because the pull unit refuses a record whose tree is
# not the one the closure was built against.
TREE="${HOMELAB_STAGE_TREE:-$TENANT}"
# In a trigger build BUILDKITE_BRANCH/BUILD_URL describe the homelab build,
# not the tenant's, so the tenant passes its own through; a direct run on
# the tenant's agent falls back to Buildkite's.
BRANCH="${HOMELAB_STAGE_BRANCH:-${BUILDKITE_BRANCH:-}}"
BUILD="${HOMELAB_STAGE_BUILD:-${BUILDKITE_BUILD_URL:-}}"

if [ -z "$TENANT" ] || [ -z "$REV" ]; then
  echo "usage: hub-queue-environment.sh <tenant> <sha>" >&2
  exit 2
fi

# The tenant name becomes a file name under $STATE, so it is validated
# before any path is formed: README's tenant names are lower-case words
# with hyphens, and anything else ('../x' from a trigger's env, say) is
# refused rather than written somewhere.
if ! [[ "$TENANT" =~ ^[a-z][a-z0-9-]*$ ]]; then
  echo "refuse queue-environment: '$TENANT' is not a tenant name (lower-case, digits, hyphens)" >&2
  exit 1
fi

# The tenant's tree must be one this hub coordinates. The remote recorded
# here is what the pull unit compares against the registry it was built
# with -- a sha of the wrong tree is refused there, loudly, rather than
# checked out.
REMOTE=$(awk -F'|' -v r="$TREE" '$1==r{print $3}' "$REG")
if [ -z "$REMOTE" ]; then
  echo "refuse queue-environment: tree '$TREE' is not in $REG (or has no remote)" >&2
  exit 1
fi

# Only main is ever staged. The pull unit checks out whatever sha is in
# this file without asking which branch it came from.
if [ "$BRANCH" != "main" ]; then
  echo "skip queue-environment: branch is '${BRANCH:-unset}', only main is staged"
  exit 0
fi

if ! [[ "$REV" =~ ^[0-9a-f]{40}$ ]]; then
  # A short sha is refused, not resolved: the pull unit fetches exactly
  # this object, and a prefix would be resolved against whatever the box's
  # checkout happens to have fetched.
  echo "refuse queue-environment: '$REV' is not a full 40-hex sha" >&2
  exit 1
fi

# Not on the box (or the agent lacks the mount): skip, do not fail. The
# agent has the mount as of ac-host 2c5e9a0; the same script runs from a
# developer's checkout too, where the message is the whole point.
if [ ! -d "$STATE" ] || [ ! -w "$STATE" ]; then
  echo "skip queue-environment: $STATE is not a writable directory here"
  echo "  (agent not on ac-box, or ac-host-ci has not been recreated with the mount)"
  exit 0
fi

PENDING="$STATE/pending-environment-$TENANT.json"

# Atomic: write beside, then rename, so the path unit fires once on the
# rename and never reads a half-written file.
TMP="$PENDING.tmp.$$"
printf '{"tenant":"%s","sha":"%s","tree":"%s","queued_at":"%s","build":"%s","branch":"%s","source":"buildkite"}\n' \
  "$TENANT" "$REV" "$REMOTE" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BUILD" "$BRANCH" \
  > "$TMP"
mv -f "$TMP" "$PENDING"

echo "queued environment $TENANT ${REV:0:7} ($TREE) -> $PENDING"
echo "$TENANT-environment-pull.service checks it out, warms it and restarts the stub within minutes (if the closure carries the pull unit)"
