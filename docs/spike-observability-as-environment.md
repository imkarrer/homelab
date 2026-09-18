# Spike: could observability run as a flox environment? (homelab-158.7, ADR 0009 step 5)

**Verdict: stays NixOS.** The mechanism works — a `[hook]` renders a promtool-checked
`prometheus.yml` from `/etc/homelab/tenants.json` at activation, the render survives,
a bad render fails the unit loudly — so this is "could move, with X" on mechanics. But
X is long and the payoff is one scrape job: the contract-derived part of the module is
smaller than the ADR assumed, and everything else the module does is either static
text or hardening that a flox activation degrades. Evidence below; WSL, flox 1.14.1,
18 Sep 2026; no git tree touched, no ssh. Throwaway env under `scratchpad/spike-observability/env`.

## 1. What `modules/observability` generates, and from what

Evaluated from `.#nixosConfigurations.ac-box` (`units.json`, `eval2.json` beside this file).

| Generated artefact | Contract / host options read | Static content |
| --- | --- | --- |
| `prometheus.yml` (store path, `promtool check` at *build*; baked into `ExecStart`) | `metrics.nix`: every enabled tenant's `metricsEndpoint` (`job`, `address`, `port`, `path`, `interval`), asserting `address` against `homelab.host.networks.*.address`. **Today that is one job: `agent-hub` → `192.168.1.50:8100`.** | The other five jobs (`node`, `cadvisor`, `unpoller`, `udr-fw`, `docker-names`) are hand-written in `default.nix` with `metrics = null` in `tenants.nix`; the `metric_relabel_configs` and the 110-line alert-rules block are literal text. |
| `alertmanager.yml` → `envsubst` to `/tmp/alert-manager-substituted.yaml` in `ExecStartPre` (nixpkgs) | `discordWebhookFile` path only | route/receiver literals |
| `grafana.ini` (`-config <store path>`) + provisioning dir (`datasources/`, `dashboards/` YAML) | `homelab.host.networks.lan.address` → `http_addr`, `domain`, `root_url`; `$__file{}` paths for admin password and `secret_key` | datasource `127.0.0.1:9090`; provider path = store copy of `grafana-dashboards/overview.json` (437 lines, keyed on the five hand-written jobs) |
| `unpoller.json` (`--config <store path>`) | `homelab.host.unifi.address` → `url`; `unpollerPassFile` | everything else |
| `udr-fw-exporter` `Environment=` | `unifi.address` → `UNIFI_HOST`; `UNIFI_PASS_FILE` | bind, poll interval; script `udr_fw_exporter.py` (223 lines) |
| `docker-name-exporter` `Environment=` | none | all literal; script `docker_name_exporter.py` (131 lines) |
| `node_exporter`, `cadvisor` flags | none | collectors, docker socket paths |

Two facts that reshape the question. (a) **`/etc/homelab/tenants.json` does not carry
`metrics`**: `quiet.nix`'s `toEntry` emits `name, tier, units, quiet, ports, portRanges`
(confirmed in `eval2.json`); a hook cannot render scrape jobs from it today without a
one-line schema-preserving addition. (b) The contract-derived surface is one scrape job
plus two host addresses (LAN, UniFi) and four secret paths — everything the stub already
passes as environment variables for agent-hub.

## 2. Where each piece would live in a manifest world

