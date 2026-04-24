# Quick Start Guide

## Prerequisites

| Component | Required | Install (openSUSE) |
|-----------|----------|-------------------|
| KVM | ✅ | `zypper install qemu-kvm` |
| QEMU | ✅ | `zypper install qemu-x86` |
| OVS | For OVS topology | `zypper install openvswitch` |
| VPP | For VPP topology | See [fd.io docs](https://fd.io/docs/vpp/latest/) |
| iperf3 | For benchmarks | `zypper install iperf3` |
| yq | Optional (YAML) | `pip install yq` or use awk fallback |

## System Check

```bash
./vnctl doctor
```

This checks for KVM support, installed tools, VM images, and boot files.

## Deploy a Topology

### Option 1: OVS (Recommended for SDN)

```bash
# Deploy OVS network
sudo ./vnctl deploy ovs

# Launch VMs
sudo ./vnctl vm start vm1            # Foreground (serial console)
sudo ./vnctl vm start vm2 --bg       # Background (telnet)

# Inside VMs — configure IPs
# VM1: ip addr add 10.0.0.1/24 dev eth0 && ip link set eth0 up
# VM2: ip addr add 10.0.0.2/24 dev eth0 && ip link set eth0 up

# Test connectivity
# VM1: ping 10.0.0.2
```

### Option 2: VPP (High Performance)

```bash
sudo ./vnctl deploy vpp
sudo ./vnctl vm start vm1
# (in another terminal)
sudo ./vnctl vm start vm2
```

### Option 3: Linux Bridge (Baseline)

```bash
sudo ./vnctl deploy linux-bridge
sudo ./vnctl vm start vm1
sudo ./vnctl vm start vm2 --bg
```

## Check Status

```bash
# VM status
sudo ./vnctl vm list

# Network status
sudo ./vnctl status ovs
```

## Run Benchmarks

```bash
# Start iperf3 server on VM2 first:
# VM2: iperf3 -s

# Run benchmark suite (from host)
sudo ./vnctl bench run ovs

# Results saved to results/ovs/<timestamp>/
```

## Compare Engines

```bash
# Run benchmarks on both engines first
sudo ./vnctl bench run ovs
sudo ./vnctl bench run vpp

# Generate comparison report
sudo ./vnctl bench compare

# Report saved to results/comparison/
```

## Tear Down

```bash
# Stop VMs and remove network
sudo ./vnctl teardown ovs
```

## VM Access

| VM | Foreground | Background |
|----|-----------|------------|
| Console | Serial (Ctrl+A, X to exit) | `telnet 127.0.0.1 5556` |
| Login | `root / linux` | `root / linux` |
| Stop | Ctrl+A, X | `sudo ./vnctl vm stop vm2` |
