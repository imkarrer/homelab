# ADR 0010: The Z840 Serves Models And Nothing Else; arcade-box Hosts The Rest

**Status:** Proposed, 19 Sep 2026. No hardware bought, nothing landed. The
decision is recorded first because the host names and the glossary change
touch every tree before a single unit moves.

## Context

ac-box is an HP Z840: 2× Xeon E5-2680 v4, 251 GiB of DDR4-2133 ECC RDIMM as
8 × 32 GB — exactly one DIMM per channel on each of two NUMA nodes (measured
19 Sep, `dmidecode -t memory`). Its one irreplaceable property is that
memory: an 80B Q8 model is ~85 GB of weights, and generation speed is
memory-bandwidth-bound, so the 13.3 tok/s in `agent-hub/docs/prefill-tuning.md`
is the eight channels streaming. Pulling any DIMM removes a channel.

Everything else on the machine is light and wants the opposite of what the
model server wants:

| Tenant | Real need | Hazard |
| --- | --- | --- |
| assetto, bot, arcade | ~4 cores, ~8 GB, an address the router forwards to and the stations mount | a switch mid-race |
| observability | ~2 GB, a disk for the TSDB | going dark with the host it watches |
| ci | a few cores per job, NVMe, privileged Docker, restarted daily | HAZARD 2: the agent that restarts itself (`modules/ci/default.nix`) |
| agent-hub | all the memory, all the channels, all the cores | being fenced to make room for the others |

ADR 0002's tiers and the cgroup fence exist to make these share one box.
They work, at a cost the tenants file records: CI sits in `batch.slice` at
CPUWeight 0.05 and queued a PR build nineteen minutes on 18 Sep
(`inquire-platform/.buildkite/pipeline.yml`); the model server holds 0.81 of
memory and 23 of 28 cores and still cannot keep both 80B models resident;
and every switch on the box waits on an empty-lobby window whether or not
it touches a lobby.

Options priced and rejected:

- **Rob 128 GB from the Z840 for a CI box.** Halves the channel count per
  socket, so roughly halves generation speed. Rejected on the measurement.
- **A second Z840 (~$600) for everything that is not a model, plus a Tiny
  for the lobbies** — three hosts. Correct in shape, and the CI host is
  deferred rather than rejected: see Consequences for the trigger.
- **SSH from a CI agent into the model host** for the steps that write
  local state. Works, but hands CI a credential onto a host and contradicts
  `ac-host/docs/ci-cd.md` "Why no SSH" and ADR 0006. Rejected; the model
  host needs no pipeline-driven delivery at all (below).

Measured 19 Sep for the sizing: `/var/lib/ac-host` 12 GB, `/srv/arcade`
460 MB, `/var/lib/arcade` 21 MB, `/var/lib/prometheus2` 98 MB. Nothing
outside agent-hub needs a large disk.

## Decision

**Two hosts. The Z840 hosts models and nothing else, hand-switched. A Tiny
hosts every other tenant, including CI, on the delivery machinery that
already exists.**

