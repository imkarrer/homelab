# Architecture

Two architectures, and the distance between them.

**Part I** is what the two hosts enforce *today*, read off each host rather than off the
config. As of 26 Sep 2026 evening both run `ab21161`, which is HEAD — but the rule stands,
because for three days in September the Z840 and HEAD were 25 commits apart, and drawing the
config as the current state is how this repo's stale comments got written.
**Part II** is the target: not a wish list, but the design the repo already
commits to in `README.md`, the ADRs and the module headers, drawn as one
picture. **Part III** is the delta — every gap between the two, what closes it,
and where that stands.

Mermaid rather than an image or a hosted link, so a diagram is reviewed in the
same diff as the change it describes and corrected when the code moves. Facts
here are load-bearing and dated; when one stops being true, fix it in the same
commit that made it false. Part I last verified against both hosts **26 Sep 2026 17:45 CDT,
both at `ab21161`** — arcade-box switched to it by `homelab-deploy` at 13:48 CDT, one minute
after `queue-closure` staged it; the Z840 by hand, the way ADR 0010 leaves it.

---

# Part I — Current

## I.1 The layers

The structure is already the target structure; this is the one part of the
design that is fully built. `README.md` states it as a table. The part a table
cannot show is that the dependency arrow only ever points one way.

```mermaid
flowchart TD
    L3["<b>L3 · tenants</b><br/>ac-host · home-arcade · agent-hub<br/><i>declare, never reach — ac-host as a flake input; home-arcade and agent-hub (since 18 Sep 2026, ADR 0009, homelab-158.11) as flox environments whose whole units are stubs in the host that runs them (hosts/arcade-box for arcade, hosts/ac-box for agent-hub), with no flake input and no Nix of their own in the closure</i>"]
    L2["<b>L2 · shared services</b><br/>modules/observability · modules/ci · modules/deploy<br/><i>consume the contract</i>"]
    L1["<b>L1 · the contract</b><br/>modules/tenant<br/>schema · ports · resources · metrics · quiet"]
    L0["<b>L0 · platform</b><br/>modules/platform<br/>hardware · NICs · identity · Docker · Nix · sshd · boot"]
    HOST["<b>host composition</b><br/>hosts/arcade-box/ · hosts/ac-box/<br/><i>the one place allowed to know both sides — one per host, one contract, one shared platform list in flake.nix</i>"]

    L3 -- "declare against" --> L1
    L2 -- "read declarations" --> L1
    L1 -- "assumes nothing about" --> L0
    HOST -- "wires tenant options to host facts" --> L3
    HOST -- "sets homelab.host.*" --> L0

    classDef layer fill:#eef3f4,stroke:#14666e,stroke-width:1px,color:#101819;
    classDef host fill:#fff,stroke:#8d5c0c,stroke-width:1.5px,color:#101819;
    class L0,L1,L2,L3 layer;
    class HOST host;
```

**L0 knows nothing about tenants. L1 knows only the schema. L2 reads
declarations. L3 declares without knowing its neighbours.** A module that
reaches sideways or guesses a host fact instead of reading it is the bug this
structure makes visible — `modules/observability` carried `192.168.1.1` twice
until `6e18170`, and that was the last such literal in the module layer.

## I.2 How code reaches each host today

Since the cutover of 26 Sep 2026 there are two hosts, and the edges split by
where the CI agent is. **arcade-box has every automatic edge**: the tenant
tree, the closure and arcade's environment are staged by its own agent
(`arcade-box`, `queue=self`) and applied by units on the same host. **The
Z840 has one automatic edge and no closure edge**: `agent-hub`'s environment
is staged by the host's own poll of GitHub (`homelab-ygc.14`) and applied by
its pull unit, and its closure is switched by an operator from a sha already
on origin (ADR 0010, "no machinery"). The diagram is that shape, read off
both hosts on 26 Sep 2026 17:45 CDT; the paragraphs after it are the history
of how the arcade-box edges were proven, on the Z840, 12–16 Sep, and in them
"the box" and "ac-box" mean the Z840 when it ran every tenant.

```mermaid
flowchart LR
    subgraph ARC ["arcade-box — 192.168.1.50 — assetto · bot · arcade · observability · ci"]
        direction LR
        AG["Buildkite agent <b>arcade-box</b><br/>queue=self, in batch.slice<br/><i>gates every tree; runs the local steps</i>"]
        AG -- "queue-prod<br/><i>stages sha</i>" --> A4["/var/lib/ac-host/pending-src"]
        A4 -- "the bot at 03:00 queues DOWNTIME<br/>ci_downtime applies + one recycle" --> A6["/var/lib/ac-host/src<br/><b>tenant tree</b>"]
        AG -- "queue-closure<br/><i>stages rev</i>" --> B4["/var/lib/homelab/pending-closure.json"]
        B4 -- "homelab-deploy, continuous (ADR 0008)<br/>busyCheck · within a minute<br/><i>13:47 staged → 13:48 switched</i>" --> B6["/run/current-system<br/><b>ab21161</b>"]
        AG -- "queue-environment<br/><i>stages a FloxHub generation</i>" --> C4["pending-environment-arcade.json"]
        C4 --> C5["arcade-environment-pull"] --> C6["arcade-freeciv · arcade-mindustry<br/><b>generation 2</b>"]
    end

    subgraph Z ["ac-box (the Z840) — 192.168.1.51 — agent-hub"]
        direction LR
        D4["agent-hub-environment-poll.timer<br/>every 10 min: main HEAD + status<br/>buildkite/agent-hub<br/><i>published from 20:05 CDT; first sha staged 20:19 (row 35)</i>"]
        D4 -- "a green sha" --> D5["pending-environment-agent-hub.json"]
        D5 --> D6["agent-hub-environment-pull"] --> D7["agent-hub-llm<br/><b>llama-swap on :8100</b>"]
        OP["an operator, from WSL<br/>nixos-rebuild switch --refresh<br/>--flake github:imkarrer/homelab/&lt;sha&gt;#ac-box"] --> Z6["/run/current-system<br/><b>ab21161</b>"]
        ZT["homelab-deploy.timer<br/><i>armed; nothing stages here</i>"] -.-> Z6
    end

    ORIGIN["origin: ac-host · homelab · home-arcade · agent-hub"] --> AG
    ORIGIN -- "GitHub API" --> D4

    classDef ok fill:#dae8df,stroke:#2c6b4b,color:#101819;
    classDef hand fill:#f0e6d0,stroke:#8d5c0c,color:#101819;
    class A6,B6,C6,D7,Z6 ok;
    class OP,ZT hand;
```

*What follows is the record of 12–16 Sep 2026 on the Z840, when it ran every
tenant. Every "not yet" in it has since closed (rows 2, 21, 29, 33, 34); the
machine the two paths now land on is arcade-box.*

**The top path has no human on it, and has not for some time.** This document,
ADR 0006's context section and `hub-status.sh` all said "a human sets
`DOWNTIME=1`". Read off the box on 12 Sep: the Discord bot's countdown posts
that build itself at mark 0 (`bot/bot.py` `fire_downtime_mark`), and
`last-downtime.json` shows it did so at 03:00:11 that morning with nobody
present. `queue-prod` stages, the bot applies, the lobbies recycle once behind
a ten-minute countdown. The one lobby bounce on this machine is that one, and
it is the designed one. What that path *depends on* is two things: the bot
container being up at 02:59, **and a live `BUILDKITE_API_TOKEN` in
`/var/lib/ac-host/.env`** — the bot only *asks* Buildkite for the build. The
first was checked from 13 Sep; the second was not, and it is the one that
failed that morning. Evidence, 13 Sep: `ac-host` `e72c1e4` went green at 01:28
CDT and `queue-prod` staged it (build 36). At 03:00 the countdown ran its
300/60/30/5/0 marks and at mark 0 logged `downtime pipeline trigger failed:
Buildkite trigger failed HTTP 401` — to docker logs only, nowhere a human
looks. `ac-host-nightly` recycled blackhawk/road-america/gingerman at 03:00:01
on the old tree `340b4fb`; `last-downtime.json` still reads
`{"date":"2026-09-12","sha":"","at":"2026-09-12T08:00:11Z"}`. At 08:50 a `GET
https://api.buildkite.com/v2/access-token` with the token from `.env` returned
401: the token is dead, and `.env`'s mtime is 6 Sep. So "the bot is up" was
true all night and proved nothing. `hub-status.sh` now prints that file's date
next to the bot's uptime and makes it a verdict when a tree is pending and the
date is behind the 03:00 that should have applied it. `ac-host` `596b970`
(bead `.49`) has the bot post a trigger failure to `#server-status` and
validate the token at startup — staged by build 38, and it reaches the box
only through the very build that needs the rotated token first.

