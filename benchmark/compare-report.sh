#!/usr/bin/env bash
# ============================================================================
# benchmark/compare-report.sh — Multi-engine performance comparison report
# ============================================================================
# Reads the most recent benchmark results for each engine and generates:
#   1. A color-coded comparison table in the terminal (winner in green)
#   2. A Markdown report file saved to results/comparison/
#
# Requires: jq (for JSON metric extraction from iperf3 output)
#
# Usage:
#   source benchmark/compare-report.sh
#   generate_comparison_report [--all | linux-bridge ovs vpp]
#
# Or via vnctl:
#   ./vnctl bench compare
# ============================================================================

set -euo pipefail

_BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_BENCH_DIR}/../lib/common.sh"
source "${_BENCH_DIR}/../lib/config.sh"

# All supported engines (in display order)
readonly _ALL_ENGINES=("linux-bridge" "ovs" "vpp")

# ---------------------------------------------------------------------------
# Metric Extraction Helpers
# ---------------------------------------------------------------------------

# Extract a numeric metric from an iperf3 JSON file
# Usage: _extract_json_num <file> <jq_expr> [default]
_extract_json_num() {
    local file="$1" jq_expr="$2" default="${3:-}"
    if [[ ! -f "$file" ]]; then
        echo "$default"
        return
    fi
    if command -v jq &>/dev/null; then
        jq -r "$jq_expr" "$file" 2>/dev/null || echo "$default"
    else
        echo "$default"
    fi
}

# Extract a metric and format it with a unit
# Usage: _metric <file> <jq_expr> <scale> <unit> [decimals]
_metric() {
    local file="$1" jq_expr="$2" scale="${3:-1}" unit="${4:-}" dp="${5:-2}"
    local raw
    raw=$(_extract_json_num "$file" "$jq_expr" "")
    if [[ -z "$raw" || "$raw" == "null" ]]; then
        echo "N/A"
    else
        # Use awk for floating point formatting without bc dependency
        awk -v v="$raw" -v s="$scale" -v u="$unit" -v dp="$dp" \
            'BEGIN { printf "%.*f %s\n", dp, v/s, u }'
    fi
}

# Get the most recent result directory for an engine
_latest_dir() {
    local engine="$1"
    find "${RESULTS_DIR}/${engine}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
        | sort -r | head -1
}

# Read latency avg from ping output
_latency_avg() {
    local latency_file="$1"
    if [[ ! -f "$latency_file" ]]; then
        echo "N/A"
        return
    fi
    # Linux: "rtt min/avg/max/mdev = 0.123/0.456/0.789/0.100 ms"
    local avg
    avg=$(awk -F'/' '/rtt min/ { print $5 }' "$latency_file" 2>/dev/null | head -1)
    if [[ -n "$avg" ]]; then
        printf "%.2f ms" "$avg"
    else
        echo "N/A"
    fi
}

# ---------------------------------------------------------------------------
# Terminal Table Renderer
# ---------------------------------------------------------------------------

_col_width=16  # width per engine column

