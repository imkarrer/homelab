#!/usr/bin/env bash
# Bump one flake input to its tip and push the lock, so a tenant push reaches
# the box. Closes docs/architecture.md Part III row 24: "push to tenant ->
# deployed" was false for home-arcade, agent-hub and ac-host's .nix module,
# because they reach ac-box only through homelab's closure, and the closure
# only moves when flake.lock does.
#
# Runs as a Buildkite step in homelab's pipeline when a TENANT pipeline
# triggers a homelab build on green (a `trigger: homelab` step behind that
# tenant's `wait: ~`, carrying HOMELAB_BUMP_INPUT). It may also be run by
# hand from a WSL checkout with the same variables. It is the third stage in
# a chain that already exists:
#
#   tenant push -> tenant gates green -> [this] lock bump pushed to homelab
#     -> homelab gates green -> queue-closure stages the sha
#     -> homelab-deploy.timer switches at 03:30, deferring if anyone is racing
#
# Nothing here touches the box. The lobbies are not in this script's blast
# radius at all: the only thing that ever restarts a race server is the
# tenant tree's 03:00 recycle, and the closure switch cannot (ac-host-static
# is restartIfChanged = false). What this script changes is a file in git.
#
# Same posture as hub-queue-closure.sh: skip, with a message, when the
# credential that makes it meaningful is absent. HOMELAB_PUSH_TOKEN is a
# GitHub token with contents:write on imkarrer/homelab and nothing else;
# ac-host's compose/docker-compose.buildkite.yml passes it into the agent
# from .env.buildkite. While it is unset every trigger is a green no-op, so
# provisioning the token IS the enabling decision -- the same shape as
# homelab.deploy.enable, and it belongs to the operator for the same reason:
# once it is set, a tenant push is, three hops later, a system switch.
#
# The gate is real: `nix flake check` runs on the bumped lock BEFORE the push,
# so a tenant tip that breaks the composition never lands on main. The
# pushed commit then gets homelab's ordinary build, which is what stages it.
set -euo pipefail
# flake.nix declares nixConfig (the flox cache substituter). Without
# accept-flake-config every `nix flake` command here asks "do you want to
# allow configuration setting ... (y/N)?" -- a real prompt under Buildkite's
# PTY, which nobody answers: on 18 Sep 2026 `nix flake update` sat in
# n_tty_read for 25 minutes holding the only agent. hub-gates.sh passes
# --accept-flake-config per call; this covers update and check alike.
export NIX_CONFIG="experimental-features = nix-command flakes
accept-flake-config = true"

HUB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HUB"

INPUT="${HOMELAB_BUMP_INPUT:-}"
WANT="${HOMELAB_BUMP_REV:-}"        # optional: the sha the tenant build proved green
TOKEN="${HOMELAB_PUSH_TOKEN:-}"
REMOTE="${HOMELAB_PUSH_REMOTE:-https://github.com/imkarrer/homelab}"
BRANCH="${HOMELAB_PUSH_BRANCH:-main}"

if [ -z "$INPUT" ]; then
  echo "refuse bump-lock: HOMELAB_BUMP_INPUT is not set (which input?)" >&2
  exit 1
fi

# Reads of flake.lock go through nix itself, not jq: nix is the one tool the
# agent image is guaranteed to carry, since the pipeline's other step is
# `nix flake check`. An input NAME maps to a lock NODE via root.inputs, and
# the two can differ, so the rev is read off the node, never off the name.
lock_inputs() {
  nix eval --impure --raw --expr \
    'builtins.concatStringsSep " " (builtins.attrNames (builtins.fromJSON (builtins.readFile ./flake.lock)).nodes.root.inputs)'
}
locked_rev() {
  nix eval --impure --raw --expr "
    let l = builtins.fromJSON (builtins.readFile ./flake.lock);
        node = l.nodes.root.inputs.\"$1\";
    in l.nodes.\"\${node}\".locked.rev or \"\""
}

# Only inputs the flake actually declares. A typo in a tenant's trigger step
# must be a loud refusal here, not a `nix flake update` that quietly does
# nothing and reports success.
case " $(lock_inputs) " in
  *" $INPUT "*) ;;
  *)
    echo "refuse bump-lock: '$INPUT' is not an input of this flake" >&2
    echo "  inputs: $(lock_inputs)" >&2
    exit 1 ;;
esac

if [ -z "$TOKEN" ]; then
  echo "skip bump-lock: HOMELAB_PUSH_TOKEN is not set; $INPUT stays at its locked rev"
  echo "  (set it in ac-host's .env.buildkite on the box and recreate the agent;"
  echo "   see docs/architecture.md Part III row 24)"
  exit 0
fi

# Bump against the tip of the branch, not the commit Buildkite checked out.
# A triggered build checks out whatever homelab main was when the trigger
# fired; if another bump landed in between, committing on top of the stale
# checkout would be a non-fast-forward push (refused below) or, worse, a
# merge. Re-basing on origin's tip first makes the common case a clean push.
git fetch --quiet origin "$BRANCH"
git checkout --quiet -B "$BRANCH" "origin/$BRANCH"

before=$(locked_rev "$INPUT")
nix flake update "$INPUT"
after=$(locked_rev "$INPUT")

if git diff --quiet -- flake.lock; then
  echo "bump-lock: $INPUT already at ${after:0:7}; nothing to push"
  exit 0
fi

# Advisory, not a gate. The trigger names the sha its build proved green;
# the lock resolves to the branch tip, which is later if two tenant pushes
# raced. Last wins, exactly as queue-prod and queue-closure behave, and the
# later sha has its own green build behind it or its trigger would not fire.
if [ -n "$WANT" ] && [ "$WANT" != "$after" ]; then
  echo "bump-lock: note: trigger named ${WANT:0:7}, tip is ${after:0:7}; taking the tip (last wins)"
fi

echo "bump-lock: $INPUT ${before:0:7} -> ${after:0:7}; running the gates before pushing"
nix flake check -L

msg="flake.lock: $INPUT ${before:0:7} -> ${after:0:7}

Automatic bump on a green $INPUT build${BUILDKITE_BUILD_URL:+ ($BUILDKITE_BUILD_URL)}.
Pushed by scripts/hub-bump-lock.sh; staged for the box by this commit's own
build (queue-closure) and applied by homelab-deploy.timer in the window."

git -c user.name="homelab bump-lock" \
    -c user.email="bump-lock@ac-box.invalid" \
    commit --quiet -m "$msg" -- flake.lock

# The token never appears on a command line or in a URL, so it cannot leak
# into the build log or `ps`. git asks the helper, the helper reads the env.
git -c credential.helper= \
    -c credential.helper='!f() { echo "username=x-access-token"; echo "password=$HOMELAB_PUSH_TOKEN"; }; f' \
    push "$REMOTE" "HEAD:refs/heads/$BRANCH"

echo "bump-lock: pushed $(git rev-parse --short HEAD) to $BRANCH"
echo "  homelab's build of that commit stages it; homelab-deploy.timer applies it at the next window"
