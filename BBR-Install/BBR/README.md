# TCP BBR Congestion Control and Variant Comparison

> **Audience:** This guide is written for two groups at once: readers who are new to TCP congestion control, and readers who are comfortable reading Linux TCP congestion-control code. Beginner-oriented explanations appear first; code-level notes and operational caveats follow.
>
> **Baseline:** In this document, **Original BBR** means the `tcp_bbr1.c` reference file from Google’s `bbr/v3` branch, not every historical Linux BBRv1 implementation. All comparisons are relative to that baseline unless otherwise stated.
>
> **Scope:** This guide compares Original BBR, upstream BBRv3, and the uploaded out-of-tree variants: `tcp_bbrx.c`, `tcp_bbrw(2).c`, `tcp_bbr_brutal.c`, and `tcp_bbrw_brutal.c`.
>
> **Caution:** The custom variants are experimental. This document describes likely behavior from source code. It is **not** a benchmark result and should not be treated as production deployment advice.

---

## Table of contents

1. [Macro-level summary: what TCP BBR is doing](#macro-level-summary-what-tcp-bbr-is-doing)
2. [Original BBR as the baseline](#original-bbr-as-the-baseline)
3. [Variant comparison against Original BBR](#variant-comparison-against-original-bbr)
4. [Scenario behavior table](#scenario-behavior-table)
5. [Likely implications of the changes](#likely-implications-of-the-changes)
6. [Supplementary guidance for readers and testers](#supplementary-guidance-for-readers-and-testers)
7. [Glossary](#glossary)
8. [Sources](#sources)

---

## Macro-level summary: what TCP BBR is doing

### The problem BBR is trying to solve

TCP has to decide how much data to put into the network. If it sends too slowly, it wastes available bandwidth. If it sends too fast, it fills queues, raises latency, causes packet loss, and may harm other flows.

Traditional TCP algorithms such as Reno and CUBIC are mostly **loss-based**. They increase their sending window until the network drops packets, then reduce the window. BBR takes a different approach: it tries to build a **model** of the path and send near the amount of data that the path can actually hold and deliver.

BBR stands for:

- **BtlBw**: bottleneck bandwidth, meaning the delivery rate of the narrowest link on the path.
- **RTprop / min RTT**: round-trip propagation time, meaning the RTT with little or no queuing.

A useful beginner mental model is a pipe:

```text
pipe volume = pipe width × pipe length
BDP         = bottleneck bandwidth × round-trip time
```

The **bandwidth-delay product** (BDP) is the amount of data that should be in flight to keep the path full without building a persistent queue.

### BBR’s control loop

At a high level, Original BBR can be simplified as:

```c
// Simplified BBR mental model, not literal kernel code.
on_each_ack(sample) {
    bw      = max_recent_delivery_rate(sample.delivered / sample.interval);
    rtt     = min_recent_rtt(sample.rtt);
    bdp     = bw * rtt;

    pacing_rate = pacing_gain * bw;
    cwnd        = max(cwnd_gain * bdp, min_cwnd);
}
```

This is why BBR is often called **model-based congestion control**. It does not wait for packet loss as the primary sign of congestion. Instead, it estimates a bandwidth and RTT model and uses that model to set:

- **pacing rate**: how quickly packets leave the sender;
- **congestion window (`cwnd`)**: the maximum number of packets allowed in flight.

### BBR’s state machine

Original BBR uses four major modes:

```text
STARTUP  ->  DRAIN  ->  PROBE_BW
   ^                       |
   |                       v
   +-------- PROBE_RTT <---+
```

The modes have different jobs:

| Mode | Beginner meaning | Code-oriented meaning |
|---|---|---|
| `STARTUP` | Quickly find the pipe’s capacity. | Use a high pacing/cwnd gain so the delivery-rate estimate rises quickly. |
| `DRAIN` | Remove queue created during startup. | Pace below estimated bandwidth until in-flight data is close to estimated BDP. |
| `PROBE_BW` | Keep the pipe full and periodically test for more bandwidth. | Cycle pacing gains around 1.0× bandwidth, usually `1.25`, `0.75`, then several `1.0` phases in Original BBR. |
| `PROBE_RTT` | Briefly drain the queue to refresh the propagation RTT estimate. | Cap in-flight data to a small minimum for a short period when the RTT filter expires. |

The key idea is that a sender cannot know the true bottleneck bandwidth or propagation RTT forever. It must keep refreshing its estimates. `PROBE_BW` refreshes bandwidth. `PROBE_RTT` refreshes minimum RTT.

---

## Original BBR as the baseline

Original BBR’s top-level model is:

```c
// Original BBR baseline, normalized from tcp_bbr1.c.
bw      = windowed_max(delivered / elapsed, 10 packet-timed rounds);
min_rtt = windowed_min(rtt_sample, 10 seconds);

pacing_rate = pacing_gain * bw;
cwnd        = max(cwnd_gain * bw * min_rtt, 4 packets);
```

Important baseline properties:

| Property | Original BBR baseline |
|---|---|
| Bandwidth estimate | Windowed maximum delivery rate over roughly 10 packet-timed rounds. |
| RTT estimate | Windowed minimum RTT over 10 seconds. |
| Startup gain | About `2.885×` for both pacing and startup cwnd behavior. |
| Steady cwnd gain | `2× BDP`. |
| Minimum cwnd target | `4 packets`. |
| Steady `PROBE_BW` cycle | 8 phases: `1.25`, `0.75`, then six `1.0` phases. |
| `PROBE_RTT` | Enabled. When min RTT expires on a continuously busy flow, cap in-flight to the minimum target for a short interval and one packet-timed round. |
| Loss behavior | BBR does not treat loss as the primary congestion signal, but it still uses loss recovery, packet conservation, and a long-term policer detector. |

A compact version of the Original BBR steady-state gain cycle is:

```c
// Original BBR-style normalized gain cycle.
probe_bw_gains = {
    1.25,  // probe upward
    0.75,  // drain excess queue
    1.00, 1.00, 1.00, 1.00, 1.00, 1.00
};
```

This baseline matters because most variants in this guide do **not** rewrite all of BBR. They usually change one or more of these levers:

1. which RTT statistic is used in BDP;
2. how aggressive the gains are;
3. whether `PROBE_RTT` exists;
4. whether packet loss or ECN directly changes the model;
5. whether loss is compensated for by intentionally pacing faster.

---

## Variant comparison against Original BBR

### Summary matrix

| Variant | Main difference from Original BBR | Main code levers | Expected direction of behavior |
|---|---|---|---|
| **BBRv3** | Adds explicit loss/ECN modeling and a redesigned 4-phase bandwidth-probing cycle. | `bw_lo`, `bw_hi`, `inflight_lo`, `inflight_hi`, ECN state, loss thresholds, `UP/DOWN/CRUISE/REFILL` cycle. | Safer than Original BBR under congestion signals; generally better coexistence and lower loss, but more complex. |
| **BBRx** | Keeps a BBRv1-like structure but greatly increases aggressiveness. | Higher startup gain, higher cwnd gain, 200-packet minimum cwnd, 600-second min-RTT window, +5% pacing formula. | Faster ramp and larger standing in-flight volume; higher risk of queue growth, loss, and unfairness. |
| **BBRW** | Uses approximate RTT p95 instead of min RTT for BDP, and removes `PROBE_RTT`. | `rtt_p95_step_us`, streaming p95 estimator, no `BBR_PROBE_RTT` mode. | Smoother throughput and no periodic ProbeRTT dip; likely larger cwnd and more tolerance of jitter, but higher queue/latency risk. |
| **BBR-Brutal** | Keeps BBR-style startup/drain and min-RTT ProbeRTT, but replaces steady probing with a 8-phase cycle and loss compensation. | `PROBE_UP`, `DRAIN`, `CRUISE`, `min_ack_percent`, `loss_guard_percent`, round-level loss tracking. | More throughput-seeking under moderate loss; potentially unfair or loss-amplifying on shared bottlenecks. |
| **BBRW-Brutal** | Combines BBRW’s RTT-p95/no-ProbeRTT design with Brutal-style loss compensation. | RTT p95, 8-phase cycle, sample-level loss guard, compensation capped by min ACK percentage. | Highest risk/reward custom variant: may keep throughput through jitter/loss, but can build large queues and compete aggressively. |

---

### BBRv3 vs Original BBR

BBRv3 is the biggest architectural change in this set. Original BBR primarily uses bandwidth and min RTT as its model, with loss mostly handled through recovery and policer logic. BBRv3 keeps the model-based philosophy but adds **explicit congestion-signal bounds**.

In BBRv3, the model has both high and low operating bounds:

- `bw_hi` / `inflight_hi`: longer-term upper estimates of what the path can support;
- `bw_lo` / `inflight_lo`: conservative short-term lower bounds when recent loss or ECN suggests the sender should reduce its footprint.

A simplified comparison:

```c
// Original BBR-like model.
bw  = max_bw_over_recent_rounds();
bdp = bw * min_rtt;
rate = pacing_gain * bw;
cwnd = cwnd_gain * bdp;

// BBRv3-like model.
bw_hi       = robust_upper_bandwidth_estimate();
inflight_hi = robust_upper_inflight_estimate();

if (loss_or_ecn_seen_when_not_probing()) {
    bw_lo       = conservative_bandwidth_bound();
    inflight_lo = conservative_inflight_bound();
}

bw   = min_or_sentinel_aware(bw_hi, bw_lo);
cwnd = bounded_by(inflight_lo, inflight_hi, bw * min_rtt * gain);
```

BBRv3 also changes the steady-state `PROBE_BW` cycle from Original BBR’s 8-phase pattern to a 4-phase pattern:

```c
// BBRv3-style normalized PROBE_BW phases.
probe_bw_gains = {
    UP:      1.25,
    DOWN:    0.91,
    CRUISE:  1.00,
    REFILL:  1.00
};
```

Other important BBRv3 differences:

- Startup pacing gain is around `2.77×`, lower than Original BBR’s `2.885×` high gain.
- Startup cwnd gain is `2×`, rather than using the same `2.885×` high gain as the startup pacing behavior.
- Loss and ECN can directly bound future sending behavior, instead of being mostly recovery-side signals.
- BBRv3 includes shallow-threshold ECN logic for environments where ECN marks are known to mean low-latency congestion signals.
- BBRv3’s release notes and IETF material describe it as BBRv2 plus bug fixes and performance tuning, with improved bandwidth/fairness convergence relative to BBRv2 and intended improvement over BBRv1 in coexistence, loss, and short-request latency.

**Likely implication:** BBRv3 is the upstream evolutionary path. It is less “purely model-only” than Original BBR because it explicitly incorporates loss and ECN into the control model. That should generally make it more conservative under real congestion and more defensible in mixed networks than custom aggressive variants.

---

### BBRx vs Original BBR

BBRx keeps the familiar BBRv1 mode structure:

```c
enum bbr_mode {
    BBR_STARTUP,
    BBR_DRAIN,
    BBR_PROBE_BW,
    BBR_PROBE_RTT,
};
```

But it changes several constants in a much more aggressive direction:

```c
// BBRx normalized constants.
min_rtt_window       = 600 seconds;  // Original BBR baseline: 10 seconds
probe_rtt_duration  = 100 ms;       // Original BBR baseline: 200 ms
startup_pacing_gain = 6.0;          // Original BBR baseline: about 2.885
steady_cwnd_gain    = 4.0;          // Original BBR baseline: 2.0
min_cwnd_target     = 200 packets;  // Original BBR baseline: 4 packets
full_bw_threshold   = 1.05;         // Original BBR baseline: 1.25
full_bw_rounds      = 10;           // Original BBR baseline: 3
pacing_multiplier   = 1.05;         // code uses 100 + margin
```

The most important practical differences are:

1. **Much larger minimum in-flight floor.** A 200-packet minimum cwnd is radically different from a 4-packet minimum. On a low-BDP path, 200 packets can already exceed the path’s comfortable queue capacity.
2. **Much faster startup attempt.** A `6×` startup gain can fill or overshoot the pipe quickly.
3. **Very long min-RTT memory.** A 600-second min-RTT filter means BBRx refreshes its base RTT far less often than Original BBR.
4. **Less effective ProbeRTT draining.** Even when BBRx enters `PROBE_RTT`, its minimum target is 200 packets, not 4. That means the mode may not drain queues enough to measure true propagation delay on many paths.
5. **Pacing margin direction changes.** Original BBR-style code paces slightly below estimated bandwidth by multiplying by `100 - margin`. BBRx multiplies by `100 + margin`, so its `5%` margin is an overpacing margin.

**Likely implication:** BBRx is a high-throughput/high-pressure variant. It may be attractive for controlled high-BDP environments where the sender is allowed to be aggressive, but it is risky for shared networks, shallow buffers, home routers, Wi-Fi, and fairness-sensitive use cases.

> **Documentation note:** Some comments in `tcp_bbrx.c` appear inherited from BBRv1 and mention a 10-second ProbeRTT cadence, 200 ms duration, and 4-packet cap. The constants in the uploaded code say 600 seconds, 100 ms, and 200 packets. When analyzing behavior, trust the constants.

---

### BBRW vs Original BBR

BBRW changes BBR’s delay component. Original BBR uses **minimum RTT** for BDP. BBRW uses an approximate **RTT p95** estimator.

Original BBR BDP:

```c
bdp = bw * min_rtt;
```

BBRW BDP:

```c
// In BBRW, the field named min_rtt_us stores the approximate p95 RTT.
rtt_p95 = streaming_percentile_estimator(rtt_sample, 95);
bdp     = bw * rtt_p95;
```

BBRW also intentionally removes `PROBE_RTT`. Its mode enum has only:

```c
enum bbr_mode {
    BBR_STARTUP,
    BBR_DRAIN,
    BBR_PROBE_BW,
};
```

This matters because Original BBR periodically reduces in-flight data to refresh the true low-queue RTT. BBRW avoids that periodic throughput dip. When the RTT percentile window expires, it renews the window from ACK samples instead of entering `PROBE_RTT`.

**Why use p95 RTT?** A p95 RTT can be interpreted as a “typical high-but-not-worst” RTT. This may be attractive when the path has jitter, delayed ACKs, wireless scheduling, or variable queuing, because a pure min RTT can be too small to keep enough data in flight during normal jittery operation.

**Tradeoff:** p95 RTT can include queuing delay. If the sender uses p95 RTT for BDP, then a queue-inflated RTT can become part of the sender’s target. This can preserve throughput but also normalize higher standing queues.

**Likely implication:** BBRW is smoother and less disruptive than Original BBR for long transfers because it does not dip into `PROBE_RTT`, but it may hold more data in flight and raise p95 latency, especially on already-buffered paths.

---

### BBR-Brutal vs Original BBR

BBR-Brutal keeps BBR-style `STARTUP` and `DRAIN`, uses min RTT, and restores BBRv1-style `PROBE_RTT`. The main change is steady-state `PROBE_BW`.

Original BBR steady cycle:

```c
probe_bw_gains = { 1.25, 0.75, 1, 1, 1, 1, 1, 1 };
```

BBR-Brutal steady cycle:

```c
probe_bw_gains = {
    PROBE_UP: 1.25,  // no Brutal compensation
    DRAIN:    0.75,  // until in-flight <= estimated BDP
    CRUISE:   1.00   // apply Brutal-style compensation
};
```

The distinctive part is **loss compensation** in `CRUISE`:

```c
// BBR-Brutal normalized logic.
can_compensate =
    mode == PROBE_BW &&
    phase == CRUISE &&
    !loss_guard &&
    !using_long_term_policer_bw &&
    !in_loss_recovery;

if (can_compensate) {
    ack_success_percent = max(100 - recent_loss_percent, min_ack_percent);
    effective_gain      = base_gain * 100 / ack_success_percent;
}
```

With the default `min_ack_percent = 80`, the maximum compensation multiplier is `1.25×`. For example:

| Observed loss | ACK success | Effective CRUISE gain |
|---:|---:|---:|
| 0% | 100% | `1.00×` |
| 5% | 95% | `~1.053×` |
| 10% | 90% | `~1.111×` |
| 20% | 80% | `1.25×` cap |

The `LOSS_GUARD` disables compensation when loss exceeds the configured guard threshold, defaulting to `20%`. In the uploaded BBR-Brutal implementation, loss is tracked over packet-timed rounds, with immediate guard activation on sufficiently lossy ACK samples.

**Likely implication:** BBR-Brutal intentionally tries to maintain goodput through moderate loss by pacing faster. That may help in a controlled network where loss is not a congestion signal, but it is dangerous if loss is caused by congestion or shared bottleneck pressure. It can increase packet drops and compete unfairly with standard congestion controls.

---

### BBRW-Brutal vs Original BBR

BBRW-Brutal combines the two custom ideas:

1. BBRW’s approximate RTT p95 BDP model and no `PROBE_RTT`.
2. Brutal-style eight-phase steady probing and loss compensation.

Its steady cycle is:

```c
probe_bw_gains = {
    PROBE_UP: 1.25,
    DRAIN:    0.75,
    CRUISE:   1.00  // plus compensation when allowed
};
```

Its BDP calculation is:

```c
rtt_p95 = approximate_windowed_percentile(rtt, 95, 10 seconds);
bdp     = bw * rtt_p95;
```

Its compensation logic is sample-based:

```c
// BBRW-Brutal normalized logic.
loss_guard = losses * 100 > (acked + losses) * guard_percent;

if (mode == PROBE_BW && phase == CRUISE && !loss_guard) {
    ack_rate = max(acked * 100 / (acked + losses), min_ack_percent);
    gain     = base_gain * 100 / ack_rate;
}
```

A subtle difference from BBR-Brutal is the timing of the first steady-state phase:

- BBR-Brutal enters steady state by starting in `PROBE_UP`.
- BBRW-Brutal enters steady state in `CRUISE`, then cycles through `PROBE_UP -> DRAIN -> CRUISE`.

**Likely implication:** BBRW-Brutal can be more aggressive than either BBRW or BBR-Brutal alone. RTT p95 can raise the cwnd target, no `PROBE_RTT` avoids periodic draining, and Brutal compensation can increase pacing under moderate loss. This is a high-risk experimental design for shared networks.

---

## Scenario behavior table

The following table is qualitative. “More aggressive” means relative to Original BBR and generally implies higher throughput-seeking behavior, larger queues, higher loss tolerance, or weaker yielding. Actual results depend on bottleneck bandwidth, RTT, buffer size, AQM, ECN, receiver behavior, offload settings, and competing traffic.

| Scenario | Original BBR | BBRv3 | BBRx | BBRW | BBR-Brutal | BBRW-Brutal |
|---|---|---|---|---|---|---|
| **Single clean bulk flow, deep buffer** | High utilization after STARTUP/DRAIN; periodic `PROBE_RTT` may briefly dip throughput. | Similar high utilization; lower startup pressure and explicit bounds may reduce loss/queue spikes. | Likely fastest ramp; may create larger queue due high startup/cwnd gains and +5% pacing. | High utilization with no `PROBE_RTT` dip; cwnd may be larger if p95 RTT > min RTT. | High utilization; 3-phase cycle may be smoother than 8 phases but compensation is mostly inactive if no loss. | High utilization; no ProbeRTT dip; likely larger in-flight target if RTT p95 is elevated. |
| **Startup on a newly opened flow** | Rapid exponential-like ramp using ~2.885 gain. Can overshoot and then drain. | Lower startup pacing/cwnd tuning than Original BBR; designed to reduce startup loss and queue. | Very aggressive `6×` startup gain; likely overshoots fastest. | Similar to Original BBR startup constants, but later BDP uses p95 RTT. | Similar to Original BBR startup/drain constants. | Similar to Original BBR startup/drain constants, then starts steady state in CRUISE. |
| **Shallow buffer with loss** | Does not primarily use loss to set model; can cause drops while probing. | More likely to reduce sending bounds after loss/ECN; should be safer. | High risk: large min cwnd and gains can overwhelm shallow buffers. | p95 RTT may rise from queueing; cwnd may increase rather than drain. | Moderate loss can trigger compensation, increasing pacing until guard threshold; risky. | p95 RTT plus compensation can amplify in-flight pressure; highest risk. |
| **Random non-congestion loss, e.g. some wireless loss** | May keep bandwidth model if delivery rate remains high; packet recovery still costs latency. | Loss bounds may reduce sending even when loss is not congestion, depending signal pattern. | May push through random loss, but at high retransmission cost. | p95 RTT can absorb jitter; no ProbeRTT dip. Loss behavior mostly Original-like. | Designed to compensate for moderate loss; may preserve goodput if loss is random. | Most loss-tolerant in spirit; may preserve goodput but raise retransmits and queues. |
| **Persistent queue / bufferbloat** | `PROBE_RTT` periodically tries to measure low-queue RTT. | `PROBE_RTT` remains, and loss/ECN bounds add congestion response. | Very long min-RTT window and 200-packet floor make queue draining unlikely. | No `PROBE_RTT`; p95 RTT can include queueing, so persistent queues can become part of the target. | Has `PROBE_RTT`, but CRUISE compensation can work against queue reduction if loss appears below guard. | No `PROBE_RTT`; p95 + compensation can normalize and reinforce standing queues. |
| **Competing with Reno/CUBIC** | Known to have fairness concerns in some settings because it does not react to loss like CUBIC. | Intended to improve coexistence using loss/ECN and bounded probing. | Likely more aggressive than Original BBR; fairness risk. | May hold larger cwnd if p95 RTT rises; fairness risk under queueing. | Can be unfair under loss because it compensates instead of backing off below guard. | Highest fairness risk among custom variants. |
| **Competing with other BBR-like flows** | Gain cycling and `PROBE_RTT` help convergence but RTT unfairness can still occur. | Improved convergence machinery compared with older BBR versions. | Large floors/gains can dominate less aggressive BBR flows. | p95 RTT can favor flows seeing more queue/jitter, depending path. | May dominate standard BBR flows if loss occurs but remains under guard. | May dominate through both larger RTT-derived cwnd and compensation. |
| **Jittery RTT / delayed ACK / ACK compression** | Min RTT can be robust to spikes but may under-provision cwnd during normal jitter. ACK aggregation logic helps. | Similar BBR model plus extra mechanisms; still uses min RTT for base BDP. | Large cwnd floor masks under-provisioning but risks queueing. | Specifically more tolerant because it targets RTT p95. | Uses min RTT, but compensation is loss-based, not jitter-based. | Tolerant of jitter due p95 and tolerant of loss due compensation. |
| **App-limited or interactive traffic** | Can opportunistically refresh min RTT during idle/low-rate periods; avoids unnecessary ProbeRTT when idle restart applies. | Similar principle, with additional model bounds. | Large minimum cwnd may be irrelevant if app-limited, but dangerous on bursts. | No ProbeRTT dip; percentile window renews from ACK samples. | Similar idle restart behavior to Original BBR, with Brutal cycle only during sustained PROBE_BW. | No ProbeRTT; burst behavior may be larger if p95 target is high. |
| **Token-bucket policer** | Has long-term bandwidth sampling to estimate policer rate after consistent loss. | Has explicit congestion modeling and release-tuned behavior. | More aggressive policer parameters may misread or push policers differently. | Inherits Original-style policer logic. | Disables compensation when long-term policer bandwidth is active. | Also suppresses compensation when long-term policer bandwidth is active. |
| **Low-BDP path, LAN, or very small queue** | Minimum 4-packet cwnd and gain cycling are usually manageable. | Similar minimum but more explicit bounds. | 200-packet minimum can be far above BDP; high risk. | p95 may inflate target if queueing is present. | 4-packet minimum but loss compensation can still be too aggressive. | 4-packet minimum, but p95 and compensation increase risk. |
| **ECN / L4S-style shallow marking** | Original BBR generally does not have BBRv3’s ECN model. | Explicit ECN logic when enabled/configured for low-latency ECN environments. | No comparable BBRv3 ECN model in the uploaded code. | No comparable BBRv3 ECN model in the uploaded code. | No comparable BBRv3 ECN model; loss guard only. | No comparable BBRv3 ECN model; loss guard only. |

---

## Likely implications of the changes

### 1. BBRv3 is the most production-oriented evolution

BBRv3 keeps the spirit of BBR but adds the machinery needed for better behavior in real shared networks: explicit loss/ECN response, upper/lower model bounds, more nuanced bandwidth probing, and tuned startup. It is the most defensible choice when the goal is to improve Original BBR while remaining aligned with upstream research and deployment direction.

### 2. BBRx is not just “BBR with small tweaks”

BBRx changes constants enough to change the character of the algorithm. A 200-packet minimum cwnd, `6×` startup gain, `4×` cwnd gain, very long min-RTT window, and +5% pacing all point toward a deliberately aggressive sender. It may look good in a narrow throughput test, but it can hide costs in queueing delay, retransmissions, and harm to competing flows.

### 3. BBRW trades low-queue purity for smoother throughput

Using RTT p95 makes the BDP estimate less sensitive to the lowest observed RTT and more representative of common high-delay operation. This can be helpful on jittery paths, but it can also treat queueing delay as part of the desired operating point. Removing `PROBE_RTT` avoids periodic throughput dips but reduces the algorithm’s opportunity to refresh the unloaded RTT.

### 4. Brutal-style compensation changes the meaning of loss

Original BBR does not primarily use loss as a congestion signal, but it also does not intentionally pace faster to compensate for loss. The Brutal variants do. That is a philosophical change: moderate loss becomes something to compensate through rather than something to avoid. This can help only when loss is truly unrelated to congestion or when the environment is controlled and intentionally configured for such behavior.

### 5. Combining p95 RTT with Brutal compensation compounds risk

BBRW-Brutal combines a larger delay component with loss compensation. That means both the window target and pacing response can move upward under conditions where a conservative congestion-control algorithm would usually try to avoid adding more queue. It is the most experimental and least fairness-friendly variant in this set.

### 6. The best variant depends on the goal

There is no universal “best BBR.” The answer depends on what the operator wants to optimize:

| Goal | Best first candidate | Why |
|---|---|---|
| General Internet safety | BBRv3 | Upstream-oriented, loss/ECN-aware, designed for coexistence improvements. |
| Educational baseline | Original BBR | Smallest model and easiest state machine to understand. |
| Controlled high-throughput experiment | BBRx or BBR-Brutal, carefully isolated | Aggressive enough to stress the path, but high risk outside isolation. |
| Jitter-tolerant throughput experiment | BBRW | p95 RTT may better match variable-delay paths. |
| Stress-testing loss compensation | BBR-Brutal | Isolates Brutal compensation while keeping min-RTT ProbeRTT. |
| Maximum experimental aggressiveness | BBRW-Brutal | Combines RTT p95 and loss compensation. Use only in controlled tests. |

---

## Supplementary guidance for readers and testers

### A code-reading map

When reading any BBR variant, look for these functions and constants first:

| What to inspect | Why it matters |
|---|---|
| `enum bbr_mode` | Tells you whether `PROBE_RTT` exists. |
| `bbr_update_bw()` | Tells you how delivery-rate samples enter the bandwidth model. |
| `bbr_update_min_rtt()` | Tells you whether the delay term is min RTT, p95 RTT, or something else. |
| `bbr_bdp()` / `bbr_inflight()` | Tells you how the cwnd/in-flight target is computed. |
| `bbr_pacing_gain[]` | Tells you the steady probing cycle. |
| `bbr_update_gains()` | Tells you which gains apply in each mode. |
| `bbr_set_pacing_rate()` | Tells you whether the variant paces below, at, or above estimated bandwidth. |
| `bbr_set_cwnd()` | Tells you whether cwnd snaps down, grows slowly, or has special caps. |
| Loss/ECN-specific functions | Tells you whether loss is a congestion signal, a compensation input, or mostly recovery-only. |

### Suggested test matrix

Before drawing conclusions, test at least these dimensions:

| Dimension | Example values |
|---|---|
| RTT | 1 ms, 20 ms, 80 ms, 200 ms |
| Bottleneck bandwidth | 10 Mbps, 100 Mbps, 1 Gbps |
| Buffer size | 0.25× BDP, 1× BDP, 10× BDP, 100× BDP |
| Loss | 0%, 0.1%, 1%, 5%, burst loss |
| AQM | FIFO, FQ-CoDel, CAKE, shallow ECN/L4S if available |
| Competing flows | same variant, CUBIC, Reno, BBRv3, mixed RTTs |
| Workload | long bulk flow, short web-like transfers, RPC bursts, app-limited video chunks |
| Direction | upload bottleneck, download bottleneck, bidirectional traffic |

### Metrics worth collecting

Throughput alone is not enough. Track:

- goodput and retransmission rate;
- RTT p50 / p95 / p99;
- queue occupancy or sojourn delay if available;
- loss and ECN CE marks;
- cwnd, pacing rate, pacing gain, cwnd gain;
- min RTT or p95 RTT estimate, depending variant;
- fairness between flows, ideally with Jain’s fairness index;
- application-level completion time for short transfers.

Useful Linux commands while testing:

```bash
# Current default congestion control
sysctl net.ipv4.tcp_congestion_control

# Available congestion controls
sysctl net.ipv4.tcp_available_congestion_control

# Per-flow TCP internals: pacing rate, cwnd, RTT, retrans, delivery rate
ss -tin

# Queueing discipline stats
tc -s qdisc show dev <iface>

# Kernel TCP counters, including retransmission and ECN-related counters
nstat -az | egrep 'Retrans|TCPECN|TCPLoss|TCPTimeout'
```

Jain’s fairness index for `n` flows with throughputs `x_i`:

```text
J = (sum(x_i)^2) / (n * sum(x_i^2))
```

`J = 1.0` means perfectly equal throughput. Lower values mean less fairness.

### Deployment cautions

- Use `fq`, FQ-CoDel, CAKE, or another pacing-aware queueing setup when evaluating BBR-like senders. Pacing quality strongly affects results.
- Do not evaluate only a single flow on an empty path. Many congestion-control failures appear only under competition.
- Do not interpret random-loss performance as shared-network safety. A sender that “pushes through loss” may be harmful when loss reflects congestion.
- Treat uploaded Brutal variants as controlled-test modules, not general-purpose congestion-control replacements.
- Be careful with BBRx on low-BDP paths. A 200-packet minimum cwnd can be larger than the path’s entire comfortable in-flight budget.

---

## Glossary

| Term | Meaning |
|---|---|
| ACK | Acknowledgment from receiver indicating delivered data. |
| ACK aggregation | ACKs arriving in bursts, which can make delivery appear burstier than actual sending. |
| AQM | Active Queue Management, e.g. FQ-CoDel or CAKE. It manages queues before they become excessive. |
| BDP | Bandwidth-delay product: estimated bandwidth × estimated RTT. |
| BtlBw | Bottleneck bandwidth, the limiting delivery rate on the path. |
| cwnd | Congestion window: sender-side limit on packets in flight. |
| ECN | Explicit Congestion Notification: marking packets instead of dropping them to signal congestion. |
| in-flight | Data sent but not yet acknowledged. |
| min RTT | Minimum observed RTT over a window; used as a proxy for propagation delay. |
| pacing | Sending packets at a controlled rate rather than in large bursts. |
| p95 RTT | 95th percentile RTT. In BBRW variants, it replaces min RTT as the BDP delay term. |
| policer | A network element that enforces a rate limit, often by dropping packets above a token-bucket rate. |
| PROBE_BW | BBR mode that cycles sending rates to test for more bandwidth and drain excess queue. |
| PROBE_RTT | BBR mode that briefly reduces in-flight data to refresh the low-queue RTT estimate. |
| RTT | Round-trip time. |

---

## Sources

Primary code sources:

- Original BBR reference used as baseline: `tcp_bbr1.c` from Google `bbr/v3` branch: <https://raw.githubusercontent.com/google/bbr/refs/heads/v3/net/ipv4/tcp_bbr1.c>
- BBRv3 upstream source: `tcp_bbr.c` from Google `bbr/v3` branch: <https://raw.githubusercontent.com/google/bbr/refs/heads/v3/net/ipv4/tcp_bbr.c>
- Uploaded variant: `tcp_bbrx.c`
- Uploaded variant: `tcp_bbrw(2).c`
- Uploaded variant: `tcp_bbr_brutal.c`
- Uploaded variant: `tcp_bbrw_brutal.c`

Background reading:

- Neal Cardwell, Yuchung Cheng, C. Stephen Gunn, Soheil Hassas Yeganeh, Van Jacobson, “BBR: Congestion-Based Congestion Control,” ACM Queue, 2016: <https://queue.acm.org/detail.cfm?id=3022184>
- BBRv3 IETF 117 slides, “BBRv3: Algorithm Bug Fixes and Public Internet Deployment”: <https://datatracker.ietf.org/meeting/117/materials/slides-117-ccwg-bbrv3-algorithm-bug-fixes-and-public-internet-deployment-00>
- Google BBR v3 README: <https://raw.githubusercontent.com/google/bbr/refs/heads/v3/README.md>

---

## One-paragraph takeaway

Original BBR is a clean model-based design: estimate bottleneck bandwidth and min RTT, then pace near BDP while periodically probing bandwidth and RTT. BBRv3 is the upstream safety-oriented evolution that adds explicit loss/ECN bounds and a more nuanced probing cycle. BBRx pushes BBRv1-style behavior much harder through high gains, high minimum cwnd, and overpacing. BBRW changes the RTT model from min RTT to p95 and removes ProbeRTT, trading lower periodic disruption for higher standing in-flight risk. BBR-Brutal and BBRW-Brutal add loss compensation, intentionally sending faster under moderate loss; this may help in controlled lossy environments but is risky for fairness, latency, and shared-network stability.
