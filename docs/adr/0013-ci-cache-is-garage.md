# ADR 0013: The CI Cache Is Garage, A Native Service Of The `ci` Tenant, Read Over The LAN

**Status:** Accepted, 29 Sep 2026 (`homelab-ygc.20`); proposed 28 Sep.
Nothing is implemented; `docs/runbook-ci-cache-garage.md` is the order, the
proofs and the rollback. Three calls are the operator's, made on 28 Sep
before this was drafted and recorded here rather than re-opened: **Garage 2
replaces MinIO**; **anonymous reads go through Garage's web endpoint**, which
serves llm-box over the LAN, read-only, as well as the host that runs it; and
**the writer gets fresh credentials**. The operator's answers to the review,
28-29 Sep, are the acceptance, and each is recorded where it decides
something (decisions 2, 3, 5, 6, 7 and 9, and Consequences). This ADR makes
the calls the first three leave -- where Garage runs, what the cache is
called, where it ranks among substituters, how a second host reads it --
with the evidence for each.

No pinned convention changes: `lan` is an existing scope and the set stays
four. Two practices widen, which is why this is an ADR: `garage-s3` is a
tenant claim declared `local` yet opened on a container bridge on the same
host, which narrows ADR 0004's "local: firewall-closed" to "not reachable off
the host" (decision 2); and `homelab.host.peers` comes to mean "scrapes or
reads from" (decision 6).

## Context

The Nix binary cache CI writes, and arcade-box and the agent read, is the
bucket `flox-binary-cache` in MinIO, a container in `ac-host`'s CI compose
project on arcade-box. MinIO's community edition is abandoned upstream and ships as
source only; nixpkgs marks `pkgs.minio` insecure -- six CVEs, two of them
unauthenticated writes through unsigned-trailer uploads -- and says to move to
Garage, SeaweedFS or Ceph. `homelab-ygc.11` kept the cache alive by building
`homelab/minio:nixpkgs` from the pin with the mark cleared on that image
alone, loopback-only, and its own header calls leaving MinIO a bead of its
own. At 13:25Z on 28 Sep the cache's write credential -- the MinIO user
`flox-cache`'s secret, sops `s3-cache-secret-access-key` -- entered an agent
transcript as the agent's `AWS_SECRET_ACCESS_KEY`; a scan of that transcript
by name and length found no other secret, the signing key included.

What the cache must keep doing, from the inspector's fact sheet in the bead
and the reads cited (28 Sep, read-only):

- **One writer.** The flox Buildkite plugin (`imkarrer/flox-buildkite-plugin`
  `c9f8570`) pushes after every step that has push on: `nix copy --to
  's3://flox-binary-cache?endpoint=…&region=us-east-1&secret-key=<file>'`
  (`hooks/post-command` 65, 83, 104), with the agent's own Nix -- flox
  1.16.0's 2.31.5 on aws-sdk-cpp 1.11.647, single PUTs carrying
  `STREAMING-UNSIGNED-PAYLOAD-TRAILER` and a CRC64NVME checksum. The hook runs
  under `set -euo pipefail` (line 2): a push that fails, fails the step.
- **Two readers today.** arcade-box's daemon, anonymously, at
  `http://127.0.0.1:9000/flox-binary-cache`; and the agent, through an `s3://`
  substituter baked into its image from compose's build args (`Dockerfile`
  53-66; the environment hook's own append is a no-op once that marker is
  present, `lib/environment.bash` 239).
- **llm-box needs it and cannot reach it.** agent-hub's lock (`9a55c11`)
  names `/nix/store/qn6qpywl…-llama-cpp-3bb386e`, the ik fork: in the bucket,
  signed `flox-binary-cache-2`, and in no public cache (404 on
  cache.nixos.org and cache.flox.dev) -- one of the 42 paths that exist
  nowhere else. llm-box's environment pull realises every lock output
  substitute-only (`modules/tenant/environment-pull.nix` 525-547), so the
  next ik build agent-hub's lock names would be refused there; MinIO is
  published on arcade-box's loopback only.
