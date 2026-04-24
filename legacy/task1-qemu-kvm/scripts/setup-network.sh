#!/bin/bash
# ===========================================================
# Lab 2 - Task 1: Setup Linux Bridge + TAP interfaces
# ===========================================================
# Create virtual network infrastructure for 2 VMs
# 
# Architecture:
#   VM1 (tap0) <---> br-test <---> (tap1) VM2
#
# Run with sudo: sudo bash setup-network.sh
# ===========================================================

set -euo pipefail

BRIDGE="br-test"
TAP0="tap0"
TAP1="tap1"
BRIDGE_IP="10.0.0.254/24"
USER=$(logname 2>/dev/null || echo "${SUDO_USER:-$(whoami)}")

echo "=== [1/6] Checking tools ==="
for cmd in ip brctl; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: '$cmd' not found. Install: sudo zypper install iproute2 bridge-utils"
        exit 1
    fi
done
echo "OK: All tools are available"

echo ""
echo "=== [2/6] Creating Linux Bridge: $BRIDGE ==="
if ip link show "$BRIDGE" &>/dev/null; then
    echo "Bridge $BRIDGE already exists, skipping"
else
    ip link add name "$BRIDGE" type bridge
    echo "Created bridge $BRIDGE"
fi

echo ""
echo "=== [3/6] Creating TAP interface: $TAP0 (for VM1) ==="
if ip link show "$TAP0" &>/dev/null; then
    echo "TAP $TAP0 already exists, skipping"
else
    ip tuntap add dev "$TAP0" mode tap user "$USER"
    echo "Created $TAP0 (owner: $USER)"
fi

echo ""
echo "=== [4/6] Creating TAP interface: $TAP1 (for VM2) ==="
if ip link show "$TAP1" &>/dev/null; then
    echo "TAP $TAP1 already exists, skipping"
else
    ip tuntap add dev "$TAP1" mode tap user "$USER"
    echo "Created $TAP1 (owner: $USER)"
fi

echo ""
echo "=== [5/6] Attaching TAP to Bridge ==="
ip link set "$TAP0" master "$BRIDGE" 2>/dev/null && echo "$TAP0 -> $BRIDGE" || echo "$TAP0 is already attached"
ip link set "$TAP1" master "$BRIDGE" 2>/dev/null && echo "$TAP1 -> $BRIDGE" || echo "$TAP1 is already attached"

echo ""
echo "=== [6/6] Bringing up all interfaces ==="
ip link set "$BRIDGE" up
ip link set "$TAP0" up
ip link set "$TAP1" up

# Assign IP to bridge (so host can ping/SSH into VMs)
ip addr flush dev "$BRIDGE" 2>/dev/null
ip addr add "$BRIDGE_IP" dev "$BRIDGE"

echo ""
echo "========================================="
echo "  NETWORK SETUP COMPLETED!"
echo "========================================="
echo "  Bridge : $BRIDGE ($BRIDGE_IP)"
echo "  TAP VM1: $TAP0"
echo "  TAP VM2: $TAP1"
echo ""
echo "  Check: ip addr show $BRIDGE"
echo "            brctl show $BRIDGE"
echo "========================================="
