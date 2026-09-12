# Turns the eval harnesses (modules/*/tests/eval*.nix) into flake checks:
# one derivation per harness that `nix flake check` builds, and that fails
# when any case's actual pass/throw disagrees with the harness's `expected`
# map. flake.nix's `checks` output is `{ ac-box = <toplevel>; } // .checks`
# from here.
#
# WHY THIS FILE EXISTS (F7's open follow-up, docs/current-state.md §4; delta
# row 14). The harnesses are the only coverage proving ports.nix still
# REJECTS fixtures/collision.nix and resources.nix still refuses a broken
# budget; `nix flake check` on the host config alone cannot show that,
# because ac-box has nothing to reject. Until 12 Sep 2026 they ran only
# through modules/ci/scripts/run-eval-tests.sh, a shell loop that read each
# harness's `expected` map and re-derived the verdict per case with one
# `nix eval` process each. Making them flake checks puts them under the one
# gate every pushed revision already passes through, and hands them the
# flake's own `nixpkgs.lib` -- the pin, from the flake, directly.
#
# THE INVERSION, and where it lives. A fixture that must THROW cannot be a
# check that must SUCCEED without inverting it: `builtins.tryEval` on
# `<case>.checked`, asserting `success == expected`. That inversion lives
# here, once, wrapping any harness's case table -- not in each harness, and
# no longer in the shell script (which is now a front-end that builds these
# same checks and prints their reports). README's Pinned conventions forbid
# a second spelling of a decided thing, and "true means evaluates cleanly,
# false means throws" is decided once, in each harness's `expected` map;
# this is the one reader of that encoding. The harnesses themselves are
# untouched by it: every `nix eval -f <harness> <case>.checked` in their
# Usage blocks still works, against the same lib (pinned-nixpkgs.nix
# resolves the same tree -- see the agreement check below).
#
# THE CONTRACT a harness must meet. Every attribute except `expected` is a
# case; every case has a `.checked` that returns a string on success and
# `throw`s on failure, and a `.messages` that is the list of failed
# assertion/check texts `.checked` would throw; and `expected` names every
# case. The last part is enforced (`missing`/`stray` below): the old runner
# iterated `expected` only, so a case added without an entry was silently
# never run. modules/ci/tests/eval.nix used to lack `.checked`, and the
# runner special-cased it by `--json`-forcing the whole case; that heuristic
# is gone and the harness has `checks`/`.checked` like the other four. A
# deep force of a whole case is exactly what NOT to do here: `deepSeq` on a
# case whose `unit.path` reaches `pkgs.docker-compose` recurses through the
# package set until the evaluator's call depth is exceeded (reproduced
# 12 Sep 2026), and that is one of the errors tryEval does not catch.
#
# WHAT tryEval CATCHES, AND WHY THAT IS NOT QUITE ENOUGH. It catches `throw`
# and `assert` (in Nix's implementation, ThrownError is a subclass of
# AssertionError and the primop catches that class) -- nothing else. Not
# `abort`, not "attribute missing", not a type error, not a stack overflow,
# and nothing that happens while a derivation is BUILT rather than
# evaluated. An uncaught error class in a negative case surfaces as an eval
# error naming the case, never as a false pass, because it propagates out
# of tryEval rather than being reported as success.
#
# The gap is the other way round: the module system rejects a bad MERGE
# with a throw too, and tryEval cannot tell that from the assertion the
# case exists to prove. Found while writing this file: three of
# eval-metrics.nix's four negative cases redefined an address the shared
# fixture already set at plain priority, so they died with "has conflicting
# definition values" before metrics.nix's assertion was evaluated -- and
# passed the runner, which only asked "did it throw?". So a negative case
# here must ALSO have a non-empty `.messages`: that list is built by the
# harness AFTER the module system has finished, so it is only reachable if
# the config merged and the module itself said no. A case that threw with
# no messages is reported as "threw, but not through the module's own
# verdict", with the underlying error re-raised so the log says what did.
# Verified 12 Sep 2026 across all 23 cases (9 negative, 14 positive) after
# `lib.mkForce` fixed those three: success == expected and, for every
# negative, `.messages` is the module's assertion text.
#
# TWO FAILURE SHAPES, on purpose. A case that should throw and did not is a
# `throw` here, at evaluation time, naming the harness and the case -- there
# is nothing more to say than "it evaluated cleanly". A case that should
# pass and threw is re-forced OUTSIDE tryEval, with error context, so the
# module's own assertion text is what reaches the log; tryEval's `false`
# carries no message, and "it threw" without the message would send whoever
# reads the CI log back to a local shell to find out why. Both are
# evaluation failures, so `nix flake check` reports them before it builds
# anything. One case per harness: the report is a string, so the first
# failing case in `expected` order is the one named (un-colliding
# fixtures/collision.nix names allFalseCollisionStillFails, not `collision`;
# both use it). Fix it and the next one, if any, is named. `nix flake check`
# likewise stops at the first failing check unless run with --keep-going.
#
# COST. The derivation below does no work: every verdict is computed at
# evaluation time and interpolated into its build script, which prints the
# report (visible under `nix flake check -L` when it builds) and writes it
# to $out. It rebuilds only when the report text changes, so on a steady
# tree it is a cache hit -- but the EVALUATION, which is the test, runs on
# every `nix flake check` regardless. Measured 12 Sep 2026: evaluating all
# five checks to their drvPaths takes 1.0s including loading the flake; a
# warm `nix flake check` went 7.5-7.9s -> 7.4-8.8s, run-to-run noise. The
# host closure's evaluation is the rest, and checks.ac-box's BUILD (the
# toplevel, minutes when it misses) dwarfs all of it.
#
# DISCOVERY. `harnesses` enumerates modules/*/tests/eval*.nix -- the same
# glob run-eval-tests.sh used to walk with `find`, now the one rule, read by
# the flake and (through the flake) by the runner. A new harness named
# eval*.nix under any modules/<m>/tests/ is a check with no flake.nix edit;
# one named anything else is silently not, which is the hazard a glob
# carries and the reason pinned-nixpkgs.nix's NOTE spells the naming rule
# out. A flake sees only tracked files, so `git add` it too.
#
# ARGUMENTS. `lib` and `pkgs` are the flake's -- nixpkgs.lib and
# nixpkgs.legacyPackages.${system} -- and are handed to each harness by
# name, only those it declares (`builtins.functionArgs`), so a lib-only
# harness and a lib+pkgs one are called the same way and a harness that
# grows a `pkgs` argument gets it without a change here.
{ lib, pkgs }:

