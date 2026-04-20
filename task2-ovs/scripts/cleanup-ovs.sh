#!/bin/bash
# ===========================================================
# Lab 2 - Task 2: Cleanup OVS + VMs
# ===========================================================

echo "=== Killing VMs ==="
if [[ -f /tmp/vm2.pid ]]; then
	VM2_PID=$(cat /tmp/vm2.pid)
	if kill -0 "$VM2_PID" 2>/dev/null; then
		kill "$VM2_PID" && echo "VM2 killed"
	else
		echo "VM2 pid file exists but process is not running"
	fi
	rm -f /tmp/vm2.pid
else
	echo "VM2 not running"
fi
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
