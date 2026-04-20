#!/bin/bash
# Run trên VM1 (client side)
RESULTS_DIR=~/vpp-results
mkdir -p $RESULTS_DIR

echo "=== TCP Throughput Test (30s) ==="
iperf3 -c 10.0.0.2 -t 30 -i 5 -J > $RESULTS_DIR/tcp.json
iperf3 -c 10.0.0.2 -t 30 -i 5 | tee $RESULTS_DIR/tcp.txt

echo ""
echo "=== UDP Throughput Test (30s, unlimited) ==="
iperf3 -c 10.0.0.2 -u -b 0 -t 30 -i 5 -J > $RESULTS_DIR/udp.json
iperf3 -c 10.0.0.2 -u -b 0 -t 30 -i 5 | tee $RESULTS_DIR/udp.txt

echo ""
echo "=== Parallel streams (4) ==="
iperf3 -c 10.0.0.2 -P 4 -t 30 -i 5 | tee $RESULTS_DIR/tcp-parallel.txt

echo ""
echo "Results saved to $RESULTS_DIR"
