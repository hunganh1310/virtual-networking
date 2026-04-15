#!/bin/bash
# ===========================================================
# Lab 2 - Task 1: Launch VM2 (gNodeB) — BACKGROUND
# ===========================================================
# VM2 đóng vai trò "gNodeB" (5G Base Station)
# - IP: 10.0.0.2/24
# - TAP: tap1 → br-test
# - Console: telnet (background)
#
# Cách dùng:    ./launch-vm2.sh
# Truy cập VM2: telnet 127.0.0.1 5556
# Thoát telnet: Ctrl+], rồi gõ quit
# QEMU Monitor: telnet 127.0.0.1 55501
# Tắt VM2:     kill $(cat /tmp/vm2.pid)
# ===========================================================
# NOTE: Boot trực tiếp bằng -kernel/-initrd (bypass GRUB)
# vì nested KVM (WSL2) không hỗ trợ intel_iommu=on trong GRUB config.
# Dùng -display none thay -nographic (tránh xung đột với -daemonize).
# ===========================================================

set -euo pipefail

WORK_DIR=~/telco-lab/virtual-networking/task1-qemu-kvm
IMAGE="$WORK_DIR/images/vm2.qcow2"
BOOT_DIR="$WORK_DIR/boot"
KERNEL="$BOOT_DIR/vmlinuz"
INITRD="$BOOT_DIR/initrd"

# Kiểm tra files
for f in "$IMAGE" "$KERNEL" "$INITRD"; do
    if [[ ! -f "$f" ]]; then
        echo "ERROR: File not found: $f"
        exit 1
    fi
done

# Kiểm tra TAP interface
if ! ip link show tap1 &>/dev/null; then
    echo "ERROR: tap1 not found. Run setup-network.sh first!"
    exit 1
fi

# Kiểm tra VM2 đã chạy chưa
if [[ -f /tmp/vm2.pid ]] && kill -0 "$(cat /tmp/vm2.pid)" 2>/dev/null; then
    echo "WARNING: VM2 đang chạy (PID: $(cat /tmp/vm2.pid))"
    echo "Dùng 'kill $(cat /tmp/vm2.pid)' để tắt trước."
    exit 1
fi

echo "============================================"
echo "  Launching VM2 (gNodeB) — BACKGROUND"
echo "  Image  : $IMAGE"
echo "  Kernel : $KERNEL"
echo "  RAM    : 1024 MB"
echo "  vCPUs  : 2"
echo "  NIC    : virtio → tap1 → br-test"
echo "============================================"
echo ""
echo "  Truy cập VM2 console:"
echo "    telnet 127.0.0.1 5556"
echo ""
echo "  QEMU monitor:"
echo "    telnet 127.0.0.1 55501"
echo ""
echo "  Tắt VM2:"
echo "    kill \$(cat /tmp/vm2.pid)"
echo "============================================"

qemu-system-x86_64 \
    -name vm2 \
    -machine q35,accel=kvm \
    -cpu host \
    -m 1024 \
    -smp 2 \
    -drive file="$IMAGE",format=qcow2,if=virtio \
    -netdev tap,id=net0,ifname=tap1,script=no,downscript=no,vhost=on \
    -device virtio-net-pci,netdev=net0,mac=52:54:00:00:00:02 \
    -kernel "$KERNEL" \
    -initrd "$INITRD" \
    -append "root=/dev/vda1 console=ttyS0,115200 net.ifnames=0 biosdevname=0 rw" \
    -display none \
    -serial telnet:127.0.0.1:5556,server,nowait \
    -monitor telnet:127.0.0.1:55501,server,nowait \
    -pidfile /tmp/vm2.pid \
    -daemonize

echo ""
echo "✅ VM2 đã khởi chạy nền (PID: $(cat /tmp/vm2.pid))"
echo "→ Truy cập: telnet 127.0.0.1 5556"
echo "→ Login: root / linux"
