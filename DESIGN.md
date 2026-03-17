# Phase 2 Design: Automatic IPv6 WAN Failover

Architecture for the failover daemon, refined with Phase 1 diagnostic data captured 2026-03-17.

## Network Topology

| Interface | Role | IPv4 | IPv6 PD | fwmark | Route table |
|---|---|---|---|---|---|
| eth9 | WAN1 (primary, SFP+) | `162.199.89.216` | `2600:1700:5451:1cff::/64` → br0 | `0x1a0000` | 201 |
| eth8 | WAN2 (Comcast) | `24.4.59.188` | `2601:647:4d7e:e30::/64` → br42 | `0x1c0000` | 202 |
| br0 | Cypress LAN | — | receives eth9 PD | — | — |
| br42 | Guest (VLAN 42) | — | receives eth8 PD | — | — |

## Detection Strategies

Phase 1 tested all four originally proposed strategies against a real L3 upstream failure (ISP outage — physical link stayed up).

### Results

| Strategy | Viable? | Notes |
|---|---|---|
| networkd-dispatcher | **No** | Hook directories empty. operstate never changed, so no-carrier.d never fires. Only useful for physical cable pull, which is the less common failure mode. |
| operstate polling | **No** | eth9 remained `up` throughout the entire outage. L3 failures (upstream ISP down, modem reachable) don't change operstate. |
| dpinger socket | **No** | UBIOS reconfigured dpinger to target the modem's private IP (`192.168.1.254`) during the outage. Modem responded fine → dpinger reported "up" while upstream was dead. We don't control dpinger config. |
| **syslog monitoring** | **Yes** | `wf-interface-eth9 is down` fired reliably at 15:12:53. ~1s from syslog write to detection via `tail -F` or `inotifywait`. |

### Additional detection signal discovered

**ip6 rule polling:** Rule 32766 (`from all lookup <table>`) switches between `201.eth9` and `202.eth8` during failover. This is a simple, reliable secondary signal — just poll `ip -6 rule show` and watch for the table to change.

### Recommended approach: syslog primary, ip6 rule secondary

1. **Primary:** `tail -F /var/log/messages` filtered for `wf-interface-eth[89].*is (down|up)`
2. **Secondary:** Poll `ip -6 rule show` every 1s, detect rule 32766 table changes
3. The secondary catches cases where syslog might be delayed or rotated

### Timing from Phase 1 data

- UBIOS takes ~18s from first internal signal to declaring the WAN down (DNS probes must fail)
- Detection of the syslog message: <1s after UBIOS writes it
- UBIOS failover action (rule/route switch): <1s after declaration
- Failback detection: <1s after DNS recovery — watch for `wf-groups-container is using wf-group-1-single`
- Total observed outage: ~2m18s (dominated by ISP recovery time, not detection lag)

## What UBIOS Does During Failover

Observed behavior from Phase 1 snapshots:

1. **ip6 rule 32766** switches from `lookup 201.eth9` → `lookup 202.eth8`
2. **Route table 201** emptied — default route via eth9 removed entirely
3. **Mangle chain** `UBIOS_WF_GROUP_1_SINGLE` unhooked (0 references, counters zeroed) — new connections don't get eth9's fwmark
4. **ip6tables NAT** unchanged — **UBIOS does NOT add MASQUERADE for the dead prefix** (this is the gap we fill)
5. **Conntrack** entries with old fwmark (`0x1a0000`) persist but are useless — the route table they reference is empty
6. **PD prefix lingers** on br0 with existing lifetime (~50 min remaining) — never removed, never deprecated via RA

## What UBIOS Does NOT Do

- Does not MASQUERADE traffic from the dead WAN's prefix through the surviving WAN
- Does not remove the dead WAN's PD prefix from the LAN bridge
- Does not send deprecating Router Advertisements for the dead prefix
- Does not flush conntrack entries for the dead WAN's fwmark

These gaps cause complete IPv6 connectivity loss for all LAN devices using the dead prefix until addresses naturally expire (up to 1+ hour).

## MASQUERADE Scope

