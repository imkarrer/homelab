# sshd and fail2ban, carried over verbatim from ac-box's configuration.nix.
#
# PasswordAuthentication and KbdInteractiveAuthentication are both still true,
# and PermitRootLogin is "prohibit-password" (root can only log in with a
# key). This is exactly what ac-box runs today — the original comment
# ("leave password on until you confirm key-only logins, then set false") is
# preserved below rather than acted on, because tightening it is a behaviour
# change this extraction is not the place for.
{ ... }:

{
  services.openssh = {
    enable = true;
    settings = {
      # Keys work for root and nixosuser. Leave password on until you confirm
      # a couple of key-only logins, then set these to false.
      PasswordAuthentication = true;
      KbdInteractiveAuthentication = true;
      PermitRootLogin = "prohibit-password";
    };
  };

  services.fail2ban.enable = true;
}
