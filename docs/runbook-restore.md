# Restore Runbook: getting ac-box's state back

The backup this runbook restores from is `scripts/hub-backup.sh` (bead
`homelab-bqo.38`, `docs/architecture.md` Part III row 22). Read the first two
sections before you need them; the rest is meant to be followed under pressure.

Everything below was executed on **14 Sep 2026** on the operator's WSL machine.
Nothing on ac-box was modified to produce it: the backup's far side is
read-only, and so is every verification step here. The one section that *does*
write to the box — [Restoring a whole tenant](#4-restoring-a-whole-tenant) — is
marked as a box action and carries its own abort criteria.

---

## 1. What exists, and where

| | |
|---|---|
| Runs on | the operator's WSL machine, **not** ac-box. A backup that lives on the machine it is backing up is not one. |
| Schedule | `hub-backup.timer`, 04:30 **America/Chicago** (09:30 UTC), `Persistent=true` |
| Staging mirror | `/home/nixos/backup/ac-box/<the box's absolute path>` — last night's tree, readable directly |
| restic repo | `/home/nixos/backup/restic` |
| Repo password | `restic-repo-password` in `secrets/ac-box.yaml` (sops; two recipients, the box's host key and the operator's) |
| Retention | 7 daily, 4 weekly, 6 monthly |
| Status | `/home/nixos/backup/status`, one `KEY=VALUE` per line; `scripts/hub-status.sh` prints its age and complains past three days |

**Two copies, and they answer different questions.** The staging mirror is what
the box looked like at the last run — restoring from it is a file copy and
needs no password. The restic repo is *history*: it is the only thing that can
answer "the file was already wrong yesterday". Reach for the mirror first.

### What is in it

The directory list is not written down anywhere except the contract. Ask:

```bash
bash scripts/hub-backup.sh --list      # ~1s, no root, no network
```

On 14 Sep 2026 that is `/var/lib/ac-host` (assetto), `/var/lib/arcade`,
`/var/lib/agent-hub`, `/var/lib/qdrant` (declared, absent on the box) and
`/var/lib/monitoring` (observability). A tenant is added to the backup by
setting `state.backup = true` in `hosts/ac-box/tenants.nix` and nothing else.

### What is NOT in it — read this before assuming a file is recoverable

- `/var/lib/ac-host/{src,dist,build,pending-src,_local_wipe_backup}` are
  excluded on purpose: 7.9 GB of the 12 GB, all of it in git or rebuildable
  from it. `src` is a checkout of ac-host at the sha in `last-applied.json`;
  `scripts/hub-status.sh` compares it to git file by file. Restore it from git.
- `/var/lib/grafana` (94 MB, the dashboards and their history) and
  `/var/lib/prometheus2` (70 MB, the TSDB) are **not declared by any tenant**,
  so they are not backed up. `observability` declares only
  `/var/lib/monitoring`, which holds four secret files that are now in git.
  This is a gap in the declaration, not in the backup.
- Anything outside the declared state directories: `/etc`, the Docker images,
  the Nix store. The box is rebuildable from git; its state is not.

---

## 2. Before restoring anything

```bash
cd /home/nixos/src/homelab
grep . /home/nixos/backup/status                  # when did this last work?
RESTIC=$(nix build --no-link --print-out-paths nixpkgs#restic)/bin/restic
export RESTIC_REPOSITORY=/home/nixos/backup/restic
export RESTIC_PASSWORD="$( . scripts/lib/sops-secret.sh; hub_sops_secret restic-repo-password )"
$RESTIC snapshots
```

`RESTIC_PASSWORD` is an environment variable and not a command-line argument
deliberately: `ps` shows argv to every user on the machine. Close the shell
when you are done, and never `echo` it.

If `hub_sops_secret` fails, the problem is the age identity, not the backup:
it needs `~/.ssh/id_ed25519_ac-host` (see `.sops.yaml`). Without either that
key or the box's host key, the repo is unreadable — that is the design.

---

## 3. Restoring a single file

**First, try the mirror.** No password, no restic, and it is the same bytes:

```bash
ls -l /home/nixos/backup/ac-box/var/lib/ac-host/whitelist.json
```

If that file is the one you want, copy it back (section 4's box-action rules
still apply) and stop reading.

**From history**, when the mirror has already copied the damage, or when the
file was deleted more than one run ago:

```bash
# Which snapshots hold it, and what it looked like in each
$RESTIC find --long /home/nixos/backup/ac-box/var/lib/ac-host/whitelist.json

# Pull one version out to a scratch directory -- NEVER straight over the box
$RESTIC restore <snapshot-id> --target /tmp/restore \
  --include /home/nixos/backup/ac-box/var/lib/ac-host/whitelist.json

# The restored path keeps the staging tree's absolute shape:
cat /tmp/restore/home/nixos/backup/ac-box/var/lib/ac-host/whitelist.json
```

Always restore to a scratch target and compare before putting anything back.
`sha256sum` both sides; if they match, the file was never the problem.

---

## 4. Restoring a whole tenant

> **This is a box action.** `AGENTS.md`: ac-box changes by landing in git and
> letting the pipeline deploy — but state is not in git, and a restore is
> exactly the case that has no git path. An agent may run the steps below
> *verbatim*; it may not improvise around them, and it stops at any abort
> criterion rather than judging it.

### 4a. Which tenant, and may it be stopped?

| Tenant | Dir | Stopping it |
|---|---|---|
| `assetto` | `/var/lib/ac-host` | **Never outside a window.** `quiet.drainable = false`; `ac-host-static`'s `ExecStop` is `docker rm -f` on live race servers. Drain with `acctl.py` first. |
| `arcade` | `/var/lib/arcade` | Freely (standing authority, 9 Sep 2026). |
| `agent-hub` | `/var/lib/agent-hub` | Freely. |
| `observability` | `/var/lib/monitoring` | Freely. |

A service must not be running while its state directory is replaced. Replacing
it underneath a live process is how a partial restore becomes a corrupt one.

### 4b. Stage the tree locally and check it

```bash
$RESTIC restore <snapshot-id> --target /tmp/restore \
  --include /home/nixos/backup/ac-box/var/lib/arcade
cd /tmp/restore/home/nixos/backup/ac-box/var/lib && ls -ln arcade
du -sh arcade
```

`ls -ln` shows numeric owners: they are the box's UIDs, preserved by
`rsync --numeric-ids` and by restic. They will not match this machine's passwd
and are not supposed to.

**Abort** if the tree is empty, if the top directory's mode is not what the
table in `hosts/ac-box/tenants.nix` implies, or if `du` is wildly smaller than
the box's current directory. A restore that silently puts back less than there
was is worse than no restore.

### 4c. Put it on the box

```bash
# 1. stop the tenant's units (arcade shown; assetto needs a window and a drain)
ssh ac-box 'systemctl stop arcade-freeciv arcade-mindustry'

# 2. move the live directory aside -- never delete it; it is the rollback
ssh ac-box 'mv /var/lib/arcade /var/lib/arcade.broken-$(date +%F)'

# 3. push the restored tree, preserving numeric ownership
sudo rsync -a --numeric-ids /tmp/restore/home/nixos/backup/ac-box/var/lib/arcade \
  root@192.168.1.50:/var/lib/

# 4. verify before starting anything
ssh ac-box 'ls -ln /var/lib/ | grep arcade; du -sh /var/lib/arcade'

# 5. start the units, then watch them
ssh ac-box 'systemctl start arcade-freeciv arcade-mindustry; systemctl status arcade-freeciv'
```

**Abort at step 4** if the owner, group or mode differs from the directory you
moved aside. Ownership is the failure this backup takes the most trouble over
(`scripts/hub-backup.sh` stamps each staged directory from the box's own
`stat`), and it is the one that makes a service fail in a way that looks like a
code bug.

Leave `/var/lib/<tenant>.broken-<date>` in place until the tenant has been
watched working, then remove it by hand. Nothing removes it for you.

---

## 5. Installing the timer

The backup runs on the operator's WSL machine, which is **NixOS**, so
`/etc/systemd/system` is a read-only symlink into `/etc/static` and unit files
cannot be dropped into it. Add to `/etc/nixos/configuration.nix`:

```nix
  systemd.packages = [
    (pkgs.runCommandLocal "hub-backup-units" { } ''
      mkdir -p $out/lib/systemd/system
      cp ${/home/nixos/src/homelab/hub/systemd}/hub-backup.{service,timer} \
         $out/lib/systemd/system/
    '')
  ];
  systemd.timers.hub-backup.wantedBy = [ "timers.target" ];
```

then

```bash
sudo nixos-rebuild switch
systemctl list-timers hub-backup.timer      # next elapse should be 09:30 UTC
sudo systemctl start hub-backup.service     # run it once, now, and watch
journalctl -u hub-backup -n 50
```

The unit files in `hub/systemd/` are the canonical text and are deliberately
**not** in ac-box's closure: nothing under `modules/` imports them. On a host
where `/etc/systemd/system` is writable the same two files install the ordinary
way — `sudo cp hub/systemd/hub-backup.* /etc/systemd/system/ && sudo systemctl
daemon-reload && sudo systemctl enable --now hub-backup.timer`.

Until the timer is installed, `scripts/hub-status.sh` says so: no status file
means nothing has ever run, and a status file older than three days means the
nightly pull has stopped.

---

## Appendix A — the restore that was proven, 14 Sep 2026

A backup nobody has restored from is a hypothesis. This is the test that was
run when the script was written; re-run it after any change to `hub-backup.sh`.

### The run that was restored from

```
== pull: rsync from root@192.168.1.50 (read-only on the far side) ==
  /var/lib/agent-hub (agent-hub, 991:987 700)          0 files transferred
  /var/lib/qdrant (agent-hub): DECLARED BUT ABSENT on the box - skipped
  /var/lib/arcade (arcade, 992:988 700)                16 files, 19,185,931 bytes
  /var/lib/ac-host (assetto, 0:0 750) excluding /src /dist /build /pending-src
                                                       1,604 files, 4,245,409,004 bytes
  /var/lib/monitoring (observability, 0:0 755)         0 files transferred
staged: 4.0G
  Added to the repository: 3.686 GiB (1.685 GiB stored)
  processed 1620 files, 3.972 GiB in 0:05
  snapshot a35f7250
  check --read-data-subset=5%: 5 / 5 packs, no errors were found
== done in 48s ==
```

Wall time 48 s for the first full pull (4.0 GB over the LAN, cold restic repo);
`restic stats --mode raw-data` → **1.685 GiB** stored for 3.686 GiB of data,
compression ratio 2.19x.

### Single file: delete it, restore it, compare

`/var/lib/ac-host/whitelist.json` — the one file in the backup that exists in
no repo by design (README: "everything is public except one file").

```
box        sha256 1cf93b62…0963   /var/lib/ac-host/whitelist.json (2637 bytes, 0:0 644)
staging    sha256 1cf93b62…0963   /home/nixos/backup/ac-box/var/lib/ac-host/whitelist.json
           rm -f <the staging copy>
restic     restic restore a35f7250 --target /tmp/hub-restore-proof \
             --include /home/nixos/backup/ac-box/var/lib/ac-host/whitelist.json
restored   sha256 1cf93b62…0963   (0.3 s)   MATCH
```

All three are the same bytes: the box's live file, the mirror, and the copy
restic handed back after the mirror's copy had been deleted.

### Whole tenant: restore `arcade` and diff it

```
restic restore a35f7250 --target /tmp/hub-restore-proof \
  --include /home/nixos/backup/ac-box/var/lib/arcade
Summary: Restored 46 / 40 files/dirs (18.297 MiB) in 0:00          (0.8 s)

diff -r --no-dereference <restored>/arcade <staging>/arcade        no differences
stat -c '%u:%g %a'       992:988 700   (both)
```

Numeric ownership and mode survive the whole path — box → rsync → staging →
restic → restore — which is the property section 4b tells you to abort on.

### What this does NOT prove

The restored tree was never written back onto ac-box. Section 4c has not been
executed; it is the one step that cannot be rehearsed without stopping a
tenant. The parts of it that could be proven read-only were: that the bytes,
the owners and the modes come back intact.
