# Secrets: sops-nix, keyed on ssh keys that already exist.
#
# README has said "credentials go to sops-nix" since the repo began, and
# every tenant declares the NAMES of its secrets in
# homelab.tenants.<name>.secrets -- but until 12 Sep 2026 none were
# provisioned by anything in git. They were hand-placed files:
# /var/lib/monitoring/secrets/*, /var/lib/ac-host/.env,
# compose/.env.buildkite, /var/lib/arcade/secrets/smb-password. A box
# rebuilt from this flake would have every unit and none of the values.
#
# --------------------------------------------------------------------------
# THE KEY MODEL -- no new key material, anywhere
# --------------------------------------------------------------------------
# age can use ssh ed25519 keys as identities, and ssh-to-age derives the
# matching recipient from a public key. So:
#
#   the box    decrypts at activation with /etc/ssh/ssh_host_ed25519_key,
#              which it has had since install. Recipient (ssh-to-age of
#              /etc/ssh/ssh_host_ed25519_key.pub, read 12 Sep 2026):
#                age135yqc5evu2tjffzgr8ryrn7n65qeuccu26jp5scpf8hp36eyrgest8agyl
#
#   the operator encrypts and edits with ~/.ssh/id_ed25519_ac-host, the key
#              they already ssh to the box with:
#                age1ygy44hwqkmnf8s742a9vf9k9fxwc7gh9jl2hyfmwwlk45n4laqqqrmyk8w
#              The identity is derived in-memory and never written to disk:
#                SOPS_AGE_KEY="$(ssh-to-age -private-key -i ~/.ssh/id_ed25519_ac-host)" \
#                  sops secrets/ac-box.yaml
#              (sops 3.13's SOPS_AGE_SSH_PRIVATE_KEY_FILE was tried first and
#              is not honoured by this build -- the error lists the paths it
#              does check, and that is not one of them. Learned 12 Sep 2026;
#              the round-trip was proven with the form above, by sha256 of
#              the decrypted value against the file on the box.)
#
# Both recipients are in .sops.yaml. Nothing was generated, nothing has to
# be backed up beyond what already is, and losing the box's host key was
# already losing the box. Reinstalling the box means: new host key, add its
# recipient to .sops.yaml, `sops updatekeys`, redeploy. That is the whole
# rotation story and it is written down here so nobody invents a second one.
#
# --------------------------------------------------------------------------
# WHY ONE SECRET, NOT ALL OF THEM
# --------------------------------------------------------------------------
# sops-nix runs at activation and INSTALLS each declared secret at its path.
# The first activation with this module is therefore the first time anything
# in git writes into those directories, and if decryption fails -- wrong
# recipient, key path, permissions -- activation fails and the consumer
# finds nothing where its file was. That is a rebuild-breaking failure mode,
# so it is proven on the secret whose consumer can least be hurt:
# arcade-smb-password, a 16-hex string for a kids' ROM share, whose
# consumer (arcade-smb-password.service in home-arcade) reads a fixed path
# and would regenerate the file if it were missing anyway.
#
# Every secret is installed at the path its consumer ALREADY reads, with the
# owner and mode the hand-placed file already has. Consumers do not change.
# That is the point: migrating a secret into git must be invisible to the
# service that uses it, or it is a service change wearing a secrets change's
# clothes. The remaining hand-placed secrets follow the same shape once this
# one has activated on the box; they are listed at the bottom, unmigrated,
# so the gap is visible rather than forgotten.
#
# --------------------------------------------------------------------------
# THE SECOND SHAPE: A RENDERED FILE, AND WHY IT IS COPIED RATHER THAN LINKED
# --------------------------------------------------------------------------
# /var/lib/ac-host/.env is not a secret; it is a compose env file of ~35 keys
# in which four values are secrets. sops.templates renders exactly that: the
# non-secret keys are the template body, in git, and the four placeholders
# are filled from secrets/ac-box.yaml at activation. The body below is the
# file the box had on 13 Sep 2026, verbatim (blank lines, the comment line,
# DISCORD_REQUIRED_ROLE twice), so that the first switch is byte-identical
# and no consumer can tell the difference -- the same invisibility rule as
# the first secret. The operator approved the non-secret keys (channel IDs,
# public IP, invite URL) appearing here in the clear.
#
# The template is NOT installed at /var/lib/ac-host/.env by sops-nix. When
# sops-nix is given a `path`, what it puts there is a SYMLINK into
# /run/secrets (see /var/lib/arcade/secrets/smb-password on the box). Two of
# the file's readers run on the host and would follow it, but the third does
# not: ac-host's scripts/ci_downtime.py runs INSIDE the Buildkite agent
# container, which bind-mounts /var/lib/ac-host and not /run/secrets. Its
# _rebuild_sidecars() checks `envf.is_file()`, which on a dangling symlink is
# false, prints "sidecar rebuild skipped: compose or .env missing", and
# returns -- so the nightly bot and sidecar rebuild would stop happening,
# silently, from the first switch onward. The template therefore renders at
# sops-nix's default, /run/secrets/rendered/ac-host-env, and
# ac-host-env.service below copies it into place as a regular file, root
# 0600, written to .env.tmp and mv'd so the swap is atomic for the bot's
# `compose --env-file` and for the container's is_file() alike.
#
# The consequence, and it is the point: /var/lib/ac-host/.env is now owned by
# this module. A hand-edit on the box survives until the next switch or boot
# and is then overwritten. Nothing else routinely writes the file
# (seed_github_env.py is a dev-profile tool, DEV.md); a value changes by
# `scripts/hub-secret-set.sh <key>` and a switch, a non-secret key by editing
# the template body here.
#
# --------------------------------------------------------------------------
# THE THIRD SHAPE: A RENDERED FILE THAT NEEDS NEITHER PATH NOR COPY
# --------------------------------------------------------------------------
# compose/.env.buildkite, the ci tenant's env file, is the same .env shape --
# thirteen keys, five of them secrets -- but the symlink hazard above does
# not apply to it, because of WHO OPENS IT. Nothing inside a container reads
# this file. Its only two readers are on the host: systemd's EnvironmentFile=
# on ac-host-ci.service and the `docker compose --env-file` in that unit's
# ExecStart/ExecStop, and modules/ci carries the PATH into both from one
# option, homelab.ci.envFile. So the template renders at sops-nix's default,
# /run/secrets/rendered/ci-env, with no `path` (no symlink to create) and no
# copy unit; this module sets homelab.ci.envFile to the rendered path and the
# consumer follows. The hand-placed file under /var/lib/ac-host/src/compose
# stops being read at the next start of the unit -- and stops living inside
# the tenant tree ci_downtime.py syncs, which is where a secret least
# belongs.
{
  config,
  lib,
  pkgs,
  ...
}:

