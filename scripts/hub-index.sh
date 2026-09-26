#!/usr/bin/env bash
# Index the hub's four trees and its beads into Qdrant, through agent-hub's
# embedding model, so an agent can ask "where is the thing about X" and get
# file:lines back instead of grepping whole trees into a 32k context. The
# search side is hub-search.sh.
#
#   hub-index.sh                 every tree in hub/repos.psv, then the beads
#   hub-index.sh homelab beads   a subset; "beads" is the tracker's export
#
# What goes in: the tracked files of each tree that carry prose or decisions
# -- .md .nix .sh .py .yml .yaml .psv -- cut into overlapping chunks of lines
# (CHUNK / OVERLAP below), and one point per bead from .beads/issues.jsonl.
# Not flake.lock, not JSON, not the models: nothing a person would want a
# search to land on.
#
# Idempotent and whole-tree: every run re-embeds a tree and upserts its
# chunks under DETERMINISTIC ids (a hash of tree, path and chunk number), then
# deletes every point of that tree not stamped with this run. So a changed
# file's old chunks go, a deleted file's chunks go, and an unchanged file's
# chunks are overwritten with themselves. No state between runs but the
# collection. ~700 chunks for the four trees as of 16 Sep 2026; a full run is
# the embedding model's throughput: ~680 tok/s on the fence's 23 threads, so a
# few minutes end to end, and one tree in well under one.
#
# Talks to the box over the LAN like vectors-smoke.sh does, so it runs from
# the WSL box that has the trees checked out. Needs curl, jq and git.
set -euo pipefail
# A failure inside $(...) must be a failure: without this, an upsert that
# returned 1 inside an arithmetic expansion was silently counted as 0 chunks.
shopt -s inherit_errexit

HUB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REG="${HUB_REGISTRY:-$HUB/hub/repos.psv}"
LLM="${LLM:-192.168.1.51:8100}"
QDRANT="${QDRANT:-192.168.1.51:6333}"
MODEL="${MODEL:-embed}"
COLLECTION="${COLLECTION:-hub}"
CHUNK="${CHUNK:-80}"      # lines per chunk
OVERLAP="${OVERLAP:-15}"  # lines shared with the previous chunk
MAXCHARS="${MAXCHARS:-12000}"  # characters per chunk (~3k tokens; the context is 8k)
BATCH="${BATCH:-16}"      # chunks per embedding request
EXT='\.(md|nix|sh|py|ya?ml|psv)$'

# jq is not on PATH here; nix brings it, resolved once rather than per call
# (hub-pipeline.sh's per-call wrapper is fine for ten calls, not seven hundred).
export NIX_CONFIG="experimental-features = nix-command flakes"
command -v jq >/dev/null 2>&1 || PATH="$(nix build --no-link --print-out-paths nixpkgs#jq 2>/dev/null | head -1)/bin:$PATH"
command -v jq >/dev/null 2>&1 || { echo "hub-index: jq not found and nix could not provide it" >&2; exit 2; }

RUN=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TMP=$(mktemp -d -t hub-index.XXXXXX)
# KEEP_TMP=1 leaves the request and response files behind for a post-mortem.
[ -n "${KEEP_TMP:-}" ] || trap 'rm -rf "$TMP"' EXIT

api() { # api <method> <path> [json-body]  -> body on stdout, non-2xx is fatal
  local m="$1" p="$2" body="${3:-}" code
  if [ -n "$body" ]; then
    # A body starting with @ is a file, as curl reads it (the points batch
    # is written to one; it is too large for argv).
    code=$(curl -sS -X "$m" "http://$QDRANT$p" -H 'Content-Type: application/json' --data-binary "$body" -o "$TMP/resp" -w '%{http_code}')
  else
    code=$(curl -sS -X "$m" "http://$QDRANT$p" -o "$TMP/resp" -w '%{http_code}')
  fi
  case "$code" in 2*) cat "$TMP/resp" ;; *) echo "hub-index: $m $p -> HTTP $code: $(head -c 300 "$TMP/resp")" >&2; return 1 ;; esac
}

embed() { # embed <file holding a JSON array of strings> -> json array of vectors
  # Files on both sides of every large payload. A single argument is capped
  # at 128 KB (MAX_ARG_STRLEN), and sixteen 12 KB chunks are past it; so is
  # a batch of vectors. The first symptom was jq printing nothing and curl
  # posting an empty body: a 404 that looked like a routing problem.
  jq -cn --slurpfile i "$1" --arg m "$MODEL" '{model:$m,input:$i[0]}' > "$TMP/embed-req"
  curl -sSf "http://$LLM/v1/embeddings" -H 'Content-Type: application/json' --data-binary "@$TMP/embed-req" | jq -c '[.data[].embedding]'
}

