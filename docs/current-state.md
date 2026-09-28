# Current State: What arcade-box and llm-box Actually Run

The standing answer to "what is deployed, and does it conform?" — maintained,
not archived. `docs/noop-reconciliation.md` is the *phase 1* survey and is
frozen as a historical record of that migration step; this file is the one
that must be true today.

**Last reconciled:** 26 Sep 2026, 17:45 CDT, both hosts. Each runs `ab21161`
(`nixos-version --configuration-revision` over ssh on each), which was
origin/main at the time of reading; `hub-status.sh` reports the exact count
per host. Every live value below was read that evening from the host the row
names — `systemctl show`, `docker ps`, `docker inspect`, `ss -tulnp`, `ps`,
`/etc/homelab/tenants.json`, `ls` of `/var/lib/homelab` — and every declared
value is from `hosts/<host>/` at this commit.
**Method:** see [Keeping this current](#keeping-this-current) at the bottom.

> **History of this document, kept because the corrections are the useful
> part.** First written 9 Sep against generation 29 with a 26-commit drift
> figure; corrected the same day to **15** (a UTC-vs-`-0500` error, settled by
> reproducing the Z840's store path from a scratch worktree). The drift grew to
> 25 over three days of committed, gated, unapplied work, then closed to zero
> on 12 Sep in two switches (§1, history). Rewritten for two hosts on 26 Sep
> 2026, the day the cutover (ADR 0010, half one) moved every tenant but
> `agent-hub` off the Z840. Anything below dated before that day says "the
> box" and means the Z840 when it ran all six.

Diagrams of the structures this document reports on —
[`docs/architecture.md`](architecture.md), tracked in git.

Visual companion to this survey (hosted, outside version control):
<https://claude.ai/code/artifact/49abb0ae-3374-4ba4-921f-8e87fba0c52d>

---

## 1. The headline: two hosts, both on main

**26 Sep 2026, 15:28–16:00 UTC: the cutover.** `aa48765` (PR #11; ADR 0010
half one; `docs/runbook-arcade-box-cutover.md`, "As it ran", is the record)
moved `assetto`, `bot`, `arcade`, `observability` and `ci` from the Z840 to
arcade-box at `192.168.1.50`, and left `agent-hub` alone on the Z840 at
`192.168.1.51`. The lobbies were down for those 32 minutes. Six more commits
landed on both hosts the same day (`docs/architecture.md` Part III, rows
36–41); as of 17:45 CDT both run `ab21161`.

| | arcade-box | llm-box (the Z840; `ac-box` until `homelab-ygc.9`) |
| --- | --- | --- |
| Hardware | Lenovo ThinkCentre M920q Tiny: i7-8700T, 6 cores / 12 threads, 31 GiB usable, 954 GB NVMe (`lscpu`, `/proc/meminfo`, `lsblk`, 26 Sep) | HP Z840: 2 × E5-2680 v4, 28 cores / 56 threads, 251 GiB (`lscpu` 26 Sep; `dmidecode` 19 Sep) |
| Address | `192.168.1.50/24` on `eno2`, MAC `e8:6a:64:f4:81:94` — a Dream Router reservation; the lobby forwards point here (§4) | `192.168.1.51/24` on `enp8s0`, MAC `c8:d3:ff:b9:28:0b` — a reservation; `eno1` has no carrier and no address (§4) |
| Tenants | `assetto`, `bot`, `arcade`, `observability`, `ci` — five in `/etc/homelab/tenants.json` | `agent-hub` — one in `/etc/homelab/tenants.json` |
| Closure reaches it | by itself: its own agent's `queue-closure` stages, `homelab-deploy` (`schedule = "continuous"`, ADR 0006/0008) switches within a minute — `pending-closure.json` 13:47 CDT, `last-applied-closure.json` 13:48, running `ab21161` | by hand: `nixos-rebuild switch --refresh --flake github:imkarrer/homelab/<sha>#llm-box`. `homelab-deploy.timer` is armed and nothing stages on this host; its `pending-closure.json` is the cutover's own record, 10:27 CDT (ADR 0010, "no machinery"; architecture row 41) |
| Tenant tree (`ac-host`) | `queue-prod` on this agent; the bot's 03:00 DOWNTIME build applies. `last-downtime.json` reads `2026-09-26T08:00:12Z` — the Z840's last run, copied over; tonight's is the first here | none |
| Environments (ADR 0009) | `arcade`: FloxHub generation 2 of `imkarrer/arcade`, staged by `queue-environment` on this agent, applied by `arcade-environment-pull` (`pinned-environment-arcade`, 08:08 CDT) | `agent-hub`: `agent-hub-environment-poll.timer` reads GitHub every 10 minutes for a green sha (`homelab-ygc.14`); `agent-hub-environment-pull` applies it. First live run 26 Sep, 20:19 CDT: agent-hub `b16781d`, staged and applied six seconds apart with no hand step (row 35) |
| Tiers | shares of 31 GiB / 12 threads; `fence = false` on `background` and `batch` (§3) | `homelab.enforce.slices = false` (`homelab-ygc.13`): no slices, no `MemoryMax`, no fence (§3) |
| Docker | yes — 9 containers | none: `docker.service` inactive, no `docker` in the closure |
| CI agent | `arcade-box` on `queue=self` (`BUILDKITE_AGENT_NAME` read from the container); builds both hosts' toplevels | none |
| Prometheus | here; scrapes the Z840 as a peer (`homelab.host.peers.llm-box`: job `node` on 9100, job `agent-hub` on 8100; `homelab-ygc.10`) | a node exporter on `192.168.1.51:9100` (`modules/platform/node-exporter.nix`); no collector |
| Secrets | sops-nix, `secrets/ac-box.yaml` (the file keeps its name; it carries both hosts' recipients, runbook D4) | imports no secrets module (`flake.nix`, the Z840's list since `aa48765`) |
| Booted vs current | switched since boot: booted `kgy5zbf1…`, current `ayg73n6b…` — the continuous edge at work, expected | switched since boot: booted `wdpgr3i6…` (`aa48765`, the 15:37 UTC reboot), current `ym3pjykm…` (`ab21161`) |

### History: how the Z840 got here (12 Sep 2026)

Two switches, not one, on this repo's own smallest-blast-radius rule:
generation 30 → `3fef4fe` (the fence fix and the `tcp/8100` close;
`diff-closures` empty, `dry-activate` a firewall reload only), then
generation 31 → HEAD after the HAZARD 1 adoption sequence (started
`agent-hub-llm` and `ac-host-ci`, moved samba/rsync into `interactive.slice`,
stopped `wpa_supplicant`, rebalanced the tiers). One defect surfaced by doing
it — `docker compose … --build` under systemd needed `git` on `ac-host-ci`'s
`PATH` — fixed in `c97cbbe`. Generation 34 (12 Sep 20:50 CDT) armed
`homelab-deploy.timer`, the Z840's last hand switch until the cutover made
hand switches its only kind. Every unit named in this paragraph except
`agent-hub-llm` now runs on arcade-box.

### What is still owed

- **The rest of the rename** (ADR 0010 half two, `homelab-ygc.9`,
  `docs/runbook-llm-box-rename.md`). The Z840 became `llm-box` on
  28 Sep 2026 — `hosts/`, the flake, its hostname, `homelab.host.peers` and
  the ssh alias. Still owed under the same bead: `secrets/ac-box.yaml`'s
  rename (section 5), the strip of the moved state from the Z840's disk
  (section 6), the other trees' docs (7.10) and the tracker (7.11). In
  anything older, "ac-box" means the Z840 (CONTEXT.md).
- **MinIO's restart** (`homelab-ygc.11`): `minio/minio` and `minio/mc` are
  gone from every public registry, so `modules/ci` now builds
  `homelab/minio:nixpkgs` and `homelab/minio-client:nixpkgs` from homelab's
  nixpkgs pin and `docker load`s them at every start of `ac-host-ci.service`;
  the `ac-host` compose file names those tags. The running containers still
  carry the `docker save | docker load`ed 2025-09-07 copies until a
  deliberate `systemctl restart ac-host-ci` from ssh with the agent idle,
  once both halves are on the box.
- ~~**agent-hub's script defaults**~~ (`homelab-ygc.7`) **Landed 26 Sep,
  20:14 CDT** (27 Sep 01:14 UTC), agent-hub PR #7, fast-forwarded: `68f50f5`
  moved `vectors-smoke.sh`'s `LLM` and `QDRANT` and `compare.sh`'s second
  target to `192.168.1.51`; `b16781d` stopped `compare.sh` claiming a cgroup
  fence the Z840 no longer has. That push was the Z840 poll edge's first
  live run (`homelab-ygc.14`): green in build 32, staged 20:19:52, applied
  20:19:58. homelab's three scripts moved in `44a8954`.
- ~~**Commit statuses**~~ (architecture row 35, an operator step in
  Buildkite) **Settled 26 Sep, 20:05 CDT** (27 Sep 01:05 UTC) — the first
  `buildkite/agent-hub` status, `success` on `4f4e83b`; `buildkite/homelab`
  had published since 18:16 (`afecdf6`, PR #18's head: build 171, first
  `success` in build 172 at 18:17). Read 28 Sep from
  `gh api /repos/imkarrer/<tree>/commits/<sha>/statuses` (the combined
  `/status` keeps only the newest per context). The Z840's poll —
  the one automatic edge that host has, and the one unit that reads a
  status — staged from agent-hub's at 20:19. `home-arcade` has not pushed
  since 19 Sep, so whether its pipeline publishes is unobserved; no unit
  reads it.
- ~~**The first night on arcade-box**~~ **Observed 27 Sep.** At 03:00 the
  bot queued DOWNTIME (`ac-host-ops` build 28) and the lobbies recycled on
  this host; the 04:30 `hub-backup` pulled from both hosts that night and the
  next (`RESULT_arcade-box=ok` beside the Z840's); the 28 Sep DOWNTIME applied
  ac-host `0fdf591` (`last-downtime.json` 08:00:11Z, read 28 Sep). The four
  moved directories had already left `/home/nixos/backup/ac-box/var/lib/` on
  26 Sep at 16:02 UTC (that directory's mtime; runbook 4.6, step 5).

---

## 2. Classification

"Conforming" means: declared in the host's tenant contract
(`hosts/<host>/tenants.nix`), present on that host, and matching the
declaration on ports, slice and state path. One table per host; a unit
appears on exactly one.

### arcade-box — conforming

Live from arcade-box, 26 Sep 2026 17:45 CDT, closure `ab21161`.

| Service | Tenant | Basis |
| --- | --- | --- |
| `ac-host-static.service` (active, exited) + `ac-static-{blackhawk,road-america,gingerman}` + `ac-host-{auth,details,plugin}-1` | assetto | Lobbies on 9600–9602 tcp+udp, 8081–8083, 8181–8183, 11200–11202/udp; sidecar sockets 18080 and 11300–11302 on loopback — every one declared and every one live in `ss`. The unit is in `system.slice` by design (unsliced: its `ExecStop` is `docker rm -f`); the six containers carry `CgroupParent = critical.slice` (`docker inspect`). State at `/var/lib/ac-host` (copied 26 Sep; the final delta was 7 files) and in the `ac-host_ac-server` Docker volume — the AC dedicated server, which anonymous steamcmd cannot reinstall; missed by the first copy, so the lobbies crash-looped 15:57–16:00 UTC until it was copied; declared `state.backup` since `homelab-ygc.12`. |
| `ac-host-nightly.timer`, `ac-host-dev.service` | assetto | Declared; the timer armed, dev `inactive (dead)` by design. |
| `ac-host-bot.service` (active, exited) + `ac-host-bot-1` | bot | Declared; unit in `system.slice`, container `CgroupParent = critical.slice` (still assetto's compose project, declared as shared). It queues the 03:00 DOWNTIME build on this host's agent; the first such night is tonight. |
| `arcade-freeciv`, `arcade-mindustry` | arcade | `interactive.slice`. 5556/tcp and 4555/udp (freeciv), 6567 tcp+udp and 20151/udp (Mindustry) live and declared. Generation 2 of `imkarrer/arcade`, run path `f6m1q3pd…` — the path the Z840 ran. |
| `samba-smbd`, `samba-winbindd`, `rsync` | arcade | `interactive.slice`; 139/445/873 bound on `192.168.1.50` — the stations' mount and the two rsync stations followed the address, unchanged. |
| observability, 8 units: `prometheus`, `grafana`, `alertmanager`, `cadvisor`, `unifi-poller`, `udr-fw-exporter`, `docker-name-exporter`, `prometheus-node-exporter` | observability | All `interactive.slice`. Grafana on `192.168.1.50:3000`; 9090, 9093, 9100, 9102, 9130–9132 on loopback; 9094 (alertmanager cluster) on the wildcard. Since `116c12e` the scrape config also carries the Z840 as a peer with `host=` on every target, and the host alerts are per machine: `HostDiskHigh`, `HostLoadHigh` (arcade-box > 6, llm-box > 56), `HostMemLow`, `NodeExporterDown`, `CadvisorDown`. |
| `ac-host-ci.service` (active, exited) + `ac-host-ci-agent-1`, `ac-host-ci-minio-1` | ci | `batch.slice` (unit and both containers' `CgroupParent`), beside `nix-daemon`. Agent `arcade-box` on `queue=self`, `--spawn 1`; MinIO on 127.0.0.1:9000/9001 serving the copied `ac-host-ci_minio-data` (3.9 GB, 5,913 files; the cache bucket inside it 2,355 objects, 3.6 GiB). Image source since `homelab-ygc.11`: `homelab/minio:nixpkgs` and `homelab/minio-client:nixpkgs`, built by `modules/ci` from homelab's nixpkgs pin (`pkgs.minio` 2025-10-15T17-29-55Z, `pkgs.minio-client` 2025-08-13T08-35-41Z) and `docker load`ed by the unit's `ExecStartPre` at every start — no registry. The containers move onto them at the first deliberate restart after the switch; until then `ac-host-ci-minio-1` runs the loaded copy of `minio/minio:latest` (RELEASE.2025-09-07T16-13-09Z, id `14cea493d9a3`). |

### llm-box — conforming

Live from the Z840, 26 Sep 2026 17:45 CDT, closure `ab21161`.

| Service | Tenant | Basis |
| --- | --- | --- |
| `agent-hub-llm.service` | agent-hub | Running in `system.slice` — there is no tier slice on this host (`homelab.enforce.slices = false`, `homelab-ygc.13`; `systemctl list-units --type=slice` shows none). `AllowedCPUs = 0-27` and `NUMAPolicy = interleave` on the unit itself: the 28 physical cores, a placement fact, not a fence; `MemoryMax = infinity`. `llama-swap` listens on `127.0.0.1:8100` over four models; the loaded `llama-server` runs `--threads 28` (`ps`). `restartIfChanged = false`: a switch does not bounce it. |
| `nginx.service` | agent-hub | Landing page and proxy on `192.168.1.51:8100` (the tenant's `llm` port, scope `lan`); `system.slice`. |
| `qdrant.service` | agent-hub | `192.168.1.51:6333` (`vectors`, scope `lan`); `system.slice`. State `/var/lib/qdrant`, `backup = true`. |
| `agent-hub-environment-pull.{path,timer}` | agent-hub | The applying half of ADR 0009's edge, armed; `last-applied-environment-agent-hub.json` 25 Sep 21:20 CDT at this reading, then 26 Sep 20:19:58 CDT: `b16781d`, the poll's first staged sha, restarting `agent-hub-llm` (the record and both units' journals, read 28 Sep). |
| `agent-hub-environment-poll.timer` | agent-hub | The staging half since `ab21161` (`homelab-ygc.14`): `OnUnitActiveSec=10min`, last 17:38, next 17:48 CDT. Two GitHub API calls per tick; stages a sha only when `buildkite/agent-hub` reads `success` on it — first at 20:19:52 CDT, `b16781d`, green in build 32 (row 35). |
| `prometheus-node-exporter.service` | platform, not a tenant (`modules/platform/node-exporter.nix`, `homelab-ygc.10`) | `192.168.1.51:9100`, opened on `enp8s0` only, scraped by arcade-box. Not in the port registry — the module header says why, and what it costs. |
| `homelab-deploy.{path,timer}` | platform | Armed (every 10 minutes) with nothing to do: no agent stages here. Accepted (architecture row 41). |

### Nonconforming and accepted

| Item | Host | Gap |
| --- | --- | --- |
| The Z840's closure edge | llm-box | No CI agent, so nothing stages a closure on this host; every switch is an operator's, from a sha on origin. **Accepted** (ADR 0010; row 41). |
| MinIO's images | arcade-box | Running from `docker save \| docker load` copies; the compose file's `image:` lines are not pullable (`homelab-ygc.11`). |
| ~~Commit statuses~~ | Buildkite | **Settled 26 Sep** — `homelab`'s published from 18:16 CDT and `agent-hub`'s from 20:05; the Z840's poll, the one unit that reads a status, staged from agent-hub's at 20:19. `home-arcade` unobserved: no push since 19 Sep (row 35). |

### Decommission

| Item | Why |
| --- | --- |
| ~~`/etc/nixos/configuration.nix`~~ | **Done** — a `throw` since 12 Sep on the Z840. The hardware file is kept, on both hosts, at `/etc/nixos/hardware-configuration.nix`. |
| ~~`wpa_supplicant.service`~~ | **Done** — `mkForce false` in `network.nix`, gone at gen 31; the same line keeps arcade-box's `wlo1` idle. |
| ~~`inquire-platform`~~ | **Removed from the registry 12 Sep** — a personal project, never part of the homelab. |
| The moved state on the Z840's disk: `/var/lib/ac-host` (12 G), `/var/lib/arcade`, `/srv/arcade`, `/var/lib/grafana`, `/var/lib/prometheus2`, and `/var/lib/docker` (52 G, the daemon's directory left behind when Docker left the closure) | Frozen at the cutover's final delta (runbook 4.4), the rollback ladder's last rung; `ls`/`du` on the Z840, 26 Sep evening. Nothing reads them. Their removal belongs to the rename's runbook (`homelab-ygc.9`, `docs/runbook-llm-box-rename.md` section 6), after arcade-box's first backed-up night. |
| `/var/lib/homelab/{pending,last-applied}-environment-{arcade,ci}.json`, `pinned-environment-arcade` on the Z840 | Records of tenants no longer declared there (18 Sep mtimes). Same runbook. |

---

## 3. Each host at rest

Live from `systemctl show <slice> -p CPUWeight -p MemoryMax -p AllowedCPUs`,
26 Sep 2026 17:45 CDT.

**arcade-box** — shares of 31 GiB and 12 threads
(`hosts/arcade-box/configuration.nix`), weights only:

| Slice | CPUWeight | MemoryMax | AllowedCPUs | Members |
| --- | --- | --- | --- | --- |
| `critical.slice` | 500 | 6.2 GiB | none | 7 docker scopes via `cgroup_parent` (3 lobbies, 3 sidecars, the bot) |
| `interactive.slice` | 200 | 6.2 GiB | none | arcade ×2, samba ×2, rsync, observability ×8 |
| `background.slice` | 50 | 1.55 GiB | none | nothing — inactive; no tenant of this tier here |
| `batch.slice` | 300 | 13.95 GiB | none | `ac-host-ci` (agent, MinIO), `nix-daemon` |
| `system.slice` | 100 | none | — | `ac-host-static`, `ac-host-bot`, `ac-host-env`, platform (sshd, fail2ban, docker, NetworkManager) |

**llm-box** — no tier slice exists (`homelab.enforce.slices = false`):

| Slice | CPUWeight | MemoryMax | AllowedCPUs | Members |
| --- | --- | --- | --- | --- |
| `system.slice` | 100 | none | — | `agent-hub-llm` (the unit's own `AllowedCPUs = 0-27`), `nginx`, `qdrant`, `prometheus-node-exporter`, platform |

**There is no fence anywhere since 26 Sep.** On the Z840 the fence existed
so a build or the model server could not reach the lobbies' cores; with one
tenant there is nothing to fence from, and `agent-hub-llm`'s `0-27` is the 28
physical cores its 28 threads want (the SMT siblings cost memory bandwidth,
agent-hub's `prefill-tuning.md`), not a boundary. On arcade-box
`resources.nix` would carve one or two of six cores for every CI build and
idle them the rest of the day, so `homelab.tiers.{background,batch}.fence =
false` and `CPUWeight` is the whole story: 500 for the lobby containers
against 300 for a build, consulted only under contention, with `MemoryMax`
still the ceiling a runaway job hits.

---

## 4. The LAN, as the router has it (`homelab-bqo.42`)

Facts read off the Dream Router's UI by the operator on 26 Sep 2026 (runbook
4.1, "As it ran") and off each host over ssh the same evening. None of it is
in code: `hosts/<host>/host.nix` declares each address, and only this table
and the router say the router will hand it out (architecture row 26).

| | |
| --- | --- |
| Router | UniFi Dream Router, `192.168.1.1` — the default route of both hosts (`ip route`) and the controller `unifi-poller` and `udr-fw-exporter` speak to (`homelab.host.unifi.address`, both host files) |
| DHCP | one `/24` pool, `192.168.1.6`–`.254`; both hosts lease (`ipv4.method auto`), pinned by a reservation per MAC |
| Reservation: arcade-box | MAC `e8:6a:64:f4:81:94` (`eno2`, the M920q's one wired port) → `192.168.1.50`. Set 15:43 UTC 26 Sep, once the Z840's lease had released it; the build-up ran on `.218` |
| Reservation: the Z840 | MAC `c8:d3:ff:b9:28:0b` (`enp8s0`) → `192.168.1.51`. Set 15:20 UTC 26 Sep; the lowest free address beside `.50` |
| Forwards | nine rules, `ac-prod-s{0,1,2}-{game,http,details}`, for the three lobby slots (9600–9602 tcp+udp, 8081–8083, 8181–8183) → `192.168.1.50`, by number, hand-set. `unifi_pf.py` is off (`/var/lib/ac-host/.env` has no `UNIFI_*` keys). Untouched by the cutover, which is why `.50` moved with the lobbies (runbook D2) |
| The Z840's two ports | `enp8s0` `c8:d3:ff:b9:28:0b` is live and reserved. `eno1` `c8:d3:ff:b9:28:0a` is administratively up with no carrier (NetworkManager "unavailable"), declared `mgmt` with `address = null` — the scope stays in the contract, nothing is plugged in, nothing is scoped to it (ADR 0007, row 11) |
| arcade-box's other port | `wlo1`, Wi-Fi, no carrier; `wireless.enable = mkForce false` |

**What breaks if the Z840's cable goes into `eno1`** — which is what happened
on 13 Sep 2026, the incident behind `homelab-bqo.42`: `eno1`'s MAC has no
reservation, so if NetworkManager brings it up it leases an address from the
pool that nothing knows — not `~/.ssh/config`, not arcade-box's peer entry,
not the operator's script defaults — and `.51` goes away with `enp8s0`'s
link. nginx, qdrant and the node exporter bind `192.168.1.51` and fail to
start without it (the cutover's own switch exited status 4 for exactly that
reason while the lease had not yet moved), and the firewall opens 8100, 6333
and 9100 on `enp8s0` only. Cabling both ports on one LAN gives the Z840 two
leases and two default routes and opens nothing on the second; it isolates
nothing, which is why ADR 0007 plugs nothing in. The one right cable is
`enp8s0`, and the check is `ip -br addr show enp8s0` reading `.51`.

---

## 5. Idiomatic Nix: audit

Assessed against the migration this repo is carrying out. Short version: the
module layer is unusually disciplined — `mkIf`/`mkMerge` are used correctly
throughout, assertions are separated from derivations so the contract can ship
inert, `follows` is applied to every input that has a `nixpkgs`, and the
option namespace is single-spelled. The findings below are the exceptions.

### Confirmed good

- **`mkIf false` contributes nothing, and the tests assert it.** `ports.nix`,
  `resources.nix` and `metrics.nix` each wrap their effect in `mkIf` rather
  than leaving an unconditional attrset with empty lists, and each has an
  `allFalse` eval case asserting the option is *undefined* rather than merely
  empty. This is the correct instinct and it is rarer than it should be.
- **Evaluation-time assertions are ungated.** Port collisions, the forwarded
  justification, the mgmt address and the 0.9 memory budget all fire with
  every `enforce.*` flag off, because they cost nothing in the closure. This
  is what let the contract ship before its effects were turned on.
- **`mkDefault` on tier values.** Every entry in `tierDefaults` is `mkDefault`,
  so a host overrides without `mkForce`. `configuration.nix` relies on this.
- **Shares, never absolute units.** No CPU index or gigabyte figure appears in
  a host file; `host.nix` is the only file with machine literals. ADR 0002
  holds under inspection.
- **Single `nixpkgs` node.** `ac-host` and `agent-hub` both `follows`;
  `home-arcade` has no inputs at all (`outputs = { self }`), so there is
  nothing to make follow and the comment saying so is accurate.
- **The `.service.service` class of bug is fixed and documented.**
  `resources.nix` strips the suffix before keying `systemd.services`, and its
  comment records that the built closure once carried ten phantom units while
  `dry-activate` cheerfully reported no restarts.

### Findings

**F1 — A silent fallback decides whether the system can boot.**
`hosts/ac-box/configuration.nix` (now `hosts/llm-box/`) selects
`hardware-configuration.nix` if `builtins.pathExists` finds it, else
`.example`, which states it will not boot a real machine. A flake copies
only *git-tracked* files into the store, so this
conditional is really testing "is the file tracked?" — and the answer today is
yes (`git ls-files` confirms both it and `ssh-keys.local.nix` are tracked;
`.gitignore` carries a NOTE explaining they were deliberately un-ignored for
exactly this reason). The build is therefore correct. The hazard is that
`README.md`'s pinned conventions and `configuration.nix`'s own comment both
still say the file *is* gitignored. Anyone who "restores" that documented
behaviour gets a silently unbootable closure with no error. This is the same
failure shape the repo has caught twice before: *a comment describing an
intention the code does not implement.* A `throw` would be safer than a silent
substitution. **Fixed** — each `hosts/<host>/configuration.nix` throws on a
missing hardware file, and README's convention now says to fetch the file from
the host it describes (`/etc/nixos/hardware-configuration.nix`), which is how
arcade-box's was fetched on 26 Sep 2026.

**F2 — `outputs` destructures without `...`.**
`outputs = { self, nixpkgs, ac-host, home-arcade, agent-hub }:` breaks
evaluation the moment an input is added, with an error that points at the
output function rather than at the input. `{ self, nixpkgs, ... }@inputs` is
the idiom. Minor, and arguably a deliberate strictness — but the failure mode
is misleading, which is the usual reason to prefer the idiom.

**F3 — `system.configurationRevision` is unset.**
`nixos-rebuild list-generations` reports `Configuration Revision: Unknown` for
every generation. Setting it (`self.rev or self.dirtyRev`) is the standard
idiom and would make the running closure self-identifying — which is precisely
what §1's blind spot needs. **Done** — `0a58999` (architecture row 16); each
host reports its own sha, which is how §1's "both run `ab21161`" was read.

**F4 — `nixosModules` under-exports.**
The flake offers `tenantContract` and `platform`, but `modules/observability`
and `modules/ci` are consumed only as inline paths in the `ac-box` module list.
`modules/observability/default.nix` was lifted out of a tenant repo *precisely*
so it could be shared; not exporting it leaves that half-done. **Done** —
`0a58999` (row 15), and since 26 Sep 2026 there are two hosts: `flake.nix`
composes each from one shared platform list plus the host's own tenants,
which is what the export was for.

**F5 — `checks.ac-box` is the full system toplevel.**
`nix flake check` therefore *builds* the system, not merely evaluates it. The
pipeline comment argues this is affordable because the self-hosted agent reuses
a warm store and the MinIO substituter. That is true today and worth
re-examining if CI ever moves off ac-box, because it would then be a
from-source system build on every push.

**Per host since 26 Sep 2026:** `checks.arcade-box` and `checks.llm-box` are
both full toplevels, and both build on arcade-box's agent — CI did move off
the Z840, and the Z840's system is now built on a 6-core Tiny from a store
that agent's `/nix` volume re-warmed from MinIO and cache.nixos.org. The
first arcade-box build was almost all substitution because both hosts pin
the nixpkgs revision the Lenovo's installer already had; whether two
toplevels per push stay affordable there is the ci-box epic's question
(`homelab-bfq`; ADR 0010's Consequences carry the trigger, and an ADR 0012
is drafted there).

**F6 — the UniFi router address was hardcoded in an L2 module. Fixed.**
`modules/observability/default.nix` reads `config.homelab.host.networks.lan
.address` for Grafana's bind (correct, and its comment says why), then
hardcodes `https://192.168.1.1` twice for `UNIFI_HOST` — once in the unpoller
config and once in `udr-fw-exporter`'s environment. The router's address is a
host fact with no home in `homelab.host.networks`, which today models only
`lan` and `mgmt` interfaces. This is the same drift trap the `arcade-hub`
comment in `configuration.nix` describes — *host facts are read from the host,
never inherited from a guess* — and it is the one place in the module layer
where a machine literal appears in code rather than in a comment. Everything
else surveyed is clean on this point: `grep` for `192.168.`, `enp8s0`, `eno1`
and `/var/lib/ac-host` across `modules/` returns comments only. The fix is a
schema addition (a gateway or `unifi.address` field on `homelab.host`), which
makes it a contract change rather than a drive-by edit. Landed in `6e18170`
as `homelab.host.unifi.address` — deliberately not `networks.lan.gateway`,
since the consumers speak the UniFi controller API and do not care what the
default route is; on both hosts those are one Dream Router wearing both hats
(arcade-box's `host.nix` states the field again as its own host fact), and a
`gateway` field would record the coincidence and go quietly wrong the day the
controller moves. Proven a no-op: the toplevel drvPath is byte-identical with
and without the change.

**F7 — the eval harnesses depended on `<nixpkgs>`, not on the flake. Fixed.**
`modules/tenant/tests/*.nix`, `modules/ci/tests/eval.nix` and
`modules/ci/scripts/run-eval-tests.sh` all default to
`(import <nixpkgs> { }).lib`, so they resolve through `NIX_PATH` rather than
through the pinned input. These are the tests that prove `ports.nix` still
*rejects* a colliding fixture — coverage `nix flake check` cannot provide,
since the real config has nothing to reject — so they are load-bearing. Being
load-bearing and unpinned is the objection: they can pass against a different
`lib` than the one the system is built with. Threading `lib` from the flake
(or exposing them as flake `checks`) closes it.

Fixed in `365e1d5`, with a correction to the finding as first written: the
*runner* was already pinned — `9c21cc7` injects the flake's nixpkgs with
`-I nixpkgs=…`. The live hole was the **harnesses**, each of which documents
`nix eval -f modules/tenant/tests/eval.nix <case>.checked` in its own Usage
block; that path got the channel's lib, or an error where no channel exists.
Fixing the injection would have fixed only the scripted path.

The pin now lives in `modules/tenant/tests/pinned-nixpkgs.nix`, which reads
`flake.lock` and `fetchTree`s the locked node verbatim — pure, no re-locking,
and the lock is *read* rather than the rev copied, so the pin keeps one home.
The `<nixpkgs>` fallback is gone, and `run-eval-tests.sh` passes
`--option nix-path ""` so a reintroduced lookup dies loudly instead of
resolving a channel. All 19 cases match baseline, including the five
expected-throw negatives, with `NIX_PATH` both cleared and poisoned. Suite
runtime dropped 18.0s → 3.8s, because three lib-only harnesses no longer
instantiate the whole package set.

**Follow-up done — `2ac2f37`.** The harnesses are flake `checks`
(`eval-ci`, `eval-tenant`, `eval-tenant-metrics`, `eval-tenant-quiet`,
`eval-tenant-resources`); one shared inversion in
`modules/tenant/tests/check.nix`; `run-eval-tests.sh` reduced to a
human-readable front-end; the pipeline's separate harness step folded into
`flake check`. Evaluation-only, ~1s for all five.

Doing it found a **defect in `e4bf36f`**, pushed earlier the same day: three of
the four new metrics negatives were throwing a *definition tie* — the case set
`agent-hub.metrics.address` at the same priority as the shared fixture — before
`metrics.nix`'s assertion ever ran. The runner said "expected throw, got throw"
and passed them; the commit message claimed they "prove the assertion bites",
and they did not. Fixed with `mkForce`, and `check.nix` now requires a negative
case's `.messages` to be non-empty — the throw must come *through the module's
own verdict*. A test that fails for the wrong reason is a test that proves
nothing, and until today nothing in this tree could tell the difference.

**F8 — the contract could not claim any unit nixpkgs already sliced. Fixed.**
Found by doing the arcade work, not by reading: `resources.nix` emitted
`Slice=` at plain priority 100, which *ties* with any upstream module that sets
its own. nixpkgs' samba module pins `Slice = "system-samba.slice"` on
`samba-smbd` and `samba-winbindd`, so the moment arcade declared those units
the whole config stopped evaluating — `has conflicting definition values`, not
a merge. Every nixpkgs service that groups itself into a slice was
un-adoptable by a tenant, and a tenant's only lever (`units`) was the very
thing that triggered it.

Fixed by emitting `lib.mkOverride 90`, establishing a deliberate ladder:
upstream module 100 → this contract 90 → host composition 50 (`mkForce`).
The contract wins, because assigning units to slices is what it is *for*, and
naming a unit in `units` is a narrower, reviewed claim than an upstream
module's general default. `mkOverride 90` rather than `mkForce` keeps the top
of the ladder open so a host can still override without editing a pinned
module. The cost is real and recorded in the comment: a typo in a `units` list
now silently relocates someone else's unit instead of failing loudly.

Verified after the change — `samba-smbd`, `samba-winbindd`, `rsync`,
`arcade-freeciv`, `arcade-mindustry` and `prometheus` all resolve to
`interactive.slice`, while `ac-host-static` correctly resolves to no slice at
all.

**F9 — module-only flakes had no evaluation gate at all. Fixed.**
`hub-gates.sh` gates a Nix tree by enumerating its `nixosConfigurations` and
evaluating each. `home-arcade` is a module-only flake and has none, so the Nix
gate is *silently skipped* and the script falls through to a flox test that
fails in this tree for an unrelated reason (`.flox/env.json` is gitignored and
absent). `modules/arcade-hub.nix` defines real systemd services and firewall
rules on ac-box and nothing evaluates it before a push. The correct gate is to
evaluate it through the host that consumes it —
`nix eval --override-input home-arcade <local tree> .#nixosConfigurations
.ac-box…toplevel.drvPath` — which is how this round's arcade change was
actually verified. Fixed in `1c6827f`, and the gap was wider than F9 first
stated: `ac-host` and `agent-hub` are module-only too, and `agent-hub` ran
*zero* gates while printing a bare `GATES PASS`. The fix needed a guard worth
knowing about — `nix eval --override-input` with a name no input has exits 0,
warns nothing, and returns the unmodified drvPath, so a renamed input would
have turned the new gate back into a green no-op proving the pinned copy.
Input names are now checked against `nix flake metadata` first.

**Coverage caveat.** A composed eval proves what is *reachable* from a host's
config, not the whole module — and since 26 Sep 2026 that is per host:
arcade's body is reached through `nixosConfigurations.arcade-box`,
agent-hub's through `.llm-box`, and `hub-gates.sh` evaluates every host the
flake declares. `agent-hub` is imported but
`services.agent-hub.enable` defaults false, so its gate proves its option
declarations compose and little of its config body. Strictly better than zero,
and not the same as full coverage — which matters, because ADR 0006 makes these
gates the only thing between a merge and a switch.

**Minor — `nixpkgs.config.allowUnfree = true`** in `modules/platform/nix.nix`
is global. `allowUnfreePredicate` scoped to the packages that actually need it
(the nvidia driver, per `homelab.host.gpu`) states the intent and stops an
unrelated unfree dependency entering the closure unremarked.

**Not a finding: the tier model cannot fence Docker.** `resources.nix` emits a
`warnings` entry for any `needsDocker` tenant in a fenced tier, saying so
explicitly, and ADR 0005 records the decision. `cgroup_parent` in each tenant's
compose file is the fix, and it is applied. This is handled correctly.

---

## 6. Open work

Tracked in **one** place: `bd ready`. `docs/architecture.md` Part III is the
narrative of the delta, one row per gap, and every open row carries its bead
id. This section used to carry its own eleven-row list; by 12 Sep nine were
done and the two lists had started to disagree, which is the failure README's
"no second spelling" rule exists to prevent. By 13 Sep the last two were also
done (the bot split, `5f58ae0`; the homelab pipeline, ADR 0006) and the table
is gone.

---

## Keeping this current

This document is only worth having if it is refreshed rather than trusted.
Refresh it whenever the answer to "what is deployed?" could have changed — after
any switch on either host, after landing anything that changes the
closure, and before planning work that assumes a service is running.

**Step 1 — the three-way state.** One call, ~2s:

```bash
bash scripts/hub-status.sh; echo "EXIT=$?"
```

Exit 0 means the trees and the tenant tree are reconciled. Read the numbered
verdict on exit 1; each line names a distinct failure and they are not
interchangeable (see the `homelab-hub` skill for how to read them).

**Step 2 — the live survey.** These are the read-only commands this document
was built from. They are the ones that find drift `hub-status.sh` cannot see,
because they compare the *box* against the *declarations* rather than git
against git:

```bash
for h in arcade-box llm-box; do
  ssh $h 'hostname; nixos-version --configuration-revision; readlink -f /run/booted-system /run/current-system'
  ssh $h 'systemctl --failed; systemctl list-units --type=service --state=active --no-legend'
  ssh $h 'systemctl list-units --type=slice --no-legend; for s in critical interactive background batch; do systemctl show $s.slice -p CPUWeight -p MemoryMax -p AllowedCPUs -p ActiveState; done'
  ssh $h 'ss -tulnp'
  ssh $h 'iptables -S nixos-fw'
  ssh $h 'cat /etc/homelab/tenants.json; ls -la /var/lib/homelab'
done
ssh arcade-box 'docker ps -a --format "{{.Names}}\t{{.Status}}\t{{.Label \"com.docker.compose.project\"}}"; for c in $(docker ps -q); do docker inspect -f "{{.Name}} {{.HostConfig.CgroupParent}}" $c; done'
ssh llm-box 'systemctl show agent-hub-llm -p Slice -p AllowedCPUs -p MemoryMax; systemctl list-timers agent-hub-environment-poll.timer homelab-deploy.timer'
```

`--state=active`, not `running`: `ac-host-static`, `ac-host-bot`,
`ac-host-env` and `ac-host-ci` are oneshots that show `active (exited)`, and
a `running` filter hides all four.

**Step 3 — diff, in this order.** The order matters; each step assumes the one
before it passed.

1. `ss -tulnp` against the `ports`/`portRanges` blocks in
   `hosts/<host>/tenants.nix`. **Every live listener must be declared, and
   every declared port must be live or explained.** Four separate gaps have
   been found this way and none of them by reading a config file — the
   11200 range, the 18080/18081 sidecars, freeciv's real 4555 announce port,
   the 11300 sidecar sockets, and Mindustry's 20151 multicast port. Assume
   there is a sixth.
2. `systemctl list-units --state=running` against every tenant's `units` list.
   A running service in nobody's `units` is invisible to drain, quiet hours
   and the inventory.
3. Slice membership against `tier`. Remember that `critical` and
   non-`drainable` tenants are *deliberately* unsliced — that is not drift.
4. `/etc/homelab/tenants.json` against `tenants.nix`. A tenant missing from
   the JSON was disabled when the closure was built; a tenant present with no
   running units is a declaration with nothing behind it.
5. The closure drift itself, per host: homelab's HEAD against each host's
   `/run/current-system`. `hub-status.sh` prints one BOX section per host.

**Step 4 — update this file.** Move the date at the top, correct the tables,
and add a row to §6 rather than deleting one — an item that turned out to be a
human decision is more useful recorded as such than silently dropped.

### Open questions this round raised but did not settle

- ~~**Thirteen containers became nine.**~~ **Settled, 12 Sep.** The four were
  the dev environment, torn down deliberately from the workstation on 7 Sep
  at 23:57 (one SSH session, four `stopping restart-manager` lines in one
  second) so the unit-based blast-radius gate would see everything that was
  running — bead `homelab-bqo.14`, still open, should be closed with that.
  Nothing wanted is missing. The runbook criterion now names the configured
  set rather than a number.
- ~~**`ci.units` is still `[]`**~~ **Settled 12 Sep** — `214cfdd` (row 7);
  `ac-host-ci.service` is in `batch.slice` on arcade-box today, unit and
  containers alike.
- ~~**`modules/ci/default.nix`'s header is stale.**~~ **Settled** — the
  header no longer says the module is unimported.
- ~~**`/var/lib/ac-host/src/hosts/ac-box/hardware-configuration.nix` is mode
  0666**, and `README.md` points operators at that path~~ **Settled 26 Sep
  2026** — README points at `<host>:/etc/nixos/hardware-configuration.nix`;
  the `src` copy is the tenant tree's and travelled to arcade-box with it.

**Standing rules while doing any of this.** Both hosts are read-only
(AGENTS.md, "The hosts are read-only"): inspect over ssh; change arcade-box
by landing in git and letting its deploy unit switch it, and the Z840 by
landing in git and switching it from the pushed sha (ADR 0010). A hand-edit on either host is a debugging step, never a
resting state — land it the same session. Leave `bd` writes to the
coordinator.
