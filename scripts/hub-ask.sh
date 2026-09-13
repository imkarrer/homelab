#!/usr/bin/env bash
# Ask agent-hub's model server (llama.cpp on ac-box, OpenAI-compatible) one
# question, with a prompt budget enforced BEFORE the request is sent.
#
# The box has no GPU. Measured 13 Sep 2026 against Qwen3-Coder-Next Q8_0:
# prefill ~13 tok/s, generation ~4.8 tok/s. Prefill is the cost that
# surprises: a 4k-token prompt is ~5 minutes of silence before the first
# output token, 32k (the context size) is ~40 minutes. So this script
# tokenizes the assembled prompt via /tokenize first, prints the estimate,
# and refuses above the budget unless told otherwise. Which tasks are worth
# sending is .agents/skills/homelab-route/SKILL.md.
#
# Usage: hub-ask.sh [-s "system prompt" | -S file] [-f file]... [-m max_tokens]
#                   [-t temperature] [-b budget_tokens] [--force] "prompt"
#        echo "prompt" | hub-ask.sh ...
#   -f FILE      include FILE's contents as a fenced block in the user message
#   -m N         max output tokens (default 1024, ~3.5 min of generation)
#   -t T         sampling temperature (default 0.2 -- code, not prose)
#   -b N         prompt budget in tokens (default 6000, ~8 min of prefill)
#   --force      send even when over budget
# Output: the answer on stdout; the timings and tok/s on stderr.
# Exit: 0 answered, 3 over budget, 4 server not healthy, 5 request failed.
#
# Keep the SYSTEM prompt byte-stable across calls: llama-server caches the
# KV of a shared prefix per slot, and a re-used prefix is prefill you do not
# pay for a second time (the "cache_n" figure on stderr says how much hit).
set -uo pipefail
if ! command -v jq >/dev/null; then
  exec nix --extra-experimental-features 'nix-command flakes' shell nixpkgs#jq --command bash "$0" "$@"
fi

# The LAN address homelab.host declares; the port services.agent-hub.llm opens.
LLM="${HUB_LLM:-http://192.168.1.50:8100}"
SYSTEM=""; FILES=(); MAXTOK=1024; TEMP=0.2; BUDGET=6000; FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    -s) SYSTEM="$2"; shift 2 ;;
    -S) SYSTEM="$(cat "$2")"; shift 2 ;;
    -f) FILES+=("$2"); shift 2 ;;
    -m) MAXTOK="$2"; shift 2 ;;
    -t) TEMP="$2"; shift 2 ;;
    -b) BUDGET="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) sed -n '13,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --) shift; break ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *) break ;;
  esac
done
PROMPT="${*:-$(cat)}"
[ -n "$PROMPT" ] || { echo "no prompt" >&2; exit 2; }

for f in "${FILES[@]}"; do
  [ -r "$f" ] || { echo "unreadable: $f" >&2; exit 2; }
  PROMPT+=$'\n\n'"\`\`\`$f"$'\n'"$(cat "$f")"$'\n'"\`\`\`"
done

[ "$(curl -s -m 5 "$LLM/health" | jq -r .status 2>/dev/null)" = ok ] \
  || { echo "agent-hub-llm not healthy at $LLM (ssh ac-box 'systemctl status agent-hub-llm')" >&2; exit 4; }

# Budget check on the same bytes the request will carry.
N=$(jq -n --arg c "$SYSTEM"$'\n'"$PROMPT" '{content:$c}' \
    | curl -s -m 60 "$LLM/tokenize" -H 'Content-Type: application/json' -d @- \
    | jq '.tokens | length')
[ -n "$N" ] && [ "$N" != null ] || { echo "tokenize failed" >&2; exit 5; }
PREFILL=$((N / 13)); GEN=$((MAXTOK * 10 / 48))
echo "prompt ${N} tok (budget ${BUDGET}) ~${PREFILL}s prefill; up to ${MAXTOK} tok ~${GEN}s generation" >&2
if [ "$N" -gt "$BUDGET" ] && [ "$FORCE" = 0 ]; then
  echo "over budget: trim the prompt (fewer -f files, a tighter brief) or pass --force" >&2
  exit 3
fi

BODY=$(jq -n --arg s "$SYSTEM" --arg u "$PROMPT" --argjson m "$MAXTOK" --argjson t "$TEMP" '
  {model:"default", max_tokens:$m, temperature:$t, stream:false,
   messages: ([ (if $s != "" then {role:"system", content:$s} else empty end),
                {role:"user", content:$u} ])}')
T0=$(date +%s)
RESP=$(curl -s -m $((PREFILL + GEN + 600)) "$LLM/v1/chat/completions" \
         -H 'Content-Type: application/json' -d "$BODY") || { echo "request failed" >&2; exit 5; }
T1=$(date +%s)
CONTENT=$(jq -r '.choices[0].message.content // empty' <<<"$RESP")
[ -n "$CONTENT" ] || { echo "no content in response: $(head -c 300 <<<"$RESP")" >&2; exit 5; }
printf '%s\n' "$CONTENT"
jq -r --arg w "$((T1 - T0))" '.timings | "wall \($w)s | prompt \(.prompt_n) tok @ \(.prompt_per_second|floor) tok/s (cache hit \(.cache_n)) | generated \(.predicted_n) tok @ \(.predicted_per_second*10|floor/10) tok/s | finish \($f)"' --arg f "$(jq -r '.choices[0].finish_reason' <<<"$RESP")" <<<"$RESP" >&2 2>/dev/null \
  || jq -r '.timings' <<<"$RESP" >&2
