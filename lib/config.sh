#!/usr/bin/env bash
# ============================================================================
# lib/config.sh — YAML configuration parser & topology loader
# ============================================================================
# Lightweight YAML parser for Bash. Uses `yq` if available, falls back to
# an awk/sed-based parser for portability. Supports nested keys via dot
# notation: config_get "vm.vm1.ram"
#
# Usage:
#   source lib/config.sh
#   config_load config/topology/ovs-bridge.yaml
#   engine=$(config_get "engine")
#   bridge_name=$(config_get "bridge.name")
# ============================================================================

# Guard against double-sourcing
[[ -n "${_CONFIG_SH_LOADED:-}" ]] && return 0
readonly _CONFIG_SH_LOADED=1

# Source common.sh if not already loaded
if [[ -z "${LIB_DIR:-}" ]]; then
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
fi

# ---------------------------------------------------------------------------
# Internal state
# ---------------------------------------------------------------------------
declare -g _CONFIG_FILE=""
declare -gA _CONFIG_CACHE=()
declare -gA _DEFAULTS_CACHE=()
declare -g _DEFAULTS_LOADED=0

# ---------------------------------------------------------------------------
# YAML Parsing Backend
# ---------------------------------------------------------------------------

# Detect best available YAML parser
_yaml_backend() {
    if command -v yq &>/dev/null; then
        echo "yq"
    else
        echo "awk"
    fi
}

# Parse YAML value using yq
_yq_get() {
    local file="$1" key="$2"
    yq -r ".${key} // empty" "$file" 2>/dev/null
}

