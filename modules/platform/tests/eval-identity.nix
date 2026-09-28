# Harness for modules/platform/identity.nix: every account gets its host's
# tracked keys, and a host with no hosts/<name>/ssh-keys.local.nix is an
# evaluation error, never an empty list. The `[]` fallback this replaced
# built a host with ZERO authorized keys when homelab.host.name moved
# without its directory (homelab-ygc.9, measured 28 Sep 2026); sshd is
# key-only, so that closure locks every account out. This is the standing
# proof that the refusal stays a refusal.
#
# The NixOS options identity.nix writes are stubbed, the way
# eval-node-exporter.nix stubs its own: the module is under test, not
# nixpkgs' users module. host-options.nix is the real one (options only).
#
# Discovered by modules/tenant/tests/check.nix as `eval-platform-identity`.
#
# Usage:
#   nix eval --impure --raw -f modules/platform/tests/eval-identity.nix llmBox.checked
#   nix eval --impure --json -f modules/platform/tests/eval-identity.nix missingKeysFile.messages
{
  lib ? (import ../../tenant/tests/pinned-nixpkgs.nix).lib,
}:
let
  hostOptions = ../host-options.nix;
  identity = ../identity.nix;

  stubs =
    { lib, ... }:
    {
      options = {
        users.users = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };
        security.sudo.wheelNeedsPassword = lib.mkOption {
          type = lib.types.bool;
          default = true;
        };
        environment.systemPackages = lib.mkOption {
          type = lib.types.listOf lib.types.anything;
          default = [ ];
        };
      };
      # identity.nix names five packages; which ones is not under test.
      config._module.args.pkgs = lib.genAttrs [ "htop" "tmux" "curl" "rsync" "git" ] (n: n);
    };

  accounts = [
    "root"
    "nixosuser"
    "ac"
  ];

  configFor =
    name:
    (lib.evalModules {
      modules = [
        stubs
        hostOptions
        identity
        { homelab.host.name = name; }
      ];
    }).config;

  keysOf = cfg: u: cfg.users.users.${u}.openssh.authorizedKeys.keys;

  # A tracked host: every account has keys, and the same keys.
  hostCase =
    name:
    let
      cfg = configFor name;
      messages =
        lib.concatMap (
          u: lib.optional (keysOf cfg u == [ ]) "${u} has no authorized keys on ${name}"
        ) accounts
        ++ lib.optional (
          lib.length (lib.unique (map (keysOf cfg) accounts)) != 1
        ) "root, nixosuser and ac must carry the same keys on ${name}";
    in
    {
      inherit messages;
      checked =
        if messages == [ ] then
          "ok: ${name}: ${toString (lib.length (keysOf cfg "root"))} key(s) each for ${lib.concatStringsSep ", " accounts}"
        else
          throw (lib.concatStringsSep "\n" messages);
    };

  # A name with no directory -- a rename without its `git mv`. identity.nix
  # must REFUSE, not hand back a list. `.messages` carries the refusal and
  # nothing else, so a module that returns [] again (the old fallback)
  # evaluates cleanly here and check.nix fails this case: "expected to throw
  # and evaluated cleanly". `merged` is forced first, outside the tryEval, so
  # a configuration that did not merge is an error, not a refusal.
  refusalCase =
    name:
    let
      cfg = configFor name;
      merged = builtins.seq cfg.security.sudo.wheelNeedsPassword true;
      refused = !(builtins.tryEval (builtins.deepSeq (map (keysOf cfg) accounts) true)).success;
      messages = builtins.seq merged (
        lib.optional refused "identity.nix refused host `${name}`: hosts/${name}/ssh-keys.local.nix is missing"
      );
    in
    {
      inherit messages;
      checked =
        if messages == [ ] then
          "identity.nix gave `${name}` ${toString (lib.length (keysOf cfg "root"))} key(s) and no error, with no keys file"
        else
          throw (lib.concatStringsSep "\n" messages);
    };
in
{
  arcadeBox = hostCase "arcade-box";
  llmBox = hostCase "llm-box";
  missingKeysFile = refusalCase "no-such-host";

  expected = {
    arcadeBox = true;
    llmBox = true;
    missingKeysFile = false;
  };
}
