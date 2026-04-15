#!/bin/bash
# ===========================================================
# Lab 2 - Task 1: Cleanup - Tắt VMs + Xóa network
# ===========================================================

echo "=== Tắt VMs ==="
for pid_file in /tmp/vm1.pid /tmp/vm2.pid; do
    if [[ -f "$pid_file" ]]; then
        PID=$(cat "$pid_file")
        if kill -0 "$PID" 2>/dev/null; then
            kill "$PID"
            echo "Đã tắt VM (PID: $PID)"
        fi
        rm -f "$pid_file"
    fi
done

echo ""
echo "=== Xóa network ==="
sudo ip link set tap0 down 2>/dev/null
sudo ip link set tap1 down 2>/dev/null
sudo ip link set br-test down 2>/dev/null

sudo ip link del tap0 2>/dev/null && echo "Đã xóa tap0" || echo "tap0 không tồn tại"
sudo ip link del tap1 2>/dev/null && echo "Đã xóa tap1" || echo "tap1 không tồn tại"
sudo ip link del br-test 2>/dev/null && echo "Đã xóa br-test" || echo "br-test không tồn tại"

echo ""
echo "✅ Cleanup hoàn tất"
