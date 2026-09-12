# Decommission Runbook: the four leftovers on ac-box

This runbook retires the four items `docs/current-state.md` §2 classifies as
**Decommission**, plus the reboot §5 records as owed. Unlike the cutover, this
is not one atomic operation — it is four unrelated items with four different
delivery mechanisms, and the most valuable thing this document does is say
which is which.

Every fact below was re-verified read-only over `ssh ac-box` on **9 Sep 2026**.
Nothing on ac-box was modified to produce it. Where a step's justification
rests on a measurement, the measurement and the command that produced it are
in [Appendix A](#appendix-a--what-was-verified-9-sep-2026), so a reader can
re-run it rather than trust it.

---

## Governing Constraint: two kinds of change, and telling them apart

`AGENTS.md` and `README.md`'s working agreements state the rule in one line:
**ac-box changes by landing in git and letting the pipeline deploy.** A change
made by hand on the box is a debugging step, never a resting state.

So before any step here, answer one question: *does the thing being removed
exist in a repo?*

| | **Git change** | **Box action** |
|---|---|---|
| The thing lives in | a tracked file in `homelab` (or a tenant flake) | the box's own filesystem, in no repo |
| You change it by | editing, gating, committing, and switching | typing a command on ac-box as a human |
| It survives a switch because | the closure declares it | nothing — a switch cannot see it either way |
| Undo is | `git revert` + switch, or `nixos-rebuild --rollback` | restoring the file from a copy you took first |
| Requires a window | only if the switch bounces a unit | only if the command bounces a unit |

The failure mode this table exists to prevent is doing the *wrong one*: hand-
disabling a unit that the closure declares. `systemctl disable wpa_supplicant`
would work for exactly as long as it takes the next `nixos-rebuild switch` to
re-assert the closure's `[Install] WantedBy=multi-user.target`, and in the
meantime `hub-status.sh` cannot see it, because it compares git to git.

Classified for the four items here:

| # | Item | Kind | Why |
|---|---|---|---|
| 1 | `/etc/nixos/configuration.nix` | **Box action** | It is in no repo. `grep -rl /etc/nixos /run/current-system/etc/` returns nothing; the closure has no opinion about this path at all. There is no git change that could remove it. |
| 2 | `wpa_supplicant.service` | **Git change** | `modules/platform/network.nix` sets `networking.networkmanager.enable = true`; nixpkgs' NetworkManager module sets `networking.wireless.enable = true` from that, and *that* is what emits the unit. The unit is in the closure. Only a closure change removes it. |
| 3 | `ac-host-ci-minio-init-1` | **Neither — no action** | See item 3. It is not garbage, and removing it by hand accomplishes nothing that survives. |
| 4 | The owed reboot | **Box action** | A reboot is not a config change. |

Item 1 is a box action *by necessity*, not by convenience — that is the whole
justification, and it is the only one of the four that gets one.

---

## Standing Hazard: `github:` refs are cached for an hour

`nixos-rebuild switch --flake github:imkarrer/homelab#ac-box` does **not**
necessarily build what is on `main`. Nix caches the resolution of a bare
`github:` ref for `tarball-ttl` — 3600 seconds by default, and that is what
ac-box has. Found 12 Sep 2026: a switch at 12:00 cached `c97cbbe`; a switch at
12:51, after three more commits had been pushed, resolved to the *cached*
`c97cbbe`, built the identical closure, and applied a no-op — while reporting
success and refreshing the generation's timestamp. The heuristic check in
`hub-status.sh` read that fresh timestamp as "consistent with current";
only `HUB_STATUS_EXACT=1` saw that the box and the tree were different closures.

Every switch command in this document carries `--refresh` for that reason.
Pinning to a full sha (`github:imkarrer/homelab/<40-hex>#ac-box`) is immune
without it — which is why ADR 0006's deploy unit stages a rev, never "main".
After any switch, run `HUB_STATUS_EXACT=1 bash scripts/hub-status.sh`; the
cheap check cannot tell you whether the switch did anything.

## Standing Hazard: the closure backlog

**Do not write "then switch" as if it were a small step.** As of 9 Sep 2026
`scripts/hub-status.sh` reports:

```
DRIFT - 20 commit(s) committed AFTER that switch, so none of them can be in it
```

Run it yourself before doing anything here; the number moves as work lands:

```bash
bash scripts/hub-status.sh; echo "EXIT=$?"
```

`hub/repos.psv` marks homelab `deploy=none`. Nothing pushes the closure. So the
*next* `nixos-rebuild switch --flake` on this box — whoever runs it, for
whatever reason — applies **all twenty commits at once**, not the one you
happen to care about. Among them:

- `4257aea` / `hosts/ac-box/configuration.nix` → `homelab.ci.enable = true`,
  which starts `ac-host-ci.service`, which runs `docker compose up -d --build`
  against the same project name as the **currently hand-started** CI stack.
  That is a port and network collision, not a takeover — `modules/ci/default.nix`
  **HAZARD 1** documents it and gives the six-step order that avoids it.
- `45f67ab` / `0de8c09` → start `agent-hub-llm.service` and rebalance every
  tier share (`background` to `CPUWeight 700`, `MemoryMax` ~163 GiB).
- `3fef4fe` → re-fences `background`/`batch` by physical core and closes the
  stale `tcp/8100` firewall rule.
- `45db9dc` → adds `samba-smbd`, `samba-winbindd` and `rsync.service` to
  arcade's `units`, which **bounces all three** (`Slice=` applies at unit
  start). AGENTS.md grants standing authority for an arcade bounce; this is
  the accepted cost, not a surprise.

Consequences for this runbook:

- **Item 2 (the git change) cannot be applied on its own.** Committing it does
  not reach the box, and the switch that would carry it carries nineteen other
  commits with it. Item 2 therefore lands in git now and *deploys* as a rider
  on the CI-adoption switch of `docs/current-state.md` §5 item 5. Say so out
  loud rather than implying `wpa_supplicant` goes away this afternoon.
- **Items 1, 3 and 4 do not require a switch at all**, which is precisely why
  they can be done first and cheaply.

---

