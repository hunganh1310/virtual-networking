#!/usr/bin/env bash
# ============================================================================
# engine/ovs.sh — Open vSwitch data plane engine
# ============================================================================
# Creates and manages an OVS bridge with TAP interfaces. Supports OpenFlow
# rule management, datapath selection, and flow table inspection.
# Refactored from task2-ovs/scripts/setup-ovs-network.sh.
#
# Interface:
#   ovs_setup     <topology_yaml>  Deploy OVS bridge + TAPs
#   ovs_teardown  <topology_yaml>  Tear down everything
#   ovs_status    [topology_yaml]  Show OVS bridge info
#   ovs_add_flow  <bridge> <spec>  Add OpenFlow rule
#   ovs_dump_flows <bridge>        Show flow table
# ============================================================================

set -euo pipefail

# Source libraries
_ENGINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_ENGINE_DIR}/../lib/common.sh"
source "${_ENGINE_DIR}/../lib/config.sh"
source "${_ENGINE_DIR}/../lib/network.sh"

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

ovs_setup() {
    local topology="$1"
    config_load "$topology"

    require_root
    require_commands ip ovs-vsctl ovs-ofctl

    local bridge_name bridge_ip datapath fail_mode protocols
    bridge_name=$(config_require "bridge.name")
    bridge_ip=$(config_require "bridge.ip")
    datapath=$(config_get "bridge.datapath" "system")
    fail_mode=$(config_get "bridge.fail_mode" "standalone")
    protocols=$(config_get "bridge.protocols" "")

    log_header "OVS Bridge — Deploy"

    # Step 1: Verify OVS service
    log_step "1/5" "Verifying OVS service"
    require_service openvswitch

    # Step 2: Create OVS bridge (idempotent)
    log_step "2/5" "Creating OVS bridge: ${bridge_name}"
    if ovs-vsctl br-exists "$bridge_name" 2>/dev/null; then
        log_info "OVS bridge '${bridge_name}' already exists."
    else
        local br_cmd="ovs-vsctl add-br ${bridge_name}"
        if [[ "$datapath" == "netdev" ]]; then
            br_cmd+=" -- set bridge ${bridge_name} datapath_type=netdev"
        fi
        eval "$br_cmd"
        log_success "Created OVS bridge '${bridge_name}' (datapath: ${datapath})."
    fi

    # Set fail mode
    ovs-vsctl set-fail-mode "$bridge_name" "$fail_mode" 2>/dev/null || true

    # Set OpenFlow protocols
    if [[ -n "$protocols" ]]; then
        ovs-vsctl set bridge "$bridge_name" protocols="$protocols" 2>/dev/null || true
        log_info "OpenFlow protocols: ${protocols}"
    fi

    # Step 3: Create TAP interfaces
    log_step "3/5" "Creating TAP interfaces"
    local vms
    vms=$(config_list_vms)
    while IFS= read -r vm_name; do
        local tap
        tap=$(config_get "vms.${vm_name}.tap")
        if [[ -n "$tap" ]]; then
            # Remove existing TAP to ensure clean state
            if link_exists "$tap"; then
                log_info "TAP '${tap}' exists, recreating for clean OVS attachment."
                ip link delete "$tap" 2>/dev/null || true
                sleep 0.5
            fi
            ip tuntap add dev "$tap" mode tap
            log_success "Created TAP '${tap}'."
        fi
    done <<< "$vms"

    # Step 4: Add ports to OVS bridge
    log_step "4/5" "Adding ports to OVS bridge"
    while IFS= read -r vm_name; do
        local tap
        tap=$(config_get "vms.${vm_name}.tap")
        if [[ -n "$tap" ]]; then
            # Check if port already exists on bridge
            if ovs-vsctl list-ports "$bridge_name" | grep -qx "$tap"; then
                log_info "Port '${tap}' already on '${bridge_name}', skipping."
            else
                ovs-vsctl add-port "$bridge_name" "$tap"
                log_success "Added port '${tap}' → '${bridge_name}'."
            fi
        fi
    done <<< "$vms"

    # Step 5: Bring up interfaces & assign IP
    log_step "5/5" "Activating interfaces"
    link_set_up "$bridge_name"

    while IFS= read -r vm_name; do
        local tap
        tap=$(config_get "vms.${vm_name}.tap")
        if [[ -n "$tap" ]]; then
            link_set_up "$tap"
        fi
    done <<< "$vms"

    ip_assign "$bridge_name" "$bridge_ip"
    enable_ip_forwarding

    # Summary
    log_header "OVS Bridge — Ready"
    echo ""
    echo "  Bridge Info:"
    ovs-vsctl show 2>/dev/null | sed 's/^/    /'
    echo ""
    echo "  Ports:"
    ovs-vsctl list-ports "$bridge_name" 2>/dev/null | sed 's/^/    /'
    echo ""
    echo "  IP:"
    ip addr show "$bridge_name" | grep inet | sed 's/^/    /'
    echo ""
    echo "  Next: vnctl vm start <vm_name>"
    echo ""
}

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------

