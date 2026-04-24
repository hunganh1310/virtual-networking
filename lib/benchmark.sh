#!/usr/bin/env bash
# ============================================================================
# lib/benchmark.sh — Benchmark orchestration helpers
# ============================================================================
# Standardized iperf3 and latency tests with consistent output format.
# All results output in JSON + human-readable text with timestamps.
#
# Key design:
#   - Each iperf3 test runs ONCE: JSON saved to file, text teed to terminal
#   - bench_summary parses saved JSON files for a final comparison table
#   - config_get_engine() is a thin wrapper around config_require "engine"
#
# Usage: source lib/benchmark.sh
# ============================================================================

# Guard against double-sourcing
[[ -n "${_BENCHMARK_SH_LOADED:-}" ]] && return 0
readonly _BENCHMARK_SH_LOADED=1

# Source common.sh if not already loaded
if [[ -z "${LIB_DIR:-}" ]]; then
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
fi
source "${LIB_DIR}/config.sh"

# ---------------------------------------------------------------------------
# Output Helpers
# ---------------------------------------------------------------------------

# Create timestamped output directory
# Usage: bench_create_output_dir <engine_name>
# Returns: path to created directory
bench_create_output_dir() {
    local engine="$1"
    local timestamp
    timestamp=$(date '+%Y%m%d-%H%M%S')
    local dir="${RESULTS_DIR}/${engine}/${timestamp}"
    mkdir -p "$dir"
    echo "$dir"
}

# Write test metadata to output directory
bench_write_metadata() {
    local output_dir="$1"
    local engine="$2"
    local topology_file="${3:-}"

    cat > "${output_dir}/metadata.txt" << EOF
=== Benchmark Metadata ===
Timestamp:      $(date -Iseconds)
Engine:         ${engine}
Hostname:       $(hostname)
Kernel:         $(uname -r)
Topology:       ${topology_file:-unknown}
QEMU:           $(qemu-system-x86_64 --version 2>/dev/null | head -1 || echo "N/A")
iperf3:         $(iperf3 --version 2>&1 | head -1 || echo "N/A")
EOF

    case "$engine" in
        ovs)
            echo "OVS Version:    $(ovs-vsctl --version 2>/dev/null | head -1 | awk '{print $NF}' || echo 'N/A')" \
                >> "${output_dir}/metadata.txt"
            ;;
        vpp)
            echo "VPP Version:    $(vppctl show version 2>/dev/null | head -1 || echo 'N/A')" \
                >> "${output_dir}/metadata.txt"
            ;;
    esac

    log_info "Metadata written to ${output_dir}/metadata.txt"
}

# ---------------------------------------------------------------------------
# iperf3 Core Wrapper
# ---------------------------------------------------------------------------
# Runs a single iperf3 invocation: saves JSON to file, tees text to stdout.
# This eliminates the double-run problem (was running twice: once for JSON,
# once for human-readable text with slightly different results each time).
#
# Usage: _iperf3_run <output_base_path> <iperf3_args...>
# Example: _iperf3_run "${dir}/tcp" -c 10.0.0.1 -t 30 -i 5
#
# Produces: <output_base_path>.json and <output_base_path>.txt
_iperf3_run() {
    local output_base="$1"; shift
    local json_file="${output_base}.json"
    local txt_file="${output_base}.txt"

    # Run iperf3 once with JSON output; simultaneously pretty-print via re-parse
    # We use --json and capture to file, then extract human summary afterward
    if iperf3 "$@" --json > "$json_file" 2>&1; then
        # Parse human-readable summary from JSON using awk (works without jq)
        _json_to_text_summary "$json_file" | tee "$txt_file"
    else
        local exit_code=$?
        # iperf3 wrote its error to json_file; show it
        cat "$json_file" | tee "$txt_file" >&2 || true
        log_warn "iperf3 exited with code ${exit_code} (server may not be ready)"
        return 0  # Don't abort the suite; allow other tests to run
    fi
}

# Convert iperf3 JSON output to a human-readable summary
# Uses awk so jq is NOT required for display (jq only needed for compare-report)
_json_to_text_summary() {
    local json_file="$1"
    if command -v jq &>/dev/null && [[ -f "$json_file" ]]; then
        # Rich output with jq
        jq -r '
            if .error then "ERROR: " + .error
            elif .end then
                ("  Sender:   " + ((.end.sum_sent.bits_per_second  / 1e6 * 100 | round / 100 | tostring) + " Mbps")),
                ("  Receiver: " + ((.end.sum_received.bits_per_second / 1e6 * 100 | round / 100 | tostring) + " Mbps")),
                ("  Duration: " + (.end.sum_received.seconds | tostring) + "s"),
                (if .end.sum.lost_percent then
                    "  UDP Loss: " + (.end.sum.lost_percent | tostring) + "%"
                 else "" end)
            else "  (no summary available)"
            end
        ' "$json_file" 2>/dev/null || cat "$json_file"
    elif [[ -f "$json_file" ]]; then
        # Minimal awk fallback: extract key values
        awk '
            /"bits_per_second"/ && /"sum_received"/ { found_rx=1 }
            found_rx && /"bits_per_second"/ {
                gsub(/[^0-9.]/, "", $2)
                printf "  Receiver: %.2f Mbps\n", $2/1e6
                found_rx=0
            }
        ' "$json_file" || cat "$json_file"
    fi
}

