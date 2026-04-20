#!/bin/bash
RESULTS=~/telco-lab/virtual-networking/task3-vpp/results
mkdir -p $RESULTS
TS=$(date +%Y%m%d-%H%M%S)

echo "=== Collecting VPP stats at $TS ==="

vppctl clear runtime
vppctl clear interfaces
vppctl clear errors

echo "Ready! Chạy iperf3 bây giờ, nhấn Enter khi xong..."
read

{
  echo "=== RUNTIME ==="
  vppctl show runtime
  echo ""
  echo "=== INTERFACES ==="
  vppctl show interface
  echo ""
  echo "=== L2FIB ==="
  vppctl show l2fib verbose
  echo ""
  echo "=== ERRORS ==="
  vppctl show errors
  echo ""
  echo "=== BRIDGE-DOMAIN ==="
  vppctl show bridge-domain 10 detail
} > $RESULTS/vpp-stats-$TS.txt

echo "✅ Saved to $RESULTS/vpp-stats-$TS.txt"