| Piece | Home | Note |
| --- | --- | --- |
| scrape jobs from `metricsEndpoint` | `[hook]` rendering from `tenants.json` (+`metrics` key) into a dir the stub names | tested below |
| the five hand-written jobs, relabels, alert rules | checked-in `prometheus.rules.yml` / a `prometheus.yml.tmpl` in the tenant tree; hook concatenates | pure text move; `promtool check` moves from build time to activation time |
| `grafana.ini` | hook renders from `OBS_LAN_ADDR`, `OBS_GRAFANA_ADMIN_FILE`, … | `$__file{}` literals survive a hook untouched |
| dashboards, provisioning YAML | checked-in files; provider `path` = `<dir>/grafana-dashboards` | needs the tree at a sha, not a FloxHub generation ("Beyond the six") |
| `alertmanager.yml`, `unpoller.json` | hook renders from `OBS_UNIFI_URL`, secret paths | nixpkgs' `envsubst` step is exactly a hook already |
| the two Python exporters | checked-in; `command = ["python3", "<dir>/scripts/…"]` | stdlib-only, nothing to install |
| `[build]` target | **nowhere useful** | a build output cannot be installed into the same environment without `flox publish` (findings, ybm); a build cannot read `/etc` anyway |
| ports, tier/slice, quiet, state dirs, secret names, `needsDocker` | **NixOS** (`tenants.nix`) | unchanged by the ADR |
| the eight unit stubs, `User=`, hardening, `ConditionPathExists`, restart triggers | **NixOS** — see §5 | |

All eight binaries are in the catalog: `prometheus@3.14.0`, `prometheus-alertmanager@0.33.1`,
`grafana`, `prometheus-node-exporter`, `cadvisor`, `unpoller`, `python3`, `jq`.

## 3. The mechanism, tested (`env/.flox/env/manifest.toml`, fixture `tenants.json` with a `metrics` key added)

| # | Experiment | Result |
| --- | --- | --- |
| T1 | hook: `jq` renders `$OBS_CONFIG_DIR/prometheus.yml.new` from `$OBS_TENANTS_JSON`, `promtool check config`, `mv`; `flox activate -- sh -c 'cat …'` | exit 0; two jobs rendered (`agent-hub` 192.168.1.50:8100, `freeciv` with `metrics_path: /stats`), promtool `SUCCESS` |
| T2 | hook `echo` to stdout vs stderr | **hook stdout is redirected to stderr**; both reach the caller (the journal, under a unit); the command's stdout is clean |
| T3 | JSON unreadable / promtool rejects `"thirty"` | `✘ ERROR: Running hook.on-activate failed`, **exit 1, the command never runs**; the previous good `prometheus.yml` is left in place (`.new` + `mv`) |
| T6 | hook `exit 7` | activation exits **1**, not 7 — the hook's code is collapsed |
| T4 | persistence: 3 activations, `rm -rf .flox/run`, a manifest edit | `FLOX_ENV_CACHE = <dir>/.flox/cache`, ext4, survives all three; re-rendered every activation (new inode each time); second activation incl. render **128 ms** |
| T4a | `OBS_TENANTS_JSON` unset (dev shell on WSL) | hook defaults to `/etc/homelab/tenants.json`, absent → exit 1. The default is load-bearing exactly as findings §Beyond-the-six warned |
| T5 | `flox activate -- sh -c 'exec prometheus --config.file=$OBS_CONFIG_DIR/prometheus.yml …'` | ready in ~1 s; `/api/v1/targets` shows `agent-hub` `http://192.168.1.50:8100/metrics`; `/api/v1/status/config` = the rendered file; `SIGTERM` to the pid → prometheus exits gracefully, exit 0, no orphan (`ps`: the pid *is* prometheus, `exec`'d) |
| T7 | `.flox/cache` read-only | hook fails (exit 1); pointing `OBS_CONFIG_DIR` at another writable dir (what `RuntimeDirectory=` gives) works |
| T8 | `.flox/` read-only | **`✘ ERROR: Permission denied (os error 13)`, exit 1.** Bisected: `.flox/log/` must be writable — flox writes `executive.<pid>.log` (1.3 KB) on **every** activation; 27 files after 27 activations, none pruned. `run/`, `cache/`, `env/` read-only are fine |

T8 is the finding that matters for this tenant. agent-hub's stub is fine because
`User=agent-hub` owns the checkout. Here the eight units run as **five different
identities** (`prometheus`, `grafana`, `node-exporter`, `unifi-poller`, and
`DynamicUser=yes` for alertmanager) — so one shared environment dir needs `.flox/log`
group-writable to a group all five carry, DynamicUser's uid is unknown until start, and
`ProtectSystem=strict` (alertmanager, node-exporter) makes the checkout read-only unless
`ReadWritePaths=` names `.flox/log` — a hardening exception for a log nobody reads. Plus
one log file per `Restart=` attempt, unbounded.

## 4. Secrets (ADR question 4)

Nothing changes in the manifest world, and nothing needs a manifest feature. Every reader
takes a **path**: Grafana `$__file{/var/lib/monitoring/secrets/grafana-admin}`, alertmanager
`webhook_url_file`, unpoller `pass`, `UNIFI_PASS_FILE`. sops-nix keeps installing the four
symlinks; the stub passes the paths as variables; the hook writes them into the rendered
config as literals. `flox activate` inherits the caller's environment (`[vars]` empty, per
findings), and the secrets are never in the manifest, the lock, or `.flox/cache` — only
their paths. The `ConditionPathExists=` gates stay on the unit (§5). The one caveat is
T7/T8: the render dir and `.flox/log` must be writable by the unit's user, which is a
permissions problem, not a secrets one.

