#!/usr/bin/env bash
# ============================================================================
# lib/common.sh — Shared utility functions for Virtual Networking project
# ============================================================================
# Provides: logging, privilege checks, prerequisite validation, idempotency
# guards, and path resolution. Source this file from all project scripts.
#
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# ============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Path Resolution
# ---------------------------------------------------------------------------
# Auto-detect project root from this file's location (lib/ is one level deep)
readonly LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "${LIB_DIR}/.." && pwd)"

# Standard project paths
readonly CONFIG_DIR="${PROJECT_ROOT}/config"
readonly TOPOLOGY_DIR="${CONFIG_DIR}/topology"
readonly ENGINE_DIR="${PROJECT_ROOT}/engine"
readonly IMAGES_DIR="${PROJECT_ROOT}/images"
readonly BOOT_DIR="${PROJECT_ROOT}/boot"
readonly RESULTS_DIR="${PROJECT_ROOT}/results"
readonly PID_DIR="/tmp/vnctl"

# Ensure PID directory exists
mkdir -p "${PID_DIR}"

# ---------------------------------------------------------------------------
# ANSI Color Codes
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    readonly _CLR_RESET='\033[0m'
    readonly _CLR_RED='\033[0;31m'
    readonly _CLR_GREEN='\033[0;32m'
    readonly _CLR_YELLOW='\033[0;33m'
    readonly _CLR_BLUE='\033[0;34m'
    readonly _CLR_CYAN='\033[0;36m'
    readonly _CLR_BOLD='\033[1m'
    readonly _CLR_DIM='\033[2m'
else
    readonly _CLR_RESET=''
    readonly _CLR_RED=''
    readonly _CLR_GREEN=''
    readonly _CLR_YELLOW=''
    readonly _CLR_BLUE=''
    readonly _CLR_CYAN=''
    readonly _CLR_BOLD=''
    readonly _CLR_DIM=''
fi

# ---------------------------------------------------------------------------
# Logging Functions
# ---------------------------------------------------------------------------
_timestamp() {
    date '+%H:%M:%S'
}

log_info() {
    echo -e "${_CLR_DIM}$(_timestamp)${_CLR_RESET} ${_CLR_BLUE}[INFO]${_CLR_RESET}  $*" >&2
}

log_warn() {
    echo -e "${_CLR_DIM}$(_timestamp)${_CLR_RESET} ${_CLR_YELLOW}[WARN]${_CLR_RESET}  $*" >&2
}

log_error() {
    echo -e "${_CLR_DIM}$(_timestamp)${_CLR_RESET} ${_CLR_RED}[ERROR]${_CLR_RESET} $*" >&2
}

log_success() {
    echo -e "${_CLR_DIM}$(_timestamp)${_CLR_RESET} ${_CLR_GREEN}[ OK ]${_CLR_RESET}  $*" >&2
}

log_step() {
    local step="$1"; shift
    echo -e "\n${_CLR_BOLD}${_CLR_CYAN}=== [${step}] $* ===${_CLR_RESET}" >&2
}

log_header() {
    echo -e "\n${_CLR_BOLD}============================================${_CLR_RESET}" >&2
    echo -e "${_CLR_BOLD}  $*${_CLR_RESET}" >&2
    echo -e "${_CLR_BOLD}============================================${_CLR_RESET}" >&2
}

# ---------------------------------------------------------------------------
# Privilege & Prerequisite Checks
# ---------------------------------------------------------------------------

# Ensure script is running as root (or via sudo)
require_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This operation requires root privileges."
        log_error "Run with: sudo $0 $*"
        exit 1
    fi
}

# Verify that required commands are available on the system
# Usage: require_commands ip ovs-vsctl qemu-system-x86_64
require_commands() {
    local missing=()
    for cmd in "$@"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required commands: ${missing[*]}"
        log_error "Install them before proceeding."
        return 1
    fi
    return 0
}

