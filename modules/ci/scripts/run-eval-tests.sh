#!/usr/bin/env bash
# Builds every eval-harness flake check (checks.<system>.eval-*) and prints
# its per-case report. A human's front-end over the same case table `nix
# flake check` gates on; it decides nothing itself.
#
# HISTORY, because the shape changed. Until 12 Sep 2026 this script WAS the
# gate: it walked modules/*/tests/eval*.nix with `find`, read each harness's
# `expected` map, ran one `nix eval` per case and compared "did it throw?"
# against the map -- and .buildkite/pipeline.yml ran it as its own named
# step, because `nix flake check` on the host config alone cannot prove a
# colliding fixture is still rejected (ac-box has no collision to reject).
# The harnesses are flake checks now (modules/tenant/tests/check.nix, which
# also owns the eval*.nix discovery this script used to do with `find`), so
# the pipeline's `nix flake check -L` step covers all of them and the
# separate step is gone. Two things made keeping a script worth it:
#
#   1. Per-case output. `nix flake check` prints a check's report only when
#      it builds, and the report derivation is a cache hit on a steady tree.
#      A failure still names the case (the inversion throws at evaluation,
#      before anything builds), but "all 23 cases, listed" is what a human
#      wants after touching a fixture, and that is what this prints.
#   2. One verdict spelling. The old loop re-derived pass/throw from the
#      `expected` map in shell -- a second reader of that encoding next to
#      check.nix, which README's Pinned conventions forbid. This script has
#      no such logic left: it builds the check and cats $out.
#
# The `--option nix-path ""` gate this script used to carry is now implicit:
# a flake evaluates in pure mode, where `<nixpkgs>` is an error regardless
# of NIX_PATH, so a reintroduced lookup dies in `nix flake check` itself.
# The pinned-nixpkgs path this script used to print is the second line of
# every report; check.nix asserts it equals the flake's own input.
#
# A flake sees only tracked files: a new harness must be `git add`ed before
# either this script or `nix flake check` can see it. `find` saw untracked
# files; this deliberately does not.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$repo_root"

nix_flags=(--extra-experimental-features "nix-command flakes")

# --impure only for currentSystem; nothing below reads the environment.
system=$(nix "${nix_flags[@]}" eval --impure --raw --expr builtins.currentSystem)

# The eval-* checks only. checks.<system>.ac-box is the full system
# toplevel, minutes rather than seconds, and not this script's job.
mapfile -t checks < <(nix "${nix_flags[@]}" eval --raw ".#checks.${system}" --apply '
  c: builtins.concatStringsSep "\n" (builtins.filter (n: builtins.substring 0 5 n == "eval-") (builtins.attrNames c))
' 2>/dev/null | sort)

if [ "${#checks[@]}" -eq 0 ]; then
  echo "no eval-* checks found under checks.${system} -- see modules/tenant/tests/check.nix" >&2
  exit 1
fi

fail=0
for name in "${checks[@]}"; do
  # A failing case is an evaluation error here, with the case named in its
  # context and the harness's own assertion text underneath -- printed by
  # nix, not reformatted by this script.
  err="$(mktemp)"
  if out=$(nix "${nix_flags[@]}" build --no-link --print-out-paths ".#checks.${system}.${name}" 2>"$err"); then
    cat "$out"
    echo
  else
    grep -v '^warning: Git tree' "$err" >&2
    echo "FAIL  ${name}" >&2
    fail=1
  fi
  rm -f "$err"
done

exit "$fail"
