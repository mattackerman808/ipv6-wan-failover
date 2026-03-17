# ipv6-wan-failover

Automatic IPv6 failover for UniFi Dream Machine dual-WAN setups.

## Problem

On a UDM with two WANs, IPv4 failover works instantly because NAT hides the source address — LAN devices keep their RFC 1918 addresses regardless of which WAN is active. IPv6 breaks because every LAN device has globally-routable addresses from the active WAN's prefix delegation. When that WAN goes down:

- Devices still have IPv6 addresses from the dead WAN's prefix
- Those addresses are not routable through the surviving WAN
- New addresses require Router Advertisements, which can take 1+ hours
- **All IPv6 connectivity is lost until then**

UBIOS correctly switches the IPv4 default route and the IPv6 catch-all routing rule, but does not MASQUERADE traffic from the dead WAN's prefix through the surviving WAN.

## How It Works

The daemon auto-detects your WAN topology (interfaces, routing tables, bridge-to-WAN mapping) from `ip -6 rule` and route table state. No configuration needed.

**Detection:** Polls each WAN's routing table every 1 second. When a WAN's table loses its default route, that WAN is down.

**Failover:** Adds two rules so LAN traffic from the dead WAN's prefix routes through the surviving WAN with NAT66:

```bash
# Route dead-prefix traffic via surviving WAN's table
ip -6 rule add from <dead_prefix> lookup <surviving_table> priority 50

# Rewrite source address so upstream ISP accepts the traffic
ip6tables -t nat -A POSTROUTING -o <surviving_wan> -s <dead_prefix> -j MASQUERADE
```

**Recovery:** Removes both rules when the WAN comes back.

The daemon caches the bridge-to-WAN mapping at startup so it can still apply rules even if the dead WAN's prefix delegation expires during the outage.

## Install

```bash
# Copy to the gateway (/data/ survives firmware updates)
ssh gateway 'mkdir -p /data/ipv6-wan-failover'
scp ipv6-wan-failover.sh gateway:/data/ipv6-wan-failover/
scp ipv6-wan-failover.service gateway:/etc/systemd/system/
```

## Usage

```bash
# Verify auto-detected topology
/data/ipv6-wan-failover/ipv6-wan-failover.sh --status

# Enable and start
systemctl daemon-reload
systemctl enable ipv6-wan-failover
systemctl start ipv6-wan-failover

# Monitor
journalctl -u ipv6-wan-failover -f

# Show current state and active rules
/data/ipv6-wan-failover/ipv6-wan-failover.sh --status

# Manually remove all failover rules
/data/ipv6-wan-failover/ipv6-wan-failover.sh --remove
```

**Note:** `/etc/systemd/system/` does not survive firmware updates. After a UDM firmware update, re-copy the service file and re-enable it. The script itself in `/data/` persists.

## Relationship to fix-ipv6-wan2

[fix-ipv6-wan2](https://github.com/mattackerman808/fix-ipv6-wan2) handles the **steady-state** problem: ensuring PBR devices and static routes use the correct WAN for IPv6 during normal dual-WAN operation. This project handles the **failover** problem: maintaining IPv6 connectivity when a WAN goes down entirely.

| | fix-ipv6-wan2 | ipv6-wan-failover |
|---|---|---|
| **When** | Always (steady state) | Only during WAN failure |
| **Scope** | Specific PBR devices + static routes | All LAN devices using the dead prefix |
| **MASQUERADE** | PBR MACs through WAN2 | All dead-prefix traffic through surviving WAN |

## License

MIT License. See [LICENSE](LICENSE) for details.
