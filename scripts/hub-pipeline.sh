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
# THE CLUSTER, AND THE ORDERING HAZARD. Buildkite no longer creates an
# unclustered pipeline: the first real run, 13 Sep, got 422 "Cluster must be
# specified". So every definition carries cluster_id = the Default cluster
# (lib/buildkite-cluster.sh, one constant shared with hub-cluster-token.sh),
# the validator requires exactly that id, and the three ac-host* objects that
# predate the rule -- grandfathered, unclustered, definitions not in git and
# not readable with this token -- are moved in by `adopt`, a PATCH of only
# {"cluster_id": ...}.
#
# A clustered pipeline is served ONLY by an agent registered with a token
# minted for that cluster. The `ac-box` agent registered unclustered
# (`cluster: null`, tag queue=self); the cluster has a `self` queue the tag
# lands in once the agent reconnects with the cluster token, and until then
# nothing serves a clustered pipeline. So between `adopt ac-host` and the
# agent's reconnect, ac-host jobs queue and do not run. That is the ci
# tenant, drainable (AGENTS.md), minutes -- but it is an outage if the
# reconnect never comes, and the reconnect is a homelab switch (the token in
# the agent's env, bead .39.1) plus `systemctl restart ac-host-ci` from ssh,
# NEVER from a job on that agent (modules/ci HAZARD 2: the job would kill
# itself). The order is therefore:
#
#   1. switch the closure that renders the cluster token into the agent's env
#   2. ssh ac-box sudo systemctl restart ac-host-ci
#   3. hub-pipeline.sh agents         -> `ac-box` connected, cluster non-null
#   4. hub-pipeline.sh adopt ac-host; adopt ac-host-ops; adopt ac-host-series
#   5. hub-pipeline.sh homelab; hub-pipeline.sh home-arcade
#   6. push to homelab; watch the agent log for homelab/builds/1
#
# `adopt` and the create path both run step 3's check first and say so when
# no connected agent is in the cluster; they do not refuse, because the
# operator may be sequencing deliberately, but the line is there to be read.
#
# GitHub. A pipeline object builds nothing on its own: what turns a push into
# a build here is a REPO WEBHOOK on the pipeline's own deliver URL. Buildkite's
# GitHub App is installed on this account and does NOT do it -- homelab had App
# access, no hook, and nine hours of pushes that created no build (bead
# homelab-pxk, 14 Sep 2026). So this script converges the hook the same way it
# converges the pipeline, from the deliver URL the pipeline object returns, and
# prints GitHub's own recent deliveries as the proof. That step needs `gh auth
# login` once per machine; without it the hook is reported, not changed.
#
# Usage: hub-pipeline.sh <tree> [--dry-run]      ensure from hub/pipelines/<tree>.json
#        hub-pipeline.sh adopt <slug> [--dry-run] move an existing object into the cluster
#        hub-pipeline.sh agents                   name / state / cluster / queue, read-only
#        hub-pipeline.sh --token-check            scopes only; nothing written
# A dry run needs no token and sends nothing.
set -uo pipefail
ORG=isaac-karrer
API="https://api.buildkite.com/v2"
HUB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REG="${HUB_REGISTRY:-$HUB/hub/repos.psv}"
export NIX_CONFIG="experimental-features = nix-command flakes"
# shellcheck source=scripts/lib/buildkite-cluster.sh
. "$HUB/scripts/lib/buildkite-cluster.sh"
CLUSTER="$BUILDKITE_CLUSTER_ID"

USAGE="usage: $0 <tree> [--dry-run] | $0 adopt <slug> [--dry-run] | $0 agents | $0 --token-check"
MODE=ensure; TREE=""; SLUG=""; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --token-check) MODE=tokencheck ;;
    adopt) MODE=adopt; SLUG="${2:-}"; shift ;;
    agents) MODE=agents ;;
    -*) echo "$USAGE"; exit 2 ;;
    *) TREE="$1" ;;
  esac
  shift
