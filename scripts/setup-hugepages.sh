#!/usr/bin/env bash
# ============================================================================
# scripts/setup-hugepages.sh — Idempotent HugePage Configuration
# ============================================================================
# Configures 2MB HugePages for VPP and DPDK workloads.
# Supports both runtime allocation and persistent grub configuration.
#
# USAGE:
#   sudo ./scripts/setup-hugepages.sh              # Allocate 512 × 2MB pages (1GB)
#   sudo ./scripts/setup-hugepages.sh --count 1024  # Allocate 1024 × 2MB pages (2GB)
#   sudo ./scripts/setup-hugepages.sh --check        # Show current allocation
#   sudo ./scripts/setup-hugepages.sh --persistent   # Also configure grub for reboot
#
# VPP REQUIREMENTS:
#   - TAP mode:   64–256 pages (128MB–512MB) sufficient for lab
#   - DPDK mode:  256–512 pages (512MB–1GB) recommended
#   - buffers-per-numa 65536 in startup.conf requires ~128MB hugepages
#
# OVS-DPDK REQUIREMENTS:
#   - dpdk-socket-mem="512,0" → 256 × 2MB = 512MB
#   - Minimum: 128 pages
#
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${PROJECT_ROOT}/lib/common.sh"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
readonly HP_SIZE_KB=2048        # 2MB pages
readonly HP_SIZE_MB=2
readonly DEFAULT_COUNT=512      # 512 × 2MB = 1GB
readonly HP_SYSFS="/sys/kernel/mm/hugepages/hugepages-${HP_SIZE_KB}kB"
readonly GRUB_FILE="/etc/default/grub"

# ---------------------------------------------------------------------------
# Functions
# ---------------------------------------------------------------------------

show_status() {
    local total free reserved
    total=$(cat "${HP_SYSFS}/nr_hugepages"   2>/dev/null || echo "0")
    free=$(cat  "${HP_SYSFS}/free_hugepages" 2>/dev/null || echo "0")
    reserved=$(cat "${HP_SYSFS}/resv_hugepages" 2>/dev/null || echo "0")
    local used=$((total - free))
    local total_mb=$((total * HP_SIZE_MB))

    echo ""
    log_header "HugePages Status (2MB)"
    printf "  %-20s %s\n"  "Total allocated:"  "${total} pages (${total_mb} MB)"
    printf "  %-20s %s\n"  "Free:"             "${free} pages"
    printf "  %-20s %s\n"  "In use:"           "${used} pages"
    printf "  %-20s %s\n"  "Reserved:"         "${reserved} pages"
    printf "  %-20s %s\n"  "Mount:"            "$(grep hugetlbfs /proc/mounts | head -1 | awk '{print $2}' || echo 'not mounted')"
    echo ""

    if [[ $total -eq 0 ]]; then
        log_warn "No hugepages allocated. VPP/DPDK will fall back to regular pages (lower performance)."
    elif [[ $free -lt 64 ]]; then
        log_warn "Low free hugepages (${free} remaining). Consider increasing allocation."
    else
        log_success "HugePages look healthy."
    fi
}

allocate_hugepages() {
    local count="$1"
    local current
    current=$(cat "${HP_SYSFS}/nr_hugepages" 2>/dev/null || echo "0")

    if [[ "$current" -eq "$count" ]]; then
        log_info "HugePages already set to ${count} (${HP_SIZE_MB}MB each = $((count * HP_SIZE_MB)) MB total). No change."
        return 0
    fi

    log_info "Setting hugepages: ${current} → ${count} (${HP_SIZE_MB}MB each)"
    log_info "Allocating $((count * HP_SIZE_MB)) MB of contiguous physical memory..."

    # Runtime allocation (works without reboot, may fail if memory fragmented)
    echo "$count" > "${HP_SYSFS}/nr_hugepages" || {
        log_error "Failed to allocate hugepages via sysfs."
        log_error "Try after a fresh reboot (less memory fragmentation)."
        log_error "Or add to kernel cmdline: hugepages=${count}"
        return 1
    }

    # Verify allocation succeeded (kernel may grant fewer than requested)
    local actual
    actual=$(cat "${HP_SYSFS}/nr_hugepages")
    if [[ "$actual" -lt "$count" ]]; then
        log_warn "Requested ${count} pages but only got ${actual}."
        log_warn "Memory may be fragmented. Try after a reboot."
    else
        log_success "Allocated ${actual} × ${HP_SIZE_MB}MB hugepages ($((actual * HP_SIZE_MB)) MB total)."
    fi
}

