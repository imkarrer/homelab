# Architecture

Tracked, diffable diagrams of how ac-box is put together. Mermaid rather than
an image or an external link, for three reasons that have already bitten this
repo: a diagram in git is reviewable in the same diff as the change it
describes, it can be corrected when the code moves, and it does not depend on a
URL outside version control staying alive. `README.md` and
`docs/current-state.md` both still link to hosted pages; those are companions,
not the record.

Facts here are load-bearing and dated. When one stops being true, fix it in the
same commit that made it false — the same rule `docs/current-state.md` runs on.
Last verified against the box 9 Sep 2026.

---

## 1. The layers, and which way they may point

`README.md` states this as a table. The part a table cannot show is that the
dependency arrow only ever points one way, which is the whole design.

```mermaid
flowchart TD
    L3["<b>L3 · tenants</b><br/>ac-host · home-arcade · agent-hub<br/><i>flake inputs — declare, never reach</i>"]
    L2["<b>L2 · shared services</b><br/>modules/observability · modules/ci · modules/deploy<br/><i>consume the contract</i>"]
    L1["<b>L1 · the contract</b><br/>modules/tenant<br/>schema · ports · resources · metrics · quiet"]
    L0["<b>L0 · platform</b><br/>modules/platform<br/>hardware · NICs · identity · Docker · Nix · sshd · boot"]
    HOST["<b>host composition</b><br/>hosts/ac-box/<br/><i>the one place allowed to know both sides</i>"]

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
declarations. L3 declares without knowing its neighbours.** A tenant that
reaches sideways — into another tenant's state, or down into host facts it
guesses rather than reads — is the bug this structure exists to make visible.

`hosts/ac-box/` is the deliberate exception: something has to hand `arcade-hub`
the LAN address, and the host composition is the one place allowed to know both
sides. When a module hardcodes a host fact instead, that is the failure mode —
see finding F6 in `docs/current-state.md`, where `modules/observability`
carried `192.168.1.1` twice.

---

## 2. Two delivery paths, and where each one stops

The single most misread thing about this box. Code reaches ac-box by two
entirely separate routes that share a CI system and nothing else.

```mermaid
flowchart LR
    subgraph TENANT ["tenant tree — containers, scripts, content"]
        direction LR
        A1["ac-host<br/>WSL checkout"] --> A2["origin"]
        A2 --> A3["Buildkite<br/>test · lint"]
        A3 -- "wait: ~" --> A4["queue-prod<br/><i>stages a sha</i>"]
        A4 --> A5{{"human sets<br/>DOWNTIME=1"}}
        A5 -- "rsync" --> A6["/var/lib/ac-host/src<br/><b>reaches the box</b>"]
    end

    subgraph CLOSURE ["system closure — units, slices, firewall, ports"]
        direction LR
        B1["homelab<br/>+ 3 tenant inputs"] --> B2["origin"]
        B2 --> B3["Buildkite<br/>flake check · module eval"]
        B3 -.-> B4["<b>queue-closure</b><br/><i>not built — the agent<br/>cannot write /var/lib/homelab</i>"]
        B4 -.-> B5["modules/deploy<br/>homelab-deploy.timer<br/><i>built, inert</i>"]
        B5 -.-> B6["/run/current-system<br/><b>20 commits behind</b>"]
        B3 -- "the only live edge:<br/>a human, unprompted" --> B6
    end

    classDef ok fill:#dae8df,stroke:#2c6b4b,color:#101819;
    classDef gap fill:#f0dcda,stroke:#8f2f29,color:#101819;
    classDef pend fill:#f0e6d0,stroke:#8d5c0c,color:#101819;
    class A6 ok;
    class B4,B6 gap;
    class B5 pend;
