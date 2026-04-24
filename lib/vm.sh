#!/usr/bin/env bash
# ============================================================================
# lib/vm.sh — VM lifecycle management
# ============================================================================
# Unified VM launch/stop/status functions. Replaces 6 duplicated launch
# scripts by reading VM parameters from YAML topology definitions.
#
# Usage:
#   source lib/vm.sh
#   config_load config/topology/ovs-bridge.yaml
#   vm_launch vm1
#   vm_launch vm2
#   vm_list
#   vm_stop vm2
# ============================================================================

# Guard against double-sourcing
[[ -n "${_VM_SH_LOADED:-}" ]] && return 0
readonly _VM_SH_LOADED=1

# Source dependencies
if [[ -z "${LIB_DIR:-}" ]]; then
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
fi
source "${LIB_DIR}/config.sh"

# ---------------------------------------------------------------------------
# VM Launch
# ---------------------------------------------------------------------------

# Launch a VM using parameters from the loaded topology
# Usage: vm_launch <vm_name>
vm_launch() {
    local vm_name="$1"

    require_commands qemu-system-x86_64

    # Read VM config from topology YAML
    local image_file tap_iface mac_addr mode
    local ram vcpus kernel_args
    local console_port monitor_port

    image_file=$(config_get "vms.${vm_name}.image")
    tap_iface=$(config_get "vms.${vm_name}.tap")
    mac_addr=$(config_get "vms.${vm_name}.mac")
    mode=$(config_get "vms.${vm_name}.mode" "foreground")
    ram=$(config_get "vms.${vm_name}.ram" "$(config_get 'vm_defaults.ram' '1024')")
    vcpus=$(config_get "vms.${vm_name}.vcpus" "$(config_get 'vm_defaults.vcpus' '2')")
    kernel_args=$(config_get "vm_defaults.kernel_args" "console=ttyS0,115200 net.ifnames=0 biosdevname=0 hugepages=0 rw")
    console_port=$(config_get "vms.${vm_name}.console_port" "")
    monitor_port=$(config_get "vms.${vm_name}.monitor_port" "")

    # Resolve image path
    local image_path="${IMAGES_DIR}/${image_file}"
    local kernel_path="${BOOT_DIR}/vmlinuz"
    local initrd_path="${BOOT_DIR}/initrd"

    # Validate prerequisites
    require_file "$image_path" "VM disk image" || return 1
    require_file "$kernel_path" "Kernel" || return 1
    require_file "$initrd_path" "Initrd" || return 1

    if ! link_exists "$tap_iface"; then
        log_error "TAP interface '${tap_iface}' not found."
        log_error "Deploy the network first: vnctl deploy <topology>"
        return 1
    fi

    if ! is_valid_mac "$mac_addr"; then
        log_error "Invalid MAC address: ${mac_addr}"
        return 1
    fi

    # Check if VM is already running
    local pid_file="${PID_DIR}/${vm_name}.pid"
    if pid_is_running "$pid_file"; then
        local existing_pid
        existing_pid=$(get_pid "$pid_file")
        log_warn "${vm_name} is already running (PID: ${existing_pid})."
        log_warn "Stop it first: vnctl vm stop ${vm_name}"
        return 1
    fi

    # Determine vhost setting
    local vhost_flag=""
    local vhost_setting
    vhost_setting=$(config_get "vm_defaults.vhost" "true")
    if [[ "$vhost_setting" == "true" ]]; then
        vhost_flag=",vhost=on"
    fi

    # Get machine and CPU type
    local machine cpu
    machine=$(config_get "vm_defaults.machine" "q35,accel=kvm")
    cpu=$(config_get "vm_defaults.cpu" "host")

    # Build QEMU command
    local -a qemu_cmd=(
        qemu-system-x86_64
        -name "$vm_name"
        -machine "$machine"
        -cpu "$cpu"
        -m "$ram"
        -smp "$vcpus"
        -drive "file=${image_path},format=qcow2,if=virtio"
        -netdev "tap,id=net0,ifname=${tap_iface},script=no,downscript=no${vhost_flag}"
        -device "virtio-net-pci,netdev=net0,mac=${mac_addr}"
        -kernel "$kernel_path"
        -initrd "$initrd_path"
        -append "root=/dev/vda1 ${kernel_args}"
    )

    local role
    role=$(config_get "vms.${vm_name}.role" "$vm_name")

    if [[ "$mode" == "background" ]]; then
        # Background mode: daemonize with telnet console
        local c_port="${console_port:-5556}"
        local m_port="${monitor_port:-55501}"

        qemu_cmd+=(
            -display none
            -serial "telnet:127.0.0.1:${c_port},server,nowait"
            -monitor "telnet:127.0.0.1:${m_port},server,nowait"
            -pidfile "$pid_file"
            -daemonize
        )

        log_header "Launching ${vm_name} (${role}) — BACKGROUND"
        echo "  Image   : ${image_path}"
        echo "  RAM     : ${ram} MB"
        echo "  vCPUs   : ${vcpus}"
        echo "  NIC     : virtio → ${tap_iface}"
        echo "  Console : telnet 127.0.0.1 ${c_port}"
        echo "  Monitor : telnet 127.0.0.1 ${m_port}"
        echo ""

        "${qemu_cmd[@]}"

        local launched_pid
        launched_pid=$(cat "$pid_file" 2>/dev/null || echo "unknown")
        log_success "${vm_name} launched in background (PID: ${launched_pid})."
        echo "  → Connect: telnet 127.0.0.1 ${c_port}"
        echo "  → Login:   root / linux"
    else
        # Foreground mode: serial console to stdio
        qemu_cmd+=(
            -nographic
            -serial mon:stdio
        )

        # Store PID for tracking (best effort since foreground QEMU blocks)
        log_header "Launching ${vm_name} (${role}) — FOREGROUND"
        echo "  Image   : ${image_path}"
        echo "  RAM     : ${ram} MB"
        echo "  vCPUs   : ${vcpus}"
        echo "  NIC     : virtio → ${tap_iface}"
        echo "  Console : serial (Ctrl+A, X to exit)"
        echo "  Login   : root / linux"
        echo ""

        # Execute (blocks until VM exits)
        "${qemu_cmd[@]}"
    fi
}