# Parse YAML value using awk (simplified — handles flat and one-level nesting)
# Supports: key: value, parent:\n  child: value
_awk_get() {
    local file="$1" key="$2"
    local IFS='.'
    # shellcheck disable=SC2206
    local parts=($key)

    if [[ ${#parts[@]} -eq 1 ]]; then
        # Top-level key
        awk -v k="${parts[0]}" '
            /^[^ #]/ && $1 == k":" { gsub(/^[^:]+:[[:space:]]*/, ""); gsub(/[[:space:]]*#.*$/, ""); gsub(/^["'\'']|["'\'']$/, ""); print; exit }
        ' "$file"
    elif [[ ${#parts[@]} -eq 2 ]]; then
        # One level nested: parent.child
        awk -v parent="${parts[0]}" -v child="${parts[1]}" '
            BEGIN { in_section=0 }
            /^[^ #]/ {
                if ($1 == parent":") { in_section=1; next }
                else { in_section=0 }
            }
            in_section && /^[[:space:]]/ {
                gsub(/^[[:space:]]+/, "")
                if ($1 == child":") {
                    gsub(/^[^:]+:[[:space:]]*/, "")
                    gsub(/[[:space:]]*#.*$/, "")
                    gsub(/^["'\'']|["'\'']$/, "")
                    print
                    exit
                }
            }
        ' "$file"
    elif [[ ${#parts[@]} -eq 3 ]]; then
        # Two levels nested: grandparent.parent.child
        awk -v gp="${parts[0]}" -v p="${parts[1]}" -v c="${parts[2]}" '
            BEGIN { in_gp=0; in_p=0; gp_indent=-1; p_indent=-1 }
            {
                # Calculate indentation
                match($0, /^[[:space:]]*/);
                indent = RLENGTH;
                line = $0;
                gsub(/^[[:space:]]+/, "", line);

                # Skip empty lines and comments
                if (line == "" || line ~ /^#/) next;

                # Check if we left the grandparent section
                if (in_gp && indent <= gp_indent && indent > 0) { in_gp=0; in_p=0; }
                if (indent == 0 && gp_indent >= 0 && line !~ "^"gp":") { in_gp=0; in_p=0; }

                # Top level: find grandparent
                if (indent == 0 && line ~ "^"gp":") {
                    in_gp=1; gp_indent=indent; in_p=0; next;
                }

                # In grandparent: find parent
                if (in_gp && !in_p && line ~ "^"p":") {
                    in_p=1; p_indent=indent; next;
                }

                # In parent: check if we left
                if (in_p && indent <= p_indent) { in_p=0; }

                # In parent: find child
                if (in_p && line ~ "^"c":") {
                    val = line;
                    gsub(/^[^:]+:[[:space:]]*/, "", val);
                    gsub(/[[:space:]]*#.*$/, "", val);
                    gsub(/^["'"'"']|["'"'"']$/, "", val);
                    print val;
                    exit;
                }
            }
        ' "$file"
    else
        log_warn "config_get: key depth > 3 not supported by awk backend — install 'yq' for full YAML support."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

# Load defaults from config/defaults.yaml
config_load_defaults() {
    local defaults_file="${CONFIG_DIR}/defaults.yaml"
    if [[ ! -f "$defaults_file" ]]; then
        log_warn "No defaults.yaml found at ${defaults_file}, skipping."
        return 0
    fi
    _DEFAULTS_LOADED=1
    return 0
}

# Load a topology YAML file
config_load() {
    local file="$1"

    # Resolve relative paths against project root
    if [[ "$file" != /* ]]; then
        file="${PROJECT_ROOT}/${file}"
    fi

    if ! require_file "$file" "Configuration file"; then
        return 1
    fi

    _CONFIG_FILE="$file"
    _CONFIG_CACHE=()

    # Load defaults if not yet loaded
    if [[ $_DEFAULTS_LOADED -eq 0 ]]; then
        config_load_defaults
    fi

    log_info "Loaded configuration: ${file}"
    return 0
}

# Get a configuration value by dot-notation key
# Falls back to defaults.yaml if not found in topology file
config_get() {
    local key="$1"
    local default="${2:-}"

    # Check cache first
    if [[ -n "${_CONFIG_CACHE[$key]+x}" ]]; then
        echo "${_CONFIG_CACHE[$key]}"
        return 0
    fi

    if [[ -z "$_CONFIG_FILE" ]]; then
        log_error "config_get: No configuration loaded. Call config_load first."
        return 1
    fi

    local backend value
    backend=$(_yaml_backend)

    # Try topology file first
    if [[ "$backend" == "yq" ]]; then
        value=$(_yq_get "$_CONFIG_FILE" "$key")
    else
        value=$(_awk_get "$_CONFIG_FILE" "$key")
    fi

    # Fallback to defaults if empty
    if [[ -z "$value" ]] && [[ -f "${CONFIG_DIR}/defaults.yaml" ]]; then
        if [[ "$backend" == "yq" ]]; then
            value=$(_yq_get "${CONFIG_DIR}/defaults.yaml" "$key")
        else
            value=$(_awk_get "${CONFIG_DIR}/defaults.yaml" "$key")
        fi
    fi

    # Fallback to provided default
    if [[ -z "$value" ]]; then
        value="$default"
    fi

    # Cache the result
    _CONFIG_CACHE[$key]="$value"
    echo "$value"
}

# Get a value or fail if missing (required field)
config_require() {
    local key="$1"
    local value
    value=$(config_get "$key")

    if [[ -z "$value" ]]; then
        log_error "Required configuration key '${key}' is missing."
        log_error "Check your topology file: ${_CONFIG_FILE}"
        return 1
    fi

    echo "$value"
}

# List all VM names defined in the topology
config_list_vms() {
    if [[ -z "$_CONFIG_FILE" ]]; then
        log_error "config_list_vms: No configuration loaded."
        return 1
    fi

    local backend
    backend=$(_yaml_backend)

    if [[ "$backend" == "yq" ]]; then
        yq -r '.vms | keys | .[]' "$_CONFIG_FILE" 2>/dev/null
    else
        # awk fallback: find keys directly under the "vms:" section.
        # Supports both 2-space and 4-space YAML indentation.
        # A VM key is any line with 1+ leading spaces that is at the FIRST
        # indent level below "vms:" (i.e., not further indented).
        awk '
            BEGIN { in_vms=0; vms_indent=-1 }
            /^vms:/ { in_vms=1; vms_indent=-1; next }
            in_vms && /^[^ #\t]/ { exit }                # Back to top-level: done
            in_vms && /^[ \t]*$/ { next }                # Skip blank lines
            in_vms && /^[ \t]*#/ { next }                # Skip comments
            in_vms {
                match($0, /^[ \t]+/);
                cur_indent = RLENGTH;
                # Capture the first indent level we see under vms:
                if (vms_indent == -1) { vms_indent = cur_indent }
                # Only emit keys at exactly the VM indent level (not sub-keys)
                if (cur_indent == vms_indent) {
                    key = $1;
                    gsub(/:$/, "", key);
                    print key
                }
            }
        ' "$_CONFIG_FILE"
    fi
}

# Get the active engine type from loaded config
config_get_engine() {
    config_require "engine"
}

# Resolve a path relative to project root
config_resolve_path() {
    local path="$1"
    if [[ "$path" == /* ]]; then
        echo "$path"
    else
        echo "${PROJECT_ROOT}/${path}"
    fi
}

# Print all loaded configuration (debug)
config_dump() {
    if [[ -z "$_CONFIG_FILE" ]]; then
        log_error "No configuration loaded."
        return 1
    fi

    log_header "Configuration: ${_CONFIG_FILE}"

    local backend
    backend=$(_yaml_backend)

    if [[ "$backend" == "yq" ]]; then
        yq '.' "$_CONFIG_FILE"
    else
        cat "$_CONFIG_FILE"
    fi
}

# Validate that a topology file has all required fields
config_validate() {
    local file="${1:-$_CONFIG_FILE}"
    local errors=0

    if [[ -z "$file" ]]; then
        log_error "config_validate: No file specified."
        return 1
    fi

    # Temporarily load the file for validation
    local saved_file="$_CONFIG_FILE"
    config_load "$file" || return 1

    # Required fields
    local engine
    engine=$(config_get "engine")
    if [[ -z "$engine" ]]; then
        log_error "Missing required field: engine"
        errors=$((errors + 1))
    fi

    # Check VM definitions exist
    local vms
    vms=$(config_list_vms)
    if [[ -z "$vms" ]]; then
        log_error "No VMs defined in topology."
        errors=$((errors + 1))
    fi

    # Validate each VM has required fields
    while IFS= read -r vm_name; do
        for field in mac tap image; do
            local val
            val=$(config_get "vms.${vm_name}.${field}")
            if [[ -z "$val" ]]; then
                log_error "VM '${vm_name}' missing required field: ${field}"
                errors=$((errors + 1))
            fi
        done
    done <<< "$vms"

    # Restore previous config
    _CONFIG_FILE="$saved_file"

    if [[ $errors -gt 0 ]]; then
        log_error "Validation failed with ${errors} error(s)."
        return 1
    fi

    log_success "Configuration validated successfully."
    return 0
}