# ---------------------------------------------------------------------------
# iperf3 Test Functions
# ---------------------------------------------------------------------------

# Run TCP throughput test (single run — JSON + text)
# Usage: bench_iperf3_tcp <server_ip> <duration> <output_dir>
bench_iperf3_tcp() {
    local server_ip="$1"
    local duration="${2:-30}"
    local output_dir="$3"

    log_step "TCP" "Throughput Test (${duration}s → ${server_ip})"

    _iperf3_run "${output_dir}/tcp" \
        -c "$server_ip" -t "$duration" -i 5

    log_success "TCP results saved to ${output_dir}/tcp.{json,txt}"
}

# Run UDP throughput test (single run — JSON + text)
# Usage: bench_iperf3_udp <server_ip> <bitrate> <duration> <output_dir>
bench_iperf3_udp() {
    local server_ip="$1"
    local bitrate="${2:-200M}"
    local duration="${3:-30}"
    local output_dir="$4"

    log_step "UDP" "Throughput Test (${duration}s, target: ${bitrate})"

    _iperf3_run "${output_dir}/udp" \
        -c "$server_ip" -u -b "$bitrate" -t "$duration" -i 5

    log_success "UDP results saved to ${output_dir}/udp.{json,txt}"
}

# Run parallel streams TCP test (single run — JSON + text)
# Usage: bench_iperf3_parallel <server_ip> <streams> <duration> <output_dir>
bench_iperf3_parallel() {
    local server_ip="$1"
    local streams="${2:-4}"
    local duration="${3:-30}"
    local output_dir="$4"

    log_step "TCP-P" "Parallel Streams Test (${streams}×, ${duration}s)"

    _iperf3_run "${output_dir}/tcp-parallel" \
        -c "$server_ip" -P "$streams" -t "$duration" -i 5

    log_success "Parallel results saved to ${output_dir}/tcp-parallel.{json,txt}"
}

# Run UDP unlimited bandwidth test (single run — JSON + text)
# Usage: bench_iperf3_udp_max <server_ip> <duration> <output_dir>
bench_iperf3_udp_max() {
    local server_ip="$1"
    local duration="${2:-30}"
    local output_dir="$3"

    log_step "UDP-MAX" "Unlimited Bandwidth Test (${duration}s)"

    _iperf3_run "${output_dir}/udp-unlimited" \
        -c "$server_ip" -u -b 0 -t "$duration" -i 5

    log_success "UDP unlimited results saved to ${output_dir}/udp-unlimited.{json,txt}"
}

# Run bidirectional TCP test (client sends AND receives simultaneously)
# Usage: bench_iperf3_reverse <server_ip> <duration> <output_dir>
bench_iperf3_reverse() {
    local server_ip="$1"
    local duration="${2:-30}"
    local output_dir="$3"

    log_step "TCP-BIDIR" "Bidirectional Test (${duration}s)"

    _iperf3_run "${output_dir}/tcp-bidir" \
        -c "$server_ip" --bidir -t "$duration" -i 5

    log_success "Bidirectional results saved to ${output_dir}/tcp-bidir.{json,txt}"
}

# ---------------------------------------------------------------------------
# Latency Test
# ---------------------------------------------------------------------------

# Run ping latency measurement
# Usage: bench_latency <target_ip> <count> <output_dir>
bench_latency() {
    local target_ip="$1"
    local count="${2:-100}"
    local output_dir="$3"

    log_step "LATENCY" "Ping Test (${count} packets → ${target_ip})"

    ping -c "$count" -i 0.1 "$target_ip" \
        2>&1 | tee "${output_dir}/latency.txt"

    # Extract and display RTT summary
    local rtt_line
    rtt_line=$(grep "rtt min/avg/max/mdev" "${output_dir}/latency.txt" 2>/dev/null || \
               grep "round-trip" "${output_dir}/latency.txt" 2>/dev/null || true)
    if [[ -n "$rtt_line" ]]; then
        echo ""
        log_info "RTT Summary: ${rtt_line}"
    fi
    log_success "Latency results saved to ${output_dir}/latency.txt"
}

# ---------------------------------------------------------------------------
# Results Summary Table
# ---------------------------------------------------------------------------

# Extract a value from an iperf3 JSON result file using jq or awk fallback
# Usage: _extract_metric <json_file> <jq_expr> <awk_pattern>
_extract_metric() {
    local json_file="$1"
    local jq_expr="$2"
    local default="${3:-N/A}"

    if [[ ! -f "$json_file" ]]; then
        echo "$default"
        return
    fi

    if command -v jq &>/dev/null; then
        local val
        val=$(jq -r "$jq_expr" "$json_file" 2>/dev/null || echo "$default")
        [[ -z "$val" || "$val" == "null" ]] && echo "$default" || echo "$val"
    else
        echo "$default (install jq for metrics)"
    fi
}