On WAN failure, the daemon must:

```bash
# MASQUERADE all traffic from the dead prefix through the surviving WAN
ip6tables -t nat -A POSTROUTING -o eth8 -s 2600:1700:5451:1cff::/64 -j MASQUERADE

# Route traffic from the dead prefix via the surviving WAN's table
ip -6 rule add from 2600:1700:5451:1cff::/64 lookup 202.eth8 priority 100
```

No mangle/fwmark rules needed — UBIOS already unhooks the dead WAN's mangle chain, so we just need a routing rule to direct the dead prefix's traffic to the surviving WAN and MASQUERADE it on the way out.

Key difference from fix-ipv6-wan2: the MASQUERADE source match is the dead WAN's PD prefix (covering all LAN devices) rather than specific MAC addresses.

## Failback

On WAN recovery (syslog: `wf-groups-container is using wf-group-1-single`):

1. Remove the MASQUERADE rule for the recovered WAN's prefix
2. Remove the ip6 routing rule
3. Optionally flush conntrack entries that were MASQUERADEd (avoids stale NAT mappings)

Existing connections through the MASQUERADE will break, but this is unavoidable and acceptable — the WAN is back, devices will reconnect with their original prefix.

UBIOS failback is fast (~1s from DNS recovery to rule switch), so the daemon should act quickly to avoid double-NATing.

## RA Manipulation (Stretch Goal)

Phase 1 findings on RA infrastructure:

- dnsmasq runs with `--enable-ra` providing Router Advertisements
- radvd is also present and active
- The dead prefix continues being advertised — no automatic deprecation

To deprecate the dead prefix, we would need to:
- Inject a zero-lifetime prefix into dnsmasq/radvd config and trigger re-advertisement
- Or send a raw RA with preferred_lft=0 for the dead prefix using radvadump/ndisc6 tools

This would accelerate device recovery from ~1 hour (waiting for address expiry) to minutes, but adds complexity. The MASQUERADE approach provides immediate connectivity without RA changes — RA manipulation is a nice-to-have optimization.

## Coexistence with fix-ipv6-wan2

Phase 1 confirmed UBIOS catches-all rule behavior:

- **If WAN1 (eth9) fails:** UBIOS switches catch-all to `202.eth8`. fix-ipv6-wan2 PBR rules for specific MACs remain active but are now redundant (everything already goes through eth8). Failover daemon adds MASQUERADE for WAN1's prefix through eth8. No conflict.
- **If WAN2 (eth8) fails:** UBIOS catch-all stays on `201.eth9`. fix-ipv6-wan2 PBR rules try to route specific MACs through eth8, which is dead. Failover daemon adds MASQUERADE for WAN2's prefix through eth9. fix-ipv6-wan2 rules should be temporarily bypassed or disabled.
- **On recovery:** Failover MASQUERADE removed. fix-ipv6-wan2 rules resume normal operation.

The failover daemon should use a higher-priority ip6 rule (e.g., priority 100) so it takes precedence over fix-ipv6-wan2 rules during failover.

## Daemon Architecture

Based on Phase 1 findings, the daemon should be **event-driven with polling fallback**:

```
┌─────────────────────────────────────────┐
│           syslog watcher                │
│  tail -F /var/log/messages              │
│  filter: wf-interface-eth[89]           │
│         wf-groups-container             │
├─────────────────────────────────────────┤
│           ip6 rule poller (1s)          │
│  ip -6 rule show | grep 32766          │
│  detect table 201↔202 transitions      │
├─────────────────────────────────────────┤
│           state machine                 │
│  NORMAL → FAILOVER → NORMAL            │
│  on failover: add MASQUERADE + rule     │
│  on recovery: remove MASQUERADE + rule  │
├─────────────────────────────────────────┤
│           systemd service               │
│  Restart=always, After=network.target   │
└─────────────────────────────────────────┘
```

Single bash script. Syslog watcher provides fast detection (<1s). ip6 rule poller provides a safety net in case syslog is missed. State machine prevents duplicate rule insertion.
