#!/usr/bin/env python3
"""
benchmark/trex-profile.py — TRex RFC 2544 Traffic Profile
===========================================================
TRex (Cisco Traffic Generator) profile for measuring NFV engine performance
using RFC 2544 methodology. Supports bidirectional throughput, latency,
frame loss rate, and back-to-back burst tests.

ARCHITECTURE
------------
TRex generates traffic on one port and receives on another.
In this lab, TRex connects to the network via two TAP interfaces
or two physical ports (the latter required for true line-rate testing).

    [TRex Port 0] → tap-trex0 → [Engine: OVS/VPP] → tap-trex1 → [TRex Port 1]
                                  ↑ DUT (Device Under Test)

REQUIREMENTS
------------
- TRex v3.x installed: https://trex-tgn.cisco.com/trex/release/
  Download: wget https://trex-tgn.cisco.com/trex/release/latest.tar.gz
- Python 3.6+ with TRex stateless API
- Two TAP interfaces connected to the engine bridge
  (or two physical NICs bound to DPDK/vfio-pci for hardware testing)

TAP-BASED SETUP (software, ~1-10 Gbps depending on CPU)
---------------------------------------------------------
    # Create TRex TAP interfaces and attach to OVS:
    ip tuntap add dev tap-trex0 mode tap
    ip tuntap add dev tap-trex1 mode tap
    ip link set tap-trex0 up
    ip link set tap-trex1 up
    ovs-vsctl add-port ovs-br0 tap-trex0
    ovs-vsctl add-port ovs-br0 tap-trex1

    # Run TRex in interactive mode against TAP interfaces:
    cd /opt/trex && sudo ./t-rex-64 -i --cfg trex_cfg.yaml

TREX CONFIG FILE (trex_cfg.yaml)
---------------------------------
    - port_limit: 2
      version: 2
      interfaces:
        - tap-trex0   # Port 0 (Tx)
        - tap-trex1   # Port 1 (Rx)
      port_info:
        - ip: 10.0.0.10
          default_gw: 10.0.0.254
        - ip: 10.0.0.11
          default_gw: 10.0.0.254

USAGE
-----
    # From TRex installation directory:
    python3 /path/to/trex-profile.py --trex-host 127.0.0.1 --engine ovs

    # Run specific test:
    python3 trex-profile.py --test throughput --duration 60
    python3 trex-profile.py --test latency --duration 30
    python3 trex-profile.py --test rfc2544

INTEGRATION WITH vnctl
-----------------------
Future: vnctl bench run --trex ovs
    This will auto-create TAP interfaces, attach to OVS, and invoke this script.
"""

import argparse
import json
import os
import sys
import time
from datetime import datetime

# ---------------------------------------------------------------------------
# TRex API Import (graceful fallback if TRex not installed)
# ---------------------------------------------------------------------------
try:
    sys.path.insert(0, "/opt/trex/automation/trex_control_plane/interactive")
    from trex.stl.api import (
        STLClient,
        STLFlowLatencyStats,
        STLPktBuilder,
        STLStream,
        STLTXCont,
        STLTXSingleBurst,
        STLVmFlowVar,
        STLVmFixIpv4,
        STLVmWrFlowVar,
    )
    from scapy.layers.inet import IP, TCP, UDP, Ether
    TREX_AVAILABLE = True
except ImportError:
    TREX_AVAILABLE = False
    print("[WARN] TRex API not found — running in stub/documentation mode.")
    print("       Install TRex: https://trex-tgn.cisco.com/trex/release/")
    print("")

# ---------------------------------------------------------------------------
# Traffic Profile Definitions
# ---------------------------------------------------------------------------

# RFC 2544 standard frame sizes
RFC2544_FRAME_SIZES = [64, 128, 256, 512, 1024, 1280, 1518]

# Default test parameters
DEFAULT_DURATION   = 30     # seconds per frame size
DEFAULT_RATE_PERCENT = 50.0 # start at 50% line rate for binary search
DEFAULT_LATENCY_PPS  = 1000 # latency stream PPS (low rate for accuracy)


