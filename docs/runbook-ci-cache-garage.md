# Runbook: the CI cache leaves MinIO for Garage (ADR 0013)

**Status: drafted 28 Sep 2026, nothing executed.** Every fact below was read
on 28 Sep 2026 between 13:35 and 14:15 CDT, read-only: over `ssh arcade-box`
(`192.168.1.50`) and `ssh ac-box` (the Z840, `192.168.1.51` -- llm-box since
homelab `1a17f76`, which arcade-box took at 13:57; the Z840's own switch to
the rename is `docs/runbook-llm-box-rename.md` 7.4), from the WSL trees at
the shas section 3 names, and from a WSL prototype of the pinned Garage with
the agent's own Nix (ADR 0013, the table under Context). Nothing on either
host was changed to produce it; everything the prototype started was stopped.

ADR 0013 is the why; this is the how. What changes: the cache's server
(MinIO, a container in `ac-host`'s CI compose project, becomes
`garage.service` on arcade-box), its name (`minio:9000` becomes
`flox-binary-cache:3900` to write and `flox-binary-cache:3902` to read), its
readers (llm-box joins arcade-box), its rank among substituters (priority 0
by accident becomes 50 on purpose) and its write credential (fresh). What
does not: the bucket's name and every object in it (the 42 paths that exist
nowhere else among them), the signing keys and what trusts them
(`flox-binary-cache-1` and `-2`), the plugin, what any pipeline does, the
agent's container and HAZARD 2, and the racing tenant -- no step touches a
lobby, `ac-host-static` or `docker.service`, so none needs the window.

---

## 1. What is known (28 Sep 2026)

| | |
| --- | --- |
| MinIO | `ac-host-ci-minio-1`, image `homelab/minio:nixpkgs` since this morning's restart, published on `127.0.0.1:9000/9001` only. Volume `ac-host-ci_minio-data` 3.7 G. Bucket `flox-binary-cache`: 1,197 narinfo objects, 1,161 NARs, `nix-cache-info` = `StoreDir: /nix/store` alone. Anonymous GET, and anonymous LIST: a GET of the bucket returned a 357,585-byte listing. Still written: two narinfos at 09:09 CDT today |
| Paths nowhere else | 42 (the bead). The one that matters: `/nix/store/qn6qpywlzv0mi1d80kgk4s3cm8acnr76-llama-cpp-3bb386e` (agent-hub `9a55c11`'s lock): 404 on cache.nixos.org and cache.flox.dev; in MinIO (FileSize 20,030,784, NarSize 162,045,832, `Sig: flox-binary-cache-2`); present in the Z840's store |
| Priorities, as root's Nix recorded them | arcade-box `binary-cache-v7.sqlite`: cache.nixos.org 40, cache.flox.dev 41, `http://127.0.0.1:9000/flox-binary-cache` **0**. The Z840: the same three (MinIO's from 26 Sep 02:20, before the cutover) and `s3://flox-binary-cache` 0 (18 Sep, the native-CI experiment) |
| arcade-box `nix.conf` | `substituters = https://cache.nixos.org/ https://cache.flox.dev http://127.0.0.1:9000/flox-binary-cache`, both `flox-binary-cache` keys trusted; `connect-timeout = 15`, `require-sigs = true`, `narinfo-cache-negative-ttl = 3600` |
| The Z840 `nix.conf` | `substituters = https://cache.nixos.org/ https://cache.flox.dev`; neither `flox-binary-cache` key; same three settings. `curl http://192.168.1.50:3902/` from it times out |
| `ac-host-ci` | active (exited) since 04:29:49. Its restart at 04:24:10 ran `down` (the agent, MinIO and the network removed 04:24:11-15), loaded both images, rebuilt the agent image from the plugin's `#main` (04:24:21-04:29:41), then created all three (04:29:46): every restart recreates the agent and its bridge |
| The compose network | `ac-host-ci_default`, bridge `br-d12f03aec340`, `172.19.0.0/16`, created 04:29:46. No interface `br-ac-host-ci`. `docker0` is `172.17.0.1/16` -- `host-gateway` |
| Firewall | iptables (nf_tables). `nixos-fw`: `lo`, established, `22` on every interface, then only the registry's `-i eno2` rules; nothing for any bridge. The nat table's `DOCKER` chain: MinIO's two DNATs (`-d 127.0.0.1/32 … 9000`, `… 9001`) and nothing else. `FORWARD` jumps to `DOCKER-USER`, `DOCKER-FORWARD` |
| Ports | nothing bound on 3900-3999 |
| Names | `nsswitch.conf` `hosts: mymachines files myhostname dns` on both hosts; `getent hosts x.web.localhost` → `::1` (nss-myhostname); `/etc/hosts` holds `localhost` and the host's own name only |
| Docker | 29.7.2, iptables backend, userland proxy on; `docker compose` and `docker-compose` 5.4.0 |
| Registry | arcade-box's system `nixpkgs` is the pin's source (`vin7xkms…`), so `nix run nixpkgs#rclone` there is rclone 1.75.0 |
| Disk | arcade-box `/`: 938 G, 70 G used |
| The agent | idle at 13:40 (no `buildkite-agent bootstrap`). Its argv carries `--token` and its environment every secret compose passes it: see 3.6 |
| The tenant tree | `/var/lib/ac-host/src` is a synced copy, not a git checkout: the DOWNTIME build (`ci_downtime.py` 48-65) syncs `pending-src` into it at 03:00. `pending-deploy.json` = ac-host `4da4918`, staged 14:18Z for the 29 Sep 03:00 apply |
| Deployed | arcade-box on homelab `1a17f76` (13:57:51 CDT); the Z840 on `47f5616` (hand-switched 09:04) |

---

## 2. Decisions this runbook takes

ADR 0013 decides the design. These are the calls about order and method,
each what the measurements force or what a careful operator would do; the
operator's own are section 6.

