# boxctl -- read-only inspector for the homelab tenant contract.
#
# Why Python, not a POSIX shell script: `boxctl plan` parses free-text
# systemd unit lists out of `switch-to-configuration dry-activate` output,
# cross-references them against /etc/homelab/tenants.json, unions sets of
# units per tenant, and shells out to per-tenant busyCheck commands with a
# timeout. That's JSON parsing, regex extraction, and set logic -- all
# straightforward in the standard library, all painful and fragile in POSIX
# sh + sed/awk/jq (and jq is an extra runtime dependency shell would still
# need). No third-party package is required, so this stays a single
# `writers.writePython3Bin` derivation rather than a full
# `buildPythonApplication` -- there's no dependency set or entry-point
# metadata to justify the extra ceremony.
{ writers }:

writers.writePython3Bin "boxctl" {
  # writers' Python check runs pyflakes/pycodestyle at build time. E501
  # (line length) is the only rule this file trips, on descriptive --help
  # strings and comments; everything else -- unused names, undefined
  # variables, syntax -- still gates the build.
  flakeIgnore = [ "E501" ];
} (builtins.readFile ./boxctl.py)