## Preconditions

Check all five before starting. Any failure aborts.

```bash
# P1 — you are on the box, not in a Buildkite job. HAZARD 2: a switch or a
#      container bounce must never be run BY the agent it bounces.
ssh ac-box 'echo $BUILDKITE_JOB_ID'          # must print an empty line

# P2 — nothing is failed, and the box is where you think it is.
ssh ac-box 'systemctl --failed --no-legend; readlink -f /run/current-system'

# P3 — no races are live, or you are inside the 03:00 window.
#      assetto is quiet.drainable = false. AGENTS.md: never bounce it outside
#      a window. Items 1-3 do not touch it; item 4 (reboot) destroys it.
ssh ac-box 'docker ps --format "{{.Names}}\t{{.Status}}" | grep ac-static'

# P4 — the three-way state, and the live backlog number.
bash scripts/hub-status.sh; echo "EXIT=$?"

# P5 — the rollback GC root from the cutover is still real.
ssh ac-box 'nix-store --gc --print-roots | grep pre-homelab'
```

P5 matters because item 4 is a reboot. `boot.loader.systemd-boot.configurationLimit = 5`
and `/boot/loader/entries/` currently holds generations 25–29; the pinned root
is the belt to that braces.

---

## Ordering

```
  Gate 0  ── hardware-configuration.nix equality  (blocks item 1 only)
     │
     ├─ Item 1  box action   /etc/nixos            ── independent, do first
     ├─ Item 3  no action    minio-init            ── inspect, record, move on
     └─ Item 2  git change   wpa_supplicant        ── land now, deploys later
                                   │
                                   ▼
                        modules/ci HAZARD 1 sequence
                        + the 20-commit switch          ← not in this runbook
                                   │
                                   ▼
                        Item 4  box action  reboot      ── last, and only here
```

Three ordering claims, each with a reason:

1. **Item 1 goes first and alone.** It has zero coupling to the closure, so it
   cannot interact with anything else, and it removes the one item on the box
   that can silently undo the whole refactor. Doing it first means every later
   step is taken on a box where that hazard is already gone.
2. **Item 2's git change goes in before the CI-adoption switch, not after.**
   If it lands after, it needs a *second* switch of its own to deploy — and a
   switch is the expensive operation here, not the commit. Riding along costs
   nothing: it removes one unit and one user and touches `NetworkManager.service`
   not at all (proven in Appendix A).
3. **Item 4 goes last.** A reboot re-runs `docker`'s `unless-stopped` restart
   policies. Between HAZARD 1 step 2 (`docker compose down`, which *removes*
   the CI containers) and the switch that creates `ac-host-ci.service`, there
   is a window in which **nothing brings the Buildkite agent back on boot** —
   the containers are gone and the unit does not exist yet. Rebooting inside
   that window leaves the box with no CI agent and no automatic way to get one.
   Reboot only after `systemctl status ac-host-ci.service` reports active.

---

## Item 1 — `/etc/nixos/configuration.nix`

**Kind: box action.** **Blast radius if done right: zero.** **Blast radius if
the file is ever *used*: the entire refactor.**

### What it is

A stock `nixos-generate-config` host config, last written 31 Aug 2026 01:27,
4792 bytes, in no git repository (`git -C /etc/nixos rev-parse` → *not a git
repository*). It imports `./hardware-configuration.nix` and declares:
systemd-boot, NetworkManager, `services.openssh.enable`, one user
(`nixosuser`), the nvidia stack, and `system.stateVersion = "26.05"`.

That list is notable for what it does **not** contain: no
`virtualisation.docker`, no tenant contract, no slices, no port registry, no
firewall rules, no observability, no samba, no rsync, no `ac` user, no fail2ban.
And it sets `services.openssh.settings.PermitRootLogin = "yes"` where
`modules/platform/ssh.nix` sets `"prohibit-password"`.

A switch to it would therefore **stop `docker.service`** — which is the exact
failure `runbook-cutover.md` gate 2 exists to prevent, taking the three live
race containers, the four `ac-host` sidecars, the Discord bot and the Buildkite
agent with it — and simultaneously loosen sshd. This is the other half of the
trap `ac-host`'s `flake.nix` closed by deleting its own
`nixosConfigurations.ac-box`; read that comment, it names the same failure.

### Correction to `docs/current-state.md` §2

current-state says a bare `nixos-rebuild switch` "builds *that* — no platform
layer, no contract, no slices — and exits 0." **On this box today, it does
not.** It fails at evaluation, before reading the file:

```
$ ssh ac-box 'nix-instantiate --find-file nixos-config'
error: file 'nixos-config' was not found in the Nix search path
```

The mechanism is worth understanding, because it is what the remedy has to
respect. `nixos-rebuild` here is `nixos-rebuild-ng-26.05`. With no `--flake`
and no `/etc/nixos/flake.nix`, `Flake.from_arg` returns `None` and
`BuildAttr.from_arg` falls all the way through (`<nixos-system>` unset,
`/etc/nixos/system.nix` absent) to `<nixpkgs/nixos>`. That file's first line is

```nix
configuration ? import ./lib/from-env.nix "NIXOS_CONFIG" <nixos-config>,
```

`NIXOS_CONFIG` is unset, so the default `<nixos-config>` is forced — and this
box's `NIX_PATH` is `nixpkgs=flake:nixpkgs:/nix/var/nix/profiles/per-user/root/channels`,
which carries **no `nixos-config` entry**. Eval error, no build, no switch.

**This does not make the file safe. It makes it safe by accident.** The
protection is a nixpkgs default for `nix.nixPath` that nothing in this repo
asserts, tests, or even mentions. Four ways it comes back:

- `sudo nixos-rebuild switch -I nixos-config=/etc/nixos/configuration.nix`
- `NIXOS_CONFIG=/etc/nixos/configuration.nix nixos-rebuild switch`
- anyone setting `nix.nixPath` or re-enabling channel-style paths in
  `modules/platform/nix.nix` — a one-line change with no obvious connection
  to this hazard
- a nixpkgs bump that restores the historical default