{
  sops = {
    defaultSopsFile = ../../secrets/ac-box.yaml;

    # The host key, not a generated age key. sops-nix would default to the
    # ed25519 entry of services.openssh.hostKeys; stated explicitly because
    # it is the load-bearing fact of the whole model and should not depend on
    # reading a default.
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    age.keyFile = null;
    age.generateKey = false;

    secrets = {
      # arcade's SMB password. Consumer: arcade-smb-password.service
      # (home-arcade/modules/arcade-hub.nix), which reads exactly this path,
      # expects owner arcade, and runs `smbpasswd` with the contents. The
      # hand-placed file was -rw------- arcade arcade; this reproduces that.
      # Declared in homelab.tenants.arcade.secrets as "arcade-smb-password".
      arcade-smb-password = {
        path = "/var/lib/arcade/secrets/smb-password";
        owner = "arcade";
        group = "arcade";
        mode = "0600";
        # The consumer is a oneshot that runs after samba starts; it must run
        # after the secret exists, and sops-nix's own ordering puts secret
        # installation before sysinit.target, which is before everything
        # here. Stated for the reader; nothing to configure.
      };

      # observability's four, 14 Sep 2026: the first shape again, one entry
      # per hand-placed file in /var/lib/monitoring/secrets, each at the
      # exact path its consumer already reads (modules/observability names
      # them: grafanaAdminFile, grafanaSecretFile, unpollerPassFile,
      # discordWebhookFile), root:monitoring 0640 as the files were. The
      # "who opens it" test that sent the .env through a copy unit passes
      # here: every reader is a host-side native unit, none is a container.
      #
      # Whether each reader can follow the link into /run/secrets.d/<n>/ was
      # checked on the box, not assumed (14 Sep 2026):
      #   grafana        User=grafana, SupplementaryGroups=monitoring,
      #                  ProtectSystem=full -- /run stays readable.
      #   alertmanager   DynamicUser=yes with SupplementaryGroups=monitoring
      #                  (modules/observability's addition), ProtectSystem=
      #                  strict -- strict makes the tree read-only, it hides
      #                  nothing; the dynamic uid still carries gid monitoring.
      #   unifi-poller   User=unifi-poller, no Group=/SupplementaryGroups= on
      #                  the unit, so initgroups() applies and the live
      #                  process shows gid 991 (monitoring); ProtectSystem=full.
      #   udr-fw-exporter  User=unifi-poller Group=monitoring, no sandbox.
      # All four already open the 0640 root:monitoring files today, so the
      # group half is proven in production; the new half is the traversal,
      # and sops-nix creates /run/secrets.d/<n> 0751 root:keys (MkdirAll
      # 0o751 in sops-install-secrets), so any uid passes through it and the
      # per-file mode decides. ConditionPathExists is evaluated by PID 1 with
      # access(2), which follows the link; sops-nix has installed the
      # generation from the activation script before any unit is considered.
      #
      # restartUnits names every reader, so a rotation is push-and-switch:
      # none of the four units sets restartIfChanged = false (grafana,
      # alertmanager and unpoller take the nixpkgs default; udr-fw-exporter
      # is this repo's and sets nothing), so nothing is dropped from the
      # activation restart list the way it would be for ac-host-bot. All are
      # in the observability tenant, drainable (AGENTS.md). The FIRST switch
      # restarts all four too -- each secret is new to sops-nix's generation
      # -- which is the moment the regular files become symlinks.
      #
      # Two Grafana facts a rotation has to know. security.admin_password is
      # read on first run only, when the admin user is created; a new value
      # here does not change the password stored in grafana.db, and
      # `grafana-cli admin reset-admin-password` (or the UI) does that.
      # security.secret_key encrypts secrets Grafana stores in its db
      # (datasource credentials); the one provisioned datasource has none,
      # so a rotation costs nothing today, but that stops being true the day
      # a datasource with a password is added.
      grafana-admin = {
        path = "/var/lib/monitoring/secrets/grafana-admin";
        owner = "root";
        group = "monitoring";
        mode = "0640";
        restartUnits = [ "grafana.service" ];
      };
      grafana-secret-key = {
        path = "/var/lib/monitoring/secrets/grafana-secret-key";
        owner = "root";
        group = "monitoring";
        mode = "0640";
        restartUnits = [ "grafana.service" ];
      };
      # Two readers, not one: unpoller's controller `pass` (a file path, to
      # unpoller) and udr-fw-exporter's UNIFI_PASS_FILE, both for the same
      # `unpoller` account on the UDR, and both gate on the path with
      # ConditionPathExists. The sops key is unpoller-pass; the file keeps
      # its dot.
      unpoller-pass = {
        path = "/var/lib/monitoring/secrets/unpoller.pass";
        owner = "root";
        group = "monitoring";
        mode = "0640";
        restartUnits = [
          "unifi-poller.service"
          "udr-fw-exporter.service"
        ];
      };
      discord-webhook = {
        path = "/var/lib/monitoring/secrets/discord-webhook";
        owner = "root";
        group = "monitoring";
        mode = "0640";
        restartUnits = [ "alertmanager.service" ];
      };

      # The four secrets in /var/lib/ac-host/.env. No `path`: nothing reads
      # them as files, they exist to be substituted into the template below
      # (sops-nix still installs each at /run/secrets/<name>, root 0400).
      # Two are the bot's (discord-token, buildkite-api-token, declared in
      # homelab.tenants.bot.secrets); the other two this module's own list
      # had missed until the file was read key by key on 13 Sep 2026:
      # ac-admin-password is the lobby admin password render_cfg.py bakes
      # into every server config (assetto's), github-status-token is what the
      # plugin sidecar pushes leaderboard.json with (also assetto's). Neither
      # is declared in tenants.nix yet.
      discord-token = { };
      buildkite-api-token = { };
      ac-admin-password = { };
      github-status-token = { };

      # The five secrets in compose/.env.buildkite, for the ci-env template
      # below. Same rule, no `path`. github-status-token is not repeated:
      # the ci tenant's file carries the same value assetto's .env does
      # (ci_publish_pages.py pushes the site with the credential push_status.py
      # writes leaderboard.json with), so it is one sops key substituted into
      # two templates.
      #
      # buildkite-agent-token is the Default-cluster token 482de9f7, minted
      # 14 Sep 2026 by scripts/hub-cluster-token.sh; the box's file holds the
      # old unclustered token, so the first render of this template is what
      # moves the agent into the cluster.
      #
      # The three cache values are NEW, generated 14 Sep 2026, not migrated:
      # the box's S3_CACHE_SECRET_ACCESS_KEY and S3_CACHE_SIGNING_KEY were
      # exposed in an agent transcript that day, and MINIO_ROOT_PASSWORD was
      # rotated with them (all three are MinIO-local; nothing off the box
      # holds them). minio-root-password and s3-cache-secret-access-key are
      # 40 chars of `openssl rand -base64 33 | tr -d '/+='`;
      # s3-cache-signing-key is a Nix cache key pair from `nix key
      # generate-secret --key-name flox-binary-cache-2` (the retired pair is
      # flox-binary-cache-1). The public half is not secret:
      #   flox-binary-cache-2:ESa71iIsMeX6Wu7EBiXXZlJraWI0HF4xdOF/ivG4UTo=
      # and must be ADDED, not swapped, where ac-host trusts the old one:
      # compose/docker-compose.buildkite.yml's S3_CACHE_PUBLIC_KEY, both the
      # image bake arg and the agent env default. The plugin (Dockerfile and
      # lib/environment.bash) writes that value verbatim into nix.conf's
      # extra-trusted-public-keys, a whitespace-separated list, so the two
      # keys go in one value. flox-binary-cache-1's public key stays trusted
      # so every NAR already in the cache, signed by it, remains
      # substitutable; only new pushes carry the -2 signature.
      buildkite-agent-token = { };
      minio-root-password = { };
      s3-cache-secret-access-key = { };
      s3-cache-signing-key = { };
      # bump-lock's credential (scripts/hub-bump-lock.sh, row 24): a GitHub
      # fine-grained token, imkarrer/homelab only, Contents read+write. The
      # agent forwards it to jobs as HOMELAB_PUSH_TOKEN; absent, bump-lock
      # skips and says so. Minted 14 Sep 2026.
      homelab-push-token = { };
    };

    # /var/lib/ac-host/.env, as of the box on 13 Sep 2026 (sha256 d85835fd...,
    # 1302 bytes). Rendered to /run/secrets/rendered/ac-host-env, root 0400;
    # ac-host-env.service copies it into place. Every non-secret line is
    # literal and in the box's order, including the duplicate
    # DISCORD_REQUIRED_ROLE (the second wins in compose; harmless, and the
    # consumer does not change on a secrets migration).
    #
    # restartUnits names the copy unit only. The bot is restarted THROUGH it
    # (PartOf=, below), not by listing it here: ac-host-bot.service carries
    # restartIfChanged = false, and switch-to-configuration runs the
    # activation restart list through the same X-RestartIfChanged check as
    # any modified unit -- so "ac-host-bot.service" in this list would land
    # in the skip set and the bot would keep running on the old token.
    # (Read in switch-to-configuration-ng's handle_modified_unit, 13 Sep
    # 2026; nothing is printed when a listed unit is skipped.)
    templates.ac-host-env = {
      restartUnits = [ "ac-host-env.service" ];
      content = ''
        AC_STATE=/var/lib/ac-host
        AC_CONTENT=/var/lib/ac-host/content
        AUTH_OPEN=0
        AUTH_REQUIRED_ROLE=ac-practice
        AUTH_BIND=127.0.0.1:18080
        STEAMCMD_LOGIN=anonymous
        AC_ADMIN_PASSWORD=${config.sops.placeholder.ac-admin-password}
        AC_GITHUB_OWNER=imkarrer
        AC_GITHUB_REPO=ac-practice
        AC_PAGES_URL=https://simracing.fugazy.dev
        GITHUB_STATUS_REPO=imkarrer/ac-practice
        GITHUB_STATUS_BRANCH=main
        GITHUB_STATUS_PATH=leaderboard.json
        GITHUB_STATUS_TOKEN=${config.sops.placeholder.github-status-token}
        DISCORD_REQUIRED_ROLE=ac-practice
        DISCORD_TOKEN=${config.sops.placeholder.discord-token}
        DISCORD_ADMIN_ROLE=ac-admin
        DISCORD_REQUIRED_ROLE=ac-practice
        DISCORD_REVIEW_CHANNEL_ID=1545234424654991411
        DISCORD_VERIFY_PROFILE=1
        REGISTER_TO_LOBBY=0
        RENDER_SKIN_MODE=cycle
        DISCORD_CHANNEL_URL=https://discord.com/channels/1544532113615749210/1545234414265700374
        DISCORD_FEATURE_REQUESTS_URL=https://discord.com/channels/1544532113615749210/1544893635353649294
        DISCORD_STATUS_CHANNEL_ID=1545234415054225511
        AC_PUBLIC_IP=167.237.13.200

        DISCORD_INVITE_URL=https://discord.gg/Rh7vevrUYy

        # Buildkite (API token is not the agent token)
        BUILDKITE_ORG=isaac-karrer
        BUILDKITE_PIPELINE=ac-host

        BUILDKITE_API_TOKEN=${config.sops.placeholder.buildkite-api-token}

        BUILDKITE_PIPELINE_OPS=ac-host-ops
        BUILDKITE_PIPELINE_SERIES=ac-host-series
      '';
    };

    # compose/.env.buildkite, as of the box on 14 Sep 2026 (root 0600, 694
    # bytes, last written 8 Sep): the same keys in the same order, the
    # non-secret values verbatim. Two differences, neither visible to a
    # reader. The comment line: the box's says "Copy this file onto ac-box;
    # do not commit it", which is exactly what stops being true. And line
    # endings: the box's file is CRLF on the six lines that came from
    # env.buildkite.example and LF on the rest; both systemd's EnvironmentFile
    # parser and compose's dotenv parser strip the CR (the live containers'
    # env shows `ac-box`, `queue=self`, `ac-minio` clean), so the pure-LF
    # render is the same file to both. Rendered to /run/secrets/rendered/ci-env, root
    # 0400 (sops-nix's default; the box's file was 0600 and root is the only
    # reader either way). No `path`, no copy unit: the third shape, in the
    # header. What each key does is ac-host's business
    # (compose/docker-compose.buildkite.yml, compose/minio-init.sh); the two
    # that matter for the agent's identity are BUILDKITE_AGENT_NAME=ac-box
    # and BUILDKITE_AGENT_TAGS containing queue=self, which every pipeline
    # hub-pipeline.sh creates targets.
    #
    # No restartUnits, on purpose, and not for the reason ac-host-env has
    # none for the bot. ac-host-ci.service carries restartIfChanged = false,
    # so naming it here would be dropped silently by switch-to-configuration
    # (the ac-host-env comment above); a PartOf= copy unit like the bot's
    # could route around that, and is deliberately not built. modules/ci's
    # HAZARD 2 is about a job on the agent bouncing the agent, and a switch
    # by hand from ssh, or by modules/deploy at 03:30, is neither -- but the
    # 03:30 switch lands while the tenant's own 03:00 ops job (ci_downtime.py,
    # the sidecar rebuilds) may still be running ON that agent, and a
    # lock-bump switch can coincide with any job. "A plain nixos-rebuild
    # switch must never implicitly bounce this unit" is the stance modules/ci
    # already took; a rotation of one of these values is rare and has been a
    # human act every time. So: the render changes at the switch, the running
    # unit keeps the environment it started with (EnvironmentFile= and
    # --env-file are read at ExecStart/ExecStop, never in between), and the
    # operator runs `systemctl restart ac-host-ci` from ssh once the agent is
    # idle. The ci tenant is drainable (AGENTS.md): a re-queued job is not an
    # outage.
    #
    # Ordering needs nothing here: this config has sops.useSystemdActivation
    # = false (no sysusers), so sops-nix installs secrets and renders
    # templates from the activation script -- at boot, in stage 2 before
    # systemd starts a single unit; at a switch, before units are touched --
    # and ac-host-ci is after docker.service besides. The file exists before
    # EnvironmentFile= is read. (An absent EnvironmentFile= without a `-`
    # prefix fails the unit; that is the right failure -- a box that could
    # not decrypt should not start an agent with no token.)
    #
    # What a bounce does with the new values, from the compose file and
    # minio-init.sh as of 14 Sep 2026:
    #   MINIO_ROOT_PASSWORD   minio takes root creds from its environment at
    #                         every start, and this MinIO (RELEASE.2025-09-07
    #                         on the box) stores IAM and config in the clear
    #                         unless a KMS is configured (cmd/iam-object-store
    #                         .go: saveIAMConfig encrypts only with GlobalKMS,
    #                         decryptData returns utf8 data untouched), so the
    #                         bucket and the flox-cache user survive the
    #                         rotation. A new value on the next start; nothing
    #                         else to do.
    #   S3_CACHE_SECRET_ACCESS_KEY
    #                         NOT free. minio-init.sh runs `mc admin user add`
    #                         only when `mc admin user info` says the user is
    #                         absent, and flox-cache exists, so its stored
    #                         secret stays the old one while the agent starts
    #                         with the new -- every cache read and push would
    #                         403 until the user's secret is reset. One
    #                         box-side step after the bounce, from the same
    #                         rendered file (`mc admin user add` on an
    #                         existing user rewrites its secret; that is what
    #                         the server's CreateUser documents):
    #                           cd /var/lib/ac-host/src/compose && docker compose \
    #                             -f docker-compose.buildkite.yml -p ac-host-ci \
    #                             --env-file /run/secrets/rendered/ci-env \
    #                             run --rm --entrypoint sh minio-init -c \
    #                             'mc alias set local http://minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null && mc admin user add local "$S3_CACHE_ACCESS_KEY_ID" "$S3_CACHE_SECRET_ACCESS_KEY"'
    #                         (Or drop the guard in minio-init.sh, which would
    #                         make every future rotation free; that is an
    #                         ac-host change.)
    #   S3_CACHE_SIGNING_KEY  the plugin's post-command hook writes the value
    #                         to a 0600 temp file and pushes with
    #                         secret-key=<file>; new NARs are signed
    #                         flox-binary-cache-2 from the first push after
    #                         the bounce, and are trusted only once ac-host's
    #                         S3_CACHE_PUBLIC_KEY carries the -2 public key
    #                         (above). Until then a push succeeds and the
    #                         pushed path is not substitutable; nothing
    #                         breaks, the cache just does not warm.
    #   BUILDKITE_AGENT_TOKEN the agent registers into the Default cluster;
    #                         GET /v2/organizations/isaac-karrer/agents shows
    #                         cluster non-null and queue self.
    templates.ci-env = {
      content = ''
        # Rendered by sops-nix from homelab's modules/platform/secrets.nix; not hand-edited.
        BUILDKITE_AGENT_TOKEN=${config.sops.placeholder.buildkite-agent-token}
        BUILDKITE_AGENT_NAME=ac-box
        BUILDKITE_AGENT_TAGS=queue=self

        MINIO_ROOT_USER=ac-minio
        MINIO_ROOT_PASSWORD=${config.sops.placeholder.minio-root-password}
        S3_CACHE_BUCKET=flox-binary-cache
        S3_CACHE_ACCESS_KEY_ID=flox-cache
        S3_CACHE_SECRET_ACCESS_KEY=${config.sops.placeholder.s3-cache-secret-access-key}
        S3_CACHE_SIGNING_KEY=${config.sops.placeholder.s3-cache-signing-key}
        GITHUB_STATUS_TOKEN=${config.sops.placeholder.github-status-token}
        GITHUB_STATUS_REPO=imkarrer/ac-practice
        AC_PAGES_PUSH=1
        HOMELAB_PUSH_TOKEN=${config.sops.placeholder.homelab-push-token}
      '';
    };
  };

  # The consumer follows the render. modules/ci reads exactly one path,
  # homelab.ci.envFile, into EnvironmentFile= and both `--env-file`s; its
  # default is the hand-placed path under the tenant tree, and this is the
  # platform saying the file is now rendered here instead. Set beside the
  # template rather than in hosts/ac-box so the two cannot drift apart.
  homelab.ci.envFile = config.sops.templates.ci-env.path;

  # The copy: /run/secrets/rendered/ac-host-env -> /var/lib/ac-host/.env as a
  # regular file (the symlink hazard in the header). Runs at boot and, via
  # the template's restartUnits, on any switch whose rendered content
  # differs. Left alone when the content already matches, so the first
  # switch does not even touch the file's mtime.
  #
  # RemainAfterExit and stopIfChanged = false are both load-bearing, for the
  # bot's sake. switch-to-configuration turns a restartUnits entry into a
  # RESTART only for a unit that is currently active; an inactive one is
  # merely started, and a stop+start (the default for a changed service) is
  # two jobs, not one. PartOf= propagates stop and restart but never start.
  # So: stay active after the copy, and be restarted rather than stopped and
  # started, and the one restart job reaches the bot as a try-restart.
  #
  # The FIRST switch is the inactive case: ac-host-env does not exist yet,
  # so it is started, not restarted, and PartOf carries nothing to the bot.
  # Seen 13 Sep 2026 at gen 35: .env was rewritten, the bot stayed on its
  # old env until the reboot that followed. Later switches whose render
  # differs do bounce it; if no reboot is coming, `systemctl restart
  # ac-host-env` does the same by hand.
  systemd.services.ac-host-env = {
    description = "Install the sops-rendered /var/lib/ac-host/.env as a regular file";
    wantedBy = [ "multi-user.target" ];
    # cmp is diffutils, not coreutils; neither is on a unit's PATH by default.
    path = [
      pkgs.coreutils
      pkgs.diffutils
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    stopIfChanged = false;
    script = ''
      set -euo pipefail
      src=/run/secrets/rendered/ac-host-env
      dst=/var/lib/ac-host/.env
      if [ -e "$dst" ] && cmp -s "$src" "$dst"; then
        exit 0
      fi
      # install reads through the symlink and writes a new regular file.
      # install chmods after create, so without this the tmp file exists at
      # the umask default for an instant -- in a directory the agent container
      # bind-mounts.
      umask 077
      install -m 0600 -o root -g root "$src" "$dst.tmp"
      mv -f "$dst.tmp" "$dst"
    '';
  };

  # Two list merges onto a unit ac-host's module defines. This is the
  # platform stating a provisioning dependency -- the bot reads a file this
  # module now writes -- not a rename, a re-slice, or a change to what the
  # unit runs; the tenant contract's Slice/Nice ladder is untouched.
  #
  #   after   the copy has happened before the bot's ConditionPathExists is
  #           evaluated and before its `compose up` reads the file.
  #   partOf  a restart of ac-host-env (a rendered-content change, or the
  #           copy unit itself changing) restarts the bot, so a rotated
  #           token reaches the container: compose interpolates the token
  #           into the service definition, so `up -d` recreates it. This is
  #           the one path by which a switch bounces the bot; every other
  #           keeps ac-host's restartIfChanged = false intact. tenants.nix
  #           declares the bot drainable (a bounce is a Discord reconnect);
  #           the 02:45-03:05 caveat recorded there applies to a secret
  #           rotation too.
  #
  # ac-host-static is deliberately NOT ordered after the copy, though
  # acctl.py reads the same file (AC_ADMIN_PASSWORD, into every lobby's
  # config). At a switch it is never restarted (restartIfChanged = false,
  # and AGENTS.md's abort criterion). At boot the file it reads is the one on
  # disk from the last activation, which this module wrote; and a box with
  # no .env at all has no /var/lib/ac-host/src either, so the static unit
  # cannot start before the tenant tree is synced regardless of ordering.
  # The sidecars (auth, plugin, details) are compose-owned and rebuilt by
  # ci_downtime.py from the file as it is at 03:00 -- after the previous
  # night's 03:30 switch, so they see the current render.
  systemd.services.ac-host-bot = {
    after = [ "ac-host-env.service" ];
    partOf = [ "ac-host-env.service" ];
  };

  # ---------------------------------------------------------------------------
  # MIGRATED
  #   arcade          arcade-smb-password, 12 Sep 2026 -- the proof secret.
  #   bot, assetto    /var/lib/ac-host/.env, 13 Sep 2026 -- the template
  #                   above. It held FOUR secrets, not the two this list
  #                   named on 12 Sep: AC_ADMIN_PASSWORD and
  #                   GITHUB_STATUS_TOKEN were found on reading the file key
  #                   by key.
  #   ci              compose/.env.buildkite, 14 Sep 2026 -- the ci-env
  #                   template. Five secrets: the cluster agent token, the
  #                   shared github-status-token, and three MinIO-local
  #                   values generated new because the box's were exposed.
  #                   Neither link nor copy: both readers are on the host and
  #                   take a path from homelab.ci.envFile. The box's file
  #                   under the tenant tree is dead once ac-host-ci has been
  #                   restarted, and should be removed by hand then.
  #   observability   /var/lib/monitoring/secrets/{grafana-admin,
  #                   grafana-secret-key, unpoller.pass, discord-webhook},
  #                   14 Sep 2026 -- four entries in the first shape, each
  #                   linked at the path its reader already opens,
  #                   root:monitoring 0640. The symlink question was checked
  #                   per unit (the entries' comment); every reader is on
  #                   the host. modules/observability no longer mints the
  #                   two Grafana values when absent.
  #
  # NOT YET MIGRATED -- hand-placed values, as of 14 Sep 2026.
  #
  #   bot             github-token -- declared, and the file does not exist on
  #                   the box (/var/lib/ac-host/secrets/ is empty). The bot
  #                   runs without it; whatever needs it is not exercised.
  # ---------------------------------------------------------------------------
}