done
case "$MODE" in
  ensure) [ -n "$TREE" ] || { echo "$USAGE"; exit 2; } ;;
  adopt)  [ -n "$SLUG" ] || { echo "$USAGE"; exit 2; }
          case "$SLUG" in *[!a-z0-9-]*) echo "slug must be [a-z0-9-]: $SLUG"; exit 2 ;; esac ;;
esac

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

# ---- the agents, as Buildkite sees them (read_agents) ------------------------
# Prints one line per agent and returns 0 only when a CONNECTED agent is in
# $CLUSTER -- the fact steps 3-5 of the sequence above depend on.
agents() {
  local code
  code=$(bk GET "$API/organizations/$ORG/agents?per_page=100")
  [ "$code" = 200 ] || { echo "  GET /agents: HTTP $code"; cat "$TMP/body"; echo; return 2; }
  echo "  name / connection_state / cluster / queue"
  jq -r '.[] | "  \(.name) / \(.connection_state) / \(.cluster_url // "" | split("/") | last // "unclustered") / \((.meta_data // []) | map(select(startswith("queue="))) | join(",") | if . == "" then "-" else . end)"' "$TMP/body"
  jq -e --arg c "$CLUSTER" '[.[] | select(.connection_state == "connected" and ((.cluster_url // "" | split("/") | last) == $c))] | length > 0' "$TMP/body" >/dev/null
}
hazard() {
  echo "== the cluster: $BUILDKITE_CLUSTER_NAME $CLUSTER =="
  echo "  Only an agent registered with a token minted for this cluster serves a"
  echo "  pipeline in it. While ac-box's agent is unclustered, every job on a"
  echo "  clustered pipeline queues and does not run: ci tenant, drainable, but"
  echo "  it stays that way until the closure with the cluster token has been"
  echo "  switched AND \`systemctl restart ac-host-ci\` has run from ssh (never"
  echo "  from a job -- modules/ci HAZARD 2). Header of this script has the order."
}
agent_check() {  # after hazard(); needs TOKEN
  echo "== agents (GET /v2/organizations/$ORG/agents) =="
  if agents; then
    echo "  a connected agent is in the cluster: jobs will run"
  else
    echo "  NO CONNECTED AGENT IN THE CLUSTER: anything clustered queues until the"
    echo "  agent reconnects with the cluster token. Proceeding because you asked;"
    echo "  the order in this script's header is what makes that a minutes-long gap."
  fi
}

