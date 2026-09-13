---
name: homelab-verify
description: Prove a change in the homelab hub is green before it is reported, committed or pushed - the exact gate per tree, what green looks like, and how to show a refactor was a no-op. Use whenever a change is about to be called done, and when a gate output needs reading.
---

# Verifying a change

The gate is what CI runs, run locally. It is seconds, not minutes, so it runs
after every change, never once at the end.

```bash
bash /home/nixos/src/homelab/scripts/hub-gates.sh <repo> [worktree path]   # homelab ~7s, ac-host ~15s
```

The path argument gates a worker worktree instead of the registry checkout;
without it the registry checkout is what gets gated, whatever directory you
are in. Green is the literal line `===== GATES PASS - safe to push =====`. Anything
else is red, and a red gate pushed to `main` stalls **every** deploy behind
`wait: ~`, not just this one.

For `homelab` the script evaluates `nixosConfigurations.ac-box`. The module
harnesses are a second, cheaper check that the contract still *rejects* what
it should (a port collision, an overrun) — ac-box has nothing to reject, so
the toplevel alone cannot prove it:

```bash
cd /home/nixos/src/homelab && nix flake check --no-build     # ~4s
```

Bare `nix` in this WSL needs flakes switched on; the hub scripts do it for
themselves, a hand-run command does not:

```bash
export NIX_CONFIG="extra-experimental-features = nix-command flakes"
```

## Proving what kind of change it was

A gate says the config evaluates. It does not say whether the change did what
was meant. Two checks close that gap, and the handoff names which one applied:

- **A no-op** (rename, move, comment, refactor): the toplevel's `drvPath` is
  byte-identical before and after. Capture it on a clean tree first.

  ```bash
  nix eval --raw '.#nixosConfigurations.ac-box.config.system.build.toplevel.drvPath'
  ```

- **A behaviour change**: the `drvPath` differs, and one of these says why —
  `nix eval` of the specific option that moved (`.#nixosConfigurations.ac-box.config.homelab.tenants.<n>.units`),
  or a new `modules/*/tests/eval*.nix` case that throws on the input the
  change now rejects. The harnesses are discovered by glob; a new file needs
  no registration.

## What the local gate cannot prove

`diff-closures` and `switch-to-configuration dry-activate` run on the box, by
`modules/deploy` in the 03:30 window. A local green means *evaluates*, not
*activates cleanly* — say so in the handoff rather than upgrading the claim.