**D1. The other trees go first, and are no-ops.** Every pipeline stops
naming the cache (its `S3_CACHE_*` restates the agent's defaults exactly),
and `ac-host`'s compose gets the named bridge, the name and an interpolated
build arg -- all inert until the switch. The switch is then three lines of
homelab's `ci-env`, and so is its revert.

**D2. Garage comes up beside MinIO in one homelab push (H1), with both
readers configured.** Nothing writes to it; arcade-box asks it last, behind
MinIO; the Z840 not until its own hand switch (4.8), after the copy is
proven.

**D3. Three restarts of `ac-host-ci`, each a verbatim step from ssh.** Each is
preceded by the busy check and by `docker compose … config --quiet`, the
check that the file on disk renders -- never without `--quiet` (3.6). A
restart rebuilds the agent image from the plugin's moving `#main`, so its
sha is recorded before each.

**D4. Writes stop for the final copy because the agent is stopped**
(`docker stop`), not because it happens to be idle.

**D5. No hand switch of arcade-box, even to roll back.** AGENTS.md keeps that
for a broken path unit. If a failing push stops CI from staging a revert, the
record is staged by hand and `homelab-deploy` applies it with its busy check
and its gates (section 5).

**D6. The operator adds the three keys on H1's branch before it merges.**
The toplevel's sops manifest check, which CI builds and the local gate does
not, needs them.

**D7. MinIO stays a week after the switch, receiving nothing, then leaves.**

---

## 3. The changes, per tree

Line numbers are at the shas named; each worker re-reads its own.

### 3.1 ac-host (`4da4918`)

**A1, the preparation** (one commit, no effect until restart 1):

- `compose/docker-compose.buildkite.yml`
  - 220: the build arg `S3_CACHE_ENDPOINT: http://minio:9000` becomes
    `${S3_CACHE_ENDPOINT:-http://minio:9000}`, so the baked read path
    follows `ci-env` (same default, so the same image until the switch).
  - the `agent` service (206-348): `extra_hosts: ["flox-binary-cache:host-gateway"]`.
  - top level, after `volumes:` (350): `networks: { default: { driver_opts:
    { com.docker.network.bridge.name: br-ac-host-ci } } }` -- the name
    homelab's rule opens 3900 on.
  - 200-201: drop `S3_CACHE_ACCESS_KEY_ID` and `S3_CACHE_SECRET_ACCESS_KEY`
    from `minio-init`'s environment. `minio-init.sh` then skips its `user
    add` (36-50) and the existing `flox-cache` user stays in MinIO's IAM
    store; from the switch on those two variables carry the Garage key,
    which MinIO must never see or store.
  - the header (1-5) and 146-149 say where the cache is.
- `.buildkite/pipeline.yml` 10-15 (the `env:` block) and 4-5,
  `.buildkite/ops.yml` 11-16, `.buildkite/series.yml` 8-13: delete. Each
  block is the five `S3_CACHE_*` values compose already gives the agent
  (294-298); a silent pipeline gets the agent's.

**A3, the removal** (4.9):

- `compose/docker-compose.buildkite.yml`: the `minio` and `minio-init`
  services (158-204), the agent's `depends_on` (232-234), `minio-data`
  (354); the defaults at 220 and 295 become `http://flox-binary-cache:3900`;
  the comments at 159-172, 187-189, 320-328 and 345.
- `compose/minio-init.sh`: delete.
- `compose/env.buildkite.example` 23-31: the MinIO block becomes the Garage
  key's two variables and the endpoint.
- `docs/ci-cd.md` 87-103 and 130-150: the cache's section;
  `scripts/ci_containerize.sh` 20 (a comment).

### 3.2 agent-hub (`9a55c11`)

- `.buildkite/pipeline.yml` 37-42: the `env:` block, delete; 19 ("the MinIO
  cache") names the CI cache.

### 3.3 home-arcade (`71b34a0`)

- `.buildkite/pipeline.yml` 13-16: delete `s3-cache-bucket`,
  `s3-cache-endpoint`, `s3-cache-region`, `s3-cache-public-key` from the
  plugin anchor (the plugin falls back to the agent's `S3_CACHE_*`; the key
  list at 16 names `-1` alone). Keep `s3-cache-push` (17, and `false` at
  68): per-step intent. The comments at 27 and 60 say MinIO.

### 3.4 homelab (`1a17f76`)

**H1, Garage beside MinIO:**

- `modules/ci/default.nix` -- the server half, under `mkIf cfg.enable`:
  - `services.garage` with ADR 0013 decision 1's settings, `package =
    pkgs.garage_2`, `environmentFile = cfg.cache.envFile`,
    `extraEnvironment.GARAGE_DEFAULT_BUCKET = cfg.cacheBucket`;
    `systemd.services.garage.serviceConfig.ExecStart = lib.mkForce
    "${pkgs.garage_2}/bin/garage server --single-node --default-bucket"`.
  - `ci-cache-init.service`: oneshot, `RemainAfterExit`, `after` and
    `requires` `garage.service`, `partOf` it, `wantedBy` it and
    `multi-user.target`, `EnvironmentFile` the same env file, `path` curl
    and the garage package. Its script: wait for `127.0.0.1:3900` to answer
    (bounded, then fail); `garage bucket website --allow flox-binary-cache`;
    PUT `nix-cache-info` -- a `pkgs.writeText` of `StoreDir: /nix/store` and
    `Priority: 50` -- with `curl --fail --aws-sigv4 aws:amz:us-east-1:s3 -K
    <(printf 'user = "%s:%s"\n' …)` (credentials on a file descriptor, never
    argv) and `-H 'Content-Type: text/x-nix-cache-info'`; then GET it back
    through `http://127.0.0.1:3902` with `Host: flox-binary-cache` and `cmp`
    it with the file.
  - `networking.firewall.interfaces.${cfg.cache.bridge}.allowedTCPPorts =
    [ 3900 ]`, `cfg.cache.bridge` defaulting to `br-ac-host-ci` -- the name
    ac-host's compose sets, the same coupling `projectName` (582-593) already
    is, with node-exporter.nix's kind of comment.
  - options `homelab.ci.cache.{envFile,bridge}`; imports the reader half.
  - the comment at 688-702: the order is Priority's, not `mkOrder`'s.
  - untouched: `systemd.services.ac-host-ci` (732-785). H1 must not change
    the agent's unit (4.4, P8).
- `modules/ci/cache-reader.nix` (new, importable alone): the cache's name,
  ports and the two public keys, defined once; option
  `homelab.ci.cache.readFrom` (a host name, or null for none). It sets
  `nix.settings.substituters = lib.mkOrder 1700 [
  "http://flox-binary-cache:3902" ]`, the two trusted keys, and
  `networking.hosts.<address> = [ "flox-binary-cache" ]`, the address
  `127.0.0.1` when `readFrom` is `homelab.host.name`, else
  `homelab.host.peers.${readFrom}.address` -- asserting the peer exists.
- `hosts/arcade-box/tenants.nix`, `ci` (605-677): the description and the
  comment at 605-607; `units` (645-651) gains `garage.service` and
  `ci-cache-init.service`, unconditionally; `ports` (653-664) gains
  `garage-s3` 3900 `local`, `garage-rpc` 3901 `local`, `garage-web` 3902
  `lan` (the `minio-*` claims stay until H3); a new `state = { dirs = [
  "/var/lib/ci" "/var/lib/private/garage" ]; backup = false; }`, in that
  order (ADR 0013 decision 8); `secrets` (668-674) gains `garage-rpc-secret`,
  `garage-s3-key-id`, `garage-s3-secret-key` and loses
  `s3-cache-access-key-id`, which sops never had.
- `hosts/arcade-box/configuration.nix`: `homelab.ci.cache.readFrom =
  "arcade-box";` beside `homelab.ci.enable` (69); the comments at 57 and 235
  name the cache, not MinIO.
- `modules/platform/secrets.nix`: `garage-rpc-secret`, `garage-s3-key-id`,
  `garage-s3-secret-key` beside 275-278; `templates.garage-env` =
  `GARAGE_RPC_SECRET`, `GARAGE_DEFAULT_ACCESS_KEY`,
  `GARAGE_DEFAULT_SECRET_KEY` from those three, `restartUnits = [
  "garage.service" ]` (a rotation restarts Garage; `garage.service` keeps
  `restartIfChanged`, so the switch does not skip it); and
  `homelab.ci.cache.envFile = config.sops.templates.garage-env.path;` beside
  490, the `homelab.ci.envFile` pattern.
- `hosts/llm-box/host.nix`: `peers.arcade-box.address =
  (import ../arcade-box/host.nix { }).homelab.host.networks.lan.address;`,
  no `metrics`, with the comment arcade-box's host.nix has for its import
  (10-17).
- `hosts/llm-box/configuration.nix`: `homelab.ci.cache.readFrom =
  "arcade-box";`.
- `flake.nix` 247-275: llm-box's modules gain `./modules/ci/cache-reader.nix`.
- `modules/platform/host-options.nix` 162-181: `peers` is "another homelab
  host this one scrapes or reads from"; "empty on every host but the
  collector" goes.
- `CONTEXT.md` 48-53, **Peer**: llm-box's peer is arcade-box, which it reads
  the CI cache from and scrapes nothing on. A new entry, **CI cache**: the
  bucket `flox-binary-cache` in Garage on the host that runs `ci`, written
  over S3 on 3900 by the agent, read anonymously over HTTP on 3902; _Avoid_:
  MinIO, the S3 cache.
- The harness (`modules/ci/tests/eval.nix` and its fixtures), a case each
  that rejects: the S3 port at any scope but `local`, or the web port at any
  but `lan`; 3900 in a global `allowedTCPPorts` or on the LAN interface; a
  `services.garage.package` below version 2; a `readFrom` that is neither
  this host nor one of its peers; `nix-cache-info` without `Priority: 50`;
  `ExecStart` without `--single-node --default-bucket`; `garage.service` or
  `ci-cache-init.service` outside `batch.slice`.
- `docs/architecture.md`: a delta row for this bead (44 today), and the two
  diagrams' "buildkite agent · minio" (199, 344) and 292.

**H2, the switch** (4.7): `modules/platform/secrets.nix`, `ci-env` (462-482):
a new line `S3_CACHE_ENDPOINT=http://flox-binary-cache:3900`;
`S3_CACHE_ACCESS_KEY_ID` (472) `=${config.sops.placeholder.garage-s3-key-id}`;
`S3_CACHE_SECRET_ACCESS_KEY` (473)
`=${config.sops.placeholder.garage-s3-secret-key}`. Nothing else.

**H3, the removal** (4.9):

- `modules/ci/default.nix`: the `minio` override and the two images
  (457-522), `homelab.ci.images` (612-630), the `ExecStartPre` loads
  (764-767), the evaluation warning (724-730), `bucketUrl` (455) and the
  MinIO substituter (706); `--remove-orphans` on `ExecStart` and `ExecStop`
  (769, 775), so the restart removes the containers compose no longer
  declares; `ac-host-ci` `after`/`wants` `ci-cache-init.service`; the
  header's IMAGES (157-237), the MinIO lines of VOLUMES and CREDENTIALS.
- `modules/platform/secrets.nix`: `minio-root-password` and
  `s3-cache-secret-access-key` (276-277); `ci-env`'s `MINIO_ROOT_USER` and
  `MINIO_ROOT_PASSWORD` (469-470); the comments at 245-274 and 410-439.
- `hosts/arcade-box/tenants.nix`: `minio-api`, `minio-console` (654-663);
  those two secret names.
- `modules/ci/tests/eval.nix` 200 and 423-489 (`composeLoadsImages`).
- `modules/tenant/environment-pull.nix` 547, the refusal's "(cache.flox.dev,
  MinIO)" names the CI cache. The line is bash text inside every pull unit
  on both hosts: the units change (and, `restartIfChanged = false`, restart
  nothing); arcade-box takes it with H3's switch, llm-box at its next hand
  switch. Not in H1, whose llm-box switch (4.8) should change nothing but
  `nix-daemon`.
- `.buildkite/pipeline.yml` 7; `docs/architecture.md` row 42 (440) closed
  and 454; `docs/current-state.md` 83-85, 138, 159, 187, 320, 327.

**Not here: native mode's MinIO** (`modules/ci/default.nix` 264-426 and
788-911, `hub/ci/minio-init.sh`, `.flox/env/manifest.toml` 55-58 and 85-86,
`hub/ci/hooks/environment`, `modules/ci/tests/eval.nix` 285-402). The flag is
off and none of it is in the closure; it is a follow-up bead (4.11).

