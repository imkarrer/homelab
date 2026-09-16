#!/usr/bin/env bash
# Run a tree's skill evals: does each SKILL.md fire when it should, stay quiet
# when it should not, and say the right thing when it does?
#
# Usage: hub-evals.sh [repo|path] [caliper args...]   default: the tree you are standing in, --k 3
#        hub-evals.sh --init [repo|path]              scaffold a spec from the tree's skills
#
# The gate (hub-gates.sh) proves the Nix evaluates. Nothing proved the skills
# discriminate -- five descriptions that all mention pushing can collapse onto
# one another, and the only way to see it is to run a real agent and watch
# which one it reaches for. That is what caliper does: k attempts per task,
# each a `claude -p` in a throwaway HOME with only these skills installed.
#
# EVERY ATTEMPT RUNS WITH --dangerously-skip-permissions.
# caliper isolates HOME, not the filesystem (harness/claude_code.py hardcodes
# the flag), so an attempt would otherwise run as you, with your write access
# to every tree on this box -- and these skills cite /home/nixos/src/... by
# absolute path, so an agent reaches the real repo whether or not the prompt
# mentions it. This script therefore never invokes the CLI directly: it
# generates a bwrap wrapper that binds / read-only, and puts that first on
# PATH for the run. Reads still work (a skill that says "run hub-status.sh"
# is still testable); writes cannot land.
set -uo pipefail

# readlink -f, not $BASH_SOURCE alone: this script is meant to be reached
# through a symlink on PATH (~/.local/bin/hub-evals), and dirname of the LINK
# resolves the hub to ~/.local -- so the registry is not found and every repo
# name is "unknown". Every other hub-*.sh carries the unresolved idiom and
# breaks the same way if linked (bead homelab-dfc).
HUB="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
REG="${HUB_REGISTRY:-$HUB/hub/repos.psv}"
VENV="${CALIPER_VENV:-$HOME/.local/share/caliper-venv}"

INIT=0
[ "${1:-}" = "--init" ] && { INIT=1; shift; }

# The tree: a registry name, a path, or -- standing in any repo with no
# argument at all -- the git toplevel of $PWD. That last form is the point:
# one command, any homelab tree, no argument to remember.
ARG="${1:-}"; [ $# -gt 0 ] && shift
if [ -z "$ARG" ] || [ "$ARG" = "." ]; then
  TREE=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "not in a git repo, and no repo named: pass a registry name (see $REG)"; exit 2; }
elif [ -d "$ARG" ]; then
  TREE=$(cd "$ARG" && pwd)
else
  TREE=$(awk -F'|' -v r="$ARG" '$1==r{print $2}' "$REG")
  [ -n "$TREE" ] || { echo "unknown repo: $ARG (see $REG)"; exit 2; }
fi
NAME=$(basename "$TREE")

# Skills live in .agents/ and .claude/skills is a symlink to it (AGENTS.md:26 --
# harness-agnostic source of truth). Prefer .agents/ so a tree that has both
# is not evaluated twice over the same files; fall back for a tree that has
# only the Claude Code layout.
if [ -d "$TREE/.agents/skills" ]; then SKILLS="$TREE/.agents/skills"; EVALS="$TREE/.agents/evals"
elif [ -d "$TREE/.claude/skills" ]; then SKILLS="$TREE/.claude/skills"; EVALS="$TREE/.claude/evals"
else
  echo "== skill evals: $NAME =="
  echo "  no .agents/skills or .claude/skills in $TREE -- nothing to evaluate."
  echo "  NOT a failure: most trees carry no skills. Today only homelab does."
  exit 0
fi

