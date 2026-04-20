# Virtual Networking in Telco

This repository contains a 3-part virtual networking lab for telco/NFV scenarios using:

- Task 1: Linux Bridge + QEMU/KVM VMs
- Task 2: Open vSwitch (OVS) + QEMU/KVM VMs
- Task 3: VPP (Vector Packet Processing) workflow and measurement scripts

The scripts are designed for a Linux environment (for example openSUSE/Ubuntu or WSL2 with nested KVM).

## Repository Structure

```text
.
├── task1-qemu-kvm/
│   └── scripts/
│       ├── setup-network.sh
│       ├── launch-vm1.sh
│       ├── launch-vm2.sh
│       └── cleanup.sh
├── task2-ovs/
│   ├── scripts/
│   │   ├── setup-ovs-network.sh
│   │   ├── launch-vm1-ovs.sh
│   │   ├── launch-vm2-ovs.sh
│   │   └── cleanup-ovs.sh
│   └── results/
│       └── ovs-benchmark.md
├── scripts/
│   └── preflight.sh
└── task3-vpp/
	├── config/
	│   └── startup.conf
	├── results/
	└── scripts/
		├── launch-vm1.sh
		├── launch-vm2.sh
		├── benchmark-vpp.sh
		└── collect-vpp-stats.sh
```

## Prerequisites

Install base tools:

```bash
sudo zypper install -y qemu-kvm iproute2 bridge-utils iperf3 telnet
```

Install/start OVS for Task 2:

```bash
sudo zypper install -y openvswitch
sudo systemctl enable --now openvswitch
```

Install VPP for Task 3 (package/source depends on distro):

```bash
vpp -v
vppctl -v
```

## Task 1: Linux Bridge + QEMU/KVM

From [task1-qemu-kvm/scripts/setup-network.sh](task1-qemu-kvm/scripts/setup-network.sh):

```bash
cd task1-qemu-kvm/scripts
sudo bash setup-network.sh
```

Launch VM1 in foreground:

```bash
./launch-vm1.sh
```

Launch VM2 in background:

```bash
./launch-vm2.sh
```

Cleanup:

```bash
sudo bash cleanup.sh
```

## Task 2: Open vSwitch (OVS)

From [task2-ovs/scripts/setup-ovs-network.sh](task2-ovs/scripts/setup-ovs-network.sh):

```bash
cd task2-ovs/scripts
sudo bash setup-ovs-network.sh
```

Launch VMs:

```bash
./launch-vm1-ovs.sh
./launch-vm2-ovs.sh
```

Cleanup:

```bash
sudo bash cleanup-ovs.sh
```

Benchmark report is available at [task2-ovs/results/ovs-benchmark.md](task2-ovs/results/ovs-benchmark.md).

## Task 3: VPP Workflow

VPP startup config: [task3-vpp/config/startup.conf](task3-vpp/config/startup.conf)

Launch VM pair for VPP scenario:

```bash
cd task3-vpp/scripts
./launch-vm1.sh
./launch-vm2.sh
```

Run benchmark from VM1 side:

```bash
./benchmark-vpp.sh
```

Collect VPP runtime/interface/error stats:

```bash
./collect-vpp-stats.sh
```

Task 3 output files are now standardized under [task3-vpp/results](task3-vpp/results).

## Shared Preflight

Shared preflight helpers are provided in [scripts/preflight.sh](scripts/preflight.sh) and are used by launch scripts across Task 1, Task 2, and Task 3.

It validates:

- Required binaries (for example `qemu-system-x86_64`)
- Required files (images/kernel/initrd)
- Required network interfaces (for example `tap0`, `tap1`)

### Completed Improvements

1. Replaced hardcoded workspace paths with script-relative path discovery in launch scripts.
2. Added shared preflight checks (commands/files/interfaces) and integrated them across Task 1/2/3 launch scripts.
3. Hardened OVS cleanup to handle missing/stale VM2 PID files gracefully.
4. Made OVS bridge IP setup idempotent by flushing bridge IP before re-adding.
5. Standardized Task 3 benchmark/stat outputs into a single directory: [task3-vpp/results](task3-vpp/results).