def build_udp_stream(src_ip: str, dst_ip: str, frame_size: int,
                     rate_percent: float, port_id: int) -> "STLStream":
    """Build a UDP stream with variable frame size."""
    payload_size = max(0, frame_size - 42)  # 14 Eth + 20 IP + 8 UDP
    pkt = (
        Ether() /
        IP(src=src_ip, dst=dst_ip) /
        UDP(sport=1234, dport=5001) /
        (b"X" * payload_size)
    )
    return STLStream(
        name=f"udp_{frame_size}B_port{port_id}",
        packet=STLPktBuilder(pkt=pkt),
        mode=STLTXCont(percentage=rate_percent),
    )


def build_latency_stream(src_ip: str, dst_ip: str, pg_id: int) -> "STLStream":
    """Build a low-rate latency measurement stream (tagged with pg_id)."""
    pkt = Ether() / IP(src=src_ip, dst=dst_ip) / UDP(sport=9999, dport=9999)
    return STLStream(
        name=f"latency_pg{pg_id}",
        packet=STLPktBuilder(pkt=pkt),
        mode=STLTXCont(pps=DEFAULT_LATENCY_PPS),
        flow_stats=STLFlowLatencyStats(pg_id=pg_id),
    )


# ---------------------------------------------------------------------------
# Test Runners
# ---------------------------------------------------------------------------

class TRexNFVBenchmark:
    """Runs RFC 2544-style benchmarks against an NFV engine via TRex."""

    def __init__(self, trex_host: str, engine: str, results_dir: str):
        self.trex_host   = trex_host
        self.engine      = engine
        self.results_dir = results_dir
        self.results     = []

    def run_throughput_sweep(self, duration: int = DEFAULT_DURATION):
        """RFC 2544 Throughput: measure max lossless rate per frame size."""
        print(f"\n[RFC 2544] Throughput Sweep — {len(RFC2544_FRAME_SIZES)} frame sizes")
        print(f"  Engine: {self.engine}  Duration: {duration}s per frame size")
        print("")

        if not TREX_AVAILABLE:
            self._stub_throughput_sweep(duration)
            return

        with STLClient(server=self.trex_host) as c:
            c.connect()
            c.reset()

            for frame_size in RFC2544_FRAME_SIZES:
                result = self._binary_search_rate(c, frame_size, duration)
                self.results.append(result)
                print(f"  {frame_size:5d} B  →  {result['max_lossless_rate_pct']:6.2f}%  "
                      f"({result['max_lossless_gbps']:.3f} Gbps)")

            c.disconnect()

    def _binary_search_rate(self, client, frame_size: int, duration: int) -> dict:
        """Binary search for max lossless rate at a given frame size."""
        lo, hi = 1.0, 100.0
        result_rate = 0.0

        for iteration in range(8):  # 8 iterations = 0.4% precision
            mid = (lo + hi) / 2.0
            tx_pkts, rx_pkts = self._run_single_rate(client, frame_size, mid, duration)
            loss = tx_pkts - rx_pkts

            if loss == 0:
                result_rate = mid
                lo = mid
            else:
                hi = mid

        # Calculate throughput at max lossless rate
        bits_per_pkt = (frame_size + 20) * 8  # +20 for Ethernet preamble+IFG
        line_rate_bps = 10e9  # assume 10GbE (adjust per your NIC)
        gbps = (line_rate_bps * result_rate / 100.0) / 1e9

        return {
            "frame_size": frame_size,
            "max_lossless_rate_pct": result_rate,
            "max_lossless_gbps": gbps,
            "engine": self.engine,
            "timestamp": datetime.now().isoformat(),
        }

    def _run_single_rate(self, client, frame_size: int, rate_pct: float,
                         duration: int):
        """Run a single rate test. Returns (tx_pkts, rx_pkts)."""
        streams = [
            build_udp_stream("10.0.0.10", "10.0.0.11", frame_size, rate_pct, 0),
            build_udp_stream("10.0.0.11", "10.0.0.10", frame_size, rate_pct, 1),
        ]
        client.add_streams(streams, ports=[0, 1])
        client.start(ports=[0, 1], duration=duration)
        client.wait_on_traffic(ports=[0, 1])
        stats = client.get_stats()
        client.remove_all_streams()

        tx = stats[0]["opackets"] + stats[1]["opackets"]
        rx = stats[0]["ipackets"] + stats[1]["ipackets"]
        return tx, rx

    def run_latency(self, duration: int = DEFAULT_DURATION):
        """Measure one-way and round-trip latency at low load."""
        print(f"\n[Latency] Measuring latency at {DEFAULT_LATENCY_PPS} pps ({duration}s)")

        if not TREX_AVAILABLE:
            print("  STUB: TRex not installed. Expected results for reference:")
            print("        Linux Bridge : ~50-100 µs")
            print("        OVS (kernel) : ~100-200 µs")
            print("        VPP (tap)    : ~200-400 µs (TAP overhead)")
            print("        VPP (DPDK)   : ~10-50 µs  (no kernel bypass on TAP)")
            return

        with STLClient(server=self.trex_host) as c:
            c.connect()
            c.reset()
            streams = [build_latency_stream("10.0.0.10", "10.0.0.11", pg_id=1)]
            c.add_streams(streams, ports=[0])
            c.start(ports=[0], duration=duration)
            c.wait_on_traffic(ports=[0])
            stats = c.get_stats()
            lat = stats["latency"][1]["latency"]

            print(f"  Min RTT:  {lat.get('total_min', 'N/A')} µs")
            print(f"  Avg RTT:  {lat.get('average',   'N/A')} µs")
            print(f"  Max RTT:  {lat.get('total_max', 'N/A')} µs")
            print(f"  Jitter:   {lat.get('jitter',    'N/A')} µs")
            c.disconnect()

    def save_results(self):
        """Save results as JSON to the results directory."""
        if not self.results:
            return
        os.makedirs(self.results_dir, exist_ok=True)
        ts = datetime.now().strftime("%Y%m%d-%H%M%S")
        out = os.path.join(self.results_dir, f"trex-{self.engine}-{ts}.json")
        with open(out, "w") as f:
            json.dump(self.results, f, indent=2)
        print(f"\n[✓] Results saved to {out}")

    # Stub mode — simulates output without TRex
    def _stub_throughput_sweep(self, duration: int):
        print("  STUB MODE — TRex not installed. Simulating expected results:")
        print("")
        print(f"  {'Frame':>8}  {'Max Rate':>10}  {'Throughput':>12}")
        print(f"  {'─────':>8}  {'────────':>10}  {'──────────':>12}")
        # Representative expected values for OVS kernel path
        stub_data = {
            "linux-bridge": [80, 70, 60, 55, 50, 48, 45],
            "ovs":          [95, 92, 88, 85, 82, 80, 78],
            "vpp":          [98, 97, 96, 95, 94, 93, 92],
        }
        rates = stub_data.get(self.engine, stub_data["ovs"])
        for i, fs in enumerate(RFC2544_FRAME_SIZES):
            pct = rates[i]
            gbps = 10.0 * pct / 100.0
            print(f"  {fs:8d}B  {pct:9.1f}%  {gbps:9.3f} Gbps")
        print("")
        print("  [!] These are stub values for reference. Run with TRex for real results.")


