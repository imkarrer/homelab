#!/usr/bin/env bash
# The one Buildkite cluster ac-box serves. Sourced by hub-pipeline.sh (every
# pipeline object carries this cluster_id) and hub-cluster-token.sh (the agent
# token is minted for it). One file so the two cannot disagree.
#
# "Default cluster", the org's only one. Since 13 Sep 2026 Buildkite refuses
# to create an unclustered pipeline (POST /pipelines without cluster_id ->
# 422 "Cluster must be specified"); the three ac-host* objects that predate
# that are grandfathered and are moved in by `hub-pipeline.sh adopt`.
# The cluster's `self` queue (4ce8ef2d-f7a0-4617-ab56-d1c0eee4479c) is the
# one the agent's queue=self tag lands in once it registers with a cluster
# token -- the same queue name the unclustered agent used, so no step changes.
# shellcheck disable=SC2034  # read by the sourcing script
BUILDKITE_CLUSTER_ID=9c1e5f56-22de-42cf-aa00-4b91d5583922
BUILDKITE_CLUSTER_NAME="Default cluster"