And the fifth, which needs no re-arming at all: a human opens `/etc/nixos/`
to answer "what does this box run?", finds a plausible, dated, self-consistent
NixOS config, and believes it.

### Remedy: replace with a `throw`, keep the hardware file

Do **not** delete `configuration.nix`. Replace its contents with a `throw`.

The reasoning, since "just delete it" is the obvious answer and it is wrong:

- **A throw is the shape this repo already chose.** `hosts/ac-box/configuration.nix`
  was changed in `37e6927` from a silent `.example` fallback to a `throw` that
  names the recovery command, for exactly this reason: *a successful evaluation
  of the wrong thing is worse than a failure.* The same argument applies here
  verbatim, and applying it twice in the same tree is consistency, not
  ceremony.
- **Deleting it re-opens the trap; a throw closes it permanently.**
  `nixos-generate-config` writes `hardware-configuration.nix` unconditionally
  but writes `configuration.nix` **only if that path does not already exist**.
  An empty `/etc/nixos` is one `nixos-generate-config` away from a fresh stock
  config — silently, with no error, by a human doing something reasonable. A
  file that throws is a tombstone `nixos-generate-config` will decline to
  overwrite. Deletion is the option that can be undone by accident.
- **It is the only thing that talks to the fifth reader** — the human who opens
  the directory to find out what runs here. A missing file tells them nothing.
  A throw tells them the flake command and where the real config lives.
- **It costs nothing.** Nothing imports it, so the throw is unreachable by
  every path except the deliberate `-I` / `NIXOS_CONFIG` invocations, which are
  precisely the ones that need to fail loudly.

**Keep `/etc/nixos/hardware-configuration.nix`, untouched.** It is not a trap:
it declares no services, imports nothing, and cannot revert anything on its
own. It is the clean machine-generated record, and — see the trap in Gate 0
below — it is *better* than what regenerating today would produce. Deleting it
also buys nothing, since `nixos-generate-config` overwrites that path
regardless.

### Gate 0 (precondition, and a step in its own right)

`hosts/ac-box/hardware-configuration.nix` has been tracked in git since
`daac96f` and nobody had verified it against the box since. Verify it **before**
touching anything in `/etc/nixos`, even though the chosen remedy does not
destroy it — the moment to find a hardware mismatch is before, not after.

Compare by **parsed AST**, not by bytes. The git copy is `nixfmt-rfc-style`-
formatted and carries an eleven-line header; the box copy is
`nixos-generate-config` output. They will never be byte-identical and a byte
diff proves nothing. `nix-instantiate --parse` normalises formatting and drops
comments, so an identical AST is an exact statement about meaning:

```bash
mkdir -p ~/hw-check && cd ~/hw-check
ssh ac-box 'cat /etc/nixos/hardware-configuration.nix'                          > etc.nix
ssh ac-box 'cat /var/lib/ac-host/src/hosts/ac-box/hardware-configuration.nix'   > tree.nix
cp /path/to/homelab/hosts/ac-box/hardware-configuration.nix                       git.nix

for f in etc tree git; do
  printf '%-6s %s\n' "$f" "$(nix-instantiate --parse $f.nix | sha256sum | cut -c1-16)"
done
```

**Acceptance criterion:** all three hashes identical.

Result on 9 Sep 2026 — all three `0f0e8b723682cbe8`:

| Copy | Bytes | Parsed-AST sha256 (16) |
|---|---|---|
| `ac-box:/etc/nixos/hardware-configuration.nix` | 989 | `0f0e8b723682cbe8` |
| `ac-box:/var/lib/ac-host/src/hosts/ac-box/…` | 902 | `0f0e8b723682cbe8` |
| `homelab` HEAD `hosts/ac-box/hardware-configuration.nix` | 1459 | `0f0e8b723682cbe8` |

Same root UUID `5ae5d017-8b98-4e5b-b8c5-f5658120ac89` (ext4), same ESP
`F5F3-902E` (vfat, `fmask=0022 dmask=0022`), same nine
`boot.initrd.availableKernelModules` in the same order, same empty
`swapDevices`, same `hostPlatform`, same microcode line. **The tracked copy
mirrors the box. Gate 0 passes; item 1 may proceed.**

Also confirmed: the AST at `5fc6c90` — the commit that built the running
closure — is the same `0f0e8b723682cbe8`. The kernel and initrd currently
booted were built from this exact hardware description, so there is no
"tracked file is right but the running system was built from something else"
gap hiding underneath.

> **If the hashes ever differ, stop.** Do not remove or overwrite anything.
> A hardware mismatch means the tracked file would produce boot entries for
> the wrong disks, and that outranks every cleanup in this document. Report it
> and reconcile the tracked copy first.

> **Trap: do not "verify" by regenerating.**
> `nixos-generate-config --show-hardware-config` on this box **today** emits a
> *different and worse* file than any of the three above, because it reads the
> live machine and the live machine is running Docker:
>
> - it adds **nine** `fileSystems."/var/lib/docker/rootfs/overlayfs/<hash>"`
>   entries — one per running container, declaring ephemeral container
>   overlays as system filesystems;
> - it **drops** `usbhid`, `usb_storage` and `sd_mod` from
>   `boot.initrd.availableKernelModules`, because nothing is currently
>   attached that needs them.
>
> Committing that output would shrink the initrd's device coverage and bake
> today's container IDs into the boot config. The three copies above are the
> good ones. Regeneration is not a verification step; it is a regression.

### Before

```bash
ssh ac-box 'ls -la /etc/nixos/; stat -c "%n %s %y" /etc/nixos/*'
ssh ac-box 'git -C /etc/nixos rev-parse --show-toplevel'      # expect: not a git repository
ssh ac-box 'grep -rl "/etc/nixos" /run/current-system/etc/'   # expect: no output
ssh ac-box 'ls -la /run/current-system/configuration.nix'     # expect: No such file
ssh ac-box 'nix-instantiate --find-file nixos-config'         # expect: not found in Nix search path
```

The third and fourth prove zero coupling: nothing in the running closure
references the path, and `system.copySystemConfiguration` is off, so there is
no `/run/current-system/configuration.nix` pointing back at it either.

