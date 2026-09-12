# ADR 0007: What Moves to the Management Interface

**Status:** Proposed. The decision is the operator's; this records the options
and a recommendation. It has a physical precondition that no commit can
satisfy.

## Context

`hosts/ac-box/host.nix` declares two networks: `lan` on `enp8s0` (192.168.1.50,
carries everything today) and `mgmt` on `eno1` with `address = null`. The
tenant contract has had a `mgmt` port scope since ADR 0004, `ports.nix` asserts
nothing may be scoped to it until the interface has an address, and nothing is.
`mgmt` is a word in the schema that no declaration uses.

`host.nix`'s comment says `eno1` is "Cabled but DOWN. The dual-NIC runbook
brings this up as management." Read live on 12 Sep 2026:

```
eno1    DOWN    <NO-CARRIER,BROADCAST,MULTICAST,UP>    carrier: 0    speed: -1
nmcli:  eno1  ethernet  unavailable
```

The interface is administratively up and has **no link**. Either there is no
cable in it, or the cable runs to a port that is not live. "Cabled" cannot be
confirmed from the box, and `NO-CARRIER` says the runbook's first step is
physical. This ADR corrects `host.nix`'s comment alongside.

What is management-shaped on `enp8s0` today: `sshd` on `0.0.0.0:22` (both
interfaces, so it would already answer on `eno1` given a link) and Grafana on
`192.168.1.50:3000`. Prometheus and every exporter are loopback-only and out of
scope.

The question this ADR exists to settle — because the repo names the interface's
*role* and nothing else — is **which services move**, and the answer decides
what `scope = "mgmt"` means in practice.

## Options

**A. Nothing. Retire `mgmt` from the schema.**
Honest simplification: one interface, one scope fewer, `ports.nix`'s mgmt
assertion and `host.nix`'s dead entry deleted. Rejected only if the isolation
below is actually wanted; if it is not, this is the right answer and the cheap
one, and a schema word nobody uses is exactly the kind of thing this repo
removes.

**B. `sshd` only.**
The textbook split: the management plane on its own interface, the LAN carrying
tenants. Every tenant port stays where it is. The risk is the obvious one — if
`eno1` or its switch port dies, so does `ssh`, and this box has no console
without a trip to it. Mitigated by keeping `sshd` on *both* interfaces during a
transition and only closing the LAN side once the mgmt path has been used
through at least one reboot.

**C. `sshd` plus the observability UI (Grafana).** — RECOMMENDED if `mgmt` is
kept at all.
Same as B, plus Grafana's 3000 moves from `scope = "lan"` to `scope = "mgmt"`.
Reasoning: Grafana is the one tenant-owned service that is for the operator, not
for the LAN's users (kids' machines need SMB, rsync, the game ports, the
Mindustry and Freeciv discovery sockets — none of them need dashboards). Moving
it gets the LAN down to exactly what the LAN's users consume. The `unifi.address`
host fact (`6e18170`) stays as-is — the exporters poll the router over whatever
route exists, and are loopback-bound themselves.

Not moved under any option: anything a tenant's *users* reach. `assetto`'s
forwarded ranges, `arcade`'s LAN ports, `agent-hub`'s 8100 (the model server is
consumed from other LAN machines, which is its whole point).

## What the decision unblocks, in order

1. **Physical.** A cable from `eno1` to a live port, and a decision about what
   that port is on — the same LAN (simplest; `mgmt` becomes a second address on
   192.168.1.0/24, and the isolation is by interface only) or a separate VLAN
   on the Dream Router (real isolation; needs a UDR-side change and a DHCP
   reservation or static address). `carrier: 1` is the acceptance test.
2. **`host.nix`.** `networks.mgmt.address` set — by reference to whatever the
   UDR assigns, never guessed. This alone flips `ports.nix`'s mgmt assertion
   from "nothing may be scoped here" to "things may".
3. **Declarations.** Under B or C, `observability.ports.grafana.scope = "mgmt"`,
   and `sshd`'s interface handling in `modules/platform/ssh.nix` (today it binds
   all interfaces via the nixpkgs default and the firewall opens 22 globally —
   check before assuming). Under A, delete `mgmt` from `schema.nix`,
   `ports.nix`, `host-options.nix`, `host.nix` and the fixtures, one commit.
4. **Runbook.** "Dual-NIC runbook" is referenced in `host.nix` and does not
   exist in `docs/`. Whichever option, it gets written before step 2 lands,
   with the sshd-on-both transition spelled out for B and C.

## Consequences

Under A, the contract gets simpler and a dead interface stays dead; nothing
else changes.

Under B or C, the box gains a second path in, and the first time that path is
the *only* one for `ssh` is the moment `eno1`'s switch port becomes a single
point of failure for operating the machine. The transition rule — both
interfaces until the mgmt path has survived a reboot — is not optional.

This is the last of the three phase-6 items (`docs/architecture.md` Part III
rows 8, 9–10, 11). The other two landed in code the same day; this one lands
as a decision, because its first step is a cable.
