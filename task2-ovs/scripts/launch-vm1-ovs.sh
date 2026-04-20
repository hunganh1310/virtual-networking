#!/bin/bash
# ===========================================================
# Lab 2 - Task 2: Launch VM1 (UPF) via OVS — FOREGROUND
# ===========================================================
# Boot: direct kernel (bypass GRUB, no iommu)
# HugePages: disabled (hugepages=0) to prevent OOM
# Console: serial (Ctrl+A, X to exit)
# Login: root / linux
# ===========================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORK_DIR="$REPO_ROOT/task1-qemu-kvm"
PREFLIGHT_SCRIPT="$REPO_ROOT/scripts/preflight.sh"

if [[ ! -f "$PREFLIGHT_SCRIPT" ]]; then
    echo "ERROR: Preflight script not found: $PREFLIGHT_SCRIPT"
    exit 1
fi

source "$PREFLIGHT_SCRIPT"

IMAGE="$WORK_DIR/images/vm1.qcow2"
BOOT_DIR="$WORK_DIR/boot"
KERNEL="$BOOT_DIR/vmlinuz"
INITRD="$BOOT_DIR/initrd"

check_files_exist "$IMAGE" "$KERNEL" "$INITRD" || exit 1
check_interfaces_exist tap0 || { echo "ERROR: tap0 not found. Run setup-ovs-network.sh first!"; exit 1; }
check_commands qemu-system-x86_64 || exit 1

echo "============================================"
echo "  VM1 (UPF) — OVS Bridge — FOREGROUND"
echo "  Login: root / linux"
echo "  Exit:  Ctrl+A, X"
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
    -append "root=/dev/vda1 console=ttyS0,115200 net.ifnames=0 biosdevname=0 hugepages=0 rw" \
    -nographic \
    -serial mon:stdio