Take the backup — cheap, and it is the rollback:

```bash
ssh ac-box 'cat /etc/nixos/configuration.nix' > ~/etc-nixos-configuration.nix.$(date +%F).bak
wc -c ~/etc-nixos-configuration.nix.*.bak     # expect 4792
```

### The change (on ac-box, as root, from a plain SSH session)

```bash
ssh ac-box
cp -a /etc/nixos/configuration.nix /etc/nixos/configuration.nix.retired-2026-09-09
cat > /etc/nixos/configuration.nix <<'EOF'
# RETIRED 9 Sep 2026. This is not ac-box's configuration and must not become it.
#
# ac-box's system closure is built by github:imkarrer/homelab, which owns the
# platform layer (modules/platform), the tenant contract (modules/tenant) and
# this host's composition (hosts/ac-box/). Rebuild with:
#
#   sudo nixos-rebuild switch --refresh --flake github:imkarrer/homelab#ac-box
#
# What used to be here was a stock, pre-refactor host config dated 31 Aug 2026.
# Building it produces a system with no Docker daemon, no tenant contract, no
# slices, no port registry, no observability and PermitRootLogin = "yes" -- i.e.
# it stops docker.service and destroys every running container, including the
# three live Assetto race servers and the Buildkite agent. It is preserved
# beside this file as configuration.nix.retired-2026-09-09 for reference only.
#
# This file throws rather than being deleted, deliberately: `nixos-generate-config`
# writes configuration.nix only when the path is absent, so an empty /etc/nixos
# is one accidental invocation away from recreating the trap. A file that throws
# cannot be recreated by accident. Same reasoning as hosts/ac-box/configuration.nix's
# hardware-file throw (commit 37e6927).
#
# See docs/runbook-decommission.md item 1 and docs/current-state.md §2.
throw ''
  /etc/nixos/configuration.nix is retired and must not be built.

  ac-box's system closure comes from the homelab flake:

    sudo nixos-rebuild switch --refresh --flake github:imkarrer/homelab#ac-box

  If you reached this by running `nixos-rebuild` without --flake, or with
  -I nixos-config= / NIXOS_CONFIG=, that is the bug. Use the command above.
''
EOF
chmod 644 /etc/nixos/configuration.nix
```

Note `configuration.nix.retired-2026-09-09` sits in the same directory. That is
harmless: `nixos-rebuild` never looks for it under any name, and it keeps the
old content readable next to the tombstone that explains it.

`hardware-configuration.nix` is **not** touched by any command above.

### After

```bash
ssh ac-box 'ls -la /etc/nixos/'
ssh ac-box 'head -3 /etc/nixos/configuration.nix'

# The throw fires when the file is actually reached:
ssh ac-box 'nix-instantiate --eval /etc/nixos/configuration.nix 2>&1 | head -12'
#   expect: error: ... /etc/nixos/configuration.nix is retired and must not be built.
#           ... nixos-rebuild switch --refresh --flake github:imkarrer/homelab#ac-box

# The hardware file is untouched and still matches git.
# Note: nix-instantiate --parse needs a real file -- it cannot read a pipe
# ("path '/proc/<pid>/fd/pipe:[…]' does not exist"), so land it on disk first.
ssh ac-box 'cat /etc/nixos/hardware-configuration.nix' > ~/hw-check/etc-after.nix
nix-instantiate --parse ~/hw-check/etc-after.nix | sha256sum | cut -c1-16
#   expect: 0f0e8b723682cbe8

# The running system did not move:
ssh ac-box 'readlink -f /run/current-system; systemctl --failed --no-legend'
ssh ac-box 'docker ps --format "{{.Names}}\t{{.Status}}"'
```

**Acceptance criterion:** `/run/current-system` unchanged, no failed units, the
same nine running containers with uptimes that predate the edit. Nothing here
activates anything, so anything else is a coincidence worth investigating
before continuing.

### Rollback

```bash
ssh ac-box 'cp -a /etc/nixos/configuration.nix.retired-2026-09-09 /etc/nixos/configuration.nix'
```

or, from the copy taken off the box:

```bash
scp ~/etc-nixos-configuration.nix.2026-09-09.bak ac-box:/etc/nixos/configuration.nix
```

Restoring it restores a hazard, not a capability. There is no scenario in which
the old contents are needed to run this box; the only reason to roll back is if
the throw somehow breaks a tool nobody anticipated, and then the right move is
to roll back *and say which tool*, because that tool is reading a file it has
no business reading.

---

## Item 2 — `wpa_supplicant.service`

**Kind: git change.** **Deploys as a rider on the CI-adoption switch, not on
its own.**

### What it is, re-verified

```
$ ssh ac-box 'ls /sys/class/net'
br-7872c3951a7d  br-b1f9e00d8c5c  docker0  eno1  enp8s0  lo
veth7e71957  veth7f03b54  veth98be840
```

Two physical NICs, both wired; three docker bridges; three veths; loopback.
**No wireless interface.** And:

```
$ ssh ac-box 'systemctl show wpa_supplicant.service -p ActiveState -p UnitFileState -p FragmentPath'
ActiveState=active
UnitFileState=enabled
FragmentPath=/etc/systemd/system/wpa_supplicant.service
$ ssh ac-box 'ps -o pid,args -C wpa_supplicant'
1539 wpa_supplicant -s -u -Dnl80211,wext -c /etc/wpa_supplicant/imperative.conf
```

Running since 5 Sep, `NRestarts=0`, driving nothing.

### Where it comes from

`modules/platform/network.nix` sets `networking.networkmanager.enable = true`.
nixpkgs' `nixos/modules/services/networking/networkmanager.nix` then does, in
its own `config` block:

```nix
(mkIf (!delegateWireless && !enableIwd) {
  # Enable wpa_supplicant but fully control it over DBus
  wireless.enable = true;
  wireless.autoDetectInterfaces = false;
  wireless.dbusControlled = true;
})
```

