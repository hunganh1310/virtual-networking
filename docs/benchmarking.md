# Benchmarking Methodology

This document outlines the testing procedures, tools, and metrics used to evaluate and compare virtual networking engines in this lab.

---

## 🛠️ Testing Tools

### 1. iperf3 (Throughput)
The primary tool for measuring TCP and UDP throughput.
- **TCP**: Measures the maximum sustainable bandwidth (Goodput). Uses multiple parallel streams by default (`-P 4`) to saturate the link.
- **UDP**: Used to measure packet loss and jitter at specific bitrates.

### 2. Ping (Latency)
Used to measure the Round-Trip Time (RTT).
- Measures the processing delay of the networking stack and the engine.
- Parameters: 100 packets, 0.1s interval for high-resolution results.

### 3. TRex (Advanced RFC 2544)
For carrier-grade testing, TRex generates traffic at different frame sizes (64B, 128B, ..., 1518B).
- **Throughput Sweep**: Finds the "Zero Loss" point for each frame size.
- **Latency Sweep**: Measures how latency scales with load.

---

## 📈 Key Metrics

| Metric | Measurement | Interpretation |
|--------|-------------|----------------|
| **TCP Rx Throughput** | Mbps / Gbps | Overall system capacity for stateful traffic. |
| **UDP Packet Loss** | Percentage (%) | Reliability and buffer efficiency of the engine. |
| **Avg Latency** | Milliseconds (ms) | Crucial for 5G/NFV use cases (URLLC). |
| **Datapath Cache Hit** | Percentage (%) | (OVS-only) Efficiency of the kernel fast-path. |

---

## 🔬 Test Procedure

1. **Deployment**: The engine is deployed via `vnctl deploy`.
2. **Warm-up**: A short 5-second traffic burst is sent to populate ARP tables and datapath caches.
3. **Execution**:
   - `bench_latency`: 100 ping packets.
   - `bench_iperf3_tcp`: 30-second TCP test.
   - `bench_iperf3_udp`: 30-second test at 200 Mbps (default).
   - `bench_iperf3_udp_max`: 30-second test with unlimited UDP bitrate.
4. **Data Collection**: Results are saved as JSON and text in `results/<engine>/<timestamp>/`.
5. **Report Generation**: `vnctl bench compare` aggregates the latest results into a cross-engine report.

---

## ⚠️ Caveats & Environment Notes

### WSL2 and Virtualization Overhead
Benchmarks run in a nested-KVM environment (WSL2 or a VM) will show lower absolute numbers than bare-metal hardware.
- **Virtio overhead**: The QEMU `virtio-net` driver involves multiple context switches between the VM and the Host.
- **Interrupt Coalescing**: May affect latency measurements at low loads.

### VPP TAP vs. DPDK
In this lab's default configuration, VPP uses **Kernel TAP** interfaces. 
- **TAP Overhead**: Packets must still pass through the kernel to reach the VPP process.
- **DPDK Advantage**: In DPDK mode (hardware only), VPP reads directly from the NIC, eliminating the kernel path entirely. Expect a **5x-10x performance boost** with DPDK.

---

## 📊 Interpreting iperf3 JSON Results

Each benchmark run produces a `tcp.json` or `udp.json` file.
- `end.sum_received.bits_per_second`: The most accurate measurement of received throughput.
- `end.sum.lost_percent`: The percentage of UDP packets dropped during the test.
- `intervals`: Provides time-series data to check for throughput "dips" or instability.
