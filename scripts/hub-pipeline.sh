#!/usr/bin/env bash
# Ensure a tree's Buildkite pipeline OBJECT matches its definition in git.
#
# The steps of every pipeline are in the tree (.buildkite/pipeline.yml). The
# object that points at those steps -- which repo, which branch, the bootstrap
# `buildkite-agent pipeline upload`, GitHub builds on push -- was a UI action
# (home-arcade/docs/ci.md "First-time pipeline"), and nothing recorded whether
# it had been done: on 13 Sep 2026 homelab's steps had been in git for a day
# and no push had ever built, because the object did not exist (Part III
# row 33 in docs/architecture.md). This script is that object as code, row 25.
#
# The definition is the whole request body, hub/pipelines/<tree>.json, and it
# is sent verbatim: what is in git is what Buildkite gets, `--dry-run` prints
# exactly it, and `diff hub/pipelines/*.json` is the per-tree difference. The
# alternative -- a template in this script with a per-tree stub -- would have
# left both stubs nearly empty and the real shape here, where a reader of the
# definition cannot see it. The shape the agent depends on is checked below
# instead, so a definition cannot drift from what the box serves.
#
# Idempotent by POST-then-PATCH, not by GET-then-decide: the token (see
# lib/buildkite-token.sh) has write_pipelines but not read_pipelines, so the
# script cannot list or fetch a pipeline (GET returns 403, verified 13 Sep).
# It creates; when Buildkite answers 422 "already taken" it updates the slug
# with the same body. Both are write_pipelines. Which path ran is printed.
#
# The agent. The only agent, `ac-box` (modules/ci), is registered UNCLUSTERED
# with tag queue=self. The org's "Default cluster" has a `self` queue too, but
# the agent is not in it, so a pipeline created with a cluster_id would wait
# for an agent forever. Definitions therefore carry no cluster_id and their
# bootstrap step targets `agents: {queue: self}` -- the shape ac-host's
# pipeline has worked with since 12 Sep. Verified against the live API 13 Sep.
#
# GitHub. Buildkite's GitHub App is installed on the imkarrer account (ac-host
# builds on push); whether it covers a given repo is not readable through the
# API -- repository_connections lists the App, not its repos. So after the
# object exists the script prints the pipeline's webhook URL and the manual
# fallback, and the proof is the first build.
#
# Usage: hub-pipeline.sh <tree> [--dry-run]     tree from hub/repos.psv
#        hub-pipeline.sh --token-check          scopes only; nothing written
# The dry run needs no token and sends nothing.
set -uo pipefail
ORG=isaac-karrer
API="https://api.buildkite.com/v2"
HUB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REG="${HUB_REGISTRY:-$HUB/hub/repos.psv}"
export NIX_CONFIG="experimental-features = nix-command flakes"

TREE=""; DRY=0; TOKEN_CHECK=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --token-check) TOKEN_CHECK=1 ;;
    -*) echo "usage: $0 <tree> [--dry-run] | $0 --token-check"; exit 2 ;;
    *) TREE="$a" ;;
  esac
done
[ -n "$TREE" ] || [ $TOKEN_CHECK -eq 1 ] || { echo "usage: $0 <tree> [--dry-run] | $0 --token-check"; exit 2; }