### 3.5 The operator's secrets

sops is the operator's (the agent harness refuses secret-store writes).

| sops key | Value | Made with |
| --- | --- | --- |
| `garage-rpc-secret` | 64 lowercase hex | `openssl rand -hex 32` |
| `garage-s3-key-id` | `GK` + 24 lowercase hex (26 characters) | `openssl rand -hex 12`, prefixed `GK` |
| `garage-s3-secret-key` | 64 lowercase hex | `openssl rand -hex 32` |

Retired after 4.9: `minio-root-password`, `s3-cache-secret-access-key`.
Unchanged: `s3-cache-signing-key` (the NAR signing key), every token.

The file is `secrets/ac-box.yaml` until `docs/runbook-llm-box-rename.md`
section 5 renames it; `scripts/hub-secret-set.sh` writes whichever it names.

### 3.6 What never to print

The 28 Sep leak came through a `docker inspect` of the agent. Nothing in
this runbook runs, and nobody executing it runs:

- `docker inspect ac-host-ci-agent-1` -- its `Config.Env` holds every secret
  compose passes it;
- `docker top ac-host-ci-agent-1` bare, or with `-eo args` unfiltered -- the
  agent's argv carries `--token` (the busy check below prints a count);
- `docker compose … config` without `--quiet` -- it prints the interpolated
  environment;
