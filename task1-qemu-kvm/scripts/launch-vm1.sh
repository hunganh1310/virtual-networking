#!/bin/bash
# ===========================================================
# Lab 2 - Task 1: Launch VM1 (UPF) — FOREGROUND
# ===========================================================
# VM1 acts as "UPF" (User Plane Function)
# - IP: 10.0.0.1/24
# - TAP: tap0 → br-test
# - Console: direct serial (foreground)
#
# Usage:       ./launch-vm1.sh
# Exit VM:     Ctrl+A, X
# ===========================================================
# NOTE: Boot directly with -kernel/-initrd (bypass GRUB)
# because nested KVM (WSL2) does not support intel_iommu=on in GRUB config.
# ===========================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PREFLIGHT_SCRIPT="$(cd "$SCRIPT_DIR/../.." && pwd)/scripts/preflight.sh"

if [[ ! -f "$PREFLIGHT_SCRIPT" ]]; then
    echo "ERROR: Preflight script not found: $PREFLIGHT_SCRIPT"
    exit 1
fi

source "$PREFLIGHT_SCRIPT"

IMAGE="$WORK_DIR/images/vm1.qcow2"
BOOT_DIR="$WORK_DIR/boot"
KERNEL="$BOOT_DIR/vmlinuz"
INITRD="$BOOT_DIR/initrd"

# Check files and required interface
check_files_exist "$IMAGE" "$KERNEL" "$INITRD" || exit 1
check_interfaces_exist tap0 || {
    echo "ERROR: tap0 not found. Run setup-network.sh first!"
    exit 1
}

check_commands qemu-system-x86_64 || exit 1

echo "============================================"
echo "  Launching VM1 (UPF) — FOREGROUND"
echo "  Image  : $IMAGE"
echo "  Kernel : $KERNEL"
echo "  RAM    : 1024 MB"
echo "  vCPUs  : 2"
echo "  NIC    : virtio → tap0 → br-test"
echo "============================================"
echo ""
echo "  Console: serial (Ctrl+A, X to exit)"
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
