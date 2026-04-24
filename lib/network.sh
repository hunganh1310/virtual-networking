#!/usr/bin/env bash
# ============================================================================
# lib/network.sh — Network primitive operations
# ============================================================================
# Provides idempotent TAP/bridge creation and teardown, IP assignment, and
# interface state management. Used by all engine backends.
#
# Usage: source lib/network.sh
# ============================================================================

# Guard against double-sourcing
[[ -n "${_NETWORK_SH_LOADED:-}" ]] && return 0
readonly _NETWORK_SH_LOADED=1

# Source common.sh if not already loaded
if [[ -z "${LIB_DIR:-}" ]]; then
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
fi

# ---------------------------------------------------------------------------
# TAP Interface Management
# ---------------------------------------------------------------------------

# Create a TAP interface (idempotent)
# Usage: tap_create <name> [user]
tap_create() {
    local name="$1"
    local user="${2:-}"

    if link_exists "$name"; then
        log_info "TAP '${name}' already exists, skipping."
        return 0
    fi

    local cmd=(ip tuntap add dev "$name" mode tap)
    if [[ -n "$user" ]]; then
        cmd+=(user "$user")
    fi

    "${cmd[@]}"
    log_success "Created TAP interface '${name}'."
}

# Delete a TAP interface (idempotent)
# Usage: tap_delete <name>
tap_delete() {
    ensure_link_absent "$1"
}

# ---------------------------------------------------------------------------
# Interface State Management
# ---------------------------------------------------------------------------

# Bring an interface up
# Usage: link_set_up <name>
link_set_up() {
    local name="$1"
    if ! link_exists "$name"; then
        log_error "Cannot bring up '${name}': interface does not exist."
        return 1
    fi
    ip link set "$name" up
    log_info "Interface '${name}' is UP."
}

# Bring an interface down
# Usage: link_set_down <name>
link_set_down() {
    local name="$1"
    if ! link_exists "$name"; then
        log_info "Interface '${name}' does not exist, nothing to bring down."
        return 0
    fi
    ip link set "$name" down 2>/dev/null || true
    log_info "Interface '${name}' is DOWN."
}

# ---------------------------------------------------------------------------
# IP Address Management
# ---------------------------------------------------------------------------

# Assign an IP address to an interface (flush existing first for idempotency)
# Usage: ip_assign <device> <cidr>
ip_assign() {
    local dev="$1"
    local cidr="$2"

    if ! link_exists "$dev"; then
        log_error "Cannot assign IP to '${dev}': interface does not exist."
        return 1
    fi

    ip addr flush dev "$dev" 2>/dev/null || true
    ip addr add "$cidr" dev "$dev"
    log_success "Assigned ${cidr} to '${dev}'."
}

# Get the first IPv4 address on an interface
# Usage: ip_get <device>
ip_get() {
    local dev="$1"
    ip -4 addr show dev "$dev" 2>/dev/null | awk '/inet / { print $2; exit }'
}

# ---------------------------------------------------------------------------
# Linux Bridge Operations
# ---------------------------------------------------------------------------

# Create a Linux bridge (idempotent)
# Usage: bridge_create <name>
bridge_create() {
    local name="$1"

    if link_exists "$name"; then
        log_info "Bridge '${name}' already exists, skipping."
        return 0
    fi

    ip link add name "$name" type bridge
    log_success "Created Linux bridge '${name}'."
}

# Delete a Linux bridge (idempotent)
# Usage: bridge_delete <name>
bridge_delete() {
    ensure_link_absent "$1"
}

# Add a port to a Linux bridge (idempotent)
# Usage: bridge_add_port <bridge> <port>
bridge_add_port() {
    local bridge="$1"
    local port="$2"

    # Check if already attached
    local current_master
    current_master=$(ip -o link show "$port" 2>/dev/null | grep -oP 'master \K\S+' || true)
    if [[ "$current_master" == "$bridge" ]]; then
        log_info "Port '${port}' already attached to '${bridge}', skipping."
        return 0
    fi

    ip link set "$port" master "$bridge"
    log_success "Attached '${port}' → '${bridge}'."
}

# Remove a port from a bridge
# Usage: bridge_del_port <port>
bridge_del_port() {
    local port="$1"
    ip link set "$port" nomaster 2>/dev/null || true
}

# Disable STP on a bridge
# Usage: bridge_disable_stp <bridge>
bridge_disable_stp() {
    local bridge="$1"
    ip link set "$bridge" type bridge stp_state 0 2>/dev/null || true
    log_info "STP disabled on '${bridge}'."
}

# Enable IP forwarding (required for host to route between VMs)
# Usage: enable_ip_forwarding
enable_ip_forwarding() {
    sysctl -q -w net.ipv4.ip_forward=1
    log_info "IP forwarding enabled."
}

# ---------------------------------------------------------------------------
# Wait/Poll Helpers
# ---------------------------------------------------------------------------

# Wait for an interface to appear (with timeout)
# Usage: wait_for_interface <name> [timeout_seconds]
wait_for_interface() {
    local name="$1"
    local timeout="${2:-10}"
    local elapsed=0

    while ! link_exists "$name"; do
        if [[ $elapsed -ge $timeout ]]; then
            log_error "Timeout waiting for interface '${name}' (${timeout}s)."
            return 1
        fi
        sleep 1
        ((elapsed++))
    done

    log_info "Interface '${name}' is available."
    return 0
}

# Display interface summary
# Usage: show_interfaces <name1> [name2] ...
show_interfaces() {
    echo ""
    for iface in "$@"; do
        if link_exists "$iface"; then
            local state ip_addr mac_addr
            state=$(ip -o link show "$iface" | awk '{ print $9 }')
            ip_addr=$(ip_get "$iface")
            mac_addr=$(ip -o link show "$iface" | awk '{ print $17 }')
            printf "  %-15s  state=%-6s  ip=%-18s  mac=%s\n" \
                "$iface" "${state:-unknown}" "${ip_addr:-none}" "${mac_addr:-unknown}"
        else
            printf "  %-15s  [not found]\n" "$iface"
        fi
    done
    echo ""
}
