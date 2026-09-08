#!/usr/bin/env bash
# Regenerate hub/trees/* -- navigable links into the sibling source trees.
# Machine-local (gitignored): hub/repos.psv is the portable truth.
set -uo pipefail
HUB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REG="${HUB_REGISTRY:-$HUB/hub/repos.psv}"
mkdir -p "$HUB/hub/trees"
while IFS='|' read -r name path remote deploy push; do
  case "$name" in ''|\#*) continue ;; esac
  [ "$name" = homelab ] && continue      # self-link would be a recursion trap
  [ -d "$path" ] || { echo "skip $name (no tree at $path)"; continue; }
  ln -sfn "../../../$name" "$HUB/hub/trees/$name" && echo "$name -> $path"
done < "$REG"
