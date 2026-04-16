#!/bin/bash
# ===========================================================
# Lab 2 - Task 2: Launch VM2 (gNodeB) via OVS — BACKGROUND
# ===========================================================
# Access:  telnet 127.0.0.1 5556
# Monitor: telnet 127.0.0.1 55501
# Kill:    kill $(cat /tmp/vm2.pid)
# Login:   root / linux
# ===========================================================

set -euo pipefail

WORK_DIR=~/telco-lab/virtual-networking/task1-qemu-kvm
IMAGE="$WORK_DIR/images/vm2.qcow2"
BOOT_DIR="$WORK_DIR/boot"
KERNEL="$BOOT_DIR/vmlinuz"
INITRD="$BOOT_DIR/initrd"

for f in "$IMAGE" "$KERNEL" "$INITRD"; do
    [[ -f "$f" ]] || { echo "ERROR: $f not found"; exit 1; }
done

ip link show tap1 &>/dev/null || { echo "ERROR: tap1 not found. Run setup-ovs-network.sh first!"; exit 1; }

if [[ -f /tmp/vm2.pid ]] && kill -0 "$(cat /tmp/vm2.pid)" 2>/dev/null; then
    echo "WARNING: VM2 đang chạy (PID: $(cat /tmp/vm2.pid))"
    echo "Dùng 'kill \$(cat /tmp/vm2.pid)' để tắt trước."
    exit 1
fi

echo "============================================"
echo "  VM2 (gNodeB) — OVS Bridge — BACKGROUND"
echo "  Console: telnet 127.0.0.1 5556"
echo "  Login:   root / linux"
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
    -append "root=/dev/vda1 console=ttyS0,115200 net.ifnames=0 biosdevname=0 hugepages=0 rw" \
    -display none \
    -serial telnet:127.0.0.1:5556,server,nowait \
    -monitor telnet:127.0.0.1:55501,server,nowait \
    -pidfile /tmp/vm2.pid \
    -daemonize

echo ""
echo "✅ VM2 launched (PID: $(cat /tmp/vm2.pid))"
echo "→ telnet 127.0.0.1 5556"
echo "→ Login: root / linux"