# jq is not on PATH here or on the agent; nix brings it, as hub-gates.sh does
# for flox. One wrapper so every jq call below is the same pinned binary.
jq() { nix shell nixpkgs#jq -c jq "$@"; }

TMP=$(mktemp -d -t hub-pipeline.XXXXXX); trap 'rm -rf "$TMP"' EXIT
# Headers go in through stdin (-H @-), so the token is never in argv.
bk() {  # bk <method> <url> [body-file]  -> prints http code, body in $TMP/body
  local method="$1" url="$2" body="${3:-}"
  local -a data=()
  [ -n "$body" ] && data=(--data-binary "@$body")
  printf 'Authorization: Bearer %s\nContent-Type: application/json\n' "$TOKEN" |
    curl -sS -X "$method" -H @- "${data[@]}" -o "$TMP/body" -w '%{http_code}' "$url"
}

# ---- the definition, checked against what the agent and the tenants assume --
if [ -n "$TREE" ]; then
  REMOTE=$(awk -F'|' -v r="$TREE" '$1==r{print $3}' "$REG")
  [ -n "$REMOTE" ] || { echo "unknown tree: $TREE (see $REG)"; exit 2; }
  DEF="$HUB/hub/pipelines/$TREE.json"
  [ -r "$DEF" ] || { echo "no definition: ${DEF#"$HUB"/} -- write one (copy hub/pipelines/homelab.json)"; exit 2; }
  # git@github.com:imkarrer/homelab -> imkarrer/homelab; the agent clones over
  # https (checked in its build dirs on the box: origin https://github.com/...git).
  GH=$(printf '%s' "$REMOTE" | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')
  WANT_REPO="https://github.com/$GH.git"

  echo "== definition: ${DEF#"$HUB"/} =="
  if ! jq -e --arg t "$TREE" --arg repo "$WANT_REPO" '
      (.name == $t and .slug == $t)
      and (.repository == $repo)
      and ((.cluster_id // null) == null)
      and (.configuration | test("buildkite-agent pipeline upload"))
      and (.configuration | test("queue: *\"?self\"?"))
      and (.provider_settings.trigger_mode == "code")
    ' "$DEF" >/dev/null; then
    echo "  REJECTED. Every definition must have, and this one does not:"
    echo "    name == slug == \"$TREE\"      (ac-host's and home-arcade's \`trigger: homelab\` steps assume the slug)"
    echo "    repository == \"$WANT_REPO\"   (from $REG; https, as the agent clones)"
    echo "    no cluster_id                (the agent is unclustered; a clustered pipeline never gets it)"
    echo "    configuration with \`buildkite-agent pipeline upload\` under \`queue: self\`"
    echo "    provider_settings.trigger_mode == \"code\"   (build on push)"
    jq . "$DEF" 2>&1 | sed 's/^/    /' | head -20
    exit 1
  fi
  echo "  name/slug $TREE, repository $WANT_REPO, unclustered, queue=self, upload step: OK"
  echo "  configuration, decoded:"
  jq -r .configuration "$DEF" | sed '/^$/d; s/^/    | /'
fi

# ---- dry run: the exact request, and nothing sent ---------------------------
if [ $DRY -eq 1 ]; then
  echo
  echo "== dry run: nothing sent, no token read =="
  echo "POST $API/organizations/$ORG/pipelines"
  echo "Authorization: Bearer <token: not read in a dry run>"
  echo "Content-Type: application/json"
  jq . "$DEF"
  echo
  echo "on 422 (name or slug already taken):"
  echo "PATCH $API/organizations/$ORG/pipelines/$TREE   (same body)"
  echo
  echo "then, read-only: GET $API/organizations/$ORG/repository_connections"
  exit 0
fi

# ---- token, proven before anything is written -------------------------------
# shellcheck source=scripts/lib/buildkite-token.sh
. "$HUB/scripts/lib/buildkite-token.sh"
TOKEN=$(buildkite_token) || exit 2
echo "== token =="
code=$(bk GET "$API/access-token")
if [ "$code" != 200 ]; then
  echo "  GET /v2/access-token: HTTP $code -- the token is not accepted"; cat "$TMP/body"; echo; exit 1
fi
SCOPES=$(jq -r '.scopes | join(" ")' "$TMP/body")
echo "  scopes: $SCOPES"
case " $SCOPES " in
  *" write_pipelines "*) ;;
  *) echo "  write_pipelines is not among them; this token cannot create or update a pipeline"; exit 1 ;;
esac
[ $TOKEN_CHECK -eq 1 ] && exit 0

# ---- create, or update the slug that already exists -------------------------
echo "== $TREE: POST $API/organizations/$ORG/pipelines =="
code=$(bk POST "$API/organizations/$ORG/pipelines" "$DEF")
PATHRAN=""
case "$code" in
  201) PATHRAN="created" ;;
  422)
    # The create endpoint rejects a name that matches an existing pipeline's;
    # that, and only that, is the "already exists" signal the token can see.
    if jq -e '[.errors[]? | select(.field == "name" or .field == "slug")] | length > 0' "$TMP/body" >/dev/null \
       || grep -qiE 'taken|already|exists' "$TMP/body"; then
      echo "  422: $(jq -r '[.errors[]? | "\(.field): \(.code)"] | join("; ")' "$TMP/body" 2>/dev/null)"
      echo "== $TREE: PATCH $API/organizations/$ORG/pipelines/$TREE (same body) =="
      code=$(bk PATCH "$API/organizations/$ORG/pipelines/$TREE" "$DEF")
      [ "$code" = 200 ] && PATHRAN="updated"
    fi ;;