```

Both paths end at a human. The difference is that the top one ends at a human
**who is prompted** — `queue-prod` stages a sha and `hub-status.sh` reports it
as pending until applied. The bottom path staged nothing and was checked by
nothing, which is how 15 commits accrued silently under a green verdict.
`hub-status.sh` now reports closure drift, which is the read side of the fix.

`home-arcade` and `agent-hub` are **flake inputs, not deploy targets** — they
reach the box only through homelab's closure, so they inherit the same stall.

**Why the missing edge is not simply a Buildkite step** (ADR 0006): the agent
that would run it is a container *on ac-box*, and once `homelab.ci.enable`
lands it is a systemd unit owned by the very closure being switched. A switch
running on it kills the job midway. That is a circularity, not a risk to be
managed — so the applying step must be something systemd owns, outside the
agent. `modules/deploy` is that, built and proven inert, waiting on a bind
mount the agent does not currently have.

---

## 3. Where work actually runs

The tier model fences systemd units. It **cannot** fence Docker containers, and
that is the subtlety worth drawing rather than describing (ADR 0005).

```mermaid
flowchart TB
    subgraph SYS ["system.slice — CPUWeight 100, uncapped"]
        S1["ac-host-static.service<br/>ac-host-nightly.timer"]
        S2["sshd · fail2ban"]
    end
    subgraph CRIT ["critical.slice — weight 500, 87.9 GiB, unfenced"]
        C1["3 × ac-static-* containers"]
        C2["auth · details · plugin sidecars"]
        C3["ac-host-bot-1"]
    end
    subgraph INT ["interactive.slice — weight 200, 37.7 GiB"]
        I1["arcade-freeciv · arcade-mindustry"]
        I2["samba-smbd · samba-winbindd · rsync"]
        I3["observability × 8"]
    end
    subgraph BG ["background.slice — weight 250, 75.3 GiB, AllowedCPUs 28-55"]
        G1["agent-hub-llm<br/><i>declared, not yet on the box</i>"]
    end
    subgraph BAT ["batch.slice — weight 50, 25.1 GiB, AllowedCPUs 28-55 ⚠"]
        T1["buildkite agent · minio"]
    end

    DOCKER["dockerd"] -- "places every container in<br/><b>system.slice</b> regardless of<br/>which unit started it" --> SYS
    COMPOSE["each tenant's compose file<br/><b>cgroup_parent: &lt;tier&gt;.slice</b>"] -- "is the only thing that<br/>puts a container in a tier" --> CRIT
    COMPOSE --> BAT

    classDef empty fill:none,stroke:#8d5c0c,stroke-dasharray:4 3,color:#101819;
    class G1 empty;
```

Two things this picture says that prose keeps failing to:

**Assetto's containers are fenced; its units are not.** `ac-host-static.service`
stays in `system.slice` on purpose — `resources.nix` assigns `Slice=` only when
`tier != critical` **and** `quiet.drainable`, because `Slice=` applies at unit
start and restarting `ac-host-static` means `docker rm -f` on three live race
servers. What is *meant* to protect racing is the fence — keeping background
and batch off the cores races use — rather than confining races. Note the
tense: that fence does not yet work, for the reason immediately below.

**`background` and `batch` share one fence, live.** Both carry
`AllowedCPUs = 28-55` — read off the box, not off the config. On this dual
E5-2680 v4, CPUs 28–55 are the SMT *siblings* of 0–27, one per physical core,
so the fence hands the two yielding tiers the second thread of every core:
it fences nothing physically, and gives a memory-bandwidth-bound workload the
worst possible CPU set. A Buildkite Nix build would land on exactly the cores
the model server is meant to be pinned to, separated only by `CPUWeight`
(50 vs 250) — a share, not an isolation.

`3fef4fe` fixes this by doing the arithmetic in physical cores and expanding
through `threadsPerCore`, giving `background` cores 3–25 and `batch` 26–27 plus
their siblings. It is committed and **not deployed** — one of the 20. The
figures above are what the box enforces today, deliberately, because a diagram
of the intended state is how the last set of stale comments happened.

**Slicing the unit that runs `docker compose` does nothing.** `dockerd` places
container scopes under `system.slice` no matter who invoked it, so a
Docker-based tenant in a fenced tier looks protected and is not. Only
`cgroup_parent` in the tenant's own compose file actually moves it.
`resources.nix` emits a warning for exactly this case, because the contract
cannot see another repo's compose file and must flag the risk without claiming
to know it was handled.

---

## 4. What gates a change before it reaches the box

```mermaid
flowchart LR
    W["a WSL tree"] --> G{"scripts/hub-gates.sh"}
    G -- "has nixosConfigurations" --> E1["evaluate each host"]
    G -- "module-only flake" --> E2["evaluate <b>through</b> ac-box<br/>--override-input &lt;name&gt; &lt;tree&gt;"]
    E2 --> N{"is &lt;name&gt; a real<br/>input of the hub?"}
    N -- "no" --> X["<b>hard fail</b><br/>--override-input ignores an<br/>unknown name and exits 0"]
    N -- "yes" --> P["pass / fail"]
    E1 --> P
    G -- "no gate applies" --> SK["counted as a GAP<br/><i>never a bare pass</i>"]

    classDef stop fill:#f0dcda,stroke:#8f2f29,color:#101819;
    class X stop;
```

`ac-host`, `home-arcade` and `agent-hub` are all module-only flakes. Before
this, their Nix gate was skipped in silence and `agent-hub` ran *no* gates while
printing a bare pass.

**Coverage caveat, and it matters more once ADR 0006 is live:** a composed eval
proves what is *reachable* from ac-box's config, not a whole module. `agent-hub`
is imported with `services.agent-hub.enable` defaulting false, so its gate
proves its option declarations compose and little of its config body. That is
fine while a human runs the switch. It is thinner than it looks when nobody
does.
