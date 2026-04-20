#!/bin/bash
# Shared preflight helpers for lab scripts.

set -u

check_commands() {
    local cmd
    local failed=0

    for cmd in "$@"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "ERROR: Required command not found: $cmd"
            failed=1
        fi
    done

    return "$failed"
}

check_files_exist() {
    local file
    local failed=0

    for file in "$@"; do
        if [[ ! -f "$file" ]]; then
            echo "ERROR: File not found: $file"
            failed=1
        fi
    done

    return "$failed"
}

check_interfaces_exist() {
    local iface
    local failed=0

    for iface in "$@"; do
        if ! ip link show "$iface" >/dev/null 2>&1; then
            echo "ERROR: Interface not found: $iface"
            failed=1
        fi
    done

    return "$failed"
}
