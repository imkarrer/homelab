#!/usr/bin/env bash
# Stage what a flox tenant runs as that tenant's ENVIRONMENT on the box:
# the staging half of ADR 0009's deploy edge, one layer down from
# hub-queue-closure.sh (ADR 0006). Usage:
#
#   hub-queue-environment.sh <tenant> <sha>                     (source.kind = tree)
#   HOMELAB_STAGE_GENERATION=<n> HOMELAB_STAGE_ENV=<owner/name> \
#   hub-queue-environment.sh <tenant> <sha>                     (source.kind = floxhub)
#
# Writes exactly one file, <state>/pending-environment-<tenant>.json, and
# bounces nothing. The applying half is modules/tenant/environment-pull.nix's
# <tenant>-environment-pull.service on the box, which checks the sha out
# (tree) or pulls the generation (floxhub) into homelab.tenants.<tenant>
# .environment.dir, warms it once online and restarts the tenant's stub
# under its quiet policy. This script must never touch the checkout, run
# flox, or restart anything: it runs on the CI agent, which is a unit of
# the box (modules/ci HAZARD 2), and the whole reason the edge is split is
# that the agent only ever writes a file.
#
# WHO CALLS IT. The tenant's own pipeline proves the sha green, then
# `trigger: homelab` with HOMELAB_STAGE_ENVIRONMENT=<tenant> and
# HOMELAB_STAGE_REV=<sha> -- the same edge bump-lock uses, carrying a
# different payload. A floxhub tenant's pipeline (home-arcade's
# scripts/ci_push.sh) has first pushed the environment and adds
# HOMELAB_STAGE_GENERATION=<n> and HOMELAB_STAGE_ENV=<owner/name>; the sha
# is still sent, as the provenance of that generation. The trigger build
# runs in homelab's checkout, so the tenant tree needs no copy of this
# script and no pinned homelab sha to curl it from; whatever is on homelab
# main stages it. .buildkite/pipeline.yml routes the trigger to this
# script and nothing else.
#
# Same posture as queue-closure: only main is staged, a short sha is
# refused, and "not on the box" is a skip with a message rather than a
# failure. Last-wins: a later green build overwrites an earlier one.
#
# TWO RECORDS, told apart by the pull unit by its own source.kind, not by
# the record's shape -- a record of the wrong kind for a tenant is refused
# there ("has no full sha" / "has no positive-integer generation"):
#
#   tree     {tenant, sha, tree, queued_at, build, branch, source}
#   floxhub  {tenant, env, generation, rev, queued_at, build, branch, source}
#
# where `tree` is the registry's remote verbatim (the pull unit compares
# it against the registry it was built with) and `env` is owner/name (the
# pull unit compares it against its source.env). `generation` is a JSON
# number. `rev` is the tenant commit whose build pushed the generation;
# hub-status shows it beside gN and holds the tree's origin HEAD against
# it, the way it does the tree kind's sha.
set -euo pipefail

HUB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REG="${HUB_REGISTRY:-$HUB/hub/repos.psv}"
STATE="${HOMELAB_DEPLOY_STATE:-/var/lib/homelab}"

TENANT="${1:-}"
REV="${2:-}"
# The floxhub kind's pair. Both or neither; validated below.
GENERATION="${HOMELAB_STAGE_GENERATION:-}"
ENVREF="${HOMELAB_STAGE_ENV:-}"
# The registry name of the tenant's tree (tree kind only). The same as the
# tenant for agent-hub; a tenant whose tree is named differently passes it
# explicitly. Must agree with homelab.tenants.<tenant>.environment.tree,
# because the pull unit refuses a record whose tree is not the one the
# closure was built against.
TREE="${HOMELAB_STAGE_TREE:-$TENANT}"
# In a trigger build BUILDKITE_BRANCH/BUILD_URL describe the homelab build,
# not the tenant's, so the tenant passes its own through; a direct run on
# the tenant's agent falls back to Buildkite's.
BRANCH="${HOMELAB_STAGE_BRANCH:-${BUILDKITE_BRANCH:-}}"
BUILD="${HOMELAB_STAGE_BUILD:-${BUILDKITE_BUILD_URL:-}}"

