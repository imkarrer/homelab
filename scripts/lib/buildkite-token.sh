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
#                                      the same value the box reads (bead .39),
#                                      read through lib/sops-secret.sh. That
#                                      decrypt -- the age identity derived
#                                      in-memory from ~/.ssh/id_ed25519_ac-host,
#                                      never written anywhere -- used to live
#                                      here; it moved out on 14 Sep 2026 when
#                                      hub-backup.sh needed a second secret
#                                      (restic-repo-password) from the same
#                                      file, so that there is one decrypt path
#                                      to fix rather than two to keep in step.
#
# The token itself goes to stdout and nowhere else. Callers must keep it out of
# argv (curl -H @- reads the header from stdin; `ps` never sees it) and out of
# files.
buildkite_token() {
  local token
  if [ -n "${BUILDKITE_API_TOKEN:-}" ]; then
    echo "token: \$BUILDKITE_API_TOKEN" >&2
    printf '%s' "$BUILDKITE_API_TOKEN"; return 0
  fi
  if [ -r "$HOME/.config/buildkite/token" ]; then
    echo "token: ~/.config/buildkite/token" >&2
    tr -d '\n' < "$HOME/.config/buildkite/token"; return 0
  fi
  # shellcheck source=scripts/lib/sops-secret.sh
  . "$(dirname "${BASH_SOURCE[0]}")/sops-secret.sh"
  token=$(hub_sops_secret buildkite-api-token) || {
    echo "no token: set BUILDKITE_API_TOKEN, write ~/.config/buildkite/token, or fix the sops read named above" >&2
    return 2
  }
  printf '%s' "$token"
}
