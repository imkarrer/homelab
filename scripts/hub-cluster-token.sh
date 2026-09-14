#!/usr/bin/env bash
# Mint a Buildkite CLUSTER agent token and put it straight into
# secrets/ac-box.yaml as `buildkite-agent-token`, never printing it.
#
# Why this exists: Buildkite stopped creating unclustered pipelines (13 Sep
# 2026: POST /pipelines -> 422 "Cluster must be specified"), so every pipeline
# the ac-box agent serves lives in the Default cluster, and an agent joins a
# cluster with a token minted FOR that cluster. The API returns the value
# exactly once, in the create response; this script hands it to sops in the
# same process and shows only the token's description and uuid. Rotation is
# running this again and switching (modules/platform/secrets.nix renders it).
#
# Needs the API token with write_clusters (lib/buildkite-token.sh finds it).
#
# Usage: hub-cluster-token.sh [description]     default: "ac-box <date>"
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib/buildkite-token.sh
. "$ROOT/scripts/lib/buildkite-token.sh"

ORG=isaac-karrer
CLUSTER=9c1e5f56-22de-42cf-aa00-4b91d5583922   # "Default cluster", the only one; hub-pipeline.sh pins the same id
DESC="${1:-ac-box $(date +%F)}"

export NIX_CONFIG="experimental-features = nix-command flakes"
TOKEN=$(buildkite_token) || exit 2

# One curl, one jq, one sops: the agent token crosses two pipes and no
# variable. jq prints the value to the pipe and the bookkeeping to stderr.
printf 'Authorization: Bearer %s\n' "$TOKEN" \
  | curl -sS -H @- -X POST \
      -H 'Content-Type: application/json' \
      -d "$(printf '{"description":"%s"}' "$DESC")" \
      "https://api.buildkite.com/v2/organizations/$ORG/clusters/$CLUSTER/tokens" \
  | nix shell nixpkgs#jq -c jq -r '
      if .token then
        (("created cluster token \(.description) uuid \(.id)" | stderr) | empty), .token
      else
        ("Buildkite refused: \(.)" | stderr) | empty
      end' \
  | bash "$ROOT/scripts/hub-secret-set.sh" buildkite-agent-token