let
  # pinned-nixpkgs.nix is what the manual `nix eval -f <harness>` route
  # resolves `lib` from, by reading flake.lock itself. The flake route gets
  # the input directly. They MUST be the same tree, or "the harness passed"
  # means different things depending on how it was run -- which is the
  # failure F7 was about. Asserted once, at evaluation, and the path is
  # printed at the top of every report the way the old runner printed it,
  # so a CI log carries the proof rather than the claim. `toString
  # pkgs.path` is the flake input's tree as a plain string with no string
  # context, which is what the report must carry: a context would make
  # every check reference the whole nixpkgs tree.
  pinned = import ./pinned-nixpkgs.nix;
  flakeNixpkgs = toString pkgs.path;
  pinnedNixpkgs =
    if pinned.path == flakeNixpkgs then
      flakeNixpkgs
    else
      throw ''
        modules/tenant/tests/pinned-nixpkgs.nix resolves flake.lock's nixpkgs to
          ${pinned.path}
        but the flake's own nixpkgs input is
          ${flakeNixpkgs}
        The manual `nix eval -f <harness>` route and `nix flake check` would be
        testing against two different libs. One of them is reading the lock
        wrong; fix that rather than either result.
      '';

  # modules/<m>/tests/eval<suffix>.nix -> "eval-<m><suffix>", so
  # modules/tenant/tests/eval.nix is `eval-tenant`, eval-metrics.nix is
  # `eval-tenant-metrics`, and modules/ci/tests/eval.nix is `eval-ci`.
  modulesDir = ../..;
  harnesses = lib.listToAttrs (
    lib.concatMap (
      m:
      let
        tests = modulesDir + "/${m}/tests";
        files = if builtins.pathExists tests then builtins.readDir tests else { };
      in
      lib.mapAttrsToList (
        f: _:
        lib.nameValuePair "eval-${m}${lib.removeSuffix ".nix" (lib.removePrefix "eval" f)}" (
          tests + "/${f}"
        )
      ) (lib.filterAttrs (f: t: t == "regular" && lib.hasPrefix "eval" f && lib.hasSuffix ".nix" f) files)
    ) (lib.attrNames (lib.filterAttrs (_: t: t == "directory") (builtins.readDir modulesDir)))
  );

  indent =
    s:
    lib.concatMapStringsSep "\n" (l: "        ${l}") (lib.splitString "\n" (lib.removeSuffix "\n" s));

  mkCheck =
    {
      name,
      harness,
    }:
    let
      # Call the harness with exactly the arguments it declares, taken from
      # the flake -- never letting it fall back to its own `import
      # ./pinned-nixpkgs.nix` default, which is the other route and is
      # checked for agreement above, not used here.
      harnessFn = import harness;
      h = harnessFn (builtins.intersectAttrs (builtins.functionArgs harnessFn) { inherit lib pkgs; });

      cases = builtins.removeAttrs h [ "expected" ];

      # Every case must have a verdict in `expected`, and every `expected`
      # entry must name a case. A case with no entry was, under the old
      # runner, a test that silently never ran.
      missing = lib.subtractLists (lib.attrNames h.expected) (lib.attrNames cases);
      stray = lib.subtractLists (lib.attrNames cases) (lib.attrNames h.expected);

      # Re-force outside tryEval so the real error, not tryEval's bare
      # `false`, is what the log shows; the context names the case.
      reraise =
        case: why:
        builtins.addErrorContext "while checking case `${case}` of ${name}: ${why}" (
          builtins.seq h.${case}.checked (
            throw "unreachable: `${case}.checked` threw under tryEval and not outside it"
          )
        );

      verdict =
        case: expected:
        let
          result = builtins.tryEval h.${case}.checked;
          # Only consulted for a negative case that did throw. Forcing the
          # list to WHNF forces the module system to finish, so a merge
          # error surfaces here as success = false, a rejection as a
          # non-empty list.
          messages = builtins.tryEval (
            let
              m = h.${case}.messages;
            in
            builtins.seq (builtins.length m) m
          );
        in
        if expected && result.success then
          "ok    ${name} :: ${case} (expected pass)"
        else if expected then
          reraise case "`expected` says it must evaluate cleanly, and it threw"
        else if result.success then
          throw ''
            FAIL  ${name} :: ${case}: `checked` was expected to throw and evaluated cleanly.
            This fixture exists to prove the module REJECTS a bad configuration, and
            the module no longer does. See the case's comment in ${toString harness}.
          ''
        else if messages.success && messages.value != [ ] then
          "ok    ${name} :: ${case} (expected throw); rejected with:\n${indent (lib.concatStringsSep "\n" messages.value)}"
        else
          reraise case (
            "it threw, but not through the module's own verdict (`.messages` is "
            + (if messages.success then "empty" else "itself an error")
            + "). Expected a failed assertion; got an evaluation error before the"
            + " assertions were reached -- a definition tie, a type error, a missing"
            + " attribute. The case proves nothing about the module until it fails"
            + " for the reason its comment gives"
          );

      lines =
        if missing != [ ] then
          throw "${name}: case(s) with no entry in `expected`, so no verdict: ${lib.concatStringsSep ", " missing}"
        else if stray != [ ] then
          throw "${name}: `expected` names case(s) that do not exist: ${lib.concatStringsSep ", " stray}"
        else
          lib.mapAttrsToList verdict h.expected;

      report = lib.concatStringsSep "\n" (
        [
          "${name}: ${toString (lib.length lines)} cases from ${baseNameOf (toString harness)}"
          "pinned nixpkgs (flake input == flake.lock via pinned-nixpkgs.nix): ${pinnedNixpkgs}"
        ]
        ++ lines
      );
    in
    pkgs.runCommand name
      {
        # Interpolated, not read from a file: forcing this attribute at
        # evaluation time IS the test. The build only records the outcome.
        inherit report;
        passAsFile = [ "report" ];
        preferLocalBuild = true;
        allowSubstitutes = false;
      }
      ''
        cat "$reportPath"
        echo
        cp "$reportPath" "$out"
      '';
in
{
  inherit mkCheck harnesses;

  # What flake.nix merges into `checks.${system}`, next to `ac-box`.
  checks = lib.mapAttrs (name: harness: mkCheck { inherit name harness; }) harnesses;
}