- `cat` of anything under `/run/secrets`, `systemctl show -p Environment`
  of `ac-host-ci`, `garage key info --show-secret`.

A step that needs a secret reads it into a variable on the box and passes the
variable's name (`docker exec -e VAR`) or a file descriptor (`curl -K`),
never a command line.

### 3.7 What each push costs

| Push | What happens | So |
| --- | --- | --- |
| ac-host (A1, the three pipelines, A3) | CI; `queue-prod` stages the tree; the 03:00 DOWNTIME build applies it. A compose change is on disk after that and live at the next restart of `ac-host-ci`, never before | push any day; the restarts are this runbook's |
| agent-hub | CI; within ~10 minutes llm-box's poll stages the sha and the pull restarts `agent-hub-llm` -- every new sha, this one too | push while bead-loop's lanes are idle, or pause them |
| home-arcade | CI; manifest and lock unchanged, so the push step stages the live generation again and bounces nothing | any time |
| homelab H1 | CI; arcade-box's `homelab-deploy` switches within a minute (deferring while anyone races): `garage` and `ci-cache-init` start, `nix-daemon` restarts (`nix.conf` is its restart trigger), the firewall reloads. llm-box only by 4.8 | 4.4 |
| homelab H2 | arcade-box switches; `ci-env` re-renders; nothing restarts -- `ac-host-ci` has no `restartUnits` and `restartIfChanged = false` | 4.7, then restart 2 the same session |
| homelab H3 | arcade-box switches; `nix-daemon` restarts; `ac-host-ci`'s new unit waits for restart 3 | 4.9 |

---

## 4. Order: the phases, each with its proof

Who: **operator** (the secret store, the go/no-go of section 6); **agent**
(read-only checks, and the box steps below, verbatim, under AGENTS.md's
migration exception -- the sha on origin, a stop at section 5); **worker** (a
commit in a worktree, its proofs in the handoff); **supervisor** (merge, push,
`bd`).

### 4.0 Preconditions

1. `bash /home/nixos/src/homelab/scripts/hub-status.sh`: no verdict naming
   arcade-box; every tree's main green.
2. The rename has reached the Z840 before 4.8:
   `ssh llm-box 'hostname; nixos-version --configuration-revision'` prints
   `llm-box` and a sha at or after `1a17f76`. Until the operator's `Host
   llm-box` exists (`docs/runbook-llm-box-rename.md` 7.1), read `ssh ac-box`
   for `ssh llm-box` in 4.4 and 4.6.
3. Everyone executing has read 3.6.

### 4.1 The pipelines stop naming the cache -- workers, supervisor

The pipeline edits of 3.1, 3.2 and 3.3, one bead per tree; ac-host's ride
with A1. Before each push: that tree's gate
(`bash /home/nixos/src/homelab/scripts/hub-gates.sh <tree> <worktree>`).

Proof, per tree, on its next main build: green, and every step that pushes
logs `--- :flox: push complete`. The line `no S3 cache configured; skipping
write-back` means the agent's environment did not reach the plugin: stop.

### 4.2 ac-host's preparation (A1) -- worker, supervisor, then 03:00

Before the push, on WSL, with placeholder values (nothing secret is
involved):

```bash
cd <A1 worktree>/compose
cfg=$(env -i PATH="$PATH" HOME="$HOME" NIX_CONFIG="extra-experimental-features = nix-command flakes" \
  BUILDKITE_AGENT_TOKEN=x S3_CACHE_ACCESS_KEY_ID=x S3_CACHE_SECRET_ACCESS_KEY=x \
  S3_CACHE_SIGNING_KEY=x MINIO_ROOT_USER=x MINIO_ROOT_PASSWORD=x \
  nix run nixpkgs#docker-compose -- -f docker-compose.buildkite.yml -p ac-host-ci config)
printf '%s\n' "$cfg" | grep -E 'br-ac-host-ci|flox-binary-cache:host-gateway|S3_CACHE_ENDPOINT'
printf '%s\n' "$cfg" | grep -c S3_CACHE_SECRET_ACCESS_KEY
```

Expected: the bridge name under `networks.default.driver_opts`, the
`extra_hosts` line, and `S3_CACHE_ENDPOINT: http://minio:9000` twice (the
build arg and the agent's environment): unchanged. Then `0`: only
`minio-init` was ever given that variable (the agent gets it as
`AWS_SECRET_ACCESS_KEY`), and it no longer is.

After the push: `queue-prod` stages it; the next 03:00 DOWNTIME build applies
it. Proof, the morning after:

```bash
ssh arcade-box 'cat /var/lib/ac-host/last-applied.json; grep -c br-ac-host-ci /var/lib/ac-host/src/compose/docker-compose.buildkite.yml'
```

Expected: A1's sha, `1`. `ac-host-ci` has not restarted (nothing is live yet).

### 4.3 The keys -- operator, on H1's branch

```bash
cd <H1 worktree>
nix run nixpkgs#openssl -- rand -hex 32 | bash scripts/hub-secret-set.sh garage-rpc-secret
nix run nixpkgs#openssl -- rand -hex 12 | sed 's/^/GK/' | bash scripts/hub-secret-set.sh garage-s3-key-id
nix run nixpkgs#openssl -- rand -hex 32 | bash scripts/hub-secret-set.sh garage-s3-secret-key
git add secrets/ && git commit -m 'secrets: garage-rpc-secret, garage-s3-key-id, garage-s3-secret-key (homelab-ygc.20)'
```

Each prints its round trip's hash; no value is shown. Proof, lengths and a
prefix only:

```bash
( . scripts/lib/sops-secret.sh
  for k in garage-rpc-secret garage-s3-key-id garage-s3-secret-key; do
    printf '%s %s\n' "$k" "$(hub_sops_secret "$k" 2>/dev/null | tr -d '\n' | wc -c)"; done
  hub_sops_secret garage-s3-key-id 2>/dev/null | cut -c1-2 )
```

Expected: `64`, `26`, `64`, then `GK`.

### 4.4 Garage beside MinIO (H1) -- worker, supervisor, then arcade-box's deploy

**Proofs before the push** (the worker's handoff carries them; `W` is the
worktree, `M` a checkout of main):

```bash
export NIX_CONFIG="extra-experimental-features = nix-command flakes"
bash /home/nixos/src/homelab/scripts/hub-gates.sh homelab "$W"                                   # P1
strip() { nix eval --raw --impure --expr "let f = builtins.getFlake \"git+file://$1\"; in
  (f.nixosConfigurations.$2.extendModules { modules = [ { system.configurationRevision =
  f.inputs.nixpkgs.lib.mkForce null; } ]; }).config.system.build.toplevel.drvPath"; }
nix run nixpkgs#nix-diff -- "$(strip "$M" arcade-box)" "$(strip "$W" arcade-box)"              # P2
nix run nixpkgs#nix-diff -- "$(strip "$M" llm-box)" "$(strip "$W" llm-box)"                    # P3
nix eval --json "$W#nixosConfigurations.llm-box.config.networking.hosts"                       # P4
git -C "$W" diff main -- '*.nix' | grep -c '^+.*192\.168\.1\.50'
nix eval --raw "$W#nixosConfigurations.arcade-box.config.services.garage.package.version"      # P5
nix eval --json "$W#nixosConfigurations.arcade-box.config.networking.firewall.interfaces"      # P6
nix eval --json "$W#nixosConfigurations.arcade-box.config.nix.settings.substituters"           # P7
for t in "$M" "$W"; do nix eval --raw "$t#nixosConfigurations.arcade-box.config.systemd.units.\"ac-host-ci.service\".unit.drvPath"; echo; done   # P8
```

Expected:

- **P1** `===== GATES PASS - safe to push =====`, the new harness cases among
  the checks.
- **P2** arcade-box differs in: `garage.toml`, `unit-garage.service` and
  `unit-ci-cache-init.service` (each with `Slice=batch.slice`) and the
  init's script, `system-path` (the root-only `garage` wrapper), `nix.conf`
  (one substituter, the keys unchanged), `unit-nix-daemon.service` (its
  restart trigger), `hosts`, the firewall's scripts (3902 on `eno2`, 3900
  on `br-ac-host-ci`), the sops manifest (three secrets, one template), the
  inventory (`/etc/homelab/tenants.json`), `system-units`, `etc`,
  `activate`. Nothing named for `ac-host-static`, `docker` or `ac-host-ci`.
