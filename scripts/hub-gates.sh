#!/usr/bin/env bash
# Run the gates Buildkite will run, locally, before pushing.
# queue-prod sits behind `wait: ~`, so a red gate blocks every deploy --
# catching it here costs seconds, catching it in CI costs a stalled pipeline.
# Usage: hub-gates.sh [repo]   (default: ac-host)
set -uo pipefail
export NIX_CONFIG="experimental-features = nix-command flakes"

HUB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REG="${HUB_REGISTRY:-$HUB/hub/repos.psv}"
REPO="${1:-ac-host}"
PATHX=$(awk -F'|' -v r="$REPO" '$1==r{print $2}' "$REG")
[ -n "$PATHX" ] || { echo "unknown repo: $REPO (see $REG)"; exit 2; }
cd "$PATHX" || exit 2

# flox pinned to the version in the CI agent container: a lock written by a
# newer flox can be unreadable there, which breaks CI instead of fixing it.
FLOX_PIN="github:flox/flox/v1.14.0#packages.x86_64-linux.flox"
# Prefer the pin over whatever is on PATH: this box carries a newer flox than
# the agent container, and the point is to match the box, not the laptop.
find_flox() {
  local p
  p=$(nix build --no-link --print-out-paths --accept-flake-config "$FLOX_PIN" 2>/dev/null | tail -1)
  if [ -n "$p" ]; then echo "$p/bin/flox"; return; fi
  command -v flox 2>/dev/null
}

RC=0
# Gates that could not run at all. Kept apart from RC on purpose: "this gate
# went red" and "this gate never ran" are different facts, and collapsing them
# is how a skipped gate came to look like a passed one. Nothing here is silent
# -- the summary at the bottom lists every entry and refuses to print a bare
# GATES PASS while the list is non-empty.
SKIPPED=()

FLOX_MISSING=""
if [ -f .flox/env/manifest.toml ]; then
  # A tree can track a manifest without carrying a materialized environment.
  # ac-host tracks .flox/env.json and .flox/env/manifest.lock; home-arcade
  # tracks only manifest.toml, so flox refuses to activate ("unable to locate
  # an 'env.json'"). That is a missing local environment, not a red test --
  # CI's flox plugin builds the environment from the manifest itself. Reporting
  # it as FAIL is what made `hub-gates.sh home-arcade` read as a broken tree
  # rather than an ungated one, which is the whole defect this file is fixing.
  [ -f .flox/env.json ] || FLOX_MISSING="$FLOX_MISSING .flox/env.json"
  [ -f .flox/env/manifest.lock ] || FLOX_MISSING="$FLOX_MISSING .flox/env/manifest.lock"
fi

if [ -f .flox/env/manifest.toml ] && [ -n "$FLOX_MISSING" ]; then
  echo "== flox: environment not materialized in this tree =="
  echo "  .flox/env/manifest.toml is present, but$FLOX_MISSING is not."
  echo "  There is nothing to activate, so the source gates below are NOT run"
  echo "  here. Not a failure: CI's flox plugin builds the environment from the"
  echo "  manifest. It is a hole in LOCAL coverage, and it is counted as one."
  gaps=""
  for gate in scripts/ci_test.sh scripts/ci_lint.sh; do
    [ -f "$gate" ] && gaps="$gaps $gate"
  done
  SKIPPED+=("flox source gates${gaps:- (none present)}: no flox environment in $PATHX")
elif [ -f .flox/env/manifest.toml ]; then
  FLOX=$(NIX_CONFIG="experimental-features = nix-command flakes" find_flox)
  [ -n "$FLOX" ] || { echo "flox unavailable; cannot reproduce the CI environment"; exit 2; }
  echo "== flox: $($FLOX --version 2>&1 | tail -1) =="

  # A manifest whose lock does not resolve it is the trap that stalled the
  # pipeline for 13h: the dependency is declared but CI never gets it.
  for pkg in $(grep -oE '^[a-zA-Z0-9_]+\.pkg-path' .flox/env/manifest.toml | cut -d. -f1); do
    if ! grep -q "\"install_id\": \"$pkg\"" .flox/env/manifest.lock 2>/dev/null; then
      echo "LOCK GAP: $pkg is in manifest.toml but not manifest.lock"; RC=1
    fi
  done
  [ $RC -eq 0 ] && echo "lock satisfies manifest: OK"

  for gate in scripts/ci_test.sh scripts/ci_lint.sh; do
    [ -f "$gate" ] || continue
    echo "== $gate =="
    if FLOX_DISABLE_METRICS=true "$FLOX" activate -- bash "$gate" >/tmp/gate.$$ 2>&1; then
      grep -E "^Ran |^OK" /tmp/gate.$$ | sed 's/^/  /' | tail -8
      echo "  PASS"
    else
      tail -25 /tmp/gate.$$ | sed 's/^/  /'; echo "  FAIL"; RC=1
    fi
    rm -f /tmp/gate.$$
  done
