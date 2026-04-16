#!/bin/bash
# ===========================================================
# Lab 2 - Task 2: Cleanup OVS + VMs
# ===========================================================

echo "=== Killing VMs ==="
kill $(cat /tmp/vm2.pid) 2>/dev/null && echo "VM2 killed" || echo "VM2 not running"
pkill -f "qemu.*vm1" 2>/dev/null && echo "VM1 killed" || echo "VM1 not running"
sleep 1

echo ""
echo "=== Removing OVS Bridge ==="
ovs-vsctl --if-exists del-br ovs-br0

echo ""
echo "=== Removing TAP interfaces ==="
ip link delete tap0 2>/dev/null && echo "tap0 deleted" || echo "tap0 not found"
ip link delete tap1 2>/dev/null && echo "tap1 deleted" || echo "tap1 not found"

echo ""
echo "✅ Cleanup complete"