- **P3** llm-box differs in `nix.conf` (the substituter and both keys),
  `unit-nix-daemon.service`, `hosts`, and what depends on them; nothing
  else.
- **P4** `"192.168.1.50": ["flox-binary-cache"]` among llm-box's hosts, and
  `0`: no added line spells the address -- it was read, not typed.
- **P5** `2.3.0`.
- **P6** `eno2` gains 3902 and nothing else; `br-ac-host-ci` has `[3900]`.
- **P7** both `http://127.0.0.1:9000/flox-binary-cache` and
  `http://flox-binary-cache:3902`.
- **P8** the same drvPath twice: H1 leaves the agent's unit alone.
- 4.3's proof passes on this branch.

**After the push** -- arcade-box switches by itself:

```bash
ssh arcade-box 'journalctl -u homelab-deploy --since "-30min" --no-pager | tail -5'
ssh arcade-box 'systemctl is-active garage ci-cache-init ac-host-ci
  systemctl show garage -p Slice -p Nice -p DynamicUser --no-pager
  systemctl show ac-host-ci -p ActiveEnterTimestamp --value
  garage status 2>&1 | tail -2
  garage bucket info flox-binary-cache 2>&1 | grep -E "Website access|Global alias|RWO"
  ss -tlnpH | grep -E ":390[0-2] " | awk "{print \$4}"
  iptables -S nixos-fw | grep -E "dport 390[0-2]"
  getent hosts flox-binary-cache; grep -E "^substituters" /etc/nix/nix.conf
  curl -s http://flox-binary-cache:3902/nix-cache-info'
curl -s -m 5 -H 'Host: flox-binary-cache' http://192.168.1.50:3902/nix-cache-info            # from WSL, over the LAN
ssh llm-box 'curl -s -m 5 -o /dev/null -w "%{http_code}\n" http://192.168.1.50:3900/'
```

Expected: the sha applied; `active` three times (`ac-host-ci` still the
exited oneshot); `Slice=batch.slice`, `Nice=19`, `DynamicUser=yes`;
`ac-host-ci`'s timestamp the one it had before the push; one healthy node on
`cargo:2.3.0`; `Website access: true`, `Global alias: flox-binary-cache`, an
`RWO` line for a `GK…` key; `0.0.0.0:3900`, `127.0.0.1:3901`,
`0.0.0.0:3902`; `-A nixos-fw -i br-ac-host-ci -p tcp -m tcp --dport 3900 -j
nixos-fw-accept` and `-A nixos-fw -i eno2 -p tcp -m tcp --dport 3902 -j
nixos-fw-accept`; `127.0.0.1` with `flox-binary-cache` among its names; the
substituter list with MinIO's URL and Garage's; `StoreDir: /nix/store` and
`Priority: 50`, from arcade-box and from WSL alike; and `000` from llm-box:
the S3 API is not on the LAN.

### 4.5 Restart 1: the agent onto the named bridge, still on MinIO -- agent, verbatim

Needs 4.2 (A1 on disk) and 4.4 (the rule). Before:

```bash
git ls-remote https://github.com/imkarrer/flox-buildkite-plugin refs/heads/main     # record it in section 7
ssh arcade-box 'cd /var/lib/ac-host/src/compose &&
  docker compose -f docker-compose.buildkite.yml -p ac-host-ci --env-file /run/secrets/rendered/ci-env config --quiet && echo CONFIG-OK
  ip link show br-ac-host-ci 2>&1 | head -1
  docker top ac-host-ci-agent-1 -eo args | grep -c "[b]uildkite-agent bootstrap"'
```

Expected: `CONFIG-OK`; `Device "br-ac-host-ci" does not exist.`; `0` (idle
-- anything else, wait). Then:

```bash
ssh arcade-box 'systemctl restart ac-host-ci'      # ~6 minutes: down, two loads, the agent image build, up
ssh arcade-box 'systemctl is-active ac-host-ci; docker ps --format "{{.Names}} {{.Status}}" | grep ac-host-ci
  ip -br link show br-ac-host-ci
  docker exec ac-host-ci-agent-1 getent hosts flox-binary-cache
  docker exec ac-host-ci-agent-1 curl -s -m 5 -o /dev/null -w "%{http_code}\n" http://flox-binary-cache:3900/
  docker exec ac-host-ci-agent-1 printenv S3_CACHE_ENDPOINT'
```

Expected: `active`; the agent and MinIO up; `br-ac-host-ci` UP;
`172.17.0.1 flox-binary-cache`; `403` -- Garage answered through the bridge
and the rule, and refused an anonymous request; `http://minio:9000`, still.
The next job's push completes.

### 4.6 The copy and the round trip -- agent, verbatim

**(a) The copy**, MinIO still live (its user's secret and Garage's key are
read on the box, never shown):