# ---- the collection: created on first use, sized by the model -------------
ensure_collection() {
  if curl -sf "http://$QDRANT/collections/$COLLECTION" >/dev/null 2>&1; then return; fi
  local dim
  printf '["dimension probe"]' > "$TMP/probe"; dim=$(embed "$TMP/probe" | jq '.[0] | length')
  echo "== creating collection $COLLECTION (${dim}-dim, cosine)"
  api PUT "/collections/$COLLECTION" "$(jq -cn --argjson d "$dim" '{vectors:{size:$d,distance:"Cosine"}}')" >/dev/null
  # Keyword indexes on the two fields every filter uses: the per-tree stale
  # delete below, and hub-search.sh's --tree.
  for f in tree path run; do
    api PUT "/collections/$COLLECTION/index" "$(jq -cn --arg f "$f" '{field_name:$f,field_schema:"keyword"}')" >/dev/null
  done
}

# ---- chunking: one JSON line per chunk ---------------------------------------
# A file becomes chunks of up to CHUNK lines AND up to MAXCHARS characters,
# whichever fills first, each starting OVERLAP lines before the previous one
# ended so a paragraph that straddles a boundary is whole in at least one.
# The character budget is what keeps docs/architecture.md indexable: its
# table rows run to thousands of characters, and eighty of them is ~30k
# tokens against the model's 8k context -- the HTTP 500 of the first run.
# A single line past the budget is cut at it; a truncated table row still
# embeds as the row it is. awk computes the ranges; jq -Rs turns each slice
# into a JSON string, which is what keeps a tab, a quote or a backslash in
# the source from breaking the record. Each chunk carries the sha256 of its
# text, which is what lets a re-run skip the embedding of anything unchanged.
chunk_file() { # chunk_file <tree> <abs-dir> <rel-path>  -> JSONL on stdout
  local tree="$1" dir="$2" rel="$3" n s e text sha
  [ -s "$dir/$rel" ] || return 0
  while read -r n s e; do
    text=$(sed -n "${s},${e}p" "$dir/$rel" | cut -c "1-$MAXCHARS")
    sha=$(printf '%s' "$text" | sha256sum | cut -c1-16)
    jq -n -c --arg tree "$tree" --arg path "$rel" --argjson n "$n" --argjson s "$s" --argjson e "$e" --arg sha "$sha" --arg text "$text" \
      '{ tree: $tree, path: $path, n: $n, start: $s, end: $e, sha: $sha,
         text: ("# \($tree)/\($path):\($s)-\($e)\n" + $text) }'
  done < <(awk -v N="$CHUNK" -v O="$OVERLAP" -v B="$MAXCHARS" '
    { len[NR] = length($0) + 1 }
    END {
      if (NR == 0) exit
      s = 1; n = 0
      while (s <= NR) {
        e = s; bytes = len[s]
        while (e + 1 <= NR && e + 1 <= s + N - 1 && bytes + len[e + 1] <= B) { e++; bytes += len[e] }
        print n, s, e
        if (e >= NR) break
        n++
        ns = e - O + 1; if (ns <= s) ns = s + 1
        s = ns
      }
    }' "$dir/$rel")
}

