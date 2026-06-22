# bbrw_brutal DKMS module

`bbrw_brutal` is the renamed BBRW + Brutal hybrid TCP congestion-control module.
It preserves your edited hybrid behavior and registers the congestion-control
name as `bbrw_brutal`.

Implemented behavior:

- BBR STARTUP and DRAIN for initial bandwidth discovery.
- Three-phase steady state:
  - `PROBE_UP`: `pacing_gain = 1.25`, no Brutal compensation.
  - `DRAIN`: `pacing_gain = 0.75` until in-flight is <= estimated BDP.
  - `CRUISE`: `pacing_gain = 1.00` with Brutal compensation.
  - `LOSS_GUARD`: compensation disabled when loss exceeds the configured threshold.
- BBRW-style RTT p95 estimator for the BDP delay component.
- BBR ProbeRTT remains removed.

## Install with DKMS

```bash
sudo mkdir -p /usr/src/bbrw-brutal-0.1.2
sudo cp -a . /usr/src/bbrw-brutal-0.1.2/

sudo dkms add -m bbrw-brutal -v 0.1.2
sudo dkms build -m bbrw-brutal -v 0.1.2
sudo dkms install -m bbrw-brutal -v 0.1.2

sudo modprobe tcp_bbrw_brutal
```

Enable it for new TCP sockets:

```bash
sudo sysctl -w net.core.default_qdisc=fq
sudo sysctl -w net.ipv4.tcp_congestion_control=bbrw_brutal
```

Persist it:

```bash
echo 'net.core.default_qdisc=fq' | sudo tee /etc/sysctl.d/99-bbrw-brutal.conf
echo 'net.ipv4.tcp_congestion_control=bbrw_brutal' | sudo tee -a /etc/sysctl.d/99-bbrw-brutal.conf
sudo sysctl --system
```

Check registration:

```bash
sysctl net.ipv4.tcp_available_congestion_control
sysctl net.ipv4.tcp_congestion_control
modinfo tcp_bbrw_brutal
```

Module parameters:

```bash
sudo modprobe tcp_bbrw_brutal loss_guard_percent=20 min_ack_percent=80
```