```bash
ssh arcade-box 'bash -s' <<'EOF'
set -eu
export RCLONE_CONFIG_MINIO_TYPE=s3 RCLONE_CONFIG_MINIO_PROVIDER=Minio RCLONE_CONFIG_MINIO_REGION=us-east-1 \
       RCLONE_CONFIG_MINIO_ENDPOINT=http://127.0.0.1:9000 RCLONE_CONFIG_MINIO_ACCESS_KEY_ID=flox-cache
export RCLONE_CONFIG_MINIO_SECRET_ACCESS_KEY="$(cat /run/secrets/s3-cache-secret-access-key)"
export RCLONE_CONFIG_GARAGE_TYPE=s3 RCLONE_CONFIG_GARAGE_PROVIDER=Other RCLONE_CONFIG_GARAGE_REGION=us-east-1 \
       RCLONE_CONFIG_GARAGE_ENDPOINT=http://127.0.0.1:3900
export RCLONE_CONFIG_GARAGE_ACCESS_KEY_ID="$(cat /run/secrets/garage-s3-key-id)"
export RCLONE_CONFIG_GARAGE_SECRET_ACCESS_KEY="$(cat /run/secrets/garage-s3-secret-key)"
rc() { nix run nixpkgs#rclone -- "$@"; }
rc sync --metadata --checksum --exclude /nix-cache-info minio:flox-binary-cache garage:flox-binary-cache --stats-one-line --stats 60s
rc check --checksum --exclude /nix-cache-info minio:flox-binary-cache garage:flox-binary-cache
rc size minio:flox-binary-cache
rc size garage:flox-binary-cache
curl -s http://flox-binary-cache:3902/nix-cache-info
EOF
```

Expected: the sync finishes; `0 differences found`; the two sizes equal,
objects and bytes (~3.6 GiB); `nix-cache-info` still says `Priority: 50`.
`--exclude /nix-cache-info` is not optional: MinIO's copy has no
`Priority`, and a reader that read it would record 0.

**(b) Written from inside the agent, with the Garage key** -- the agent's
own Nix, its own network path, its own signing key; the key passed by name:

```bash
ssh arcade-box 'export AWS_ACCESS_KEY_ID="$(cat /run/secrets/garage-s3-key-id)" AWS_SECRET_ACCESS_KEY="$(cat /run/secrets/garage-s3-secret-key)"
  exec docker exec -i -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_EC2_METADATA_DISABLED=true ac-host-ci-agent-1 bash -s' <<'EOF'
for s in /etc/profile.d/nix*.sh; do [ -e "$s" ] && . "$s"; done   # as the image's entrypoint does
set -eu
f=/tmp/ci-cache-probe-$(date -u +%Y%m%dT%H%M%SZ)
printf 'ADR 0013 round trip, written from the agent with the Garage key\n' > "$f"
p=$(nix-store --add "$f"); rm -f "$f"
k=$(mktemp); trap 'rm -f "$k"' EXIT
( umask 177; printf '%s' "$S3_CACHE_SIGNING_KEY" > "$k" )
nix --extra-experimental-features nix-command copy \
  --to "s3://flox-binary-cache?endpoint=http://flox-binary-cache:3900&region=us-east-1&secret-key=$k" "$p"
echo "PROBE $p"
EOF
```

Expected: `copying path … to 's3://flox-binary-cache'`, exit 0, `PROBE
/nix/store/…-ci-cache-probe-…`. Call it `P1`.

**(c) Read on arcade-box**, substitute-only, the environment pull's own
command:

```bash
ssh arcade-box "nix-store --realise --max-jobs 0 $P1 && nix path-info --sigs $P1 &&
  nix path-info --sigs --store http://flox-binary-cache:3902 /nix/store/qn6qpywlzv0mi1d80kgk4s3cm8acnr76-llama-cpp-3bb386e"
```

Expected: `copying path '…' from 'http://flox-binary-cache:3902'`; `P1` with
`flox-binary-cache-2:…`; the llama path with its signature, served by
Garage.

**(d) Read on llm-box**, over the LAN, before its reader exists: the bytes a
substitution would fetch, checked against what each narinfo promises.

```bash
ssh llm-box 'set -eu; for p in '"$P1"' /nix/store/qn6qpywlzv0mi1d80kgk4s3cm8acnr76-llama-cpp-3bb386e; do
    h=${p#/nix/store/}; h=${h%%-*}
    ni=$(curl -sf -m 10 -H "Host: flox-binary-cache" "http://192.168.1.50:3902/$h.narinfo")
    url=$(printf "%s\n" "$ni" | sed -n "s/^URL: //p")
    want=$(printf "%s\n" "$ni" | sed -n "s/^FileHash: sha256://p")
    sig=$(printf "%s\n" "$ni" | sed -n "s/^Sig: \([^:]*\):.*/\1/p" | tr "\n" " ")
    t=$(mktemp); curl -sf -m 300 -H "Host: flox-binary-cache" -o "$t" "http://192.168.1.50:3902/$url"
    got=$(nix-hash --type sha256 --flat --base32 "$t"); rm -f "$t"
    if [ "$got" = "$want" ]; then echo "OK   $p ($sig)"; else echo "FAIL $p want $want got $got"; fi
  done'
```

Expected: two `OK` lines, each signed `flox-binary-cache-2` (or `-1`).

### 4.7 The switch (H2, the final copy, restart 2) -- worker, supervisor, agent

**(a) H2** (3.4). Proofs before the push: P1; P2's recipe for arcade-box
names the `ci-env` template's inputs and `activate`, and no unit file; P3's
for llm-box finds the stripped drvPath unchanged.

**(b) The push.** arcade-box switches by itself. Proof:

```bash
ssh arcade-box 'journalctl -u homelab-deploy --since "-30min" --no-pager | tail -3
  systemctl show ac-host-ci -p ActiveEnterTimestamp --value
  grep -c "^S3_CACHE_ENDPOINT=http://flox-binary-cache:3900$" /run/secrets/rendered/ci-env
  grep -o "^S3_CACHE_ACCESS_KEY_ID=GK" /run/secrets/rendered/ci-env'
```

Expected: applied; the timestamp unchanged (nothing restarted); `1`;
`S3_CACHE_ACCESS_KEY_ID=GK`. The running agent still writes to MinIO.

**(c) Same session.** A reboot now would start the agent on Garage without
the final copy; if one happens, run the copy anyway, before anything else.

```bash
ssh arcade-box 'docker top ac-host-ci-agent-1 -eo args | grep -c "[b]uildkite-agent bootstrap"'     # 0, or wait
ssh arcade-box 'docker stop ac-host-ci-agent-1'       # no job writes to MinIO after this line
# 4.6(a) again, verbatim: the delta since the bulk copy, then check and sizes
ssh arcade-box 'cd /var/lib/ac-host/src/compose &&
  docker compose -f docker-compose.buildkite.yml -p ac-host-ci --env-file /run/secrets/rendered/ci-env config --quiet && echo CONFIG-OK'
ssh arcade-box 'systemctl restart ac-host-ci'       # record the time as T2
```