`delegateWireless` is `networking.wireless.networks != {} && cfg.unmanaged != []`
— both empty here, so false. `enableIwd` is `wifi.backend == "iwd"` — the
default is `"wpa_supplicant"`, so false. Both false, so
`networking.wireless.enable` becomes `true`, and
`services/networking/wpa_supplicant.nix`'s `config = mkIf cfg.enable {…}`
emits the unit with `[Install] WantedBy=multi-user.target`.

**This is why it must not be fixed with `systemctl disable`.** The `[Install]`
section is in the closure. The next `nixos-rebuild switch` re-asserts it, the
unit comes back, and `hub-status.sh` — which compares git to git — cannot see
that it ever left. `AGENTS.md` forbids a hand-edit as a resting state for
exactly this reason.

### The change (describe, do not apply — this is not this runbook's file)

In `modules/platform/network.nix`, add one option beside the existing
NetworkManager line:

```nix
  networking.networkmanager.enable = true;

  # NetworkManager sets networking.wireless.enable = true unconditionally when
  # its backend is wpa_supplicant and no wireless config is delegated (nixpkgs
  # networkmanager.nix: `mkIf (!delegateWireless && !enableIwd)`), which emits
  # wpa_supplicant.service. ac-box has no wireless interface -- /sys/class/net
  # is eno1, enp8s0, docker bridges and veths -- so that unit has driven
  # nothing since the machine was built.
  #
  # mkForce, not a bare false: nixpkgs sets it at normal priority inside its
  # own config block, so `networking.wireless.enable = false` here is a tie and
  # therefore an evaluation error ("conflicting definition values"), not a
  # merge. Verified both ways -- see docs/runbook-decommission.md item 2.
  #
  # NetworkManager itself is unaffected: it talks to wpa_supplicant over D-Bus
  # on demand and carries no systemd dependency on the unit.
  networking.wireless.enable = lib.mkForce false;
```

This needs `lib` in the module's argument list — `network.nix` currently takes
`{ config, ... }`, so it becomes `{ config, lib, ... }`.

### Before (proof, runnable in WSL — no box access needed)

The blast radius of this change is provable locally, and it was:

Write the probe to a file — `--expr` here needs both `${…}` interpolation and
embedded quotes, and shell-quoting it is how you get a syntax error instead of
an answer:

```bash
cat > /tmp/wpa-probe.nix <<'EOF'
let
  f = builtins.getFlake "path:/home/nixos/src/homelab";
  base = f.nixosConfigurations.ac-box;
  has = c: if c.config.systemd.units ? "wpa_supplicant.service" then "PRESENT" else "ABSENT";
  forced = base.extendModules { modules = [ ({ lib, ... }: { networking.wireless.enable = lib.mkForce false; }) ]; };
  plain  = base.extendModules { modules = [ { networking.wireless.enable = false; } ]; };
  t = builtins.tryEval (has plain);
in
  "as-is: " + has base
  + "\nmkForce false: " + has forced
  + "\nplain false: " + (if t.success then t.value else "EVAL ERROR (conflicting definition)")
  + "\n"
EOF
nix eval --impure --raw --file /tmp/wpa-probe.nix
```

(If your shell's Nix has flakes off by default, prefix
`nix --extra-experimental-features 'nix-command flakes'`. The box has both
enabled via `modules/platform/nix.nix`; a WSL tree may not.)

Result, 9 Sep 2026:

```
as-is: PRESENT
mkForce false: ABSENT
plain false: EVAL ERROR (conflicting definition)
```

And the full delta between the two composed configurations:

```
removed units: wpa_supplicant.service
added units:   (none)
removed users: wpa_supplicant
NetworkManager.service unchanged: yes
```

Exactly one unit and its service user leave the closure. `NetworkManager.service`'s
unit text is byte-identical either way, and it declares no `Wants=`/`After=`/
`Requires=` on `wpa_supplicant` (verified live on the box). Nothing else moves.

Capture the box-side baseline before the switch that carries this:

```bash
ssh ac-box 'systemctl is-active wpa_supplicant.service; systemctl is-enabled wpa_supplicant.service'
ssh ac-box 'nmcli -t -f DEVICE,TYPE,STATE device status'
ssh ac-box 'ip -br addr show eno1 enp8s0'
```

### Landing it

Use the `homelab-land` skill / `scripts/hub-gates.sh`. Do **not** push from an
agent: `hub/repos.psv` governs that, and this is a platform-layer change.

```bash
bash scripts/hub-gates.sh homelab
```

Commit and push. **The box does not change yet** — homelab is `deploy=none`.

### After (post-switch — the CI-adoption switch, not a switch of its own)

```bash
ssh ac-box 'systemctl status wpa_supplicant.service'      # expect: Unit ... could not be found
ssh ac-box 'ls /etc/systemd/system/wpa_supplicant.service' # expect: No such file
ssh ac-box 'nmcli -t -f DEVICE,TYPE,STATE device status'   # expect: identical to the before capture
ssh ac-box 'ip -br addr show eno1 enp8s0'                  # expect: identical addresses
ssh ac-box 'ping -c2 1.1.1.1 >/dev/null && echo routing-ok'
ssh ac-box 'systemctl --failed --no-legend'                # expect: empty
```

**Acceptance criterion:** the unit is gone, both NICs keep the same addresses
and states, routing works, nothing failed. NetworkManager must still be
`active (running)`.

Expect `wpa_supplicant.service` to appear in the switch's `would stop` /
`stopping` list. That is the change working. It is not on any tenant's `units`
list and belongs to no tenant, so nothing in the drain contract applies to it.

### Rollback

Git, not the box:

```bash
git revert <sha>          # then the next switch restores the unit
```

If it must come back *immediately*, before a switch is possible, that is a
debugging step and must be landed the same session per `AGENTS.md`:

```bash
ssh ac-box 'systemctl start wpa_supplicant.service'   # only if the unit still exists
```

Once the closure has dropped the unit it cannot be started on the box at all,
which is the correct property: the only way back is through git.

---

## Item 3 — `ac-host-ci-minio-init-1`

**Kind: no action.** **Do not `docker rm` it.**

### Re-verified

```
$ ssh ac-box 'docker ps -a --format "{{.Names}}\t{{.State}}\t{{.Status}}"'
ac-host-ci-minio-init-1   exited   Exited (0) 10 hours ago
```

