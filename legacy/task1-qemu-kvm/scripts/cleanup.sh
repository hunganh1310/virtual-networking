#!/bin/bash
# ===========================================================
# Lab 2 - Task 1: Cleanup - Stop VMs + Remove network
# ===========================================================

echo "=== Stopping VMs ==="
for pid_file in /tmp/vm1.pid /tmp/vm2.pid; do
    if [[ -f "$pid_file" ]]; then
        PID=$(cat "$pid_file")
        if kill -0 "$PID" 2>/dev/null; then
            kill "$PID"
            echo "VM stopped (PID: $PID)"
        fi
        rm -f "$pid_file"
    fi
done

echo ""
echo "=== Removing network ==="
sudo ip link set tap0 down 2>/dev/null
sudo ip link set tap1 down 2>/dev/null
sudo ip link set br-test down 2>/dev/null

sudo ip link del tap0 2>/dev/null && echo "Removed tap0" || echo "tap0 does not exist"
sudo ip link del tap1 2>/dev/null && echo "Removed tap1" || echo "tap1 does not exist"
sudo ip link del br-test 2>/dev/null && echo "Removed br-test" || echo "br-test does not exist"

echo ""
echo "Cleanup completed"
