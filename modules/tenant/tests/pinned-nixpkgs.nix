# The one nixpkgs every eval harness in this repo is allowed to use: the
# revision flake.lock pins, resolved from the lock file itself.
#
# WHY THIS FILE EXISTS (finding F7, docs/current-state.md; closed 9 Sep 2026).
# Until now every harness in modules/*/tests/ opened with
# `{ lib ? (import <nixpkgs> { }).lib }`, so it resolved through NIX_PATH --
# a channel, a `-I` flag, or nothing at all -- rather than through the
# revision this repo pins. That is not pedantry here, for two reasons:
#
#   1. These harnesses are load-bearing. They are the ONLY coverage proving
#      ports.nix still *rejects* fixtures/collision.nix, that resources.nix
#      still fires the 0.9 memoryShare budget assertion, and that a
#      `forwarded` claim without a justification is still refused.
#      `nix flake check` cannot cover any of it: the real ac-box config has
#      no collision and no overrun to reject, so it proves only that a good
#      config passes. .buildkite/pipeline.yml runs this set as its own named
#      gate for exactly that reason.
#
#   2. The two trees really do differ on the machines this runs on. Measured
#      in the WSL dev tree on 9 Sep 2026:
#        <nixpkgs>  (root channel) -> /nix/store/38cfv0p50zc47wi3xskv7srvs4nd0fj6-...-source
#        flake.lock (this repo)    -> /nix/store/vin7xkmskj4k065z1w7bwwwwp4dbfv93-source
#      Both call themselves 26.05, and neither says so out loud. flake.nix's
#      own pin comment records what that kind of drift already cost once:
#      tracking the branch instead of the exact revision resolved six days
#      newer and renamed the system derivation, which would have buried a
#      real diff-closures result under hundreds of spurious ones. A test
#      suite that quietly opts out of that pin can pass against a different
#      `lib` than the system is built with, which is the same failure mode
#      wearing a smaller hat.
#
# There is a third failure mode the old default hid: on a machine with no
# NIX_PATH at all -- a CI sandbox has no reason to have channels configured
# -- `import <nixpkgs>` throws, so a harness invoked the way its own header
# documents does not run. The runner script papered over that with
# `-I nixpkgs=...`, which fixed the scripted path only; a human following
# the Usage block at the top of any harness still got the channel's lib, or
# an error. Resolving the pin HERE fixes both paths at once, and there is no
# <nixpkgs> fallback left to silently take.
#
# HOW. builtins.fetchTree is handed the lock node verbatim -- type, owner,
# repo, rev and narHash -- so this is the same fetch the flake itself
# performs, and it resolves to the identical store path (proven above and by
# `nix eval -f modules/tenant/tests/pinned-nixpkgs.nix path`). Because the
# narHash is supplied it is a pure, locked fetch: no registry lookup, no
# re-locking, no network once the input is in the store, and no dependence
# on this tree being clean or even being a git checkout. The lock is read
# rather than the revision copied, so the pin has exactly one home
# (flake.nix / flake.lock) and cannot drift out from under the tests.
#
# Deliberately NOT `builtins.getFlake (toString ../../..)`: that is impure
# (it needs --impure, which every documented harness invocation would then
# have to grow), it re-locks the whole flake including three tenant inputs
# just to reach nixpkgs, and on a dirty tree it evaluates a copy of the
# working directory rather than the pin.
#
# WHY IT LIVES UNDER modules/tenant/tests/. modules/ci/tests/eval.nix imports
# it from here, which is L2 depending on L1 -- the direction README's "Layers"
# table permits. The neutral home would be a repo-level lib/ or a flake
# `checks` output; neither exists yet, and adding one is a flake change with
# its own review. If this repo ever grows either, move the file and leave a
# stub -- do not add a second copy, because two copies of a pin is the bug
# this file was written to remove.
#
# NOTE for whoever adds a harness: name it eval*.nix (that glob is what
# modules/ci/scripts/run-eval-tests.sh enumerates) and take `lib`/`pkgs` from
# here, never from <nixpkgs>.
let
  lock = builtins.fromJSON (builtins.readFile ../../../flake.lock);

  # Follow root's own input name rather than assuming the node is called
  # "nixpkgs": Nix renames a node when two inputs collide, and the root
  # inputs map is the authoritative indirection.
  node = lock.nodes.${lock.nodes.root.inputs.nixpkgs}.locked;

  src = builtins.fetchTree {
    inherit (node)
      type
      owner
      repo
      rev
      narHash
      ;
  };
in
{
  # The store path of the pinned tree. Printed by run-eval-tests.sh on every
  # run so a CI log carries the proof, and the handle for checking by hand
  # that it matches `nix flake metadata --json`'s nixpkgs node.
  path = builtins.toString src;

  inherit (node) rev narHash;

  # nixpkgs' own flake.nix exposes `lib = import ./lib`, so this IS nixpkgs'
  # lib output -- not a second spelling of it -- and it costs nothing like
  # instantiating the whole package set, which is what the old
  # `(import <nixpkgs> { }).lib` did for three harnesses that only wanted
  # evalModules. (Measured 9 Sep 2026: the full suite went 18.0s -> 3.8s.)
  # Checked equivalent to `(import src { }).lib` before relying on it: same
  # attrNames, same lib.version (26.05pre-git). Only the attrset identity of
  # individual functions differs, which is thunk identity, not behaviour --
  # and the definitive check is that every case in the suite produced an
  # identical pass/throw result before and after this change.
  lib = import (src + "/lib");

  # For the two harnesses that thread a real `pkgs` into specialArgs
  # (eval-resources.nix, modules/ci/tests/eval.nix). Same call shape as the
  # `import <nixpkgs> { }` it replaces -- default config, no overlays -- so
  # only the tree it reads has changed.
  pkgs = import src { };
}