# Verify that a systemd service is active
# Usage: require_service openvswitch
require_service() {
    local service="$1"
    if ! systemctl is-active --quiet "${service}" 2>/dev/null; then
        log_error "Service '${service}' is not running."
        log_error "Start it with: sudo systemctl enable --now ${service}"
        return 1
    fi
    log_info "Service '${service}' is active."
    return 0
}

# ---------------------------------------------------------------------------
# Idempotent Interface Helpers
# ---------------------------------------------------------------------------

# Check if a network interface exists
# Usage: if link_exists tap0; then ...
link_exists() {
    ip link show "$1" &>/dev/null
}

# Ensure a network interface exists; return 0 if already present, 1 if created
# This is a check-only function; creation logic belongs in network.sh
ensure_link_exists() {
    local name="$1"
    if link_exists "$name"; then
        log_info "Interface '${name}' already exists, skipping creation."
        return 0
    fi
    return 1
}

# Safely delete a network interface if it exists
ensure_link_absent() {
    local name="$1"
    if link_exists "$name"; then
        ip link set "$name" down 2>/dev/null || true
        ip link delete "$name" 2>/dev/null || true
        log_info "Removed interface '${name}'."
    else
        log_info "Interface '${name}' does not exist, nothing to remove."
    fi
}

# ---------------------------------------------------------------------------
# File & Process Helpers
# ---------------------------------------------------------------------------

# Check if a file exists and is readable
require_file() {
    local filepath="$1"
    local description="${2:-file}"
    if [[ ! -f "$filepath" ]]; then
        log_error "${description} not found: ${filepath}"
        return 1
    fi
    if [[ ! -r "$filepath" ]]; then
        log_error "${description} not readable: ${filepath}"
        return 1
    fi
    return 0
}

# Read PID from a file, verify it's running
# Returns: 0 if process is alive, 1 otherwise
pid_is_running() {
    local pid_file="$1"
    if [[ ! -f "$pid_file" ]]; then
        return 1
    fi
    local pid
    pid=$(cat "$pid_file")
    if kill -0 "$pid" 2>/dev/null; then
        return 0
    fi
    # Stale PID file — clean it up
    rm -f "$pid_file"
    return 1
}

# Get PID from file (or empty string)
get_pid() {
    local pid_file="$1"
    if [[ -f "$pid_file" ]]; then
        cat "$pid_file"
    fi
}

# Graceful process termination: SIGTERM → wait → SIGKILL
stop_process() {
    local pid_file="$1"
    local name="${2:-process}"
    local timeout="${3:-5}"

    if ! pid_is_running "$pid_file"; then
        log_info "${name} is not running."
        return 0
    fi

    local pid
    pid=$(cat "$pid_file")
    log_info "Stopping ${name} (PID: ${pid})..."

    kill "$pid" 2>/dev/null || true

    # Wait for graceful shutdown
    local i=0
    while kill -0 "$pid" 2>/dev/null && [[ $i -lt $timeout ]]; do
        sleep 1
        i=$((i + 1))
    done

    # Force kill if still running
    if kill -0 "$pid" 2>/dev/null; then
        log_warn "${name} did not stop gracefully, sending SIGKILL..."
        kill -9 "$pid" 2>/dev/null || true
        sleep 1
    fi

    rm -f "$pid_file"
    log_success "${name} stopped."
}

# ---------------------------------------------------------------------------
# Validation Helpers
# ---------------------------------------------------------------------------

# Validate an IP address (basic IPv4 check)
is_valid_ipv4() {
    local ip="$1"
    local IFS='.'
    # shellcheck disable=SC2206
    local octets=($ip)
    [[ ${#octets[@]} -eq 4 ]] || return 1
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]+$ ]] || return 1
        (( octet >= 0 && octet <= 255 )) || return 1
    done
    return 0
}

# Validate a MAC address
is_valid_mac() {
    [[ "$1" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]]
}