fi

# Tests run with PYTHONPATH spanning the whole repo, so every import resolves
# on the host whatever the image actually contains. Only the container
# disagrees, and it disagrees at runtime, in production, on restart. Compare
# what each entrypoint imports against what its Dockerfile copies.
for df in $(find . -name Dockerfile -not -path "*/node_modules/*" 2>/dev/null); do
  dir=$(dirname "$df")
  copied=$(grep -oE "[a-z_]+/[a-z_]+\.py" "$df" | xargs -n1 basename 2>/dev/null | sed "s/\.py$//" | sort -u)
  [ -n "$copied" ] || continue
  echo "== image imports: $df =="
  gap=0
  for rel in $(grep -oE "[a-z_]+/[a-z_]+\.py" "$df" | sort -u); do
    [ -f "$rel" ] || continue
    for imp in $(grep -oE "^import [a-z_]+|^from [a-z_]+ import" "$rel" 2>/dev/null | awk "{print \$2}" | sort -u); do
      # only local modules matter; stdlib and pip packages are not our problem
      if ls */"$imp".py >/dev/null 2>&1; then
        echo "$copied" | grep -qx "$imp" || { echo "  MISSING from image: $imp (imported by $rel)"; gap=1; RC=1; }
      fi
    done
  done
  [ $gap -eq 0 ] && echo "  every local import is copied"
done