# ---- the definition, checked against what the agent and the tenants assume --
if [ "$MODE" = ensure ]; then
  REMOTE=$(awk -F'|' -v r="$TREE" '$1==r{print $3}' "$REG")
  [ -n "$REMOTE" ] || { echo "unknown tree: $TREE (see $REG)"; exit 2; }
  DEF="$HUB/hub/pipelines/$TREE.json"
  [ -r "$DEF" ] || { echo "no definition: ${DEF#"$HUB"/} -- write one (copy hub/pipelines/homelab.json)"; exit 2; }
  # git@github.com:imkarrer/homelab -> imkarrer/homelab; the agent clones over
  # https (checked in its build dirs on the box: origin https://github.com/...git).
  GH=$(printf '%s' "$REMOTE" | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')
  WANT_REPO="https://github.com/$GH.git"

  echo "== definition: ${DEF#"$HUB"/} =="
  if ! jq -e --arg t "$TREE" --arg repo "$WANT_REPO" --arg c "$CLUSTER" '
      (.name == $t and .slug == $t)
      and (.repository == $repo)
      and (.cluster_id == $c)
      and (.configuration | test("buildkite-agent pipeline upload"))
      and (.configuration | test("queue: *\"?self\"?"))
      and (.provider_settings.trigger_mode == "code")
    ' "$DEF" >/dev/null; then
    echo "  REJECTED. Every definition must have, and this one does not:"
    echo "    name == slug == \"$TREE\"      (ac-host's and home-arcade's \`trigger: homelab\` steps assume the slug)"
    echo "    repository == \"$WANT_REPO\"   (from $REG; https, as the agent clones)"
    echo "    cluster_id == \"$CLUSTER\"   (lib/buildkite-cluster.sh: the one cluster the agent joins; Buildkite refuses none, and any other never gets the agent)"
    echo "    configuration with \`buildkite-agent pipeline upload\` under \`queue: self\`"
    echo "    provider_settings.trigger_mode == \"code\"   (build on push)"
    jq . "$DEF" 2>&1 | sed 's/^/    /' | head -20
    exit 1
  fi
  echo "  name/slug $TREE, repository $WANT_REPO, cluster $CLUSTER, queue=self, upload step: OK"
  echo "  configuration, decoded:"
  jq -r .configuration "$DEF" | sed '/^$/d; s/^/    | /'
fi

# ---- dry run: the exact request, and nothing sent ---------------------------
if [ $DRY -eq 1 ]; then
  echo
  echo "== dry run: nothing sent, no token read =="
  case "$MODE" in
    ensure)
      echo "POST $API/organizations/$ORG/pipelines"
      echo "Authorization: Bearer <token: not read in a dry run>"
      echo "Content-Type: application/json"
      jq . "$DEF"
      echo
      echo "on 422 (name or slug already taken):"
      echo "PATCH $API/organizations/$ORG/pipelines/$TREE   (same body)"
      echo
      echo "before either: GET $API/organizations/$ORG/agents   (is a connected agent in the cluster?)"
      echo
      echo "then, from the pipeline's provider.webhook_url, the repo hook is converged:"
      echo "  gh api repos/<owner/repo>/hooks                  (is a webhook.buildkite.com hook there?)"
      echo "  gh api -X POST|PATCH repos/<owner/repo>/hooks    (url, push + pull_request, json, active)"
      echo "  gh api repos/<owner/repo>/hooks/<id>/deliveries  (what GitHub says it delivered)"
      echo "after, read-only: GET $API/organizations/$ORG/repository_connections" ;;
    adopt)
      hazard
      echo "PATCH $API/organizations/$ORG/pipelines/$SLUG"
      echo "Authorization: Bearer <token: not read in a dry run>"
      echo "Content-Type: application/json"
      printf '{"cluster_id": "%s"}\n' "$CLUSTER"
      echo
      echo "before: GET $API/organizations/$ORG/agents   (is a connected agent in the cluster?)"
      echo "then the response's slug and cluster_id are checked: slug == $SLUG, cluster_id == $CLUSTER" ;;
    *) echo "$USAGE"; exit 2 ;;
  esac
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
need() { case " $SCOPES " in *" $1 "*) ;; *) echo "  $1 is not among them; this token cannot $2"; exit 1 ;; esac; }
case "$MODE" in
  tokencheck) exit 0 ;;
  agents) need read_agents "list agents"
          echo "== agents (GET /v2/organizations/$ORG/agents) =="
          if agents; then echo "  a connected agent is in cluster $CLUSTER"; exit 0
          else echo "  no connected agent in cluster $CLUSTER ($BUILDKITE_CLUSTER_NAME)"; exit 1; fi ;;
esac
need write_pipelines "create or update a pipeline"

