#!/bin/bash
#
# ipv6-wan-failover — Automatic IPv6 failover for UDM dual-WAN
#
# Copyright (c) 2026 Matthew Ackerman <matt@808.org>
# Licensed under the MIT License. See LICENSE file for details.
#
# Detects WAN failure and applies NAT66/MASQUERADE so LAN devices
# with addresses from the dead WAN's prefix can route through the
# surviving WAN.
#
# All topology (WAN interfaces, tables, bridge-to-WAN mapping) is
# auto-detected from ip6 rules, routes, and prefix delegation state.
#
# Usage:
#   ./ipv6-wan-failover.sh            Run the failover daemon
#   ./ipv6-wan-failover.sh --status   Show discovered topology and current state
#   ./ipv6-wan-failover.sh --remove   Remove all failover rules

set -uo pipefail

POLL_INTERVAL=1
RULE_PRIORITY=50
RULE_COMMENT="ipv6-wan-failover"

# ─── Discovered Topology ──────────────────────────────────────────
# Populated by discover()

declare -a WAN_IFS=()           # ("eth9" "eth8")
declare -A WAN_TABLE=()         # [eth9]="201.eth9"
declare -A BRIDGE_WAN=()        # [br0]="eth9"
declare -A BRIDGE_PREFIX=()     # [br0]="2600:1700:5451:1cff::/64"

# ─── Runtime State ────────────────────────────────────────────────

STATE="normal"                  # "normal" or the name of the dead WAN (e.g. "eth9")
declare -a ACTIVE_PREFIXES=()   # Prefixes currently being MASQUERADEd
ACTIVE_OUT_IF=""                # Surviving WAN interface
ACTIVE_TABLE=""                 # Surviving WAN's routing table

# ─── Logging ──────────────────────────────────────────────────────

log() {
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') ipv6-wan-failover: $*" >&2
    logger -t ipv6-wan-failover "$*" 2>/dev/null || true
}

# ─── IPv6 Helpers ─────────────────────────────────────────────────

# Convert first 4 groups of an IPv6 address to a 16-char hex string.
# Used for /64 prefix comparison.
#   "2600:1700:5451:1cff::/64" → "2600170054511cff"
#   "2601:647:4d7e:e30:5ad6:..." → "260106474d7e0e30"
ipv6_first4_hex() {
    local addr="${1%%/*}"       # strip prefix length
    addr="${addr%%::*}"         # take groups before :: (or all if no ::)
    IFS=: read -ra groups <<< "$addr"
    local hex=""
    for i in 0 1 2 3; do
        hex+=$(printf '%04x' "0x${groups[$i]:-0}")
    done
    echo "$hex"
}

# Check if outer prefix contains inner prefix.
# Works for prefix lengths that are multiples of 4 (covers /48, /52, /56, /60, /64).
#   prefix_contains "2600:1700:5451:1cf0::/60" "2600:1700:5451:1cff::/64" → true
prefix_contains() {
    local outer="$1" inner="$2"
    local outer_len="${outer##*/}"
    local hex_chars=$(( outer_len / 4 ))

    local outer_hex inner_hex
    outer_hex=$(ipv6_first4_hex "$outer")
    inner_hex=$(ipv6_first4_hex "$inner")

    [[ "${outer_hex:0:$hex_chars}" == "${inner_hex:0:$hex_chars}" ]]
}

# ─── Discovery ────────────────────────────────────────────────────

# Find WAN interfaces and their routing tables from ip6 fwmark rules.
# Parses rules like: "32501: from all fwmark 0x1c0000/0x7e0000 lookup 202.eth8"
discover_wans() {
    WAN_IFS=()
    WAN_TABLE=()

    while IFS= read -r line; do
        if [[ "$line" =~ fwmark.*lookup[[:space:]]+([0-9]+\.(eth[0-9]+)) ]]; then
            local table="${BASH_REMATCH[1]}"
            local iface="${BASH_REMATCH[2]}"
            if [[ -z "${WAN_TABLE[$iface]:-}" ]]; then
                WAN_IFS+=("$iface")
                WAN_TABLE["$iface"]="$table"
            fi
        fi
    done < <(ip -6 rule show 2>/dev/null)
}

