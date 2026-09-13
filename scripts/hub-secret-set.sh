#!/usr/bin/env bash
# Put one secret value into secrets/ac-box.yaml, encrypted, from stdin.
#
# This is how a secret reaches the box without anyone ssh-ing in to place a
# file: the value goes into git encrypted (modules/platform/secrets.nix has
# the key model), the closure carries it, and sops-nix installs it at
# activation at the path the consumer already reads.
#
# The value is read from stdin, never from an argument -- an argument would
# sit in shell history and `ps`. At a terminal the prompt hides the echo;
# piped input works too (one-time migration of a value the box already has:
#   ssh ac-box "grep ^DISCORD_TOKEN= /var/lib/ac-host/.env | cut -d= -f2-" \
#     | scripts/hub-secret-set.sh discord-token
# ). A trailing newline is stripped; nothing else is touched.
#
# The identity is derived in-memory from the operator's ssh key and never
# written to disk, exactly as .sops.yaml documents. The round trip is proven
# before the script says done: the value decrypted back out must hash to what
# went in (12 Sep 2026's first attempt silently encrypted nothing; that is why
# the hash is printed rather than "ok").
#
# Usage: hub-secret-set.sh <key>        e.g. buildkite-api-token
set -euo pipefail
KEY="${1:-}"
[ -n "$KEY" ] || { echo "usage: $0 <key>   (value on stdin)"; exit 2; }
case "$KEY" in *[!a-z0-9-]*) echo "key must be [a-z0-9-]: $KEY"; exit 2 ;; esac

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"   # sops finds .sops.yaml (the creation rules) from the cwd upward
FILE="${HOMELAB_SOPS_FILE:-$ROOT/secrets/ac-box.yaml}"
IDENTITY="${HOMELAB_SOPS_SSH_KEY:-$HOME/.ssh/id_ed25519_ac-host}"
[ -r "$IDENTITY" ] || { echo "no operator key at $IDENTITY (set HOMELAB_SOPS_SSH_KEY)"; exit 2; }

if [ -t 0 ]; then
  read -rs -p "value for $KEY (hidden): " VALUE; echo >&2
else
  VALUE=$(cat)
fi
VALUE="${VALUE%$'\n'}"
[ -n "$VALUE" ] || { echo "empty value; nothing written"; exit 1; }

export NIX_CONFIG="experimental-features = nix-command flakes"
# The tools come from nixpkgs on demand; nothing is installed. Both run in
# one shell so the derived identity lives in one process's environment.
JSON=$(printf '%s' "$VALUE" | sed 's/\\/\\\\/g; s/"/\\"/g')
WANT=$(printf '%s' "$VALUE" | sha256sum | cut -c1-16)
GOT=$(nix shell nixpkgs#sops nixpkgs#ssh-to-age -c bash -c '
  set -euo pipefail
  SOPS_AGE_KEY="$(ssh-to-age -private-key -i "$1")"; export SOPS_AGE_KEY
  sops --set "[\"$2\"] \"$3\"" "$4"
  sops -d --extract "[\"$2\"]" "$4" | sha256sum | cut -c1-16
' _ "$IDENTITY" "$KEY" "$JSON" "$FILE")

if [ "$GOT" != "$WANT" ]; then
  echo "ROUND TRIP FAILED for $KEY: wrote sha256 $WANT, read back $GOT -- not committed, fix before trusting $FILE"
  exit 1
fi
echo "$KEY set in ${FILE#"$ROOT"/}; round trip sha256 $WANT. Commit it:"
echo "  git -C $ROOT add secrets/ac-box.yaml && git -C $ROOT commit -m 'secrets: $KEY'"