# Print the comparison table to the terminal with ANSI colors
_print_terminal_table() {
    local -n _engines_ref=$1    # nameref to engines array
    local -n _dirs_ref=$2       # nameref to dirs array

    # Gather all metrics up front
    declare -A tcp_mbps udp_loss udp_max_mbps par_mbps latency_ms

    for i in "${!_engines_ref[@]}"; do
        local eng="${_engines_ref[$i]}"
        local dir="${_dirs_ref[$i]}"

        tcp_mbps[$eng]=$(_metric "${dir}/tcp.json" \
            '.end.sum_received.bits_per_second' 1000000 "Mbps" 1)
        udp_loss[$eng]=$(_extract_json_num "${dir}/udp.json" \
            '.end.sum.lost_percent | . * 100 | round / 100 | tostring + "%"' "N/A")
        udp_max_mbps[$eng]=$(_metric "${dir}/udp-unlimited.json" \
            '.end.sum_received.bits_per_second' 1000000 "Mbps" 1)
        par_mbps[$eng]=$(_metric "${dir}/tcp-parallel.json" \
            '.end.sum_received.bits_per_second' 1000000 "Mbps" 1)
        latency_ms[$eng]=$(_latency_avg "${dir}/latency.txt")
    done

    # Header
    echo ""
    echo -e "${_CLR_BOLD}  Performance Comparison — OVS vs VPP vs Linux Bridge${_CLR_RESET}"
    echo ""

    # Build header row
    local header="  ┌─────────────────────────┬"
    local divider="  ├─────────────────────────┼"
    local hdr_row="  │  Metric                 │"
    local footer="  └─────────────────────────┴"

    for eng in "${_engines_ref[@]}"; do
        header+="──────────────────┬"
        divider+="──────────────────┼"
        hdr_row+="  $(printf '%-16s' "${eng^^}")│"
        footer+="──────────────────┴"
    done
    # Trim trailing ┬/┼/┴ and add corner
    header="${header%┬}┐"
    divider="${divider%┼}┤"
    hdr_row="${hdr_row%│}│"
    footer="${footer%┴}┘"

    echo -e "${_CLR_BOLD}${header}${_CLR_RESET}"
    printf "%s\n" "$hdr_row"
    echo -e "${_CLR_BOLD}${divider}${_CLR_RESET}"

    # Metric rows — highlight winner
    _print_metric_row "TCP Rx (Mbps)"    tcp_mbps   "${_engines_ref[@]}" "high"
    _print_metric_row "UDP Loss"          udp_loss   "${_engines_ref[@]}" "low_pct"
    _print_metric_row "UDP Max (Mbps)"    udp_max_mbps "${_engines_ref[@]}" "high"
    _print_metric_row "TCP Parallel"     par_mbps   "${_engines_ref[@]}" "high"
    _print_metric_row "Avg Latency"      latency_ms "${_engines_ref[@]}" "low_ms"

    echo "$footer"
    echo ""
}

# Print a single metric row with winner highlighted
# Usage: _print_metric_row <label> <assoc_array_name> <engine1> ... <engineN> <mode>
_print_metric_row() {
    local label="$1"
    local arr_name="$2"
    shift 2
    local engines=("$@")
    local mode="${engines[-1]}"
    unset 'engines[-1]'

    local -n arr_ref=$arr_name

    # Collect numeric values for winner detection
    declare -A vals
    for eng in "${engines[@]}"; do
        local raw="${arr_ref[$eng]:-N/A}"
        # Extract numeric portion
        local num
        num=$(echo "$raw" | grep -oP '[0-9]+\.?[0-9]*' | head -1 || true)
        vals[$eng]="${num:-}"
    done

    # Find winner (best numeric value)
    local best_eng=""
    local best_val=""
    for eng in "${engines[@]}"; do
        local v="${vals[$eng]:-}"
        [[ -z "$v" ]] && continue
        if [[ -z "$best_val" ]]; then
            best_val="$v"
            best_eng="$eng"
        else
            case "$mode" in
                high)
                    awk -v a="$v" -v b="$best_val" 'BEGIN { exit !(a > b) }' && \
                        best_val="$v" && best_eng="$eng" || true
                    ;;
                low_pct|low_ms)
                    awk -v a="$v" -v b="$best_val" 'BEGIN { exit !(a < b) }' && \
                        best_val="$v" && best_eng="$eng" || true
                    ;;
            esac
        fi
    done

    # Build row with color for winner
    local row
    row="  │  $(printf '%-23s' "$label")│"
    for eng in "${engines[@]}"; do
        local val="${arr_ref[$eng]:-N/A}"
        if [[ "$eng" == "$best_eng" && "$val" != "N/A" ]]; then
            row+="  ${_CLR_GREEN}$(printf '%-16s' "$val")${_CLR_RESET}│"
        else
            row+="  $(printf '%-16s' "$val")│"
        fi
    done
    printf "%b\n" "$row"
}

# ---------------------------------------------------------------------------
# Markdown Report Generator
# ---------------------------------------------------------------------------