Exit code **0**. Restart policy `no`. It is the `minio-init` service of the
`ac-host-ci` compose project: an `minio/mc` one-shot that provisions the cache
bucket and the dedicated S3 user, then exits.

### Correction to `docs/current-state.md` §2

current-state says it "disappears when the CI stack is adopted under systemd."
**It will not.** Read the compose file:

```yaml
  minio-init:
    restart: "no"
    depends_on:
      minio: { condition: service_started }
  agent:
    depends_on:
      minio-init: { condition: service_completed_successfully }
```

`agent` depends on `minio-init` having **completed successfully**, and compose
evaluates that condition by inspecting the exited container. The container is
therefore not litter — it is the recorded evidence that the dependency was
satisfied, and compose needs it to stay. `modules/ci/default.nix`'s
`ExecStart` is `docker-compose … up -d --build` against the same project name,
so after adoption the stack is composed exactly as it is today and
`ac-host-ci-minio-init-1` will still be sitting there, exited 0.

The only thing that removes it is `docker compose down` — which is HAZARD 1
step 2, and the next `up` recreates it.

### The right procedure is elsewhere; do not duplicate it

`modules/ci/default.nix`'s **HAZARD 1** owns the adoption sequence, in six
numbered steps: confirm the agent is idle → `down` **without `-v`** → verify
the three named volumes (`ac-host-ci_buildkite-nix`,
`ac-host-ci_buildkite-builds`, `ac-host-ci_minio-data`) survive → verify
127.0.0.1:9000/9001 are free → *then* switch → verify the same containers
reattach to the same volumes. It also owns **HAZARD 2**: none of it may run
from a Buildkite step on the agent it bounces.

That sequence is not restated here and must not be forked. This runbook's only
contribution to item 3 is: **it is not a decommission item, and it needs no
step of its own.**

### Before / After / Rollback

```bash
# Before: confirm it exited cleanly rather than failing.
ssh ac-box 'docker inspect -f "{{.State.Status}} exit={{.State.ExitCode}} restart={{.HostConfig.RestartPolicy.Name}}" ac-host-ci-minio-init-1'
#   expect: exited exit=0 restart=no
ssh ac-box 'docker logs --tail 20 ac-host-ci-minio-init-1'

# Change: none.

# After the HAZARD 1 adoption (not part of this runbook):
ssh ac-box 'systemctl status ac-host-ci.service'
ssh ac-box 'docker ps -a --format "{{.Names}}\t{{.Status}}" | grep ac-host-ci'
#   expect ac-host-ci-minio-init-1 present and Exited (0). That is correct.
```

Rollback: not applicable — nothing is changed.

> **A non-zero exit code here is a different problem.** If `ExitCode` is ever
> anything but 0, the cache bucket or the S3 user was never provisioned, the
> `agent` service's `service_completed_successfully` condition cannot be met,
> and adoption will hang rather than succeed. Check that *before* HAZARD 1
> step 1, not after.

---

## Item 4 — the owed reboot

**Kind: box action.** **Go last.** **Window required — this destroys live
races.**

### Re-verified, and narrower than recorded

```
$ ssh ac-box 'readlink -f /run/booted-system; readlink -f /run/current-system'
/nix/store/9ick7piz7mr3li3z7wlwaig66nam2mgc-nixos-system-ac-box-26.05.20260829.c5c4a43
/nix/store/2a6qm0bvk5mhrphf9zakgwhwhwbbci9a-nixos-system-ac-box-26.05.20260829.c5c4a43
```

Different, as `hub-status.sh` reports. But going one level deeper changes the
picture:

| | booted | current |
|---|---|---|
| `kernel` | `ryhz70a…-linux-6.18.48/bzImage` | **same** |
| `initrd` | `2yrb847…-initrd-linux-6.18.48/initrd` | **same** |
| `kernel-modules` | `flywlb9…-linux-6.18.48-modules` | **same** |
| `kernel-params` | `root=fstab loglevel=4 lsm=landlock,yama,bpf` | **same** |
| `init` | `9ick7piz…/init` | `2a6qm0b…/init` |
| `sw` (system-path) | `vwj8wdk…-system-path` | `6spp63d…-system-path` |

`nix store diff-closures /run/booted-system /run/current-system` shows the
difference is entirely userspace: samba, cifs-utils, freeciv, openjdk, the
four tier slices, `etc-homelab-tenants.json`, the arcade and rsync units —
generation 28 → 29.

**So no kernel change is pending.** `docs/current-state.md` says "the kernel,
initrd and modules are still the booted ones", which is true, but the useful
addition is that they are also *the same ones* — there is nothing kernel-side
waiting to be applied. The reboot is owed as bookkeeping, not as a correctness
fix for the current closure.

### So why reboot at all

Three reasons, and only the third is urgent:

1. **It restores the invariant.** While `booted != current`, a future kernel or
   boot-parameter change will look applied and not be. That is a trap for the
   *next* operator, and it is exactly what `hub-status.sh` now reports.
2. **The 20-commit switch may make it matter.** That switch does not currently
   bump nixpkgs (`flake.nix` pins the exact revision ac-box runs, deliberately),
   so it should not move the kernel — but confirm with `diff-closures` rather
   than assuming, and if the kernel *does* move, the reboot stops being
   optional.
3. **It is the only honest test that the CI stack starts on boot.** That is the
   entire point of `homelab.ci.enable` + `systemd.services.ac-host-ci.wantedBy =
   [ "multi-user.target" ]`. Until the box has actually rebooted with that unit
   in place, "starts on boot" is a claim, not a fact.

### Ordering, stated plainly

**Reboot last, and only after `ac-host-ci.service` is active.** Every container
on this box carries `restart: unless-stopped` *except* `ac-host-ci-minio-init-1`
(`no`), so today a reboot brings the whole stack back by itself. But HAZARD 1
step 2 runs `docker compose down`, which **removes** the CI containers — and
until the switch creates `ac-host-ci.service`, nothing restarts them. A reboot
in that window leaves ac-box with no Buildkite agent and no automatic path to
one.