# ---- adopt: an existing, unreadable object gets the cluster and nothing else -
if [ "$MODE" = adopt ]; then
  hazard
  agent_check
  printf '{"cluster_id": "%s"}' "$CLUSTER" > "$TMP/adopt.json"
  echo "== adopt $SLUG: PATCH $API/organizations/$ORG/pipelines/$SLUG {\"cluster_id\": \"$CLUSTER\"} =="
  code=$(bk PATCH "$API/organizations/$ORG/pipelines/$SLUG" "$TMP/adopt.json")
  if [ "$code" != 200 ]; then
    echo "  HTTP $code"; jq . "$TMP/body" 2>/dev/null || cat "$TMP/body"; echo
    [ "$code" = 404 ] && echo "  404: no pipeline with slug '$SLUG' in $ORG (adopt does not create; \`$0 <tree>\` does)"
    exit 1
  fi
  GOT_SLUG=$(jq -r .slug "$TMP/body"); GOT_CLUSTER=$(jq -r '.cluster_id // "null"' "$TMP/body")
  echo "  slug $GOT_SLUG, cluster_id $GOT_CLUSTER  $(jq -r .web_url "$TMP/body")"
  [ "$GOT_SLUG" = "$SLUG" ] || { echo "  SLUG MISMATCH: Buildkite answered for '$GOT_SLUG'"; exit 1; }
  [ "$GOT_CLUSTER" = "$CLUSTER" ] || { echo "  CLUSTER DID NOT TAKE: Buildkite holds '$GOT_CLUSTER', wanted $CLUSTER"; exit 1; }
  echo "  adopted: $SLUG is in $BUILDKITE_CLUSTER_NAME; its steps' queue=self resolves to the cluster's self queue"
  exit 0
fi

# ---- create, or update the slug that already exists -------------------------
hazard
agent_check
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
GOT_CLUSTER=$(jq -r '.cluster_id // "null"' "$TMP/body")
HOOK=$(jq -r '.provider.webhook_url // "?"' "$TMP/body")
PREPO=$(jq -r '.provider.settings.repository // "?"' "$TMP/body")
PMODE=$(jq -r '.provider.settings.trigger_mode // "?"' "$TMP/body")
echo "  $PATHRAN: $SLUG  $WEB"
echo "  cluster_id $GOT_CLUSTER; provider repository $PREPO, trigger_mode $PMODE"
[ "$SLUG" = "$TREE" ] || { echo "  SLUG MISMATCH: Buildkite holds '$SLUG', the trigger steps say '$TREE'"; exit 1; }
[ "$GOT_CLUSTER" = "$CLUSTER" ] || { echo "  WRONG CLUSTER: Buildkite holds '$GOT_CLUSTER', the agent joins $CLUSTER"; exit 1; }

