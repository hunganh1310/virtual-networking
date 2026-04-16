#!/bin/bash
# ===========================================================
# Lab 2 - Task 2: Setup OVS Bridge + TAP interfaces
# ===========================================================
# Tạo OVS bridge (ovs-br0) thay thế Linux Bridge từ Task 1
# Kết nối 2 VMs qua TAP interfaces
#
# Yêu cầu: openvswitch đã cài và đang chạy
# ===========================================================

set -euo pipefail

BRIDGE="ovs-br0"
BRIDGE_IP="10.0.0.254/24"

echo "============================================"
echo "  Task 2: Setup OVS Network"
echo "============================================"

# Kiểm tra OVS service
if ! systemctl is-active --quiet openvswitch; then
    echo "ERROR: openvswitch service not running!"
    echo "Run: sudo systemctl enable --now openvswitch"
    exit 1
fi

# Xóa bridge cũ nếu tồn tại
ovs-vsctl --if-exists del-br "$BRIDGE"

# Xóa TAP cũ
ip link delete tap0 2>/dev/null || true
ip link delete tap1 2>/dev/null || true

# Tạo OVS bridge
ovs-vsctl add-br "$BRIDGE"

# Tạo TAP interfaces
ip tuntap add dev tap0 mode tap
ip tuntap add dev tap1 mode tap

# Gắn TAP vào OVS bridge
ovs-vsctl add-port "$BRIDGE" tap0
ovs-vsctl add-port "$BRIDGE" tap1

# Bật interfaces
ip link set "$BRIDGE" up
ip link set tap0 up
ip link set tap1 up

# Gán IP cho bridge (host connectivity)
ip addr add "$BRIDGE_IP" dev "$BRIDGE"

echo ""
echo "=== OVS Bridge ==="
ovs-vsctl show

echo ""
echo "=== Ports ==="
ovs-vsctl list-ports "$BRIDGE"

echo ""
echo "=== IP ==="
ip addr show "$BRIDGE" | grep inet

echo ""
echo "✅ OVS network setup complete!"
echo ""
echo "Next steps:"
echo "  1. Launch VM1: ./launch-vm1-ovs.sh"
echo "  2. Launch VM2: ./launch-vm2-ovs.sh"
echo "  3. In VM1: ip addr add 10.0.0.1/24 dev eth0 && ip link set eth0 up"
echo "  4. In VM2: ip addr add 10.0.0.2/24 dev eth0 && ip link set eth0 up"
