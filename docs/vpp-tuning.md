# VPP Performance Tuning Guide

FD.io VPP is designed for multi-terabit performance. To achieve optimal results in this lab, several system-level tunings are required.

---

## 💎 1. HugePages (Critical)

VPP uses HugePages (2MB or 1GB) to minimize TLB misses and ensure contiguous memory for buffer pools.

### Configuration
Use the provided script to allocate at least 1GB of HugePages:
```bash
sudo ./scripts/setup-hugepages.sh --count 512 --persistent
```

### Verification
```bash
grep -i huge /proc/meminfo
# HugePages_Total:     512
# HugePages_Free:      508
```

---

## 🧵 2. CPU Pinning & Worker Threads

By default, VPP runs on a single core. For production-grade throughput, you must pin VPP to specific cores.

### `startup.conf` Settings
```hcl
cpu {
  main-core 0            # VPP Control Plane on Core 0
  corelist-workers 1-3   # VPP Data Plane on Cores 1, 2, and 3
}
```

### Why Pinning Matters
- **L1/L2 Cache Locality**: Prevents the OS from migrating VPP threads between cores.
- **Isolcpus**: For maximum performance, exclude these cores from the Linux scheduler using the `isolcpus=1,2,3` kernel boot parameter.

---

## 📦 3. Buffer Sizing

VPP processes packets in batches (vectors). The buffer pool must be large enough to handle bursts and high-speed links.

```hcl
buffers {
  buffers-per-numa 65536  # Default is often too small for 10GbE+
  default data-size 2048  # Standard MTU size
}
```

---

## 🔌 4. Interface Modes

### TAP Mode (Standard Lab)
In this lab, VPP connects to VMs via TAPs.
- **Optimization**: Use `virtio` based TAPs.
- **Command**: `create tap id 0 host-if-name tap0 virtio`

### DPDK Mode (Performance)
The gold standard for VPP. Bypasses the kernel using Poll Mode Drivers (PMD).
- **Setup**: Bind NIC to `vfio-pci`.
- **Config**: Use `config/vpp/startup-dpdk.conf`.

---

## 🧪 5. Runtime Telemetry

Use these commands while running a benchmark to identify bottlenecks:

| Command | Purpose |
|---------|---------|
| `show run` | Shows CPU cycles per packet for each graph node. |
| `show int` | Check for interface drops or RX-misses. |
| `show buffers` | Check for buffer exhaustion. |
| `show error` | Detailed count of packet drops (e.g., checksum fail, no route). |

---

## 🛠️ 6. System Level Tuning

For bare-metal deployments, also consider:
- **IOMMU**: Must be enabled for DPDK/VFIO (`intel_iommu=on`).
- **Power Management**: Set CPU governor to `performance`.
- **IRQ Balance**: Disable `irqbalance` service for pinned cores.