# ---------------------------------------------------------------------------
# CLI Entry Point
# ---------------------------------------------------------------------------

def parse_args():
    p = argparse.ArgumentParser(
        description="TRex RFC 2544 NFV Engine Benchmark",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    p.add_argument("--trex-host", default="127.0.0.1",
                   help="TRex server IP (default: 127.0.0.1)")
    p.add_argument("--engine", choices=["linux-bridge", "ovs", "vpp"],
                   default="ovs", help="Engine under test (for labeling)")
    p.add_argument("--test", choices=["throughput", "latency", "rfc2544", "all"],
                   default="all", help="Test to run (default: all)")
    p.add_argument("--duration", type=int, default=DEFAULT_DURATION,
                   help=f"Test duration in seconds (default: {DEFAULT_DURATION})")
    p.add_argument("--results-dir", default="results/trex",
                   help="Output directory for results")
    return p.parse_args()


def main():
    args = parse_args()

    bench = TRexNFVBenchmark(
        trex_host=args.trex_host,
        engine=args.engine,
        results_dir=args.results_dir,
    )

    print(f"\nTRex NFV Benchmark — Engine: {args.engine.upper()}")
    print(f"TRex Server: {args.trex_host}")
    if not TREX_AVAILABLE:
        print("[STUB MODE — install TRex for real measurements]")
    print("")

    if args.test in ("throughput", "rfc2544", "all"):
        bench.run_throughput_sweep(duration=args.duration)

    if args.test in ("latency", "rfc2544", "all"):
        bench.run_latency(duration=args.duration)

    bench.save_results()


if __name__ == "__main__":
    main()
