# Agent instructions — homelab

Read `README.md` first. Its **Pinned conventions** section is binding: option
namespace, tenant names, port scopes, unit-name stability, tier semantics,
state-path preservation, nixpkgs ownership, and the public/private boundary are
all already decided.

Its **Working agreements for automated changes** section is also binding, and
is the short version:

- Never write to ac-box. Read-only SSH inspection only: change it by landing
  in git and letting Buildkite deploy.
- Push only what `hub/repos.psv` marks `agent-push=yes`, and only on green
  gates. Everything else is `ask`.
- Never run `bd` write commands — one coordinator owns the tracker.
- Prove Nix work with `nix eval` / `nix flake check` locally.

## Issue tracker

Beads (`bd`), rooted in this repo. This is the single tracker for the whole
multi-repo refactor, including work that lands in `home-arcade`, `agent-hub`
and `ac-host`.

```bash
bd ready              # what is actionable
bd show <id>          # detail
```

## Hub

This repo is the hub for all five source trees. `hub/repos.psv` is the
registry: where each tree lives, whether it reaches ac-box, and whether an
agent may push it unattended.

```bash
bash scripts/hub-status.sh        # three-way state: box vs origin vs WSL trees
bash scripts/hub-gates.sh <repo>  # the gates CI will run, before pushing
```

Run `hub-status.sh` before acting. It answers what the box runs, what is on
origin, and what is uncommitted here — in one call, so none of it gets
re-derived by hand. Exit 1 prints what is unreconciled.

A hand-edit on ac-box is a debugging step, never a resting state: land it the
same session. `hub-status.sh` reports the box tree diverging from the sha it
claims to run, which is how such an edit is found before an rsync destroys it.
