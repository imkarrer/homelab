---
name: homelab-route
description: Decide which model does a piece of homelab work - the supervisor's own frontier model, or agent-hub's local Qwen3-Coder on ac-box (free, private, slow). Use when dispatching a worker, when asked to delegate to agent-hub or the local model, and when a task looks like it could be routed local.
---

# Routing work between models

Two backends exist. The supervisor picks per task; the task, not the
backend, decides.

| | Frontier (the supervisor's own model) | agent-hub (`agent-hub-llm` on ac-box) |
| --- | --- | --- |
| Model | whatever the harness runs | `coder`: Qwen3-Coder-Next 80B-A3B, Q8_0, ctx 32k; `instruct`: its general-purpose sibling for prose and judgement; both behind llama-swap, one loaded at a time (`hub-ask.sh -M`) |
| Cost | per token, external | zero, and nothing leaves the LAN |
| Prefill | fast | **~140 tok/s** (measured 14 Sep 2026 on the live unit; was 13 the day before — agent-hub `docs/prefill-tuning.md`) — 4k tokens ≈ 30 s before the first output token, the full 32k ≈ 4 min |
| Generation | fast | ~13 tok/s — 500 tokens ≈ 40 s |
| Swap | — | ~20-60 s the first call after naming a model that is not the one loaded |
| Reach | tools, files, ssh | text in, text out; no tools |
| Reliability of *facts* | good | **poor** — asked what `mkOverride 90` means, it said `mkForce` is 100 and `mkDefault` 50; both are wrong (50 and 1000; lower wins) |

The mechanism today is `scripts/hub-ask.sh`: one prompt, an answer, a
prompt budget enforced before sending. Once a harness can bind a subagent to
the local backend natively, `homelab-local-worker` is the definition to bind;
until then that agent drives `hub-ask.sh` itself.

## Route local when all four hold

1. **The prompt fits in ~6k tokens** including every file it needs (that budget
   is now ~45 s of prefill, not 8 min; it stays because a task needing more
   context than that is usually a task needing `grep`, not a bigger prompt). `hub-ask.sh`
   counts and refuses above budget; a task that needs the whole module tree
   to reason about is not a local task, however simple the edit.
2. **The output is bounded** — a function, a test case, a doc section, a
   commit message, a shell script — not an open-ended exploration.
3. **The gate, not a reader, verifies it.** `hub-gates.sh` and the eval
   harnesses catch a wrong Nix expression; nothing catches a wrong sentence.
   Code with a check beats prose with none.
4. **Latency is acceptable** — nobody is waiting on this turn. Background
   dispatch, a batch of small tasks, overnight.

## Tasks that fit

- A harness case in `modules/*/tests/eval*.nix` from a stated fixture and
  expected verdict — the check is the proof.
- A shell script or a `jq`/`awk` transform with a described input and output.
- Rewriting a comment block or a docs paragraph to a stated shape, with the
  paragraph supplied.
- A commit message from a diff under ~200 lines.
- Classifying or summarising bounded text: a journal excerpt, a `bd list`,
  a gate failure — where the reader will act on the summary, not trust it.
- A first draft of a function against a stated signature and test.

## Tasks that do not

- Anything that is a **decision**: an ADR, a tenant boundary, a port scope,
  what to bounce. The disruption table exists because guessing is an outage.
- **Facts about NixOS, nixpkgs, or this repo's history.** See the table.
- Multi-file refactors, renames across trees, anything needing `grep` over
  the hub to know what it touches.
- Reviewing. The reviewer's job is judgement against rules; that is the
  frontier model's.
- Anything on the critical path of a human waiting.

## Sending it

```bash
bash scripts/hub-ask.sh -S .agents/skills/homelab-route/system.md -f <file> "<brief>"
```

- Keep the system prompt **byte-identical** across calls: llama-server
  caches the KV of a shared prefix per slot, and a repeated prefix is prefill
  not paid twice (`cache hit N` on stderr).
- One question per call. A 300-token brief with one file beats a 3k-token
  brief that asks for three things; the second costs four minutes more and
  the model handles the first better.
- Read the stderr line. `finish length` means `-m` was too small and the
  answer is truncated; `prompt N tok` far above the estimate means a `-f`
  file was bigger than it looked.
- Then gate it. The local model's output enters a worktree like any other
  worker's and earns the same PASS line before it is a handoff.
