# bbr-brutal DKMS module

`bbr_brutal` is an experimental TCP congestion-control module derived from the provided BBRx DKMS compatibility approach. It keeps BBR-style `STARTUP` and `DRAIN` for initial bandwidth discovery, uses a custom Brutal-style steady-state `PROBE_BW`, and restores BBRv1-style `PROBE_RTT`.

## Control loop

| Mode / phase | Pacing behavior |
| --- | --- |
| `STARTUP` | BBR high-gain startup to discover initial bottleneck bandwidth |
| `DRAIN` | BBR drain after startup until in-flight data is near estimated BDP |
| `PROBE_BW / PROBE_UP` | gain `1.25`; Brutal compensation disabled |
| `PROBE_BW / DRAIN` | gain `0.75`; stays here until in-flight data is `<= estimated BDP` |
| `PROBE_BW / CRUISE` | gain `1.00`; Brutal loss compensation enabled |
| `LOSS_GUARD` | if the last packet-timed round loss is `> loss_guard_percent`, compensation is disabled and normal BBR-style cwnd/loss recovery is used |
| `PROBE_RTT` | BBRv1-style min-RTT refresh: cwnd cap `4`, pacing gain `1.00`, cwnd gain `1.00`, duration `>= 200 ms` and one packet-timed round |

Brutal compensation is only applied in `PROBE_BW / CRUISE` and only when the connection is not in loss recovery, not using long-term policer bandwidth, and not in `LOSS_GUARD`.

```text
ack_percent = max(100 - loss_percent, min_ack_percent)
effective_cruise_gain = 1.00 * 100 / ack_percent
```

With defaults, `min_ack_percent=80`, so CRUISE compensation is capped at `1.25x`. If loss is greater than `loss_guard_percent=20`, compensation is disabled.

## ProbeRTT behavior

This version restores BBRv1-style `PROBE_RTT`:

```text
min_rtt filter window: 10 seconds
PROBE_RTT cwnd cap:   4 packets
PROBE_RTT minimum:    200 ms and one packet-timed round
PROBE_RTT exit:       return to PROBE_BW if full bandwidth was reached, otherwise STARTUP
```

While in `PROBE_RTT`, the module disables Brutal compensation because the mode is outside `PROBE_BW / CRUISE` and uses BBRv1 pacing/cwnd gains of `1.00`.

## Requested recovery change

The BBR recovery entry cut is preserved with your requested modification:

```c
cwnd = max(cwnd, tcp_packets_in_flight(tp) + acked);
```

instead of directly setting:

```c
cwnd = tcp_packets_in_flight(tp) + acked;
```

Packet conservation still uses:

```c
*new_cwnd = max(cwnd, tcp_packets_in_flight(tp) + acked);
```

## Files

```text
tcp_bbr_brutal.c  Kernel TCP congestion-control module
Makefile          External module / DKMS build Makefile with tcp.h API probes
dkms.conf         DKMS package configuration
README.md         This file
```

## Install with DKMS

```bash
sudo mkdir -p /usr/src/bbr-brutal-0.1.1
sudo cp -a tcp_bbr_brutal.c Makefile dkms.conf README.md /usr/src/bbr-brutal-0.1.1/

sudo dkms add -m bbr-brutal -v 0.1.1
sudo dkms build -m bbr-brutal -v 0.1.1
sudo dkms install -m bbr-brutal -v 0.1.1

sudo modprobe tcp_bbr_brutal
sysctl net.ipv4.tcp_available_congestion_control
```

To enable it for new TCP sockets:

```bash
sudo sysctl -w net.core.default_qdisc=fq
sudo sysctl -w net.ipv4.tcp_congestion_control=bbr_brutal
```

To make it persistent:

```bash
cat <<'SYSCTL' | sudo tee /etc/sysctl.d/99-bbr-brutal.conf
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr_brutal
SYSCTL
sudo sysctl --system
```

## Module parameters

```bash
sudo modprobe tcp_bbr_brutal min_ack_percent=80 loss_guard_percent=20
```

`min_ack_percent` controls the Brutal compensation cap. Lower values allow more compensation; higher values reduce compensation. `loss_guard_percent` controls when compensation is disabled. Defaults implement the requested behavior: full Brutal compensation up to a 20% loss boundary, then `LOSS_GUARD`.

## Compatibility

The Makefile probes the target kernel's `include/net/tcp.h` instead of relying only on `LINUX_VERSION_CODE`. This is intended to keep the module buildable across stock Linux kernels and kernels with BBRv3/L4S TCP congestion-control API changes.

This package was smoke-built against local Debian 6.12.74 headers. Kernel 5.10 through 7.1 and Google BBRv3 kernels still need build/runtime validation on those exact trees.

## Important note

`bbr_brutal` is intentionally aggressive in steady-state CRUISE because it applies Brutal compensation there. `PROBE_RTT` now periodically drains to refresh `min_rtt`, but this is still experimental and should be tested in a controlled environment before system-wide deployment.
