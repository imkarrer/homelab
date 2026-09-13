#!/usr/bin/env bash
# Apply the queued deploy on ac-box by starting the ac-host-ops pipeline.
# queue-prod only stages; this is what makes the box take it.
#
# Token: scripts/lib/buildkite-token.sh -- $BUILDKITE_API_TOKEN, else
# ~/.config/buildkite/token (chmod 600), else secrets/ac-box.yaml decrypted
# with the operator key. Needs write_builds. Never in argv, never in a file.
#
# Usage: hub-deploy.sh [downtime|emergency]
#   downtime  (default) apply the folded pending tree + one lobby recycle
#   emergency            drain, apply now, resume
set -uo pipefail
ORG=isaac-karrer
PIPELINE=ac-host-ops
MODE="${1:-downtime}"

# shellcheck source=scripts/lib/buildkite-token.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/buildkite-token.sh"
TOKEN=$(buildkite_token) || exit 2

case "$MODE" in
  downtime)  ENVJSON='{"DOWNTIME":"1"}' ;;
  emergency) ENVJSON='{"EMERGENCY":"1"}' ;;
  *) echo "usage: $0 [downtime|emergency]"; exit 2 ;;
esac

# Recycling a lobby with someone in it drops them mid-session, so check the
# board rather than trusting that it is quiet.
ONLINE=$(ssh -o BatchMode=yes -o ConnectTimeout=8 "${HOMELAB_BOX:-ac-box}" \
  'grep -oE "\"online\": \[[^]]+\]" /var/lib/ac-host/leaderboard.json 2>/dev/null | grep -cv "\[\]"' 2>/dev/null)
if [ "${ONLINE:-0}" != 0 ]; then
  echo "REFUSING: $ONLINE lobby/lobbies have drivers online."
  echo "Wait, or let the bot's countdown warn them first."
  exit 1
fi
echo "lobbies empty - proceeding"

PENDING=$(ssh -o BatchMode=yes "${HOMELAB_BOX:-ac-box}" 'grep -oE "[0-9a-f]{40}" /var/lib/ac-host/pending-deploy.json 2>/dev/null | head -1')
[ -n "$PENDING" ] || { echo "nothing queued - queue-prod has not staged a sha"; exit 1; }
echo "queued sha: ${PENDING:0:7}"

printf 'Authorization: Bearer %s\nContent-Type: application/json\n' "$TOKEN" |
  curl -sS -X POST -H @- \
  --data "{\"commit\":\"HEAD\",\"branch\":\"main\",\"message\":\"Apply pending ${PENDING:0:7} ($MODE)\",\"env\":$ENVJSON}" \
  "https://api.buildkite.com/v2/organizations/$ORG/pipelines/$PIPELINE/builds" \
  | grep -oE '"web_url": *"[^"]+"' | head -1 | cut -d'"' -f4