mount_hugetlbfs() {
    local mountpoint="/dev/hugepages"

    if grep -q hugetlbfs /proc/mounts; then
        log_info "hugetlbfs already mounted at: $(grep hugetlbfs /proc/mounts | awk '{print $2}' | head -1)"
        return 0
    fi

    mkdir -p "$mountpoint"
    mount -t hugetlbfs none "$mountpoint" 2>/dev/null || {
        log_warn "Could not mount hugetlbfs (may already be handled by systemd)."
        return 0
    }
    log_success "hugetlbfs mounted at ${mountpoint}"

    # Make it persistent across reboots
    if ! grep -q hugetlbfs /etc/fstab; then
        echo "none  ${mountpoint}  hugetlbfs  defaults  0  0" >> /etc/fstab
        log_info "Added hugetlbfs to /etc/fstab for persistence."
    fi
}

make_persistent_grub() {
    local count="$1"

    if [[ ! -f "$GRUB_FILE" ]]; then
        log_warn "GRUB config not found at ${GRUB_FILE}. Skipping persistent setup."
        log_warn "Add manually to kernel cmdline: hugepages=${count} hugepagesz=2M"
        return 0
    fi

    log_info "Updating GRUB for persistent hugepages (requires root and grub update)..."

    # Check if already set
    if grep -q "hugepages=${count}" "$GRUB_FILE"; then
        log_info "GRUB already has hugepages=${count}. No change needed."
        return 0
    fi

    # Backup
    cp "$GRUB_FILE" "${GRUB_FILE}.bak.$(date +%Y%m%d)"
    log_info "Backup: ${GRUB_FILE}.bak.$(date +%Y%m%d)"

    # Add/update hugepages in GRUB_CMDLINE_LINUX_DEFAULT
    sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"/GRUB_CMDLINE_LINUX_DEFAULT=\"hugepages=${count} hugepagesz=2M /" \
        "$GRUB_FILE"

    log_success "Updated GRUB_CMDLINE_LINUX_DEFAULT with hugepages=${count}"

    # Detect and run grub update
    if command -v grub2-mkconfig &>/dev/null; then
        log_info "Running grub2-mkconfig..."
        grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null && \
            log_success "GRUB config updated. Hugepages will persist after reboot."
    elif command -v update-grub &>/dev/null; then
        update-grub 2>/dev/null && \
            log_success "GRUB config updated. Hugepages will persist after reboot."
    else
        log_warn "Could not find grub update command. Run manually:"
        log_warn "  grub2-mkconfig -o /boot/grub2/grub.cfg"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    local count="$DEFAULT_COUNT"
    local persistent=false
    local check_only=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --count|-n) count="$2"; shift 2 ;;
            --persistent|-p) persistent=true; shift ;;
            --check|-c) check_only=true; shift ;;
            --help|-h)
                echo "Usage: $0 [--count N] [--persistent] [--check]"
                echo "  --count N       Allocate N × 2MB hugepages (default: ${DEFAULT_COUNT})"
                echo "  --persistent    Also update GRUB for reboot persistence"
                echo "  --check         Only show current status"
                exit 0
                ;;
            *) log_error "Unknown option: $1"; exit 1 ;;
        esac
    done

    if [[ $check_only == true ]]; then
        show_status
        exit 0
    fi

    require_root

    log_header "HugePage Setup (${count} × ${HP_SIZE_MB}MB = $((count * HP_SIZE_MB)) MB)"

    allocate_hugepages "$count"
    mount_hugetlbfs

    if $persistent; then
        make_persistent_grub "$count"
    fi

    show_status
}

main "$@"
