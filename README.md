# ipv6-wan-failover

Automatic IPv6 failover for UniFi Dream Machine dual-WAN setups.

## Problem

On a UDM with two WANs, IPv4 failover works instantly because NAT hides the source address — LAN devices keep their RFC1918 addresses regardless of which WAN is active. IPv6 breaks because every LAN device has globally-routable addresses from the active WAN's prefix delegation. When that WAN goes down:

- Devices still have IPv6 addresses from the dead WAN's prefix
- Those addresses are not routable through the surviving WAN
- New addresses require Router Advertisements, which can take 1+ hours
- All IPv6 connectivity is lost until then

## Relationship to fix-ipv6-wan2

[fix-ipv6-wan2](https://github.com/mackerman/fix-ipv6-wan2) handles the **steady-state** problem: ensuring PBR devices and static routes use the correct WAN for IPv6 during normal dual-WAN operation. This project handles the **failover** problem: maintaining IPv6 connectivity when a WAN goes down entirely.

The core technique is the same — NAT66/MASQUERADE — but the trigger and scope differ:

| | fix-ipv6-wan2 | ipv6-wan-failover |
|---|---|---|
| **When** | Always (steady state) | Only during WAN failure |
| **Scope** | Specific PBR devices + static routes | All LAN devices using the dead prefix |
| **MASQUERADE** | PBR MACs through WAN2 | All dead-prefix traffic through surviving WAN |

## Phase 1: Diagnostic Data Gathering (current)

Before building the failover script, we need to understand exactly what changes on the UDM during a failover event. The `diagnose-failover.sh` script captures 14 categories of system state.

### Setup

```bash
scp diagnose-failover.sh gateway:~/
ssh gateway
chmod +x ~/diagnose-failover.sh
```

### Workflow

1. Open two SSH sessions to the gateway
2. **Terminal 1:** Capture baseline state:
   ```bash
   ./diagnose-failover.sh baseline
   ```
3. **Terminal 1:** Start the continuous monitor:
   ```bash
   ./diagnose-failover.sh --monitor
   ```
4. **Terminal 2:** Trigger WAN1 failure (unplug cable or disable in UI)
5. Wait ~60s for IPv4 failover to complete
6. **Terminal 2:** Capture mid-failover state:
   ```bash
   ./diagnose-failover.sh during
   ```
7. Restore WAN1 (plug cable back in or re-enable)
8. Wait for failback to complete
9. **Terminal 2:** Capture post-recovery state:
   ```bash
   ./diagnose-failover.sh after
   ```
10. **Terminal 1:** Ctrl-C to stop the monitor
11. Copy all data off the gateway:
    ```bash
    scp -r gateway:/tmp/ipv6-failover-diag/ ./
    ```

### What we're measuring

- **Detection signals:** How quickly can we detect WAN failure? (operstate, dpinger, syslog, networkd-dispatcher)
- **UBIOS behavior:** Does the catch-all fwmark switch WANs? Do routing tables change?
- **Prefix delegation survival:** Does the dead WAN's PD get removed or linger?
- **Connection tracking:** Do existing IPv6 conntrack entries survive?
- **Timing:** How fast do various signals fire relative to the actual failure?

### Captured data (14 files per snapshot)

| File | What it answers |
|------|----------------|
| `interfaces.txt` | Do addresses get removed? Interface state changes? |
| `routes.txt` | Does default route change? Do WAN tables get modified? |
| `ip6tables-mangle.txt` | Does the catch-all fwmark switch WANs during failover? |
| `ip6tables-nat.txt` | Existing NAT state |
| `iptables-mangle.txt` | IPv4 failover comparison |
| `conntrack.txt` | Do IPv6 connections survive failover? |
| `networkd-dispatcher.txt` | What hooks are available for detection? |
| `dpinger.txt` | Can we read health data directly? |
| `syslog.txt` | What gets logged and when? |
| `dhcpv6.txt` | Does DHCPv6 client release the PD? |
| `dnsmasq-ra.txt` | Can we manipulate RAs to deprecate old prefix? |
| `ubios-state.txt` | Machine-readable WAN status? |
| `connectivity.txt` | Actual connectivity per-WAN |
| `timestamp.txt` | Timing reference |

## Phase 2: Automatic Failover (planned)

See [DESIGN.md](DESIGN.md) for the planned architecture. The failover daemon will:
- Detect WAN failure (fastest available signal)
- MASQUERADE all traffic from the dead prefix through the surviving WAN
- Remove MASQUERADE on WAN recovery
- Coexist with fix-ipv6-wan2
