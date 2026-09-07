# Agent instructions — homelab

Read `README.md` first. Its **Pinned conventions** section is binding: option
namespace, tenant names, port scopes, unit-name stability, tier semantics,
state-path preservation, nixpkgs ownership, and the public/private boundary are
all already decided.

Its **Working agreements for automated changes** section is also binding, and
is the short version:

- Never write to ac-box. Read-only SSH inspection only.
- Never `git push`.
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
