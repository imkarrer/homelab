# Runbook: arcade-box takes the lobbies, the arcade, observability and CI off ac-box (ADR 0010, half one)

**Status: drafted 26 Sep 2026, nothing executed.** The Lenovo is on the LAN
and running a stock NixOS install; the operator has password ssh to it and
nothing else has touched it. Every fact below that came from a machine says
which one and when. Facts still owed are in the table at the end and are
filled in by phase 1 before phase 2 writes a line of Nix.

This is the first half of ADR 0010: the move. The second half -- stripping
the Z840 to `agent-hub` and renaming it `llm-box` -- is its own runbook and
epic, because it touches every tree's docs and the tracker. What this
runbook leaves behind on ac-box is already ADR 0010's llm-box in everything
but name: `agent-hub`, the platform, the deploy units idle.

`ci-box` (ADR 0012, proposed in a worktree, epic `homelab-bfq`) is not this
box and not this runbook: `ci` moves here whole, and ADR 0012 later takes
the gate steps off it onto a fourth machine. Section 2 says why it cannot
stay behind.

---

## 1. What is known about the new box (26 Sep 2026)

Found from ac-box with a ping sweep and `ip neigh`, then probed from WSL
with `ssh-keyscan` and an `ssh -v` that offered no credential. Nothing was
logged in to.