# Trailing slash: .claude/skills is a symlink into .agents/ and find will not
# descend a symlinked start point without it.
mapfile -t SKILL_FILES < <(find "$SKILLS/" -mindepth 2 -maxdepth 2 -name SKILL.md | sort)
[ ${#SKILL_FILES[@]} -gt 0 ] || { echo "$SKILLS exists but holds no <name>/SKILL.md"; exit 2; }

# --init: one trigger probe per skill, prompts left as TODO. A generated prompt
# would be a guess at what should fire the skill, and a guess that runs looks
# like evidence -- so the runner below refuses any spec still carrying a TODO.
if [ $INIT -eq 1 ]; then
  mkdir -p "$EVALS"
  SPEC="$EVALS/$NAME-skills.eval.yaml"
  [ -e "$SPEC" ] && { echo "already exists: $SPEC"; exit 2; }
  {
    echo "# Skill evals for $NAME. Run: bash $HUB/scripts/hub-evals.sh   (from this tree)"
    echo "#"
    echo "# Each task is one prompt. \`activates:\` asserts the exact set of skills"
    echo "# the agent reached for -- [] means nothing should fire. \`expect:\` adds an"
    echo "# LLM judge over the transcript; \`assert:\` adds a Python assertion."
    echo "# Replace every TODO before running: this file will not run until you do."
    echo "skills:"
    for f in "${SKILL_FILES[@]}"; do echo "  - ../skills/$(basename "$(dirname "$f")")/SKILL.md"; done
    echo
    echo "tasks:"
    for f in "${SKILL_FILES[@]}"; do
      s=$(basename "$(dirname "$f")")
      echo "  - name: A $s prompt reaches $s"
      echo "    prompt: \"TODO: something a user would actually say, phrased as a question --"
      echo "      an order sends the agent off to DO the work and time out.\""
      echo "    activates: [$s]"
      echo
    done
    echo "  - name: Unrelated work, silence expected"
    echo "    prompt: \"Rename resolved_model to engine_model across this repo.\""
    echo "    activates: []"
  } > "$SPEC"
  echo "wrote $SPEC -- replace the TODOs, then: bash $HUB/scripts/hub-evals.sh $TREE"
  exit 0
fi

mapfile -t SPECS < <(find "$EVALS" -maxdepth 1 -name '*.eval.yaml' 2>/dev/null | sort)
if [ ${#SPECS[@]} -eq 0 ]; then
  echo "== skill evals: $NAME =="
  echo "  ${#SKILL_FILES[@]} skill(s) in $SKILLS, but no spec in $EVALS."
  echo "  A skill with no eval is ungated, not passing. Scaffold one:"
  echo "    bash $HUB/scripts/hub-evals.sh --init $TREE"
  exit 2
fi
for s in "${SPECS[@]}"; do
  grep -q 'TODO' "$s" && { echo "$s still carries a TODO prompt -- fill it in first."; exit 2; }
done

# caliper is a pip package and this box has no system python; the venv is
# created once and reused. Bootstrapping here rather than in a setup doc is
# deliberate: an eval you have to install before you can run is an eval that
# does not get run.
if [ ! -x "$VENV/bin/caliper" ]; then
  echo "== bootstrapping caliper into $VENV =="
  NIX_CONFIG="extra-experimental-features = nix-command flakes" \
    nix shell nixpkgs#python312 -c python3 -m venv "$VENV" || exit 2
  "$VENV/bin/pip" install -q caliper-eval || exit 2
fi

# Upstream bug, re-applied after every install because pip overwrites it:
# snapshot_skill() walks the companion files a SKILL.md cites and calls
# relative_to() on each, which RAISES for a path outside the skill's own
# directory. homelab-hub cites /home/nixos/src/homelab/scripts/hub-status.sh,
# so caliper crashes before the first attempt. Skip what is not a companion.
"$VENV/bin/python" - "$VENV" <<'PATCH' || exit 2
import sys, glob
from pathlib import Path
hits = glob.glob(f"{sys.argv[1]}/lib/python3.*/site-packages/caliper/skillsnapshot.py")
if not hits: sys.exit("caliper not found in venv")
f = Path(hits[0]); s = f.read_text()
if "is_relative_to(path.parent)" in s: sys.exit(0)
old = "        if referenced.exists() and referenced != path:\n"
new = ("        if (\n            referenced.exists()\n            and referenced != path\n"
       "            and referenced.is_relative_to(path.parent)\n        ):\n")
if s.count(old) != 1: sys.exit("caliper changed shape; re-check the skillsnapshot patch")
f.write_text(s.replace(old, new))
PATCH

command -v bwrap >/dev/null || {
  echo "bwrap (bubblewrap) is not installed, and without it every attempt could"
  echo "write to your trees. Refusing to run unsandboxed. Install it with:"
  echo "    nix profile add nixpkgs#bubblewrap"
  exit 2; }

# The real CLI, resolved not pinned: the desktop app ships it under a version
# directory that changes on every update, and a pinned path breaks silently
# on the next one. Newest wins; an installed `claude` on PATH is preferred if
# there is one, and the sandbox dir is not yet on PATH so this cannot find
# the wrapper we are about to write.
REAL_CLAUDE="${CALIPER_REAL_CLAUDE:-$(command -v claude 2>/dev/null)}"
# A `claude` on PATH that is itself a bwrap wrapper would nest sandboxes and
# bind the OUTER attempt's HOME -- so refuse it and fall through to the real
# binary. Cheap insurance against someone putting a wrapper dir on PATH for good.
if [ -n "$REAL_CLAUDE" ] && head -c 4096 "$REAL_CLAUDE" 2>/dev/null | grep -q '^exec bwrap'; then
  REAL_CLAUDE=""
fi
[ -n "$REAL_CLAUDE" ] || REAL_CLAUDE=$(ls -d "$HOME"/.claude/remote/ccd-cli/* 2>/dev/null | sort -V | tail -1)
[ -x "$REAL_CLAUDE" ] || { echo "no claude CLI found; set CALIPER_REAL_CLAUDE"; exit 2; }

SBX=$(mktemp -d); trap 'rm -rf "$SBX"' EXIT

# OAuth. The CLI refreshes an expired token and writes the new one back to
# ~/.claude/.credentials.json -- but an attempt runs with / read-only and a
# COPY of that file in its throwaway HOME, so a refresh made inside an attempt
# dies with the HOME, while the single-use refresh token it consumed is now
# dead in the real file too. Three parallel attempts on an expired token: two
# "could not be refreshed", one wins, and the CLI is logged out for good
# afterwards (15 Sep). So the token is refreshed HERE, unsandboxed, with the
# real HOME, before the first attempt copies it: one haiku call. A run then
# starts on a fresh token and never needs to refresh inside the sandbox.
PING=$(cd "$SBX" && timeout 120 "$REAL_CLAUDE" -p "Reply with exactly: OK" \
  --model claude-haiku-4-5-20251001 --output-format json 2>&1)
if ! printf '%s' "$PING" | grep -q '"is_error":false'; then
  echo "the claude CLI cannot reach the API, so no attempt could either:"
  printf '%s\n' "$PING" | grep -oE '"result":"[^"]*"' | head -1 | sed 's/^/  /'
  echo "  log in again:  $REAL_CLAUDE auth login"
  exit 2
fi
cat > "$SBX/claude" <<WRAPPER
#!/usr/bin/env bash
# / is read-only. The holes are the two places an attempt legitimately writes:
# its own isolated HOME (caliper's per-attempt tempdir, handed to us as \$HOME)
# and /tmp, where a task's setup:/cleanup: fixtures live.
exec bwrap \\
  --ro-bind / / \\
  --proc /proc \\
  --dev /dev \\
  --bind /tmp /tmp \\
  --bind "\$HOME" "\$HOME" \\
  --die-with-parent \\
  -- "$REAL_CLAUDE" "\$@"
WRAPPER
chmod +x "$SBX/claude"

echo "== skill evals: $NAME =="
echo "  ${#SKILL_FILES[@]} skills, ${#SPECS[@]} spec(s), sandboxed: / read-only"
echo "  CLI: $REAL_CLAUDE"

# "${@:---k 3}" would pass the default as ONE argument; caliper wants two.
ARGS=("$@"); [ ${#ARGS[@]} -eq 0 ] && ARGS=(--k 3)

RC=0
for spec in "${SPECS[@]}"; do
  echo "== $(basename "$spec") =="
  PATH="$SBX:$PATH" "$VENV/bin/caliper" run "$spec" "${ARGS[@]}" || RC=1
done
exit $RC