**The bottom path ends at a timer as of generation 34** (`homelab.deploy.enable
= true`, switched 12 Sep 20:50 CDT by hand — the last hand switch). Its first
firing was Sunday 13 Sep 03:30:03: `homelab-deploy.service` logged "nothing
staged at /var/lib/homelab/pending-closure.json; nothing to do" and exited
clean — the timer has now been watched firing, on its no-op path. It stages
nothing yet because the agent lacks its mount, and the 04:00 recreate that
morning came from the *old* compose, so it still lacks it (row 2, row 29).
Until `1c6827f` this path was checked by
nothing; it is *current* today because an operator switched it.
`home-arcade` and `agent-hub` were flake inputs, not deploy targets, until
18 Sep 2026: they reached the box only through homelab's closure, and only
when `flake.lock` moved — row 24, and the bump-lock step built 13 Sep. Since
`homelab-158.11` neither is an input; each reaches the box through its own
environment edge (a sha or a FloxHub generation, staged by its CI on the host
that runs the agent -- or, on a host with none, by that host's own poll of
GitHub's commit status, `environment.poll`, `homelab-ygc.14` -- and applied
by `<tenant>-environment-pull` on the box), and `ac-host` is the one tree
bump-lock still moves.

**Why the applying edge is not simply a Buildkite step** (ADR 0006): the agent
that would run it is a container *on the host being switched* (the Z840 then,
arcade-box now) and, since generation 31, a systemd unit owned by the very
closure being switched. A switch running on it
kills the job midway — a circularity, not a risk to be managed. So CI only
*stages* (`queue-closure`, one file, nothing bounced) and a systemd unit on the
box applies. Both halves are in git as of 12 Sep evening and the unit is
enabled as of generation 34. What turned the dotted edges solid was `homelab.deploy.enable`,
one line, and it was deliberately the operator's — an agent's attempt to commit
it was stopped by the harness classifier, correctly.

**And a hazard the diagram cannot show:** a bare `github:imkarrer/homelab` ref
is cached by nix for an hour. A switch at 12:51 today resolved to the rev cached
at 12:00, built the identical closure, and applied a no-op while reporting
success. The deploy unit is immune (it stages a full sha); a human switch is not
— always `--refresh`. `hub-status.sh`'s cheap check could not see this; only
`HUB_STATUS_EXACT=1` could, which is why `configurationRevision` is now set.

## I.3 Where work runs today

Live values from `systemctl show` and `docker inspect` on each host, 26 Sep
2026 17:45 CDT.

```mermaid
flowchart TB
    subgraph ARC ["arcade-box — 6 cores / 12 threads, 31 GiB — weights only, AllowedCPUs empty on every slice"]
        direction TB
        subgraph SYS ["system.slice — weight 100, uncapped"]
            S1["ac-host-static · ac-host-bot · ac-host-env<br/>ac-host-nightly.timer"]
            S2["sshd · fail2ban · docker · NetworkManager"]
        end
        subgraph CRIT ["critical.slice — weight 500, 6.2 GiB"]
            C1["3 × ac-static-* containers"]
            C2["auth · details · plugin sidecars"]
            C3["ac-host-bot-1"]
        end
        subgraph INT ["interactive.slice — weight 200, 6.2 GiB"]
            I1["arcade-freeciv · arcade-mindustry"]
            I2["samba-smbd · samba-winbindd · rsync"]
            I3["observability × 8"]
        end
        subgraph BG ["background.slice — weight 50, 1.55 GiB, inactive"]
            G0["<i>no tenant of this tier here</i>"]
        end
        subgraph BAT ["batch.slice — weight 300, 13.95 GiB"]
            T1["ac-host-ci.service: buildkite agent · minio<br/>nix-daemon"]
        end
        COMPOSE["cgroup_parent: &lt;tier&gt;.slice<br/>in each tenant's compose file"] -- "the only thing that puts<br/>a container in a tier" --> CRIT
        COMPOSE --> BAT
    end

    subgraph Z ["ac-box (the Z840) — 28 cores / 56 threads, 251 GiB — enforce.slices = false, no tier slice exists"]
        direction TB
        subgraph ZSYS ["system.slice — weight 100, uncapped"]
            Z1["<b>agent-hub-llm</b><br/>llama-swap → llama-server --threads 28<br/>unit AllowedCPUs 0-27 (placement, not a fence) · NUMA interleave"]
            Z2["nginx :8100 · qdrant :6333 · node exporter :9100"]
            Z3["sshd · fail2ban · NetworkManager"]
        end
    end
```

**Assetto's containers are sliced; its units are not.** `ac-host-static.service`
stays in `system.slice` on purpose — `resources.nix` assigns `Slice=` only when
`tier != critical` **and** `quiet.drainable`, because `Slice=` applies at unit
start and restarting `ac-host-static` means `docker rm -f` on three live race
servers. The six racing containers and the bot carry `CgroupParent =
critical.slice`, CI's two `batch.slice` (`docker inspect`, arcade-box).

**There is no fence anywhere since 26 Sep 2026.** On the Z840 the fence
existed so a build or the model server could not reach the lobbies' cores
(`3fef4fe` did the arithmetic in physical cores); with one tenant there is
nothing to fence from, and `agent-hub-llm`'s `AllowedCPUs = 0-27` is the 28
physical cores its 28 threads want — the SMT siblings cost memory bandwidth
— not a boundary (`homelab-ygc.13`). On arcade-box `resources.nix` would
carve one or two of six cores for every CI build and idle them the rest of
the day, so `homelab.tiers.{background,batch}.fence = false` and `CPUWeight`
is the whole story: 500 for the lobby containers against 300 for a build,
consulted only under contention, with `MemoryMax` the ceiling a runaway job
hits.

**Slicing the unit that runs `docker compose` does nothing.** `dockerd` places
container scopes under `system.slice` no matter who invoked it. Only
`cgroup_parent` in the tenant's own compose file moves a container (ADR 0005).

## I.4 Tenants, network, secrets — as enforced

