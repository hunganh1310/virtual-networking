#!/usr/bin/env bash
# ============================================================================
# benchmark/collect-stats.sh — Runtime stats collector
# ============================================================================
set -euo pipefail

_BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_BENCH_DIR}/../lib/common.sh"
source "${_BENCH_DIR}/../lib/config.sh"

_detect_active_engine() {
    if pgrep -x vpp &>/dev/null; then echo "vpp"
    elif ovs-vsctl show &>/dev/null 2>&1 && [[ -n "$(ovs-vsctl list-br 2>/dev/null)" ]]; then echo "ovs"
    elif bridge link show 2>/dev/null | grep -q "master"; then echo "linux-bridge"
    else echo ""; fi
}

stats_collect() {
    local topology_file="$1"
    config_load "$topology_file"
    local engine; engine=$(config_get_engine)
    _collect_stats_for_engine "$engine"
}

stats_collect_auto() {
    local engine; engine=$(_detect_active_engine)
    if [[ -z "$engine" ]]; then
        log_error "No active networking engine detected."
        return 1
    fi
    log_info "Detected engine: ${engine}"
    _collect_stats_for_engine "$engine"
}

_collect_stats_for_engine() {
    local engine="$1"
    local ts; ts=$(date '+%Y%m%d-%H%M%S')
    local output_dir="${RESULTS_DIR}/${engine}"
    local output_file="${output_dir}/stats-${ts}.txt"
    mkdir -p "$output_dir"

    log_header "Runtime Stats — ${engine^^}"
    {
        echo "=== Runtime Stats: ${engine} ==="
        echo "Timestamp: $(date -Iseconds)"
        echo ""
        case "$engine" in
            linux-bridge)
                echo "=== BRIDGE LINKS ==="; bridge link show 2>/dev/null
                echo ""; echo "=== FDB TABLE ==="; bridge fdb show 2>/dev/null
                ;;
            ovs)
                echo "=== OVS SHOW ==="; ovs-vsctl show 2>/dev/null
                echo ""; echo "=== FLOW TABLE ==="
                for br in $(ovs-vsctl list-br 2>/dev/null); do
                    ovs-ofctl dump-flows "$br" 2>/dev/null; echo ""
                done
                echo "=== DATAPATH ==="; ovs-dpctl show 2>/dev/null
                echo ""; echo "=== MAC TABLE ==="
                for br in $(ovs-vsctl list-br 2>/dev/null); do
                    ovs-appctl fdb/show "$br" 2>/dev/null; echo ""
                done
                ;;
            vpp)
                echo "=== VPP VERSION ==="; vppctl show version 2>/dev/null
                echo ""; echo "=== INTERFACES ==="; vppctl show interface 2>/dev/null
                echo ""; echo "=== RUNTIME ==="; vppctl show runtime 2>/dev/null
                echo ""; echo "=== BRIDGE-DOMAIN ==="; vppctl show bridge-domain 10 detail 2>/dev/null
                echo ""; echo "=== L2 FIB ==="; vppctl show l2fib verbose 2>/dev/null
                echo ""; echo "=== ERRORS ==="; vppctl show errors 2>/dev/null
                ;;
        esac
    } | tee "$output_file"
    echo ""
    log_success "Stats saved to ${output_file}"
}
