# Issue tracker: `bd` (beads)

Issues for this repo — and for every tree the hub coordinates (`ac-host`,
`agent-hub`, `home-arcade`) — live in the `bd` tracker rooted in `homelab`.
It is Dolt-backed, exported to `.beads/issues.jsonl` on commit, and is the
**single** tracker: GitHub Issues on `imkarrer/homelab` are not used. An issue
is a **bead** (see `CONTEXT.md`); ids look like `homelab-bqo.51`.

One writer: the supervisor session writes `bd`; workers report in a handoff
and the supervisor records it (`AGENTS.md` → Roles). A skill that runs inside
a worker collects what it would have written and returns it in the handoff
instead.

## Conventions

- **Create an issue**: `bd create --title "..." --description "..." --type=task|bug|feature --priority=<0-4> [--parent=<id>] [--acceptance="..."] [--design="..."]`. Priority is a digit (0 critical … 4 backlog), never a word. Use `--parent` for work under an epic; the parent today is `homelab-bqo` (the platform layer refactor).
- **Read an issue**: `bd show <id>` (add `--json --include-comments` for machine reading).
- **List issues**: `bd list --status=open` / `bd ready` (open and unblocked); filter with `-l <label>`, `--label-any`, `--exclude-label`; `--json` for structured output. `bd search <query>` for keyword search.
- **Comment on an issue**: `bd comment <id> "..."`. Longer supplementary context goes in `bd update <id> --notes="..."`.
- **Apply / remove labels**: `bd label add <id> <label>` / `bd label remove <id> <label>`.
- **Close**: `bd close <id> --reason="<sha>: <why>"`. Several at once: `bd close <id1> <id2>`.
- **Dependencies**: `bd dep add <issue> <depends-on>` (the second blocks the first); `bd blocked`, `bd show <id>` list them.
- **Never** `bd edit` — it opens `$EDITOR` and blocks an agent. Update fields inline with `bd update <id> --title/--description/--notes/--design`.

## When a skill says "publish to the issue tracker"

`bd create` as above. A spec that spans several implementation issues is one
parent bead with the spec in `--design`, and one child bead per issue.

## When a skill says "fetch the relevant ticket"

`bd show <id>`. The user will normally pass the id; `bd search` when they
pass a phrase.

## Wayfinding operations

Used by `/wayfinder`. The **map** is a bead whose children are the tickets.

- **Map**: a bead labelled `wayfinder:map`, its body (Notes / Decisions-so-far / Fog) in `--design`.
- **Child ticket**: `bd create --parent=<map>` with the question in the description and a `wayfinder:<type>` label (`research`/`prototype`/`grilling`/`task`).
- **Blocking**: `bd dep add <child> <blocker>`. A ticket is unblocked when every blocker is closed — `bd ready` is the live gate.
- **Frontier query**: `bd ready` scoped to the map's children (`bd show <map>` lists them), drop any with an assignee; first in map order wins.
- **Claim**: `bd update <n> --claim`, the session's first write.
- **Resolve**: `bd comment <n> "<answer>"`, then `bd close <n>`, then append a context pointer (gist + link) to the map's Decisions-so-far with `bd update <map> --design="..."`.