| | Current |
| --- | --- |
| **Tenants** | 6 declared across two hosts, 6 in the two inventories: arcade-box's `/etc/homelab/tenants.json` lists `assetto`, `bot`, `arcade`, `observability`, `ci`; the Z840's lists `agent-hub`. Every running tenant unit is in exactly one tenant's `units` on exactly one host. |
| **Network** | arcade-box: `eno2` at `192.168.1.50` carries everything — LAN, forwarded AC traffic, the stations' SMB, sshd; no `mgmt` entry, the Tiny has one port. The Z840: `enp8s0` at `192.168.1.51`; `eno1` administratively up with **no carrier**, declared `mgmt` with no address (ADR 0007, row 11). Both addresses are Dream Router reservations by MAC and the nine lobby forwards point at `.50` — `docs/current-state.md` §4 has the router's facts (`homelab-bqo.42`). |
| **Secrets** | sops-nix on arcade-box: `secrets/ac-box.yaml` (the name predates the split; it carries both hosts' recipients) rendered at activation — `ci-env`, the tenant tree's `.env` (`ac-host-env.service`), the observability files, `arcade-smb-password`. The Z840 imports no secrets module: nothing on it needs one (`flake.nix`, the ac-box list since `aa48765`). `whitelist.json` is arcade-box state, never git. |
| **Metrics** | One Prometheus, on arcade-box. Its local jobs plus the Z840 as a peer (`homelab.host.peers.ac-box`, `116c12e`): `node` at `192.168.1.51:9100` from `modules/platform/node-exporter.nix`, `agent-hub` at `192.168.1.51:8100` through the tenant's nginx; `host=` on every target, host alerts per machine. |
| **Gates** | `checks.ac-box`, `checks.arcade-box` (both full toplevels) and the harness checks `check.nix` discovers under `modules/*/tests/eval*.nix` (nine on 26 Sep 2026), all built on arcade-box's agent; `hub-gates.sh` evaluates every `nixosConfigurations` attribute, so a third host is gated the moment it exists. |
| **Reporting** | `hub-status.sh` is host-aware since `homelab-ygc.4` (`scripts/lib/hosts.sh` reads the hosts off the flake): one BOX section per host, closure drift exact per host via `configurationRevision`, environment pairs per tenant. `HOMELAB_BOX=<host>` narrows to one. |

---

# Part II — Target

What the repo already says it is building, drawn as one picture. Every claim
below is sourced to a file that states it; nothing here is invented for the
diagram.

## II.1 How code reaches each host

Three paths, all staged in CI — or, on a host with no agent, by that host's
own poll of GitHub — and applied on the host by systemd, all reported as a
pending/applied pair. **No human at an SSH prompt on the path** (ADR 0006,
`README.md` goal 3), with one deliberate exception since ADR 0010: the Z840's
closure, which an operator switches by hand from a pushed sha, because one
tenant with rare, interactive changes does not earn the machinery (row 41).
The third path — a tenant's **environment**
(ADR 0009, live for `agent-hub` since 18 Sep 2026) — is the closure's shape
one layer down: the tenant's CI stages its sha, `<tenant>-environment-pull`
checks it out, substitutes every path the lock names (never compiles),
activates once online, records it and restarts the stub; the closure is
touched only when a host fact changes.

```mermaid
flowchart LR
    subgraph TENANT ["tenant tree"]
        direction LR
        A1["ac-host"] --> A2["origin"] --> A3["Buildkite<br/>test · lint · image<br/><i>flox containerize → the box's daemon</i>"]
        A3 -- "wait: ~" --> A4["queue-prod<br/>stages sha"]
        A4 --> A6["03:00 window<br/>ci_downtime applies<br/>+ recycle once"]
    end

    subgraph CLOSURE ["system closure"]
        direction LR
        B1["homelab<br/>+ ac-host as input"] --> B2["origin"] --> B3["Buildkite<br/>flake check · eval · harnesses"]
        B3 -- "wait: ~" --> B4["queue-closure<br/>stages rev to<br/>/var/lib/homelab on arcade-box"]
        B4 --> B5["homelab-deploy on arcade-box<br/>continuous (ADR 0008) · consults quiet policy<br/><b>defers if assetto busy</b>"]
        B5 -- "nixos-rebuild switch<br/>--flake …/rev#arcade-box" --> B6["arcade-box /run/current-system<br/>== origin/main"]
        OP["an operator (ADR 0010)"] -- "nixos-rebuild switch --refresh<br/>--flake …/&lt;sha&gt;#ac-box" --> B7["the Z840 /run/current-system<br/>== a sha on origin"]
    end

    subgraph ENV ["tenant environment (ADR 0009)"]
        direction LR
        C1["agent-hub · home-arcade<br/>.flox (+ llama-swap.yaml)<br/><i>no Nix; the unit is a stub in the closure</i>"] --> C2["origin"] --> C3["Buildkite<br/>under the flox plugin<br/><i>pushes every lock output to MinIO</i>"]
        C3 -- "trigger: homelab (CI host)" --> C4["queue-environment<br/>stages sha to<br/>/var/lib/homelab"]
        C3 -- "commit status buildkite/&lt;slug&gt;" --> C4b["agent-hub-environment-poll.timer<br/>(a host with no agent: the Z840)<br/>stages the green sha itself"]
        C4 --> C5["agent-hub-environment-pull.path<br/>checkout · substitute-only · one warm<br/><b>never compiles</b>"]
        C4b --> C5
        C5 -- "restart under quiet policy" --> C6["agent-hub-llm.service<br/>flox activate -d /var/lib/agent-hub/env"]
    end

    STATUS["hub-status.sh<br/>pending vs applied, all three paths<br/>closure exact via configurationRevision,<br/>environment via the run store path"]
    A4 -.-> STATUS
    B4 -.-> STATUS
    B6 -.-> STATUS
    B7 -.-> STATUS
    C4 -.-> STATUS
    C6 -.-> STATUS

    classDef ok fill:#dae8df,stroke:#2c6b4b,color:#101819;
    class A6,B6,B7,C6 ok;
```

Properties the target must hold, none optional (ADR 0006 "Consequences"):

- **The drain policy is consulted, never assumed.** The deploy unit's
  `busyCheck` is the only thing between a merge and `docker rm -f` on live race
  servers. It defers; it never drains. It fails closed if the inventory is
  unreadable. *Built and tested — `modules/deploy`.*
- **Every tree that reaches the box has a real gate.** For a flox tenant that
  gate is its own CI under the flox plugin (`hub-gates.sh` reproduces it);
  for the closure it is `nix flake check` plus the harnesses.
- **`deploy=buildkite` for homelab in `hub/repos.psv`** — at which point
  `agent-push=yes` means an agent pushing green is, indirectly, scheduling a
  system switch. Reconsider that flag at the same time, not after.

## II.2 Where work runs

Two hosts, two shapes, and since 26 Sep 2026 Part I already draws both
(ADR 0010; `hosts/arcade-box/configuration.nix`, `hosts/ac-box/configuration.nix`).

```mermaid
flowchart TB
    subgraph ARC ["arcade-box — tiers as shares of 31 GiB / 12 threads, CPUWeight only, no cpuset fence (homelab.tiers.*.fence = false)"]
        direction TB
        subgraph SYS ["system.slice — unsliced by design"]
            S1["ac-host-static · ac-host-bot · nightly timer<br/><i>never Slice= — ExecStop is docker rm -f</i>"]
        end
        subgraph CRIT ["critical.slice — 20% mem · weight 500"]
            C1["3 × ac-static-* containers · auth · details · plugin · ac-host-bot-1<br/><i>via cgroup_parent</i>"]
        end
        subgraph INT ["interactive.slice — 20% mem · weight 200"]
            I1["arcade-freeciv · arcade-mindustry · samba × 2 · rsync · observability × 8"]
        end
        subgraph BAT ["batch.slice — 45% mem · weight 300"]
            T1["ac-host-ci.service: buildkite agent · minio<br/>nix-daemon<br/><i>what OOMs is a build, never a lobby</i>"]
        end
        subgraph BG ["background.slice — 5% mem · weight 50"]
            G0["<i>empty: no tenant of this tier on this host</i>"]
        end
    end

    subgraph Z ["ac-box → llm-box — no tiers, no slices, no fence (enforce.slices = false)"]
        direction TB
        Z1["<b>agent-hub-llm</b><br/>all 28 physical cores (AllowedCPUs 0-27 as placement) · all 251 GiB · 28 threads<br/>NUMA interleave · a second 80B resident"]
        Z2["nginx :8100 · qdrant :6333 · node exporter :9100"]
        Z3["agent-hub runner<br/><i>phase 2 — needs sops githubTokenFile (row 9)</i>"]
    end

    classDef phase2 fill:none,stroke:#8d5c0c,stroke-dasharray:4 3,color:#101819;
    class Z3 phase2;
```

What the two shapes say out loud: on arcade-box **the weight is the whole
story** — 500 for the lobby containers against 300 for a build, consulted only
under contention, with `MemoryMax` still the ceiling a runaway job hits; a
fence would carve one or two of six cores off every build and idle them the
rest of the day. On the Z840 **there is nothing to fence from**: one tenant
gets the machine, and `AllowedCPUs = 0-27` on the unit is the 28 physical
cores its 28 threads want (the SMT siblings cost memory bandwidth), not a
boundary. `critical.cpuShare` on arcade-box is still not about how much CPU
assetto gets — its slice holds containers through `cgroup_parent` and the
share sets their weight; with the fence off it reserves nothing.

## II.3 Tenants, network, secrets — as designed

| | Target | Stated in |
| --- | --- | --- |
| **Tenants** | 6: `assetto`, `bot` (split out — "after phase 6", which has landed), `arcade`, `agent-hub` (llm **and** runner), `observability`, `ci` (`units = [ "ac-host-ci.service" ]`). Every running unit in exactly one tenant's `units`, on exactly one host (`hosts/<host>/tenants.nix`, ADR 0010: "tenant assignment is a host fact in the contract"). | `README.md` tenant names; `modules/ci` header; `configuration.nix` agent-hub block; ADR 0010 |
| **Network** | Two hosts on one LAN, each at a router reservation its `host.nix` declares. arcade-box has one port and no `mgmt` entry. The Z840 keeps `eno1` as the `mgmt` scope with no address and nothing plugged in (ADR 0007, row 11) — the scope stays a schema word until a threat model appears; which services would move there is still not stated anywhere in the repo, and would be an ADR. | `hosts/*/host.nix`; `schema.nix` `portScope`; ADR 0004; ADR 0007 |
| **Secrets** | Credentials via **sops-nix**, named in `tenants.<name>.secrets` and provisioned by the platform. `whitelist.json` stays box state, by design — third-party IDs, never git. | `README.md` "Everything is public except one file"; `schema.nix` `secrets` |
| **Metrics** | Every tenant with an endpoint scraped, on whichever host it runs: one collector, on arcade-box, and the Z840 declared as its peer (`homelab.host.peers`), each peer job a per-host target with a `host=` label and host-agnostic alerts. Done for `node` and `agent-hub` (`116c12e`); a third host is a second `peers` entry. | `modules/platform/host-options.nix` (`peers`); `modules/platform/node-exporter.nix` header; ADR 0010 ("scraped over the LAN") |
| **Gates** | Composed eval reaches every module body that will run; harnesses exposed as flake `checks` (expected-throw cases inverted via `tryEval`). | `docs/current-state.md` F7 follow-up |
| **Reporting** | `system.configurationRevision` set from the flake, so the running closure is self-identifying and drift is exact, not a lower bound. | ADR 0006 "Reporting" — pending a ruling on the no-op-proof trade |
| **Reuse** | `modules/observability`, `modules/ci`, `modules/deploy` exported as `nixosModules`, so a second host takes the layer without taking ac-box's tenants. | `flake.nix` `nixosModules` comment; F4 |
| **Box hygiene** | `/etc/nixos/configuration.nix` a `throw`; `wpa_supplicant` off via `mkForce` in `network.nix`; reboot taken so booted == current. | `docs/runbook-decommission.md` |

---

# Part III — The delta

Every gap between Part I and Part II, what closes it, and where that stands as
of 26 Sep 2026. Open rows carry their bead id; `bd ready` is the actionable
list, this table is the narrative. **Human** means a write to a host or a
decision; agents do not do those. Ordered roughly by what unblocks what. Rows
1–35 were written with one host and read "the box" as the Z840; rows 36
onward are the two-host shape (ADR 0010, cut over 26 Sep 2026).

| # | Gap | Closes it | Status |
| --- | --- | --- | --- |
| 1 | 25 commits committed, not on the box | Two switches, `3fef4fe` then HEAD, after HAZARD 1 | **Done 12 Sep** — generations 30 and 31. `HUB_STATUS_EXACT=1` reports CLEAN. |
| 2 | Closure has no deploy path | ADR 0006: `queue-closure` step + `modules/deploy` | `homelab-bqo.36` — Applying half **built, inert, tested**. Staging half **blocked**: the agent mounts only `/var/lib/ac-host`; a `/var/lib/homelab` bind mount must land in `ac-host`'s `docker-compose.buildkite.yml` (one place — `modules/ci` runs that file, it declares no volumes). |
| 3 | Fence is `28-55` on both tiers | `3fef4fe` | **Done** — live at gen 30. |
| 4 | `agent-hub-llm` absent; `tcp/8100` open with nothing behind it | `45f67ab`, `3fef4fe` | **Done** — `llama-server` on `192.168.1.50:8100` since gen 31. |
| 5 | CI stack hand-started, no unit | `4257aea` + HAZARD 1 | **Done** — `ac-host-ci.service` active at gen 31, same volumes. Found and fixed `c97cbbe` in the doing. |
| 6 | Tier shares are the old defaults | `45f67ab`, `0de8c09` | **Done** — live at gen 31. |
| 7 | `ci.units = []` — `ac-host-ci.service` lands in no slice even after #5 | Add it to `ci.units` | **Done** — `214cfdd`, live at gen 31. |
| 8 | Bot is a compose profile inside assetto | Split into a `bot` tenant | **Done** — `5f58ae0`, `28a5e5d`, `ac-host 8c456cb`. Six tenants; the bot has a unit (`ac-host-bot.service`) for the first time. Still assetto's compose project and state directory, declared as shared. |
| 9 | `agent-hub` runner off | sops-backed `githubTokenFile` (`homelab-bqo.10`) + runner image | `homelab-bqo.10` — **Open.** #10's model now exists; this is the second secret to migrate through it. Note the bot's declared `github-token` does not exist on the box either. |
| 10 | Secrets hand-placed | sops-nix | `homelab-bqo.39` — **Model built, first secret migrated** — `a3375be`. Both recipients derive from existing ssh keys (box host key, operator's `id_ed25519_ac-host`); no new key material. `arcade-smb-password` encrypted, round-trip proven by hash, installed at the consumer's path at the next switch. Seven more listed in `modules/platform/secrets.nix`, each following the same shape once this one activates. |
| 11 | `eno1` down; `mgmt` scope unused | ADR 0007 | **Decided — keep the scope, plug nothing in, move nothing.** A second NIC on one LAN isolates nothing; a VLAN would, and there is nothing here to isolate from. The scope stays because the metrics harness uses it as a real fixture. Revisit only if a threat model appears. |
| 12 | `agent-hub` metrics unscraped | `metricsEndpoint.address` | **Done** — `e4bf36f`. Loopback default keeps all five existing jobs byte-identical; new job `agent-hub` at the LAN address; a non-loopback address must be one the host declares. Lands on next switch. |
| 13 | `agent-hub` body ungated | Turn its enable on in the composition | **Done** — enable is true in the composition, so the composed eval reaches the body. |
| 14 | Harnesses not flake `checks` | `tryEval` inversion in the harnesses | **Done** — `2ac2f37`. One shared inversion; the runner is a front-end. Found three negatives in `e4bf36f` passing for the wrong reason (a definition tie, not the assertion) and now requires a throw to come through the module's own verdict. |
| 15 | L2 not exported as `nixosModules` (F4) | `flake.nix` | **Done** — `0a58999`. |
| 16 | `Configuration Revision: Unknown` | `system.configurationRevision = self.rev or self.dirtyRev` | **Done** — `0a58999`, forced by the cache-stale switch: a stamp would have caught it instantly where the heuristic could not. The no-op proof survives via `extendModules { system.configurationRevision = lib.mkForce null; }` on both sides. Lands on next switch. |
| 17 | `/etc/nixos/configuration.nix` stale | Replace with a `throw` | **Done 12 Sep.** |
| 18 | `wpa_supplicant` on a box with no wireless | `networking.wireless.enable = lib.mkForce false` in `network.nix` | **Done** — gone at gen 31. |
| 19 | Booted ≠ current | Reboot | `homelab-bqo.37` — **Human, now safe** — #5 is done, so `ac-host-ci` returns on boot. No kernel change pending. |
| 20 | 13 containers → 9, unexplained | Establish whether four were retired deliberately | **Settled — deliberate.** The four were the dev environment (`ac-host-dev-*` ×3, `ac-dev-static-dev-blackhawk`), torn down from the workstation 7 Sep 23:57 so the unit-based gate would see everything running (bead .14). Criterion 4 rewritten to name the configured set, not a number. |
| 21 | `agent-push=yes` on homelab will mean "schedule a switch" once #2 is live | Reconsider the flag alongside #2 | **Flipped to `yes` 16 Sep** — `fd12f93` decided `ask`; the timer fired on its no-op path (13 Sep), the first staged closure switched by itself under ADR 0008 (15 Sep), and every tree reached the box unattended (agent-hub in 80 s, home-arcade via bump-lock). An agent pushing green homelab work is switching the server, and the gate plus hub-status's build section are what stand between a push and a bad switch. |
| 22 | **`backup = true` is declared by four tenants and implemented by nothing.** No backup job exists for `/var/lib/ac-host` (races, series, whitelist), `/var/lib/monitoring`, `/var/lib/arcade` (saves) or `/var/lib/agent-hub`. A dead disk loses them. | A backup module consuming `tenants.<n>.state.backup` — the contract already says what to back up; nothing reads it | `homelab-bqo.38` — **Built and proven 14 Sep: `scripts/hub-backup.sh` + `docs/runbook-restore.md`.** Not a module and not on the box: it runs on the operator's WSL machine, because a backup that lives on the machine it backs up is not one. It **pulls** — the WSL distro is behind Windows' NAT, exposing an sshd into it is the thing being avoided, and the far side stays read-only (outbound ssh as root with the operator's existing key; nothing here can write to ac-box). The directory list is the contract, read at run time (`nix eval` of `homelab.tenants.<n>.state` where `backup` is true, `hub-backup.sh --list`, ~1s): setting `state.backup = true` on a tenant is the entire change needed to back it up, which is what makes the declaration load-bearing at last. Then `rsync -a --numeric-ids --delete` into `/home/nixos/backup/ac-box/<the box's absolute path>` — which doubles as the instant-restore mirror — and `restic backup` of that tree into `/home/nixos/backup/restic`, `forget --prune --keep-daily 7 --keep-weekly 4 --keep-monthly 6`, `check --read-data-subset=5%` (structure alone would not notice a rotted pack). Repo password: `restic-repo-password` in sops, read through the extracted `scripts/lib/sops-secret.sh` — the one decrypt path, now shared with `lib/buildkite-token.sh` — and handed to restic in the environment, never argv or a file. **Excludes are measured, not guessed**: `/var/lib/ac-host/{src,dist,build,pending-src,_local_wipe_backup}` is 7.9 GB of the 12 GB and every byte of it is in git or rebuildable from it; `content` (4.0 GB — 3.6 G tracks, 429 M cars) is kept, because mods whose upstream is gone are not reproducible and restic stores them once. Two facts the first runs taught, both now in the script: `ssh` without `-n` eats the loop's stdin and silently backs up only the *first* directory (a run that reported success having copied one tenant), and `rsync src/ → dst/` says nothing about `dst`'s own owner and mode, so each staged directory is stamped from the box's `stat` (`/var/lib/arcade` is `0700 arcade:arcade`; a restore that flattens that hands a service a directory it cannot open). Schedule: `hub/systemd/hub-backup.{service,timer}`, 04:30 **America/Chicago** — the box's timezone, so it follows the 03:00 and 03:30 windows rather than preceding them by an hour and a half as a bare UTC `04:30` would — `Persistent=true` for a machine that is not always on. Deliberately **not** in ac-box's closure; `/etc/systemd/system` on that NixOS WSL machine is a read-only symlink, so the runbook installs it through `/etc/nixos/configuration.nix`. Visibility: a `KEY=VALUE` status file and one line in `hub-status.sh`'s DEV section, a verdict past three days. Proof (14 Sep): full pull 4.0 GB in **48 s**, repo **1.685 GiB** for 3.686 GiB (2.19x), `check` clean; `whitelist.json` deleted from the mirror and restored from the snapshot is byte-identical to the box's live copy (`1cf93b62…`), and a whole-tenant restore of `arcade` diffs clean with `992:988 0700` intact. **What is still open, and neither is this row's bead:** the timer is written but not installed (one `nixos-rebuild switch` on the WSL machine, runbook §5), and `/var/lib/qdrant` is declared by `agent-hub` but does not exist on the box — reported per run rather than hidden. **26 Sep 2026 (`homelab-ygc.4`), the second host:** the directory list is built per host from that host's configuration (`enable && state.backup`, evaluated against `nixosConfigurations.<host>`; `scripts/lib/hosts.sh` reads the hosts off the flake), each host is pulled from its own address into `/home/nixos/backup/<host>/…` (ac-box's path unchanged) and snapshotted as its own restic host and forget group; `--list` prints `<host> <tenant> <dir>`. A directory that moves hosts leaves a frozen copy under the old host's mirror until removed by hand -- the cutover runbook's 4.6 owns that step. |
| 23 | Seven secrets still hand-placed | sops, same shape as `arcade-smb-password` | `homelab-bqo.39` — **`/var/lib/ac-host/.env` migrated 13 Sep**; ci's `.env.buildkite` and observability's four files followed on 14 Sep (in order, down this row). The file held four secrets, not two (`AC_ADMIN_PASSWORD`, `GITHUB_STATUS_TOKEN` found on reading it key by key); it is a `sops.templates` entry whose body is the box's file verbatim, proven byte-identical by rendering it with the box's own values (sha256 `d85835fd…` both sides). Not the same shape as the first secret: sops-nix installs a `path` as a *symlink* into `/run/secrets`, and `ci_downtime.py` opens `.env` from inside the agent container, where `/run/secrets` is not mounted and `is_file()` on the dangling link is false — the nightly bot/sidecar rebuild would have skipped silently forever. So the template renders at sops-nix's default and `ac-host-env.service` copies it into place as a regular file (atomic `mv`). The bot is bounced through `PartOf=` on that unit, not `restartUnits`: `ac-host-bot`'s `restartIfChanged = false` makes switch-to-configuration skip it from the activation restart list. First switch installs the rotated Discord and Buildkite tokens from sops (the box's copies are the dead ones from bead `.49`), so it changes the file on purpose -- but that first switch *starts* the copy unit rather than restarting it, and `PartOf=` propagates only restarts, so the bot stayed on its old env until the reboot of 13 Sep; every later switch with a changed render does bounce it. **`compose/.env.buildkite` migrated 14 Sep** (`homelab-bqo.39.1`): `sops.templates.ci-env`, rendered at sops-nix's default `/run/secrets/rendered/ci-env`, and `homelab.ci.envFile` set to that path beside the template. Neither a `path` nor a copy unit this time, by the same test — who opens it: nothing inside a container does; `EnvironmentFile=` and the two `--env-file`s all read on the host, so the rendered file is used in place and the secret leaves the tenant tree `ci_downtime.py` syncs. Five secrets: the Default-cluster agent token (`482de9f7`, what moves the agent into the cluster), `github-status-token` shared with assetto's `.env` (one sops key, two templates), and three MinIO-local values generated new rather than migrated because the box's `S3_CACHE_SECRET_ACCESS_KEY` and `S3_CACHE_SIGNING_KEY` were exposed in an agent transcript on 14 Sep — the signing pair is `flox-binary-cache-2`, whose public key must be *added* to ac-host's `S3_CACHE_PUBLIC_KEY` next to `-1` so the warm cache stays valid. No `restartUnits`: `ac-host-ci` has `restartIfChanged = false` and a changed render is applied by `systemctl restart ac-host-ci` from ssh once the agent is idle, followed by one `mc admin user add` to reset the `flox-cache` user's secret (`minio-init.sh` only creates when absent). **Observability's four files migrated 14 Sep** (`homelab-bqo.39.3`): `grafana-admin`, `grafana-secret-key`, `unpoller-pass`, `discord-webhook` as four `sops.secrets` entries in the first shape, each with `path` = the file in `/var/lib/monitoring/secrets/` its reader already opens, `root:monitoring 0640` as the hand-placed files were. Same test, opposite answer to the `.env`: every reader is a host-side native unit (Grafana's `$__file{}`, unpoller's `pass`, `udr-fw-exporter`'s `UNIFI_PASS_FILE`, Alertmanager's `webhook_url_file`, and the `ConditionPathExists` on three of them), so the symlink into `/run/secrets` is followed in place — checked per unit on the box rather than assumed: grafana and unifi-poller run `ProtectSystem=full`, alertmanager is `DynamicUser` under `ProtectSystem=strict`, and all three carry gid `monitoring` (the sandboxes make the tree read-only, they do not hide `/run`); sops-nix's generation directory is `0751` so any uid traverses it and the per-file mode decides. `modules/observability`'s activation script no longer generates the two Grafana values when absent (a missing sops key is now the manifest check's build-time error, not a silently minted password) nor chmods the four files; it keeps the directory. `restartUnits` on each names every reader (`unpoller-pass` has two), none of which has `restartIfChanged = false`, so a rotation is push-and-switch; the first switch restarts all four as well. What is left of this row: the bot's declared `github-token`, which has never existed on the box, and the `tenants.nix` declarations bead `.54` owns. |
| 24 | **A push to `home-arcade`, `agent-hub`, or a change to `ac-host`'s `.nix` module does not reach the box** until someone bumps homelab's `flake.lock`. "Push to tenant → deployed" is false for module changes. On 13 Sep all three inputs were behind their tips. | A step in each tenant pipeline that triggers homelab on green; homelab's `bump-lock` step (`scripts/hub-bump-lock.sh`) moves that input, runs `nix flake check` on the result, pushes. The pushed commit gets an ordinary build and is staged like any other. Chosen over a cron because a cron is a Buildkite UI object (row 25) and a trigger is in git. | `homelab-bqo.40` — **Built 13 Sep, one secret from live.** Exercised end to end against a bare remote (bumped `home-arcade` 2b396af→711259e, gates green, pushed). `ac-host` and `home-arcade` carry the trigger; `agent-hub` since 15 Sep (`homelab-luc`, the pipeline object and hook), and its first unattended bump landed def0d6c in 80 s on 16 Sep. **Live from the 15 Sep 03:30 switch**: `HOMELAB_PUSH_TOKEN` (a fine-grained token, Contents read+write on `imkarrer/homelab` only) is in sops as `homelab-push-token` and rendered into the CI env (14 Sep, `.39.1`'s template); the agent picks it up at its next recreate (04:00). With it set, a tenant push is a system switch three hops later. **18 Sep 2026, ADR 0009 (`homelab-158.3`): a second edge on the same trigger.** For a flox tenant the tenant's build triggers homelab with `HOMELAB_STAGE_ENVIRONMENT`/`HOMELAB_STAGE_REV` and homelab's `queue-environment` step (`scripts/hub-queue-environment.sh`) stages the sha in `/var/lib/homelab/pending-environment-<tenant>.json`; on the box `<tenant>-environment-pull` (modules/tenant/environment-pull.nix) checks it out, substitutes the locked paths (never builds), activates once and restarts the stub under the tenant's quiet policy — no closure switch, no lock bump. With `environment.enable = false` it stages and warms only. `agent-hub`'s pipeline carries the trigger from its next commit; the bump-lock trigger stays until its module leaves the closure. **`homelab-158.5`: the same edge for a FloxHub generation.** `arcade`'s deploy unit is a generation of `imkarrer/arcade` (`environment.source.kind = floxhub`): home-arcade's CI pushes on green (`FLOX_FLOXHUB_TOKEN` from sops `floxhub-token`, a 30-day JWT rotated by hand) and triggers with `HOMELAB_STAGE_GENERATION`/`HOMELAB_STAGE_ENV` beside the sha; the pull unit reads generation N's lock from FloxHub's floxmeta anonymously, substitutes, `flox pull`s a tracking checkout, activates `-g N`, pins N for the stub's wrapper, restarts. Landed with `enable = false`; `hub-status` prints `staged gN / applied gN (run …)`. **`homelab-158.11`, 18 Sep: the row is `ac-host`'s alone.** `agent-hub` and `home-arcade` left `flake.nix` — their units are whole stubs in `hosts/ac-box/configuration.nix` (every unit, user, tmpfiles rule and firewall port proven byte-identical; the stamp-stripped toplevel drvPath unchanged), what the box owes each is `hosts/ac-box/tenants/{agent-hub,arcade}.nix`, `hub/repos.psv` says `deploy=environment`, `hub-gates.sh` gates them by their manifests, and `hub-bump-lock.sh` skips a bump trigger from either until the tenant pipelines drop the step. |
| 25 | Buildkite pipeline *objects* (which repo, branch, steps file) live in the Buildkite UI; only the steps are in git | Pipeline-as-code via the Buildkite API or Terraform provider | `homelab-bqo.41` — **Built 13 Sep: `scripts/hub-pipeline.sh <tree>`, definitions in `hub/pipelines/<tree>.json`** (homelab, home-arcade). The definition is the whole request body, sent verbatim, so `--dry-run` prints exactly what Buildkite gets and the two files differ only in the tree's name. Idempotent as POST-then-PATCH: the token (`buildkite-api-token` in sops, the same value the box holds) has `write_pipelines` and not `read_pipelines`, so the script cannot list a pipeline and instead creates, then updates the slug on a 422 "already taken", printing which path ran. Every definition is checked before anything is sent: name = slug = tree (the tenants' `trigger: homelab` steps assume it), repository = the registry's remote over https (as the agent clones), the bootstrap step `buildkite-agent pipeline upload` under `queue: self`, and **`cluster_id` = the Default cluster** (`scripts/lib/buildkite-cluster.sh`, one constant shared with `hub-cluster-token.sh`). The first real run proved the cluster is not optional: POST without one is 422 "Cluster must be specified" — Buildkite no longer creates unclustered pipelines, and the three `ac-host*` objects that predate that rule are grandfathered. So everything moves into the cluster: `hub-pipeline.sh adopt <slug>` PATCHes an existing object with only `{"cluster_id": …}` (for `ac-host`, `ac-host-ops`, `ac-host-series`, whose definitions are not in git and cannot be read back), and the `ac-box` agent joins with a cluster token (`hub-cluster-token.sh`, in sops; into the agent's env by bead `.39.1`). The ordering hazard is in the script's header and printed before `adopt` acts: a clustered pipeline is served only by a cluster-registered agent, so between adopting `ac-host` and the agent's reconnect (a switch, then `systemctl restart ac-host-ci` from ssh — never from a job, HAZARD 2) ac-host jobs queue; ci tenant, drainable, minutes. `hub-pipeline.sh agents` (`read_agents`) is the check between the two steps: `ac-box / connected / <cluster> / queue=self`. The UI owns nothing of the object now. GitHub's half is in the script too as of 14 Sep: a pipeline object builds nothing without a **repo webhook** on its own deliver URL, and Buildkite's App — installed on this account — does not supply one. `hub-pipeline.sh <tree>` now converges that hook from the pipeline's `provider.webhook_url` (`gh api repos/<r>/hooks`, created or repointed, `push` + `pull_request`, json, active) and prints GitHub's own recent deliveries as the proof. It needs `gh auth login` once per machine; without it the hook is reported and not changed, which is the one manual step left. See row 34. |
| 26 | The Dream Router's DHCP reservation for `192.168.1.50` and the UniFi settings are hand-set | Documented in a runbook at minimum; `unifi_pf.py` already drives the forwards from code | `homelab-bqo.42` — **Answered 26 Sep 2026**, `docs/current-state.md` §4: both reservations by MAC (`e8:6a:64:f4:81:94` → `.50` arcade-box, `c8:d3:ff:b9:28:0b` → `.51` the Z840), the pool `.6`–`.254`, the nine forwards to `.50`, which Z840 port is live (`enp8s0`) and what cabling `eno1` breaks. Still hand-set on the router and `unifi_pf.py` still off; each `host.nix` declares its address and that section is the only record that the router agrees. |
| 27 | Pre-flake `nixos-26.05` channel still on the box; `NIX_PATH` references it | `nix.channel.enable = false` in `modules/platform/nix.nix` | `homelab-bqo.43` — **Open.** Harmless to the closure; a stale channel is one more thing that is not what the flake says. |
| 28 | Hand-placed files in `/root`: `fetch-model.sh`/`.log`, `result` (a human's GC root), `.docker` | `fetch-model.sh` reconciled into `agent-hub` `bb6a7db` — git's copy fetched a *different, never-deployed* model. `/root/result` pins a stale closure against GC. | `homelab-bqo.44` — **Partly done.** The script is in git; the `/root` copies and the GC root remain, harmless. |
| 29 | The loop has not yet closed end to end | The proof night: 03:00 tenant tree → 03:30 timer → 04:00 remount. Then a push to homelab → `queue-closure` writes → 03:30 next night → first automatic switch | `homelab-bqo.45` — **Ran 13 Sep; one of three legs held.** 03:00 did *not* apply: `e72c1e4` was staged (build 36, 01:28 CDT), the bot's countdown reached mark 0, and the trigger got HTTP 401 — the `BUILDKITE_API_TOKEN` in `.env` is dead (I.2); the lobbies were recycled at 03:00:01 by `ac-host-nightly` on the old tree `340b4fb`. 03:30 fired clean: `homelab-deploy.service` "nothing staged at /var/lib/homelab/pending-closure.json; nothing to do", exit 0 — the timer has now been watched firing, on its no-op path. 04:00 recreated `ac-host-ci` from the *old* compose, so the agent still has no `/var/lib/homelab` mount (row 2). The proof night restarts once the token is rotated (bead `.49`; `ac-host` `596b970`, staged by build 38, waits on it) and homelab's pipeline exists (bead `.50`, row 33). `HUB_STATUS_EXACT=1` after that 03:30 is the proof. |
| 30 | **The lobbies are recycled twice at 03:00.** `ac-host-nightly.timer` ran `recycle-static` at 03:00:01 on 12 Sep; the bot's `DOWNTIME=1` build recycled again at ~03:00:11. `ci_downtime.py` dedupes against its own `last-downtime.json`; `ac-host-nightly` neither reads nor writes it. Ten seconds apart, so nobody has noticed, but one of them is redundant and both are on the racing tenant's critical path. | Order matters: the tree must be *applied* before the recycle that picks it up, so the build's recycle is the one that has to stay. Make `ac-host-nightly` the fallback — skip when the bot is up (it will queue the build), recycle only when nothing else will. An `ac-host` change, in `modules/ac-host.nix` and `ci_downtime.py`. "Skip when the bot is up" is the wrong key: on 13 Sep the bot was up and the build did not fire (I.2) — key the fallback on `last-downtime.json`'s date instead, the fact `hub-status.sh` now reads for the same reason (bead `.46`). | `homelab-bqo.46` — **Open, deliberately not touched 13 Sep.** Found while answering "what can deploy without affecting the lobbies". Left alone tonight because tonight is row 29's proof and the 03:00 machinery is the thing under test. |
| 31 | Everything waits for the window even when nothing it changes is racing-adjacent. A firewall rule, a tier share, a Grafana dashboard, a secret, or the deploy unit itself sits staged until 03:30 by design, though nothing in them can reach a lobby: `ac-host-static` is `restartIfChanged = false`, the sidecars are compose-owned, and the only closure change that *can* touch a race is a `docker.service` restart — already AGENTS.md's abort criterion. | A push-time switch gated on blast radius: the deploy unit runs `switch-to-configuration dry-activate` first and switches immediately when the restart/stop set excludes `docker.service` and every `assetto`/`bot` unit; anything else falls through to the window as now. The tenant-tree analogue is splitting `ci_downtime.py`'s *apply* (tree sync, bot rebuild — drainable) from its *recycle* (lobbies, `plugin`/`auth`/`details`), so only the second half waits. | `homelab-bqo.47` / `homelab-wv8` — **Decided 15 Sep, ADR 0008 Accepted.** The operator answered "any hour is fine": arcade and observability may bounce whenever, so the only thing a switch waits for is people racing. That answer removed the `dry-activate` parser and the `windowOnly` word from the design — `busyCheck` was already the gate; it just never ran outside 03:30. Built as `homelab.deploy.schedule = "continuous"`: a path unit on `pending-closure.json` applies a revision the moment CI stages it, a 10-minute timer retries a deferral and covers a reboot, the build is niced (not sliced: batch's ceiling would OOM it), the busy question is asked again after the build, and 03:00–03:30 is a blackout so the closure never switches into the DOWNTIME build's drain. `modules/deploy/tests/eval.nix` proves each of those against a stub, both schedules, and is a flake check. The tenant-tree analogue (option 3) is still not taken. |
| 32 | Three documents said the tenant tree "needs a human to set `DOWNTIME=1`": this file's I.2, ADR 0006's context, `hub-status.sh`'s verdict line and header. The bot has queued it nightly since `bot/downtime.py` landed; `last-downtime.json` on the box is the record. | Corrected in place, dated. `hub-status.sh` now reports the queued tree as a state with a schedule and complains only when `ac-host-bot-1` is not running; its closure notes say "needs a human switch" only when `homelab-deploy.timer` is not enabled. | **Done 13 Sep.** The same class of error as row 20's "13 → 9 containers": the doc described the process as it was designed, not as it was running. |
| 33 | **homelab's Buildkite pipeline has never run.** The only `queue=self` agent (`ac-host-ci-agent-1`, up since 12 Sep 12:37) has executed 32 jobs, every one of them `ac-host`: none for the homelab pushes of 12 Sep evening, none for `eb55a83` (13 Sep 01:25), and none for `home-arcade` `3ae0a71` either. `.buildkite/pipeline.yml` is in git (bead `.29`, "verified locally") but the pipeline *object* — repo, webhook, cluster, first step `buildkite-agent pipeline upload` — is a Buildkite UI action (`home-arcade/docs/ci.md` "First-time pipeline") and nothing records it being done for homelab. Without it `queue-closure` never writes, and row 29's "push → 03:30 next night" cannot happen. | The sequence in `scripts/hub-pipeline.sh`'s header, in order: switch the closure that puts the cluster token in the agent's env (`.39.1`) → `ssh ac-box sudo systemctl restart ac-host-ci` → `hub-pipeline.sh agents` shows `ac-box` connected with the cluster → `adopt ac-host`, `adopt ac-host-ops`, `adopt ac-host-series` → `hub-pipeline.sh homelab`, `hub-pipeline.sh home-arcade` → push anything to homelab and watch the agent log for a `homelab/builds/1` job (since 16 Sep, `hub-status.sh`'s CI section shows that build, or its absence, without the log). If none comes, the GitHub App does not cover the repo and the script has printed the webhook to add by hand. | `homelab-bqo.50` — **Open; the objects wait on the agent joining the cluster.** Found 13 Sep by waiting for the build that the push should have produced; confirmed by the operator the same night: no homelab pipeline exists in Buildkite. Row 25's "a misclick could detach a pipeline" was optimistic — the closure's pipeline was never attached. The first attempt, 13 Sep, got 422 "Cluster must be specified" and turned into row 25's cluster move. The script is proven by `--dry-run` (create and adopt), by the validator rejecting a definition without the cluster id, and by `agents` reading the live state (`ac-box / connected / null / queue=self` — the pre-move state); the run itself is the supervisor's, and the proof is the first homelab build on the `ac-box` agent, not the 201. |
| 34 | **A push created no build for nine hours and nothing said so.** `homelab` had no repo webhook, and Buildkite's GitHub App — installed on this account, and the thing row 25 assumed was the trigger — does not deliver pushes. `ac-host`, the one tree that built on push, turns out to do it through a repo webhook; homelab's build 7 (14 Sep 12:44) was hand-created and merely coincided with the agent reconnecting, which is why the trigger looked alive. Five commits pushed 20:27–22:37 produced nothing, and `hub-status.sh` cannot tell "no build exists" from "a build is running" because the API token has neither `read_pipelines` nor `read_builds`. | The webhook stops being an operator chore: `hub-pipeline.sh <tree>` converges it from the pipeline's own `provider.webhook_url` and prints GitHub's recent deliveries (row 25). Give the API token `read_pipelines` + `read_builds` so `hub-status.sh` can say "HEAD pushed 47 min ago, no build exists". | `homelab-pxk` — **Closed 14 Sep**: hook added to `homelab`, proven by push → delivery 200 → `homelab/builds/9` two seconds later → green → `0123c54` staged. `home-arcade`'s hook created by the same script the same night. `homelab-luc` — **Closed 15 Sep**: `agent-hub`'s pipeline object and hook created by the same script; until then the lock was bumped by hand (`be854ca`). `homelab-g49` — **Built 16 Sep, one piece open**: the token has `read_pipelines` + `read_builds`, and `hub-status.sh` prints the newest `main` build per pipeline against origin's HEAD — `push did not build` when there is none, the state when one is running, a verdict when it failed — replacing the agent-log grep that could not tell those apart; `hub-build.sh` for hand-started builds is still open. |
| 35 | **The environment edge broke for the tenant that stayed behind.** ADR 0009's edge assumes the CI agent and the tenant's stub share a host: since the cutover the agent runs on arcade-box and `agent-hub`'s stub on the Z840, so a green agent-hub build staged `pending-environment-agent-hub.json` on a host with no puller and the Z840's tree fell behind main with nothing to say so. Under it a second gap: Buildkite publishes no GitHub commit status for `agent-hub`, `homelab` or `home-arcade` (`publish_commit_status: true` on every object, yet `/commits/main/status` is `pending, total_count 0`); only `ac-host` and `bead-loop`, the pipelines connected through Buildkite's GitHub App, carry one -- the three API-created pipelines trigger by repo webhook (row 34) and the App never learned their repositories. | A host with no agent stages its own green sha: `homelab.tenants.<t>.environment.poll` (`modules/tenant/environment-poll.nix`) polls GitHub for main's HEAD and its `buildkite/<slug>` status every ten minutes and writes `queue-environment`'s record with `source = "github-poll"`; the pull unit is unchanged. The status gap is an operator step: grant the Buildkite GitHub App the three repositories and connect each pipeline through it, then `gh api /repos/imkarrer/agent-hub/commits/main/status` reads `success` after the next green build. Follow-up: agent-hub's `HOMELAB_STAGE_ENVIRONMENT` trigger into homelab's pipeline is dead weight on arcade-box. | `homelab-ygc.14` -- **Landed 26 Sep 2026** (PR #17), applied on the Z840 by hand the same day; silent while HEAD equals the applied sha. **First live run 26 Sep 20:19 CDT** (27 Sep 01:19 UTC), with no hand step: the status gap had closed minutes before -- `buildkite/agent-hub` first reads `success` at 20:05 CDT, on `4f4e83b`, `buildkite/homelab` at 20:14 -- so agent-hub `b16781d` (PR #7, `homelab-ygc.7`, row 40), green in build 32 at 20:14, was staged by the poll at 20:19:52 and applied at 20:19:58, restarting `agent-hub-llm`. `home-arcade` has not pushed since 19 Sep, so whether it publishes is unobserved; no unit reads it. |
| 36 | **Six tenants on one machine** — the model server fenced to 23 of 28 cores to make room, CI at CPUWeight 0.05, every switch waiting on an empty-lobby window whether or not it touched a lobby (ADR 0010, Context). | ADR 0010 half one: a second host, arcade-box, takes `assetto`, `bot`, `arcade`, `observability` and `ci` with the address the forwards and the stations name; the Z840 keeps `agent-hub`. | **Done 26 Sep 2026** — epic `homelab-ygc`: the host in git and its first switch `e4e8ce6` (PR #10), state warm-up and arcade's generation (`homelab-ygc.5`), the cutover `aa48765` (PR #11), the operator's scripts to `.51` `44a8954` (PR #12), the runbook as it ran `d20f45b` (PR #13). Lobbies down 15:28–16:00 UTC; one volume missed on the way (row 38). |
| 37 | The Z840 still carried five tenants' slices and a cpuset fence with one tenant left on it: `agent-hub-llm` in `background.slice` on cores 3–25 under a 0.81 memory ceiling. | `homelab.enforce.slices = false` on ac-box (ADR 0010, "no tiers, no fence"): `agent-hub-llm` in `system.slice` on all 28 physical cores and all 251 GiB, 28 threads; `AllowedCPUs = 0-27` kept on the unit as placement. | **Done 26 Sep** — `8ebc402` (PR #14, `homelab-ygc.13`). The switch was the restart, once: removing `background.slice` took its three members down and the target start brought them back. Live: `Slice=system.slice`, `AllowedCPUs=0-27`, `MemoryMax=infinity`. |
| 38 | **The `ac-host_ac-server` Docker volume was in no state inventory.** It holds the Assetto Corsa dedicated server, installed once by steamcmd, which anonymous Steam cannot reinstall; the lobbies crash-looped (exit 8) on the new host until it was copied from the Z840's disk. | assetto declares the volume as backed-up state; `docs/runbook-restore.md` says how it goes back before the lobbies start. | **Done 26 Sep** — `039fe75` (PR #15, `homelab-ygc.12`). `hub-backup.sh` pulls it nightly with the rest of arcade-box's state. |
| 39 | **The Z840 had no collector after observability left**: the machine serving the models was the one nobody could graph, and the alert rules carried `ac-box` and 56 threads as literals. | `homelab.host.peers` on arcade-box (address read from the peer's own `host.nix`, never retyped); `modules/platform/node-exporter.nix` on the Z840, bound to the LAN address and opened on `enp8s0` only; host-agnostic alerts with `host=` on every target. | **Done 26 Sep** — `116c12e` (PR #16, `homelab-ygc.10`). Jobs `node` and `agent-hub` at `192.168.1.51`; `HostLoadHigh` per machine, arcade-box > 6, ac-box > 56 (its 28 generation threads sit at load 28–30 by design). |
| 40 | The operator's machine named `192.168.1.50:8100` for the model server in five script defaults (`hub-ask.sh`, `hub-index.sh`, `hub-search.sh`; agent-hub's `vectors-smoke.sh`, `compare.sh`) — the lobby host's address since the cutover. | Defaults moved to `192.168.1.51`. | **homelab's three done 26 Sep** — `44a8954` (PR #12). agent-hub's two are `homelab-ygc.7`, deferred to that tree's first push. |
| 41 | **The Z840's closure has no deploy edge.** Since the cutover the only CI agent is arcade-box's, so `queue-closure` writes arcade-box's `pending-closure.json`; the Z840's is frozen at the cutover's own record (10:27 CDT) and `homelab-deploy.timer` is armed there with nothing to do. Every closure change reaches it as `nixos-rebuild switch --refresh --flake github:imkarrer/homelab/<sha>#ac-box`, by hand. | Nothing — **accepted** (ADR 0010, "why llm-box gets no machinery"): one tenant, no lobbies, no agent that could restart itself, changes rare and interactive. The cost is visible rather than hidden: `hub-status.sh` reports the Z840's drift as a number per host, and a green homelab push switches arcade-box in a minute while the Z840 waits for a hand. | **Accepted 26 Sep 2026.** Revisited only by the rename (`homelab-ygc.9`), when the idle deploy units go or stay by a decision. |
| 42 | `ac-host`'s `docker-compose.buildkite.yml` names `minio/minio:latest` and `minio/mc:latest`, which Docker Hub refused on 26 Sep ("pull access denied" — the repositories are gone, quay.io's copies private, upstream's community edition source-only); arcade-box's CI cache runs on images `docker save \| docker load`ed from the Z840. | No registry at all: `modules/ci` builds `homelab/minio:nixpkgs` and `homelab/minio-client:nixpkgs` from homelab's own nixpkgs pin with `dockerTools` (`pkgs.minio` 2025-10-15T17-29-55Z, `pkgs.minio-client` 2025-08-13T08-35-41Z; exposed read-only as `homelab.ci.images`), and `ac-host-ci.service`'s `ExecStartPre` `docker load`s both before `docker-compose up`; the compose file in `ac-host` names the two tags verbatim. The tag is constant, the bytes move with `flake.lock`, and compose recreates only `minio`/`minio-init` for a changed image — never the agent. | `homelab-ygc.11` — **homelab half done 27 Sep 2026**; the `ac-host` half is the compose file naming the tags. Order: this half switches on arcade-box BEFORE the compose file on disk names the tags; the reverse plus a restart or reboot is `up -d` failing on an image the daemon does not have, no agent, and no pipeline able to fix it. Live at the first deliberate `systemctl restart ac-host-ci` from ssh with the agent idle (HAZARD 2 — a switch restarts nothing): `minio` and `minio-init` move onto the new IDs, the volume is read in place (proven on WSL: 2025-09-07's data read by 2025-10-15). `pkgs.minio` is insecure-marked in nixpkgs (abandoned upstream); the acknowledgement is scoped to the image, not `nixpkgs.config`, and leaving MinIO is a bead of its own. |
| 43 | ADR 0010 half two: the Z840 is still `ac-box` — `hosts/ac-box/`, `secrets/ac-box.yaml`, `~/.ssh/config`, `homelab.host.peers.ac-box`, the tracker and every tree's docs — the day the lobbies left it. | Rename to `llm-box`, its own runbook (ADR 0010, "Rename, not alias"). | `homelab-ygc.9` — **Open.** `hosts/arcade-box/host.nix` imports the Z840's `host.nix` by path and fails loudly when the directory moves, by design. |

### What the delta says, read as a whole

**26 Sep 2026, rows 36–43:** the six-tenant machine became two hosts in one
day, and this table changed shape with it. What arcade-box inherits is every
automatic edge the rows above spent September proving on the Z840 —
`queue-prod` and the 03:00 build, `queue-closure` and the continuous switch,
`queue-environment` and the pull — and all of it ran on the new host the
same afternoon (`ab21161` staged 13:47 CDT, switched 13:48). What the Z840
keeps is one tenant, one poll and a hand: row 41 is the first gap this table
carries as *accepted* rather than open, because ADR 0010 decided it and the
cost is a number `hub-status.sh` prints. Open in the epic: the rename (43),
MinIO's image pins (42) and agent-hub's two script defaults (40). Row 35's
operator fact — Buildkite published no commit status for three of the five
pipelines — closed that evening for `agent-hub` and `homelab` (`home-arcade`
has not pushed since): from 20:05 CDT `buildkite/agent-hub` reads
`success`, and at 20:19 the Z840's poll, the one automatic edge that host
has, staged and applied agent-hub `b16781d` with no hand step.

Rows 1 and 3–8, 10 (first secret), 11–18, 20–21 closed 12 Sep. What remains
divides cleanly: **rows 22–24 are the substance** — nothing backs up the state,
seven secrets are still hand-placed, and module-only tenants need a hand to
reach the box; **25 is built and 26–28 are hygiene**; **29 is the proof night, which restarts after `.49` (token) and `.50` (pipeline)**. Rows 22 and 24 are
the two that would make a rebuild-from-git or a push-to-deploy claim false.

**On "what can deploy without touching the lobbies" (13 Sep, rows 30–32):**
the answer turned out to be *everything already does*. The one lobby bounce on
this machine is the 03:00 recycle, and it is the designed one; the closure
switch cannot reach a race server by construction, and the tenant tree is
applied by the bot, not a human. What is left is not lobby risk but latency
(row 31 — every change waits for the window whether or not it needs to), one
missing edge (row 24 — built, waiting on a token), and one redundancy on the
critical path (row 30 — two recycles). None of these is racing's problem to
solve; all three are decisions about how much of the night the operator wants
to give up.

Rows 1 and 3–7, 13, 17, 18 closed on 12 Sep in two switches. Rows 8–10 are the
tenant model finishing what phase 6 started. Rows 11–12 are the two schema words — `mgmt`, `metricsEndpoint.address`
— that exist in the contract and nothing uses yet. Rows 2 and 21 are the
change that makes the box self-switching, and they should land together and
deliberately.

The thing that has actually changed since this repo began is not the code —
the layers, the contract and the tiers were built early and built well. It is
**observability of the gap**: `hub-status.sh` now reports what the box runs
versus what main says, and the difference is a number rather than a
surprise. Part III is that number, itemised.