# Find LAN bridges with PD-assigned global /64 prefixes, then match
# each to its upstream WAN interface.
discover_bridges() {
    BRIDGE_WAN=()
    BRIDGE_PREFIX=()

    # Find global unicast /64 proto kernel routes on br* interfaces
    while IFS= read -r line; do
        local prefix bridge
        prefix=$(echo "$line" | awk '{print $1}')
        bridge=$(echo "$line" | awk '{print $3}')
        [[ -z "$prefix" || -z "$bridge" ]] && continue
        [[ "$bridge" != br* ]] && continue

        BRIDGE_PREFIX["$bridge"]="$prefix"
        local bridge_hex
        bridge_hex=$(ipv6_first4_hex "$prefix")

        # Method 1: check if any WAN has a proto kernel route in the same /64.
        # UBIOS creates a host route on the WAN interface from the PD range.
        #   e.g., 2601:647:4d7e:e30:5ad6:...:8e14 dev eth8 proto kernel
        for wan_if in "${WAN_IFS[@]}"; do
            while IFS= read -r route; do
                local route_addr="${route%% *}"
                local wan_hex
                wan_hex=$(ipv6_first4_hex "$route_addr")
                if [[ "$bridge_hex" == "$wan_hex" ]]; then
                    BRIDGE_WAN["$bridge"]="$wan_if"
                    break 2
                fi
            done < <(ip -6 route show dev "$wan_if" proto kernel 2>/dev/null \
                | grep '^2[0-9a-f]')
        done

        # Method 2: check if any WAN has an RA aggregation route (< /64) that
        # contains this bridge prefix.
        #   e.g., 2600:1700:5451:1cf0::/60 dev eth9 proto ra
        if [[ -z "${BRIDGE_WAN[$bridge]:-}" ]]; then
            for wan_if in "${WAN_IFS[@]}"; do
                while IFS= read -r route; do
                    local ra_prefix="${route%% *}"
                    local ra_len="${ra_prefix##*/}"
                    if (( ra_len < 64 )) && prefix_contains "$ra_prefix" "$prefix"; then
                        BRIDGE_WAN["$bridge"]="$wan_if"
                        break 2
                    fi
                done < <(ip -6 route show dev "$wan_if" proto ra 2>/dev/null \
                    | grep '^2[0-9a-f]')
            done
        fi

        if [[ -z "${BRIDGE_WAN[$bridge]:-}" ]]; then
            log "WARNING: cannot determine WAN for $bridge ($prefix) — prefix will not be protected"
        fi
    done < <(ip -6 route show proto kernel 2>/dev/null \
        | grep '^2[0-9a-f].*\/64 dev br')
}

