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
  };

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
  #
  # NOT YET MIGRATED -- hand-placed values, as of 13 Sep 2026.
  #
  #   observability   /var/lib/monitoring/secrets/{grafana-admin,
  #                   grafana-secret-key, unpoller.pass, discord-webhook}
  #                   root:monitoring 0640. Four sops.secrets entries, each
  #                   with a path -- and each read on the host, so the
  #                   symlink is fine there. Check that before assuming it.
  #   ci              compose/.env.buildkite -- BUILDKITE_AGENT_TOKEN,
  #                   MINIO_ROOT_PASSWORD, three S3 keys. The .env shape
  #                   above, and the same question: modules/ci reads it via
  #                   EnvironmentFile= (host; a symlink is fine), but if the
  #                   agent container opens it too it needs the copy unit.
  #                   Decide link-vs-copy by who opens the file.
  #   bot             github-token -- declared, and the file does not exist on
  #                   the box (/var/lib/ac-host/secrets/ is empty). The bot
  #                   runs without it; whatever needs it is not exercised.
  # ---------------------------------------------------------------------------
}
