#!/usr/bin/env bash
# Runs every modules/*/tests/eval*.nix harness's `expected` case map and
# fails if actual pass/fail doesn't match. Wired into .buildkite/pipeline.yml
# (beads homelab-bqo.29).
#
# Each harness is a plain `lib.evalModules` fixture, not a flake target (see
# e.g. modules/tenant/tests/eval.nix's own header) -- <nixpkgs> is resolved
# by hand below rather than left to NIX_PATH/channels, which a CI sandbox has
# no reason to have configured. Pinned to the SAME nixpkgs this repo already
# owns via flake.lock -- see README's "nixpkgs is owned here" -- never
# whatever `nix-channel` happens to point at.
#
# A harness's `expected.<case> = true` means `<case>.checked` (or, for a
# harness with no `.checked` field, the whole case) must evaluate without
# throwing; `false` means it must throw. Some fixtures (e.g. `collision`)
# exist specifically to prove a bad config is rejected -- a case like that
# NOT throwing is exactly the regression this script exists to catch.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$repo_root"

nix_flags=(--extra-experimental-features "nix-command flakes")

nixpkgs_path=$(nix "${nix_flags[@]}" eval --impure --raw --expr \
  '(builtins.getFlake (toString ./.)).inputs.nixpkgs.outPath')

fail=0

mapfile -t files < <(find modules -path '*/tests/eval*.nix' | sort)

for file in "${files[@]}"; do
  expected_list=$(nix "${nix_flags[@]}" eval -I "nixpkgs=${nixpkgs_path}" --impure --raw --expr "
    let
      lib = (import <nixpkgs> { }).lib;
      expected = (import ./${file} { }).expected;
    in
    lib.concatStringsSep \"\n\" (lib.mapAttrsToList (k: v: \"\${k}\t\${if v then \"true\" else \"false\"}\") expected)
  " 2>/dev/null) || {
    echo "SKIP (no expected map): ${file}"
    continue
  }

  while IFS=$'\t' read -r case expect; do
    [ -z "$case" ] && continue

    err="$(mktemp)"
    if nix "${nix_flags[@]}" eval -I "nixpkgs=${nixpkgs_path}" -f "$file" "${case}.checked" \
        >/dev/null 2>"$err"; then
      actual=true
    elif grep -q "attribute 'checked'.*not found" "$err"; then
      # This harness has no `.checked` field (e.g. modules/ci/tests/eval.nix)
      # -- force full evaluation of the case itself instead.
      if nix "${nix_flags[@]}" eval -I "nixpkgs=${nixpkgs_path}" --json -f "$file" "$case" \
          >/dev/null 2>"$err"; then
        actual=true
      else
        actual=false
      fi
    else
      actual=false
    fi

    if [ "$actual" = "$expect" ]; then
      echo "ok    ${file} :: ${case} (expected ${expect})"
    else
      echo "FAIL  ${file} :: ${case} (expected ${expect}, got ${actual})"
      cat "$err" >&2
      fail=1
    fi
    rm -f "$err"
  done <<< "$expected_list"
done

exit "$fail"