## 5. NixOS options with no manifest equivalent

The stub is still a NixOS unit — `environment.nix` writes only `ExecStart` (mkForce) and
`environment`; everything else in the unit is untouched. So:

- **Kept by the stub, for free:** `Slice=interactive.slice`, `User=`/`Group=`,
  `SupplementaryGroups=monitoring|docker`, `Restart=`, `After=network-online.target`,
  `ConditionPathExists=<secret>` (PID 1 evaluates it before flox is ever run),
  `StateDirectory=`, `RuntimeDirectory=`, `restartIfChanged`.
- **Kept but in tension with flox:** `DynamicUser=yes` (alertmanager) — no stable uid to
  own `.flox/log`; `ProtectSystem=strict` + `ProtectHome=tmpfs` (alertmanager,
  node-exporter) — needs `ReadWritePaths=` for `.flox/log` and the render dir;
  `MemoryDenyWriteExecute`, `SystemCallFilter=@system-service` — untested against the
  `flox-activations` executive and the `bash` hook (agent-hub has no such filter). The
  `ExecStartPre` scripts (`envsubst`, Grafana's pre-start) become hook lines.
- **Lost unless re-added on the stub:** `restartTriggers` are 0 today because the config
  is a **store path in `ExecStart`** — a scrape or rule change changes the unit file and
  the switch restarts it. Under a stub the rendered file lives outside the unit; a change
  to `tenants.json` or the tenant tree restarts nothing until the pull unit or an explicit
  `restartTriggers = [ tenantsJson.text ]` does. Prometheus's `SIGHUP` reload would need
  the hook to run *without* a restart, which `flox activate` does not offer.
- **Lost outright:** build-time `promtool check` and the `metrics.nix` address assertion
  (a wrong address fails at eval today; the hook can only fail at start), and `nix flake
  check`'s eval of the whole config. Failure moves from red CI to a `Restart=` loop.

## Product-gap statement for `docs/flox-findings.md` §5

A manifest can hold a host-fact-derived config only as a `[hook]` shell idiom: render from a
path the caller names into a dir the caller names, validate, `exec`. That works (T1–T5) but
flox contributes nothing to it and takes three things away — the hook's exit code (T6),
a per-activation write to `.flox/log` that makes the environment a per-user state dir and
fights `DynamicUser`/`ProtectSystem=strict` (T8), and any notion of "my input changed,
re-render / reload" (restart triggers). Whether that is a gap or correctly out of scope
turns on the input: `tenants.json` is a host artefact, and flox's contract is "an OS someone
else configures", so the honest reading is out of scope — with a real product ask left over
that is not about host facts at all: **`flox activate` should be runnable read-only** (no
mandatory log write) **and should pass the hook's exit code through**, so an environment can
sit under a hardened supervisor.

For this tenant: one contract-derived job, four static files, five unix identities, two
`strict` sandboxes. Stays NixOS. Re-open if `tenants.json` grows `metrics` for a second
reason or a second host wants the same dashboards.
