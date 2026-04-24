#!/usr/bin/env bash
# ============================================================================
# scripts/install-vpp.sh — FD.io VPP Installation for openSUSE
# ============================================================================
# Installs FD.io VPP from the official packagecloud.io repository.
# Supports openSUSE Tumbleweed and Leap 15.x.
#
# USAGE:
#   sudo ./scripts/install-vpp.sh           # Install latest stable VPP
#   sudo ./scripts/install-vpp.sh --check   # Check if VPP is installed
#   sudo ./scripts/install-vpp.sh --remove  # Remove VPP
#
# INSTALLED PACKAGES:
#   vpp              — VPP runtime and data plane
#   vpp-plugins      — Core plugins (L2, L3, TAP, etc.)
#   vpp-api-python   — Python API bindings (for automation)
#   vpp-devel        — Development headers (optional)
#
# POST-INSTALL:
#   sudo systemctl enable --now vpp   # Start as system service
#   OR
#   sudo ./vnctl deploy vpp           # Start managed by vnctl
#
# ALTERNATIVE — Build from source:
#   git clone https://gerrit.fd.io/r/vpp
#   cd vpp && make install-dep && make build
#
# Reference: https://fd.io/docs/vpp/latest/gettingstarted/installing/
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${PROJECT_ROOT}/lib/common.sh"

# VPP repository details
readonly VPP_REPO_URL="https://packagecloud.io/fdio/release/opensuse"
readonly VPP_REPO_FILE="/etc/zypp/repos.d/fdio-vpp.repo"

# ---------------------------------------------------------------------------
# Detection
# ---------------------------------------------------------------------------

_opensuse_version() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        echo "${VERSION_ID:-tumbleweed}"
    else
        echo "unknown"
    fi
}

_is_tumbleweed() {
    [[ -f /etc/os-release ]] && grep -qi "tumbleweed" /etc/os-release
}

_vpp_installed() {
    command -v vpp &>/dev/null && command -v vppctl &>/dev/null
}

show_check() {
    log_header "VPP Installation Check"
    echo ""

    if _vpp_installed; then
        local ver
        ver=$(vpp --version 2>/dev/null | head -1 || echo "version unknown")
        log_success "VPP is installed: ${ver}"

        echo "  Binaries:"
        for bin in vpp vppctl vpp-api-test; do
            if command -v "$bin" &>/dev/null; then
                printf "    %-20s %s\n" "${bin}" "$(which "${bin}")"
            fi
        done

        echo ""
        echo "  Plugins:"
        find /usr/lib/vpp_plugins/ -name "*.so" 2>/dev/null | \
            xargs -I{} basename {} | sort | sed 's/^/    /' || echo "    (none found)"

        echo ""
        echo "  Service status:"
        systemctl status vpp 2>/dev/null | head -5 | sed 's/^/    /' || \
            echo "    (vpp service not registered)"
    else
        log_warn "VPP is NOT installed."
        echo "  Run: sudo ./scripts/install-vpp.sh"
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# Repository Setup
# ---------------------------------------------------------------------------

_add_repo_opensuse() {
    local os_ver
    os_ver=$(_opensuse_version)

    log_info "Detecting openSUSE version: ${os_ver}"

    if _is_tumbleweed; then
        # Tumbleweed: use the latest stable repo
        local repo_url="https://packagecloud.io/fdio/release/opensuse/15.4"
        log_info "Using openSUSE Leap 15.4 repo (compatible with Tumbleweed)"
    else
        local repo_url="${VPP_REPO_URL}/${os_ver}"
    fi

    log_info "Adding FD.io VPP repository..."

    # Download and import GPG key
    log_info "Importing packagecloud GPG key..."
    rpm --import "https://packagecloud.io/fdio/release/gpgkey" 2>/dev/null || {
        log_warn "Could not import GPG key automatically."
        log_warn "Add manually: rpm --import https://packagecloud.io/fdio/release/gpgkey"
    }

    # Add zypper repository
    cat > "${VPP_REPO_FILE}" << EOF
[fdio-vpp]
name=FD.io VPP Release
baseurl=${repo_url}/
enabled=1
autorefresh=1
gpgcheck=0
type=rpm-md
EOF

    log_success "Repository added: ${VPP_REPO_FILE}"
    log_info "Refreshing package metadata..."
    zypper --non-interactive --gpg-auto-import-keys refresh fdio-vpp 2>/dev/null || {
        log_warn "Could not refresh repo. Will try with --no-gpg-checks."
        zypper --non-interactive --no-gpg-checks refresh fdio-vpp || true
    }
}

# ---------------------------------------------------------------------------
# Installation
# ---------------------------------------------------------------------------

install_vpp() {
    require_root
    require_commands zypper rpm

    if _vpp_installed; then
        log_info "VPP is already installed."
        show_check
        return 0
    fi

    log_header "Installing FD.io VPP"

    # Add repository
    if [[ ! -f "$VPP_REPO_FILE" ]]; then
        _add_repo_opensuse
    else
        log_info "VPP repository already configured."
    fi

    # Install packages
    log_step "1/3" "Installing VPP packages"
    local packages=(vpp vpp-plugins)

    # Try with vpp-api-python too (may not be available on all repos)
    if zypper --non-interactive search vpp-api-python &>/dev/null; then
        packages+=(vpp-api-python)
    fi

    zypper --non-interactive --no-gpg-checks install "${packages[@]}" || {
        log_error "zypper install failed."
        log_error ""
        log_error "Alternative installation methods:"
        log_error "  1. Build from source:"
        log_error "       git clone https://gerrit.fd.io/r/vpp && cd vpp"
        log_error "       make install-dep && make build && make install"
        log_error ""
        log_error "  2. Download pre-built binary:"
        log_error "       https://packagecloud.io/fdio/release"
        return 1
    }

    log_step "2/3" "Verifying installation"
    if _vpp_installed; then
        log_success "VPP installed successfully."
    else
        log_error "Installation completed but 'vpp' binary not found in PATH."
        return 1
    fi

    # Create vpp group (needed for CLI socket permissions)
    log_step "3/3" "Post-install configuration"
    if ! getent group vpp &>/dev/null; then
        groupadd vpp
        log_info "Created 'vpp' group."
    fi

    # Create CLI socket directory
    mkdir -p /run/vpp
    chown root:vpp /run/vpp 2>/dev/null || true

    show_check

    log_header "VPP Installation Complete"
    echo ""
    echo "  Test:     sudo vpp -c ${PROJECT_ROOT}/config/vpp/startup.conf"
    echo "  Deploy:   sudo ./vnctl deploy vpp"
    echo "  Doctor:   ./vnctl doctor"
    echo ""
}

remove_vpp() {
    require_root
    log_header "Removing VPP"
    zypper --non-interactive remove vpp vpp-plugins vpp-api-python vpp-devel 2>/dev/null || true
    rm -f "$VPP_REPO_FILE"
    log_success "VPP removed."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    case "${1:-install}" in
        --check|-c)    show_check ;;
        --remove|-r)   remove_vpp ;;
        install|--install|-i) install_vpp ;;
        --help|-h)
            echo "Usage: $0 [--check | --remove | install]"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            echo "Usage: $0 [--check | --remove | install]"
            exit 1
            ;;
    esac
}

main "$@"
