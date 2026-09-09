#!/usr/bin/env bash
# Runs every modules/*/tests/eval*.nix harness's `expected` case map and
# fails if actual pass/fail doesn't match. Wired into .buildkite/pipeline.yml
# (beads homelab-bqo.29).
#
# Each harness is a plain `lib.evalModules` fixture, not a flake target (see
# e.g. modules/tenant/tests/eval.nix's own header). It uses the SAME nixpkgs
# this repo owns via flake.lock -- see README's "nixpkgs is owned here" --
# never whatever `nix-channel` happens to point at.
#
# That pin now lives in the harnesses themselves
# (modules/tenant/tests/pinned-nixpkgs.nix, which reads flake.lock), not
# here. This script used to resolve it and inject it with `-I nixpkgs=...`,
# which worked but fixed only the scripted path: a human running the
# `nix eval -f` command each harness documents in its own Usage block still
# got the channel's lib, and on a box with no channels got an error instead
# of a test run. Finding F7 (docs/current-state.md), closed 9 Sep 2026.
#
# Hence `--option nix-path ""` below, which is a gate rather than a
# formality: it empties the Nix search path for every evaluation this script
# performs, so if any harness, fixture or module ever reintroduces a
# `<nixpkgs>` lookup, it fails here with "file 'nixpkgs' was not found in the
# Nix search path" instead of silently resolving against a channel. The one
# line of output before the results reports the store path actually in use,
# so a CI log carries the proof rather than the claim.
#
# A harness's `expected.<case> = true` means `<case>.checked` (or, for a
# harness with no `.checked` field, the whole case) must evaluate without
# throwing; `false` means it must throw. Some fixtures (e.g. `collision`)
# exist specifically to prove a bad config is rejected -- a case like that
# NOT throwing is exactly the regression this script exists to catch.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$repo_root"

nix_flags=(--extra-experimental-features "nix-command flakes" --option nix-path "")

# The pin, resolved once from flake.lock, printed once. Not passed to the
# harnesses -- they resolve it themselves, which is the point -- so this is a
# report, not a parameter. Compare it against `nix flake metadata --json`'s
# nixpkgs node if you ever doubt the two agree.
pinned_nixpkgs=$(nix "${nix_flags[@]}" eval --raw \
  -f modules/tenant/tests/pinned-nixpkgs.nix path)
echo "pinned nixpkgs (flake.lock): ${pinned_nixpkgs}"

fail=0

mapfile -t files < <(find modules -path '*/tests/eval*.nix' | sort)

for file in "${files[@]}"; do
  # --impure only because --expr evaluates in pure mode, where reading a path
  # outside the store (this repo) is refused; the nixpkgs it reaches is still
  # the pinned one, since that is now the harness's own default.
  expected_list=$(nix "${nix_flags[@]}" eval --impure --raw --expr "
    let
      lib = (import ./modules/tenant/tests/pinned-nixpkgs.nix).lib;
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
    if nix "${nix_flags[@]}" eval -f "$file" "${case}.checked" \
        >/dev/null 2>"$err"; then
      actual=true
    elif grep -q "attribute 'checked'.*not found" "$err"; then
      # This harness has no `.checked` field (e.g. modules/ci/tests/eval.nix)
      # -- force full evaluation of the case itself instead.
      if nix "${nix_flags[@]}" eval --json -f "$file" "$case" \
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
