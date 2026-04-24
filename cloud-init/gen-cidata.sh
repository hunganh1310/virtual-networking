#!/usr/bin/env bash
# ============================================================================
# cloud-init/gen-cidata.sh — Generate cloud-init seed ISO from topology YAML
# ============================================================================
# Creates a cloud-init "seed" ISO (NoCloud datasource) for a specific VM.
# The ISO is attached to QEMU as a second drive and provides:
#   - user-data: network config, packages, iperf3 auto-start
#   - meta-data: hostname, instance ID
#
# USAGE:
#   ./cloud-init/gen-cidata.sh <topology> <vm_name>
#
# EXAMPLES:
#   ./cloud-init/gen-cidata.sh ovs vm1        # Generate for VM1 in OVS topo
#   ./cloud-init/gen-cidata.sh vpp vm2        # Generate for VM2 in VPP topo
#   ./cloud-init/gen-cidata.sh ovs all        # Generate for all VMs in topology
#
# OUTPUT:
#   cloud-init/<vm_name>-seed.iso             # Attach as QEMU drive
#
# REQUIREMENTS:
#   - genisoimage or mkisofs (cloud-image-utils)
#   - yq (for YAML parsing — falls back to grep/awk)
#   - VM image must have cloud-init installed
#
# ATTACHING TO QEMU:
#   qemu-system-x86_64 ... \
#     -drive file=cloud-init/vm1-seed.iso,format=raw,if=virtio,readonly=on
#
# Reference: https://cloudinit.readthedocs.io/en/latest/reference/datasources/nocloud.html
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${PROJECT_ROOT}/lib/common.sh"
source "${PROJECT_ROOT}/lib/config.sh"

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
_check_deps() {
    local missing=()
    for cmd in genisoimage mkisofs; do
        command -v "$cmd" &>/dev/null && return 0
    done
    log_error "Neither 'genisoimage' nor 'mkisofs' found."
    log_error "Install: zypper install genisoimage  OR  apt install cloud-image-utils"
    exit 1
}

_iso_tool() {
    if command -v genisoimage &>/dev/null; then echo "genisoimage"
    else echo "mkisofs"; fi
}

# ---------------------------------------------------------------------------
# ISO Generation
# ---------------------------------------------------------------------------

# Generate cloud-init seed ISO for a single VM
# Usage: _gen_seed_iso <vm_name> <vm_ip> <gateway_ip> <hostname> <output_iso>
_gen_seed_iso() {
    local vm_name="$1"
    local vm_ip="$2"
    local gateway_ip="$3"
    local vm_hostname="${4:-${vm_name}-nfv}"
    local output_iso="$5"

    local tmpdir
    tmpdir=$(mktemp -d)
    trap "rm -rf ${tmpdir}" EXIT

    log_info "Generating cloud-init data for ${vm_name} (IP: ${vm_ip}, GW: ${gateway_ip})"

    # --- user-data ---
    local base_yaml="${SCRIPT_DIR}/vm-base.yaml"
    if [[ ! -f "$base_yaml" ]]; then
        log_error "Base user-data template not found: ${base_yaml}"
        return 1
    fi

    # Substitute IP placeholders from vm-base.yaml
    sed \
        -e "s|__VM_IP__|${vm_ip%/*}|g" \
        -e "s|__GATEWAY_IP__|${gateway_ip}|g" \
        -e "s|hostname: vm-nfv|hostname: ${vm_hostname}|g" \
        "$base_yaml" > "${tmpdir}/user-data"

    # --- meta-data ---
    cat > "${tmpdir}/meta-data" << EOF
instance-id: ${vm_name}-$(date +%s)
local-hostname: ${vm_hostname}
EOF

    # --- network-config (v2 format) ---
    cat > "${tmpdir}/network-config" << EOF
version: 2
ethernets:
  eth0:
    dhcp4: false
    addresses:
      - ${vm_ip%/*}/24
    gateway4: ${gateway_ip}
    nameservers:
      addresses: [8.8.8.8, 1.1.1.1]
EOF

    # Build the ISO using genisoimage / mkisofs
    local iso_tool; iso_tool=$(_iso_tool)
    "$iso_tool" \
        -output "$output_iso" \
        -volid cidata \
        -joliet -rock \
        -quiet \
        "${tmpdir}/user-data" \
        "${tmpdir}/meta-data" \
        "${tmpdir}/network-config" 2>/dev/null

    log_success "Seed ISO: ${output_iso}"
    echo "  Attach: -drive file=${output_iso},format=raw,if=virtio,readonly=on"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    local topology_name="${1:-}"
    local vm_target="${2:-all}"

    if [[ -z "$topology_name" ]]; then
        cat << 'USAGE'
Usage: ./cloud-init/gen-cidata.sh <topology> [vm_name|all]

Examples:
  ./cloud-init/gen-cidata.sh ovs vm1
  ./cloud-init/gen-cidata.sh ovs all
  ./cloud-init/gen-cidata.sh vpp vm2
USAGE
        exit 1
    fi

    _check_deps

    # Resolve and load topology
    local topo_file
    case "$topology_name" in
        linux-bridge|lb|bridge) topo_file="${PROJECT_ROOT}/config/topology/linux-bridge.yaml" ;;
        ovs|openvswitch)        topo_file="${PROJECT_ROOT}/config/topology/ovs-bridge.yaml" ;;
        vpp)                    topo_file="${PROJECT_ROOT}/config/topology/vpp-bridge.yaml" ;;
        *.yaml|*.yml)           topo_file="${PROJECT_ROOT}/${topology_name}" ;;
        *)
            log_error "Unknown topology: ${topology_name}"
            exit 1
            ;;
    esac

    require_file "$topo_file" "Topology file"
    config_load "$topo_file"

    # Gateway IP (bridge IP without CIDR suffix)
    local gateway_cidr gateway_ip
    gateway_cidr=$(config_get "bridge.ip" "10.0.0.254/24")
    gateway_ip="${gateway_cidr%%/*}"

    # Determine which VMs to process
    local vms_list
    vms_list=$(config_list_vms)

    local generated=0
    while IFS= read -r vm_name; do
        [[ -z "$vm_name" ]] && continue
        [[ "$vm_target" != "all" && "$vm_name" != "$vm_target" ]] && continue

        local vm_ip
        vm_ip=$(config_get "vms.${vm_name}.ip" "")
        if [[ -z "$vm_ip" ]]; then
            log_warn "VM '${vm_name}' has no IP defined in topology — skipping."
            continue
        fi

        local output_iso="${SCRIPT_DIR}/${vm_name}-seed.iso"
        _gen_seed_iso \
            "$vm_name" \
            "$vm_ip" \
            "$gateway_ip" \
            "${vm_name}-nfv" \
            "$output_iso"

        generated=$((generated + 1))
    done <<< "$vms_list"

    if [[ $generated -eq 0 ]]; then
        if [[ "$vm_target" != "all" ]]; then
            log_error "VM '${vm_target}' not found in topology '${topology_name}'."
        else
            log_error "No VMs found in topology '${topology_name}'."
        fi
        exit 1
    fi

    echo ""
    log_header "Cloud-init ISOs Generated (${generated} VM(s))"
    echo ""
    ls -lh "${SCRIPT_DIR}"/*.iso 2>/dev/null | sed 's/^/  /'
    echo ""
    echo "  Next: attach seed ISOs to VM launch (edit topology or use --cloud-init flag)"
    echo "  Or:   sudo ./vnctl vm start ${vm_target} --topology ${topology_name}"
}

main "$@"
