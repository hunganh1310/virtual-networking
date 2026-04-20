#!/bin/bash
# ===========================================================
# Lab 2 - Task 1: Launch VM2 (gNodeB) — BACKGROUND
# ===========================================================
# VM2 acts as "gNodeB" (5G Base Station)
# - IP: 10.0.0.2/24
# - TAP: tap1 → br-test
# - Console: telnet (background)
#
# Usage:         ./launch-vm2.sh
# Access VM2:    telnet 127.0.0.1 5556
# Exit telnet:   Ctrl+], then type quit
# QEMU Monitor: telnet 127.0.0.1 55501
# Stop VM2:     kill $(cat /tmp/vm2.pid)
# ===========================================================
# NOTE: Boot directly with -kernel/-initrd (bypass GRUB)
# because nested KVM (WSL2) does not support intel_iommu=on in GRUB config.
# Use -display none instead of -nographic (avoid conflict with -daemonize).
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

IMAGE="$WORK_DIR/images/vm2.qcow2"
BOOT_DIR="$WORK_DIR/boot"
KERNEL="$BOOT_DIR/vmlinuz"
INITRD="$BOOT_DIR/initrd"

# Check files and required interface
check_files_exist "$IMAGE" "$KERNEL" "$INITRD" || exit 1
check_interfaces_exist tap1 || {
    echo "ERROR: tap1 not found. Run setup-network.sh first!"
    exit 1
}

check_commands qemu-system-x86_64 || exit 1

# Check whether VM2 is already running
if [[ -f /tmp/vm2.pid ]] && kill -0 "$(cat /tmp/vm2.pid)" 2>/dev/null; then
    echo "WARNING: VM2 is already running (PID: $(cat /tmp/vm2.pid))"
    echo "Use 'kill $(cat /tmp/vm2.pid)' to stop it first."
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
echo "  Access VM2 console:"
echo "    telnet 127.0.0.1 5556"
echo ""
echo "  QEMU monitor:"
echo "    telnet 127.0.0.1 55501"
echo ""
echo "  Stop VM2:"
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
echo "VM2 started in background (PID: $(cat /tmp/vm2.pid))"
echo "Access: telnet 127.0.0.1 5556"
echo "Login: root / linux"
