# Four shares that sum to exactly 0.9 on paper and to 0.9000000000000001 in
# IEEE doubles -- ac-box's real table from 14 Sep 2026 (critical 0.02,
# interactive 0.02, background 0.81, batch 0.05). The budget assertion once
# compared the raw float against 0.9 and refused this with the message
# "Got 0.900000", which is the shape of a bug a person cannot see in the
# output. Must evaluate cleanly.
{ lib, ... }:
{
  homelab.tiers = {
    critical.memoryShare = lib.mkForce 0.02;
    interactive.memoryShare = lib.mkForce 0.02;
    background.memoryShare = lib.mkForce 0.81;
    batch.memoryShare = lib.mkForce 0.05;
  };
}