# ---------------------------------------------------------------------------
# VM Stop
# ---------------------------------------------------------------------------

# Stop a specific VM or all VMs
# Usage: vm_stop <vm_name|all>
vm_stop() {
    local target="$1"

    if [[ "$target" == "all" ]]; then
        log_info "Stopping all VMs..."
        local found=0
        for pid_file in "${PID_DIR}"/*.pid; do
            [[ -f "$pid_file" ]] || continue
            local name
            name=$(basename "$pid_file" .pid)
            stop_process "$pid_file" "$name"
            found=1
        done

        # Also kill any foreground QEMU processes
        if pgrep -f "qemu-system.*-name" &>/dev/null; then
            log_info "Killing remaining QEMU processes..."
            pkill -f "qemu-system.*-name" 2>/dev/null || true
            sleep 1
            found=1
        fi

        if [[ $found -eq 0 ]]; then
            log_info "No running VMs found."
        fi
    else
        local pid_file="${PID_DIR}/${target}.pid"

        # Try PID file first
        if pid_is_running "$pid_file"; then
            stop_process "$pid_file" "$target"
        else
            # Fallback: try to find by QEMU name
            local pid
            pid=$(pgrep -f "qemu-system.*-name ${target}" 2>/dev/null || true)
            if [[ -n "$pid" ]]; then
                log_info "Stopping ${target} (PID: ${pid})..."
                kill "$pid" 2>/dev/null || true
                sleep 2
                kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
                rm -f "$pid_file"
                log_success "${target} stopped."
            else
                log_info "${target} is not running."
            fi
        fi
    fi
}

# ---------------------------------------------------------------------------
# VM Status
# ---------------------------------------------------------------------------

# List all VMs and their status
# Usage: vm_list
vm_list() {
    log_header "VM Status"
    printf "  %-12s  %-8s  %-8s  %-10s  %s\n" "NAME" "STATUS" "PID" "RAM" "CONSOLE"
    printf "  %-12s  %-8s  %-8s  %-10s  %s\n" "────" "──────" "───" "───" "───────"

    local found=0

    # Check PID files
    for pid_file in "${PID_DIR}"/*.pid; do
        [[ -f "$pid_file" ]] || continue
        local name pid status
        name=$(basename "$pid_file" .pid)
        pid=$(cat "$pid_file")

        if kill -0 "$pid" 2>/dev/null; then
            status="${_CLR_GREEN}running${_CLR_RESET}"

            # Try to detect console port from process args
            local console_port
            console_port=$(ps -p "$pid" -o args= 2>/dev/null | grep -oP 'telnet:127\.0\.0\.1:\K\d+' | head -1 || echo "stdio")
            local ram
            ram=$(ps -p "$pid" -o args= 2>/dev/null | grep -oP '(?<=-m )\d+' || echo "?")

            printf "  %-12s  ${status}  %-8s  %-10s  %s\n" "$name" "$pid" "${ram}MB" "telnet 127.0.0.1:${console_port}"
        else
            status="${_CLR_RED}dead${_CLR_RESET}"
            printf "  %-12s  ${status}     %-8s  %-10s  %s\n" "$name" "$pid" "-" "-"
            rm -f "$pid_file"
        fi
        found=1
    done

    # Also check for foreground QEMU processes not tracked by PID files
    while IFS= read -r line; do
        local name pid
        pid=$(echo "$line" | awk '{print $1}')
        name=$(echo "$line" | grep -oP '(?<=-name )\S+' || echo "unknown")

        # Skip if already listed
        [[ -f "${PID_DIR}/${name}.pid" ]] && continue

        local status="${_CLR_GREEN}running${_CLR_RESET}"
        local ram
        ram=$(echo "$line" | grep -oP '(?<=-m )\d+' || echo "?")
        printf "  %-12s  ${status}  %-8s  %-10s  %s\n" "$name" "$pid" "${ram}MB" "stdio"
        found=1
    done < <(pgrep -af "qemu-system.*-name" 2>/dev/null || true)

    if [[ $found -eq 0 ]]; then
        echo "  No running VMs."
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# VM Console
# ---------------------------------------------------------------------------

# Attach to a background VM's console
# Usage: vm_console <vm_name>
vm_console() {
    local vm_name="$1"

    require_commands telnet

    # Try to find console port from process args
    local pid_file="${PID_DIR}/${vm_name}.pid"
    if ! pid_is_running "$pid_file"; then
        log_error "${vm_name} is not running."
        return 1
    fi

    local pid console_port
    pid=$(cat "$pid_file")
    console_port=$(ps -p "$pid" -o args= 2>/dev/null | grep -oP 'telnet:127\.0\.0\.1:\K\d+' | head -1 || true)

    if [[ -z "$console_port" ]]; then
        log_error "Cannot determine console port for ${vm_name}."
        log_error "The VM may be running in foreground mode."
        return 1
    fi

    log_info "Connecting to ${vm_name} console on port ${console_port}..."
    log_info "Disconnect: Ctrl+], then type 'quit'"
    echo ""
    telnet 127.0.0.1 "$console_port"
}
