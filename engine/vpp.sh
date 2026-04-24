#!/usr/bin/env bash
# ============================================================================
# engine/vpp.sh — FD.io VPP data plane engine
# ============================================================================
# Manages VPP lifecycle, TAP interface creation via VPP, and L2 bridge-domain
# configuration. Fills the missing "setup-vpp-network.sh" gap from task3.
#
# Interface:
#   vpp_setup     <topology_yaml>   Start VPP, create TAPs, configure bridge-domain
#   vpp_teardown  [topology_yaml]   Stop VPP, clean up interfaces
#   vpp_status    [topology_yaml]   Show VPP runtime info
#   vpp_configure_bridge_domain     Configure L2 bridge-domain
# ============================================================================

set -euo pipefail

# Source libraries
_ENGINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_ENGINE_DIR}/../lib/common.sh"
source "${_ENGINE_DIR}/../lib/config.sh"
source "${_ENGINE_DIR}/../lib/network.sh"

# VPP PID file location (same directory as other vnctl PID files)
readonly _VPP_PID_FILE="${PID_DIR}/vpp.pid"

# ---------------------------------------------------------------------------
# VPP Control Helpers
# ---------------------------------------------------------------------------

# Execute a VPP CLI command via vppctl
_vppctl() {
    local cli_socket
    cli_socket=$(config_get "vpp_config.cli_socket" "/run/vpp/cli.sock")
    vppctl -s "$cli_socket" "$@" 2>/dev/null
}

# Wait for VPP to become ready (poll CLI socket)
_vpp_wait_ready() {
    local timeout="${1:-30}"
    local elapsed=0
    local log_file
    log_file=$(config_get "vpp_config.log_file" "/tmp/vpp.log")

    log_info "Waiting for VPP to become ready (timeout: ${timeout}s)..."
    while ! _vppctl show version &>/dev/null; do
        if [[ $elapsed -ge $timeout ]]; then
            log_error "Timeout waiting for VPP to start (${timeout}s)."
            log_error "Check VPP startup log: ${log_file}"
            # Print last 10 lines of VPP log to aid debugging
            if [[ -f "$log_file" ]]; then
                log_error "Last 10 lines of ${log_file}:"
                tail -10 "$log_file" | sed 's/^/  /' >&2
            fi
            return 1
        fi
        sleep 1
        ((elapsed++))
    done
    log_success "VPP is ready (took ${elapsed}s)."
}

# Check if VPP process is running (checks both pgrep and PID file)
_vpp_is_running() {
    # First check PID file (most reliable)
    if [[ -f "${_VPP_PID_FILE}" ]]; then
        local pid
        pid=$(cat "${_VPP_PID_FILE}" 2>/dev/null || true)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        # Stale PID file — clean it up
        rm -f "${_VPP_PID_FILE}"
    fi
    # Fallback: check by process name
    pgrep -x vpp &>/dev/null
}