discover() {
    discover_wans
    if (( ${#WAN_IFS[@]} < 2 )); then
        log "ERROR: found ${#WAN_IFS[@]} WAN interface(s), need at least 2"
        exit 1
    fi

    discover_bridges
    if (( ${#BRIDGE_PREFIX[@]} == 0 )); then
        log "WARNING: no bridge PD prefixes found — will keep polling"
    fi

    log "topology:"
    for wan_if in "${WAN_IFS[@]}"; do
        local bridges=""
        for bridge in "${!BRIDGE_WAN[@]}"; do
            if [[ "${BRIDGE_WAN[$bridge]}" == "$wan_if" ]]; then
                bridges+=" $bridge(${BRIDGE_PREFIX[$bridge]})"
            fi
        done
        log "  $wan_if table=${WAN_TABLE[$wan_if]}${bridges:+ →$bridges}"
    done
}

# ─── State Detection ─────────────────────────────────────────────

# Check which WAN is down by looking for missing default routes.
# Returns "normal" or the interface name of the dead WAN.
detect_wan_state() {
    for wan_if in "${WAN_IFS[@]}"; do
        if ! ip -6 route show table "${WAN_TABLE[$wan_if]}" 2>/dev/null | grep -q "^default"; then
            echo "$wan_if"
            return
        fi
    done
    echo "normal"
}

# ─── Rule Management ─────────────────────────────────────────────

apply_failover() {
    local dead_wan="$1" surviving_wan="$2"
    local surviving_table="${WAN_TABLE[$surviving_wan]}"
    local applied=0

    ACTIVE_PREFIXES=()
    ACTIVE_OUT_IF="$surviving_wan"
    ACTIVE_TABLE="$surviving_table"

    for bridge in "${!BRIDGE_WAN[@]}"; do
        [[ "${BRIDGE_WAN[$bridge]}" != "$dead_wan" ]] && continue
        local prefix="${BRIDGE_PREFIX[$bridge]}"

        # Idempotency
        if ip -6 rule show 2>/dev/null | grep -q "from $prefix lookup $surviving_table"; then
            log "rules for $prefix already in place"
            ACTIVE_PREFIXES+=("$prefix")
            continue
        fi

        log "FAILOVER: $dead_wan down — MASQUERADE $prefix ($bridge) via $surviving_wan"

        if ! ip -6 rule add from "$prefix" lookup "$surviving_table" priority "$RULE_PRIORITY"; then
            log "ERROR: failed to add ip6 rule for $prefix"
            continue
        fi

        if ! ip6tables -t nat -A POSTROUTING -o "$surviving_wan" -s "$prefix" -j MASQUERADE \
             -m comment --comment "$RULE_COMMENT"; then
            log "ERROR: failed to add MASQUERADE for $prefix — rolling back rule"
            ip -6 rule del from "$prefix" lookup "$surviving_table" priority "$RULE_PRIORITY" 2>/dev/null
            continue
        fi

        ACTIVE_PREFIXES+=("$prefix")
        (( applied++ ))
    done

    if (( applied > 0 )); then
        log "failover applied: $applied prefix(es) via $surviving_wan"
    elif (( ${#ACTIVE_PREFIXES[@]} == 0 )); then
        log "WARNING: no prefixes to failover for $dead_wan"
    fi
}

remove_failover() {
    (( ${#ACTIVE_PREFIXES[@]} == 0 )) && return 0

    log "RECOVERY: removing failover rules"

    for prefix in "${ACTIVE_PREFIXES[@]}"; do
        ip -6 rule del from "$prefix" lookup "$ACTIVE_TABLE" \
            priority "$RULE_PRIORITY" 2>/dev/null || true
        ip6tables -t nat -D POSTROUTING -o "$ACTIVE_OUT_IF" -s "$prefix" -j MASQUERADE \
            -m comment --comment "$RULE_COMMENT" 2>/dev/null || true
    done

    log "removed ${#ACTIVE_PREFIXES[@]} failover rule(s)"
    ACTIVE_PREFIXES=()
    ACTIVE_OUT_IF=""
    ACTIVE_TABLE=""
}

# ─── Commands ─────────────────────────────────────────────────────

cmd_status() {
    echo "=== Discovered Topology ==="
    for wan_if in "${WAN_IFS[@]}"; do
        local bridges=""
        for bridge in "${!BRIDGE_WAN[@]}"; do
            if [[ "${BRIDGE_WAN[$bridge]}" == "$wan_if" ]]; then
                bridges+="  $bridge → ${BRIDGE_PREFIX[$bridge]}"$'\n'
            fi
        done
        echo "$wan_if (table ${WAN_TABLE[$wan_if]}):"
        local has_default
        has_default=$(ip -6 route show table "${WAN_TABLE[$wan_if]}" 2>/dev/null | grep "^default" || true)
        echo "  default route: ${has_default:-(none)}"
        if [[ -n "$bridges" ]]; then
            echo "  PD bridges:"
            echo -n "$bridges" | sed 's/^/    /'
        fi
    done

    echo ""
    echo "=== Current State ==="
    echo "WAN state: $(detect_wan_state)"
    echo ""
    echo "Failover ip6 rules (priority $RULE_PRIORITY):"
    ip -6 rule show 2>/dev/null | grep "^${RULE_PRIORITY}:" || echo "  (none)"
    echo ""
    echo "Failover MASQUERADE rules:"
    ip6tables -t nat -S POSTROUTING 2>/dev/null | grep "$RULE_COMMENT" || echo "  (none)"
}

cmd_remove() {
    while ip -6 rule show 2>/dev/null | grep -q "^${RULE_PRIORITY}:"; do
        ip -6 rule del priority "$RULE_PRIORITY" 2>/dev/null || break
    done

    while ip6tables -t nat -S POSTROUTING 2>/dev/null | grep -q "$RULE_COMMENT"; do
        local rule
        rule=$(ip6tables -t nat -S POSTROUTING 2>/dev/null \
            | grep "$RULE_COMMENT" | head -1 | sed 's/^-A /-D /')
        eval "ip6tables -t nat $rule" 2>/dev/null || break
    done

    echo "All failover rules removed."
}

# ─── Main Loop ────────────────────────────────────────────────────

cleanup() {
    log "shutting down (state=$STATE)"
    if [[ "$STATE" != "normal" ]]; then
        log "WAN still down — failover rules left in place"
    fi
    exit 0
}

find_surviving_wan() {
    local dead_wan="$1"
    for wan_if in "${WAN_IFS[@]}"; do
        if [[ "$wan_if" != "$dead_wan" ]]; then
            echo "$wan_if"
            return
        fi
    done
}

run_daemon() {
    log "starting"
    trap cleanup EXIT INT TERM

    STATE=$(detect_wan_state)
    log "initial state: $STATE"

    if [[ "$STATE" != "normal" ]]; then
        local surviving
        surviving=$(find_surviving_wan "$STATE")
        apply_failover "$STATE" "$surviving"
    fi

    log "watching (${POLL_INTERVAL}s interval)"

    local last_discovery
    last_discovery=$(date +%s)

    while true; do
        sleep "$POLL_INTERVAL"

        # Periodically re-discover bridges during normal operation
        # to catch PD renewals with new prefixes
        if [[ "$STATE" == "normal" ]]; then
            local now
            now=$(date +%s)
            if (( now - last_discovery >= 60 )); then
                discover_bridges
                last_discovery=$now
            fi
        fi

        local new_state
        new_state=$(detect_wan_state)

        [[ "$new_state" == "$STATE" ]] && continue

        log "state change: $STATE → $new_state"

        # Remove existing failover rules before applying new ones
        [[ "$STATE" != "normal" ]] && remove_failover

        if [[ "$new_state" != "normal" ]]; then
            # Use cached bridge mapping — do NOT re-discover here.
            # The dead WAN's PD prefix may already be gone from the
            # routing table by the time the outage is detected.
            local surviving
            surviving=$(find_surviving_wan "$new_state")
            apply_failover "$new_state" "$surviving"
        else
            # Recovery — re-discover bridges in case PD changed
            discover_bridges
            last_discovery=$(date +%s)
        fi

        STATE="$new_state"
    done
}

# ─── Entry Point ──────────────────────────────────────────────────

case "${1:-}" in
    --status)
        discover
        cmd_status
        ;;
    --remove)
        cmd_remove
        ;;
    --help|-h)
        echo "Usage: $(basename "$0") [--status|--remove]"
        echo "  (no args)  Run failover daemon"
        echo "  --status   Show discovered topology and current state"
        echo "  --remove   Remove all failover rules"
        ;;
    *)
        discover
        run_daemon
        ;;
esac
