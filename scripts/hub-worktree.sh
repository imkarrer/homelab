#!/usr/bin/env bash
# One worktree per worker, so parallel sessions never share a working tree.
# 13 Sep 2026: two sessions edited docs/architecture.md in the same checkout
# and one's commit swept up the other's half-finished stamps. A worktree
# gives each worker its own index; the supervisor merges branches, not files.
#
# Worktrees live OUTSIDE every registered tree, so hub-status.sh's dirty and
# untracked counts for a tree stay about that tree; unmerged worktree
# branches get their own verdict line there instead.
#
# Usage: hub-worktree.sh add  <repo> <name>   # prints the worktree path
#        hub-worktree.sh rm   <repo> <name>   # refuses while dirty; keeps the branch while unmerged
#        hub-worktree.sh list [repo]
# Branch is wt/<name>, cut from the tree's current main. Gate a worktree with
#   hub-gates.sh <repo> <path>
set -uo pipefail
HUB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REG="${HUB_REGISTRY:-$HUB/hub/repos.psv}"
ROOT="${HUB_WORKTREES:-$(dirname "$HUB")/.worktrees}"

usage() { sed -n '11,15p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
tree_path() {
  local p; p=$(awk -F'|' -v r="$1" '$1==r{print $2}' "$REG")
  [ -n "$p" ] || { echo "unknown repo: $1 (see $REG)" >&2; exit 2; }
  echo "$p"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  add)
    [ $# -eq 2 ] || usage
    repo=$1; name=$2; path=$(tree_path "$repo"); wt="$ROOT/$repo/$name"
    [ -e "$wt" ] && { echo "exists: $wt" >&2; exit 1; }
    mkdir -p "$(dirname "$wt")"
    git -C "$path" worktree add -q -b "wt/$name" "$wt" main || exit 1
    echo "$wt"
    ;;
  rm)
    [ $# -eq 2 ] || usage
    repo=$1; name=$2; path=$(tree_path "$repo"); wt="$ROOT/$repo/$name"
    [ -d "$wt" ] || { echo "no worktree: $wt" >&2; exit 1; }
    n=$(git -C "$wt" status --porcelain 2>/dev/null | wc -l)
    [ "$n" = 0 ] || { echo "refusing: $n uncommitted change(s) in $wt" >&2; exit 1; }
    # -d, never -D: git refuses to delete a branch main does not contain,
    # which is exactly the work this script exists to keep from being lost.
    git -C "$path" worktree remove "$wt" || exit 1
    git -C "$path" branch -d "wt/$name" || { echo "worktree gone, branch wt/$name kept: unmerged" >&2; exit 1; }
    ;;
  list)
    while IFS='|' read -r name path _; do
      case "$name" in ''|\#*) continue ;; esac
      [ $# -eq 0 ] || [ "$1" = "$name" ] || continue
      git -C "$path" worktree list --porcelain 2>/dev/null | awk -v n="$name" '
        /^worktree /{w=$2} /^branch /{b=$2; sub("refs/heads/","",b)}
        /^$/{ i++; if (i>1) printf "%-12s %-24s %s\n", n, b, w; w=""; b="" }
        END{ if (w!="") { i++; if (i>1) printf "%-12s %-24s %s\n", n, b, w } }'
    done < "$REG"
    ;;
  *) usage ;;
esac
