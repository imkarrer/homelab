# Runbook: the Z840 becomes llm-box -- the rename, the secrets file and the strip (ADR 0010, half two)

**Status: drafted 28 Sep 2026, nothing executed.** Every fact below was read
on 28 Sep 2026 between 08:27 and 09:16 CDT, read-only: over `ssh ac-box` (the
Z840, `192.168.1.51`) and `ssh arcade-box` (`192.168.1.50`), from the WSL
trees at the shas section 3 names, and from the operator's files. Nothing on
either host or in the operator's files was changed to produce it. The closure
measurements in sections 4 and 5 come from a scratch copy of homelab
`1a3a7ff` with the rename applied, evaluated with `nix eval` and compared
with `nix-diff`; nothing was built for a host or switched.

This is the second half of ADR 0010. The first half
(`docs/runbook-arcade-box-cutover.md`) left the Z840 running `agent-hub`
alone, unsliced, switched by hand. What is left is its name and its disk.
The name is `ac-box` in 201 present-tense places in homelab alone -- a
misnomer since 26 Sep, and ADR 0010 asks for a rename, not an alias. The
disk still carries ~69 G of what moved to arcade-box.

What does **not** change: the address (`192.168.1.51`, the Dream Router
reservation for MAC `c8:d3:ff:b9:28:0b` on `enp8s0`), the ssh host key, the
operator key, every unit, port and state path of `agent-hub`, the models
under `/srv/agent-hub`, the environment's poll edge, and everything on
arcade-box except two Prometheus labels and one alert selector.

The bead title's "agent-hub's hand pull" is no longer a step:
`agent-hub-environment-poll` (`homelab-ygc.14`) staged `b16781d` on 27 Sep
and `agent-hub-environment-pull` applied it (01:19:58 UTC,
`/var/lib/homelab/last-applied-environment-agent-hub.json`). 7.8 keeps only
the fallback, for a day the poll cannot see GitHub.

---

## 1. What is known (28 Sep 2026)