# ---- the GitHub side: the webhook, converged like the pipeline --------------
# A pipeline object alone builds nothing. What turns a push into a build on
# this account is a REPO WEBHOOK pointing at the pipeline's own deliver URL --
# not Buildkite's GitHub App, which is installed here and does not do it: on
# 14 Sep 2026 homelab had App access and no hook, and nine hours of pushes
# created no build while ac-host, the one tree with a hook, kept building
# (bead homelab-pxk). The App may cover a repo and the pushes still go
# nowhere, so "it is in the installation list" is not a check, and the hook
# is not an operator chore to be printed and remembered. It is derived from
# the pipeline object we just read, so this script owns it exactly as it owns
# the pipeline.
#
# gh, not curl: the GitHub token stays in gh's own store and never passes
# through this script's environment or argv. `gh auth login` once per machine
# is the only manual step, and its absence is reported rather than guessed at.
echo
echo "== GitHub webhook on $GH =="
gh() { nix shell nixpkgs#gh -c gh "$@"; }

if [ "$HOOK" = "?" ] || [ -z "$HOOK" ]; then
  echo "  the pipeline object carries no provider.webhook_url; nothing to converge."
  echo "  (a pipeline whose provider is not GitHub, or a response shape that moved)"
  exit 0
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "  gh is not authenticated on this machine, so the hook cannot be checked."
  echo "  Either run once:  gh auth login --hostname github.com --git-protocol https --web"
  echo "  or add this by hand at https://github.com/$GH/settings/hooks"
  echo "  -- content type json, events push + pull_request:"
  echo "    $HOOK"
  exit 1
fi

# Match on the deliver PATH, not the whole URL: a pipeline that is deleted and
# re-created gets a new deliver id, and the hook to fix is the one already
# pointing at webhook.buildkite.com, not a second one beside it.
HOOKS="$TMP/hooks.json"
if ! gh api "repos/$GH/hooks" > "$HOOKS" 2>"$TMP/hookerr"; then
  echo "  GET repos/$GH/hooks failed:"; sed 's/^/    /' "$TMP/hookerr"
  echo "  (the gh token needs admin:repo_hook, which the 'repo' scope includes)"
  exit 1
fi
EXISTING=$(jq -r --arg u "$HOOK" '
  [ .[] | select(.config.url // "" | startswith("https://webhook.buildkite.com/")) ]
  | (map(select(.config.url == $u)) + .) | first | .id // ""' "$HOOKS")
CUR=$(jq -r --arg i "$EXISTING" '.[] | select((.id|tostring) == $i) | .config.url // ""' "$HOOKS")

if [ -z "$EXISTING" ]; then
  echo "  no Buildkite hook on this repo; creating one"
  if gh api -X POST "repos/$GH/hooks" -f name=web -F active=true \
       -f 'events[]=push' -f 'events[]=pull_request' \
       -f "config[url]=$HOOK" -f 'config[content_type]=json' -f 'config[insecure_ssl]=0' \
       > "$TMP/hookout" 2>"$TMP/hookerr"; then
    echo "  created hook $(jq -r .id "$TMP/hookout") -> $HOOK"
  else
    echo "  create failed:"; sed 's/^/    /' "$TMP/hookerr"; exit 1
  fi
else
  echo "  hook $EXISTING exists -> $CUR"
  # One PATCH, whether or not the URL moved: active and the two events matter
  # as much as the URL -- a hook that is inactive, or subscribed to nothing
  # this pipeline reacts to, is the same outage with a row in the UI. The
  # whole config goes every time because GitHub rejects a config patch that
  # omits url ("url cannot be blank", 422), so there is no partial form to
  # prefer.
  [ "$CUR" = "$HOOK" ] || echo "  it points at a different pipeline's deliver URL; repointing to $HOOK"
  gh api -X PATCH "repos/$GH/hooks/$EXISTING" -F active=true \
    -f 'events[]=push' -f 'events[]=pull_request' \
    -f "config[url]=$HOOK" -f 'config[content_type]=json' -f 'config[insecure_ssl]=0' \
    >/dev/null 2>"$TMP/hookerr" || { echo "  update failed:"; sed 's/^/    /' "$TMP/hookerr"; exit 1; }
  echo "  active, events push + pull_request, content type json, url $HOOK: OK"
fi

# What GitHub says it did with the last few deliveries. This is the one place
# the whole chain is visible from: a 2xx here with no build means Buildkite
# dropped it, a non-2xx means the URL or the pipeline is wrong, and nothing
# listed means the hook has never fired.
echo "  recent deliveries:"
if gh api "repos/$GH/hooks/${EXISTING:-$(jq -r '.[0].id // ""' "$TMP/hookout" 2>/dev/null)}/deliveries" \
     > "$TMP/deliv" 2>/dev/null; then
  jq -r '.[0:3][] | "    \(.delivered_at)  \(.event) -> \(.status) \(.status_code)"' "$TMP/deliv"
  jq -e 'length > 0' "$TMP/deliv" >/dev/null || echo "    none yet -- the next push is the proof"
else
  echo "    none yet -- the next push is the proof"
fi

# read_organization_repository_connections: lists the App(s), not their repos.
# Kept because a repo reachable BOTH ways is worth seeing; the hook above is
# what actually delivers.
echo
echo "== GitHub App connections the org has (informational) =="
code=$(bk GET "$API/organizations/$ORG/repository_connections")
if [ "$code" = 200 ]; then
  for id in $(jq -r '.[].id' "$TMP/body"); do
    if [ "$(bk GET "$API/organizations/$ORG/repository_connections/$id")" = 200 ]; then
      jq -r '"  \(.type): \(.display_name), account \(.service_account.login // "-"), \(.host.url // "-")"' "$TMP/body"
    fi
  done
else
  echo "  (repository_connections: HTTP $code; not listed)"
fi