# Print a formatted summary table from results in an output directory
# Usage: bench_summary <engine> <output_dir>
bench_summary() {
    local engine="$1"
    local output_dir="$2"

    echo ""
    echo -e "${_CLR_BOLD}  ┌──────────────────────────────────────────────────────┐${_CLR_RESET}"
    printf  "  │  %-52s│\n" "Benchmark Summary — ${engine^^}"
    echo -e "${_CLR_BOLD}  ├────────────────────────┬─────────────────────────────┤${_CLR_RESET}"
    printf  "  │  %-22s│  %-27s│\n" "Test" "Result"
    echo -e "  ├────────────────────────┼─────────────────────────────┤"

    # TCP throughput
    local tcp_rx
    tcp_rx=$(_extract_metric "${output_dir}/tcp.json" \
        '.end.sum_received.bits_per_second / 1e6 | . * 100 | round / 100 | tostring + " Mbps"')
    printf  "  │  %-22s│  %-27s│\n" "TCP Rx Throughput" "$tcp_rx"

    # UDP packet loss
    local udp_loss
    udp_loss=$(_extract_metric "${output_dir}/udp.json" \
        '.end.sum.lost_percent | tostring + "%"')
    printf  "  │  %-22s│  %-27s│\n" "UDP Loss (${BENCH_UDP_BITRATE:-200M}bps)" "$udp_loss"

    # UDP unlimited throughput
    local udp_max_rx
    udp_max_rx=$(_extract_metric "${output_dir}/udp-unlimited.json" \
        '.end.sum_received.bits_per_second / 1e6 | . * 100 | round / 100 | tostring + " Mbps"')
    printf  "  │  %-22s│  %-27s│\n" "UDP Max Throughput" "$udp_max_rx"

    # Parallel TCP
    local par_rx
    par_rx=$(_extract_metric "${output_dir}/tcp-parallel.json" \
        '.end.sum_received.bits_per_second / 1e6 | . * 100 | round / 100 | tostring + " Mbps"')
    printf  "  │  %-22s│  %-27s│\n" "TCP Parallel Rx" "$par_rx"

    # Latency
    local avg_lat="N/A"
    if [[ -f "${output_dir}/latency.txt" ]]; then
        avg_lat=$(grep -oP 'avg/max/mdev = \K[0-9.]+/\K[0-9.]+' \
            "${output_dir}/latency.txt" 2>/dev/null | head -1 || \
            awk -F'/' '/rtt min/ { print $5 " ms" }' \
            "${output_dir}/latency.txt" 2>/dev/null || echo "N/A")
        [[ -n "$avg_lat" ]] && avg_lat="${avg_lat} ms"
    fi
    printf  "  │  %-22s│  %-27s│\n" "Avg Latency" "$avg_lat"

    echo -e "  └────────────────────────┴─────────────────────────────┘"
    echo ""
    log_info "Full results in: ${output_dir}"
}

# ---------------------------------------------------------------------------
# Full Test Suite
# ---------------------------------------------------------------------------

# Run a complete benchmark suite
# Usage: bench_run_suite <server_ip> <output_dir> [tcp_duration] [udp_bitrate] [streams] [ping_count]
bench_run_suite() {
    local server_ip="$1"
    local output_dir="$2"
    local tcp_duration="${3:-30}"
    local udp_bitrate="${4:-200M}"
    local parallel_streams="${5:-4}"
    local ping_count="${6:-100}"

    # Export for bench_summary to access udp_bitrate label
    export BENCH_UDP_BITRATE="$udp_bitrate"

    log_header "Benchmark Suite"
    echo "  Server:   ${server_ip}"
    echo "  Output:   ${output_dir}"
    echo "  Duration: ${tcp_duration}s per test"
    echo ""

    # 1. Latency (fast, run first to confirm connectivity)
    bench_latency "$server_ip" "$ping_count" "$output_dir"
    echo ""

    # 2. TCP throughput (single stream)
    bench_iperf3_tcp "$server_ip" "$tcp_duration" "$output_dir"
    echo ""

    # 3. UDP controlled bitrate
    bench_iperf3_udp "$server_ip" "$udp_bitrate" "$tcp_duration" "$output_dir"
    echo ""

    # 4. UDP unlimited
    bench_iperf3_udp_max "$server_ip" "$tcp_duration" "$output_dir"
    echo ""

    # 5. Parallel TCP
    bench_iperf3_parallel "$server_ip" "$parallel_streams" "$tcp_duration" "$output_dir"
    echo ""

    log_header "Benchmark Complete"
    echo "  All results saved to: ${output_dir}"
    echo ""
    ls -la "$output_dir" | sed 's/^/  /'
    echo ""
}