| | |
| --- | --- |
| Name | `hostnamectl`: static `ac-box`; `/proc/sys/kernel/hostname` `ac-box` |
| Running | homelab `1a3a7ff`, generation 127, switched 28 Sep 04:46 CDT |
| Booted | generation 120 (`aa48765`, the cutover's reboot of 26 Sep); `hub-status`: same kernel, initrd, modules and params, no reboot owed |
| Units | `agent-hub-llm`, `nginx`, `qdrant`, `prometheus-node-exporter` and the base set; `systemctl --failed` empty. Timers: `agent-hub-environment-{poll,pull}` every 10 min, `homelab-deploy` every 10 min with nothing new staged, `nix-gc` weekly (`--delete-older-than 7d`) |
| Docker | **not installed**: `docker.service` and `docker.socket` are `not-found`, no `docker` in the system profile. `/var/lib/docker` (52 G) is the directory the daemon left behind |
| Disk | `/` 915 G, 225 G used (26 %) |
| `nix.conf` | `substituters = https://cache.nixos.org/ https://cache.flox.dev` -- MinIO left with Docker |
| DHCP and DNS | NetworkManager `Wired connection 2` on `enp8s0`: `ipv4.method auto`, `dhcp-send-hostname` at its default (yes), no `dhcp-hostname` -- the system hostname goes to the router. The Dream Router's DNS answers `ac-box.localdomain -> 192.168.1.51` and the PTR back. Nothing in any tree or config resolves the Z840 by name; every consumer names `192.168.1.51` |
| `/etc/nixos` | `configuration.nix` is the 12 Sep tombstone: a `throw` whose text names `github:imkarrer/homelab#ac-box` twice. `hardware-configuration.nix` has the same content as the tracked `hosts/ac-box/hardware-configuration.nix` (the tracked one is nixfmt'd; `diff` of the two minus comments differs in layout only) |
| `/var/lib/homelab` | `{pending,last-applied}-closure.json`, both `aa48765` (the cutover's own record, so the idle deploy unit is a no-op); `{pending,last-applied}-environment-agent-hub.json`, both `b16781d` (live); five records of tenants gone since the cutover (section 6) |
| Seen from arcade-box | Prometheus targets `192.168.1.51:9100` (job `node`) and `192.168.1.51:8100` (job `agent-hub`), both `host="ac-box"`, both up; `HostLoadHigh: node_load5{host="ac-box"} > 56` |
| Backup | `/home/nixos/backup/status`: `LAST_RESULT=ok`, `RESULT_ac-box=ok` (`DIRS_ac-box=/var/lib/agent-hub /var/lib/qdrant`), `RESULT_arcade-box=ok`, 13 snapshots, 1.848 GiB, last success 28 Sep 09:33 UTC |
| WSL mirror | `/home/nixos/backup/ac-box/var/lib/`: `agent-hub` 284 K and `qdrant` 763 M (mirrored nightly), `monitoring` 12 K (frozen since observability stopped declaring it on 16 Sep; it holds the `secrets\r` twin). The four moved directories (`ac-host`, `arcade`, `grafana`, `prometheus2`) are **already gone**: the directory's mtime is 26 Sep 16:02 UTC, the cutover's step 4.6.5 |
| ssh | `~/.ssh/config`: `Host ac-box` -> `192.168.1.51`, `Host arcade-box` -> `192.168.1.50`, both `root` with `id_ed25519_ac-host`. `known_hosts` is keyed by **address**, not alias: `.51` and a stale `.49` carry the Z840's ed25519 key, `.50` and a stale `.218` pair carry arcade-box's, plus one stray `# 192.168.1.51:22 SSH-2.0-OpenSSH_10.5` banner line |

---

## 2. Decisions this runbook takes

Each is what the measurements force or what a careful operator would do.
The operator's own choices are section 9; the phases assume its
recommendations and say where an overrule changes them.

**D1. homelab goes first, and one commit carries everything that keys on
the name.** The name is defined in homelab -- the flake attribute, the host
directory, `homelab.host.name` (which is `networking.hostName` and the peer
name arcade-box scrapes under) -- and every hub script reads it from there;
other trees' prose follows a name that exists. Why one commit, measured on
the scratch copy: `modules/platform/identity.nix` reads the authorized keys
from `hosts/<homelab.host.name>/ssh-keys.local.nix` and falls back to `[]`
when that file is absent. A commit that sets `name = "llm-box"` without the
`git mv` evaluates, builds `nixos-system-llm-box-…`, and gives `root`,
`nixosuser` and `ac` **zero keys**. Switching it locks everyone out of a host
that is key-only since the cutover's D7; the way back is the console. The
other half alone (directory moved, name kept) fails evaluation loudly. So the
rename commit's proof includes the key count (7.2, P1).

**D2. Two ssh aliases for the transition, one at the end.** `Host llm-box`
is added before the push (7.1), because `hub-status.sh` ssh's to each flake
host by name and would call the Z840 unreachable the moment the registry
checkout carries the rename. `Host ac-box` is removed after the reboot's
proofs (7.5). Both point at `.51`, and `known_hosts` is keyed by address, so
neither needs a host-key step.

**D3. One hand switch, one reboot.** The command names the new attribute at
a pushed sha -- `#llm-box`, which exists only on origin -- and runs on the
Z840 through either alias, since both reach `.51`. `nixos-rebuild` without
an attribute would look for `#ac-box`, the current hostname, and find
nothing. `dry-activate` first. The reboot follows the switch (9.6).

**D4. No window, no drain.** Nothing on the Z840 races (CONTEXT.md: it has no
window), and `agent-hub` may be bounced freely (AGENTS.md). The one cost of a
bounce is a bead-loop round in flight, so the loop's lanes are paused around
the reboot. On arcade-box the push restarts `prometheus.service` and nothing
else (measured, 4.1) -- observability, freely; `homelab-deploy` still defers
it while anyone races.

**D5. The secrets file is its own, later commit, run by the operator** (the
agent harness refuses secret-store writes, cutover runbook 5.2). It changes
arcade-box's sops manifest and nothing else, and the Z840 not at all
(measured, section 5).

**D6. The strip is last.** It is the one irreversible phase, so it runs
after the rename is proven, after a backup run under the new host tag, and
after a restore spot-check proves arcade-box's copies restorable. None of it
is in git: box actions, run verbatim under AGENTS.md's migration exception,
stopping at section 8's criteria.

---

## 3. Inventory: every "ac-box", and where it goes

**Classes.**

- **(a)** means the Z840 today, or "the host" in a sentence still true of
  it -> `llm-box` (or the host-neutral word where the sentence is about
  either host). **L** marks a line that changes evaluation or behaviour: it
  must change in the rename commit.
- **(b)** means what has run on arcade-box since 26 Sep -- the lobbies, the
  bot, arcade, observability, the CI agent, the continuous deploy edge, the
  sops activation -> should already say `arcade-box`; stale since the
  cutover. **s** marks the path `secrets/ac-box.yaml`, which changes in the
  secrets commit (section 5), not the rename.
- **(c)** dated history: ADRs, runbooks and their "as it ran" records,
  surveys, measurements, closed beads, the tracker's export. Leave.
  CONTEXT.md's `ac-box` entry, kept and reworded (7.2), is how a reader
  decodes them.
- **(d)** an identifier that contains the string and names no host: a
  provider key, an environment variable, a commit identity. Leave; 9.5
  prices the one that matters.

**Counts**, by this runbook's reading, at the refs named. They move: ygc.15,
ygc.17 and ygc.19 are editing some of these files as this is written, so
3.7 regenerates the lists at execution.

| Tree (ref) | Hits | (a) | (b) | (c) | (d) |
| --- | --- | --- | --- | --- | --- |
| homelab (`main`, `1a3a7ff`) | 710 | 201 (12 L, 4 throw-text, 3 s) | 82 (21 s) | 426 | 1 |
| ac-host (`0fdf591`) | 73 | 4 | 32 | 18 | 19 |
| agent-hub (`b16781d`) | 96 | 56 (5 L) | 2 | 37 | 1 |
| home-arcade (`71b34a0`) | 62 | 0 | 26 | 36 | 0 |
| bead-loop (`origin/main`, `9a5af46`) | 89 | 1 | 6 | 39 | 43 |
| workstation (`5c48431`) | 14 | 9 | 5 | 0 | 0 |
| the operator's machine | 17 live + backups | 9 (3 L) | 1 | the `.bak` copies | 7 |

bead-loop was read at `origin/main` after a fetch: its registry checkout is
123 commits behind and dirty, and `hub-worktree.sh` branches from local
`main`, so its sweep's worktree must be based on `origin/main` explicitly.

### 3.1 homelab (a) -> llm-box

The rename commit (7.2, commit A) -- code, configuration and their comments:

- `flake.nix`: 2, 30, 32, 49, 142, 166, 226, **247 L**, 262, **265 L**,
  **268 L**, **269 L**, **270 L**, 308, **320 L** (and 250-258's "the rename
  to llm-box is homelab-ygc.9")
- `hosts/ac-box/` -> `hosts/llm-box/` by `git mv`: `host.nix` **8 L**;
  `configuration.nix` 1, 9, 37, 43, 47, 48 (the throw text: `git checkout --
  hosts/llm-box/…`, and re-fetch from `llm-box:/etc/nixos/hardware-configuration.nix`
  then nixfmt, not from `/var/lib/ac-host/src`, which the strip deletes --
  bead note 2), 124, 128, 203, 398; `tenants.nix` 1, 24;
  `tenants/agent-hub.nix` 1, 4, 23; `hardware-configuration.nix.example` 3, 6.
  ygc.15 edits `configuration.nix` and `tenants/agent-hub.nix`: land it first
- `hosts/arcade-box/host.nix`: 2, **16 L** (`import ../llm-box/host.nix`; the
  binding `acBox` becomes `llmBox` at 56, 57, 64), 45, 67, 78;
  `configuration.nix` 11, 116, 117; `hardware-configuration.nix` 7
- the harnesses' host facts: `modules/ci/tests/eval.nix` **47 L**;
  `modules/tenant/tests/eval-environment.nix` **49 L**, 858;
  `modules/tenant/tests/eval-resources.nix` 9, 10, 12, **43 L**, 110, 126,
  221. The same file, moved: verdicts unchanged (`nix flake check --no-build`
  passes on the scratch copy)
- other tests: `modules/tenant/tests/check.nix` 4, 11, 92, 263;
  `tests/eval.nix` 10, 54; `tests/eval-metrics.nix` 209;
  `tests/fixtures/environment-tenants.nix` 2, 3; `tests/fixtures/metrics-host.nix`
  15; `tests/fixtures/mgmt-no-address.nix` 2; `tests/stub-host-single-nic.nix`
  5; `tests/pinned-nixpkgs.nix` 14; `modules/ci/scripts/run-eval-tests.sh`
  11, 46
- modules: `modules/platform/boot.nix` 16, 18, 21, 27; `host-options.nix` 7,
  202, 247, 321; `identity.nix` 9; `network.nix` 22; `node-exporter.nix` 8;
  `modules/tenant/environment.nix` 91; `metrics.nix` 70, 71; `ports.nix` 123;
  `quiet.nix` 12; `schema.nix` 125
- `pkgs/boxctl/boxctl.py` 1, 4, 32, 358, 371
- scripts: `hub-status.sh` 19, **22 L** (the discovery fallback
  `HOSTS=ac-box`, a name that will not exist; `ls "$HUB/hosts"` gives the
  same names by identity.nix's invariant without a second spelling), 23;
  `hub-backup.sh` 23, 43, 49, 51, 56 (these claim the Z840's staging tree and
  restic history "run on unbroken" under `ac-box`; after the rename both
  split, 4.3), 331, 332, 383 (the `HOMELAB_HOSTS` hint), 454; `lib/hosts.sh`
  6, 18, 23, 30 (comments only -- it reads the names off the flake);
  `hub-gates.sh` 17, 28, 190, 271, 306; `hub-ask.sh` 2, 71
- `hub/repos.psv` 4, 30 (the hand-switch command), 53
- `.buildkite/pipeline.yml` 62 (a step label), 71, 72, 80
- `.gitignore` 36
- `.sops.yaml` 4, 11, 21 **s** -- the Z840's recipient, removed in section 5

The prose commit (7.2, commit B) -- docs and the agent-facing text:

- `AGENTS.md` 4, 22, 57, 59, 62 (the section "ac-box is read-only", bead
  note 1), 117
- `README.md` 6, 39, 114
- `CONTEXT.md` 20, 21, 25, 48, 106 -- every "until the rename lands"
  clause: **llm-box** (19-23, "until it lands this machine is `ac-box`";
  "_Avoid_: ac-box (after the rename)"), **ac-box** (25-29, "until
  `homelab-ygc.9` renames it"), **Peer** (48, "(llm-box once renamed)"),
  **Closure** (106, `nixosConfigurations.ac-box`)
- `docs/adr/0010-llm-box-serves-models-only.md` 9 (Status, "until it lands
  the Z840 is still `ac-box` …")
- `docs/architecture.md` 33, 37, 84, 89, 203, 243, 244, 285, 326, 349, 437
  (row 41: the hand-switch command, and "revisited only by the rename" --
  9.7), 439 (row 43: this bead)
- `docs/current-state.md` 1, 45, 50, 56, 76, 77, 78, 120, 123, 141, 152,
  173, 259, 306, 428, 482, 491, 543 (ygc.17 edits this file and row 40 of
  architecture.md: land it first)
- `docs/runbook-restore.md` 1, 19, 21, 166, 306, 317, 391
- `.agents/agents/homelab-inspector.md` 3, 14, 21; `homelab-local-worker.md`
  3, 11, 51; `homelab-worker.md` 32, 47
- `.agents/evals/homelab-skills.eval.yaml` 20, 32, 63, 66
- `.agents/skills/homelab-hub/SKILL.md` 3, 119; `homelab-land` 3, 8;
  `homelab-route` 3, 11; `homelab-supervise` 34; `homelab-verify` 21, 23,
  46, 50

### 3.2 homelab (b) -> arcade-box, stale since the cutover

- `modules/ci/default.nix` 1, 102, 114, 116 (HAZARD 2 names the agent's
  host), 255, 551, 577, 712; `modules/ci/tests/eval.nix` 3, 4, 14;
  `modules/ci/tests/fixtures/tenants.nix` 1
- `modules/deploy/default.nix` 290, 353 (an example `nix eval
  .#nixosConfigurations.ac-box…` for the deploy script; the deploy edge that
  runs is arcade-box's)
- `modules/observability/default.nix` 19, 36 **s**, 285;
  `modules/observability/scripts/docker_name_exporter.py` 4
- `modules/platform/secrets.nix` 27 **s**, 67 **s**, 121 **s**
  (`defaultSopsFile`), 489
- `modules/tenant/environment-pull.nix` 528;
  `tests/fixtures/environment-floxhub-tenants.nix` 2, 4;
  `tests/fixtures/metrics-quiet-tenants.nix` 68
- `hosts/arcade-box/tenants/arcade.nix` 1, 5, 23 ("arcade on ac-box",
  "imported by hosts/ac-box only")
- `pkgs/boxctl/boxctl.py` 41
- scripts: `hub-backup.sh` 176 **s**, 180 **s**, 443 **s**; `hub-status.sh`
  147 **s**; `hub-gates.sh` 211; `hub-pipeline.sh` 48, 49, 129;
  `hub-cluster-token.sh` 3 **s**, 7, 15, 25 (the token description's
  default); `hub-secret-set.sh` 2 **s**, 12, 30 **s**, 59 **s**;
  `hub-queue-closure.sh` 51 and `hub-queue-environment.sh` 144 ("(agent not
  on ac-box …)"); `hub-bump-lock.sh` 5; `hub-deploy.sh` 7 **s**;
  `lib/sops-secret.sh` 2 **s**, 29 **s**; `lib/buildkite-token.sh` 12 **s**;
  `lib/buildkite-cluster.sh` 2
- `hub/systemd/hub-backup.service` 1, 2 ("the nightly backup of ac-box's
  declared state" -- it backs up both hosts; this file reaches the WSL
  machine only when the workstation bumps its `homelab` input)
- `.sops.yaml` 7 **s**, 9 **s**; `.buildkite/pipeline.yml` 6
- `.agents/agents/homelab-inspector.md` 18, 19, 20, 22, 23 and
  `.agents/skills/homelab-land/SKILL.md` 60, 61, 75: `ssh ac-box` for the
  deploy records, the tenant tree, slices and `docker ps`, all arcade-box's
- `docs/architecture.md` 242 **s**; `docs/current-state.md` 57 **s**;
  `docs/runbook-restore.md` 23 **s**, 138, 149, 153, 156, 190, 191, 200, 217,
  220, 225, 229, 232. **The last five are a live hazard, not prose:** 4c
  stops the arcade units, moves `/var/lib/arcade` aside and verifies with
  `ssh ac-box` -- the Z840 -- but rsyncs the restored tree to
  `root@192.168.1.50`. Run verbatim today, the stop and the move land on the
  Z840 and the rsync lands on arcade-box, under arcade's running units. Its
  source path (`/home/nixos/backup/ac-box/var/lib/arcade`) is pre-cutover
  history, not arcade's current state. Fix these in commit B whatever else
  waits -- or before this runbook runs at all.

### 3.3 The other trees

**ac-host** -- (a) 4: `.cursor/skills/ac-ops/SKILL.md` 16; `README.md` 39;
`scripts/bootstrap_ssh.py` 9; `scripts/sync_series_models.py` 31 (its
reason -- "the Z840 still has a /var/lib/ac-host tree on disk" -- ends with
the strip). (b) 32, nearly all `homelab-ygc.19`'s list, which writes "the
Z840" where a hostname meant it: `.buildkite/pipeline.yml` 4;
`.flox/env/manifest.toml` 5; `DEV.md` 13; `compose/docker-compose.buildkite.yml`
1, 25, 39, 66, 90, 195, 204 (`BUILDKITE_AGENT_NAME` defaults to `ac-box`);
`compose/docker-compose.yml` 17, 22; `compose/env.buildkite.example` 3, 5;
`docs/ci-cd.md` 3, 12, 86; `flake.nix` 15, 16, 20; `monitoring/secrets.example`
1; `scripts/bootstrap_ssh.py` 28, 169 (a directory removed on 8 Sep);
`scripts/ci_containerize.sh` 18; `scripts/ci_image_smoke.py` 8;
`scripts/ci_queue_prod.py` 20; `scripts/ci_series_pack.sh` 2;
`scripts/github_release.py` 3, 26; `scripts/steamcmd_login.sh` 2;
`shared/pending_deploy.py` 1, 180. (c) 18: `.gitignore` 20, 21 (dead
patterns), `README.md` 21, 51, `docs/deploy-audit.md` (8),
`docs/plan-dual-nic.md` 5, `docs/runbook-dual-nic.md` 167, 172, 176,
`modules/ac-host.nix` 59, `scripts/acctl.py` 442. (d) 19: the
`AC_BOX_HOST`/`AC_BOX_USER` variables ("the Assetto Corsa box", still true of
arcade-box; neither is set in the live `.env`, so their defaults apply) in
`compose/env.example`, `compose/env.dev.example`, `scripts/settings.py`,
`scripts/unifi_pf.py`, `scripts/bootstrap_ssh.py` and the two dual-NIC docs.

**agent-hub** -- (a) 56: `.buildkite/pipeline.yml` 3, 12;
`.flox/env/manifest.lock` 24, 188 (generated from the manifest's hook and
flake description); `.flox/env/manifest.toml` 3, 17, 75, 86, 98;
`README.md` 7, 16, 23, 29, 32, 35, 37, 52, 77, 94, 96, 99, 101, 127, 143,
173, 212, 228, 230, 237, 277, 306, 328, 331, 334 -- of which 23 ("nothing
here should assume it's the only thing on ac-box"), 127 and 173 ("ac-box
runs plain rootful Docker") and 331-334 (`threads = 23` "to match the
fence") are false now, not merely misnamed; `flake.nix` 2, 5, 25;
`llama-swap.yaml` 2, 9, 40; `nix/ik-llama-cpp.nix` 13;
`scripts/bench/batch2.sh` **14 L**, **16 L**, **30 L**, **35 L** and
`scripts/bench/bench.sh` 4, 27, **45 L** (`ssh ac-box` commands, which break
when the alias goes); `scripts/compare.sh` 7, 11, 17; `scripts/fetch-model.sh`
2, 35; `scripts/run-task.sh` 32, 53 (again "plain rootful Docker");
`scripts/vectors-smoke.sh` 7. (b) 2: `.buildkite/pipeline.yml` 1 ("on the
ac-box agent"), `README.md` 319 (the Assetto Corsa port block). (c) 37:
`docs/network-isolation.md` (30, a dated live investigation of the
five-tenant host), `docs/prefill-tuning.md` 1, 188, 189, `README.md` 295, 298,
`llama-swap.yaml` 30, `nix/ik-llama-cpp.nix` 2. (d) 1: `README.md` 285 (the
opencode provider key in an example).

**home-arcade** -- (b) 26: `.buildkite/pipeline.yml` 1, 25;
`.flox/env/manifest.toml` 3, 9, 22; `.gitignore` 1; **`README.md` 3, 11**
(held on purpose by the previous session: a push of this tree can redeploy
it); `README.md` 23; `docs/candidates.md` 11, 43; `docs/ci.md` 3, 14, 29,
92, 116, 210, 213 (213 is an `ssh ac-box` step for a file on arcade-box);
`scripts/ci_test.sh` 6, 48; `scripts/fetch_mindustry.py` 5;
`windows/README.md` 26; `windows/hub.json.example` 5; `windows/install.ps1`
85, 102; `windows/sync.ps1` 1. The stations mount `\\192.168.1.50\arcade`
by address, so none of this is functional. (c) 36: `docs/plan-arcade.md`, a
plan written when one machine ran everything.

**bead-loop** (`origin/main`) -- (b) 6: `.buildkite/pipeline.yml` 9, 12;
`docs/pipeline.md` 27, 57; **`scripts/ci.sh` 12** and
**`systemd/bead-loop-deploy.service` 5** (both held on purpose; the unit's
installed copy is `~/.config/systemd/user/bead-loop-deploy.service` 5,
refreshed by the next deploy). (a) 1: `docs/examples/homelab.md` 30 (the
comment "ac-box's CPU"). (c) 39: `.beads/issues.jsonl` (17),
`.beads/interactions.jsonl` (1), `docs/design-lanes-per-server.md` (14),
`docs/design-providers.md` (3), `docs/operating.md` (4, log excerpts). (d)
43: the `acbox/…` provider key in `bead-loop.example.toml`, `docs/config.md`,
`docs/examples/homelab.md` 4, 23, 38, 45, 62, `docs/examples/quorum.md`,
`docs/state-machine.md`, `src/{config,lanes,park,round,stats}.rs`,
`src/doctor/probe.rs`, `test/run.sh`.

**workstation** (`~/src/workstation`, flox-workstation's) -- (a) 9:
`flake.nix` 70; `platforms/linux/README.md` 65, 96;
`platforms/linux/agent-hub.nix` 33, 40, 47, 53, 54;
`platforms/linux/docker.nix` 8. (b) 5: `flake.nix` 81, 82;
`platforms/linux/README.md` 23; **`platforms/linux/hub-backup.nix` 1, 2**
(held on purpose) -- "the nightly backup of ac-box" covers both hosts.

### 3.4 The operator's machine

A bounded `grep -rI` over `~/.config`, `~/.local/bin` and `~/.ssh`, plus
`/etc/nixos` and the trees' `.claude/settings.local.json`:

| Where | Class | What |
| --- | --- | --- |
| `~/.ssh/config` 1 | (a) L | `Host ac-box`. 7.1 adds `llm-box`; 7.5 removes this |
| `/home/nixos/src/homelab/.claude/settings.local.json` 4 and `/home/nixos/src/agent-hub/.claude/settings.local.json` 9 | (a) L | `"Bash(ssh ac-box:*)"`: Claude Code permission grants keyed on the alias. The operator's to change (7.5); an agent does not edit permissions |
| `~/.config/opencode/opencode.json` 6, 16, 24, 32 | (a) | display names: `"ac-box agent-hub (192.168.1.51:8100)"`, `"… (ac-box)"`. Cosmetic |
| `~/.config/opencode/opencode.json` 4, 69 | (d) | provider key `acbox`, `small_model: "acbox/utility"`; `baseURL` is `http://192.168.1.51:8100/v1` |
| `~/.config/bead-loop/config.toml` 22 | (a) | comment `[providers.acbox]  # ac-box's CPU …`; the probe is `http://192.168.1.51:8100/health` |
| `~/.config/bead-loop/config.toml` 13, 31, 37, 47, 59 | (d) | `acbox/coder`, `acbox/reviewer`, the `cpu` lane's `models = ["acbox/*"]` |
| `~/.config/systemd/user/bead-loop-deploy.service` 5 | (b) | installed copy of bead-loop's unit |
| `/etc/nixos/configuration.nix` 22 (WSL) | (a) | the WSL tombstone's "Same reasoning as ac-box's tombstone" |
| `*.bak*` copies of the above (4 bead-loop, 4 opencode, `~/.ssh/config.bak-20260908`, `/etc/nixos/configuration.nix.bak*`) | (c) | leave |
| `~/.local/bin` | -- | none: symlinks into the homelab registry checkout |
| `~/.ssh/known_hosts` | -- | no name entries at all (4.6) |

State keyed by the name that is not a file line: the Z840's hostname, its
`/etc/hosts`, its initrd and its `/etc/nixos` tombstone (4.1, 7.5); the
Dream Router's client name and DNS record (4.5); Prometheus's `host` label
(4.4); restic's host and tag, and the WSL staging path (4.3).

### 3.5 (c), summarized

homelab's 426: the tracker export (`.beads/issues.jsonl` 47,
`.beads/interactions.jsonl` 11); the ADRs (27 of 28 -- 0010's Status
paragraph is (a)); five dated runbooks and surveys
(`runbook-decommission.md` 98, `noop-reconciliation.md` 47,
`runbook-arcade-box-cutover.md` 46, `runbook-cutover.md` 17,
`runbook-ci-native-cutover.md` 6); `flox-findings.md`,
`flox-upgrade-1.16.md`, `spike-observability-as-environment.md` (4); and 123
lines in mixed files that record a date, a measurement or a provenance --
"surveyed live on ac-box, 7 Sep 2026", "verified on ac-box", "carried over
verbatim from ac-box's configuration.nix", the phase-1 `enforce.nix` notes,
arcade-box's comparisons with what the Z840 did. Every tree's (c) stays as
written; the "the box" sweep ADR 0010's Consequences names is a separate bead
and not this one.

### 3.6 (d), summarized

homelab `scripts/hub-bump-lock.sh` 144 (`bump-lock@ac-box.invalid`, the
bump-lock commits' author); ac-host's `AC_BOX_*` variables; bead-loop's and
the operator's `acbox` provider key (9.5). The operator key's file name,
`id_ed25519_ac-host`, is named for the ac-host tree, not a host, and is the
default in every hub script and in `.sops.yaml`'s identity derivation: leave.

### 3.7 Regenerating the lists

```bash
for t in homelab ac-host agent-hub home-arcade workstation; do
  git -C /home/nixos/src/$t fetch -q
  git -C /home/nixos/src/$t grep -n -i -E 'ac-box|acbox|ac_box' origin/main
done
git -C /home/nixos/src/bead-loop fetch -q
git -C /home/nixos/src/bead-loop grep -n -i -E 'ac-box|acbox|ac_box' origin/main
grep -rn -i -I -E 'ac-box|acbox|ac_box' ~/.config ~/.local/bin ~/.ssh /etc/nixos \
  /home/nixos/src/*/.claude/settings.local.json
```

Classify each new line by the rule above, not by the file it is in.

### 3.8 What a push of each tree costs

| Tree | A push does | So |
| --- | --- | --- |
| homelab | CI on arcade-box's agent, `queue-closure` stages, arcade-box's `homelab-deploy` switches within a minute (deferring while anyone races). The Z840 takes it only by the hand switch | the rename's push is 7.3 and 7.4 |
| ac-host | CI, `queue-prod` stages the tree, the bot's 03:00 DOWNTIME build applies it and recycles the lobbies in the window | one push with ygc.19; it lands the next night |
| agent-hub | CI; within ~10 minutes the Z840's poll stages the green sha and the pull checks it out and **restarts `agent-hub-llm`** -- every new sha, docs-only included (drainable) | pause bead-loop's lanes around it, or push while they are idle |
| home-arcade | CI; a push whose manifest or lock differ becomes a FloxHub generation and `arcade-environment-pull` bounces `arcade-freeciv` and `arcade-mindustry` (freely, AGENTS.md); one that changes neither stages the live generation again and bounces nothing | a sweep touching only `README.md`, `docs/` and `windows/` bounces nothing; the three `manifest.toml` comment lines cost one bounce |
| bead-loop | PR, CI on arcade-box's agent, automerge; `bead-loop-deploy.timer` on the WSL machine downloads the release and recycles the loop when idle | worktree from `origin/main` |
| workstation | nothing until the operator rebuilds (flox-workstation) | any time |

---

## 4. What keys on the name, and what happens when it changes

### 4.1 The closures (measured)

A scratch copy of `1a3a7ff` with the rename applied -- the `git mv`, `name =
"llm-box"`, the flake's four host paths and its two attribute names (247,
320), arcade-box's import, the three harness paths, nothing else -- passes
`nix flake check --no-build`, and
its stamp-stripped toplevels differ from `main`'s in exactly these
derivations (`nix-diff`):

| Host | Differs in | Therefore |
| --- | --- | --- |
| the Z840 | `etc-hostname` (`ac-box` -> `llm-box`), `string-hosts` (`127.0.0.2 llm-box`), `homelab-deploy` (its script's `host=`) and so `unit-homelab-deploy.service`, `initrd-hostname` and so `initrd-linux-6.18.48` and `boot.json`; the toplevel's name `nixos-system-llm-box-…` | no unit restarts at the switch: `homelab-deploy.service` is an inactive oneshot, `/etc` changes restart nothing. The initrd changes, so after the switch `hub-status` reports a reboot owed |
| arcade-box | `prometheus.yml` (the two Z840 targets' `host` label, `ac-box` -> `llm-box`; addresses and `instance` unchanged), `prometheus.rules` (`node_load5{host="llm-box"} > 56`), so `unit-prometheus.service` | the switch restarts `prometheus.service`, nothing else |

`networking.hostName` is `homelab.host.name` (`modules/platform/network.nix`).
The pinned nixpkgs writes `/etc/hostname` and nothing sets the kernel
hostname at activation (no activation script does, and
`switch-to-configuration-ng` has no hostname step). arcade-box's own first
switch showed it: "the kernel hostname stays `nixos` until a reboot
(`hostnamectl --static` already says `arcade-box`)" (cutover runbook 5.4).
So after the Z840's switch, `hostnamectl --static` says `llm-box` and
`/proc/sys/kernel/hostname` still says `ac-box` until the reboot.

CI names no host: `nix flake check` evaluates whatever `checks` holds,
`hub-gates.sh` iterates `nixosConfigurations`, `queue-closure` writes a rev
and each host's deploy unit builds its own attribute. Only a step label says
`ac-box`.

### 4.2 The hub scripts

`scripts/lib/hosts.sh` reads the host list off the flake; it has no list of
its own, only comments. Per script, after the rename:

- `hub-status.sh` ssh's to `$BOX` -- the flake name, so the **alias** -- and
  compares `/proc/sys/kernel/hostname` with it. Over the transition it
  therefore reports three expected verdicts for `llm-box`, and no others:
  "the ssh alias reached a machine calling itself ac-box" (from the push to
  the reboot), a closure behind HEAD that "only a hand switch moves" (from
  the push to the switch), and a reboot owed because the initrd differs
  (from the switch to the reboot). Its one literal host, the discovery
  fallback at 22, changes in the rename commit.
- `hub-backup.sh` ssh's to `root@<homelab.host.networks.lan.address>` from
  the eval, **not** the alias, and checks the key against the operator's
  `known_hosts` by address: the pull is unaffected. It stages under
  `/home/nixos/backup/<name>/`, tags restic `--host <name> --tag <name>` and
  writes `RESULT_<name>` -- all move to `llm-box` from the first run after the
  registry checkout carries the rename (4.3).
- `hub-deploy.sh` defaults to `arcade-box` (the tenant tree). `hub-ask.sh`,
  `hub-index.sh` and `hub-search.sh` default to `192.168.1.51`. None changes
  behaviour.

### 4.3 The backup

restic's `forget` groups by host and paths. From the rename on, the Z840's
snapshots form a new group, host `llm-box`, paths `/home/nixos/backup/llm-box`
-- a full first pull (~764 M, qdrant most of it) that deduplicates against
the old group's chunks. The `ac-box` group stops growing, and **a group that
stops growing never ages out**: `--keep-daily 7 --keep-weekly 4
--keep-monthly 6` keeps the newest seven days, four weeks and six months *that
have snapshots*, however old they are. It also holds the only history there
is of every tenant's state before 26 Sep (arcade-box's group starts that
day). 9.3 decides its end.

The staging tree `/home/nixos/backup/ac-box/` is never touched again: the
script pulls, snapshots and mirrors only the hosts the flake declares, and
removes no staging tree. It is deleted by hand after the first `llm-box`
snapshot (7.6). Its `monitoring/` has been a frozen copy re-snapshotted
nightly since 16 Sep; that ends with it.

### 4.4 Prometheus, the alerts and Grafana

The scrape target is the address (`192.168.1.51:9100`, `:8100`) and the
`instance` label is the address; the `host` label is the peer's name. At
arcade-box's switch the Z840's series change identity (`host="ac-box"` ends,
`host="llm-box"` begins) -- no gap in collection beyond Prometheus's restart.
The old series stay queryable until the TSDB's 14-day retention drops them.
The overview dashboard keys its panels on `job` with `{{host}}` legends and
no panel names a host, so it needs no edit; for up to 14 days the Z840 shows
as an `ac-box` line that ends and an `llm-box` line that starts (9.4). An
alert firing for `ac-box` at the switch would resolve and re-fire under
`llm-box`; none is firing today.

### 4.5 The router

The reservation is by MAC (`c8:d3:ff:b9:28:0b` -> `.51`), so the address does
not move. The name is what NetworkManager sends in its DHCP requests -- the
system hostname, `llm-box` everywhere from the reboot on -- and the Dream
Router registers it in its DNS (`llm-box.localdomain`). If the Clients page
carries a hand-set alias for the Z840, it keeps saying `ac-box` until edited
(7.5). Nothing resolves the Z840 by name.

### 4.6 ssh, known_hosts and the permission grants

The host key does not change. `known_hosts` is keyed by the `HostName`
address, so neither `ssh llm-box` nor `hub-backup`'s
`StrictHostKeyChecking=yes` pull needs anything added. Optional clean-up
(7.5): `.49` (the Z840's key at an address it no longer has), the two `.218`
lines (arcade-box's build-up address) and the stray banner line. `.51` and
`.50` stay. The two `Bash(ssh ac-box:*)` grants would make every `ssh
llm-box` prompt until replaced.

### 4.7 The environment edge and the Z840's records

Nothing in it carries a host name: `/etc/homelab/environments.json`, the
poll and pull units and their records name the tenant, the tree's remote
and a sha. Unchanged by the rename. The idle closure edge (`homelab-deploy`
and its `aa48765` records) is 9.7.

---

## 5. The secrets file

Since the cutover the Z840 imports no sops (`flake.nix`: sops-nix and
`modules/platform/secrets.nix` are in arcade-box's list only), yet
`.sops.yaml` still lists `&ac-box` (`age135yq…8agyl`) as a recipient of
`secrets/*.yaml`, and the file is named for it. D4 of the cutover runbook
deferred the rename as data churn; this is that bead.

**The step** (the operator; 9.1 recommends the name). In a worktree where a
worker has already changed the 21 **s** path references of 3.2 and
`.sops.yaml`'s header (the recipient table, lines 1-9; line 14's "until the
Z840 is stripped" goes) and the recipient comment in
`modules/platform/secrets.nix` 17-20, which names the Z840's key as "the
box":

```bash
git mv secrets/ac-box.yaml secrets/arcade-box.yaml
# .sops.yaml: delete `- &ac-box age135yqc5evu2tjffzgr8ryrn7n65qeuccu26jp5scpf8hp36eyrgest8agyl`
#             and the rule's `- *ac-box`
nix shell nixpkgs#sops nixpkgs#ssh-to-age -c bash -c '
  set -euo pipefail
  export SOPS_AGE_KEY="$(ssh-to-age -private-key -i ~/.ssh/id_ed25519_ac-host)"
  before=$(sops -d secrets/arcade-box.yaml | sha256sum)
  sops updatekeys -y secrets/arcade-box.yaml    # the recipients become the two in .sops.yaml
  sops rotate -i secrets/arcade-box.yaml        # a new data key, every value re-encrypted
  after=$(sops -d secrets/arcade-box.yaml | sha256sum)
  [ "$before" = "$after" ] && echo VALUES-UNCHANGED || echo VALUES-DIFFER
  grep -c "recipient: age1" secrets/arcade-box.yaml
  grep -c age135yqc5evu2tjffzgr8ryrn7n65qeuccu26jp5scpf8hp36eyrgest8agyl secrets/arcade-box.yaml || true'
```

from the tree's root, so sops finds `.sops.yaml`. Expected:
`VALUES-UNCHANGED`, `2`, `0`. The decrypted values go to `sha256sum` and
nowhere else.

**Every reference that moves with it**, all in homelab (no other tree, and
none of the operator's files, names the path): `modules/platform/secrets.nix`
121 (`defaultSopsFile`, the one that evaluates) and 27, 67;
`scripts/lib/sops-secret.sh` 2, 29 (the read path every hub script uses);
`scripts/hub-secret-set.sh` 2, 30, 59; `scripts/hub-backup.sh` 176, 180, 443;
`scripts/hub-status.sh` 147; `scripts/hub-cluster-token.sh` 3;
`scripts/hub-deploy.sh` 7; `scripts/lib/buildkite-token.sh` 12;
`modules/observability/default.nix` 36; `.sops.yaml` 7, 9;
`docs/architecture.md` 242; `docs/current-state.md` 57;
`docs/runbook-restore.md` 23. The dated runbooks keep the old name.

**What it changes, measured** on the scratch copy with the rename applied:
arcade-box's stamp-stripped toplevel differs only in sops-nix's
`manifest.json` (the source file's name) and so `activate`/`dry-activate`; no
unit file. The values are the same, so sops-nix modifies no secret and
restarts nothing. The Z840's toplevel is identical with and without it: it
needs no switch for this commit (a stamp-only hand switch keeps `hub-status`
quiet about "behind HEAD", at the operator's convenience).

**What dropping the recipient does NOT do.**

- It does not revoke anything already public. The repo is public, and every
  commit before this one holds ciphertext the Z840's host key
  (`/etc/ssh/ssh_host_ed25519_key` on the Z840) decrypts: every value as it
  stood then stays readable to that key for good. Only rotating the values
  themselves (the tokens, the passwords) takes them out of its reach -- not
  recommended while the Z840 is the operator's own machine on the same LAN;
  required before its disk ever leaves the house.
- `sops updatekeys` alone would not even protect later values: it re-wraps
  the **same** data key for the new recipients, and the old wrapped copy in
  history lets the Z840's key recover that data key and read any value
  written with it afterwards. That is why the step runs `sops rotate` too.
- It does not touch the Z840, which reads nothing from the file.
- When llm-box needs a secret again (a runner token, `homelab-bqo.10`), it
  gets its own `secrets/llm-box.yaml` with its own recipient and a creation
  rule of its own, not a place back on arcade-box's file.

Proof: gate green; `nix-diff` of arcade-box's stamp-stripped toplevel names
only `manifest.json`, `activate`, `dry-activate`; after the push, arcade-box's
`homelab-deploy` journal shows the switch with no unit restarted and
`systemctl --failed` empty there; `bash scripts/hub-status.sh` still prints
`floxhub-token present` (it decrypts through the new path).

---

## 6. The strip

### 6.1 What is on the Z840's disk (measured 28 Sep 2026)

| Path | Size | What | Where else it is |
| --- | --- | --- | --- |
| `/var/lib/ac-host` | 12 G | the racing tenant's state and `src`/`dist`/`build` | arcade-box, live, and restic under `arcade-box` (`src`/`dist`/`build` are git or rebuilt from it) |
| `/var/lib/arcade` | 21 M | arcade's saves and its old environment | arcade-box, live, and restic |
| `/srv/arcade` | 460 M | the ROMs | arcade-box, live. **Not in restic by design** (`data.backup = false`: "every one of them is re-obtainable"), so 6.3's S4 compares the two copies |
| `/var/lib/grafana` | 91 M | dashboards, users | arcade-box, live, and restic |
| `/var/lib/prometheus2` | 106 M | the TSDB, frozen 26 Sep | arcade-box (its copy continued) and restic |
| `/var/lib/docker` | 52 G | the orphaned daemon directory: `containerd` 19 G of images; volumes 33 G -- `ac-host-ci_buildkite-nix` 28 G, `ac-host-ci_minio-data` 3.7 G, `ac-host-ci_buildkite-builds` 1.7 G, `ac-host_ac-server` 31 M, anonymous ones of under 2 M | `ac-host_ac-server` on arcade-box and in restic; `minio-data` on arcade-box (a cache, regrown by CI); the rest regrows or is dead |
| `/var/lib/ci` | 3.6 G | the native-CI experiment of 18 Sep (`builds`, `env`, `minio`, `plugins`) | dead |
| `/var/lib/ac-host-dev` | 160 M | the dev profile's scratch, 2-7 Sep: `content/cars`, `dist`, `static/dev-blackhawk`, a dev `whitelist.json` and a dev `.env` | **nowhere** -- arcade-box's is the empty set of directories its module creates. 9.8 |
| `/var/lib/samba` | 2.2 M | smbd's databases | arcade-box has its own |
| `/var/lib/private/alertmanager`, `/var/lib/alertmanager` (a symlink to it) | 4 K | alertmanager's state | arcade-box has its own. `/var/lib/private/qdrant` beside it is **live** |
| `/var/lib/monitoring` | 12 K | two directories named `secrets`, one with a trailing carriage return (`homelab-bqo.61`) | sops on arcade-box |
| `/root` | 459 M | `fetch-model.sh` and `.log`, `result` (a GC root pinning a 7 Sep closure), `.docker` (`homelab-bqo.44`); `.buildkite-agent`, `.mc`, `.minio` from the CI era; `.npm` and `.cache` are root's tool caches and stay | -- |

And in `/var/lib/homelab`, the records of tenants the Z840 no longer
declares. No unit watches them there (the Z840's path units are
`agent-hub-environment-pull.path` and `homelab-deploy.path` only):

| File | Size, mtime (CDT) | Content |
| --- | --- | --- |
| `last-applied-environment-arcade.json` | 244 B, 18 Sep 17:53 | generation 2 of `imkarrer/arcade`, run `f6m1q3pd…` |
| `pending-environment-arcade.json` | 247 B, 18 Sep 19:05 | generation 2, rev `71b34a0`, home-arcade build 10 |
| `pinned-environment-arcade` | 2 B, 18 Sep 17:53 | `2` |
| `last-applied-environment-ci.json` | 278 B, 18 Sep 18:01 | homelab `754d21f` at `/var/lib/ci/env`, the native-CI units |
| `pending-environment-ci.json` | 187 B, 18 Sep 17:01 | homelab `754d21f`, `source: runbook` |

They stay: `pending-closure.json` and `last-applied-closure.json` (9.7) and
the two agent-hub records.

Pre-cutover system generations 117-119 still sit in the Z840's profile (not
in the boot menu, which lists 123-127); the next weekly `nix-gc` (Monday 5
Oct, `--delete-older-than 7d`) collects them. Nothing to do.

### 6.2 What hub-backup does with it

Nothing changes. Since the cutover none of these paths is declared on the
Z840 (`DIRS_ac-box=/var/lib/agent-hub /var/lib/qdrant`), so the nightly pull
never read them, and deleting them is invisible to it. On the WSL side the
four moved directories already left `/home/nixos/backup/ac-box/` on 26 Sep;
the rest of that tree goes in 7.6. Their history stays in restic under
`ac-box` (9.3).

### 6.3 Preconditions -- all of them, or delete nothing

**S1.** Phases 7.1-7.6 are done: the rename is live and proven, and the
throw text in `hosts/llm-box/configuration.nix` points at
`llm-box:/etc/nixos/hardware-configuration.nix`, not into the
`/var/lib/ac-host/src` this deletes.

**S2.** The backup is ok for both hosts, from a run after the rename:

```bash
grep -E '^(LAST_SUCCESS|LAST_RESULT|HOSTS|RESULT_)' /home/nixos/backup/status
```

`LAST_RESULT=ok`, `HOSTS=arcade-box llm-box`, `RESULT_arcade-box=ok`,
`RESULT_llm-box=ok`, `LAST_SUCCESS` from the last run; and `hub-status.sh`
prints no `backup:` verdict.

**S3.** A restore spot-check: one file from each moved tree that restic
holds, out of arcade-box's newest snapshot, against the live file on
arcade-box. The invocation is `docs/runbook-restore.md` section 2's, with one
correction: the repo is `root:root 0700` (`ls -la /home/nixos/backup`), so
restic runs under `sudo`. Every file below is static (mtimes 31 Aug-13 Sep),
so a live file cannot have legitimately moved on since the snapshot.

```bash
cd /home/nixos/src/homelab
RESTIC=$(nix build --no-link --print-out-paths nixpkgs#restic)/bin/restic
export RESTIC_REPOSITORY=/home/nixos/backup/restic
export RESTIC_PASSWORD="$( . scripts/lib/sops-secret.sh; hub_sops_secret restic-repo-password )"
R() { sudo --preserve-env=RESTIC_REPOSITORY,RESTIC_PASSWORD "$RESTIC" --no-cache "$@"; }
R snapshots --host arcade-box --latest 1          # the snapshot the loop restores from
SCRATCH=$(mktemp -d); M=/home/nixos/backup/arcade-box
PB=$(ssh arcade-box 'ls /var/lib/prometheus2/data | grep -E "^01[0-9A-Z]{24}$" | head -1')
for f in /var/lib/ac-host/whitelist.json \
         /var/lib/docker/volumes/ac-host_ac-server/_data/acServer \
         /var/lib/arcade/mindustry/server-release.jar \
         /var/lib/grafana/plugins/grafana-metricsdrilldown-app/1296.js \
         "/var/lib/prometheus2/data/$PB/meta.json"; do
  R restore latest --host arcade-box --target "$SCRATCH" --include "$M$f" >/dev/null
  a=$(sudo sha256sum "$SCRATCH$M$f" 2>/dev/null | cut -c1-64)
  b=$(ssh arcade-box "sha256sum '$f'" | cut -c1-64)
  if [ -n "$a" ] && [ "$a" = "$b" ]; then echo "OK   $f"; else echo "FAIL $f restored=${a:-missing} live=$b"; fi
done
sudo rm -rf "$SCRATCH"; unset RESTIC_PASSWORD
```

Expected: five `OK` lines. The Prometheus line takes the oldest block,
immutable once cut; if retention dropped it after the snapshot it reads
`missing` -- take the next (`sed -n 2p`) and re-run that one line. Any other
`FAIL` is a backup that does not restore: stop, and open a bead against
`hub-backup.sh`.

**S4.** `/srv/arcade`, which restic does not hold, compared copy to copy:

```bash
T=$(mktemp -d)
ssh llm-box    'cd /srv/arcade && find . -type f -print0 | sort -z | xargs -0 sha256sum' | sort > "$T/z840"
ssh arcade-box 'cd /srv/arcade && find . -type f -print0 | sort -z | xargs -0 sha256sum' | sort > "$T/arcade-box"
wc -l < "$T/z840"; comm -23 "$T/z840" "$T/arcade-box"; rm -rf "$T"
```

Expected: a count, then nothing -- every file on the Z840 is on arcade-box,
byte for byte (arcade-box may have more).

**S5.** The Z840 is what it should be, and nothing is mounted under a
target:

```bash
ssh llm-box 'grep -oE "\"name\":\"[a-z-]+\"" /etc/homelab/tenants.json; ls /var/lib/private
  findmnt -rn -o TARGET | grep -E "^/(var/lib/(docker|ac-host|ac-host-dev|arcade|grafana|prometheus2|ci|samba|monitoring)|srv/arcade)" || echo no-mounts'
```

Expected: `"name":"agent-hub"` alone; `alertmanager qdrant`; `no-mounts`.

**S6.** The operator has decided 9.8 (`/var/lib/ac-host-dev`).

### 6.4 The deletions (box actions on the Z840, verbatim, in this order)

One command per path, run one at a time; a non-zero exit is a stop.
`--one-file-system` keeps `rm` from crossing into anything S5 missed.

```bash
ssh llm-box 'rm -f /var/lib/homelab/last-applied-environment-arcade.json'
ssh llm-box 'rm -f /var/lib/homelab/pending-environment-arcade.json'
ssh llm-box 'rm -f /var/lib/homelab/pinned-environment-arcade'
ssh llm-box 'rm -f /var/lib/homelab/last-applied-environment-ci.json'
ssh llm-box 'rm -f /var/lib/homelab/pending-environment-ci.json'
ssh llm-box 'rm -rf --one-file-system /var/lib/monitoring'          # both `secrets` dirs, homelab-bqo.61
ssh llm-box 'rm -rf --one-file-system /var/lib/private/alertmanager' # NOT /var/lib/private: qdrant lives there
ssh llm-box 'rm -f /var/lib/alertmanager'                           # the symlink to it
ssh llm-box 'rm -rf --one-file-system /var/lib/samba'
ssh llm-box 'rm -rf --one-file-system /var/lib/grafana'
ssh llm-box 'rm -rf --one-file-system /var/lib/prometheus2'
ssh llm-box 'rm -rf --one-file-system /var/lib/arcade'
ssh llm-box 'rm -rf --one-file-system /srv/arcade'                  # NOT /srv: the models are /srv/agent-hub
ssh llm-box 'rm -rf --one-file-system /var/lib/ac-host-dev'         # only if 9.8 says drop
ssh llm-box 'rm -rf --one-file-system /var/lib/ac-host'
ssh llm-box 'rm -rf --one-file-system /var/lib/ci'
ssh llm-box 'rm -rf --one-file-system /var/lib/docker'
ssh llm-box 'rm -f /root/fetch-model.sh'                            # homelab-bqo.44: this and the next three
ssh llm-box 'rm -f /root/fetch-model.log'
ssh llm-box 'rm -f /root/result'
ssh llm-box 'rm -rf /root/.docker'
ssh llm-box 'rm -rf /root/.buildkite-agent'
ssh llm-box 'rm -rf /root/.mc'
ssh llm-box 'rm -rf /root/.minio'
```

### 6.5 Proof

```bash
ssh llm-box 'for p in /var/lib/ac-host /var/lib/ac-host-dev /var/lib/arcade /srv/arcade /var/lib/grafana \
    /var/lib/prometheus2 /var/lib/docker /var/lib/ci /var/lib/samba /var/lib/monitoring \
    /var/lib/alertmanager /var/lib/private/alertmanager; do { test -e "$p" || test -L "$p"; } && echo "STILL $p"; done
  ls /var/lib/homelab; ls /var/lib/private; df -h /
  systemctl --failed --no-legend | wc -l; systemctl is-active agent-hub-llm nginx qdrant'
curl -s -m 10 http://192.168.1.51:8100/running
```

Expected: no `STILL` line; `/var/lib/homelab` holds the two closure records
and the two agent-hub records; `/var/lib/private` holds `qdrant`; `/` down
from 225 G used by ~69 G (less 160 M if 9.8 kept `ac-host-dev`); `0`;
`active` three times; `/running` answers. `hub-status.sh` clean for
`llm-box`; the next backup run still `RESULT_llm-box=ok` with the same
`DIRS_llm-box`.

---

## 7. Order: the phases, each with its proof

Who: **operator** (a human: the operator's files, the router, the secret
store, the console); **agent** (read-only checks, and box steps this runbook
spells out, under AGENTS.md's migration exception -- sha on origin, stop at
section 8); **worker** (a commit in a worktree); **supervisor** (merge,
push, `bd`).

### 7.0 Preconditions

1. ygc.15 and ygc.17 have landed. They edit files the rename moves or
   rewrites (`hosts/ac-box/configuration.nix`, `hosts/ac-box/tenants/agent-hub.nix`,
   `docs/current-state.md`, `docs/architecture.md`). If ygc.15's homelab half
   is on `main`, the Z840's hand switch carries it and its new variables reach
   `agent-hub-llm` at the reboot (`restartIfChanged = false`); its agent-hub
   half is pushed after 7.5's proofs, which is the order ygc.15 needs anyway.
2. `bash /home/nixos/src/homelab/scripts/hub-status.sh`: no verdict prefixed
   `ac-box:` or `arcade-box:`; both closure sections `CLEAN`, the Z840 on
   HEAD -- so its hand switch carries the rename and nothing unread.
3. The backup's last run ok for both hosts (6.3, S2's command, with
   `RESULT_ac-box`).

### 7.1 The new alias -- operator

Add to `~/.ssh/config`, beside `Host ac-box`:

```
Host llm-box
  HostName 192.168.1.51
  User root
  IdentityFile ~/.ssh/id_ed25519_ac-host
  IdentitiesOnly yes
```

Proof: `ssh -o BatchMode=yes llm-box hostname` prints `ac-box`, with no
host-key prompt (`known_hosts` already has `.51`).

### 7.2 The rename in git -- worker, then supervisor

Two commits on one branch, one push.

**Commit A, the rename** -- every **L** line of 3.1 and the (a) comments in
the same code files, together:

- `git mv hosts/ac-box hosts/llm-box`; `name = "llm-box";` in its `host.nix`
- `flake.nix`: `nixosConfigurations.llm-box`, the four `./hosts/llm-box/…`
  paths, `checks.llm-box = self.nixosConfigurations.llm-box…`
- `hosts/arcade-box/host.nix`: `llmBox = (import ../llm-box/host.nix { }).homelab.host;`
  and its three uses
- the three harness `hostFacts` paths
- `scripts/hub-status.sh`'s fallback; `scripts/hub-backup.sh`'s hint and
  its header's claims about an unbroken `ac-box` history (4.3)
- the throw text in `hosts/llm-box/configuration.nix` (bead note 2)
- `hub/repos.psv`'s hand-switch command: `…#llm-box`

**Commit B, the prose** -- 3.1's second list, and 3.2's (b) lines that are
not **s** (a homelab push costs one arcade-box switch whatever it carries, so
the stale-since-the-cutover sweep rides here). Four texts to get right:

- `AGENTS.md`, the section now headed "ac-box is read-only" (bead note 1):
  "The hosts are read-only" -- never hand-edit arcade-box or llm-box; an
  agent may apply a pushed revision with `nixos-rebuild switch --flake
  github:imkarrer/homelab/<full-sha>#<host>` (on llm-box the closure's only
  edge, ADR 0010) and run host-side steps a runbook spells out verbatim; the
  `dry-activate` abort on `ac-host-static.service` or `docker.service` is
  arcade-box's.
- `CONTEXT.md`: **llm-box** loses "until it lands this machine is `ac-box`"
  and says renamed from `ac-box` on the date, _Avoid_: ac-box. **ac-box**
  stays, as the decoder for history: the Z840's name until that date; before
  26 Sep the machine that ran all six tenants, from 26 Sep to the rename the
  model host alone; "not a host name any more". **Peer**: "arcade-box's peer
  is `llm-box`". **Closure**: `nixosConfigurations.llm-box`.
- ADR 0010's Status: half two landed, with the date and the sha.
- `docs/architecture.md` row 43 landed; row 41 records 9.7's decision.
  `docs/runbook-restore.md` 4c's `ssh` steps name `arcade-box` (3.2).

**Proofs, before the push** (the worker's handoff carries them):

- **P1, the keys** -- the lockout check (D1). Two keys, and the same two
  `main` gives the Z840 today:
  ```bash
  k() { nix eval --json "$1#nixosConfigurations.$2.config.users.users.root.openssh.authorizedKeys.keys"; }
  k . llm-box | jq length                                  # 2
  k . llm-box | sha256sum                                  # the branch, after
  k /home/nixos/src/homelab ac-box | sha256sum             # main, before: the same digest
  ```
- **P2** `nix eval --raw .#nixosConfigurations.llm-box.config.networking.hostName` is `llm-box`.
- **P3** `nix-diff` of the Z840's stamp-stripped toplevel, `main`'s
  `ac-box` against the branch's `llm-box` (`homelab-verify`'s recipe with
  `system.configurationRevision = mkForce null` on both sides), names exactly
  4.1's derivations.
- **P4** the same for arcade-box names exactly `prometheus.yml`,
  `prometheus.rules` and what depends on them (`unit-prometheus.service`,
  `system-units`, `etc`, `activate`). Anything with `ac-host`, `docker` or
  `ac-host-ci` in its name: do not push (AGENTS.md's abort, earned before it
  can happen -- arcade-box switches by itself).
- **P5** `bash /home/nixos/src/homelab/scripts/hub-gates.sh homelab <worktree>`:
  `===== GATES PASS - safe to push =====`.

### 7.3 The push -- supervisor

Merge, push. CI (arcade-box's agent) builds both toplevels, `queue-closure`
stages, arcade-box's `homelab-deploy` switches.

Proof:

```bash
ssh arcade-box 'journalctl -u homelab-deploy --since "-30min" --no-pager | tail -5'   # "applied <sha>"
ssh arcade-box 'curl -s "http://127.0.0.1:9090/api/v1/targets?state=active"' \
  | jq -r '.data.activeTargets[] | select(.labels.host=="llm-box") | [.labels.job,.labels.instance,.health] | @tsv'
ssh arcade-box 'curl -s "http://127.0.0.1:9090/api/v1/rules?type=alert"' \
  | jq -r '.data.groups[].rules[] | select(.name=="HostLoadHigh") | .query'
```

Expected: the sha applied; `node 192.168.1.51:9100 up` and `agent-hub
192.168.1.51:8100 up`; `node_load5{host="arcade-box"} > 6` and
`node_load5{host="llm-box"} > 56`. `hub-status.sh` now walks `arcade-box
llm-box`: arcade-box `CLEAN`; llm-box carries exactly the first two expected
verdicts of 4.2 (the kernel hostname, the closure behind HEAD).

### 7.4 The hand switch -- agent, verbatim

First pause what uses the model server (operator):

```bash
bead-supervisor pause cpu    # the lane over acbox/*: reviews, research
bead-supervisor pause gpu    # its sessions call acbox/utility, opencode's small_model
bead-supervisor status       # wait until neither lane has a round in flight
```

Then, `SHA` the full 40-hex sha of 7.3's push, on origin. `ssh ac-box` would
reach the same machine; `#llm-box` is the point, and it exists only at that
sha.

```bash
SHA=<full sha>
ssh llm-box "nixos-rebuild dry-activate --flake github:imkarrer/homelab/$SHA#llm-box" 2>&1 | tail -15
```

Expected: `would activate the configuration...` and no unit under `would
stop`, `would restart`, `would reload` or `would start`. A `would NOT stop`
or `NOT restarting` line for `agent-hub-llm.service` is ygc.15's unit change
riding along (7.0) and is fine. Anything else is a stop (section 8).

```bash
ssh llm-box "nixos-rebuild switch --flake github:imkarrer/homelab/$SHA#llm-box"; echo "exit $?"
ssh llm-box 'hostnamectl --static; cat /proc/sys/kernel/hostname; nixos-version --configuration-revision
  systemctl --failed --no-legend | wc -l; systemctl is-active agent-hub-llm nginx qdrant prometheus-node-exporter'
curl -s -m 10 http://192.168.1.51:8100/running
```

Expected: `exit 0`; `llm-box`, then `ac-box` (the kernel's, until 7.5);
`$SHA`; `0`; `active` four times; `/running` answers as before -- the switch
restarted nothing. `hub-status.sh` now shows llm-box's closure `CLEAN` and a
reboot owed (the initrd differs), plus the hostname verdict.

### 7.5 The reboot, then the operator's machine and the router

```bash
ssh llm-box systemctl reboot
# back in ~3.5 min at the cutover; retry this until it answers
ssh -o BatchMode=yes -o ConnectTimeout=5 llm-box true
ssh llm-box 'hostnamectl; cat /proc/sys/kernel/hostname; readlink /run/booted-system /run/current-system
  systemctl --failed --no-legend | wc -l; systemctl is-active agent-hub-llm nginx qdrant prometheus-node-exporter
  systemctl list-timers agent-hub-environment-poll.timer --no-pager | head -3'
curl -s -m 10 http://192.168.1.51:8100/running
curl -s -m 120 http://192.168.1.51:8100/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"utility","messages":[{"role":"user","content":"Reply with the word ok."}],"max_tokens":5}'
curl -s -m 10 http://192.168.1.51:9100/metrics | grep '^node_uname_info'
```

Expected: static and kernel hostname `llm-box`; booted == current; `0`;
`active` four times; the poll timer's NEXT within 10 minutes; `/running`
answers (empty until a model is asked for); the 4B answers; `nodename="llm-box"`.
Within ten minutes, `ssh llm-box 'journalctl -u agent-hub-environment-poll
--since "-15min" --no-pager | tail -2'` shows a `Finished` tick. Within a
minute, 7.3's target query still shows both `llm-box` targets `up`.
`hub-status.sh`: llm-box and arcade-box `CLEAN`, llm-box's booted line "no
reboot owed", no verdict prefixed with either host. Then
`bead-supervisor resume cpu; bead-supervisor resume gpu`.

The operator, afterwards:

- `~/.ssh/config`: delete the `Host ac-box` block (D2, 9.2). Proof: `ssh -G
  ac-box | grep '^hostname '` prints `hostname ac-box` (no alias), and
  `hub-status.sh` is unchanged.
- The two `"Bash(ssh ac-box:*)"` grants become `"Bash(ssh llm-box:*)"`
  (`/home/nixos/src/homelab/.claude/settings.local.json`,
  `/home/nixos/src/agent-hub/.claude/settings.local.json`).
- Optional: `ssh-keygen -R 192.168.1.49; ssh-keygen -R 192.168.1.218`, and
  delete the `# 192.168.1.51:22 SSH-2.0-OpenSSH_10.5` line. Keep `.51`, `.50`.
- Optional, cosmetic: opencode's four `ac-box` display strings and the
  bead-loop config comment (9.5).
- Dream Router -> Clients -> MAC `c8:d3:ff:b9:28:0b`: if the name is a
  hand-set `ac-box`, make it `llm-box`; leave the Fixed IP. Proof:
  `ssh llm-box 'host llm-box 192.168.1.1; host 192.168.1.51 192.168.1.1'`
  answers `llm-box.localdomain` both ways.

And one box step, verbatim -- the Z840's `/etc/nixos` tombstone names the
configuration a human would rebuild with. Every `ac-box` in it means the
Z840:

```bash
ssh llm-box 'sed -i -e "s|homelab#ac-box|homelab/<full-sha>#llm-box|g" -e "s|ac-box|llm-box|g" /etc/nixos/configuration.nix
  nix-instantiate --parse /etc/nixos/configuration.nix >/dev/null && grep -c llm-box /etc/nixos/configuration.nix'
```

Expected: parses, `7`. (The `<full-sha>` stays a literal placeholder in the
text, as AGENTS.md's form has it.)

### 7.6 The backup under the new name -- operator

`sudo systemctl start hub-backup.service` (or wait for 04:30 CDT), then:

```bash
grep -E '^(LAST_RESULT|HOSTS|RESULT_|SNAPSHOT_|DIRS_)' /home/nixos/backup/status
sudo ls /home/nixos/backup/llm-box/var/lib
```

Expected: `LAST_RESULT=ok`, `HOSTS=arcade-box llm-box`, `RESULT_llm-box=ok`,
`SNAPSHOT_llm-box=<id>`, `DIRS_llm-box=/var/lib/agent-hub /var/lib/qdrant`;
`agent-hub qdrant`. With 6.3's `R` defined, `R snapshots --host llm-box`
lists one snapshot tagged `llm-box,hub-backup`. Then the frozen staging
tree:

```bash
sudo rm -rf --one-file-system /home/nixos/backup/ac-box
```

Its contents stay in restic under host `ac-box` until 9.3's date.

### 7.7 The secrets file -- worker, operator, supervisor

Section 5, as its own push. Nothing on the Z840.

### 7.8 The environment's fallback -- only if the poll is down

The poll stages nothing when GitHub is unreachable, rate-limited, or
carries no `buildkite/agent-hub` success on main's HEAD. To stage a green
sha by hand, write the exact record `scripts/hub-queue-environment.sh`
writes, atomically, and let the pull unit's path unit fire on the rename:

```bash
SHA=<full sha on agent-hub origin/main, its Buildkite build green>
BUILD=<https://buildkite.com/isaac-karrer/agent-hub/builds/N>
jq -cn --arg sha "$SHA" --arg build "$BUILD" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{tenant:"agent-hub", sha:$sha, tree:"git@github.com:imkarrer/agent-hub",
    queued_at:$at, build:$build, branch:"main", source:"runbook"}' \
| ssh llm-box 'f=/var/lib/homelab/pending-environment-agent-hub.json; cat > "$f.tmp" && mv -f "$f.tmp" "$f"'
```

`tree` must be `hub/repos.psv`'s remote verbatim or the pull refuses the
record. Proof: `ssh llm-box 'journalctl -u agent-hub-environment-pull
--since "-10min" --no-pager | tail'` shows the checkout, the warm and the
restart; `last-applied-environment-agent-hub.json` names the sha; hub-status
prints `agent-hub env: staged X / applied X`. The pull substitutes but never
builds, and only from the Z840's own caches (cache.nixos.org and
cache.flox.dev, section 1): a sha whose lock names a new CI-built path is
refused however it was staged.

### 7.9 The strip -- agent, verbatim

Section 6: S1-S6, then 6.4, then 6.5.

### 7.10 The other trees -- a bead each, after 7.5

In the order the costs of 3.8 make cheap: workstation (free), home-arcade
(free unless it touches `manifest.toml`), bead-loop (a PR), ac-host (with
ygc.19, applied at the next 03:00), agent-hub last (a model-server restart;
the lanes paused, and its bench scripts' `ssh ac-box` lines are **L**). Each
sweep takes both (a) and (b) of 3.3; the lines the previous session held
back ride here.

### 7.11 The tracker -- supervisor

`bd` memories that say `ac-box`:

| Key | What changes |
| --- | --- |
| `arcade-box-bootstrap-facts` | the Z840 is llm-box; the hand switch is `…#llm-box`; its environment arrives by its own poll (ygc.14), not "pulled by hand"; aliases `llm-box -> .51`, `arcade-box -> .50` |
| `buildkite-cluster-and-sandbox` | the agent is `arcade-box`; "privileged is the only option" held on arcade-box too (cutover runbook, phase 3) |
| `closure-switches-continuously` | the continuous edge is arcade-box's; its proof is `ssh arcade-box 'journalctl -u homelab-deploy …'`. Also stale in it: "hub/repos.psv keeps agent-push=ask" (it is `yes` since 16 Sep) |
| `configuration-revision-drvpath-proof` | the recipe's `nixosConfigurations.ac-box` -> `.llm-box` or `.arcade-box` |
| `flox-environment-deploy-edge` | `agent-hub-llm` runs on llm-box; agent-hub's staging half is the poll; MinIO is no substituter on the Z840 |
| `homelab-agent-push-yes` | a push switches arcade-box within a minute, the Z840 by hand |
| `homelab-glossary` | "'The box' = ac-box" is wrong since ADR 0010: Box is any host, named |
| `hub-gates-homelab-lacks-flake-check` | stale twice (it evaluates every host and runs `nix flake check --no-build`): forget it |

Open beads that say `ac-box`:

| Bead | What changes |
| --- | --- |
| `homelab-bqo.44`, `homelab-bqo.61` | done by 6.4: close with the strip |
| `homelab-bqo.39.1` | "BUILDKITE_AGENT_NAME stays ac-box" -> `arcade-box` (rendered from `homelab.host.name` since the cutover); its acceptance's `secrets/ac-box.yaml` -> `secrets/arcade-box.yaml` after 7.7 |
| `homelab-bqo.54` | `hosts/ac-box/tenants.nix` -> `hosts/arcade-box/tenants.nix` |
| `homelab-bfq`, `homelab-bfq.12`, `homelab-bfq.13` | `modules/ci` moves off arcade-box, not ac-box; "ac-box's ci compose stack" is arcade-box's |
| `homelab-bfq.5` | its baseline was the Z840 at `CPUWeight 0.05`; ci-box's comparison is now with arcade-box, which needs a baseline of its own |
| `homelab-bfq.11` | its probe results are the Z840's (history); arcade-box's are in the cutover runbook, phase 3 |
| `homelab-bqo.10` (deferred) | "the runner on ac-box" -> llm-box; a token there needs a `secrets/llm-box.yaml` (section 5), since the Z840 imports no sops |
| `homelab-ygc.15`, `homelab-ygc.19` (in progress) | paths `hosts/ac-box/…` are `hosts/llm-box/…` once 7.3 lands |
| `homelab-ygc`, `homelab-bqo` (epics) | titles are history: leave |

bead-loop's own tracker (`bl-*`, bead-loop's `.beads`, not this hub's) has
eleven open beads that mention it; two mean a host -- `bl-6fx` ("the resident
4B on ac-box") and `bl-6aa` ("cold vs warm rust step on ac-box", the CI agent
that is arcade-box's now) -- the rest are `acbox/…` model strings and round
notes. For whoever owns that tracker.

---

## 8. Abort criteria and the rollback ladder

Stop -- not judge -- at any of these:

- **P1** finds a key count or digest other than `main`'s. A lockout, not a
  warning.
- **P3/P4** name a derivation 4.1 does not. On arcade-box, anything with
  `ac-host`, `docker` or `ac-host-ci` in its name.
- **7.3**: arcade-box's `homelab-deploy` fails, or restarts anything but
  `prometheus.service`.
- **7.4 dry-activate** lists a unit under stop, restart, reload or start.
- **7.4 switch** exits non-zero, `systemctl --failed` is non-empty, or `ssh
  llm-box` stops answering.
- **7.5**: the Z840 does not answer ssh within 10 minutes of the reboot
  (the operator goes to the console), or `agent-hub-llm` is not active, or
  `:8100` does not answer.
- **Section 5**: `VALUES-DIFFER`, or a recipient count other than 2.
- **6.3**: any precondition unmet. **6.4**: any non-zero exit.

Rollback, by how far it got:

- Before 7.3's push: drop the branch; remove `Host llm-box` if wanted.
  Nothing moved.
- After the push, before 7.4: `git revert` both commits and push --
  arcade-box switches its labels back; the Z840 was never touched.
- After 7.4's switch, before the reboot: `ssh llm-box nixos-rebuild switch
  --rollback` (the generation before, which 7.0 made HEAD-before-the-rename;
  127 on 28 Sep), and the revert above. Minutes.
- After the reboot: pick that generation in the systemd-boot menu at the
  console, or `nixos-rebuild switch --rollback` then reboot; the revert above;
  keep or restore `Host ac-box`. Nothing about the name touches data.
- After section 5: `git revert` brings back the old file and recipients --
  ciphertext the operator's and arcade-box's keys still open.
- After 6.4: none, by design; S3 and S4 proved the copies that remain.
  `/var/lib/ac-host-dev` (if dropped) and `/var/lib/ci` are gone for good.

---

## 9. Open decisions -- the operator's, each with a recommendation

**9.1 The secrets file's name.** Recommend `secrets/arcade-box.yaml`: it
names the one host whose key decrypts it at activation, it keeps the
`secrets/<host>.yaml` shape the file already had, and ci-box, when it comes,
splits off a `secrets/ci-box.yaml` rather than renaming this one. Cost: the 21
path references and three recipient lines of one commit; arcade-box's sops
manifest changes (no restart, measured). Rejected: keeping `ac-box.yaml` --
the third name ADR 0010 rules out, pointing at a host that no longer exists;
`secrets/homelab.yaml` -- survives any move, but hides whose key opens it,
which is the thing to know when a host leaves (as now). Either way the
operator-only values in it (`restic-repo-password`, `buildkite-api-token`)
stay readable to arcade-box's key, as they are today; an operator-only file
is a separate bead if that matters.

**9.2 An `ac-box` ssh alias after the rename.** Recommend drop (7.5, after
the reboot's proofs), as ADR 0010 says. Cost: anything still typing `ssh
ac-box` fails loudly -- agent-hub's two bench scripts until their sweep, the
two permission grants until replaced. Keeping it is the alias ADR 0010
rejected.

**9.3 restic's `ac-box` snapshots.** Recommend keep until 1 Apr 2027 -- six
months, the reach of the 7/4/6 policy's monthly slots -- then forget them in
a dated bead:

```bash
R snapshots --host ac-box --json | jq -r '.[].id' | xargs sudo --preserve-env=RESTIC_REPOSITORY,RESTIC_PASSWORD "$RESTIC" --no-cache forget --prune
```

Why not now: they are the only history of every tenant's state from 14 to
26 Sep and of the Z840's agent-hub and qdrant until the rename, and they
cost little (the repo is 1.848 GiB and deduplicated). Why not never: a group
that stops growing is never pruned by the nightly `forget` (4.3), so without
a date it stays in every `restic snapshots` indefinitely.

**9.4 Prometheus label continuity.** Recommend accept the split. The Z840's
series change identity at arcade-box's switch; the overview dashboard needs
no edit and shows an ended `ac-box` line beside a new `llm-box` one until the
14-day retention drops the old series. Nothing is lost that 14 days would
not lose anyway. The alternative (a recording rule, or `label_replace` in
every panel) is machinery for two weeks of a legend. ygc.10's label change
did the same to arcade-box's own series.

**9.5 The `acbox` provider key.** Recommend keep it. It is a provider name
in `opencode.json` and bead-loop's config, not a host name -- like
`AC_BOX_HOST`, and the traffic goes to `192.168.1.51` either way. Renaming it
costs one coordinated edit of `opencode.json` (the provider key,
`small_model`) and bead-loop's `config.toml` (`research_model`, the stage
reviewer, the `cpu` lane's glob, `[providers.acbox]`) with the loop paused,
since a model string naming a provider opencode lacks fails the round; a
split per-model history in bead-loop's scoreboard; and, optionally, the
bead-loop repo's 43 sample and test lines. It buys consistency and no
function. Change only the display strings (cosmetic, 7.5).

**9.6 The reboot.** Recommend fold it in (7.5). Bead note 5's reason is gone
(`hub-status` stopped owing a reboot for every switch with `bqo.63`), but
two measured ones replace it: the rename changes the Z840's initrd
(`initrd-hostname`), so `hub-status` reports a reboot owed after the switch;
and nothing on this nixpkgs sets the kernel hostname at activation, so until
a boot `hub-status`'s alias check, node_exporter's `nodename`, the journal
and the router all keep saying `ac-box`. Cost: `agent-hub` down ~3.5 minutes
(the cutover's reboot) with the lanes paused, and models reloading on first
use. Setting the kernel hostname by hand instead would be a hand-edit and
would leave the initrd verdict standing.

**9.7 The idle closure edge on the Z840** (architecture row 41: "revisited
only by the rename"). Recommend keep `modules/deploy` on llm-box through this
change and decide its removal in its own bead. Keeping it costs a timer that
does nothing every ten minutes, two `aa48765` records, and hub-status's
informational "a hand switch happened since" line. Removing it inside the
rename would add unit stops to the one switch whose `dry-activate` is meant
to show none, and it is a behaviour change, not a name. What keeping it
buys: an edge ready the day something stages a closure there.

**9.8 `/var/lib/ac-host-dev` on the Z840.** Recommend drop. It is the only
copy of the dev profile's scratch from 2-7 Sep -- a dev whitelist (third-party
ids, so never git) and a dev `.env` among it -- and nothing reads it on
either host. If the operator wants it, copy it first, privately:
`sudo rsync -a --numeric-ids -e "ssh -i /home/nixos/.ssh/id_ed25519_ac-host -o
UserKnownHostsFile=/home/nixos/.ssh/known_hosts"
root@192.168.1.51:/var/lib/ac-host-dev/ /home/nixos/backup/z840-ac-host-dev/`.

---

## 10. As it ran

_Empty until executed. One row per step: when (CDT), who, what happened, the
proof's actual output where it differed from the expected._

| When | Step | What happened |
| --- | --- | --- |
| | | |
