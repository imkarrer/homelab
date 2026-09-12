# Agent instructions — homelab

Read `README.md` first. Its **Pinned conventions** section is binding: option
namespace, tenant names, port scopes, unit-name stability, tier semantics,
state-path preservation, nixpkgs ownership, and the public/private boundary are
all already decided.

Its **Working agreements for automated changes** section is also binding, and
is the short version:

Never hand-edit ac-box. Read-only SSH inspection is always fine. Migration exception, until ADR 0006's deploy unit is enabled: an agent may apply a pushed revision with nixos-rebuild switch --flake github:imkarrer/homelab/<full-sha>#ac-box, and may run box-side steps a runbook in docs/ spells out verbatim. Two conditions: the sha must already be on origin, and the agent must stop — not judge — at a runbook's abort criteria. ac-host-static.service or docker.service under stop/restart in dry-activate is an abort, full stop.

## Which tenants may be disrupted

The contract can only place a unit in a slice by restarting it (`Slice=`
applies at unit start), so "may this tenant be reconciled?" is really "may its
units bounce?". That is a per-tenant fact, and guessing it wrong is how a
config change becomes an outage:

- **assetto — never, outside a window.** `quiet.drainable = false`, and
  `ac-host-static`'s `ExecStop` is `docker rm -f` on live race servers. Drain
  through `acctl.py` first; the 03:00 window exists for this.
- **arcade — freely.** Standing authority, granted 9 Sep 2026: bouncing
  freeciv, mindustry, smbd, winbindd or rsyncd is acceptable without a window.
  Nothing is mid-race, and the clients are kids' machines that reconnect. This
  is what let `samba-*`/`rsync.service` be pulled into the tenant's `units` at
  all.
- **observability, ci, agent-hub — freely.** All `drainable = true`; a gap in
  a Grafana graph or a re-queued Buildkite job is not an outage. The one
  exception is bouncing `ac-host-ci.service` *from a job running on it* — see
  `modules/ci/default.nix` HAZARD 2, which is a circularity, not a preference.

## A tenant unit outranks an upstream slice

`modules/tenant/resources.nix` emits `Slice=` and `Nice=` at
`lib.mkOverride 90`, deliberately, giving a three-rung ladder:

    upstream nixpkgs module   100
    this contract              90
    a host's own mkForce       50

A plain value here ties with any nixpkgs module that slices itself — nixpkgs'
samba pins `system-samba.slice` — and a tie is an evaluation error, not a
merge. Naming a unit in `homelab.tenants.<name>.units` is therefore an
authoritative claim on where that unit runs. **The cost:** a typo in a `units`
list silently relocates some other module's unit instead of failing loudly.
Keep those lists short, explicit and hand-checked; never derive or glob them.

## Issue tracker

Beads (`bd`), rooted in this repo. This is the single tracker for the whole
multi-repo refactor, including work that lands in `home-arcade`, `agent-hub`
and `ac-host`.

```bash
bd ready              # what is actionable
bd show <id>          # detail
```

## Hub

This repo is the hub for all four source trees. `hub/repos.psv` is the
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

It also compares ac-box's running **system closure** against this repo's HEAD.
That is a separate question from the tenant tree above, with a separate answer:
`hub/repos.psv` marks homelab `deploy=none`, so committing and pushing does not
reach the box — only a human `nixos-rebuild switch --flake` does. Green there
means no commit is newer than the last switch, which is consistent with the box
being current, not proof of it; `HUB_STATUS_EXACT=1 bash scripts/hub-status.sh`
proves it by comparing store paths, at ~7s instead of ~2s.