ovs_teardown() {
    local topology="$1"
    config_load "$topology"

    require_root
    require_commands ovs-vsctl

    local bridge_name
    bridge_name=$(config_require "bridge.name")

    log_header "OVS Bridge — Teardown"

    # Remove OVS bridge (this also removes all ports)
    log_step "1/2" "Removing OVS bridge: ${bridge_name}"
    ovs-vsctl --if-exists del-br "$bridge_name"
    log_success "OVS bridge '${bridge_name}' removed."

    # Clean up TAP interfaces (OVS del-br doesn't remove TAPs)
    log_step "2/2" "Cleaning up TAP interfaces"
    local vms
    vms=$(config_list_vms)
    while IFS= read -r vm_name; do
        local tap
        tap=$(config_get "vms.${vm_name}.tap")
        if [[ -n "$tap" ]]; then
            tap_delete "$tap"
        fi
    done <<< "$vms"

    log_success "OVS teardown complete."
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------

ovs_status() {
    local topology="${1:-}"

    require_commands ovs-vsctl ovs-ofctl ovs-dpctl

    log_header "OVS Bridge — Status"

    if [[ -n "$topology" ]]; then
        config_load "$topology"
        local bridge_name
        bridge_name=$(config_get "bridge.name" "ovs-br0")

        if ovs-vsctl br-exists "$bridge_name" 2>/dev/null; then
            echo ""
            echo "  Bridge Configuration:"
            ovs-vsctl show 2>/dev/null | sed 's/^/    /'
            echo ""
            echo "  Ports:"
            ovs-vsctl list-ports "$bridge_name" 2>/dev/null | sed 's/^/    /'
            echo ""
            echo "  Flow Table:"
            ovs_dump_flows "$bridge_name" 2>/dev/null
            echo ""
            echo "  Datapath Stats:"
            ovs-dpctl show 2>/dev/null | sed 's/^/    /'
            echo ""
            echo "  MAC Table:"
            ovs-appctl fdb/show "$bridge_name" 2>/dev/null | sed 's/^/    /'
        else
            log_warn "OVS bridge '${bridge_name}' does not exist."
        fi
    else
        ovs-vsctl show 2>/dev/null | sed 's/^/  /'
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# Flow Management
# ---------------------------------------------------------------------------

# Add an OpenFlow rule
# Usage: ovs_add_flow <bridge> <flow_spec>
# Example: ovs_add_flow ovs-br0 "priority=100,dl_dst=52:54:00:00:00:01,actions=output:1"
ovs_add_flow() {
    local bridge="$1"
    local flow_spec="$2"

    ovs-ofctl add-flow "$bridge" "$flow_spec"
    log_success "Added flow to '${bridge}': ${flow_spec}"
}

# Delete OpenFlow rules matching a specification
# Usage: ovs_del_flow <bridge> <match_spec>
ovs_del_flow() {
    local bridge="$1"
    local match_spec="${2:-}"

    if [[ -n "$match_spec" ]]; then
        ovs-ofctl del-flows "$bridge" "$match_spec"
        log_info "Deleted flows matching '${match_spec}' from '${bridge}'."
    else
        ovs-ofctl del-flows "$bridge"
        log_info "Deleted all flows from '${bridge}'."
    fi
}

# Dump flow table in readable format
# Usage: ovs_dump_flows <bridge>
ovs_dump_flows() {
    local bridge="$1"
    echo "  Flow Table (${bridge}):"
    ovs-ofctl dump-flows "$bridge" 2>/dev/null | sed 's/^/    /'
}
