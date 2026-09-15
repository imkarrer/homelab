#!/usr/bin/env bash
# The one place a hub script reads a value out of secrets/ac-box.yaml.
# Sourced, not run:
#   . "$(dirname "$0")/lib/sops-secret.sh"
#   VALUE=$(hub_sops_secret restic-repo-password) || exit 2
#
# This is the read half of scripts/hub-secret-set.sh, and it derives the
# operator identity the same way that script does and .sops.yaml documents:
# ssh-to-age turns ~/.ssh/id_ed25519_ac-host into an age key inside ONE child
# process's environment, and it is never written to disk. Both tools come from
# nixpkgs on demand; nothing is installed.
#
# It was extracted from lib/buildkite-token.sh on 14 Sep 2026, when
# hub-backup.sh needed a second secret (restic-repo-password) out of the same
# file. Extracting rather than copying is deliberate: README's pinned
# conventions forbid a second spelling of a decided thing, and "how a script
# on this machine decrypts a repo secret" is one decided thing with one place
# to fix it if sops, ssh-to-age or the key model ever change.
#
# The value goes to stdout and NOWHERE else -- not into a log, not into argv,
# not into a file. Callers keep it out of argv too (an environment variable or
# a here-document, never a command line: `ps` shows argv to every user).
# Everything this function says about WHICH key it read, from WHICH file, with
# WHICH identity goes to stderr, so a failure is attributable without anyone
# printing the secret.
hub_sops_secret() {
  local key="${1:?hub_sops_secret <key>}" root file identity value
  root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
  file="${HOMELAB_SOPS_FILE:-$root/secrets/ac-box.yaml}"
  identity="${HOMELAB_SOPS_SSH_KEY:-$HOME/.ssh/id_ed25519_ac-host}"
  if [ ! -r "$identity" ]; then
    echo "no $key: cannot read the operator key $identity (set HOMELAB_SOPS_SSH_KEY)" >&2
    return 2
  fi
  echo "$key: sops ${file#"$root"/} via $identity" >&2
  # cd so sops finds .sops.yaml from the cwd upward; nix brings the tools.
  # shellcheck disable=SC2016  # the quoted script is for the child bash
  value=$(cd "$root" && NIX_CONFIG="experimental-features = nix-command flakes" \
    nix shell nixpkgs#sops nixpkgs#ssh-to-age -c bash -c '
      set -euo pipefail
      SOPS_AGE_KEY="$(ssh-to-age -private-key -i "$1")"; export SOPS_AGE_KEY
      sops -d --extract "[\"$2\"]" "$3"
    ' _ "$identity" "$key" "$file") || {
    echo "no $key: sops could not decrypt it from ${file#"$root"/}" >&2; return 2; }
  value="${value%$'\n'}"
  [ -n "$value" ] || { echo "no $key: it is empty in ${file#"$root"/}" >&2; return 2; }
  printf '%s' "$value"
}