**(d) Proofs.**

```bash
ssh arcade-box 'systemctl is-active ac-host-ci; docker ps --format "{{.Names}} {{.Status}}" | grep ac-host-ci
  docker exec ac-host-ci-agent-1 printenv S3_CACHE_ENDPOINT
  docker exec ac-host-ci-agent-1 sh -c "printenv AWS_ACCESS_KEY_ID | cut -c1-2"
  docker exec ac-host-ci-agent-1 grep -c "endpoint=http://flox-binary-cache:3900" /etc/nix/nix.conf'
```

Expected: `active`; the agent and MinIO up; `http://flox-binary-cache:3900`;
`GK`; `1` (the baked read path). Then a probe written with the agent's own
environment -- nothing passed in:

```bash
ssh arcade-box 'exec docker exec -i ac-host-ci-agent-1 bash -s' <<'EOF'
for s in /etc/profile.d/nix*.sh; do [ -e "$s" ] && . "$s"; done
set -eu
f=/tmp/ci-cache-probe-$(date -u +%Y%m%dT%H%M%SZ)
printf 'ADR 0013 round trip, written with the agent environment\n' > "$f"
p=$(nix-store --add "$f"); rm -f "$f"
k=$(mktemp); trap 'rm -f "$k"' EXIT
( umask 177; printf '%s' "$S3_CACHE_SIGNING_KEY" > "$k" )
nix --extra-experimental-features nix-command copy \
  --to "s3://$S3_CACHE_BUCKET?endpoint=$S3_CACHE_ENDPOINT&region=$S3_CACHE_REGION&secret-key=$k" "$p"
echo "PROBE $p"
EOF
```

Call it `P2`; 4.6(c) for `P2` on arcade-box. The next real job logs `---
:flox: push complete`. After that job, MinIO received nothing:

```bash
ssh arcade-box 'find /var/lib/docker/volumes/ac-host-ci_minio-data/_data/flox-binary-cache -name xl.meta -newermt "<T2>" | wc -l'
```

Expected: `0`.

### 4.8 llm-box reads -- agent, verbatim

Needs 4.6(d), 4.7(d) and 4.0's second precondition. Nothing restarts the
model server here, so bead-loop's lanes run on. `SHA` is the full sha of
origin's main, which carries H1 and H2.

```bash
SHA=<full sha>
ssh llm-box "nixos-rebuild dry-activate --flake github:imkarrer/homelab/$SHA#llm-box" 2>&1 | tail -15
```

Expected: `nix-daemon.service` under "would restart", and no other unit
under stop, start, restart or reload -- nor any line naming
`agent-hub-llm.service`. Then:

```bash
ssh llm-box "nixos-rebuild switch --flake github:imkarrer/homelab/$SHA#llm-box"; echo "exit $?"
ssh llm-box 'grep -E "^substituters" /etc/nix/nix.conf; grep -c flox-binary-cache-2 /etc/nix/nix.conf
  getent hosts flox-binary-cache; curl -s http://flox-binary-cache:3902/nix-cache-info
  nix-store --realise --max-jobs 0 '"$P2"' && nix path-info --sigs '"$P2"'
  systemctl is-active agent-hub-llm nginx qdrant; systemctl --failed --no-legend | wc -l'
```

Expected: `exit 0`; the substituters end with `http://flox-binary-cache:3902`;
`1`; `192.168.1.50 flox-binary-cache`; the two lines of `nix-cache-info`;
`copying path '…' from 'http://flox-binary-cache:3902'` and `P2` signed
`flox-binary-cache-2`; `active` three times; `0`. The proof that matters
most arrives later and is recorded in section 7: the first agent-hub lock
that names a new `llama-cpp-*` is applied on llm-box by its pull, not
refused.

### 4.9 A week later: MinIO leaves (A3, H3, restart 3)

After section 6.1's week. A3 (3.1) through its 03:00 apply, H3 (3.4)
through arcade-box's deploy -- either order; restart 3 needs both.

- H3's proofs before the push: P1; P2's recipe for arcade-box names the
  images' removal, `unit-ac-host-ci.service`, `nix.conf` (MinIO's URL gone),
  `unit-nix-daemon.service`, the pull units (the refusal's text), the
  `ci-env` template, the sops manifest; no `ac-host-static`, no `docker`;
  P3's for llm-box names the pull unit and nothing else; `nix eval --json
  .#nixosConfigurations.arcade-box.config.warnings` has no
  `homelab-ygc.11` line.
- After arcade-box's switch: the deploy's journal shows `nix-daemon`
  restarted and `ac-host-ci` not (its changed unit waits, `restartIfChanged
  = false`).
- Restart 3: 4.5's three checks, then `systemctl restart ac-host-ci`. Proof:

```bash
ssh arcade-box 'docker ps -a --format "{{.Names}}" | grep -c minio; ss -tlnH | grep -cE ":900[01] "
  grep -E "^substituters" /etc/nix/nix.conf
  nix-store -qR /run/current-system | grep -c -- "-minio-"
  systemctl show ac-host-ci -p ExecStartPre --value | grep -c "docker load"'
```

Expected: `0`, `0`, no `127.0.0.1:9000`, `0`, `0`; the next job's push
completes.

### 4.10 The volume, the images, the retired keys -- agent, operator

On the operator's word (6.2):

```bash
ssh arcade-box 'docker image rm homelab/minio:nixpkgs homelab/minio-client:nixpkgs'
ssh arcade-box 'docker volume rm ac-host-ci_minio-data'
```

Proof: `ssh arcade-box 'docker volume ls -q | grep -c minio; df -h / | tail
-1'` -- `0`, and ~3.7 G back. The operator, from the tree's root so sops
finds `.sops.yaml`, with the file 3.5 names:

```bash
nix shell nixpkgs#sops nixpkgs#ssh-to-age -c bash -c '
  set -euo pipefail
  export SOPS_AGE_KEY="$(ssh-to-age -private-key -i ~/.ssh/id_ed25519_ac-host)"
  for k in minio-root-password s3-cache-secret-access-key; do sops unset secrets/<file>.yaml "[\"$k\"]"; done'
```

then commit and push: undeclared since H3, so the switch changes only the
encrypted file.

### 4.11 The tracker -- supervisor

- Close `homelab-ygc.20` after 4.10.
- New beads: native mode's MinIO (3.4's "Not here"; the native agent's
  cache is the same `garage.service`, at `http://flox-binary-cache:3900` on
  loopback); Garage's metrics in observability, if 6.4 says so; private
  trees' pushes, if 6.3 says so; `modules/deploy/default.nix` 195's comment,
  which assumes the closure is pushed to the cache (it never is: the bead's
  fact 5).