A reboot also destroys the three live race containers regardless of restart
policy — `ac-host-static.service` is `WantedBy=multi-user.target` and its
`ExecStop` is `docker rm -f`. `assetto` is `quiet.drainable = false`. Per
`AGENTS.md`, **this is a 03:00-window action only**, and races must be drained
through `acctl.py` first.

### Before

```bash
ssh ac-box 'readlink -f /run/booted-system; readlink -f /run/current-system'
ssh ac-box 'systemctl status ac-host-ci.service'          # must be active before rebooting
ssh ac-box 'cat /boot/loader/loader.conf; ls /boot/loader/entries/'
ssh ac-box 'nix-store --gc --print-roots | grep pre-homelab'
ssh ac-box 'docker ps --format "{{.Names}}\t{{.Status}}"' > /tmp/ac-box-docker-before-reboot.txt
ssh ac-box 'systemctl list-units --type=service --state=running --no-legend' > /tmp/ac-box-units-before-reboot.txt
ssh ac-box 'ss -tulnp' > /tmp/ac-box-sockets-before-reboot.txt
```

`/boot/loader/loader.conf` currently reads `default nixos-generation-29.conf`
with entries for 25–29, so the reboot lands on the current closure and four
older generations remain selectable at the menu.

Drain first:

```bash
ssh ac-box 'python3 /var/lib/ac-host/src/scripts/acctl.py --env prod drain'
```

### The change

```bash
ssh ac-box 'systemctl reboot'
```

### After

```bash
ssh ac-box 'readlink -f /run/booted-system; readlink -f /run/current-system'  # must now match
ssh ac-box 'uname -r'                                                          # expect 6.18.48
ssh ac-box 'systemctl --failed --no-legend'                                    # expect empty
ssh ac-box 'systemctl is-active ac-host-ci.service'                            # expect active
ssh ac-box 'docker ps --format "{{.Names}}\t{{.Status}}"' > /tmp/ac-box-docker-after-reboot.txt
diff /tmp/ac-box-docker-before-reboot.txt /tmp/ac-box-docker-after-reboot.txt  # names must match; uptimes will not
ssh ac-box 'ss -tulnp' > /tmp/ac-box-sockets-after-reboot.txt
diff /tmp/ac-box-sockets-before-reboot.txt /tmp/ac-box-sockets-after-reboot.txt
ssh ac-box 'curl -s localhost:9090/api/v1/targets | head -c 400'
bash scripts/hub-status.sh; echo "EXIT=$?"    # the reboot line must be gone from the verdict
```

Resume races:

```bash
ssh ac-box 'python3 /var/lib/ac-host/src/scripts/acctl.py --env prod resume'
```

**Acceptance criterion:** `booted == current`; every container name from the
before capture is back; every listening socket from the before capture is back;
`ac-host-ci.service` is active *without a human running `docker compose`*; no
failed units; `hub-status.sh` no longer reports the owed reboot.

### Rollback

A reboot has no undo — it is a fresh start, not a state change. What it has is
a *boot menu*, and that needs console access:

- **If the box boots but the CI stack does not come up:** start it by hand from
  a plain SSH session (`systemctl start ac-host-ci.service`) and treat the
  boot-ordering bug as a git change to land the same session. Do not leave a
  hand-started stack as the resting state.
- **If the box boots to an unusable state:** `runbook-cutover.md`'s abort ladder
  applies unchanged. Method 1 (`nixos-rebuild switch --rollback`) if SSH works;
  Method 2 (systemd-boot menu, arrow keys, five generations, **needs physical
  or IPMI console**) if it does not; Method 3 (the `pre-homelab` GC root) if
  the weekly `nix.gc` has already collected the previous generation.
- **If the box does not boot at all:** this is the only step in this runbook
  that can produce that outcome, which is the reason it is last and the reason
  P5 checks the GC root before starting.

---

## Success Criteria

The decommission is complete when:

1. `/etc/nixos/configuration.nix` throws, naming the flake command, and
   `nix-instantiate --eval` on it produces that message.
2. `/etc/nixos/hardware-configuration.nix` is untouched and still parses to
   `0f0e8b723682cbe8`, matching `hosts/ac-box/hardware-configuration.nix`.
3. `networking.wireless.enable = lib.mkForce false` is committed in
   `modules/platform/network.nix`, and after the next switch
   `systemctl status wpa_supplicant.service` reports the unit does not exist,
   while `nmcli device status` and `ip -br addr` are unchanged.
4. `ac-host-ci-minio-init-1` is still present and still `Exited (0)` — and
   nobody removed it.
5. `readlink -f /run/booted-system` equals `readlink -f /run/current-system`.
6. `bash scripts/hub-status.sh` no longer lists the owed reboot, and the closure
   drift line reflects a switch that actually happened.
7. `docs/current-state.md` §2's Decommission table is updated: three rows
   closed, `inquire-platform` (a registry decision, out of scope here) still
   open, and the two corrections in Appendix B folded in.

Items 1, 3 and 4 are box actions or no-ops and leave no git trace at all. That
is the expected outcome and not a gap — but it is exactly why criterion 7 is on
the list. A box action that nobody records is a box action nobody can audit.

---

## Appendix A — What was verified, 9 Sep 2026

Read-only over `ssh ac-box` (session lands as `root`). Nothing on the box was
modified. Local Nix evaluation was done in WSL against `homelab` HEAD `d74131d`.

