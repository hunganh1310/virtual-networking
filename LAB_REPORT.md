# Lab Results Summary

## OVS Results (Measured)

- TCP throughput (peak): 18.7-19.9 Gbps
- TCP throughput (average): ~19.3 Gbps
- UDP test at 200 Mbps:
  - Receiver bitrate: ~199 Mbps
  - Packet loss: ~0.63%
  - Jitter: ~0.027-0.156 ms
- Datapath cache hit rate: ~99.95%

## VPP Results (Estimated)

- TCP throughput: ~20-24 Gbps
- UDP at 200 Mbps: stable, expected packet loss <0.5%
- Latency: ~1.3-2.0 ms

## OVS vs VPP (Short Comparison)

- Throughput: VPP is expected to be slightly higher than OVS in this setup.
- Latency: both are low; VPP may be slightly better when tuned.
- Practical note: OVS has confirmed measured results in this lab, while VPP values above are estimates.

## Final Result

- OVS delivered strong, near line-rate performance (~19 Gbps TCP) with low jitter and low loss.
- VPP is likely to provide a small performance gain over OVS, but this should be confirmed with a fresh benchmark run.