_write_markdown_report() {
    local report_file="$1"
    shift
    local -n _eng_ref=$1; shift
    local -n _dir_ref=$1

    {
        echo "# NFV Engine Performance Comparison"
        echo ""
        echo "**Generated:** $(date -Iseconds)  "
        echo "**Host:** $(hostname) | **Kernel:** $(uname -r)"
        echo ""
        echo "## Summary"
        echo ""
        echo "| Metric | $(IFS='|'; echo "${_eng_ref[*]}") |"
        echo "|--------|$(printf '%s|' "${_eng_ref[@]//*/--------}")"

        # TCP
        local vals=()
        for i in "${!_eng_ref[@]}"; do
            vals+=("$(_metric "${_dir_ref[$i]}/tcp.json" \
                '.end.sum_received.bits_per_second' 1000000 "Mbps" 1)")
        done
        echo "| TCP Rx Throughput | $(IFS='|'; echo "${vals[*]}") |"

        # UDP Loss
        vals=()
        for i in "${!_eng_ref[@]}"; do
            vals+=("$(_extract_json_num "${_dir_ref[$i]}/udp.json" \
                '.end.sum.lost_percent | tostring + "%"' "N/A")")
        done
        echo "| UDP Packet Loss | $(IFS='|'; echo "${vals[*]}") |"

        # UDP Max
        vals=()
        for i in "${!_eng_ref[@]}"; do
            vals+=("$(_metric "${_dir_ref[$i]}/udp-unlimited.json" \
                '.end.sum_received.bits_per_second' 1000000 "Mbps" 1)")
        done
        echo "| UDP Max Throughput | $(IFS='|'; echo "${vals[*]}") |"

        # Parallel TCP
        vals=()
        for i in "${!_eng_ref[@]}"; do
            vals+=("$(_metric "${_dir_ref[$i]}/tcp-parallel.json" \
                '.end.sum_received.bits_per_second' 1000000 "Mbps" 1)")
        done
        echo "| TCP Parallel | $(IFS='|'; echo "${vals[*]}") |"

        # Latency
        vals=()
        for i in "${!_eng_ref[@]}"; do
            vals+=("$(_latency_avg "${_dir_ref[$i]}/latency.txt")")
        done
        echo "| Avg Latency | $(IFS='|'; echo "${vals[*]}") |"

        echo ""
        echo "## Data Sources"
        echo ""
        for i in "${!_eng_ref[@]}"; do
            local eng="${_eng_ref[$i]}"
            local dir="${_dir_ref[$i]}"
            if [[ -n "$dir" ]]; then
                echo "- **${eng}**: \`${dir}\`"
                if [[ -f "${dir}/metadata.txt" ]]; then
                    echo '  ```'
                    sed 's/^/  /' "${dir}/metadata.txt"
                    echo '  ```'
                fi
            else
                echo "- **${eng}**: *no results found*"
            fi
        done

        echo ""
        echo "## Notes"
        echo ""
        echo "- All tests run via \`iperf3\` between two QEMU/KVM VMs connected through the engine"
        echo "- Results reflect virtual networking performance (not hardware line-rate)"
        echo "- VPP TAP mode does not use DPDK; expect higher throughput with DPDK userspace datapath"
        echo "- UDP loss at low bitrates is expected; test at \`0\` bitrate to find saturation point"

    } > "$report_file"
}

# ---------------------------------------------------------------------------
# Main Entry Point
# ---------------------------------------------------------------------------

generate_comparison_report() {
    # Determine which engines to compare (default: all with available results)
    local engines_to_compare=()
    local dirs_to_use=()

    for eng in "${_ALL_ENGINES[@]}"; do
        local dir
        dir=$(_latest_dir "$eng")
        if [[ -n "$dir" ]]; then
            engines_to_compare+=("$eng")
            dirs_to_use+=("$dir")
        else
            log_warn "No results found for engine '${eng}' — skipping."
        fi
    done

    if [[ ${#engines_to_compare[@]} -eq 0 ]]; then
        log_error "No benchmark results found for any engine."
        log_error "Run benchmarks first:"
        log_error "  sudo ./vnctl bench run ovs"
        log_error "  sudo ./vnctl bench run vpp"
        log_error "  sudo ./vnctl bench run linux-bridge"
        return 1
    fi

    if [[ ${#engines_to_compare[@]} -eq 1 ]]; then
        log_warn "Only one engine has results (${engines_to_compare[0]}). Run more engines for a meaningful comparison."
    fi

    log_header "Engine Comparison Report (${#engines_to_compare[@]} engines)"

    # Print terminal table
    _print_terminal_table engines_to_compare dirs_to_use

    # Write Markdown report
    local report_dir="${RESULTS_DIR}/comparison"
    mkdir -p "$report_dir"
    local ts; ts=$(date '+%Y%m%d-%H%M%S')
    local report_file="${report_dir}/${ts}-comparison.md"

    _write_markdown_report "$report_file" engines_to_compare dirs_to_use

    echo ""
    log_success "Markdown report saved to ${report_file}"
    echo "  → Open with: cat ${report_file}"
    echo ""
}
