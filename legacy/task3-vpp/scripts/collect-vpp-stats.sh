#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASK3_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS="$TASK3_DIR/results"
mkdir -p "$RESULTS"
TS=$(date +%Y%m%d-%H%M%S)

echo "=== Collecting VPP stats at $TS ==="

vppctl clear runtime
vppctl clear interfaces
vppctl clear errors

echo "Ready! Run iperf3 now, then press Enter when done..."
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
} > "$RESULTS/vpp-stats-$TS.txt"

echo "✅ Saved to $RESULTS/vpp-stats-$TS.txt"
