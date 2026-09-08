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
if [ -f .flox/env/manifest.toml ]; then
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
  fi
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
[ $RC -eq 0 ] && echo "===== GATES PASS - safe to push =====" || echo "===== GATES FAIL - pushing would stall the pipeline ====="
exit $RC
