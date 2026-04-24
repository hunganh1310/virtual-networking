#!/usr/bin/env bash
# ============================================================================
# engine/linux-bridge.sh — Linux Bridge data plane engine
# ============================================================================
# Creates and manages a Linux kernel bridge with TAP interfaces for VM
# connectivity. Refactored from task1-qemu-kvm/scripts/setup-network.sh.
#
# Interface:
#   lb_setup   <topology_yaml>   Deploy bridge + TAPs
#   lb_teardown <topology_yaml>  Tear down everything
#   lb_status                    Show bridge info
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

lb_setup() {
    local topology="$1"
    config_load "$topology"

    require_root
    require_commands ip

    local bridge_name bridge_ip stp
    bridge_name=$(config_require "bridge.name")
    bridge_ip=$(config_require "bridge.ip")
    stp=$(config_get "bridge.stp" "false")

    local total_steps=5
    local step=0

    log_header "Linux Bridge — Deploy"

    # Step 1: Prerequisites
    ((step++))
    log_step "${step}/${total_steps}" "Checking prerequisites"
    require_commands ip
    log_success "All tools available."

    # Step 2: Create bridge
    ((step++))
    log_step "${step}/${total_steps}" "Creating Linux bridge: ${bridge_name}"
    bridge_create "$bridge_name"

    if [[ "$stp" == "false" ]]; then
        bridge_disable_stp "$bridge_name"
    fi

    # Step 3: Create TAP interfaces
    ((step++))
    log_step "${step}/${total_steps}" "Creating TAP interfaces"
    local user
    user=$(logname 2>/dev/null || echo "${SUDO_USER:-$(whoami)}")

    local vms
    vms=$(config_list_vms)
    while IFS= read -r vm_name; do
        local tap
        tap=$(config_get "vms.${vm_name}.tap")
        if [[ -n "$tap" ]]; then
            tap_create "$tap" "$user"
        fi
    done <<< "$vms"

    # Step 4: Attach TAPs to bridge
    ((step++))
    log_step "${step}/${total_steps}" "Attaching ports to bridge"
    while IFS= read -r vm_name; do
        local tap
        tap=$(config_get "vms.${vm_name}.tap")
        if [[ -n "$tap" ]]; then
            bridge_add_port "$bridge_name" "$tap"
        fi
    done <<< "$vms"

    # Step 5: Bring up & assign IP
    ((step++))
    log_step "${step}/${total_steps}" "Activating interfaces"
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
    log_header "Linux Bridge — Ready"
    echo "  Bridge : ${bridge_name} (${bridge_ip})"
    local vm_list_str=""
    while IFS= read -r vm_name; do
        local tap ip
        tap=$(config_get "vms.${vm_name}.tap")
        ip=$(config_get "vms.${vm_name}.ip" "dhcp")
        echo "  ${vm_name}   : ${tap} → ${bridge_name}  (expected IP: ${ip})"
    done <<< "$vms"

    echo ""
    echo "  Verify: ip addr show ${bridge_name}"
    echo "  Next:   vnctl vm start <vm_name>"
    echo ""
}

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------

lb_teardown() {
    local topology="$1"
    config_load "$topology"

    require_root

    local bridge_name
    bridge_name=$(config_require "bridge.name")

    log_header "Linux Bridge — Teardown"

    # Remove TAP interfaces
    log_step "1/2" "Removing TAP interfaces"
    local vms
    vms=$(config_list_vms)
    while IFS= read -r vm_name; do
        local tap
        tap=$(config_get "vms.${vm_name}.tap")
        if [[ -n "$tap" ]]; then
            tap_delete "$tap"
        fi
    done <<< "$vms"

    # Remove bridge
    log_step "2/2" "Removing bridge: ${bridge_name}"
    ensure_link_absent "$bridge_name"

    log_success "Linux Bridge teardown complete."
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------

lb_status() {
    local topology="${1:-}"

    log_header "Linux Bridge — Status"

    if [[ -n "$topology" ]]; then
        config_load "$topology"
        local bridge_name
        bridge_name=$(config_get "bridge.name" "br-test")

        if link_exists "$bridge_name"; then
            echo ""
            echo "  Bridge: ${bridge_name}"
            echo ""
            ip -d link show "$bridge_name" 2>/dev/null | sed 's/^/    /'
            echo ""
            echo "  Ports:"
            bridge link show 2>/dev/null | grep "$bridge_name" | sed 's/^/    /' || echo "    (none)"
            echo ""
            echo "  IP:"
            ip addr show "$bridge_name" | grep inet | sed 's/^/    /'
            echo ""
            echo "  FDB:"
            bridge fdb show br "$bridge_name" 2>/dev/null | head -20 | sed 's/^/    /'
        else
            log_warn "Bridge '${bridge_name}' does not exist."
        fi
    else
        # Show all Linux bridges
        echo ""
        bridge link show 2>/dev/null | sed 's/^/  /' || echo "  No bridges found."
    fi
    echo ""
}
