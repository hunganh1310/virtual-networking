#!/usr/bin/env bash
# ============================================================================
# benchmark/run-benchmark.sh — Unified benchmark runner
# ============================================================================
# Runs the full benchmark suite against the currently deployed topology.
# Detects the active engine and collects engine-specific stats alongside
# iperf3 performance data.
#
# Usage:
#   source benchmark/run-benchmark.sh
#   benchmark_run <topology_yaml>
#
# Or via vnctl:
#   sudo ./vnctl bench run ovs
# ============================================================================

set -euo pipefail

# Source libraries
_BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_BENCH_DIR}/../lib/common.sh"
source "${_BENCH_DIR}/../lib/config.sh"
source "${_BENCH_DIR}/../lib/benchmark.sh"

# ---------------------------------------------------------------------------
# Main benchmark runner
# ---------------------------------------------------------------------------

benchmark_run() {
    local topology_file="$1"

    config_load "$topology_file"

    require_commands iperf3 ping

    local engine
    engine=$(config_get_engine)

    # Determine target IP (first VM's IP, stripped of CIDR)
    local server_ip
    server_ip=$(config_get "vms.vm1.ip" "10.0.0.1/24")
    server_ip="${server_ip%%/*}"

    # Read benchmark parameters from defaults
    local tcp_duration udp_bitrate parallel_streams ping_count
    tcp_duration=$(config_get "benchmark.tcp_duration" "30")
    udp_bitrate=$(config_get "benchmark.udp_bitrate" "200M")
    parallel_streams=$(config_get "benchmark.parallel_streams" "4")
    ping_count=$(config_get "benchmark.latency_count" "100")

    # Create output directory
    local output_dir
    output_dir=$(bench_create_output_dir "$engine")

    log_header "Benchmark: ${engine^^}"
    echo ""
    echo "  Engine:   ${engine}"
    echo "  Topology: ${topology_file}"
    echo "  Target:   ${server_ip}"
    echo "  Output:   ${output_dir}"
    echo ""

    # Write metadata
    bench_write_metadata "$output_dir" "$engine" "$topology_file"

    # Pre-benchmark: collect engine stats
    log_info "Collecting pre-benchmark engine stats..."
    _collect_engine_stats "$engine" "${output_dir}/stats-pre.txt"

    # Run the full test suite
    bench_run_suite \
        "$server_ip" \
        "$output_dir" \
        "$tcp_duration" \
        "$udp_bitrate" \
        "$parallel_streams" \
        "$ping_count"

    # Post-benchmark: collect engine stats
    log_info "Collecting post-benchmark engine stats..."
    _collect_engine_stats "$engine" "${output_dir}/stats-post.txt"

    # Print inline results summary table
    bench_summary "$engine" "$output_dir"

    log_success "Benchmark complete. Results: ${output_dir}"
}

# ---------------------------------------------------------------------------
# Engine-specific stats collection
# ---------------------------------------------------------------------------

_collect_engine_stats() {
    local engine="$1"
    local output_file="$2"

    {
        echo "=== Engine Stats (${engine}) — $(date -Iseconds) ==="
        echo ""

        case "$engine" in
            linux-bridge)
                echo "--- Bridge Info ---"
                bridge link show 2>/dev/null || echo "(not available)"
                echo ""
                echo "--- FDB ---"
                bridge fdb show 2>/dev/null | head -30 || echo "(not available)"
                ;;
            ovs)
                echo "--- OVS Show ---"
                ovs-vsctl show 2>/dev/null || echo "(not available)"
                echo ""
                echo "--- Flow Table ---"
                ovs-ofctl dump-flows ovs-br0 2>/dev/null || echo "(not available)"
                echo ""
                echo "--- Datapath Stats ---"
                ovs-dpctl show 2>/dev/null || echo "(not available)"
                echo ""
                echo "--- MAC Table ---"
                ovs-appctl fdb/show ovs-br0 2>/dev/null || echo "(not available)"
                ;;
            vpp)
                echo "--- VPP Interfaces ---"
                vppctl show interface 2>/dev/null || echo "(not available)"
                echo ""
                echo "--- VPP Runtime ---"
                vppctl show runtime 2>/dev/null || echo "(not available)"
                echo ""
                echo "--- VPP Bridge-Domain ---"
                vppctl show bridge-domain 10 detail 2>/dev/null || echo "(not available)"
                echo ""
                echo "--- VPP L2 FIB ---"
                vppctl show l2fib verbose 2>/dev/null || echo "(not available)"
                echo ""
                echo "--- VPP Errors ---"
                vppctl show errors 2>/dev/null || echo "(not available)"
                ;;
        esac
    } > "$output_file"

    log_info "Engine stats saved to ${output_file}"
}
