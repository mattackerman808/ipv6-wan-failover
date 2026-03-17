#!/bin/bash
# diagnose-failover.sh
#
# Diagnostic data gathering for IPv6 WAN failover behavior on UDM.
# Captures system state before, during, and after a WAN failover event
# to identify detection signals and understand UBIOS failover mechanics.
#
# Usage:
#   ./diagnose-failover.sh [label]       # Snapshot mode (e.g., baseline, during, after)
#   ./diagnose-failover.sh --monitor     # Monitor mode (continuous 1s polling)

set -uo pipefail

DIAG_DIR="/tmp/ipv6-failover-diag"
MONITOR_LOG="${DIAG_DIR}/monitor.log"

# --- Snapshot mode ---
snapshot() {
    local label="${1:-snapshot}"
    local seq=0

    mkdir -p "$DIAG_DIR"

    # Find next sequence number
    while [ -d "${DIAG_DIR}/snapshot-$(printf '%02d' $seq)-"* ] 2>/dev/null; do
        seq=$((seq + 1))
    done

    local dir="${DIAG_DIR}/snapshot-$(printf '%02d' $seq)-${label}"
    mkdir -p "$dir"
    echo "Capturing snapshot: ${dir}"

    # 1. interfaces.txt — Interface state + addresses
    {
        echo "=== ip link show ==="
        ip link show 2>&1
        echo ""
        echo "=== ip -6 addr show ==="
        ip -6 addr show 2>&1
        echo ""
        echo "=== operstate ==="
        for iface in eth8 eth9; do
            local state_file="/sys/class/net/${iface}/operstate"
            if [ -f "$state_file" ]; then
                echo "${iface}: $(cat "$state_file")"
            else
                echo "${iface}: (no operstate file)"
            fi
        done
    } > "${dir}/interfaces.txt" 2>&1
    echo "  interfaces.txt"

    # 2. routes.txt — Routing tables + policy rules
    {
        echo "=== ip -6 route show ==="
        ip -6 route show 2>&1
        echo ""
        echo "=== ip -6 route show table 201.eth9 ==="
        ip -6 route show table 201.eth9 2>&1
        echo ""
        echo "=== ip -6 route show table 202.eth8 ==="
        ip -6 route show table 202.eth8 2>&1
        echo ""
        echo "=== ip -6 rule show ==="
        ip -6 rule show 2>&1
    } > "${dir}/routes.txt" 2>&1
    echo "  routes.txt"

    # 3. ip6tables-mangle.txt — IPv6 mangle rules
    {
        echo "=== ip6tables -t mangle -L UBIOS_WF_GROUP_1_SINGLE -nv --line-numbers ==="
        ip6tables -t mangle -L UBIOS_WF_GROUP_1_SINGLE -nv --line-numbers 2>&1
        echo ""
        echo "=== ip6tables -t mangle -S UBIOS_WF_GROUP_1_SINGLE ==="
        ip6tables -t mangle -S UBIOS_WF_GROUP_1_SINGLE 2>&1
        echo ""
        echo "=== ip6tables -t mangle -L PREROUTING -nv --line-numbers ==="
        ip6tables -t mangle -L PREROUTING -nv --line-numbers 2>&1
        echo ""
        echo "=== ip6tables -t mangle -L OUTPUT -nv --line-numbers ==="
        ip6tables -t mangle -L OUTPUT -nv --line-numbers 2>&1
    } > "${dir}/ip6tables-mangle.txt" 2>&1
    echo "  ip6tables-mangle.txt"

    # 4. ip6tables-nat.txt — IPv6 NAT rules
    {
        echo "=== ip6tables -t nat -L -nv --line-numbers ==="
        ip6tables -t nat -L -nv --line-numbers 2>&1
        echo ""
        echo "=== ip6tables -t nat -S ==="
        ip6tables -t nat -S 2>&1
    } > "${dir}/ip6tables-nat.txt" 2>&1
    echo "  ip6tables-nat.txt"

    # 5. iptables-mangle.txt — IPv4 mangle (for comparison)
    {
        echo "=== iptables -t mangle -L UBIOS_WF_GROUP_1_SINGLE -nv --line-numbers ==="
        iptables -t mangle -L UBIOS_WF_GROUP_1_SINGLE -nv --line-numbers 2>&1
        echo ""
        echo "=== iptables -t mangle -S UBIOS_WF_GROUP_1_SINGLE ==="
        iptables -t mangle -S UBIOS_WF_GROUP_1_SINGLE 2>&1
    } > "${dir}/iptables-mangle.txt" 2>&1
    echo "  iptables-mangle.txt"

    # 6. conntrack.txt — Connection tracking
    {
        echo "=== conntrack -C ==="
        conntrack -C 2>&1
        echo ""
        echo "=== conntrack -L -f ipv6 (first 200 entries) ==="
        conntrack -L -f ipv6 2>&1 | head -200
    } > "${dir}/conntrack.txt" 2>&1
    echo "  conntrack.txt"

    # 7. networkd-dispatcher.txt — Available hooks
    {
        echo "=== networkctl ==="
        networkctl 2>&1
        echo ""
        echo "=== dispatcher state directories ==="
        for state_dir in /etc/networkd-dispatcher/*/; do
            if [ -d "$state_dir" ]; then
                echo "--- ${state_dir} ---"
                ls -la "$state_dir" 2>&1
            fi
        done
    } > "${dir}/networkd-dispatcher.txt" 2>&1
    echo "  networkd-dispatcher.txt"

    # 8. dpinger.txt — Health monitor state
    {
        echo "=== dpinger processes ==="
        ps aux 2>&1 | grep -i dpinger | grep -v grep
        echo ""
        echo "=== /run/dpinger* ==="
        ls -la /run/dpinger* 2>&1
        echo ""
        echo "=== dpinger socket reads ==="
        for sock in /run/dpinger*.sock; do
            if [ -S "$sock" 2>/dev/null ]; then
                echo "--- ${sock} ---"
                echo "" | nc -U "$sock" -w1 2>&1 || echo "(read failed)"
            fi
        done
    } > "${dir}/dpinger.txt" 2>&1
    echo "  dpinger.txt"

    # 9. syslog.txt — Failover-related log messages
    {
        echo "=== /var/log/messages (failover/carrier/link) ==="
        grep -iE 'wanFailover|wan.?fail|carrier|link.?(up|down)|eth[89]' /var/log/messages 2>&1 | tail -100
        echo ""
        echo "=== dmesg (link/carrier) ==="
        dmesg 2>&1 | grep -iE 'eth[89]|carrier|link' | tail -50
    } > "${dir}/syslog.txt" 2>&1
    echo "  syslog.txt"

    # 10. dhcpv6.txt — DHCPv6 client state
    {
        echo "=== odhcp6c processes ==="
        ps aux 2>&1 | grep odhcp6c | grep -v grep
        echo ""
        echo "=== DHCPv6 state files ==="
        for f in /tmp/odhcp6c* /var/run/odhcp6c*; do
            if [ -e "$f" ]; then
                echo "--- ${f} ---"
                cat "$f" 2>&1
            fi
        done
        echo ""
        echo "=== /tmp/*dhcp* /var/run/*dhcp* ==="
        ls -la /tmp/*dhcp* /var/run/*dhcp* 2>&1
    } > "${dir}/dhcpv6.txt" 2>&1
    echo "  dhcpv6.txt"

    # 11. dnsmasq-ra.txt — RA configuration
    {
        echo "=== dnsmasq processes ==="
        ps aux 2>&1 | grep dnsmasq | grep -v grep
        echo ""
        echo "=== dnsmasq config (RA-related) ==="
        for f in /etc/dnsmasq.d/* /tmp/dnsmasq.d/* /run/dnsmasq.d/*; do
            if [ -f "$f" ]; then
                echo "--- ${f} ---"
                grep -iE 'ra-|dhcp-range|enable-ra|ra_' "$f" 2>&1 || echo "(no RA lines)"
            fi
        done
        echo ""
        echo "=== radvd processes ==="
        ps aux 2>&1 | grep radvd | grep -v grep
    } > "${dir}/dnsmasq-ra.txt" 2>&1
    echo "  dnsmasq-ra.txt"

    # 12. ubios-state.txt — UBIOS machine-readable state
    {
        echo "=== /config/udapi-net/ ==="
        ls -la /config/udapi-net/ 2>&1
        echo ""
        echo "=== WAN status files ==="
        for f in /config/udapi-net/wan* /config/udapi-net/eth8* /config/udapi-net/eth9*; do
            if [ -f "$f" ]; then
                echo "--- ${f} ---"
                cat "$f" 2>&1
            fi
        done
        echo ""
        echo "=== ubios-udapi-server state ==="
        if command -v ubnt-systool >/dev/null 2>&1; then
            echo "--- ubnt-systool wanFailover --status ---"
            ubnt-systool wanFailover --status 2>&1
        fi
        echo ""
        echo "=== local API probe ==="
        if command -v curl >/dev/null 2>&1; then
            curl -sk --max-time 2 https://localhost/proxy/network/api/s/default/stat/health 2>&1 | head -50
        fi
    } > "${dir}/ubios-state.txt" 2>&1
    echo "  ubios-state.txt"

    # 13. connectivity.txt — Per-WAN reachability
    {
        echo "=== IPv6 connectivity ==="
        for iface in eth8 eth9; do
            echo "--- ping6 -I ${iface} 2001:4860:4860::8888 ---"
            ping6 -I "$iface" -c 3 -W 2 2001:4860:4860::8888 2>&1
            echo ""
        done
        echo "=== IPv4 connectivity ==="
        for iface in eth8 eth9; do
            echo "--- ping -I ${iface} 8.8.8.8 ---"
            ping -I "$iface" -c 3 -W 2 8.8.8.8 2>&1
            echo ""
        done
    } > "${dir}/connectivity.txt" 2>&1
    echo "  connectivity.txt"

    # 14. timestamp.txt — Timing reference
    {
        echo "=== date ==="
        date -u 2>&1
        echo ""
        echo "=== uptime ==="
        uptime 2>&1
    } > "${dir}/timestamp.txt" 2>&1
    echo "  timestamp.txt"

    echo ""
    echo "Snapshot complete: ${dir}"
    echo "Files: $(ls "${dir}" | wc -l | tr -d ' ')"
}

# --- Monitor mode ---
monitor() {
    mkdir -p "$DIAG_DIR"
    echo "Monitor mode: writing to ${MONITOR_LOG}"
    echo "Press Ctrl-C to stop."
    echo ""
    echo "# Monitor started $(date -u)" >> "$MONITOR_LOG"

    while true; do
        local ts
        ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

        # Interface operstate
        local eth8_state eth9_state
        eth8_state=$(cat /sys/class/net/eth8/operstate 2>/dev/null || echo "unknown")
        eth9_state=$(cat /sys/class/net/eth9/operstate 2>/dev/null || echo "unknown")

        # Default IPv6 route
        local default_v6
        default_v6=$(ip -6 route show default 2>/dev/null | head -1 | sed 's/  */ /g')

        # UBIOS catch-all mark value
        local catchall_mark
        catchall_mark=$(ip6tables -t mangle -S UBIOS_WF_GROUP_1_SINGLE 2>/dev/null | \
            grep -- "-d ::/0 -s ::/0" | grep -oP '(?<=--set-xmark )\S+' | tail -1)

        # WAN IPv6 addresses (global scope only)
        local eth8_v6 eth9_v6
        eth8_v6=$(ip -6 addr show dev eth8 scope global 2>/dev/null | grep -oP '(?<=inet6 )\S+' | head -1)
        eth9_v6=$(ip -6 addr show dev eth9 scope global 2>/dev/null | grep -oP '(?<=inet6 )\S+' | head -1)

        # Latest failover syslog line
        local last_failover
        last_failover=$(grep -i 'wanFailover\|wan.fail' /var/log/messages 2>/dev/null | tail -1 | sed 's/  */ /g')

        local line="${ts} eth8=${eth8_state} eth9=${eth9_state} mark=${catchall_mark:-?} defrt=[${default_v6:-none}] eth8_v6=${eth8_v6:-none} eth9_v6=${eth9_v6:-none} syslog=[${last_failover:-none}]"

        echo "$line" >> "$MONITOR_LOG"
        echo "$line"

        sleep 1
    done
}

# --- Main ---
case "${1:-}" in
    --monitor|-m)
        monitor
        ;;
    --help|-h)
        echo "Usage:"
        echo "  $0 [label]     Capture a diagnostic snapshot (e.g., baseline, during, after)"
        echo "  $0 --monitor   Continuously poll fast-changing state (1s interval)"
        echo ""
        echo "Output: ${DIAG_DIR}/"
        ;;
    *)
        snapshot "${1:-snapshot}"
        ;;
esac
