#!/bin/bash
# ===========================================================
# Task 3 - VPP: Launch VM1 on tap0
# ===========================================================
set -euo pipefail

WORK_DIR=~/telco-lab/virtual-networking/task1-qemu-kvm
IMG_PATH="$WORK_DIR/images/vm1.qcow2"
KERNEL="$WORK_DIR/boot/vmlinuz"
INITRD="$WORK_DIR/boot/initrd"

# Verify files
for f in "$IMG_PATH" "$KERNEL" "$INITRD"; do
  if [[ ! -f "$f" ]]; then
    echo "❌ Missing: $f"
    exit 1
  fi
done

echo "============================================"
echo "  Launching VM1 on tap0 (VPP scenario)"
echo "  Image : $IMG_PATH"
echo "  Exit  : Ctrl+A, X"
echo "============================================"

sudo qemu-system-x86_64 \
  -name vm1 \
  -enable-kvm \
  -m 512 \
  -smp 1 \
  -drive file=$IMG_PATH,if=virtio,format=qcow2 \
  -kernel $KERNEL \
  -initrd $INITRD \
  -append "root=/dev/vda1 console=ttyS0 rw" \
  -netdev tap,id=net0,ifname=tap0,script=no,downscript=no \
  -device virtio-net-pci,netdev=net0,mac=52:54:00:00:00:01 \
  -nographic \
  -serial mon:stdio
