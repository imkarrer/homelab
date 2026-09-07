# Restores background.memoryShare to the literal 0.35 first suggested as a
# "sensible starting value" -- which, alongside critical's 0.35, interactive's
# 0.15 and batch's 0.10, sums to 0.95 and must fail the <= 0.9 assertion in
# resources.nix. Proves the budget check actually fires, and documents why
# resources.nix ships 0.30 as background's *default* instead.
{ lib, ... }:
{
  homelab.tiers.background.memoryShare = lib.mkForce 0.35;
}