| Host | Hardware | Tenants | Delivery |
| --- | --- | --- | --- |
| **llm-box** | the existing Z840, renamed from `ac-box` | `agent-hub` only (llama-server, nginx, qdrant) | **none.** No Buildkite agent, no `modules/deploy`, no `environment-pull`, no tiers, no fence. The operator runs `nixos-rebuild switch --flake .#llm-box --target-host llm-box` when a homelab build is green, and pulls + restarts the agent-hub environment by hand. CI gates this host (`flake check` evaluates `nixosConfigurations.llm-box`; agent-hub's pipeline proves its manifest) and stages nothing on it |
| **arcade-box** | Lenovo ThinkCentre M920q Tiny, i7-8700T (6c/12t -- measured 26 Sep 2026 by `lscpu`; drafted here as an i7-9700T), 31 GiB usable of 32 GB dual-channel, 954 GB NVMe (~$300 used) | `assetto`, `bot`, `arcade`, `observability`, `ci` | as ac-box today: `modules/deploy` timer with the window (ADR 0006/0008), `environment-pull` (ADR 0009), tier → slice (ADR 0002) without the cpuset fence. The Buildkite agent runs `--spawn 2`, in `batch.slice`, with a `MemoryMax` so a runaway job OOMs itself and not a lobby |

**Why llm-box gets no machinery.** The deploy edge exists for hosts where a
switch has a window and a hazard. llm-box has one tenant, no lobbies, no
agent that could restart itself, and its changes are rare and interactive —
every number in `prefill-tuning.md` was a hand measurement. Automating a
thing done four times a year by the person tuning it is machinery for its
own sake. The model server gets all 28 cores, all 56 threads and all 251 GB;
whether that is one instance spanning both sockets or one 80B pinned per
NUMA node (85 GB fits in a socket's 128 GB, with its 14 cores and 4 local
channels) is a `llama-server` flag decided at tuning time, not a platform
concern.

**Amendment, 26 Sep 2026 (`homelab-ygc.14`): the environment edge stays,
fed by a poll.** "No machinery" above was written about the *closure*: the
Z840 is still switched by hand. But `agent-hub`'s *environment* (ADR 0009)
had an edge before the cutover -- Buildkite on the same box staged a green
sha, `agent-hub-environment-pull` applied it -- and moving CI to arcade-box
cut it: a green agent-hub build staged a record on a host with no agent-hub
stub, and the Z840's tree fell behind main with nothing to say so. The
staging half is now the host's own timer, `agent-hub-environment-poll`
(`homelab.tenants.<t>.environment.poll`, `modules/tenant/environment-poll.nix`):
two unauthenticated GitHub API calls every ten minutes read main's HEAD and
its commit status for the tenant's own `buildkite/<slug>` context, and a
green sha not already staged or applied is written in exactly
`queue-environment`'s record with `source = "github-poll"`. The applying half
is unchanged. What this costs: a tenant's green-ness is now read off GitHub's
commit status, so a pipeline whose statuses do not reach GitHub is a tenant
that never deploys on such a host -- and on the day this landed, Buildkite
published none for `agent-hub`, `homelab` or `home-arcade`, only for the two
pipelines connected through its GitHub App (`docs/architecture.md`, row 35).
The table's "no `environment-pull`" was never true of the built system and
is read as "no CI agent".

**Why arcade-box keeps CI beside the lobbies.** The Tiny's budget is ~24 GB
and ~6 cores after the standing load; the heaviest realistic trio of jobs
(homelab `flake check`, inquire unit, one inquire smoke stack) is ~18 GB and
mostly single-threaded. Two agents clear the queue — the queue was one agent,
not slow jobs. CI on the Tiny is faster in wall time than CI on the Z840
today because it stops competing with an 80B for cores. The costs are the
ones ADR 0002 already manages: a switch that touches CI's units waits for a
window, and HAZARD 2 lives on the host people notice. Both are the trade
lived with today, moved off the model box.

**Tenant assignment is a host fact in the contract:** `hosts/<name>/tenants.nix`
declares which tenants a host runs, exactly as it declares their ports and
tiers. The contract does not change shape; it gains a second instance. The
six tenants do not split or merge. `observability` moves whole; llm-box's
node exporter and the model server's `/metrics` are scraped over the LAN, as
agent-hub's already is.

**Pipelines change by queue name and by which host `queue-closure` stages.**
Gates: `queue: self` → `queue: ci`. Local steps (ac-host's `queue-prod`,
`promote-image`, `pages`, `ops.yml`; homelab's `queue-closure`,
`queue-environment`) stay local, because CI and the state they write share
arcade-box. `hub-queue-closure.sh` stages `nixosConfigurations.arcade-box`.
No step targets llm-box. The `image` step keeps loading into the local
Docker daemon; no registry.

**Rename, not alias.** The Z840 becomes `llm-box` in the same change that
strips it to agent-hub. `ac-box` is a misnomer the day the lobbies leave,
and an alias would be a third name to explain. The rename is its own step
with its own runbook: ssh config, `hosts/`, the tracker, every tree's docs.

## Consequences

- **The glossary loses "the box".** `CONTEXT.md` defines **Box** (any host,
  always named), **llm-box**, **arcade-box** and marks "the box" _Avoid_.
  The sweep of existing "the box" references across the four trees is a
  bead. Until it lands, "the box" in an older doc means the machine that was
  ac-box when it was written.
- **Order:** arcade-box first, llm-box second. arcade-box is the only
  cutover with a real window (lobbies, router forwards, the stations' SMB
  mount) and it takes CI with it, so the Z840 is emptied by a single
  move. Then the Z840 is stripped, renamed and retuned with nothing
  competing for its cores.
- **ci-box is deferred, not rejected.** A second Z840 (2× E5 v4, 64 GB,
  ~$600) takes `ci` off arcade-box the first time either trigger fires: the
  Buildkite queue wait on arcade-box exceeds a few minutes at `--spawn 2`,
  or a CI-only closure change waits on an empty-lobby window. Its design is
  the three-host shape above with `queue: ci` moved; nothing in this
  decision has to be undone for it.
- **Cost:** ~$300 of used hardware, ~15 W. The Z840 stops giving 0.19 of its
  memory and 5 cores to everything else, which is what makes a second 80B
  resident.
- **What this does not decide:** secrets distribution for a second host
  (`modules/platform/secrets.nix` has served one), LAN name resolution for
  arcade-box, and whether the agent-hub environment moves to FloxHub so the
  hand pull becomes a generation switch. Each is a bead; none changes this
  shape.