if [ -z "$TENANT" ] || [ -z "$REV" ]; then
  echo "usage: hub-queue-environment.sh <tenant> <sha>   [HOMELAB_STAGE_GENERATION=<n> HOMELAB_STAGE_ENV=<owner/name>]" >&2
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

# Which kind, and nothing in between. A generation without an env (or the
# reverse) is a trigger with a hole in it; an explicit tree beside a
# generation is a trigger that has not decided which edge it is on.
KIND=tree
if [ -n "$GENERATION" ] || [ -n "$ENVREF" ]; then
  KIND=floxhub
  if [ -z "$GENERATION" ] || [ -z "$ENVREF" ]; then
    echo "refuse queue-environment: HOMELAB_STAGE_GENERATION ('$GENERATION') and HOMELAB_STAGE_ENV ('$ENVREF') go together; one without the other stages nothing" >&2
    exit 1
  fi
  if [ -n "${HOMELAB_STAGE_TREE:-}" ]; then
    echo "refuse queue-environment: HOMELAB_STAGE_TREE ('$HOMELAB_STAGE_TREE') beside a generation -- a floxhub record carries the environment, not a tree; drop one" >&2
    exit 1
  fi
  if ! [[ "$GENERATION" =~ ^[1-9][0-9]*$ ]]; then
    echo "refuse queue-environment: generation '$GENERATION' is not a positive integer" >&2
    exit 1
  fi
  if ! [[ "$ENVREF" =~ ^[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+$ ]]; then
    echo "refuse queue-environment: environment '$ENVREF' is not owner/name" >&2
    exit 1
  fi
fi

# The tree kind's remote: the tenant's tree must be one this hub
# coordinates. The remote recorded here is what the pull unit compares
# against the registry it was built with -- a sha of the wrong tree is
# refused there, loudly, rather than checked out.
REMOTE=""
if [ "$KIND" = tree ]; then
  REMOTE=$(awk -F'|' -v r="$TREE" '$1==r{print $3}' "$REG")
  if [ -z "$REMOTE" ]; then
    echo "refuse queue-environment: tree '$TREE' is not in $REG (or has no remote)" >&2
    exit 1
  fi
fi

# Only main is ever staged. The pull unit applies whatever this file
# names without asking which branch it came from.
if [ "$BRANCH" != "main" ]; then
  echo "skip queue-environment: branch is '${BRANCH:-unset}', only main is staged"
  exit 0
fi

if ! [[ "$REV" =~ ^[0-9a-f]{40}$ ]]; then
  # A short sha is refused, not resolved: the pull unit fetches exactly
  # this object (tree), and a prefix would be resolved against whatever
  # the box's checkout happens to have fetched. The floxhub kind records
  # it as provenance, and provenance is not guessed either.
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
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [ "$KIND" = tree ]; then
  printf '{"tenant":"%s","sha":"%s","tree":"%s","queued_at":"%s","build":"%s","branch":"%s","source":"buildkite"}\n' \
    "$TENANT" "$REV" "$REMOTE" "$NOW" "$BUILD" "$BRANCH" \
    > "$TMP"
else
  printf '{"tenant":"%s","env":"%s","generation":%s,"rev":"%s","queued_at":"%s","build":"%s","branch":"%s","source":"buildkite"}\n' \
    "$TENANT" "$ENVREF" "$GENERATION" "$REV" "$NOW" "$BUILD" "$BRANCH" \
    > "$TMP"
fi
mv -f "$TMP" "$PENDING"

if [ "$KIND" = tree ]; then
  echo "queued environment $TENANT ${REV:0:7} ($TREE) -> $PENDING"
  echo "$TENANT-environment-pull.service checks it out, warms it and restarts the stub within minutes (if the closure carries the pull unit)"
else
  echo "queued environment $TENANT generation $GENERATION of $ENVREF (from ${REV:0:7}) -> $PENDING"
  echo "$TENANT-environment-pull.service pulls it, warms generation $GENERATION and restarts the stub within minutes (if the closure carries the pull unit)"
fi
