#!/bin/bash
# ===========================================================
# Lab 2 - Task 1: Setup Linux Bridge + TAP interfaces
# ===========================================================
# Tạo virtual network infrastructure cho 2 VMs
# 
# Kiến trúc:
#   VM1 (tap0) <---> br-test <---> (tap1) VM2
#
# Chạy với sudo: sudo bash setup-network.sh
# ===========================================================

set -euo pipefail

BRIDGE="br-test"
TAP0="tap0"
TAP1="tap1"
BRIDGE_IP="10.0.0.254/24"
USER=$(logname 2>/dev/null || echo "${SUDO_USER:-$(whoami)}")

echo "=== [1/6] Kiểm tra tools ==="
for cmd in ip brctl; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: '$cmd' not found. Install: sudo zypper install iproute2 bridge-utils"
        exit 1
    fi
done
echo "OK: Tất cả tools có sẵn"

echo ""
echo "=== [2/6] Tạo Linux Bridge: $BRIDGE ==="
if ip link show "$BRIDGE" &>/dev/null; then
    echo "Bridge $BRIDGE đã tồn tại, skip"
else
    ip link add name "$BRIDGE" type bridge
    echo "Đã tạo bridge $BRIDGE"
fi

echo ""
echo "=== [3/6] Tạo TAP interface: $TAP0 (cho VM1) ==="
if ip link show "$TAP0" &>/dev/null; then
    echo "TAP $TAP0 đã tồn tại, skip"
else
    ip tuntap add dev "$TAP0" mode tap user "$USER"
    echo "Đã tạo $TAP0 (owner: $USER)"
fi

echo ""
echo "=== [4/6] Tạo TAP interface: $TAP1 (cho VM2) ==="
if ip link show "$TAP1" &>/dev/null; then
    echo "TAP $TAP1 đã tồn tại, skip"
else
    ip tuntap add dev "$TAP1" mode tap user "$USER"
    echo "Đã tạo $TAP1 (owner: $USER)"
fi

echo ""
echo "=== [5/6] Gắn TAP vào Bridge ==="
ip link set "$TAP0" master "$BRIDGE" 2>/dev/null && echo "$TAP0 -> $BRIDGE" || echo "$TAP0 đã gắn rồi"
ip link set "$TAP1" master "$BRIDGE" 2>/dev/null && echo "$TAP1 -> $BRIDGE" || echo "$TAP1 đã gắn rồi"

echo ""
echo "=== [6/6] Bật tất cả interfaces ==="
ip link set "$BRIDGE" up
ip link set "$TAP0" up
ip link set "$TAP1" up

# Gán IP cho bridge (để host có thể ping/SSH vào VMs)
ip addr flush dev "$BRIDGE" 2>/dev/null
ip addr add "$BRIDGE_IP" dev "$BRIDGE"

echo ""
echo "========================================="
echo "  NETWORK SETUP HOÀN THÀNH!"
echo "========================================="
echo "  Bridge : $BRIDGE ($BRIDGE_IP)"
echo "  TAP VM1: $TAP0"
echo "  TAP VM2: $TAP1"
echo ""
echo "  Kiểm tra: ip addr show $BRIDGE"
echo "            brctl show $BRIDGE"
echo "========================================="
