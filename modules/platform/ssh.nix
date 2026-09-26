# sshd and fail2ban, for every homelab host.
#
# KEY-ONLY since 26 Sep 2026 (homelab-ygc.3, the operator's decision the day
# arcade-box got its key). Until then PasswordAuthentication and
# KbdInteractiveAuthentication were both true, carried over verbatim from
# ac-box's pre-flake configuration.nix with its own note -- "leave password
# on until you confirm a couple of key-only logins, then set these to false"
# -- and the confirmation is three weeks old: every switch, the nightly
# backup (scripts/hub-backup.sh) and hub-status.sh have reached ac-box as
# root with ~/.ssh/id_ed25519_ac-host since 7 Sep. Setting them false is the
# behaviour change that note deferred, taken deliberately.
#
# What that means for a person: any device without one of the keys in
# hosts/<name>/ssh-keys.local.nix cannot ssh to either host; the physical
# console is the way back in. PermitRootLogin stays "prohibit-password":
# root with a key, never with a password. sshd is reloaded by the switch;
# open sessions survive it.
{ ... }:

{
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };

  services.fail2ban.enable = true;
}