# Get the running VPP PID
_vpp_get_pid() {
    if [[ -f "${_VPP_PID_FILE}" ]]; then
        cat "${_VPP_PID_FILE}" 2>/dev/null || true
    else
        pgrep -x vpp 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

vpp_setup() {
    local topology="$1"
    config_load "$topology"

    require_root
    require_commands vpp vppctl

    local bd_id bd_learn bd_forward bd_flood bd_uu_flood bd_arp_term
    bd_id=$(config_get "bridge_domain.id" "10")
    bd_learn=$(config_get "bridge_domain.learn" "true")
    bd_forward=$(config_get "bridge_domain.forward" "true")
    bd_flood=$(config_get "bridge_domain.flood" "true")
    bd_uu_flood=$(config_get "bridge_domain.uu_flood" "true")
    bd_arp_term=$(config_get "bridge_domain.arp_term" "false")

    local startup_conf
    startup_conf=$(config_get "vpp_config.startup_conf" "config/vpp/startup.conf")
    startup_conf=$(config_resolve_path "$startup_conf")

    log_header "VPP Bridge-Domain — Deploy"

    # Step 1: Verify prerequisites
    log_step "1/5" "Checking prerequisites"
    require_file "$startup_conf" "VPP startup.conf" || return 1
    log_success "All prerequisites met."

    # Step 2: Start VPP (if not already running)
    log_step "2/5" "Starting VPP"
    if _vpp_is_running; then
        log_info "VPP is already running (PID: $(_vpp_get_pid))."
    else
        local vpp_log
        vpp_log=$(config_get "vpp_config.log_file" "/tmp/vpp.log")
        log_info "Starting VPP with config: ${startup_conf}"
        log_info "VPP stdout/stderr → ${vpp_log}"

        # Launch VPP in background via nohup; startup.conf must NOT have 'nodaemon'
        # (nodaemon keeps VPP in foreground; we manage it as a background process)
        mkdir -p "${PID_DIR}"
        nohup vpp -c "$startup_conf" >> "${vpp_log}" 2>&1 &
        local vpp_bg_pid=$!
        echo "$vpp_bg_pid" > "${_VPP_PID_FILE}"
        log_info "VPP launched (PID: ${vpp_bg_pid}), waiting for CLI to become available..."

        # Give VPP a moment to either start or fail fast
        sleep 2
        if ! kill -0 "$vpp_bg_pid" 2>/dev/null; then
            log_error "VPP process exited immediately. Check log: ${vpp_log}"
            rm -f "${_VPP_PID_FILE}"
            return 1
        fi
    fi
    _vpp_wait_ready || return 1

    # Display VPP version
    local vpp_version
    vpp_version=$(_vppctl show version | head -1)
    log_info "VPP version: ${vpp_version}"

    # Step 3: Create TAP interfaces via VPP
    log_step "3/5" "Creating TAP interfaces"
    local vms
    vms=$(config_list_vms)
    local iface_index=0

    while IFS= read -r vm_name; do
        local host_tap
        host_tap=$(config_get "vms.${vm_name}.host_tap" "")
        if [[ -z "$host_tap" ]]; then
            host_tap=$(config_get "vms.${vm_name}.tap")
        fi

        if [[ -n "$host_tap" ]]; then
            # Check if TAP already exists in VPP
            if _vppctl show interface | grep -q "tap${iface_index}"; then
                log_info "VPP tap${iface_index} (host: ${host_tap}) already exists."
            else
                _vppctl create tap id "$iface_index" host-if-name "$host_tap"
                log_success "Created VPP tap${iface_index} → host '${host_tap}'."
            fi

            # Bring up VPP-side interface
            _vppctl set interface state "tap${iface_index}" up
            log_info "VPP tap${iface_index} is UP."

            ((iface_index++))
        fi
    done <<< "$vms"

    # Step 4: Configure L2 bridge-domain
    log_step "4/5" "Configuring L2 bridge-domain ${bd_id}"

    # Build bridge-domain flags
    local bd_flags=""
    [[ "$bd_learn" == "true" ]]     && bd_flags+=" learn"     || bd_flags+=" no-learn"
    [[ "$bd_forward" == "true" ]]   && bd_flags+=" forward"   || bd_flags+=" no-forward"
    [[ "$bd_flood" == "true" ]]     && bd_flags+=" flood"     || bd_flags+=" no-flood"
    [[ "$bd_uu_flood" == "true" ]]  && bd_flags+=" uu-flood"  || bd_flags+=" no-uu-flood"
    [[ "$bd_arp_term" == "true" ]]  && bd_flags+=" arp-term"  || bd_flags+=" no-arp-term"

    # Add interfaces to bridge-domain
    iface_index=0
    while IFS= read -r vm_name; do
        local host_tap
        host_tap=$(config_get "vms.${vm_name}.host_tap" "")
        if [[ -z "$host_tap" ]]; then
            host_tap=$(config_get "vms.${vm_name}.tap")
        fi

        if [[ -n "$host_tap" ]]; then
            _vppctl set interface l2 bridge "tap${iface_index}" "$bd_id"
            log_info "tap${iface_index} → bridge-domain ${bd_id}"
            ((iface_index++))
        fi
    done <<< "$vms"

    log_success "Bridge-domain ${bd_id} configured with${bd_flags}."

    # Step 5: Bring up host-side TAPs
    log_step "5/5" "Activating host-side interfaces"
    while IFS= read -r vm_name; do
        local host_tap
        host_tap=$(config_get "vms.${vm_name}.host_tap" "")
        if [[ -z "$host_tap" ]]; then
            host_tap=$(config_get "vms.${vm_name}.tap")
        fi

        if [[ -n "$host_tap" ]]; then
            wait_for_interface "$host_tap" 10 || true
            link_set_up "$host_tap"
        fi
    done <<< "$vms"

    # Summary
    log_header "VPP Bridge-Domain — Ready"
    echo ""
    echo "  VPP Interfaces:"
    _vppctl show interface | sed 's/^/    /'
    echo ""
    echo "  Bridge-Domain ${bd_id}:"
    _vppctl show bridge-domain "$bd_id" detail 2>/dev/null | sed 's/^/    /'
    echo ""
    echo "  Next: vnctl vm start <vm_name>"
    echo ""
}

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------

vpp_teardown() {
    local topology="${1:-}"

    require_root

    log_header "VPP — Teardown"

    # Step 1: Clean up TAP interfaces on host side
    log_step "1/3" "Removing host-side TAP interfaces"
    if [[ -n "$topology" ]]; then
        config_load "$topology"
        local vms
        vms=$(config_list_vms)
        while IFS= read -r vm_name; do
            local host_tap
            host_tap=$(config_get "vms.${vm_name}.host_tap" "")
            if [[ -z "$host_tap" ]]; then
                host_tap=$(config_get "vms.${vm_name}.tap")
            fi
            if [[ -n "$host_tap" ]]; then
                ensure_link_absent "$host_tap"
            fi
        done <<< "$vms"
    else
        # Best effort: remove common TAP names
        for tap in tap0 tap1 tap2 tap3; do
            ensure_link_absent "$tap"
        done
    fi

    # Step 2: Stop VPP
    log_step "2/3" "Stopping VPP"
    if _vpp_is_running; then
        local vpp_pid
        vpp_pid=$(_vpp_get_pid)
        log_info "Stopping VPP (PID: ${vpp_pid})..."
        kill "$vpp_pid" 2>/dev/null || true

        # Wait for graceful shutdown (up to 10s)
        local elapsed=0
        while kill -0 "$vpp_pid" 2>/dev/null && [[ $elapsed -lt 10 ]]; do
            sleep 1
            ((elapsed++))
        done

        if kill -0 "$vpp_pid" 2>/dev/null; then
            log_warn "VPP did not stop gracefully, sending SIGKILL..."
            kill -9 "$vpp_pid" 2>/dev/null || true
            sleep 1
        fi
        rm -f "${_VPP_PID_FILE}"
        log_success "VPP stopped."
    else
        log_info "VPP is not running."
    fi

    # Step 3: Clean up runtime files
    log_step "3/3" "Cleaning up runtime files"
    rm -f /run/vpp/cli.sock 2>/dev/null || true
    rm -f /dev/shm/vpp-stats-segment 2>/dev/null || true
    log_info "Runtime files cleaned."

    log_success "VPP teardown complete."
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------

vpp_status() {
    local topology="${1:-}"

    log_header "VPP — Status"

    if ! _vpp_is_running; then
        log_warn "VPP is not running."
        return 0
    fi

    local vpp_pid
    vpp_pid=$(_vpp_get_pid)
    log_info "VPP is running (PID: ${vpp_pid})"

    echo ""
    echo "  Version:"
    _vppctl show version | sed 's/^/    /'

    echo ""
    echo "  Interfaces:"
    _vppctl show interface | sed 's/^/    /'

    echo ""
    echo "  Bridge-Domains:"
    _vppctl show bridge-domain | sed 's/^/    /'

    echo ""
    echo "  L2 FIB:"
    _vppctl show l2fib verbose | sed 's/^/    /'

    echo ""
    echo "  Runtime:"
    _vppctl show runtime | head -30 | sed 's/^/    /'

    echo ""
    echo "  Errors:"
    _vppctl show errors | head -20 | sed 's/^/    /'
    echo ""
}

# ---------------------------------------------------------------------------
# Bridge-Domain Management
# ---------------------------------------------------------------------------

# Configure bridge-domain parameters
# Usage: vpp_configure_bridge_domain <bd_id> <learn|no-learn> <forward|no-forward> ...
vpp_configure_bridge_domain() {
    local bd_id="$1"; shift
    local flags="$*"

    if ! _vpp_is_running; then
        log_error "VPP is not running."
        return 1
    fi

    _vppctl set bridge-domain "$bd_id" "$flags"
    log_success "Bridge-domain ${bd_id} updated: ${flags}"
}