# Nix trees prove themselves by evaluating every host they declare. An eval
# failure here is a box that cannot be rebuilt, which no test suite would catch.
#
# A MODULE-ONLY flake declares no host of its own -- `outputs = { self }: {
# nixosModules.arcade-hub = ...; }` and nothing else. home-arcade, agent-hub and
# ac-host are all this shape, and for all three the enumeration below came back
# empty and the gate fell through in SILENCE. modules/arcade-hub.nix ships
# systemd units and firewall rules to ac-box and had no evaluation gate at all;
# a syntax error or a dead option reference in it passed this script and only
# surfaced later, inside homelab.
#
# So a module-only tree is gated through the host that COMPOSES it. That host is
# the only place the tree's modules are actually put together with the options
# they reference, so it is the only place their breakage is visible -- and it
# checks the real composition rather than the module in isolation.
#
# Discovery is DERIVED, not declared:
#   consuming tree   $HUB -- the tree this script ships in. homelab is the hub
#                    for all five trees (AGENTS.md) and the only one that owns
#                    nixosConfigurations (README's layer table: L3 tenants
#                    "declare, never reach").
#   consuming hosts  $HUB's own nixosConfigurations attribute names, read the
#                    same way a self-hosting tree's are, so a second host costs
#                    no new configuration anywhere.
#   input name       the registry name from hub/repos.psv.
# hub/repos.psv deliberately gains no `consumer` column: homelab's flake.nix
# already states which trees compose into ac-box and under which input name, and
# a column would be a second spelling of a decided fact -- which README's Pinned
# conventions forbid -- free to drift out of agreement with the flake. Silent
# drift is the defect being closed here, not a tool to close it with.
#
# The input-name check below is load-bearing, not defensive. `nix eval
# --override-input <name> <path>` accepts a name that is NOT an input of the
# flake, without error or warning, and evaluates the pinned revision instead
# (verified: `--override-input nosuchinput /tmp` exits 0 and returns the
# unmodified drvPath). Rename an input in homelab's flake.nix without renaming
# the registry entry and, without this check, the gate silently goes back to
# proving github's copy while reporting the working tree as green.
if [ -f flake.nix ]; then
  hosts=$(nix eval --raw .#nixosConfigurations --apply 'c: builtins.concatStringsSep " " (builtins.attrNames c)' 2>/dev/null)
  if [ -n "$hosts" ]; then
    echo "== nix eval: $hosts =="
    for h in $hosts; do
      if nix eval --raw ".#nixosConfigurations.$h.config.system.build.toplevel.drvPath" >/dev/null 2>&1; then
        echo "  $h: evaluates"
      else
        echo "  $h: EVAL FAILED"; RC=1
      fi
    done
  else
    echo "== nix eval: $REPO is module-only, gating through the hub =="
    hubhosts=$(cd "$HUB" && nix eval --raw .#nixosConfigurations --apply 'c: builtins.concatStringsSep " " (builtins.attrNames c)' 2>/dev/null)
    # The hub's real input names, read from its lock rather than grepped out of
    # flake.nix, so an input added by a `follows` or a rename is seen as nix
    # sees it. No jq/python3 on the CI agent's PATH; nix parses its own JSON.
    META=$(mktemp -t hub-gates-meta.XXXXXX.json)
    nix flake metadata --json "$HUB" >"$META" 2>/dev/null
    hubinputs=$(nix eval --impure --raw --expr \
      "builtins.concatStringsSep \" \" (builtins.attrNames (builtins.fromJSON (builtins.readFile $META)).locks.nodes.root.inputs)" 2>/dev/null)
    rm -f "$META"

    if [ -z "$hubhosts" ]; then
      echo "  NO NIX GATE: $REPO declares no nixosConfigurations, and neither"
      echo "  does the hub tree $HUB -- there is no host to compose it through."
      echo "  Its modules would reach ac-box unproven."
      RC=1
    elif ! printf ' %s ' "$hubinputs" | grep -q " $REPO "; then
      echo "  NO NIX GATE: $HUB/flake.nix has no input named '$REPO'."
      echo "  hub inputs: ${hubinputs:-<could not be read>}"
      echo "  --override-input ignores an unknown name WITHOUT erroring, so"
      echo "  gating on a mismatched name would quietly evaluate the pinned"
      echo "  revision and call this working tree green. Make the input name in"
      echo "  $HUB/flake.nix and the name column in $REG agree."
      RC=1
    else
      echo "  composed into: $hubhosts (as input '$REPO' of $HUB)"
      for h in $hubhosts; do
        if (cd "$HUB" && nix eval --override-input "$REPO" "$PATHX" \
              --raw ".#nixosConfigurations.$h.config.system.build.toplevel.drvPath") >/tmp/nixgate.$$ 2>&1; then
          echo "  $h: evaluates with '$REPO' = $PATHX"
          grep -q "Updated input '$REPO'" /tmp/nixgate.$$ \
            && echo "    (input redirected off its pin onto this working tree)"
        else
          echo "  $h: EVAL FAILED with '$REPO' = $PATHX"
          grep -vE "^warning: (Git tree|not writing)" /tmp/nixgate.$$ | tail -25 | sed 's/^/    /'
          RC=1
        fi
        rm -f /tmp/nixgate.$$
      done
    fi
  fi
else
  # Not a Nix tree at all. Nothing here reaches ac-box
  # through a system closure, so there is no eval to run -- but it is still a
  # gate that did not happen, and it says so rather than passing quietly.
  SKIPPED+=("nix eval: $REPO has no flake.nix, so nothing was evaluated")
fi

# The pages step republishes the live site from these templates. render_site.py
# fills site/ and ci_publish_pages.py copies the result over the Pages checkout,
# so a template that lost markup deletes it from production on the next green build.
if [ -f scripts/render_site.py ] && [ -d site ]; then
  echo "== site render vs live =="
  OUT=$(mktemp -d)
  if nix shell nixpkgs#python3 -c python scripts/render_site.py --out "$OUT" >/dev/null 2>&1; then
    LIVE="${HUB_LIVE_URL:-https://simracing.fugazy.dev}"
    for f in index.html style.css; do
      curl -fsS --max-time 20 "$LIVE/$f" -o "$OUT/.live" 2>/dev/null || { echo "  $f: live unreachable, skipped"; continue; }
      miss=$(comm -23 \
        <(grep -oE 'id="[a-z-]+"' "$OUT/.live" | sort -u) \
        <(grep -oE 'id="[a-z-]+"' "$OUT/$f" 2>/dev/null | sort -u) | tr '\n' ' ')
      if [ -n "${miss// /}" ]; then
        echo "  $f WOULD DROP from live: $miss"; RC=1
      else
        echo "  $f: keeps everything live has"
      fi
    done
  else
    echo "  render failed"; RC=1
  fi
  rm -rf "$OUT"
fi

echo
if [ ${#SKIPPED[@]} -gt 0 ]; then
  echo "Gates that did NOT run -- neither proven nor disproven:"
  for s in "${SKIPPED[@]}"; do echo "  - $s"; done
  echo
fi

if [ $RC -ne 0 ]; then
  echo "===== GATES FAIL - pushing would stall the pipeline ====="
elif [ ${#SKIPPED[@]} -gt 0 ]; then
  # Deliberately not the same banner as a clean run. A gate that never ran is
  # the thing that let modules/arcade-hub.nix reach ac-box unevaluated, and it
  # is only harmless while somebody can see it.
  echo "===== GATES PASS WITH GAPS - ${#SKIPPED[@]} gate(s) above did not run ====="
else
  echo "===== GATES PASS - safe to push ====="
fi
exit $RC