chunk_beads() { # -> JSONL, one per bead, from the tracker's export
  local f="$HUB/.beads/issues.jsonl"
  [ -r "$f" ] || { echo "hub-index: no $f; skipping beads" >&2; return; }
  jq -c '
    select(.id != null)
    | { tree: "beads", path: .id, n: 0, start: 0, end: 0,
        text: ("# bead " + .id + " [" + (.status // "?") + "] " + (.title // "") + "\n\n"
               + (.description // "") + (if .notes then "\n\nNotes: " + .notes else "" end)
               + (if .close_reason then "\n\nClosed: " + .close_reason else "" end)) }' "$f" \
  | while IFS= read -r line; do
      # The same content hash chunk_file carries, so an untouched bead is a
      # payload touch on re-run rather than an embedding.
      jq -c --arg sha "$(jq -r .text <<<"$line" | sha256sum | cut -c1-16)" '. + { sha: $sha }' <<<"$line"
    done
}

# ---- embedding and upserting, BATCH chunks at a time ------------------------
# Point ids must be unsigned integers or UUIDs; this is 60 bits of the sha256
# of tree/path/chunk-number, which is what makes a re-run overwrite rather
# than duplicate. The payload keeps the text, so a hit can be shown without
# a second lookup, and the run stamp, so the stale delete can find the rest.
point_id() { printf '%d' "0x$(printf '%s' "$1" | sha256sum | cut -c1-15)"; }

upsert_batch() { # stdin: JSONL chunks -> prints "<embedded> <unchanged>"
  local chunks ids="" key
  chunks=$(cat)
  [ -n "$chunks" ] || { echo "0 0"; return 0; }
  while IFS= read -r key; do ids+="$(point_id "$key"),"; done < <(jq -r '"\(.tree)/\(.path)#\(.n)"' <<<"$chunks")
  # Every chunk gets its id; then the collection is asked what it already
  # holds under those ids. A chunk whose stored sha matches is unchanged:
  # its run stamp is touched and the embedding is skipped. That is what
  # makes a re-run over four trees seconds instead of minutes -- the model
  # only sees what moved.
  jq -cs --argjson ids "[${ids%,}]" '[ range(length) as $i | .[$i] + { id: $ids[$i] } ]' <<<"$chunks" > "$TMP/chunks"
  api POST "/collections/$COLLECTION/points" "$(jq -c '{ ids: map(.id), with_payload: ["sha"], with_vector: false }' "$TMP/chunks")" \
    | jq -c '[ .result[] | { id, sha: .payload.sha } ]' > "$TMP/have"
  jq -c --slurpfile have "$TMP/have" '
    ($have[0] | map({ key: (.id|tostring), value: .sha }) | from_entries) as $h
    | map(select(.sha != "" and $h[(.id|tostring)] == .sha))' "$TMP/chunks" > "$TMP/same"
  jq -c --slurpfile same "$TMP/same" '
    ($same[0] | map(.id)) as $s | map(select(.id as $i | $s | index($i) | not))' "$TMP/chunks" > "$TMP/changed"
  local n_same n_changed
  n_same=$(jq 'length' "$TMP/same"); n_changed=$(jq 'length' "$TMP/changed")
  if [ "$n_same" -gt 0 ]; then
    api POST "/collections/$COLLECTION/points/payload?wait=true" \
      "$(jq -c --arg run "$RUN" '{ payload: { run: $run }, points: map(.id) }' "$TMP/same")" >/dev/null
  fi
  if [ "$n_changed" -gt 0 ]; then
    # Vectors go through a file, not argv: sixteen 1024-float vectors are
    # ~350 KB of JSON, past the argument limit ("Argument list too long").
    jq -c 'map(.text)' "$TMP/changed" > "$TMP/texts"
    embed "$TMP/texts" > "$TMP/vecs"
    jq -c --slurpfile v "$TMP/vecs" --arg run "$RUN" '
      { points: [ range(length) as $i | { id: .[$i].id, vector: $v[0][$i], payload: (.[$i] | del(.id) + { run: $run }) } ] }' "$TMP/changed" > "$TMP/points"
    api PUT "/collections/$COLLECTION/points?wait=true" "@$TMP/points" >/dev/null
  fi
  echo "$n_changed $n_same"
}

index_stream() { # stdin: JSONL chunks -> reports embedded / unchanged
  local emb=0 same=0 batchfile="$TMP/batch" n=0 c
  : > "$batchfile"
  flush() {
    c=$(upsert_batch < "$batchfile"); emb=$((emb + ${c% *})); same=$((same + ${c#* }))
    : > "$batchfile"; n=0
    printf '\r   %d embedded, %d unchanged' "$emb" "$same" >&2
  }
  while IFS= read -r line; do
    printf '%s\n' "$line" >> "$batchfile"; n=$((n+1))
    [ "$n" -ge "$BATCH" ] && flush
  done
  [ "$n" -gt 0 ] && flush
  printf '\r   %d embedded, %d unchanged\n' "$emb" "$same" >&2
}

delete_stale() { # delete_stale <tree>: every point of the tree not from this run
  local before after
  before=$(api POST "/collections/$COLLECTION/points/count" "$(jq -cn --arg t "$1" '{filter:{must:[{key:"tree",match:{value:$t}}]},exact:true}')" | jq '.result.count')
  api POST "/collections/$COLLECTION/points/delete?wait=true" "$(jq -cn --arg t "$1" --arg run "$RUN" \
    '{filter:{must:[{key:"tree",match:{value:$t}}],must_not:[{key:"run",match:{value:$run}}]}}')" >/dev/null
  after=$(api POST "/collections/$COLLECTION/points/count" "$(jq -cn --arg t "$1" '{filter:{must:[{key:"tree",match:{value:$t}}]},exact:true}')" | jq '.result.count')
  echo "   $1: $after points ($((before - after)) stale removed)"
}

index_tree() { # index_tree <name> <dir>
  local tree="$1" dir="$2"
  [ -d "$dir/.git" ] || { echo "hub-index: $tree: no checkout at $dir" >&2; return 1; }
  echo "== $tree ($dir)"
  git -C "$dir" ls-files | grep -E "$EXT" | grep -v '^flake\.lock$' | while IFS= read -r rel; do
    [ -f "$dir/$rel" ] && chunk_file "$tree" "$dir" "$rel"
  done | index_stream
  delete_stale "$tree"
}

# ---- main --------------------------------------------------------------------
ensure_collection
targets=("$@")
if [ ${#targets[@]} -eq 0 ]; then
  mapfile -t targets < <(awk -F'|' '!/^#/ && NF>=2 {print $1}' "$REG")
  targets+=(beads)
fi
for t in "${targets[@]}"; do
  if [ "$t" = beads ]; then
    echo "== beads ($HUB/.beads/issues.jsonl)"
    chunk_beads | index_stream
    delete_stale beads
  else
    dir=$(awk -F'|' -v r="$t" '$1==r{print $2}' "$REG")
    [ -n "$dir" ] || { echo "hub-index: unknown tree $t (see $REG)" >&2; exit 2; }
    index_tree "$t" "$dir"
  fi
done
echo "== done: run $RUN, collection $COLLECTION on $QDRANT"
api GET "/collections/$COLLECTION" | jq -r '"   \(.result.points_count) points total"'