| Claim | Command | Result |
|---|---|---|
| `/etc/nixos` is in no repo | `git -C /etc/nixos rev-parse --show-toplevel` | *not a git repository* |
| Both files dated 31 Aug | `stat -c "%n %s %y" /etc/nixos/*` | `configuration.nix` 4792 B 01:27; `hardware-configuration.nix` 989 B 00:57 |
| Zero closure coupling | `grep -rl /etc/nixos /run/current-system/etc/` | no output |
| `copySystemConfiguration` off | `ls /run/current-system/configuration.nix` | No such file |
| A bare rebuild fails, not reverts | `nix-instantiate --find-file nixos-config` | `error: file 'nixos-config' was not found in the Nix search path` |
| …and why | `NIX_PATH` | `nixpkgs=flake:nixpkgs:/nix/var/nix/profiles/per-user/root/channels` — no `nixos-config` entry |
| …and the fallback that would have used it | `nixos/default.nix` line 2 in the pinned nixpkgs | `configuration ? import ./lib/from-env.nix "NIXOS_CONFIG" <nixos-config>` |
| No `/etc/nixos/flake.nix` | `ls -a /etc/nixos/` | two files only, so `nixos-rebuild-ng` takes the classic path |
| **Hardware files match** | `nix-instantiate --parse … \| sha256sum` on all three copies | all `0f0e8b723682cbe8` |
| …including at the booted commit | same, on `git show 5fc6c90:hosts/ac-box/hardware-configuration.nix` | `0f0e8b723682cbe8` |
| Regenerating would regress | `nixos-generate-config --show-hardware-config` | 2541 B: 9 docker overlayfs `fileSystems` entries added; `usbhid`, `usb_storage`, `sd_mod` dropped from initrd modules |
| No wireless hardware | `ls /sys/class/net` | `eno1 enp8s0 lo` + 3 docker bridges + 3 veths |
| `wpa_supplicant` live and enabled | `systemctl show wpa_supplicant.service` | `ActiveState=active`, `UnitFileState=enabled`, `WantedBy=multi-user.target`, `NRestarts=0` |
| NetworkManager is the source | nixpkgs `networkmanager.nix` `mkIf (!delegateWireless && !enableIwd)` | sets `networking.wireless.enable = true` |
| NM has no unit dep on it | `systemctl show NetworkManager.service -p Wants -p After -p Requires` | no `wpa_supplicant` |
| `mkForce false` removes exactly one unit | `nix eval` + `extendModules` (item 2) | removed: `wpa_supplicant.service`; added: none; removed user: `wpa_supplicant`; `NetworkManager.service` byte-identical |
| plain `false` does **not** work | same, `builtins.tryEval` | eval error — conflicting definition values |
| `minio-init` exited cleanly | `docker ps -a` / `docker inspect` | `Exited (0)`, restart policy `no` |
| …and is a required dependency record | `compose/docker-compose.buildkite.yml` | `agent` `depends_on: minio-init: service_completed_successfully` |
| Kernel is *not* pending | `readlink -f /run/{booted,current}-system/{kernel,initrd,kernel-modules}` | all three pairs identical (`linux-6.18.48`) |
| The drift is userspace | `nix store diff-closures /run/booted-system /run/current-system` | samba, cifs-utils, freeciv, openjdk, the four tier slices, `etc-homelab-tenants.json`, arcade + rsync units |
| Boot menu depth | `cat /boot/loader/loader.conf; ls /boot/loader/entries/` | `default nixos-generation-29.conf`; entries 25–29 |
| Backlog is 20, not 15 | `bash scripts/hub-status.sh` | `DRIFT - 20 commit(s) committed AFTER that switch` |
| Nothing failed | `systemctl --failed` | empty |

---

## Appendix B — Corrections owed to `docs/current-state.md`

Recorded here rather than applied; §2 and §5 are maintained by the coordinator.

1. **§2 Decommission, `/etc/nixos`** — "one `nixos-rebuild switch` without the
   flag builds *that* … and exits 0" is **not true on this box today**. It
   fails at evaluation, because `NIX_PATH` carries no `nixos-config` entry.
   The item's priority is unchanged — the protection is an unasserted nixpkgs
   default, and four ordinary actions re-arm the trap — but the mechanism in
   the table should say "fails with a cryptic search-path error, and would
   silently revert the moment `nixos-config` is back in `NIX_PATH`."
2. **§2 Decommission, `ac-host-ci-minio-init-1`** — "Disappears when the CI
   stack is adopted under systemd" is wrong. `docker compose up` recreates it
   and compose *requires* the exited container to satisfy `agent`'s
   `service_completed_successfully`. It belongs under a "not a defect" note,
   not under Decommission.
3. **§5 item 1 / F1 follow-up** — the hardware-file check that item 1 asks for
   is now done, with evidence: all three copies parse to `0f0e8b723682cbe8`,
   including the copy at `5fc6c90`, the commit that built the running closure.
4. **The "Reboot owed" note** — accurate but incomplete. Kernel, initrd,
   modules and kernel-params are byte-identical between booted and current;
   only `init` and `system-path` differ. Nothing kernel-side is pending.
5. **§3 / `runbook-cutover.md` baseline: 13 containers, now 9.** `docker ps`
   and `hub-status.sh` both report nine running (3 lobbies, 4 `ac-host`
   sidecars incl. the bot, agent, minio) plus one exited. The cutover baseline
   and its success criterion 4 both say thirteen. Somebody should establish
   whether four containers were retired deliberately or went away unnoticed;
   this runbook did not investigate it.
6. **`modules/ci/default.nix`'s header is now stale.** It opens "NOT imported
   by flake.nix or by hosts/ac-box/configuration.nix, and must not be until the
   adoption sequence below has been run by hand." Both now import it and
   `hosts/ac-box/configuration.nix` sets `homelab.ci.enable = true`. The
   sequencing warning is still right; the statement of fact is not.
7. **`ci.units` is still `[]`** in `hosts/ac-box/tenants.nix` and in the live
   `/etc/homelab/tenants.json`, so `ac-host-ci.service` will not be claimed by
   `batch.slice` even after adoption. The module header names this as the
   follow-up ("a future, separate change … can add its name to `ci.units`") and
   it has not been made. Low impact — the containers are fenced by
   `cgroup_parent`, not by the unit — but the tenant inventory will show a
   tenant with a running service and an empty `units` list, which is exactly
   the shape §2 classifies as nonconforming.
8. **`/var/lib/ac-host/src/hosts/ac-box/hardware-configuration.nix` is mode
   `0666`.** `README.md` tells operators to fetch the hardware config from that
   path. A world-writable file in the rsync-deployed tree is not a secret leak
   (disk UUIDs are not secrets, as README says) but it is a writable input to a
   documented trust path.
