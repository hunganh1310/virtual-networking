#!/bin/bash
# ===========================================================
# Task 3 - VPP: Launch VM1 on tap0
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

IMG_PATH="$WORK_DIR/images/vm1.qcow2"
KERNEL="$WORK_DIR/boot/vmlinuz"
INITRD="$WORK_DIR/boot/initrd"

check_files_exist "$IMG_PATH" "$KERNEL" "$INITRD" || exit 1
check_interfaces_exist tap0 || {
  echo "ERROR: tap0 not found. Create TAP interfaces before launching VMs."
  exit 1
}
check_commands qemu-system-x86_64 || exit 1

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
