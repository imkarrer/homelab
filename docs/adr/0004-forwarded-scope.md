# ADR 0004: Forwarded Is a Distinct Port Scope from LAN

**Status:** Accepted

## Context

Assetto Corsa race servers listen on ac-box's LAN address (192.168.1.50). They are reachable locally by design — clients on the home network can connect directly. But Assetto Corsa is also internet-facing: the UniFi Dream Router is configured with port forwards that expose specific race lobby ports to the public internet.

Port scopes must reflect this reality. The tenant contract defines four scopes:

- `local`: bound to 127.0.0.1, firewall-closed, never reachable outside the box.
- `lan`: opened on the LAN interface (enp8s0) only.
- `forwarded`: opened on the LAN interface AND reachable from the internet because the router forwards it.
- `mgmt`: opened on the management interface (eno1), currently down.

The natural choice for Assetto is `lan`. But `lan` implies "this port is on the local network and may never be internet-facing." For a game server where internet traffic is the entire point, that framing is backwards. A tenant declaring a port as `lan` but then having it forwarded is a lie in the configuration. The platform cannot protect against that lie because firewall rules are written at layer 0, which knows nothing about what the router does outside the box.

## Decision

Ports that are intentionally forwarded to the internet are declared with `scope = "forwarded"` and must include a `justification` string that explains what gates internet access and why it is safe.

When a tenant declares `scope = "forwarded"`, the platform opens it on the LAN interface as normal, but the configuration becomes explicit: "this is public, this is gated, and here is why." The justification is required and is read by the operator every time the config is reviewed.

For Assetto, the justification is: "Assetto Corsa race servers are internet-facing by design. Each lobby slot is forwarded by the UniFi Dream Router based on the lobby slot number. The forwarding is per-slot, time-bounded, and logged."

## Consequences

**Positive:**
- Internet-facing ports are declared, not hidden or implied.
- An operator reviewing the config immediately sees which ports are public and why.
- The schema enforces a justification, which helps catch accidental internet exposure.
- The difference between `lan` (not forwarded) and `forwarded` (intentionally public) is obvious.

**Negative:**
- Every internet-facing tenant must write and maintain a justification. If the reason changes, the config must be updated.
- The firewall rule generation is the same for `lan` and `forwarded` (both open on the LAN interface). The difference is purely in declaration and documentation. The platform does not enforce that the router is actually forwarding; it trusts the operator.
- If a tenant is initially declared as `lan` but later exposed to the internet by router config changes, the mismatch is not caught by the platform. Auditing must be manual.

**Verification:**
To verify that forwarded ports are correctly opened on the router:
1. Check the UniFi Dream Router admin console for active port forward rules.
2. Compare the rule list against the `forwarded` declarations in the tenant config.
3. Document any mismatches as config drift.
4. Update the config to match reality, or update the router to match the config.

**Adding a new forwarded port:**
1. Decide on the port number and the justification.
2. Add it to the tenant config: `scope = "forwarded"; justification = "...";`.
3. Rebuild and activate with the platform changes.
4. Manually configure the port forward in the UniFi Dream Router admin console.
5. Test the forward from outside the LAN.
6. Commit the config changes (the router changes are manual and not version-controlled).