| | |
| --- | --- |
| Address | `192.168.1.218`, DHCP, **no reservation yet** |
| MAC | `e8:6a:64:f4:81:94` |
| Hostname it announces | `nixos` (the installer's default) |
| OS | NixOS, `OpenSSH_10.5`; root login offers `publickey,password,keyboard-interactive` |
| Host key (ed25519) | `AAAAC3NzaC1lZDI1NTE5AAAAILcHBx8G0JLhFqlGgD+1ajjrIhiOVqCfHRGhJalc9vYj` |
| Its age recipient (`ssh-to-age` of that key) | `age15lpvpdcg6k7jt82wk4fwmu7a3gtgkf2mwk6cxfst5r2xura8u9xsuz33rr` |
| Accounts | `root` and a login named `arcade` (uid 1000, `wheel`, sudo **with** a password). The operator's key is on `arcade` since 26 Sep 2026; root refused it because the installer's `configuration.nix` sets `PermitRootLogin = "no"`. The name matters: in the closure `arcade` is the **tenant's system user** (`hosts/*/tenants/arcade.nix`, `isSystemUser`, home `/var/lib/arcade`), and the human accounts on every homelab host are `nixosuser` and `ac` (`modules/platform/identity.nix`, key-only). See 5.4 |
| Hardware (measured 26 Sep 2026) | **i7-8700T**, 6 cores / 12 threads, one socket (ADR 0010's table said i7-9700T; bead `homelab-bfq.6` had it right). 31 GiB (`MemTotal` 32700632 kB). `nvme0n1` 953.9 G: p1 512 M vfat `/boot`, p2 ext4 `/`, no swap. UEFI (AMI 5.13), systemd-boot 260.2, Secure Boot off, TPM2 present |
| NICs | `eno2` `e8:6a:64:f4:81:94` is the LAN port (`.218`); `wlo1` is a Wi-Fi card with no carrier, which `network.nix`'s `wireless.enable = mkForce false` already leaves alone |
| NixOS | `26.05.8639.c5c4a43b0e80` -- the **same nixpkgs revision homelab pins**, so the first switch is almost entirely substitution; `system.stateVersion = "26.05"` |

And the side of ac-box that matters here, read the same day:

| | |
| --- | --- |
| `enp8s0` (the live NIC, `.50`) | `c8:d3:ff:b9:28:0b` |
| `eno1` (no carrier) | `c8:d3:ff:b9:28:0a` -- the port the cable went into by mistake on 13 Sep (bead `homelab-bqo.42`) |
| Address | DHCP with a UDR reservation per MAC (`nmcli`: `ipv4.method auto`); no static address in the closure |
| `/var/lib/ac-host` | 12 G (`content` 4.0 G; `src`/`dist`/`build` 7.9 G, all in git or rebuilt from it) |
| `/srv/arcade`, `/var/lib/arcade` | 460 M, 21 M |
| `/var/lib/prometheus2`, `/var/lib/grafana` | 107 M, 91 M |
| CI volumes | `ac-host-ci_minio-data` 3.7 G (the flox binary cache -- keep), `ac-host-ci_buildkite-nix` 27 G (the agent's store -- re-warms, do not copy), `ac-host-ci_buildkite-builds` 1.7 G (checkouts -- skip) |
| Images built on the box, not pulled | `ac-host-env:latest` 4.24 G, `ac-host-server:latest` 187 M, `ac-host-buildkite-agent:flox` 6.39 G |
| `UNIFI_*` keys in `/var/lib/ac-host/.env` | none: `unifi_pf.py` is off, so the nine `ac-prod-s{0,1,2}-{game,http,details}` forwards on the Dream Router are hand-set and point at `.50` by number |

---

## 2. Decisions this runbook takes

Each is the routine call a careful operator would make; each names what
changes if the operator overrules it.

**D1. `ci` moves with the lobbies, in the same cutover.** The tenant tree's
delivery is local by design (`ac-host/docs/ci-cd.md`, "Why no SSH"): the
`Image` step loads `ac-host-env:<sha>` into the daemon the agent's socket
belongs to, `queue-prod` writes `/var/lib/ac-host/pending-src` through a
bind mount, the bot's 03:00 DOWNTIME build applies it in place, and
homelab's `queue-closure` and `queue-environment` write the local
`/var/lib/homelab`. Every one of those steps must run on the host that owns
the state, and every pipeline says `queue: self` -- one queue, one agent.
So the agent and its MinIO go where the lobbies go, and the Z840's agent
stops the moment its closure drops the `ci` tenant. The cost: CI is offline
for the minutes between the two switches in phase 4, and `agent-hub`'s
environment edge on the Z840 loses its staging step (its pending file is
written wherever the agent runs) -- which is ADR 0010's stated end state
for llm-box, "pulls and restarts by hand".

**D2. arcade-box inherits `192.168.1.50`; the Z840 gets a new address.**
Everything that people and the router know by address belongs to the
tenants that are moving: the nine hand-set forwards, the stations' SMB path
and the two rsync stations, Grafana's URL. None of them changes. What does
change is the address of the model server, and every consumer of that is a
script default the operator owns:

```
homelab/scripts/hub-ask.sh          HUB_LLM=http://192.168.1.50:8100
homelab/scripts/hub-index.sh        LLM / QDRANT
homelab/scripts/hub-search.sh       LLM / QDRANT
agent-hub/scripts/vectors-smoke.sh  LLM / QDRANT
agent-hub/scripts/compare.sh        TARGETS
```

The swap is two DHCP reservations on the Dream Router (per MAC, section 1)
and a lease renewal on each box. The operator can overrule this into "the
Lenovo keeps a new address" at the cost of editing nine forwards in the
UDR UI and every station.

**D3. The Lenovo's existing install is kept.** No reinstall, no
`nixos-anywhere`: `hardware-configuration.nix` is fetched from its
`/etc/nixos/` (README: fetched, never invented), its host key is the sops
recipient above, and the first switch replaces the installer's
configuration with the flake's. If phase 1 finds a disk layout worth
changing (no swap on 32 GB is fine; a single ext4 root is what ac-box has),
that is a reinstall decision to take before phase 2, not after.

**D4. One secrets file for two hosts, for now.** `secrets/ac-box.yaml`
gains arcade-box's recipient (`sops updatekeys`); after the cutover it is
arcade-box that needs every key in it and the Z840 that needs none.
Renaming the file is data churn for a later bead, not this one.

**D5. The cutover is a daytime, operator-present event, not the 03:00
window.** Two hosts switch and a reservation moves between them; that is
not a thing `homelab-deploy` does alone. `busyCheck` still guards the
Z840's switch (it defers while anyone is racing, ADR 0008), so the only
scheduling requirement is `drivers_online.py` at 0 and a post in
`#server-status` first. The one abort criterion this runbook suspends, for
the one switch that empties the Z840, is AGENTS.md's "`docker.service`
under stop is an abort": stopping the lobbies is that switch's job.

**D6. No cpuset fence on arcade-box** (ADR 0010, "tier -> slice without the
cpuset fence"). `resources.nix` always fences `batch` to at least one core;
on a 6-core host with `critical.cpuShare` at the default that is one or two
cores for every CI build. A per-tier `homelab.tiers.<tier>.fence` (default
true, so ac-box is unchanged) turns `AllowedCPUs` off on this host;
`CPUWeight` and `MemoryMax` still apply, which is what a runaway build
needs to hit.

**D7. Password ssh goes off on both hosts, in the same change** (the
operator, 26 Sep 2026, the day the key landed on the Lenovo).
`modules/platform/ssh.nix` carried `PasswordAuthentication = true` from
ac-box's pre-flake config with a note to turn it off once key-only logins
were confirmed; three weeks of switches, backups and `hub-status` runs as
root over the key are that confirmation. The push that adds arcade-box
carries `false` for both `PasswordAuthentication` and
`KbdInteractiveAuthentication`, so ac-box goes key-only at that switch and
arcade-box is key-only from its first. Cost: a device without one of the
two keys in `ssh-keys.local.nix` has no ssh to either host, and the way
back in is the console. `sudo` needs no password for `wheel` on either
host (`identity.nix`, `wheelNeedsPassword = false`); the installer's
password prompt exists only until the first switch.

---

## 3. Phase 0 -- human only

Three things only the operator can do; everything after them can be done
from WSL by an agent under this runbook.

**0.1 Key access.** Done in two steps on 26 Sep 2026, because the installer
refuses root over ssh (`PermitRootLogin = "no"`) and the one login it made,
`arcade`, sudoes with a password:

1. `ssh-copy-id -i ~/.ssh/id_ed25519_ac-host.pub arcade@192.168.1.218`
   (done; the key on that account is the same one `ssh-keys.local.nix`
   installs for root and `nixosuser`, verified byte for byte).
2. The bootstrap, one command, one password. It gives root the same key,
   lets root in with a key on the installer's own config, and rebuilds that
   config -- nothing of the flake yet:

```bash
ssh -t arcade@192.168.1.218 'sudo install -d -m 700 /root/.ssh && sudo install -m 600 ~/.ssh/authorized_keys /root/.ssh/authorized_keys && sudo sed -i "s/PermitRootLogin = \"no\"/PermitRootLogin = \"prohibit-password\"/" /etc/nixos/configuration.nix && grep -n PermitRootLogin /etc/nixos/configuration.nix && sudo nixos-rebuild switch && echo BOOTSTRAP-OK'
```

After `BOOTSTRAP-OK`, `ssh -o BatchMode=yes root@192.168.1.218 true` works
from WSL, every later step is an agent's, and the first flake switch (5.4)
removes the `arcade` login, turns password ssh off (D7) and makes `sudo`
passwordless for `wheel`.

Add to `~/.ssh/config` beside `ac-box`:

```
Host arcade-box
  HostName 192.168.1.218
  User root
  IdentityFile ~/.ssh/id_ed25519_ac-host
  IdentitiesOnly yes
```

(`HostName` becomes `192.168.1.50` in phase 4.)

**0.2 Pin the build-up address.** Dream Router -> Network -> Clients ->
the client with MAC `e8:6a:64:f4:81:94` -> Fixed IP `192.168.1.218`. This
is what keeps `hosts/arcade-box/host.nix` true for the weeks before the
swap. Note the new address the Z840 will take in phase 4 while you are
there (a free one the UDR offers; write it in section 9, never guess it).

**0.3 BIOS.** Power on after power loss (this is an always-on host), and
confirm the machine boots unattended with no keyboard. Secure Boot off or
already working with the installed systemd-boot -- `bootctl status` in
phase 1 confirms.

---

## 4. Phase 1 -- survey, read-only

Agent, from WSL, nothing written on the box. Fill section 9 from:

```bash
ssh arcade-box 'lscpu | grep -E "Model name|^CPU\(s\)|Thread\(s\) per core|Socket"; \
  free -g; lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT; ip -br link; ip -4 addr; \
  nixos-version; bootctl status | head -8; cat /etc/nixos/configuration.nix; \
  cat /etc/nixos/hardware-configuration.nix; ls /sys/firmware/efi'
```

Then:

- `scp arcade-box:/etc/nixos/hardware-configuration.nix hosts/arcade-box/`
  (tracked, like ac-box's -- README's pinned convention).
- `stateVersion`: whatever the installer wrote; it is copied, not chosen.
- Capacity for `host.nix`: `cpuThreads`, `threadsPerCore`, `memoryGiB`
  (`/proc/meminfo` rounded, the activation check allows 2 GiB slack), the
  NIC name for `networks.lan.interface`.
- Correct ADR 0010's hardware row from `lscpu`, and close or note
  `homelab-bfq.6`'s claim.

The Nix-sandbox probe for CI (bead `homelab-bfq.11`'s one-line derivation
under `docker run --security-opt seccomp=unconfined`, then `privileged`)
runs in phase 3 once Docker exists on the box. Its answer is recorded, not
acted on: the compose file stays `privileged: true`, which is correct on
both kinds of host.

---

## 5. Phase 2 -- the host in git, and the first switch

One bead, landed through the gate and pushed. A push to homelab main
switches ac-box (ADR 0008): adding a host changes nothing in ac-box's
closure but the revision stamp, and the stamp-stripped `drvPath` proof
(`homelab-verify`) is how the refactor below is shown to be a no-op for it.
The flake check on ac-box's agent now builds two toplevels; the first
arcade-box build is mostly substitution and runs at `cores = 2` in
`batch.slice`, so expect one slow build.

### 5.1 New files

```
hosts/arcade-box/host.nix                  name, tz, lan = <nic>/.218/24, unifi 192.168.1.1,
                                           capacity from phase 1, paths, window 03:00, gpu null
hosts/arcade-box/tenants.nix               ac-box's minus agent-hub: assetto, bot, arcade,
                                           observability, ci -- verbatim, same ports, same state
hosts/arcade-box/configuration.nix         enforce.* on; services.ac-host.enable = false (build-up);
                                           lanInterface = the host's lan NIC; arcade stub declared,
                                           environment.enable = false (first-switch order);
                                           ci.enable = false (build-up); deploy.enable = true,
                                           schedule continuous (idle: nothing stages until the
                                           agent is here); tiers per 5.3
hosts/arcade-box/hardware-configuration.nix   fetched, phase 1
hosts/arcade-box/ssh-keys.local.nix        a copy of ac-box's (same operator keys)
hosts/arcade-box/tenants/arcade.nix        `git mv` from hosts/ac-box/tenants/ -- one spelling;
                                           ac-box imports it from here until phase 4 removes the import
```

`services.ac-host.lanInterface` has never been set on ac-box because its
default, `enp8s0`, happens to match; on arcade-box it is
`config.homelab.host.networks.lan.interface` or the lobby ports open on no
interface at all.

### 5.2 Module changes, each small, each with its harness case

| File | Change | Why |
| --- | --- | --- |
| `flake.nix` | per-host module lists from one shared platform list; `nixosConfigurations.arcade-box`; `checks.arcade-box` | two hosts, one contract |
| `modules/tenant/ports.nix` | read `networks.mgmt` only if declared | the Tiny has one NIC; `mgmtIface = netCfg.mgmt.interface` is evaluated unconditionally today |
| `modules/tenant/resources.nix` | `homelab.tiers.cpusetFence` (default true) | D6 |
| `modules/observability/default.nix` | alert names and summaries from `homelab.host.name`; `AcBoxLoadHigh`'s `> 28` from `capacity.cpuThreads / 2` | the rules carry ac-box's name and 56 threads as literals |
| `modules/platform/secrets.nix` | `BUILDKITE_AGENT_NAME=${homelab.host.name}` in the `ci-env` template; the `.env` copy unit and the bot's ordering on it exist only while `services.ac-host` is enabled | two agents named `ac-box` would be indistinguishable in Buildkite; a host without the lobbies would otherwise get a copy unit with nowhere to copy to and an empty `ac-host-bot` unit |
| `modules/platform/ssh.nix` | `PasswordAuthentication` and `KbdInteractiveAuthentication` false | D7 |
| `.sops.yaml` + `secrets/ac-box.yaml` | add `&arcade-box` (section 1's recipient) to `keys:` and to the rule's `age:` list; then `SOPS_AGE_KEY="$(ssh-to-age -private-key -i ~/.ssh/id_ed25519_ac-host)" sops updatekeys -y secrets/ac-box.yaml` (both under `nix shell nixpkgs#sops nixpkgs#ssh-to-age`). **The operator runs this**: the agent harness refuses secret-store writes (26 Sep 2026). It must land before 5.4 -- activation decrypts with the host key, and a file the box cannot read fails the switch | D4; the box decrypts with its host key at activation |
| `scripts/hub-status.sh`, `hub-backup.sh`, `hub-deploy.sh` | host-aware: `HOMELAB_BOX` per host, the BOX section per host, backup evaluates the host that declares the state. **Landed 26 Sep 2026** (`homelab-ygc.4`, `scripts/lib/hosts.sh` reads the hosts off the flake; the staging mirror gains `backup/<host>/`, ac-box's untouched) | after phase 4 the scripts would report and back up the wrong machine -- this lands **before** the cutover, not after |

`hub-gates.sh` already iterates every `nixosConfigurations` attribute, so
the gate covers arcade-box the moment it exists.

### 5.3 Tier shares for a 6-core, 32 GiB host (confirm against phase 1)

| Tier | memoryShare | cpuShare | Holds |
| --- | --- | --- | --- |
| critical | 0.20 (~6.2 GiB) | 0.50 | the lobby containers, sidecars, bot via `cgroup_parent` (peak 2.5 GiB on ac-box) |
| interactive | 0.20 (~6.2 GiB) | 0.20 | arcade (Mindustry `-Xmx1G`), samba, rsync, observability (~1.3 GiB peak) |
| background | 0.05 (~1.5 GiB) | 0.05 | nothing -- no tenant of this tier here; a small ceiling rather than a `MemoryMax=0` slice |
| batch | 0.45 (~14 GiB) | 0.30 | the agent, MinIO, `nix-daemon` (`modules/platform/nix.nix` slices it here) |

Sum 0.90, the budget. Weights only, no `AllowedCPUs` (D6,
`homelab.tiers.{background,batch}.fence = false`): a CI build takes the
whole box when the lobbies are idle and yields 500:300 when they are not.
`--spawn` stays 1 until `homelab-bfq.5`-style numbers exist for this host.
Live values are `hosts/arcade-box/configuration.nix`'s, not this table's.

### 5.4 The first switch -- box action on arcade-box

**Precondition: the installer's `arcade` login is gone.** With
`users.mutableUsers` at its default, NixOS keeps an existing user's uid when
the declaration names none, so the first switch would turn the installer's
uid-1000 `arcade` into the tenant's "system" user with a leftover
`/home/arcade` -- working, and wrong-shaped for good. After 0.1's bootstrap
root has the key, so the agent does this while the box is still the
installer's:

```bash
ssh root@192.168.1.218 'loginctl terminate-user arcade 2>/dev/null; userdel -r arcade; id arcade 2>/dev/null || echo removed'
```

From the switch on, `root` and `nixosuser` carry the key exactly as on
ac-box, password ssh is off (D7) and `wheel` sudoes without a password.

The command that worked, 26 Sep 2026 (`22c30a3`, CI build 144 green on the
branch first), as a transient unit so an sshd restart mid-switch cannot
take the switch with it, and with two things the installer's system lacks
supplied on the way in:

```bash
ssh arcade-box 'cat > /root/first-switch.sh' <<'EOF'
#!/run/current-system/sw/bin/bash
set -euo pipefail
# no experimental features in the installer's nix.conf; accept-flake-config
# so root takes flake.nix's cache.flox.dev rather than compiling flox
export NIX_CONFIG=$'experimental-features = nix-command flakes\naccept-flake-config = true'
export PATH=/run/current-system/sw/bin:/run/wrappers/bin:$PATH
# no `git` on the installer's system, and nix's fetcher shells out to it for
# flox's git+https input (httpmock): the first attempt died there
exec nix shell github:NixOS/nixpkgs/c5c4a43b0e8056328ec4529f735cabdb8f1942bb#git -c \
  nixos-rebuild switch --refresh --flake github:imkarrer/homelab/<full sha>#arcade-box
EOF
ssh arcade-box 'chmod +x /root/first-switch.sh; systemd-run --unit=arcade-box-first-switch \
  --setenv=HOME=/root --setenv=PATH=/run/current-system/sw/bin:/run/wrappers/bin \
  /run/current-system/sw/bin/bash /root/first-switch.sh'
# then: systemctl is-active arcade-box-first-switch; journalctl -u arcade-box-first-switch
```

Three things the run taught. A `#!/usr/bin/env bash` shebang fails under
`systemd-run` (its PATH has no `env`); the interpreter is spelled
absolutely. The unit ends **failed with status 4** even on success:
`switch-to-configuration` returns 4 when any unit failed to start, and
the two arcade stubs are meant to. And the kernel hostname stays `nixos`
until a reboot (`hostnamectl --static` already says `arcade-box`); the
reboot before the cutover settles it. 12:59 to 13:02 wall clock, almost
all of it substitution.

Proof: `nixos-version --configuration-revision` is the sha; `systemctl
--failed` is empty; `arcade-freeciv`/`arcade-mindustry` are **failed with
the placeholder message** (declared, `environment.enable = false` -- the
designed first-switch state, not a defect); Grafana answers on
`http://192.168.1.218:3000` with an empty TSDB; `ac-host-*` units do not
exist; `ac-host-ci.service` does not exist; `homelab-deploy.path` is
active and idle.

Expected and accepted for the build-up weeks: two Alertmanagers post to
the same Discord webhook, and two unpollers poll the Dream Router at 2 m
each -- still a quarter of the load the 30 s interval put on it before
10 Sep.

---

## 6. Phase 3 -- state and warm-up

Box actions on arcade-box only; ac-box is read from, never written. The
copies run box-to-box over the LAN with the operator's agent forwarded, so
no key lands on either box:

```bash
ssh -A ac-box 'rsync -a --delete -e "ssh -o StrictHostKeyChecking=accept-new" \
  /var/lib/ac-host/ root@192.168.1.218:/var/lib/ac-host/'
```

Ownership maps **by name**, not `--numeric-ids`: the closure has already
created `arcade`, `grafana`, `prometheus`, `unifi-poller` on arcade-box
(phase 2), and their uids differ from ac-box's (`arcade` is 992 there and
dynamic). Verify with `ls -ln` on both sides after each tree.

| What | How | When |
| --- | --- | --- |
| `/var/lib/ac-host` whole (`src`, `content`, `.env` too) | rsync as above | bulk now; delta in phase 4 with the lobbies stopped |
| `/srv/arcade`, `/var/lib/arcade` minus `env/` | rsync | now; the environment is re-pulled, below |
| `/var/lib/grafana`, `/var/lib/prometheus2` | rsync with `grafana`/`prometheus` **stopped on arcade-box** | bulk now; delta in phase 4 with both sides stopped |
| `ac-host-ci_minio-data` | `docker volume create ac-host-ci_minio-data` then rsync `/var/lib/docker/volumes/ac-host-ci_minio-data/_data/` | bulk now; delta in phase 4 |
| Images | `ssh ac-box docker save ac-host-env:latest ac-host-server:latest \| ssh arcade-box docker load` (through WSL, ~4.5 G); the agent image the same way, or rebuilt below | now |
| the agent's `/nix` volume | **not copied**: a live rsync of a Nix store is a db/store mismatch waiting to happen; it re-warms from MinIO and cache.nixos.org | -- |

**arcade's environment**, in the order `environment-pull.nix`'s header
requires: stage generation 2 by hand on arcade-box
(`HOMELAB_STAGE_GENERATION=2 HOMELAB_STAGE_ENV=imkarrer/arcade
scripts/hub-queue-environment.sh arcade <home-arcade sha>` from a homelab
checkout on the box, or the same JSON written to
`/var/lib/homelab/pending-environment-arcade.json`), watch
`arcade-environment-pull.service` clone, pull and warm, then land
`environment.enable = true` for arcade-box and switch again. Both game
servers come up on `.218`; a station can join by address for the test.

**CI, without starting the agent**: `docker compose -f
docker-compose.buildkite.yml --env-file /run/secrets/rendered/ci-env -p
ac-host-ci build agent` once (heavy: flox and the seed packages; this is
the "keep it off race night" build), then `up -d minio minio-init`.
`curl http://127.0.0.1:9000/flox-binary-cache/nix-cache-info` on
arcade-box proves the copied cache is served. The agent stays down until
phase 4: two agents on `queue=self` would split the local steps across two
hosts. Run the sandbox probe here and record it.

**Rehearse the delta.** Time a second rsync pass of each tree; phase 4's
budget is that number, and it should be seconds.

### Status, 26 Sep 2026 (13:06-13:12 CDT)

Done, box-to-box with the operator's agent forwarded, ownership mapped by
name, `nice -n 19 ionice -c3` on ac-box's side:

| What | Measured |
| --- | --- |
| `/var/lib/ac-host` | 12.64 GB, 2,989 files, 154 s at 82 MB/s; **delta pass 1 s** (2 files) |
| `ac-host-env:latest`, `ac-host-server:latest` | `docker save \| docker load` through ac-box, 108 s |
| `/srv/arcade`, `/var/lib/arcade` (minus `env/`, `secrets/`, flox scratch) | 464 MB + 19 MB, 9 s |
| `/var/lib/grafana`, `/var/lib/prometheus2` | 93 MB + 107 MB, arcade-box's services stopped for it and active again after |
| `ac-host-ci_minio-data` | 3.9 GB, 5,913 files, 67 s into a pre-created volume of that name |
| arcade generation 2 | staged by hand as the record ac-box holds; `arcade-environment-pull` pulled, pinned and warmed it in 23 s to run path `f6m1q3pd…`, **the same path ac-box's applied record names**; `environment.enable = true` landed as `abf44ac` (CI build 145) and the switch started both game servers on `.218` |

Then, 13:11-13:20:

| What | Measured |
| --- | --- |
| `ac-host-buildkite-agent:flox` | built by hand from the compose file (`docker compose … build agent`), 4 min 10 s, 6.36 GB; the agent itself stays down (D1) |
| MinIO on the copied volume | **Docker Hub refused** `minio/minio:latest` and `minio/mc:latest` ("pull access denied … repository does not exist"), so both images came from ac-box by `docker save \| docker load`; `up -d --pull never minio minio-init`; `nix-cache-info` served on `127.0.0.1:9000`, bucket 3.6 GiB / 2,355 objects, the `flox-cache` user enabled with readwrite. **The compose file's `image:` lines are no longer pullable on a fresh daemon** -- an ac-host bead, not a blocker here |
| Sandbox probe (`homelab-bfq.11`'s one-liner, inside the built image) | `--security-opt seccomp=unconfined`: "this system does not support the kernel namespaces"; `--privileged`: the sandbox engages and the probe builds. **Same answer as ac-box**, so the compose file's `privileged: true` stands on this host too, and ADR 0012's "a modern chip likely only needs seccomp" is not what this kernel and image do |

**Reboot, 13:20:12.** Back in ~25 s with nobody at it: kernel and static
hostname both `arcade-box`, `booted == current` (the flake closure of
`abf44ac`, the installer generation left behind), zero failed units, every
unit above active again, both game servers listening, the hand-started
MinIO container back on its own (`restart: unless-stopped`), Grafana 200,
generation 2 still pinned. Phase 3 is complete; 5.4 and 6 are the
build-up state the cutover starts from.

---

## 7. Phase 4 -- the cutover

Operator present. `python3 /var/lib/ac-host/src/scripts/drivers_online.py`
on ac-box exits 1 (nobody racing); a post in `#server-status` has gone
out; phase 2's script change is landed and `hub-status` reads both hosts.
One push, two switches, one reboot, one hour.

**4.1 The reservations -- human, UDR UI.** MAC `e8:6a:64:f4:81:94` ->
Fixed IP `192.168.1.50`; MAC `c8:d3:ff:b9:28:0b` -> Fixed IP `<section 9's
address for the Z840>`. Leases do not move until each box renews; nothing
changes yet.

**4.2 The cutover commit -- supervisor, WSL, one push.**

- `hosts/arcade-box`: `host.nix` address `192.168.1.50`;
  `services.ac-host.enable = true` (and `ac-host-dev`); `homelab.ci.enable
  = true` with `ac-host-ci.wantedBy`; the bot, nightly timer and static
  lobbies come with the module.
- `hosts/ac-box`: `host.nix` address = the Z840's new one; `tenants.nix`
  keeps `agent-hub` only; `configuration.nix` drops the ac-host, arcade,
  ci and deploy-of-tenants blocks and gives background the freed shares;
  `flake.nix`'s ac-box list drops `modules/observability`, `modules/ci`,
  `modules/platform/secrets.nix` + `sops-nix`, `ac-host.nixosModules.ac-host`
  and the arcade tenant file. `modules/deploy` stays, idle. Docker goes
  with them (no tenant left declares `needsDocker`), which is ADR 0010's
  llm-box shape minus the rename.
- Gate green locally (`hub-gates.sh homelab`, `nix flake check
  --no-build`), the stamp-stripped drvPath of arcade-box compared before
  and after for the parts that should not have moved, then push.

The Z840's own agent gates the push and stages it; `homelab-deploy` asks
`busyCheck` (still the old inventory, with assetto in it), builds, asks
again, and switches. That switch removes `ac-host-static`, `ac-host-bot`,
`ac-host-nightly`, the arcade units, the eight observability units and
`ac-host-ci` from the closure and stops them all, `docker.service`
included -- **the one time that line in the activation plan is the goal
and not the abort**. Buildkite shows agent `ac-box` disconnect; jobs queue.

If drivers joined in the meantime, the unit defers every 10 minutes; wait,
do not drain by hand.

**4.3 The Z840 takes its new address -- box action, runbook verbatim.**
A reboot is owed anyway (`hub-status`: switched since boot). `ssh ac-box
reboot`; it comes back on the new address with `agent-hub-llm`, `nginx`,
`qdrant` and nothing else. Update `~/.ssh/config`'s `ac-box` `HostName`.

**4.4 The delta -- box action on arcade-box.** The lobbies, bot, Grafana,
Prometheus and MinIO on the Z840 are stopped, so this pass is the final
state: `/var/lib/ac-host` (whitelist, `leaderboard.json`, `races/`,
`series/`, `pending-src`, `pending-deploy.json`, `last-downtime.json`),
`/var/lib/grafana` and `/var/lib/prometheus2` (arcade-box's own stopped for
the copy), `ac-host-ci_minio-data` (arcade-box's minio stopped for it).
Seconds, per phase 3's rehearsal.

**4.5 arcade-box takes `.50` and switches -- box action.**

```bash
ssh arcade-box 'nmcli connection up "$(nmcli -t -f NAME,DEVICE con show --active | grep -v ":lo$\|:docker\|:br-" | head -1 | cut -d: -f1)"'
# reconnect on 192.168.1.50 -- new host key at an old address: ssh-keygen -R 192.168.1.50 first
ssh root@192.168.1.50 'nixos-rebuild switch --refresh --flake github:imkarrer/homelab/<the pushed sha>#arcade-box'
```

Starts, in order: `ac-host-env` (the sops render into `.env`),
`ac-host-static` (three lobbies from the loaded images and the copied
tree), `ac-host-bot`, the arcade units and exports on `.50`,
observability on `.50`, `ac-host-ci` (agent `arcade-box`, `queue=self`,
MinIO on the copied cache).

**4.6 Proof, in this order.**

1. `ss -tlnp`, `docker ps`, `systemctl list-units --state=running` against
   the same captures taken on ac-box before 4.2: the same listeners on
   the same ports at `.50`, nine containers, no failed unit.
2. Grafana at `http://192.168.1.50:3000` shows the copied dashboards and
   the TSDB continues where it stopped.
3. A lobby joined from **outside the LAN** (phone hotspot): the forwards
   still point at `.50` and `.50` is now this box. Drive a lap; the
   leaderboard updates. This is the only test the closure diff cannot do
   (runbook-cutover, gate 3b).
4. `scripts/hub-pipeline.sh agents` shows `arcade-box / connected /
   queue=self`. A trivial homelab push builds on it, `queue-closure`
   stages, and `homelab-deploy` on arcade-box switches within a minute:
   the continuous path proven on the new host. A rebuild of ac-host main
   lands `Image`, `Promote image` and `Queue prod` on arcade-box.
5. That night: the bot's 03:00 countdown queues DOWNTIME, the ops job runs
   on arcade-box's agent and applies `pending-src`; `last-downtime.json`
   carries the date. `hub-status` (host-aware) is CLEAN for arcade-box,
   and `hub-backup` pulled the tenants' state from arcade-box at 04:30.
   Two things that 04:30 run needs, found in review (`homelab-ygc.4`):
   **before 04:30, as user `nixos`**, both hosts' keys accepted into
   `~/.ssh/known_hosts` -- the backup runs `StrictHostKeyChecking=yes`
   keyed by IP, `.50` now presents arcade-box's key and the Z840's new
   address has none, so until then both hosts read unreachable and the run
   dies "no host was backed up". And **after arcade-box's first successful
   snapshot**, remove the four moved directories from
   `/home/nixos/backup/ac-box/var/lib/` (`ac-host`, `arcade`, `grafana`,
   `prometheus2`): the pull only mirrors inside the directories a host
   still declares, so they would sit there frozen at their pre-cutover
   state, re-snapshotted under host `ac-box` every night, and the restore
   runbook's "try the mirror first" would hand back a whitelist missing
   every driver added since.
6. The operator's machine: `hub-ask.sh`, `hub-index.sh`, `hub-search.sh`,
   `vectors-smoke.sh`, `compare.sh` defaults (or `HUB_LLM`/`LLM`/`QDRANT`)
   moved to the Z840's new address; `~/.ssh/config` has `arcade-box` at
   `.50` and `ac-box` at the new address; `known_hosts` cleaned.

**Rollback ladder.**

- Before 4.2's switch has happened: revert the commit; nothing moved.
- After the Z840 switched, before arcade-box did: `nixos-rebuild switch
  --rollback` on the Z840, swap the two reservations back, renew. The
  Z840's state is intact (phase 3 and 4.4 only ever read it). Minutes.
- After arcade-box is live: the Z840's copy freezes at 4.4. Rolling back
  after a race has been run on arcade-box loses that race; from the first
  lap, fix forward.

---

## 8. Phase 5 -- what this leaves open (each a bead)

- **ADR 0010 half two**: strip and rename the Z840 to `llm-box` --
  `hosts/llm-box`, hostname, `secrets/` file name, ssh config, the
  tracker, every tree's docs, and the hand-pull procedure for
  `agent-hub`'s environment now that no agent stages it there.
- **Cross-host scrape**: llm-box's node exporter and `llama-server`'s
  `/metrics` into arcade-box's Prometheus (ADR 0010, "scraped over the
  LAN"). `metricsEndpoint.address` only admits loopback or this host's own
  addresses; a peer-host fact is a schema addition.
- ADR 0010's status and hardware row; `docs/current-state.md` and
  `docs/architecture.md` Part III for two hosts; `README.md`'s first line.
- `homelab-bqo.42` gets its answer: both reservations, both MACs, which
  Z840 port is live, written down.
- `ci-box` (ADR 0012, `homelab-bfq`) proceeds unchanged: it takes the
  `queue: ci` gate steps off arcade-box's agent when the fourth machine
  exists; arcade-box keeps its own agent for the local steps either way.

---

## 9. Facts to fill in (phase 0 and 1)

| Fact | Value | Source |
| --- | --- | --- |
| CPU model, cores, threads | i7-8700T, 6 c / 12 t, `threadsPerCore = 2` | `lscpu`, 26 Sep 2026 |
| Memory (GiB, `/proc/meminfo`) | 31 (`memoryGiB = 31`) | 26 Sep 2026 |
| Disk, layout, filesystem | `nvme0n1` 953.9 G; vfat `/boot` 512 M + ext4 `/`; no swap | `lsblk`, 26 Sep 2026 |
| LAN NIC name | `eno2` (`wlo1` unused) | `ip -br link`, 26 Sep 2026 |
| `system.stateVersion` | `"26.05"` | `/etc/nixos/configuration.nix`, 26 Sep 2026 |
| Nix-sandbox answer under Docker | | the probe, phase 3 |
| The Z840's post-cutover address | | the UDR, phase 0.2 |
| Sandbox probe / agent image build time | | phase 3 |
