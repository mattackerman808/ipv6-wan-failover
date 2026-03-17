# Feature Request: IPv6 NAT66/MASQUERADE during WAN failover

## Summary

When a WAN fails on a dual-WAN UDM, IPv4 fails over seamlessly but **IPv6 connectivity is completely lost** for up to 1+ hour. UBIOS correctly switches the IPv4 default route and catch-all ip6 rule, but does not MASQUERADE traffic from the dead WAN's prefix delegation through the surviving WAN. LAN devices retain their globally-routable IPv6 addresses from the dead WAN's prefix, and those addresses are not routable upstream of the surviving WAN.

This is a significant gap that makes IPv6 unreliable on any dual-WAN deployment and discourages enabling IPv6 entirely.

## The Problem

IPv4 failover works instantly because NAT hides the source address — LAN devices keep their RFC 1918 addresses regardless of which WAN is active. IPv6 has no equivalent. Each WAN's ISP delegates a unique prefix (e.g., `2600:1700:5451:1cff::/64` from WAN1, `2601:647:4d7e:e30::/64` from WAN2), and LAN devices use globally-routable addresses derived from these prefixes.

When WAN1 fails:

1. LAN devices on br0 still have IPv6 addresses from WAN1's prefix (`2600:1700:...`)
2. UBIOS correctly switches the catch-all ip6 rule to route through WAN2
3. Traffic arrives at WAN2's upstream router with a **source address from WAN1's prefix**
4. WAN2's ISP drops the traffic — that prefix doesn't belong to them
5. All IPv6 connectivity is lost

Devices must wait for their existing addresses to expire and acquire new ones via Router Advertisements from the surviving WAN's prefix. This can take **over an hour** depending on address lifetimes.

## What UBIOS Does Today (observed on UniFi OS 4.x)

We captured detailed diagnostic data during a real WAN1 failure event. UBIOS does handle several things correctly:

- **ip6 rule 32766** (catch-all) switches from `lookup 201.eth9` to `lookup 202.eth8`
- **Route table 201** is emptied (default route removed)
- **Mangle chain** for the dead WAN is unhooked (0 references, counters zeroed) so new connections don't get the dead WAN's fwmark
- **WAN failure detection** works via DNS-based monitors (~18s to declare down)

## What UBIOS Does NOT Do

- **Does not MASQUERADE** traffic from the dead WAN's prefix through the surviving WAN
- **Does not remove** the dead WAN's prefix delegation from the LAN bridge
- **Does not send deprecating Router Advertisements** for the dead prefix (preferred lifetime stays positive)
- **Does not flush conntrack entries** for the dead WAN's fwmark (they persist but are useless since the route table is empty)

The first item is the critical gap. The others are secondary.

## Proposed Fix

When UBIOS detects a WAN failure and performs the IPv4/IPv6 route switchover, it should also add two rules:

```bash
# Route traffic from dead WAN's prefix through surviving WAN's table
ip -6 rule add from <dead_pd_prefix> lookup <surviving_table> priority 50

# MASQUERADE (NAT66) so the source address is rewritten to the surviving WAN's address
ip6tables -t nat -A POSTROUTING -o <surviving_wan_if> -s <dead_pd_prefix> -j MASQUERADE
```

On WAN recovery, remove both rules.

This is the IPv6 equivalent of what already happens for IPv4 — the source address is rewritten so the upstream ISP accepts the traffic. LAN devices continue working with their existing IPv6 addresses immediately, with zero downtime beyond the ~18s detection window that already exists for IPv4.

### Concrete example from our network

Normal state:
- WAN1 (eth9) delegates `2600:1700:5451:1cff::/64` to br0
- WAN2 (eth8) delegates `2601:647:4d7e:e30::/64` to br42

When WAN1 fails, UBIOS should add:
```bash
ip -6 rule add from 2600:1700:5451:1cff::/64 lookup 202.eth8 priority 50
ip6tables -t nat -A POSTROUTING -o eth8 -s 2600:1700:5451:1cff::/64 -j MASQUERADE
```

When WAN1 recovers, remove them.

## Why This Matters

- **IPv6 adoption**: Dual-WAN users who need reliability cannot safely enable IPv6 today. This is a blocker for IPv6 deployment.
- **Parity with IPv4**: IPv4 failover is seamless. IPv6 failover should be too.
- **Small scope**: The fix is two iptables/ip rules added during failover, removed on recovery. UBIOS already has all the information it needs (it knows which WAN failed, which prefix was delegated, and which WAN survived).

## Workaround

We wrote an open-source daemon ([ipv6-wan-failover](https://github.com/mackerman/ipv6-wan-failover)) that auto-detects the WAN topology from ip6 rules and routing tables, monitors for WAN failure by polling route table state every 1s, and applies the MASQUERADE rules automatically. It works, but this should be built into UBIOS alongside the existing IPv4 failover logic.

## Environment

- UniFi Dream Machine (UDM Pro SE)
- UniFi OS 4.x
- Dual WAN with IPv6 prefix delegation on both WANs
- Failover mode: failover (not load balance)