- `bd` memory `flox-environment-deploy-edge`: "MinIO is no substituter on
  the Z840" becomes "llm-box reads the CI cache from arcade-box, priority
  50".
- `docs/architecture.md` rows 42 and the new one closed.

---

## 5. Abort criteria and the rollback ladder

Stop -- not judge -- at any of these:

- **4.1**: a pushing step logs `no S3 cache configured`, or its push fails.
- **4.2**: the rendered config lacks the bridge or the host line, or shows
  an endpoint other than `http://minio:9000`.
- **4.3**: a length other than 64, 26, 64, or an id not starting `GK`.
- **4.4, before the push**: P2 or P3 names a derivation outside its list;
  P8's two drvPaths differ; anything in P2 named for `ac-host-static`,
  `docker` or `ac-host-ci`.
- **4.4, after**: `homelab-deploy` refuses or fails; `garage` or
  `ci-cache-init` not active; `nix-cache-info` without `Priority: 50`; any
  HTTP code from 3900 at llm-box; nothing from 3902 at WSL; `ac-host-ci`'s
  timestamp moved.
- **4.5**: before, the agent busy (wait), `CONFIG-OK` missing, or the bridge
  already there; after, no agent within 10 minutes, the name not
  `172.17.0.1`, anything but `403`, or the next push failing.
- **4.6**: differences found; sizes unequal; `nix-cache-info` changed; the
  probe's copy failing; arcade-box's realise not from
  `http://flox-binary-cache:3902`; any `FAIL` line.
- **4.7**: H2's diff names a unit; the render without the new endpoint;
  after restart 2, no agent within 10 minutes, any of the four values wrong,
  the probe or the first real push failing, or MinIO written to.
- **4.8**: dry-activate lists any unit but `nix-daemon.service`; the switch
  exits non-zero; a failed unit; the realise failing.
- **4.9**: H3's on-box activation restarts anything but `nix-daemon`; after
  restart 3, a MinIO container, a bound 9000, or a failed push.

Rollback, by how far it got:

- **Before 4.4's push.** Drop the branches. 4.1 and A1 are harmless to keep:
  no-ops.
- **After 4.4** (Garage beside MinIO; nothing writes it). Revert H1 and push
  -- CI is healthy, the agent still writes to MinIO. The switch stops and
  removes both units, the rules and the substituter. `/var/lib/private/garage`
  stays (ADR 0003) until removed by hand, if the ADR is abandoned.
- **After 4.5** (the agent on the named bridge). Nothing to undo: it still
  writes to MinIO. If the agent does not come back -- which also means no CI
  and no DOWNTIME build to deliver a revert of A1 -- put the previous compose
  file back and restart, then land A1's revert the same session, so that the
  next 03:00 apply agrees with the file on disk (the one hand edit in this
  ladder):

  ```bash
  git -C /home/nixos/src/ac-host show <A1's parent>:compose/docker-compose.buildkite.yml \
    | ssh arcade-box 'f=/var/lib/ac-host/src/compose/docker-compose.buildkite.yml; cat > "$f.tmp" && mv -f "$f.tmp" "$f" && systemctl restart ac-host-ci'
  ```

- **After 4.7** (the switch). Revert H2 -- three lines -- and push. If the
  revert's own build cannot go green because pushes fail, stage it by hand in
  exactly the record `scripts/hub-queue-closure.sh` writes, and let
  `homelab-deploy` apply it with its busy check and its gates (D5):

  ```bash
  REV=<the revert's full sha, on origin>
  printf '{"rev":"%s","flake":"github:imkarrer/homelab","queued_at":"%s","build":"","branch":"main","source":"runbook"}\n' \
    "$REV" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    | ssh arcade-box 'f=/var/lib/homelab/pending-closure.json; cat > "$f.tmp" && mv -f "$f.tmp" "$f"'
  ```

  Once `ci-env` is back -- `grep -c "^S3_CACHE_ENDPOINT=" /run/secrets/rendered/ci-env`
  prints `0` and `grep -o "^S3_CACHE_ACCESS_KEY_ID=flox-cache$"` finds the
  old id -- 4.5's checks and `systemctl restart ac-host-ci`: the agent writes
  to MinIO again. What was
  pushed to Garage in between is not in MinIO; each tree's next build pushes
  it again. Garage keeps running; llm-box, if already switched, keeps
  reading it.
- **After 4.8.** `ssh llm-box nixos-rebuild switch --rollback`, minutes;
  nothing on llm-box needs the reader until its next pull.
- **After 4.9, before 4.10.** Revert A3 and H3 (the MinIO images come back
  -- a Go compile of `minio` in arcade-box's deploy, a few minutes, since
  Hydra builds no insecure-marked package), restart: MinIO returns on its
  volume, without what went to Garage since T2.
- **After 4.10.** None to MinIO, by design. If Garage's data is ever lost,
  CI regrows it, and the unique paths return with their trees' next builds.

---

## 6. Open decisions -- the operator's, each with a recommendation

**6.1 MinIO's week.** Recommend seven days after 4.7(d), and at least one
green push from each tree that pushes (ac-host, agent-hub, home-arcade,
homelab, bead-loop, inquire-platform) landed in Garage. The leaked secret
stays valid on MinIO that long -- over loopback and the compose bridge, and
it cannot sign.

**6.2 The volume.** Recommend deleting it in 4.10, the day of 4.9. Once
MinIO's container is gone the volume is a cold copy whose IAM store keeps
the leaked secret and the root password in the clear
(`modules/platform/secrets.nix` 412-420), and a rollback to MinIO after a
week of Garage is not one anybody will want.

**6.3 Private trees in a LAN-readable cache.** Recommend accepting it: no
listing, and a store hash is 160 bits a reader must already know (ADR 0013,
Consequences). The alternative is `S3_CACHE_PUSH: "false"` in
inquire-platform's pipeline: its cold CI starts refill from the public
caches, and nothing on either host substitutes its paths anyway.

**6.4 Garage's metrics.** Recommend a bead after 4.9: an admin bind on
loopback, a metrics token in sops, a scrape job in observability.

---

## 7. As it ran

_One row per step: when (CDT), who, what happened, the proof's actual output
where it differed from the expected, and the plugin's `#main` sha at each
restart._

| When | Step | What happened |
| --- | --- | --- |
