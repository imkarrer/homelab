#!/usr/bin/env bash
# Ask the hub's index where something is. The question is embedded by the
# same model hub-index.sh used, Qdrant returns the nearest chunks, and each
# hit prints as tree/path:start-end with its score and the first lines of
# the chunk -- enough to open the file at the right place, which is the
# point: an agent reads three chunks instead of grepping three trees into
# its context.
#
#   hub-search.sh "how does a tenant push reach the box"
#   hub-search.sh -k 3 -t homelab "memory budget assertion"
#   hub-search.sh --json "..."          the raw hits, for a tool to consume
#
# -t restricts to one tree (homelab, ac-host, agent-hub, home-arcade, beads).
# Scores are cosine similarity; on this model a hit above ~0.5 is usually the
# right file and below ~0.35 is usually noise, but read the snippet.
set -euo pipefail

LLM="${LLM:-192.168.1.51:8100}"
QDRANT="${QDRANT:-192.168.1.51:6333}"
MODEL="${MODEL:-embed}"
COLLECTION="${COLLECTION:-hub}"
K=6; TREE=""; JSON=0; LINES=4

while [ $# -gt 0 ]; do
  case "$1" in
    -k) K="$2"; shift ;;
    -t|--tree) TREE="$2"; shift ;;
    -n|--lines) LINES="$2"; shift ;;
    --json) JSON=1 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    -*) echo "unknown option $1" >&2; exit 2 ;;
    *) break ;;
  esac
  shift
done
QUERY="${*:-}"
[ -n "$QUERY" ] || { echo "usage: hub-search.sh [-k N] [-t tree] [-n lines] [--json] <question>" >&2; exit 2; }

export NIX_CONFIG="experimental-features = nix-command flakes"
command -v jq >/dev/null 2>&1 || PATH="$(nix build --no-link --print-out-paths nixpkgs#jq 2>/dev/null | head -1)/bin:$PATH"

vec=$(curl -sSf "http://$LLM/v1/embeddings" -H 'Content-Type: application/json' \
  -d "$(jq -cn --arg m "$MODEL" --arg q "$QUERY" '{model:$m,input:[$q]}')" | jq -c '.data[0].embedding')

body=$(jq -cn --argjson v "$vec" --argjson k "$K" --arg t "$TREE" '
  { vector: $v, limit: $k, with_payload: true }
  + (if $t != "" then { filter: { must: [ { key: "tree", match: { value: $t } } ] } } else {} end)')
hits=$(curl -sSf "http://$QDRANT/collections/$COLLECTION/points/search" -H 'Content-Type: application/json' -d "$body")

if [ "$JSON" = 1 ]; then
  jq '[.result[] | { score, tree: .payload.tree, path: .payload.path, start: .payload.start, end: .payload.end, text: .payload.text }]' <<<"$hits"
  exit 0
fi

jq -r --argjson n "$LINES" '
  .result[]
  | "\(.score * 1000 | round / 1000)  \(.payload.tree)/\(.payload.path)" + (if .payload.end > 0 then ":\(.payload.start)-\(.payload.end)" else "" end)
    + "\n" + ((.payload.text | split("\n") | .[1:] | map(select(length > 0))) | .[0:$n] | map("      " + .) | join("\n")) + "\n"' <<<"$hits"