- **It is asked first, by accident.** The bucket's `nix-cache-info` is
  `StoreDir: /nix/store` and nothing else, so Nix gives it priority 0, ahead
  of cache.nixos.org (40) and cache.flox.dev (41). Measured, not inferred:
  root's `binary-cache-v7.sqlite` on arcade-box records
  `http://127.0.0.1:9000/flox-binary-cache|0` beside `|40` and `|41`.
  `modules/ci/default.nix` 698-702 says the opposite -- `mkOrder` orders the
  list, and Nix sorts by priority first.

The server, as the operator chose it: `pkgs.garage_2` is 2.3.0 at the pin;
`pkgs.garage` is 1.3.1, which answers the agent's uploads with `400 invalid
checksum algorithm` (CRC64NVME). SeaweedFS stores `Content-Encoding:
aws-chunked` on an object written that way, and every later read of it
fails; its 4.36 is under a critical advisory. Ceph is a distributed store;
this is one bucket on one disk.

**Proven for this ADR** on WSL, 28 Sep, with the pinned `garage_2` (2.3.0),
the agent's own Nix (flox 1.16.0's 2.31.5), the hosts' Nix (2.34.8) and the
pinned rclone (1.75.0). The bead's research had used Garage 2.4.1.

| What | Result |
| --- | --- |
| The writer | flox's Nix 2.31.5 `nix copy --to s3://…` accepted, a 60 MiB NAR in one PUT among them (293 ms) |
| The web endpoint, by `Host` | `flox-binary-cache` and `flox-binary-cache:<port>` → 200 (the bucket's global alias; the port is stripped); `flox-binary-cache.<root_domain>` → 200; an IP → 404; path-style `/flox-binary-cache/…` → 404 |
| What the web endpoint refuses | PUT and DELETE → 400; `GET /` → 404 NoSuchKey, so no listing; a missing key → 404 on GET and on HEAD |
| The S3 API, anonymously | 403 |
| A reader | Nix 2.34.8 substituted the 60 MiB path through the web endpoint into a chroot store, signature and hash checked, byte-identical; with an untrusted key it refused: "lacks a signature by a trusted key" |
| `nix-cache-info` | without one a reader refuses the URL: "does not appear to be a binary cache". A writer whose disk cache already knows `s3://flox-binary-cache` does not create one: the S3 store skips its init for a cached URI, and the cache key omits the endpoint (Nix 2.31.2 `s3-binary-cache-store.cc` 283-295, the same lines in the agent's 2.31.5). A cold writer writes `StoreDir` alone (`binary-cache-store.cc` 49-50), which is how MinIO's 5 Sep file came to be. PUT through the S3 API (curl `--aws-sigv4`, credentials on a file descriptor) it is served, and Nix records its `Priority` (the prototype's 50, in the `priority` column of `binary-cache-v7.sqlite`) |
| An unreachable cache, `fallback` off | reproduced in review, 28 Sep, with the pinned 2.34.8 against a dead localhost cache: asked last (Priority 50) → `unable to download '…narinfo'`, exit 1; asked first (Priority 10) → the error logged, the build proceeds |
| Provisioning | `garage server --single-node --default-bucket` with `GARAGE_DEFAULT_{ACCESS_KEY,SECRET_KEY,BUCKET}` makes the layout, the key and the bucket, the key `RWO` on it; a restart re-runs it harmlessly; `bucket website --allow` is idempotent; `[s3_web]` without `root_domain` is a parse error |
| Key ids | 8 characters or more (`fc`: "Key identifiers should be at least 8 characters long"); `GK` + 24 hex is Garage's own form |
| A changed secret for an existing key id | the server refuses to start: "Access key GK… is associated with a secret key different than the one given in GARAGE_DEFAULT_SECRET_KEY" |
| A new key id at restart | created and given `RWO` on the bucket; the old key keeps working until `garage key delete`, then 403 |
| The copy | `rclone sync --metadata --checksum --exclude /nix-cache-info` keeps the destination's `nix-cache-info` and deletes what the source lacks; `rclone check` finds 0 differences. The research ran the same copy MinIO → Garage with the real bucket and substituted from the result |
| Settings | `metadata_fsync`, `data_fsync`, `metadata_auto_snapshot_interval`, `compression_level = "none"` accepted without a warning |

## Decision

### 1. Garage 2, one node, from the pin

`services.garage`, nixpkgs' module, with `package = pkgs.garage_2` -- never
`pkgs.garage`, whatever a later pin makes of that name. Its settings:

```toml
replication_factor = 1
db_engine = "lmdb"
metadata_fsync = true                    # a few pushes a day: fsync costs nothing, and a power
data_fsync = true                        # cut must not leave a narinfo naming a torn NAR
metadata_auto_snapshot_interval = "6h"   # LMDB is one file; a snapshot is its way back
compression_level = "none"               # every NAR is xz already
rpc_bind_addr = "127.0.0.1:3901"
rpc_public_addr = "127.0.0.1:3901"

[s3_api]
s3_region = "us-east-1"                  # what every S3_CACHE_REGION says; the two must match
api_bind_addr = "0.0.0.0:3900"

[s3_web]
bind_addr = "0.0.0.0:3902"
root_domain = ".web.localhost"           # required; no reader goes through it
```

No `[admin]` section: the `garage` CLI speaks RPC, so there is no admin token
to hold. The server runs `garage server --single-node --default-bucket` (an
`ExecStart` override of the module's plain `garage server`, from the same
`services.garage.package`, never a second copy of the package), with
`GARAGE_DEFAULT_BUCKET=flox-binary-cache` in the unit's environment and
`GARAGE_RPC_SECRET`, `GARAGE_DEFAULT_ACCESS_KEY` and
`GARAGE_DEFAULT_SECRET_KEY` from a sops-rendered env file. A oneshot beside
it, `ci-cache-init.service` (`PartOf=garage.service`, so it re-runs with every
restart), does what the flags do not: `bucket website --allow`, the
`nix-cache-info` PUT (decision 5), and a read of that file back through 3902.

### 2. A native service on the host that runs `ci`, not a container beside the agent

Garage is `garage.service` on arcade-box -- the host whose tenants include
`ci` -- and a unit of that tenant, not a service in `ac-host`'s compose
project where MinIO runs. The reasons, strongest first:

1. **The LAN port has to be one the registry enforces.** `ports.nix` turns a
   claim's scope into `nixos-fw` rules on the INPUT path, per interface; on
   arcade-box every port the registry opens is an `-i eno2 --dport N` rule
   (`iptables -S nixos-fw`, 28 Sep). Docker publishes a port with a DNAT in
   the nat table's `DOCKER` chain and accepts it in `FORWARD` (`DOCKER-USER`,
   `DOCKER-FORWARD`) -- before `nixos-fw` sees the packet; MinIO's two
   loopback publishes are exactly such rules today. A containerised Garage's
   3902 would be `scope = "lan"` in the registry and whatever the compose
   file's publish line says on the wire, and nothing this repo evaluates
   could catch a `3902:3902` that binds every interface. It would also be
   the first Docker-published LAN port on the platform: the nat table's
   `DOCKER` chain holds MinIO's two loopback rules and nothing else, so every
   LAN port today is a host socket.
2. **The cache's availability stops being the agent's.** `systemctl restart
   ac-host-ci` is `down` then `up -d --build`. The one of 28 Sep (04:24-04:29
   CDT) removed the agent, MinIO and the network, rebuilt the agent image
   from the plugin's moving `#main` for five minutes, and only then created
   containers: compose builds before it creates, so a failed agent build
   leaves no cache either, and llm-box's reads would fail with CI. (Not the
   MinIO-only recreate `modules/ci`'s HAZARD 2 and IMAGES describe, 120-128
   and 197-205; the runbook's H1 corrects them.)
3. **Garage's fixes arrive with the closure.** A pin move that changes
   `garage_2` restarts `garage.service` at that switch -- `ci` is drainable,
   and a re-queued push is not an outage (AGENTS.md). In the compose shape a
   new image waits in the store for a deliberate restart that recreates the
   agent (HAZARD 2), the arrangement that kept MinIO's image behind the pin
   until 28 Sep. `garage_2` is in cache.nixos.org: no dockerTools image, no
   `docker load`, no compile.
4. **Its slice is the contract's.** `garage.service` in `ci.units` gets
   `batch.slice` and `Nice=19` at `mkOverride 90`; nixpkgs' module sets no
   `Slice=` (read at the pin), so nothing ties. No `cgroup_parent` for
   another tree to remember (ADR 0005).
5. **The cache no longer depends on how the agent is delivered.** Native
   mode (ADR 0011, off) and the compose shape reach the same unit, and
   ADR 0012's ci-box enables the same module.

The cost is the writer's path. The agent is a container on the project's
bridge, and nothing on arcade-box admits a bridge: `nixos-fw` has no rule
for any `br-*` or `docker0`, and the project's bridge is renamed at every
restart (`down` removed `ac-host-ci_default` at 04:24:13; `up` created
`br-d12f03aec340` at 04:29:46). Three small pieces make the path:

- `ac-host`'s compose pins the bridge's name --
  `networks.default.driver_opts."com.docker.network.bridge.name":
  br-ac-host-ci` (13 of Linux's 15 characters; no such interface on
  arcade-box today).
- The agent maps the cache's name to its host -- `extra_hosts:
  ["flox-binary-cache:host-gateway"]`, docker0's `172.17.0.1`; the packet
  arrives on `br-ac-host-ci` and is delivered through INPUT.
- `modules/ci` opens 3900/tcp on `br-ac-host-ci` and nowhere else
  (`networking.firewall.interfaces.br-ac-host-ci.allowedTCPPorts`), beside
  the registry, not through it. `garage-s3` stays a registry claim at scope
  `local`, so a collision is still caught, and this opening is a named
  exception to what `local` has meant: ADR 0004 defines it as "bound to
  127.0.0.1, firewall-closed", and `ports.nix` derives no rule for it; for
  this one claim it narrows to "not reachable off the host" (the operator,
  on review). A bridge between a container and its own host is neither the
  LAN nor the management network, so no scope describes it, and one opening
  does not earn a fifth (below). `modules/platform/node-exporter.nix` (12-25,
  103) is the nearest precedent -- one interface, never global, its reason
  written where the rule is -- and not the same case: its port is nobody's
  tenant on its host, while 3900 is `ci`'s and in the registry. So the
  reason is written on the claim as well, in `tenants.nix`, the way
  `alertmanager-mesh`'s is (520-523).

Rejected with it: a Garage container with `network_mode: host` (the
firewall stays honest, but it keeps costs 2 and 3 and adds this path
anyway); a container plus a native socket proxy for 3902 (fixes cost 1 and
keeps the rest); a fifth port scope for the bridge (the scopes are pinned,
and one opening does not earn a contract change -- the second tenant that
needs a container-to-host port is the moment); llm-box as the cache's host
(ADR 0010: it serves models and nothing else).

### 3. One name, two ports

The bucket's own name, `flox-binary-cache`, is the cache's hostname for
every client:

| Client | The name resolves through | It uses |
| --- | --- | --- |
| the agent, writing and reading | `extra_hosts` → `172.17.0.1` | `http://flox-binary-cache:3900`, S3, with the Garage key |
| arcade-box's daemon | `/etc/hosts`: `127.0.0.1 flox-binary-cache` | `http://flox-binary-cache:3902`, anonymous |
| llm-box's daemon | `/etc/hosts`: `<homelab.host.peers.arcade-box.address> flox-binary-cache` | `http://flox-binary-cache:3902`, anonymous |

Why the bucket's name: the web endpoint chooses the bucket from the `Host`
header -- the header less `root_domain` when it ends with it, otherwise the
whole header as a global bucket alias, the port stripped -- and a bucket's
name is its global alias. So the name every reader must resolve anyway is
the one Garage routes on: no second alias to create and keep, and the
substituter URL says what it serves. A `.localhost` name (the research's
`flox-binary-cache.web.localhost`) would work on arcade-box alone:
`*.localhost` is the local machine by definition (RFC 6761), and
nss-myhostname answers it that way on both hosts (`getent hosts
x.web.localhost` → `::1`), so on llm-box it would name llm-box.

**Renamed at once; no transitional `minio` alias** (the operator, on
review). What an alias would have saved is small or already paid. The
agent's image is rebuilt from `#main` at every start of `ac-host-ci` anyway,
so a changed build arg costs the layers after it. And the five pipeline
files that spell `http://minio:9000` stop naming the cache at all before the
switch: their `S3_CACHE_*` blocks restate the agent's own defaults exactly,
and the plugin reads the agent's environment when a pipeline is silent --
its own advice, "cache identity is cluster-wide -- do not make every step
repeat it" (`lib/environment.bash` 199-200). What an alias would have cost:
here, `minio:9000` means a host port that MinIO's publish holds
(`127.0.0.1:9000`) for the whole side-by-side period, so it could appear
only by moving Garage's port at the switch; and after that, a name that says
MinIO for a server that is not, until someone edits the same files anyway.
After the preparation the endpoint lives in compose's build arg and agent
default (one file, a fallback for a stack started by hand) and in `ci-env`'s
`S3_CACHE_ENDPOINT`, which the switch sets.

The cost of no alias: a branch cut in `ac-host`, `agent-hub` or
`home-arcade` before its pipeline stopped naming the cache (runbook 4.1)
still says `http://minio:9000`, and its next push fails once the agent holds
the Garage key (runbook 4.7: MinIO refuses the key) and for good once the
name is gone (4.9). On origin on 29 Sep: `ac-host` `ci-cache-probe` and
`ci-smoke`, `agent-hub` `claude/work-your-beads-74e362` and
`coder-two-slots`. Each is rebased or closed before the switch.

### 4. The ports, and what the LAN port can do

| Claim (`ci`) | Port | Scope | Bound |
| --- | --- | --- | --- |
| `garage-s3` | 3900/tcp | `local` | `0.0.0.0`; nothing opens it on `eno2`; `modules/ci` opens it on `br-ac-host-ci` alone (decision 2's named exception) |
| `garage-rpc` | 3901/tcp | `local` | `127.0.0.1` |
| `garage-web` | 3902/tcp | **`lan`** | `0.0.0.0`; the registry opens it on `eno2` |

A wide bind with a narrow scope is `alertmanager-mesh`'s precedent
(`hosts/arcade-box/tenants.nix` 520-528: the scope describes what the
platform exposes, not the bind address). `lan`, not `forwarded`: nothing
forwards 3902 and nothing should; the router's forwards are hand-set per
lobby slot (ADR 0004).

What the LAN port can do, proven: GET and HEAD of a key the client names.
PUT and DELETE are refused; there is no listing -- MinIO's anonymous policy
did list: a GET of the bucket on arcade-box's loopback returned a 357,585-byte
listing on 28 Sep. The S3 API refuses anonymous requests and is not on the
LAN at all. What it serves is what MinIO's anonymous-download policy served,
widened from loopback to the LAN: signed NARs and narinfos. Readers check
the signatures (`require-sigs = true` on both hosts).

### 5. Priority 10, written down

`nix-cache-info` is two lines, `StoreDir: /nix/store` and `Priority: 10`,
from a file in git, PUT by `ci-cache-init` at every start of
`garage.service`. Asked first -- before cache.nixos.org (40) and
cache.flox.dev (41), where MinIO's missing `Priority` puts it today by
accident -- because an unreachable cache can fail a build only when it is
asked last (the operator, on review):

- Both hosts run `fallback = false`, Nix's default (`nix config show` on
  each, 29 Sep). Nix 2.34.8 asks the substituters in priority order, logs an
  earlier one's error and clears it when it asks the next
  (`src/libstore/build/substitution-goal.cc` 49-53), and rethrows the error
  it still holds when no substituter had the path (147-150). The last
  cache's error is fatal; every earlier one's is a log line.
- Asked last -- Priority 50, this ADR's first draft -- and unreachable, the
  cache would fail every build of a substitutable derivation no public cache
  has: llm-box's whenever arcade-box is down, arcade-box's whenever
  `garage.service` is, `homelab-deploy`'s build of a fix included. The
  review reproduced it (Context, the table).
- Written down, not left to whoever uploads first: without a
  `nix-cache-info` an HTTP reader refuses the URL outright ("does not appear
  to be a binary cache", proven), and the one writer writes one only on a
  cold cache, never with a `Priority` (Context, the table) -- MinIO's file
  of 5 Sep is such a write. And it makes `modules/ci`'s comment true: its
  698-702 credit `mkOrder`, and `Priority` is what orders the list.

The cost is time, not failure. Every lookup of a path the narinfo disk cache
does not hold asks this cache first: one 404 from arcade-box for what only
the public caches have. While the cache is unreachable, each such lookup
waits out the failure before moving on: Nix disables a failing HTTP cache
for 60 s only when fallback is on (`http-binary-cache-store.cc` 94-103), and
it retries a connection error `download-attempts` (5) times with backoff
from 250 ms (`filetransfer.cc` 747-751). Read from the source, not measured:
four to five seconds a lookup while arcade-box refuses the connection, up to
five `connect-timeout`s (15 s) while nothing answers at all.

The agent is not covered by this. Its Nix, flox 1.16.0's 2.31.5, rethrows a
substituter's error at once when fallback is off, whatever its priority
(`substitution-goal.cc` 90-95 there): a job whose Nix queries the cache
while `garage.service` is down fails (Consequences).

Nix caches a substituter's `nix-cache-info` per URL (`binary-cache-v7.sqlite`),
which is why the copy never overwrites the file (`--exclude /nix-cache-info`)
and why no reader keeps MinIO's URL for Garage.

### 6. Every reader through one half of `modules/ci`

`modules/ci` gains a reader half that a host can import alone, with one
setting, `homelab.ci.cache.readFrom = "<host>"` -- the host that runs the
cache. From it the reader derives the substituter
`http://flox-binary-cache:3902`, trusts `flox-binary-cache-1` and `-2` (both
stay: the bucket's narinfos carry 440 signatures by `-1` and 755 by `-2`, 31
by `-1` alone -- the bead), and writes one `/etc/hosts` line: loopback when
`readFrom` is this host, else `homelab.host.peers.<readFrom>.address`, never
an address typed again. The reader half is the one place the two keys are
set: `modules/ci`'s server half sets them today (707), and they move, so
`nix.conf` lists them once. arcade-box gets it with `modules/ci`; llm-box
imports the reader alone, and trusting the keys there is the operator's call
(on review), its cost under Consequences. Not a platform module:
`modules/platform` knows nothing about tenants (README, layers), and the
cache is `ci`'s.

llm-box's `readFrom = "arcade-box"` needs its first peer: `hosts/llm-box/
host.nix` imports `../arcade-box/host.nix` for the address, as arcade-box's
imports llm-box's (the two imports are lazy and do not loop -- checked with a
pure-Nix pair of the same shape). `homelab.host.peers` then means "another
homelab host this one scrapes or reads from" (the operator, on review), and
llm-box declares one it scrapes nothing from; the option's description and
CONTEXT.md's **Peer** say so in the same change.

What llm-box gains: agent-hub can move its ik build. The next
`llama-cpp-*` its lock names is pushed by CI, and the Z840's substitute-only
pull fetches it from arcade-box over the LAN instead of refusing it.

### 7. Fresh credentials, and rotation is a new key id

Three new sops keys, nothing reused:

| sops key | Format | Read by |
| --- | --- | --- |
| `garage-rpc-secret` | 64 hex characters | `garage.service` (`GARAGE_RPC_SECRET`); the root-only `garage` CLI |
| `garage-s3-key-id` | `GK` + 24 hex characters | `garage.service` (`GARAGE_DEFAULT_ACCESS_KEY`); the agent from the switch on (`S3_CACHE_ACCESS_KEY_ID`) |
| `garage-s3-secret-key` | 64 hex characters | `garage.service` (`GARAGE_DEFAULT_SECRET_KEY`); the agent (`S3_CACHE_SECRET_ACCESS_KEY`) |

The key id is not a secret, and it lives in sops anyway, so that id and
secret change in one sops session. Garage requires that: a changed secret for
an existing id stops the server from starting, and a new id is created and
given the bucket while the old one keeps working until it is deleted (both
proven). A rotation is therefore, in this order: a new pair; a switch (the
template's `restartUnits` restarts `garage.service`, which creates the new
key; `ci-env` re-renders with it); the agent bounced from ssh when idle, so
that it holds the new pair; and only then `garage key delete --yes <old id>`.
Deleting first fails every push until the bounce.

The leaked MinIO secret retires with MinIO. It is valid only on MinIO --
loopback and the compose bridge -- and a write with it is not a path anyone
substitutes: a narinfo needs a signature by `flox-binary-cache-1` or `-2`.
It stays valid until MinIO leaves (decision 9). MinIO's volume is deleted
the day MinIO leaves, because its IAM store holds that secret and the root
password in the clear (the operator, on review); the two sops keys,
`s3-cache-secret-access-key` and `minio-root-password`, go after it.
`tenants.nix`'s `s3-cache-access-key-id`, a name sops never had, goes with
Garage's arrival.

### 8. State: where the module keeps it, declared, not backed up

Garage keeps its data where nixpkgs' module does -- `StateDirectory=garage`
under `DynamicUser`, so `/var/lib/private/garage/{meta,data}`, with
`/var/lib/garage` a link to it. The `ci` tenant declares it
(`observability`'s precedent for a nixpkgs module's own path), after the
tenant's derived `/var/lib/ci`, because `modules/tenant/environment.nix`
247-249 derives native mode's `environment.dir` from the first entry
(`assetto`'s precedent, `hosts/arcade-box/tenants.nix` 204-215). `backup =
false`: 3.7 GiB that CI regrows, and losing it costs recompiling the unique
paths (the ik fork, under `batch`'s `MemoryMax` at `cores = 2`), not data.
From the first switch ADR 0003 applies: the path is state and stays put.

### 9. Beside, copy, prove, switch, then remove

Garage comes up beside MinIO with nothing writing to it; the bucket is
copied (`rclone sync`); a probe written from inside the agent with the new
key is realised substitute-only on arcade-box and hash-checked on llm-box;
only then does the writer switch -- three lines of `ci-env` -- after a final
copy with the agent stopped. MinIO stays as the rollback target, receiving
nothing, for seven days after the switch is proven and until every
repository whose pipeline pushes has pushed green to Garage (the operator,
on review); then it leaves, and its volume the same day: the compose
services, `modules/ci`'s two images, their `knownVulnerabilities` override
and its evaluation warning. The three `systemctl restart ac-host-ci` this
takes are the only disruptive steps, each from ssh with no `buildkite-agent
bootstrap` in the agent (HAZARD 2). Native mode's MinIO pieces are a
follow-up bead: the flag is off, they are not in the closure
(`nativeOffIsCompose`), and their MinIO is the ci environment's catalog
package, not the pin's image the override covers.

## Consequences

- **The LAN gains one port on arcade-box, read-only, and llm-box asks it
  first.** llm-box gains a dependency on arcade-box at run time. For the
  paths no public cache has it is the only source: while arcade-box is down,
  a pull that needs one leaves its record staged and tries again at its next
  firing -- where today it could never succeed. For everything else it is a
  delay: each uncached lookup waits out arcade-box's failure before a public
  cache answers (decision 5).
- **Any job on the agent can sign what llm-box substitutes.** llm-box trusts
  `flox-binary-cache-1` and `-2` (decision 6), and every job on the agent
  holds `S3_CACHE_SIGNING_KEY`: any job of any repository the agent builds, a
  branch or a pull request, can sign a path llm-box will substitute, as
  arcade-box already does. What bounds it is who can start a job there. Six
  of the seven repositories the agent builds are public, and on 29 Sep all
  eight pipeline objects in its cluster refused builds from forks
  (`build_pull_request_forks: false`); the runbook reads that again before
  starting (4.0).
- **The bucket becomes readable on the LAN by anyone holding one store
  hash, and a hash opens a closure, not a path**: each narinfo's
  `References` names the paths it depends on, and each of those is fetched
  the same way. There is still no listing. The bucket holds every
  environment CI activates with push on -- by the agent's default the
  private `inquire-platform` repository's among them (its pipeline sets no
  push setting; the bucket holds 21 `environment-dev` and 20 `manifest`
  outputs). The operator accepted that on review for what those are: at
  `inquire-platform` `1f1c9a9`, catalog packages plus its manifest text --
  two non-secret variables and an `on-activate` hook. A repository that
  wants its outputs off the LAN sets `S3_CACHE_PUSH=false`.
- **HAZARD 2 stops covering the cache; the agent still depends on it.**
  Garage restarts like any drainable unit; the agent's restarts are still
  HAZARD 2, and the migration needs three. The other direction stays: a job
  whose Nix queries the cache while `garage.service` is down fails (the
  agent's 2.31.5, decision 5), and a restart of Garage at a switch is
  enough. `ci` is drainable: that is a job to run again, not an outage.
- **A failed `garage.service` alerts.** llm-box's pulls depend on it, so the
  implementation adds a failed-unit rule beside `PracticeLobbiesFailed`, on
  `node_systemd_unit_state`, which the `node` job already scrapes and keeps.
  Garage's own metrics are a later bead (the operator, on review).
- **arcade-box's closure gains `garage` (substituted) and loses `minio`**
  -- a Go compile at every pin move, since Hydra builds no insecure-marked
  package -- and the warning `homelab-ygc.11` added.
- **Rotation is a runbook step** (decision 7), not a switch alone.
- **ADR 0012 is superseded in part, and not edited.** The draft `ci-box` ADR
  (Proposed 20 Sep 2026, epic `homelab-bfq`) is not in git; it lives
  untracked in the registry checkout, at
  `.claude/worktrees/buildkite-workstation-runners-faf041/docs/adr/0012-ci-box-is-a-dedicated-host.md`.
  This ADR supersedes two of its decisions, as the operator ruled on
  review: 3, "MinIO stays exactly where CI runs" with `minio-api` at scope
  `lan`, and 4, an unconditional, platform-level substituter in
  `modules/platform/nix.nix`. That file is left as it is; whoever lands 0012
  points those two decisions here. The cache is `garage.service` on
  whichever host runs `ci`, only the web endpoint is on the LAN, and a
  reader names that host in `readFrom`. Moving it is an `rclone sync` Garage
  to Garage and one `readFrom` per reader. Whether an agent on another host
  writes to it -- the S3 API would then need a LAN scope of its own -- is
  ADR 0012's to decide.

## What this does not decide

- Garage's own metrics in observability (the admin API's `/metrics` needs a
  bind and a token): a bead of their own, after MinIO leaves. Until then the
  failed-unit alert is the cache's one signal.
- Native mode's cache: the follow-up bead points it at the same unit.
- Whether the agent's Nix gets `fallback = true` (`ac-host`'s compose
  `NIX_CONFIG`), so that a job builds rather than fails while the cache is
  unreachable -- at the price of compiling what the cache would have served.
