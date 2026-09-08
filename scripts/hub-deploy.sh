#!/usr/bin/env bash
# Apply the queued deploy on ac-box by starting the ac-host-ops pipeline.
# queue-prod only stages; this is what makes the box take it.
#
# Token: $BUILDKITE_API_TOKEN, or ~/.config/buildkite/token (chmod 600).
# Never commit it -- needs write_builds.
#
# Usage: hub-deploy.sh [downtime|emergency]
#   downtime  (default) apply the folded pending tree + one lobby recycle
#   emergency            drain, apply now, resume
set -uo pipefail
ORG=isaac-karrer
PIPELINE=ac-host-ops
MODE="${1:-downtime}"

TOKEN="${BUILDKITE_API_TOKEN:-}"
[ -z "$TOKEN" ] && [ -r "$HOME/.config/buildkite/token" ] && TOKEN=$(tr -d '\n' < "$HOME/.config/buildkite/token")
[ -n "$TOKEN" ] || { echo "no token: set BUILDKITE_API_TOKEN or write ~/.config/buildkite/token"; exit 2; }

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

curl -sS -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  --data "{\"commit\":\"HEAD\",\"branch\":\"main\",\"message\":\"Apply pending ${PENDING:0:7} ($MODE)\",\"env\":$ENVJSON}" \
  "https://api.buildkite.com/v2/organizations/$ORG/pipelines/$PIPELINE/builds" \
  | grep -oE '"web_url": *"[^"]+"' | head -1 | cut -d'"' -f4
