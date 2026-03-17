# Phase 2 Design: Automatic IPv6 WAN Failover

Architecture notes for the failover daemon. Details will be refined based on Phase 1 diagnostic data.

## Detection Strategies

Ranked by expected speed (fastest first):

1. **networkd-dispatcher hooks** — Scripts in `/etc/networkd-dispatcher/no-carrier.d/` fire on interface state change. Fastest if UBIOS uses networkd to manage WAN interfaces. Need to verify this fires on WAN failure (not just link-down).

2. **syslog monitoring** — Watch `/var/log/messages` for `wanFailover` events. Known to work but adds latency (syslog write + tail lag). Could use `inotifywait` on the log file to reduce lag.

3. **dpinger socket** — The UDM health monitor daemon exposes real-time latency/loss data via Unix sockets at `/run/dpinger*.sock`. Polling these gives sub-second detection if the socket protocol is simple (need Phase 1 data to confirm format).

4. **operstate polling** — Check `/sys/class/net/eth{8,9}/operstate` on a 1s loop. Reliable but slowest, since the kernel operstate may lag behind actual connectivity loss (especially for L3 failures where the link stays up).

## MASQUERADE Scope

On WAN failure:
- Identify the dead WAN's prefix delegation (PD) — all LAN addresses in that prefix become unroutable
- Add `ip6tables -t nat -A POSTROUTING -o <surviving_wan> -s <dead_pd_prefix> -j MASQUERADE`
- Add mangle rules to remark traffic from the dead prefix to use the surviving WAN's routing table
- This covers ALL LAN devices, not just PBR devices

Key difference from fix-ipv6-wan2: the MASQUERADE source match is the dead WAN's PD prefix (covering all LAN devices) rather than specific MAC addresses.

## Failback

On WAN recovery:
- Remove the MASQUERADE and mangle rules for the recovered WAN's prefix
- Existing connections through the MASQUERADE will break (conntrack entries become invalid), but this is unavoidable and acceptable — the alternative is no IPv6 at all
- New connections will use the restored WAN directly

## RA Manipulation (Stretch Goal)

After failover, deprecate the dead prefix via Router Advertisements so LAN devices acquire new addresses from the surviving WAN's PD. This would eliminate MASQUERADE entirely after a transition period. Requires:
- Understanding dnsmasq/radvd RA configuration on UDM
- Ability to inject a "deprecated" prefix into RA
- Phase 1 data on RA timing and tooling

## Coexistence with fix-ipv6-wan2

fix-ipv6-wan2 handles steady-state PBR routing for WAN2. During failover:
- If WAN2 fails: fix-ipv6-wan2 rules become no-ops (WAN2 has no route). The failover script adds MASQUERADE for WAN2's prefix through WAN1.
- If WAN1 fails: UBIOS mangle catch-all may or may not switch to WAN2. The failover script adds MASQUERADE for WAN1's prefix through WAN2. fix-ipv6-wan2 rules remain active for PBR devices.
- On recovery: failover MASQUERADE is removed. fix-ipv6-wan2 rules resume normal operation.

The two scripts should use distinct marks/flags to avoid conflicts. The failover script should check for fix-ipv6-wan2 rules before modifying shared chains.

## Daemon Architecture

Likely a single bash script running as a systemd service (or via nohup on UDM). Options:
- **Event-driven:** networkd-dispatcher hook triggers failover/failback scripts
- **Polling loop:** 1s poll of dpinger sockets + operstate, acts on state transitions
- **Hybrid:** networkd-dispatcher for fast detection, polling as a safety net

The choice depends on Phase 1 findings about which signals are available and reliable.