esac
if [ -z "$PATHRAN" ]; then
  echo "  HTTP $code"; jq . "$TMP/body" 2>/dev/null || cat "$TMP/body"; echo
  [ "$code" = 403 ] && echo "  403 with write_pipelines in scope usually means the token's user is not an org admin, or a cluster/team rule applies."
  exit 1
fi

# The response is the object as Buildkite now holds it; read the facts the
# agent and the trigger steps depend on back out of it rather than trusting
# the request.
SLUG=$(jq -r .slug "$TMP/body"); WEB=$(jq -r .web_url "$TMP/body")
CLUSTER=$(jq -r '.cluster_id // "null"' "$TMP/body")
HOOK=$(jq -r '.provider.webhook_url // "?"' "$TMP/body")
PREPO=$(jq -r '.provider.settings.repository // "?"' "$TMP/body")
PMODE=$(jq -r '.provider.settings.trigger_mode // "?"' "$TMP/body")
echo "  $PATHRAN: $SLUG  $WEB"
echo "  cluster_id $CLUSTER; provider repository $PREPO, trigger_mode $PMODE"
[ "$SLUG" = "$TREE" ] || { echo "  SLUG MISMATCH: Buildkite holds '$SLUG', the trigger steps say '$TREE'"; exit 1; }
[ "$CLUSTER" = null ] || { echo "  CLUSTERED: $CLUSTER -- the ac-box agent is not in any cluster and will never take this pipeline's jobs"; exit 1; }

# ---- what the operator may still owe on the GitHub side ---------------------
echo
echo "== GitHub side =="
echo "  Buildkite's GitHub App is what turns a push into a build. It is installed"
echo "  on the imkarrer account (ac-host builds today); whether it may see"
echo "  $GH is not readable here, so the proof is the first push:"
echo "    watch: ssh ac-box docker logs -f ac-host-ci-agent-1     (a $SLUG/builds/1 job)"
echo "  If the first push does not build, add this as a GitHub webhook on"
echo "  https://github.com/$GH/settings/hooks -- content type json, events push +"
echo "  pull_request -- or grant the App the repo at"
echo "  https://github.com/settings/installations (Buildkite -> Repository access):"
echo "    $HOOK"
# read_organization_repository_connections: lists the App(s), not their repos.
code=$(bk GET "$API/organizations/$ORG/repository_connections")
if [ "$code" = 200 ]; then
  echo "  connections the org has (the API lists Apps, not which repos each covers):"
  for id in $(jq -r '.[].id' "$TMP/body"); do
    if [ "$(bk GET "$API/organizations/$ORG/repository_connections/$id")" = 200 ]; then
      jq -r '"    \(.type): \(.display_name), account \(.service_account.login // "-"), \(.host.url // "-")"' "$TMP/body"
    fi
  done
else
  echo "  (repository_connections: HTTP $code; not listed)"
fi
