#!/usr/bin/env bash
# Which hosts a hub script is about, and how it asks the flake. Sourced, not run:
#   . "$(dirname "$0")/lib/hosts.sh"
#   HOSTS=$(hub_hosts "$HUB") || exit 2
#
# Since 26 Sep 2026 (homelab-ygc.4) flake.nix declares two hosts, ac-box and
# arcade-box, and after the cutover (docs/runbook-arcade-box-cutover.md,
# phase 4) the state hub-status.sh reports on and hub-backup.sh pulls is
# split between them: every tenant but agent-hub on arcade-box. Neither
# script may carry its own list of hosts. flake.nix's nixosConfigurations IS
# the list (README's pinned conventions: no second spelling of a decided
# fact), read here the way scripts/hub-gates.sh reads it, so a third host
# costs no change to any script.
#
# hub_hosts <tree> prints the hosts, space-separated. First match wins:
#   HOMELAB_BOX=<host>      one host -- the narrowing hub-status.sh and
#                           hub-deploy.sh honoured before there were two, and
#                           still the way to ask about one. HOMELAB_BOX=ac-box
#                           is exactly the pre-26-Sep behaviour of every script.
#   HOMELAB_HOSTS="a b"     an explicit list, in this order. A host the flake
#                           does not declare fails where it is used, not here.
#   the flake               the attribute names of <tree>#nixosConfigurations,
#                           ~0.05 s warm, alphabetical -- ac-box first today by
#                           the alphabet, which is also the order the operator
#                           reads them in.
# Non-zero when the flake will not evaluate; the caller says what that means
# for it (hub-status.sh reports one host and a verdict, hub-backup.sh stops).
#
# The ssh alias for a host IS its attribute name, and so is what the machine
# calls itself: ~/.ssh/config carries both aliases (ac-box -> 192.168.1.50,
# arcade-box -> 192.168.1.218 during the build-up), and networking.hostName
# is homelab.host.name, which modules/platform/identity.nix ties to
# hosts/<name>/. Reading homelab.host.name out of the flake to confirm that
# would cost a ~7 s evaluation per host against hub-status.sh's ~2 s
# contract, so it is not read; instead hub-status.sh compares the alias with
# the kernel hostname on every round trip, which is the check that matters --
# the cutover swaps 192.168.1.50 between the two machines, and an alias left
# pointing at the wrong one is exactly the mistake nothing else would see.
#
# hub_nix_eval <tree> <nix eval args...> runs `nix eval` with flakes on and,
# when the caller is root, as the checkout's OWNER: hub-backup.sh runs from a
# timer as root, and Nix (libgit2) refuses a git repository "not owned by
# current user" (the 16 Sep 2026 run failed there before touching anything).
# Evaluation needs no privilege; the nix-daemon serves any user. stderr is
# left alone so a caller can show why an evaluation failed.
hub_nix_eval() {
  local tree="${1:?hub_nix_eval <tree> <nix eval args...>}" owner
  shift
  owner=$(stat -c %U "$tree")
  local -a as_owner=()
  if [ "$(id -u)" = 0 ] && [ "$owner" != root ]; then
    as_owner=(runuser -u "$owner" -- env "HOME=$(getent passwd "$owner" | cut -d: -f6)")
  fi
  "${as_owner[@]}" env NIX_CONFIG="${NIX_CONFIG:-experimental-features = nix-command flakes}" \
    nix eval "$@"
}

hub_hosts() {
  local tree="${1:?hub_hosts <tree>}" hosts
  if [ -n "${HOMELAB_BOX:-}" ]; then printf '%s\n' "$HOMELAB_BOX"; return 0; fi
  if [ -n "${HOMELAB_HOSTS:-}" ]; then printf '%s\n' "$HOMELAB_HOSTS"; return 0; fi
  # The flake's nixConfig (cache.flox.dev) makes nix warn an untrusted user
  # on stderr; the names are the same either way.
  hosts=$(hub_nix_eval "$tree" --raw "$tree#nixosConfigurations" \
            --apply 'c: builtins.concatStringsSep " " (builtins.attrNames c)' 2>/dev/null) || return 1
  [ -n "$hosts" ] || return 1
  printf '%s\n' "$hosts"
}
