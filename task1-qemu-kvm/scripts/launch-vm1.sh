#!/bin/bash
# ===========================================================
# Lab 2 - Task 1: Launch VM1 (UPF) — FOREGROUND
# ===========================================================
# VM1 đóng vai trò "UPF" (User Plane Function)
# - IP: 10.0.0.1/24
# - TAP: tap0 → br-test
# - Console: serial trực tiếp (foreground)
#
# Cách dùng:   ./launch-vm1.sh
# Thoát VM:    Ctrl+A, X
# ===========================================================
# NOTE: Boot trực tiếp bằng -kernel/-initrd (bypass GRUB)
# vì nested KVM (WSL2) không hỗ trợ intel_iommu=on trong GRUB config.
# ===========================================================

set -euo pipefail

WORK_DIR=~/telco-lab/virtual-networking/task1-qemu-kvm
IMAGE="$WORK_DIR/images/vm1.qcow2"
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
if ! ip link show tap0 &>/dev/null; then
    echo "ERROR: tap0 not found. Run setup-network.sh first!"
    exit 1
fi

echo "============================================"
echo "  Launching VM1 (UPF) — FOREGROUND"
echo "  Image  : $IMAGE"
echo "  Kernel : $KERNEL"
echo "  RAM    : 1024 MB"
echo "  vCPUs  : 2"
echo "  NIC    : virtio → tap0 → br-test"
echo "============================================"
echo ""
echo "  Console: serial (Ctrl+A, X để thoát)"
echo "  Login  : root / linux"
echo "============================================"

qemu-system-x86_64 \
    -name vm1 \
    -machine q35,accel=kvm \
    -cpu host \
    -m 1024 \
    -smp 2 \
    -drive file="$IMAGE",format=qcow2,if=virtio \
    -netdev tap,id=net0,ifname=tap0,script=no,downscript=no,vhost=on \
    -device virtio-net-pci,netdev=net0,mac=52:54:00:00:00:01 \
    -kernel "$KERNEL" \
    -initrd "$INITRD" \
    -append "root=/dev/vda1 console=ttyS0,115200 net.ifnames=0 biosdevname=0 rw" \
    -nographic \
    -serial mon:stdio
