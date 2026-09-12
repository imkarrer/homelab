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
{ config, lib, ... }:

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
    };
  };

  # ---------------------------------------------------------------------------
  # NOT YET MIGRATED -- declared names with hand-placed values, 12 Sep 2026.
  # Each follows the pattern above once arcade-smb-password has activated.
  #
  #   observability   /var/lib/monitoring/secrets/{grafana-admin,
  #                   grafana-secret-key, unpoller.pass, discord-webhook}
  #                   root:monitoring 0640. Four sops.secrets entries.
  #   bot, assetto    /var/lib/ac-host/.env -- a compose env FILE with ~30
  #                   keys, of which DISCORD_TOKEN and BUILDKITE_API_TOKEN are
  #                   secrets and the rest are config. sops.templates renders
  #                   a file from secrets plus literals; the non-secret keys
  #                   belong in git as the template body.
  #   ci              compose/.env.buildkite -- BUILDKITE_AGENT_TOKEN,
  #                   MINIO_ROOT_PASSWORD, three S3 keys. Same template shape.
  #                   Note modules/ci reads this path via EnvironmentFile=.
  #   bot             github-token -- declared, and the file does not exist on
  #                   the box (/var/lib/ac-host/secrets/ is empty). The bot
  #                   runs without it; whatever needs it is not exercised.
  # ---------------------------------------------------------------------------
}
