#!/usr/bin/env bash
# The one place a hub script gets the Buildkite API token. Sourced, not run:
#   . "$(dirname "$0")/lib/buildkite-token.sh"; TOKEN=$(buildkite_token) || exit 2
# Used by hub-deploy.sh (write_builds) and hub-pipeline.sh (write_pipelines).
#
# Three sources, first hit wins, and the caller is told WHICH on stderr so a
# 401 is attributable without anyone printing the value:
#
#   1. $BUILDKITE_API_TOKEN            an operator's explicit override
#   2. ~/.config/buildkite/token       the pre-sops place (chmod 600), kept so a
#                                      laptop without the ac-host key still works
#   3. secrets/ac-box.yaml             the repo's own copy, `buildkite-api-token`,
#                                      the same value the box reads (bead .39).
#                                      Decrypted with the operator identity derived
#                                      in-memory from ~/.ssh/id_ed25519_ac-host,
#                                      exactly as hub-secret-set.sh does it: the
#                                      age key lives in one child process's
#                                      environment and is never written anywhere.
#
# The token itself goes to stdout and nowhere else. Callers must keep it out of
# argv (curl -H @- reads the header from stdin; `ps` never sees it) and out of
# files.
buildkite_token() {
  local root file identity token
  root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
  if [ -n "${BUILDKITE_API_TOKEN:-}" ]; then
    echo "token: \$BUILDKITE_API_TOKEN" >&2
    printf '%s' "$BUILDKITE_API_TOKEN"; return 0
  fi
  if [ -r "$HOME/.config/buildkite/token" ]; then
    echo "token: ~/.config/buildkite/token" >&2
    tr -d '\n' < "$HOME/.config/buildkite/token"; return 0
  fi
  file="${HOMELAB_SOPS_FILE:-$root/secrets/ac-box.yaml}"
  identity="${HOMELAB_SOPS_SSH_KEY:-$HOME/.ssh/id_ed25519_ac-host}"
  if [ ! -r "$identity" ]; then
    echo "no token: set BUILDKITE_API_TOKEN, write ~/.config/buildkite/token, or have $identity to decrypt ${file#"$root"/}" >&2
    return 2
  fi
  echo "token: sops ${file#"$root"/} [\"buildkite-api-token\"] via $identity" >&2
  # cd so sops finds .sops.yaml from the cwd upward; nix brings the tools.
  # shellcheck disable=SC2016  # the quoted script is for the child bash
  token=$(cd "$root" && NIX_CONFIG="experimental-features = nix-command flakes" \
    nix shell nixpkgs#sops nixpkgs#ssh-to-age -c bash -c '
      set -euo pipefail
      SOPS_AGE_KEY="$(ssh-to-age -private-key -i "$1")"; export SOPS_AGE_KEY
      sops -d --extract "[\"buildkite-api-token\"]" "$2"
    ' _ "$identity" "$file") || { echo "no token: sops could not decrypt buildkite-api-token from ${file#"$root"/}" >&2; return 2; }
  token="${token%$'\n'}"
  [ -n "$token" ] || { echo "no token: buildkite-api-token is empty in ${file#"$root"/}" >&2; return 2; }
  printf '%s' "$token"
}
