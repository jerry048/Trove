#!/usr/bin/env bash
# netem_bench.sh
#
# Debian 13 TCP congestion-control benchmark using network namespaces,
# tc/netem, HTB shaping, tc-police ingress policing, and iperf3 JSON output.
#
# Run:
#   sudo bash ./netem_bench.sh
#
# Useful examples:
#   sudo ALGOS="cubic bbr reno" bash ./netem_bench.sh
#   sudo LATENCY_MODE=full LATENCY_SWEEP="1ms 50ms 100ms 200ms 300ms" bash ./netem_bench.sh
#   sudo ALGOS="cubic bbr reno" COMPETITOR_ALGOS="auto" SCENARIOS="flow_fairness combined_all" bash ./netem_bench.sh
#   sudo BASE_RATE=200mbit DROP_RATE=25mbit POLICE_RATE=40mbit ONEWAY_DELAY=25ms bash ./netem_bench.sh
#   sudo PARALLEL_WORKERS=auto bash ./netem_bench.sh
#   sudo LIGHTWEIGHT_PARALLEL=0 bash ./netem_bench.sh
#
# Output:
#   ./netem-results/<timestamp>/
#     report.md         generated aggregate analysis
#     manifest.json     machine-readable run metadata and output schema
#     run-meta.txt      legacy key=value metadata for easy shell inspection
#     data/
#       runs.csv                 one row per iperf3 flow/run
#       intervals.csv            one row per iperf3 interval
#       events.csv               merged event timeline for dynamic tests
#       rtt_samples.csv          parsed ping/RTT probe samples
#       metrics.csv              long-format aggregate metrics
#       failures.csv             failed or incomplete iperf3 rows
#       scenario-algo-summary.csv  convenience wide throughput/retransmit view
#       flow-fairness.csv          convenience wide Jain fairness view
#       bufferbloat-summary.csv    convenience wide idle-vs-loaded RTT view
#       bufferbloat-algo-summary.csv  convenience wide RTT-under-load view
#     raw/
#       iperf-json/*.json   raw iperf3 JSON
#       tcp-ss/*.sslog      sampled TCP socket state
#       tc/*.tc             qdisc/class/filter stats after each run
#       events/*.csv        per-case raw event logs
#       ping/*.ping         raw ping probes
#       stderr/*.stderr     iperf3 stderr
#       server-logs/*.log   iperf3 server logs
#
# Notes:
# - netem loss is probabilistic packet impairment.
# - policer loss is token-bucket overflow loss: packets above a configured
#   rate/burst are dropped immediately by a tc police action.
# - The impairment is placed in a router namespace, not directly on the TCP
#   sender, so the sender TCP stack is not artificially delayed by its own qdisc.

set -euo pipefail

C_NS="${C_NS:-cc_client}"
R_NS="${R_NS:-cc_router}"
S_NS="${S_NS:-cc_server}"

C_IF="${C_IF:-c0}"
R_C_IF="${R_C_IF:-rc0}"
S_IF="${S_IF:-s0}"
R_S_IF="${R_S_IF:-rs0}"

C_IP="${C_IP:-10.10.1.2}"
R_C_IP="${R_C_IP:-10.10.1.1}"
S_IP="${S_IP:-10.10.2.2}"
R_S_IP="${R_S_IP:-10.10.2.1}"

BASE_PORT="${BASE_PORT:-5201}"
SERVER_COUNT="${SERVER_COUNT:-16}"
# Rotate multi-flow/competition cases across a pool of iperf3 server ports.
# Raising SERVER_COUNT alone only starts more servers; PORT_ROTATION makes the
# benchmark actually use fresh port blocks instead of reusing BASE_PORT..N.
PORT_ROTATION="${PORT_ROTATION:-1}"              # 1/yes/true/on/rotate or 0/no/false/off/fixed
PORT_BLOCK_SIZE="${PORT_BLOCK_SIZE:-auto}"      # auto = required simultaneous flows for the case
PORT_ROTATION_NEXT_OFFSET=0

ALGOS="${ALGOS:-cubic bbr reno}"
# SCENARIOS can be driven directly or selected through TEST_GROUPS. If both are
# set, SCENARIOS wins. TEST_GROUPS is intentionally coarse so broad real-life
# runs can be selected without listing every individual scenario.
USER_SCENARIOS_SET=0
if [[ -n "${SCENARIOS+x}" ]]; then USER_SCENARIOS_SET=1; fi
TEST_GROUPS="${TEST_GROUPS:-}"
SCENARIOS="${SCENARIOS:-baseline latency_spike latency_reduction jitter_light jitter_heavy jitter_long_tail reorder_light reorder_heavy capacity_drop sustain_loss loss_bursts loss_spike policer_static policer_spike policer_adaptive_rate policer_adaptive_retrans ack_rate_limit ack_loss ack_delay_spike ack_bufferbloat flow_fairness flow_fairness_sustain_loss flow_fairness_loss_spike flow_fairness_latency_spike flow_fairness_capacity_drop flow_fairness_policer flow_fairness_ack_limit flow_fairness_jitter flow_fairness_reorder short_flow_repeated short_flow_under_load bufferbloat_upload bufferbloat_download bufferbloat_bidirectional profile_proxy_mobile_china}"
REPEATS="${REPEATS:-1}"

# Lightweight multiprocessing.  Full scenario-level parallelism would share and
# mutate the same router qdisc/policer state, so the parent process only splits
# low-noise, static scenarios across isolated namespace topologies.  Dynamic,
# competition, bufferbloat, and real-world profile tests remain sequential by
# default because they intentionally observe interactions over time.
LIGHTWEIGHT_PARALLEL="${LIGHTWEIGHT_PARALLEL:-1}"   # 1/yes/true/on enables parent orchestration
PARALLEL_WORKERS="${PARALLEL_WORKERS:-auto}"        # auto = half of detected CPU cores; 1 disables parallel mode
PARALLEL_LIGHTWEIGHT_SCENARIOS="${PARALLEL_LIGHTWEIGHT_SCENARIOS:-baseline latency_sweep sustain_loss jitter_light jitter_heavy jitter_long_tail reorder_light reorder_heavy ack_rate_limit ack_loss policer_static short_flow_repeated}"
PARALLEL_CHILD="${PARALLEL_CHILD:-0}"

BASE_RATE="${BASE_RATE:-100mbit}"
CONFIGURED_BASE_RATE="$BASE_RATE"
DROP_RATE="${DROP_RATE:-20mbit}"
ACK_RATE="${ACK_RATE:-1000mbit}"
CONFIGURED_ACK_RATE="$ACK_RATE"

# Optional rate sweep. Keep broad tests at 100 Mbit/s or 1 Gbit/s; use 10 Gbit/s
# only for selected stress scenarios because CPU, pacing, buffers, and qdisc
# implementation details become part of the result.
RATE_MODE="${RATE_MODE:-single}"              # single, sweep, or scenario
RATE_SWEEP="${RATE_SWEEP:-100mbit 1gbit}"
ENABLE_10G_STRESS="${ENABLE_10G_STRESS:-0}"
TEN_G_RATE="${TEN_G_RATE:-10gbit}"
TEN_G_SCENARIOS="${TEN_G_SCENARIOS:-baseline sustain_loss flow_fairness bufferbloat_upload bufferbloat_bidirectional policer_static policer_adaptive_retrans combined_all}"
RATE_LABEL_IN_SCENARIO="${RATE_LABEL_IN_SCENARIO:-auto}"

ONEWAY_DELAY="${ONEWAY_DELAY:-20ms}"       # approximate baseline RTT = 2 * this
HIGH_DELAY="${HIGH_DELAY:-200ms}"          # latency spike/high-latency phase per direction
LOW_DELAY="${LOW_DELAY:-1ms}"              # latency-reduction/recovery phase per direction

# One-way delay values used as the full matrix when LATENCY_MODE=full and as
# the default internal ladder for combined_all. LATENCY_SWEEP is the only
# supported external knob for this list.
LATENCY_SWEEP="${LATENCY_SWEEP:-1ms 15ms 50ms 150ms}"
LATENCY_SWEEP_DELAYS="$LATENCY_SWEEP"

# Latency execution policy.
#   smart  = scenario-specific latency lists based on prior results; default.
#   full   = run every normal scenario over LATENCY_SWEEP.
#   single = run each normal scenario once at LATENCY_SINGLE_DEFAULT.
# In smart mode, override any scenario with LATENCY_<SCENARIO>_SET, for example:
#   LATENCY_LOSS_BURSTS_SET="50ms 300ms"
LATENCY_MODE="${LATENCY_MODE:-smart}"
LATENCY_SINGLE_DEFAULT="${LATENCY_SINGLE_DEFAULT:-$ONEWAY_DELAY}"
LATENCY_SENSITIVE_SET="${LATENCY_SENSITIVE_SET:-$LATENCY_SWEEP}"
LATENCY_COMPETITION_SET="${LATENCY_COMPETITION_SET:-1ms 50ms 100ms}"
LATENCY_DYNAMIC_SET="${LATENCY_DYNAMIC_SET:-1ms 50ms 100ms}"

# Scenario-specific smart-mode defaults. These reduce runtime by skipping
# latency sweeps where prior results did not show meaningful behavior changes,
# while keeping sweeps where latency materially changed throughput/fairness.
LATENCY_BASELINE_SET="${LATENCY_BASELINE_SET:-$LATENCY_SENSITIVE_SET}"
LATENCY_SUSTAIN_LOSS_SET="${LATENCY_SUSTAIN_LOSS_SET:-$LATENCY_SENSITIVE_SET}"
LATENCY_LOSS_BURSTS_SET="${LATENCY_LOSS_BURSTS_SET:-$LATENCY_SINGLE_DEFAULT}"
LATENCY_LOSS_SPIKE_SET="${LATENCY_LOSS_SPIKE_SET:-$LATENCY_SENSITIVE_SET}"
LATENCY_LATENCY_SPIKE_SET="${LATENCY_LATENCY_SPIKE_SET:-$LATENCY_DYNAMIC_SET}"
LATENCY_LATENCY_REDUCTION_SET="${LATENCY_LATENCY_REDUCTION_SET:-$LATENCY_DYNAMIC_SET}"
LATENCY_CAPACITY_DROP_SET="${LATENCY_CAPACITY_DROP_SET:-$LATENCY_SINGLE_DEFAULT}"
LATENCY_FLOW_FAIRNESS_SET="${LATENCY_FLOW_FAIRNESS_SET:-$LATENCY_COMPETITION_SET}"
LATENCY_FLOW_FAIRNESS_IMPAIRMENT_SET="${LATENCY_FLOW_FAIRNESS_IMPAIRMENT_SET:-$LATENCY_COMPETITION_SET}"
LATENCY_POLICER_STATIC_SET="${LATENCY_POLICER_STATIC_SET:-$LATENCY_SINGLE_DEFAULT}"
LATENCY_POLICER_SPIKE_SET="${LATENCY_POLICER_SPIKE_SET:-$LATENCY_DYNAMIC_SET}"
LATENCY_POLICER_ADAPTIVE_SET="${LATENCY_POLICER_ADAPTIVE_SET:-$LATENCY_DYNAMIC_SET}"
LATENCY_BUFFERBLOAT_SET="${LATENCY_BUFFERBLOAT_SET:-$LATENCY_SINGLE_DEFAULT}"
LATENCY_ACK_PATH_SET="${LATENCY_ACK_PATH_SET:-$LATENCY_DYNAMIC_SET}"
LATENCY_JITTER_REORDER_SET="${LATENCY_JITTER_REORDER_SET:-$LATENCY_SINGLE_DEFAULT}"
LATENCY_SHORT_FLOW_SET="${LATENCY_SHORT_FLOW_SET:-1ms 50ms 100ms}"
LATENCY_PROFILE_SET="${LATENCY_PROFILE_SET:-$LATENCY_SINGLE_DEFAULT}"
COMBINED_LATENCY_LADDER="${COMBINED_LATENCY_LADDER:-$LATENCY_SWEEP}"

SUSTAINED_LOSS="${SUSTAINED_LOSS:-0.5%}"
# Sustained loss now mirrors benchmark.sh's model: independent random loss is
# applied on both router egress directions. SUSTAINED_LOSS remains the legacy
# one-knob default; LOSS_FWD/LOSS_REV are accepted as benchmark.sh-compatible
# aliases unless the SUSTAINED_LOSS_FWD/REV knobs are set explicitly.
SUSTAINED_LOSS_FWD="${SUSTAINED_LOSS_FWD:-${LOSS_FWD:-$SUSTAINED_LOSS}}"
SUSTAINED_LOSS_REV="${SUSTAINED_LOSS_REV:-${LOSS_REV:-$SUSTAINED_LOSS}}"
SUDDEN_LOSS="${SUDDEN_LOSS:-15%}"
# loss_bursts always schedules explicit burst-loss windows.
BURSTY_LOSS_SPEC="${BURSTY_LOSS_SPEC:-loss random 2% 75%}"
BURST_LOSS_RATE="${BURST_LOSS_RATE:-25%}"
BURST_ON_SECONDS="${BURST_ON_SECONDS:-2}"
BURST_OFF_SECONDS="${BURST_OFF_SECONDS:-5}"
BURST_COUNT="${BURST_COUNT:-3}"
BURST_START="${BURST_START:-${EVENT_AT:-15}}"

# Ingress policer. This creates packet loss by hard-dropping packets that exceed
# the token bucket. It is intentionally separate from netem's random/state loss.
POLICE_RATE="${POLICE_RATE:-30mbit}"
POLICE_BURST="${POLICE_BURST:-64kb}"
# Large enough for GSO/TSO-sized skb packets often seen on veth paths.
POLICE_MTU="${POLICE_MTU:-64kb}"
# Match only the client->server data direction by default.
POLICE_MATCH_DST="${POLICE_MATCH_DST:-${S_IP}/32}"

QUEUE_PACKETS="${QUEUE_PACKETS:-10000}"
# QUEUE_MODE=auto sizes netem queue limits from rate*RTT so high-RTT, high-rate
# tests are not accidentally capped by the qdisc queue rather than congestion control.
# Use QUEUE_MODE=static to retain exactly QUEUE_PACKETS.
QUEUE_MODE="${QUEUE_MODE:-auto}"
QUEUE_MTU_BYTES="${QUEUE_MTU_BYTES:-1514}"
QUEUE_BDP_MULTIPLIER="${QUEUE_BDP_MULTIPLIER:-2}"
QUEUE_MIN_PACKETS="${QUEUE_MIN_PACKETS:-$QUEUE_PACKETS}"
QUEUE_MAX_PACKETS="${QUEUE_MAX_PACKETS:-200000}"
QUEUE_ACK_PACKETS="${QUEUE_ACK_PACKETS:-auto}"
NETEM_SEED="${NETEM_SEED:-12345}"
ACK_SEED="${ACK_SEED:-54321}"

BASE_DURATION="${BASE_DURATION:-30}"
EVENT_DURATION="${EVENT_DURATION:-40}"
# Adaptive duration gives high-BDP tests more time to reach steady state without
# making short-RTT tests unnecessarily slow.
ADAPTIVE_DURATION="${ADAPTIVE_DURATION:-1}"
HIGH_LATENCY_THRESHOLD_MS="${HIGH_LATENCY_THRESHOLD_MS:-200}"
HIGH_LATENCY_BASE_DURATION="${HIGH_LATENCY_BASE_DURATION:-60}"
HIGH_LATENCY_EVENT_DURATION="${HIGH_LATENCY_EVENT_DURATION:-90}"
HIGH_LATENCY_COMPETITOR_DURATION="${HIGH_LATENCY_COMPETITOR_DURATION:-45}"
HIGH_LATENCY_OMIT="${HIGH_LATENCY_OMIT:-10}"
COMPETITOR_START="${COMPETITOR_START:-10}"
COMPETITOR_DURATION="${COMPETITOR_DURATION:-20}"
EVENT_RECOVERY_POST="${EVENT_RECOVERY_POST:-5}"
EVENT_AT="${EVENT_AT:-15}"
EVENT_HOLD="${EVENT_HOLD:-10}"
RUN_COOLDOWN="${RUN_COOLDOWN:-2}"
# Cooldown between high-interaction competition cases inside a single scenario/algo pass.
# The original RUN_COOLDOWN only runs after run_scenario() returns, which means
# high-flow fairness cases can otherwise reuse the same iperf3 server ports immediately.
COMPETITION_COOLDOWN="${COMPETITION_COOLDOWN:-$RUN_COOLDOWN}"
# Fairness/competition scenarios run every selected congestion-control
# algorithm together against one shared 10 Gbit/s receiver by default.
COMPETITION_RECEIVER_RATE="${COMPETITION_RECEIVER_RATE:-10gbit}"
# 30 minutes per fairness/competition case.
COMPETITION_TEST_DURATION="${COMPETITION_TEST_DURATION:-1800}"
# Dynamic all-algorithm fairness impairments use the same case duration,
# with the impairment window defaulting to the middle third.
COMPETITION_EVENT_AT="${COMPETITION_EVENT_AT:-auto}"
COMPETITION_EVENT_HOLD="${COMPETITION_EVENT_HOLD:-auto}"
# Capacity-drop fairness cases start at COMPETITION_RECEIVER_RATE, drop to
# this rate during the impairment window, then restore the receiver rate.
COMPETITION_DROP_RATE="${COMPETITION_DROP_RATE:-$DROP_RATE}"
# One iperf3 flow per algorithm by default. Raise this only when you explicitly
# want multiple equal-weight flows per algorithm in the same shared competition.
COMPETITION_FLOWS_PER_ALGO="${COMPETITION_FLOWS_PER_ALGO:-5}"
POST_IMPAIRMENT_SETTLE="${POST_IMPAIRMENT_SETTLE:-1}"
# Legacy pairwise-flow knob retained for older wrappers; all-algorithm fairness
# scenarios now use COMPETITION_FLOWS_PER_ALGO instead.
MULTI_COMPETITOR_FLOWS="${MULTI_COMPETITOR_FLOWS:-3}"
OMIT="${OMIT:-3}"
SS_INTERVAL="${SS_INTERVAL:-1}"

# Final combined_all scenario. COMBINED_DURATION=0/auto means auto-size from the
# number of latency sweep points and COMBINED_PHASE_SECONDS.
COMBINED_PHASE_SECONDS="${COMBINED_PHASE_SECONDS:-6}"
COMBINED_DURATION="${COMBINED_DURATION:-0}"
COMBINED_COMPETITOR_FLOWS="${COMBINED_COMPETITOR_FLOWS:-}"
COMBINED_NETEM_LOSS_SPEC="${COMBINED_NETEM_LOSS_SPEC:-$BURSTY_LOSS_SPEC}"
# Include the extended scenarios inside combined_all in a controlled sequence.
# Disable with COMBINED_INCLUDE_EXTENDED_PHASES=0 for the shorter combined schedule.
COMBINED_INCLUDE_EXTENDED_PHASES="${COMBINED_INCLUDE_EXTENDED_PHASES:-1}"
COMBINED_ENABLE_RTT_PROBE="${COMBINED_ENABLE_RTT_PROBE:-1}"
COMBINED_JITTER_EXTRA="${COMBINED_JITTER_EXTRA:-25ms 50% distribution normal}"
COMBINED_LONG_TAIL_EXTRA="${COMBINED_LONG_TAIL_EXTRA:-80ms 75% distribution paretonormal}"
COMBINED_REORDER_EXTRA="${COMBINED_REORDER_EXTRA:-reorder 1% 25%}"
COMBINED_ACK_LIMIT_RATE="${COMBINED_ACK_LIMIT_RATE:-${ACK_LIMIT_RATE:-5mbit}}"
COMBINED_ACK_LOSS_RATE="${COMBINED_ACK_LOSS_RATE:-${ACK_LOSS_RATE:-1%}}"
COMBINED_ACK_DELAY="${COMBINED_ACK_DELAY:-${ACK_SPIKE_DELAY:-$HIGH_DELAY}}"
COMBINED_BUFFERBLOAT_QUEUE_PROFILE="${COMBINED_BUFFERBLOAT_QUEUE_PROFILE:-pfifo_deep}"
COMBINED_RECOVERY_QUEUE_PROFILE="${COMBINED_RECOVERY_QUEUE_PROFILE:-cake}"
COMBINED_ADAPTIVE_POLICER_MODE="${COMBINED_ADAPTIVE_POLICER_MODE:-retrans_feedback}"
COMBINED_ADAPTIVE_POLICER_PHASES="${COMBINED_ADAPTIVE_POLICER_PHASES:-3}"


# Queue / AQM profiles. "netem_fifo" preserves the original FIFO behavior.
# Bufferbloat defaults to a single unmanaged deep FIFO bottleneck. This answers:
#   "How much queue does each congestion-control algorithm build when the
#    bottleneck queue is bloated and does not run AQM/fair queueing?"
# Use fq/fq_codel/cake only for separate managed-queue/AQM comparisons.
QUEUE_PROFILE="${QUEUE_PROFILE:-netem_fifo}"         # netem_fifo, pfifo_deep, pfifo_bdp, fq, fq_codel, cake
ACTIVE_QUEUE_PROFILE="$QUEUE_PROFILE"
ACTIVE_ACK_QUEUE_PROFILE="${ACK_QUEUE_PROFILE:-$QUEUE_PROFILE}"
BUFFERBLOAT_QUEUE_PROFILE="${BUFFERBLOAT_QUEUE_PROFILE:-pfifo_deep}"
# Legacy knob is recorded for metadata compatibility only. To override the
# controlled queue for bufferbloat tests, set BUFFERBLOAT_QUEUE_PROFILE.
BUFFERBLOAT_QUEUE_PROFILES="${BUFFERBLOAT_QUEUE_PROFILES:-$BUFFERBLOAT_QUEUE_PROFILE}"
BUFFERBLOAT_DEEP_PACKETS="${BUFFERBLOAT_DEEP_PACKETS:-200000}"
PFIFO_BDP_MULTIPLIER="${PFIFO_BDP_MULTIPLIER:-1}"
FQ_LIMIT="${FQ_LIMIT:-10000}"
FQ_FLOW_LIMIT="${FQ_FLOW_LIMIT:-100}"
FQ_QUANTUM="${FQ_QUANTUM:-1514}"
FQ_INITIAL_QUANTUM="${FQ_INITIAL_QUANTUM:-15140}"
FQ_CODEL_LIMIT="${FQ_CODEL_LIMIT:-10000}"
FQ_CODEL_TARGET="${FQ_CODEL_TARGET:-5ms}"
FQ_CODEL_INTERVAL="${FQ_CODEL_INTERVAL:-100ms}"
FQ_CODEL_ECN="${FQ_CODEL_ECN:-1}"
CAKE_OVERHEAD_MODE="${CAKE_OVERHEAD_MODE:-besteffort flows nonat nowash no-ack-filter split-gso}"
CAKE_ECN_MODE="${CAKE_ECN_MODE:-}"

# Bufferbloat measurement. Each bufferbloat scenario records raw ping output,
# parsed ping-sample CSV, and direct qdisc backlog samples.
# The RTT probe uses an explicit ping count instead of a kill-after-sleep wrapper
# so idle, loaded, and recovery phases produce deterministic sample counts.
PING_INTERVAL="${PING_INTERVAL:-0.2}"
PING_SIZE="${PING_SIZE:-56}"
# Let ping wait beyond the send window so a deep FIFO can deliver late samples
# instead of truncating exactly the queueing delay this test is meant to reveal.
BB_PING_DEADLINE_EXTRA="${BB_PING_DEADLINE_EXTRA:-15}"
# A bufferbloat row is marked valid only if each phase collects at least this
# fraction of the expected ping replies. This catches broken probes or massive
# loss instead of silently reporting a misleading p95.
BB_SAMPLE_VALID_MIN_RATIO="${BB_SAMPLE_VALID_MIN_RATIO:-0.80}"
BB_IDLE_SECONDS="${BB_IDLE_SECONDS:-8}"
BB_LOAD_DURATION="${BB_LOAD_DURATION:-30}"
BB_RECOVERY_SECONDS="${BB_RECOVERY_SECONDS:-8}"
BB_DIRECTION_SET="${BB_DIRECTION_SET:-upload download bidirectional}"
BUFFERBLOAT_REVERSE_RATE="${BUFFERBLOAT_REVERSE_RATE:-}"
BB_SAMPLE_QUEUE_STATS="${BB_SAMPLE_QUEUE_STATS:-1}"
BB_QUEUE_SAMPLE_INTERVAL="${BB_QUEUE_SAMPLE_INTERVAL:-0.5}"

# ACK-path impairments. These model asymmetric uplinks, ACK starvation, reverse
# queueing, and ACK loss independent of forward data-path loss.
ACK_LIMIT_RATE="${ACK_LIMIT_RATE:-5mbit}"
ACK_LOSS_RATE="${ACK_LOSS_RATE:-1%}"
ACK_SPIKE_DELAY="${ACK_SPIKE_DELAY:-$HIGH_DELAY}"
ACK_BUFFERBLOAT_RATE="${ACK_BUFFERBLOAT_RATE:-10mbit}"
ACK_BUFFERBLOAT_QUEUE_PROFILE="${ACK_BUFFERBLOAT_QUEUE_PROFILE:-pfifo_deep}"
ACTIVE_ACK_RATE="$ACK_RATE"
ACTIVE_ACK_DELAY=""
ACTIVE_ACK_LOSS="0%"
ACTIVE_DATA_DELAY_EXTRA=""
ACTIVE_ACK_DELAY_EXTRA=""

# Jitter/reorder profiles.
JITTER_LIGHT="${JITTER_LIGHT:-delay $ONEWAY_DELAY 5ms 25% distribution normal}"
JITTER_HEAVY="${JITTER_HEAVY:-delay $ONEWAY_DELAY 25ms 50% distribution normal}"
JITTER_LONG_TAIL="${JITTER_LONG_TAIL:-delay $ONEWAY_DELAY 80ms 75% distribution paretonormal}"
REORDER_LIGHT_SPEC="${REORDER_LIGHT_SPEC:-delay $ONEWAY_DELAY reorder 1% 25%}"
REORDER_HEAVY_SPEC="${REORDER_HEAVY_SPEC:-delay $ONEWAY_DELAY reorder 5% 50%}"

# Adaptive policer models.
ADAPTIVE_POLICER_INTERVAL="${ADAPTIVE_POLICER_INTERVAL:-1}"
ADAPTIVE_POLICER_ENABLE_RETRANS_PER_SEC="${ADAPTIVE_POLICER_ENABLE_RETRANS_PER_SEC:-500}"
ADAPTIVE_POLICER_DISABLE_RETRANS_PER_SEC="${ADAPTIVE_POLICER_DISABLE_RETRANS_PER_SEC:-50}"
ADAPTIVE_POLICER_ENABLE_SAMPLES="${ADAPTIVE_POLICER_ENABLE_SAMPLES:-3}"
ADAPTIVE_POLICER_DISABLE_SAMPLES="${ADAPTIVE_POLICER_DISABLE_SAMPLES:-5}"
ADAPTIVE_POLICER_MIN_HOLD="${ADAPTIVE_POLICER_MIN_HOLD:-5}"
ADAPTIVE_POLICER_COOLDOWN="${ADAPTIVE_POLICER_COOLDOWN:-5}"
ADAPTIVE_POLICER_ENABLE_MBPS="${ADAPTIVE_POLICER_ENABLE_MBPS:-auto}"
ADAPTIVE_POLICER_DISABLE_MBPS="${ADAPTIVE_POLICER_DISABLE_MBPS:-auto}"
ADAPTIVE_POLICER_TRIGGER_LOSS="${ADAPTIVE_POLICER_TRIGGER_LOSS:-$SUDDEN_LOSS}"
ADAPTIVE_POLICER_TRIGGER_AT="${ADAPTIVE_POLICER_TRIGGER_AT:-$EVENT_AT}"
ADAPTIVE_POLICER_TRIGGER_HOLD="${ADAPTIVE_POLICER_TRIGGER_HOLD:-$EVENT_HOLD}"
ADAPTIVE_POLICER_DURATION="${ADAPTIVE_POLICER_DURATION:-0}"   # 0 means use duration_for_event_delay

# Short-flow tests.
SHORT_FLOW_COUNT="${SHORT_FLOW_COUNT:-20}"
SHORT_FLOW_BYTES="${SHORT_FLOW_BYTES:-1M}"
SHORT_FLOW_GAP="${SHORT_FLOW_GAP:-0.2}"
SHORT_FLOW_LOAD_WARMUP="${SHORT_FLOW_LOAD_WARMUP:-3}"
SHORT_FLOW_UNDER_LOAD_DURATION="${SHORT_FLOW_UNDER_LOAD_DURATION:-$EVENT_DURATION}"

# Named real-world profile. This sets rates/delays/queues temporarily inside
# the profile-specific scenario, without changing the global default run.
# Proxy-to-China profiles: Mainland China user connects to a proxy/server
# outside Mainland China. Direction labels are from the China user's view:
#   client-bound = proxy/server -> China client (iperf3 -R download data path)
#   proxy-bound  = China client -> proxy/server (upload data path)
# The defaults are intentionally asymmetric and use worse impairment on the
# client-bound path, following the profile guidance in Pasted markdown(2).md.
PROXY_CHINA_PROFILE_SET="${PROXY_CHINA_PROFILE_SET:-mobile_typical mobile_poor lan_typical lan_poor}"
PROXY_CHINA_DIRECTION_SET="${PROXY_CHINA_DIRECTION_SET:-download upload}"
# Use "1 6 30" for the full proxy-specific concurrency matrix; default stays
# light enough for the broader benchmark suite.
PROXY_CHINA_PARALLEL_SET="${PROXY_CHINA_PARALLEL_SET:-1}"
PROXY_CHINA_PHASE_SECONDS="${PROXY_CHINA_PHASE_SECONDS:-${PROXY_MOBILE_PHASE_SECONDS:-8}}"
PROXY_CHINA_DURATION="${PROXY_CHINA_DURATION:-${PROXY_MOBILE_DURATION:-0}}"  # 0/auto = derive from phase schedule
PROXY_CHINA_QUEUE_PROFILE="${PROXY_CHINA_QUEUE_PROFILE:-netem_fifo}"
PROXY_CHINA_ENABLE_STALLS="${PROXY_CHINA_ENABLE_STALLS:-1}"
PROXY_CHINA_STALL_SECONDS="${PROXY_CHINA_STALL_SECONDS:-2}"
PROXY_CHINA_STALL_TARGET="${PROXY_CHINA_STALL_TARGET:-client_bound}"  # client_bound, proxy_bound, or both
PROXY_CHINA_ENABLE_PROFILE_SWING="${PROXY_CHINA_ENABLE_PROFILE_SWING:-1}"

# Profile defaults. "DOWN" means client-bound/proxy->China-client; "UP" means
# proxy-bound/China-client->proxy. Each profile also supplies netem delay
# jitter/correlation, loss correlation, optional slotting, and queue limit.
PROXY_CHINA_MOBILE_TYPICAL_DOWN_RATE="${PROXY_CHINA_MOBILE_TYPICAL_DOWN_RATE:-15mbit}"
PROXY_CHINA_MOBILE_TYPICAL_UP_RATE="${PROXY_CHINA_MOBILE_TYPICAL_UP_RATE:-5mbit}"
PROXY_CHINA_MOBILE_TYPICAL_DOWN_DELAY="${PROXY_CHINA_MOBILE_TYPICAL_DOWN_DELAY:-85ms}"
PROXY_CHINA_MOBILE_TYPICAL_UP_DELAY="${PROXY_CHINA_MOBILE_TYPICAL_UP_DELAY:-60ms}"
PROXY_CHINA_MOBILE_TYPICAL_DOWN_JITTER="${PROXY_CHINA_MOBILE_TYPICAL_DOWN_JITTER:-35ms}"
PROXY_CHINA_MOBILE_TYPICAL_UP_JITTER="${PROXY_CHINA_MOBILE_TYPICAL_UP_JITTER:-20ms}"
PROXY_CHINA_MOBILE_TYPICAL_DOWN_LOSS="${PROXY_CHINA_MOBILE_TYPICAL_DOWN_LOSS:-0.8%}"
PROXY_CHINA_MOBILE_TYPICAL_UP_LOSS="${PROXY_CHINA_MOBILE_TYPICAL_UP_LOSS:-0.3%}"
PROXY_CHINA_MOBILE_TYPICAL_DIST="${PROXY_CHINA_MOBILE_TYPICAL_DIST:-paretonormal}"
PROXY_CHINA_MOBILE_TYPICAL_JITTER_CORR="${PROXY_CHINA_MOBILE_TYPICAL_JITTER_CORR:-60%}"
PROXY_CHINA_MOBILE_TYPICAL_LOSS_CORR="${PROXY_CHINA_MOBILE_TYPICAL_LOSS_CORR:-40%}"
PROXY_CHINA_MOBILE_TYPICAL_LIMIT="${PROXY_CHINA_MOBILE_TYPICAL_LIMIT:-1500}"
PROXY_CHINA_MOBILE_TYPICAL_SLOT_ARGS="${PROXY_CHINA_MOBILE_TYPICAL_SLOT_ARGS:-slot distribution normal 8ms 4ms packets 64}"

PROXY_CHINA_MOBILE_POOR_DOWN_RATE="${PROXY_CHINA_MOBILE_POOR_DOWN_RATE:-3mbit}"
PROXY_CHINA_MOBILE_POOR_UP_RATE="${PROXY_CHINA_MOBILE_POOR_UP_RATE:-1mbit}"
PROXY_CHINA_MOBILE_POOR_DOWN_DELAY="${PROXY_CHINA_MOBILE_POOR_DOWN_DELAY:-160ms}"
PROXY_CHINA_MOBILE_POOR_UP_DELAY="${PROXY_CHINA_MOBILE_POOR_UP_DELAY:-120ms}"
PROXY_CHINA_MOBILE_POOR_DOWN_JITTER="${PROXY_CHINA_MOBILE_POOR_DOWN_JITTER:-80ms}"
PROXY_CHINA_MOBILE_POOR_UP_JITTER="${PROXY_CHINA_MOBILE_POOR_UP_JITTER:-50ms}"
PROXY_CHINA_MOBILE_POOR_DOWN_LOSS="${PROXY_CHINA_MOBILE_POOR_DOWN_LOSS:-3.0%}"
PROXY_CHINA_MOBILE_POOR_UP_LOSS="${PROXY_CHINA_MOBILE_POOR_UP_LOSS:-1.0%}"
PROXY_CHINA_MOBILE_POOR_DIST="${PROXY_CHINA_MOBILE_POOR_DIST:-paretonormal}"
PROXY_CHINA_MOBILE_POOR_JITTER_CORR="${PROXY_CHINA_MOBILE_POOR_JITTER_CORR:-75%}"
PROXY_CHINA_MOBILE_POOR_LOSS_CORR="${PROXY_CHINA_MOBILE_POOR_LOSS_CORR:-70%}"
PROXY_CHINA_MOBILE_POOR_LIMIT="${PROXY_CHINA_MOBILE_POOR_LIMIT:-1000}"
PROXY_CHINA_MOBILE_POOR_SLOT_ARGS="${PROXY_CHINA_MOBILE_POOR_SLOT_ARGS:-slot distribution normal 12ms 8ms packets 32}"

PROXY_CHINA_LAN_TYPICAL_DOWN_RATE="${PROXY_CHINA_LAN_TYPICAL_DOWN_RATE:-100mbit}"
PROXY_CHINA_LAN_TYPICAL_UP_RATE="${PROXY_CHINA_LAN_TYPICAL_UP_RATE:-40mbit}"
PROXY_CHINA_LAN_TYPICAL_DOWN_DELAY="${PROXY_CHINA_LAN_TYPICAL_DOWN_DELAY:-60ms}"
PROXY_CHINA_LAN_TYPICAL_UP_DELAY="${PROXY_CHINA_LAN_TYPICAL_UP_DELAY:-45ms}"
PROXY_CHINA_LAN_TYPICAL_DOWN_JITTER="${PROXY_CHINA_LAN_TYPICAL_DOWN_JITTER:-10ms}"
PROXY_CHINA_LAN_TYPICAL_UP_JITTER="${PROXY_CHINA_LAN_TYPICAL_UP_JITTER:-8ms}"
PROXY_CHINA_LAN_TYPICAL_DOWN_LOSS="${PROXY_CHINA_LAN_TYPICAL_DOWN_LOSS:-0.10%}"
PROXY_CHINA_LAN_TYPICAL_UP_LOSS="${PROXY_CHINA_LAN_TYPICAL_UP_LOSS:-0.05%}"
PROXY_CHINA_LAN_TYPICAL_DIST="${PROXY_CHINA_LAN_TYPICAL_DIST:-normal}"
PROXY_CHINA_LAN_TYPICAL_JITTER_CORR="${PROXY_CHINA_LAN_TYPICAL_JITTER_CORR:-40%}"
PROXY_CHINA_LAN_TYPICAL_LOSS_CORR="${PROXY_CHINA_LAN_TYPICAL_LOSS_CORR:-25%}"
PROXY_CHINA_LAN_TYPICAL_LIMIT="${PROXY_CHINA_LAN_TYPICAL_LIMIT:-3000}"
PROXY_CHINA_LAN_TYPICAL_SLOT_ARGS="${PROXY_CHINA_LAN_TYPICAL_SLOT_ARGS:-}"

PROXY_CHINA_LAN_POOR_DOWN_RATE="${PROXY_CHINA_LAN_POOR_DOWN_RATE:-15mbit}"
PROXY_CHINA_LAN_POOR_UP_RATE="${PROXY_CHINA_LAN_POOR_UP_RATE:-8mbit}"
PROXY_CHINA_LAN_POOR_DOWN_DELAY="${PROXY_CHINA_LAN_POOR_DOWN_DELAY:-130ms}"
PROXY_CHINA_LAN_POOR_UP_DELAY="${PROXY_CHINA_LAN_POOR_UP_DELAY:-100ms}"
PROXY_CHINA_LAN_POOR_DOWN_JITTER="${PROXY_CHINA_LAN_POOR_DOWN_JITTER:-45ms}"
PROXY_CHINA_LAN_POOR_UP_JITTER="${PROXY_CHINA_LAN_POOR_UP_JITTER:-30ms}"
PROXY_CHINA_LAN_POOR_DOWN_LOSS="${PROXY_CHINA_LAN_POOR_DOWN_LOSS:-1.2%}"
PROXY_CHINA_LAN_POOR_UP_LOSS="${PROXY_CHINA_LAN_POOR_UP_LOSS:-0.5%}"
PROXY_CHINA_LAN_POOR_DIST="${PROXY_CHINA_LAN_POOR_DIST:-paretonormal}"
PROXY_CHINA_LAN_POOR_JITTER_CORR="${PROXY_CHINA_LAN_POOR_JITTER_CORR:-65%}"
PROXY_CHINA_LAN_POOR_LOSS_CORR="${PROXY_CHINA_LAN_POOR_LOSS_CORR:-60%}"
PROXY_CHINA_LAN_POOR_LIMIT="${PROXY_CHINA_LAN_POOR_LIMIT:-2000}"
PROXY_CHINA_LAN_POOR_SLOT_ARGS="${PROXY_CHINA_LAN_POOR_SLOT_ARGS:-}"

# Legacy names kept only for older wrappers and outer rate/latency labels. The
# new profile function uses the PROXY_CHINA_* knobs above.
PROXY_BACKHAUL_RATE="${PROXY_BACKHAUL_RATE:-$PROXY_CHINA_LAN_TYPICAL_DOWN_RATE}"
PROXY_MOBILE_BASE_DELAY="${PROXY_MOBILE_BASE_DELAY:-$PROXY_CHINA_MOBILE_TYPICAL_DOWN_DELAY}"

# Competition matrix controls.
# COMPETITOR_ALGOS=auto means: for every primary algorithm in ALGOS, run
# competitors using every selected algorithm too. This includes same-algo
# competition, e.g. cubic-vs-cubic, and cross-algo competition, e.g. cubic-vs-bbr.
COMPETITOR_ALGOS="${COMPETITOR_ALGOS:-auto}"

# HTB's default quantum is rate / r2q, with default r2q=10. At 100 Mbit/s and
# above that can trigger: "sch_htb: quantum of class 10001 is big. Consider r2q change."
# Use an explicit MTU-sized quantum by default; tune higher if CPU overhead matters.
HTB_R2Q="${HTB_R2Q:-1000}"
HTB_QUANTUM="${HTB_QUANTUM:-1514}"

IPERF_EXTRA="${IPERF_EXTRA:-}"             # e.g. IPERF_EXTRA="-Z"
IPERF_CONNECT_TIMEOUT_MS="${IPERF_CONNECT_TIMEOUT_MS:-15000}"



RESULT_ROOT="${RESULT_ROOT:-./netem-results}"
RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
OUT_DIR="${OUT_DIR:-${RESULT_ROOT}/${RUN_ID}}"

SCHEMA_VERSION="${SCHEMA_VERSION:-3}"
DATA_DIR="${OUT_DIR}/data"
RAW_DIR="${OUT_DIR}/raw"
JSON_DIR="${RAW_DIR}/iperf-json"
SS_DIR="${RAW_DIR}/tcp-ss"
TC_DIR="${RAW_DIR}/tc"
EVENTS_RAW_DIR="${RAW_DIR}/events"
PINGS_RAW_DIR="${RAW_DIR}/ping"
QUEUE_RAW_DIR="${RAW_DIR}/queue"
STDERR_DIR="${RAW_DIR}/stderr"
SERVER_LOG_DIR="${RAW_DIR}/server-logs"

SUMMARY_CSV="${DATA_DIR}/runs.csv"
INTERVALS_CSV="${DATA_DIR}/intervals.csv"
EVENTS_CSV="${DATA_DIR}/events.csv"
PING_CSV="${DATA_DIR}/rtt_samples.csv"
QUEUE_CSV="${DATA_DIR}/queue_samples.csv"
METRICS_CSV="${DATA_DIR}/metrics.csv"
FAILURES_CSV="${DATA_DIR}/failures.csv"
META_FILE="${OUT_DIR}/run-meta.txt"
MANIFEST_JSON="${OUT_DIR}/manifest.json"
ANALYSIS_REPORT="${OUT_DIR}/report.md"
SCENARIO_ALGO_CSV="${DATA_DIR}/scenario-algo-summary.csv"
FLOW_FAIRNESS_CSV="${DATA_DIR}/flow-fairness.csv"
BUFFERBLOAT_CSV="${DATA_DIR}/bufferbloat-summary.csv"
BUFFERBLOAT_ALGO_CSV="${DATA_DIR}/bufferbloat-algo-summary.csv"
BUFFERBLOAT_QUEUE_CSV="${DATA_DIR}/bufferbloat-queue-summary.csv"

log() { printf '[%s] %s\n' "$(date -Is)" "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "Run as root: sudo bash $0"
}

require_cmds() {
  local missing=()
  for cmd in ip tc iperf3 python3 ss modprobe ping; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if ((${#missing[@]})); then
    die "Missing commands: ${missing[*]}. Install at least: apt install -y iproute2 iperf3 python3 kmod iputils-ping"
  fi
}

cleanup_namespaces() {
  for ns in "$C_NS" "$R_NS" "$S_NS"; do
    if ip netns list | awk '{print $1}' | grep -qx "$ns"; then
      ip netns pids "$ns" 2>/dev/null | xargs -r kill -TERM 2>/dev/null || true
      sleep 0.2
      ip netns pids "$ns" 2>/dev/null | xargs -r kill -KILL 2>/dev/null || true
      ip netns del "$ns" 2>/dev/null || true
    fi
  done
}

on_exit() { cleanup_namespaces; }
trap on_exit EXIT INT TERM

setup_dirs() {
  mkdir -p "$DATA_DIR" "$JSON_DIR" "$SS_DIR" "$TC_DIR" "$EVENTS_RAW_DIR" "$SERVER_LOG_DIR" "$STDERR_DIR" "$PINGS_RAW_DIR" "$QUEUE_RAW_DIR"
  printf 'schema_version,run_id,case_id,flow_id,trial_id,repeat_index,worker_id,timestamp_start,timestamp_end,scenario_family,scenario,variant,flow_group,role,algo,peer_algo,direction,parallel_streams,parallel,oneway_delay,oneway_delay_ms,rate,data_rate_mbps,ack_rate_mbps,netem_loss,loss_fwd_pct,loss_rev_pct,police_rate,policer_enabled,policer_rate_mbps,queue_profile_data,queue_profile_ack,repeat,requested_seconds,start_offset_seconds,actual_seconds,sender_mbps,receiver_mbps,utilization_pct,retransmits,bytes_sent,bytes_received,receiver_gbits,retrans_per_gbit,success,rc,failure_category,json_path,stderr_path,ss_path,tc_path,json_file,error\n' > "$SUMMARY_CSV"
  printf 'schema_version,run_id,case_id,flow_id,interval_index,timestamp,scenario_family,scenario,variant,flow_group,role,algo,peer_algo,direction,oneway_delay,oneway_delay_ms,rate,data_rate_mbps,netem_loss,police_rate,repeat,parallel_streams,parallel,start_offset_seconds,interval_start,interval_end,absolute_start,absolute_end,seconds,mbps,retransmits,omitted,json_path,json_file,phase_name,active_event_id\n' > "$INTERVALS_CSV"
  printf 'schema_version,run_id,case_id,event_id,timestamp,relative_s,scenario,phase_name,event_name,target,parameter,old_value,new_value,unit,rate,data_rate_mbps,oneway_delay,oneway_delay_ms,netem_loss,loss_fwd_pct,loss_rev_pct,police_rate,policer_rate_mbps,police_burst,metric_name,metric_value,extra,raw_event_file\n' > "$EVENTS_CSV"
  printf 'schema_version,run_id,case_id,probe_id,timestamp,relative_s,phase,scenario,variant,flow_group,role,algo,direction,queue_profile,oneway_delay,oneway_delay_ms,rate,data_rate_mbps,repeat,seq,icmp_time,rtt_ms,lost,raw_path,raw_file\n' > "$PING_CSV"
  printf 'schema_version,run_id,case_id,sample_id,timestamp,relative_s,phase,scenario,variant,flow_group,role,algo,direction,queue_profile,oneway_delay,oneway_delay_ms,rate,data_rate_mbps,repeat,sample_index,path,dev,qdisc_kind,handle,parent,backlog_bytes,backlog_packets,drops,requeues,overlimits,raw_line,raw_path,raw_file\n' > "$QUEUE_CSV"
  printf 'schema_version,run_id,case_id,metric_scope,metric_family,scenario_family,scenario,variant,flow_group,algo,peer_algo,role,direction,queue_profile,oneway_delay_ms,data_rate_mbps,statistic,metric_name,value,unit,sample_count,source_table\n' > "$METRICS_CSV"
  {
    echo "run_id=${RUN_ID}"
    echo "date=$(date -Is)"
    echo "kernel=$(uname -a)"
    echo "algos_requested=${ALGOS}"
    echo "scenarios=${SCENARIOS}"
    echo "repeats=${REPEATS}"
    echo "lightweight_parallel=${LIGHTWEIGHT_PARALLEL}"
    echo "parallel_workers=${PARALLEL_WORKERS}"
    echo "parallel_lightweight_scenarios=${PARALLEL_LIGHTWEIGHT_SCENARIOS}"
    echo "parallel_child=${PARALLEL_CHILD}"
    echo "base_rate=${BASE_RATE}"
    echo "configured_base_rate=${CONFIGURED_BASE_RATE}"
    echo "drop_rate=${DROP_RATE}"
    echo "ack_rate=${ACK_RATE}"
    echo "configured_ack_rate=${CONFIGURED_ACK_RATE}"
    echo "rate_mode=${RATE_MODE}"
    echo "rate_sweep=${RATE_SWEEP}"
    echo "enable_10g_stress=${ENABLE_10G_STRESS}"
    echo "ten_g_rate=${TEN_G_RATE}"
    echo "ten_g_scenarios=${TEN_G_SCENARIOS}"
    echo "oneway_delay=${ONEWAY_DELAY}"
    echo "high_delay=${HIGH_DELAY}"
    echo "low_delay=${LOW_DELAY}"
    echo "sustain_loss=${SUSTAINED_LOSS}"
    echo "sustain_loss_model=benchmark_forward_reverse_random_loss"
    echo "sustain_loss_fwd=$(sustain_loss_fwd)"
    echo "sustain_loss_rev=$(sustain_loss_rev)"
    echo "loss_spike=${SUDDEN_LOSS}"
    echo "loss_bursts_fallback_spec=${BURSTY_LOSS_SPEC}"
    echo "police_rate=${POLICE_RATE}"
    echo "police_burst=${POLICE_BURST}"
    echo "police_mtu=${POLICE_MTU}"
    echo "police_match_dst=${POLICE_MATCH_DST}"
    echo "queue_packets=${QUEUE_PACKETS}"
    echo "queue_mode=${QUEUE_MODE}"
    echo "queue_mtu_bytes=${QUEUE_MTU_BYTES}"
    echo "queue_bdp_multiplier=${QUEUE_BDP_MULTIPLIER}"
    echo "queue_min_packets=${QUEUE_MIN_PACKETS}"
    echo "queue_max_packets=${QUEUE_MAX_PACKETS}"
    echo "queue_ack_packets=${QUEUE_ACK_PACKETS}"
    echo "latency_sweep=${LATENCY_SWEEP}"
    echo "latency_mode=${LATENCY_MODE}"
    echo "latency_single_default=${LATENCY_SINGLE_DEFAULT}"
    echo "latency_sensitive_set=${LATENCY_SENSITIVE_SET}"
    echo "latency_competition_set=${LATENCY_COMPETITION_SET}"
    echo "latency_dynamic_set=${LATENCY_DYNAMIC_SET}"
    echo "latency_baseline_set=${LATENCY_BASELINE_SET}"
    echo "latency_sustain_loss_set=${LATENCY_SUSTAIN_LOSS_SET}"
    echo "latency_loss_bursts_set=${LATENCY_LOSS_BURSTS_SET}"
    echo "latency_loss_spike_set=${LATENCY_LOSS_SPIKE_SET}"
    echo "latency_latency_spike_set=${LATENCY_LATENCY_SPIKE_SET}"
    echo "latency_latency_reduction_set=${LATENCY_LATENCY_REDUCTION_SET}"
    echo "latency_capacity_drop_set=${LATENCY_CAPACITY_DROP_SET}"
    echo "latency_flow_fairness_set=${LATENCY_FLOW_FAIRNESS_SET}"
    echo "latency_policer_static_set=${LATENCY_POLICER_STATIC_SET}"
    echo "latency_policer_spike_set=${LATENCY_POLICER_SPIKE_SET}"
    echo "combined_latency_ladder=${COMBINED_LATENCY_LADDER}"
    echo "adaptive_duration=${ADAPTIVE_DURATION}"
    echo "high_latency_threshold_ms=${HIGH_LATENCY_THRESHOLD_MS}"
    echo "high_latency_base_duration=${HIGH_LATENCY_BASE_DURATION}"
    echo "high_latency_event_duration=${HIGH_LATENCY_EVENT_DURATION}"
    echo "high_latency_competitor_duration=${HIGH_LATENCY_COMPETITOR_DURATION}"
    echo "high_latency_omit=${HIGH_LATENCY_OMIT}"
    echo "event_recovery_post=${EVENT_RECOVERY_POST}"
    echo "run_cooldown=${RUN_COOLDOWN}"
    echo "competition_cooldown=${COMPETITION_COOLDOWN}"
    echo "competition_receiver_rate=${COMPETITION_RECEIVER_RATE}"
    echo "competition_test_duration=${COMPETITION_TEST_DURATION}"
    echo "competition_event_at=${COMPETITION_EVENT_AT}"
    echo "competition_event_hold=${COMPETITION_EVENT_HOLD}"
    echo "competition_drop_rate=${COMPETITION_DROP_RATE}"
    echo "competition_flows_per_algo=${COMPETITION_FLOWS_PER_ALGO}"
    echo "competition_execution_model=all_selected_algorithms_shared_receiver"
    echo "post_impairment_settle=${POST_IMPAIRMENT_SETTLE}"
    echo "competitor_algos=${COMPETITOR_ALGOS}"
    echo "multi_competitor_flows=${MULTI_COMPETITOR_FLOWS}"
    echo "combined_phase_seconds=${COMBINED_PHASE_SECONDS}"
    echo "combined_duration=${COMBINED_DURATION}"
    echo "combined_competitor_flows=${COMBINED_COMPETITOR_FLOWS}"
    echo "combined_netem_loss_spec=${COMBINED_NETEM_LOSS_SPEC}"
    echo "combined_include_extended_phases=${COMBINED_INCLUDE_EXTENDED_PHASES}"
    echo "combined_enable_rtt_probe=${COMBINED_ENABLE_RTT_PROBE}"
    echo "combined_jitter_extra=${COMBINED_JITTER_EXTRA}"
    echo "combined_long_tail_extra=${COMBINED_LONG_TAIL_EXTRA}"
    echo "combined_reorder_extra=${COMBINED_REORDER_EXTRA}"
    echo "combined_ack_limit_rate=${COMBINED_ACK_LIMIT_RATE}"
    echo "combined_ack_loss_rate=${COMBINED_ACK_LOSS_RATE}"
    echo "combined_ack_delay=${COMBINED_ACK_DELAY}"
    echo "combined_bufferbloat_queue_profile=${COMBINED_BUFFERBLOAT_QUEUE_PROFILE}"
    echo "combined_recovery_queue_profile=${COMBINED_RECOVERY_QUEUE_PROFILE}"
    echo "combined_adaptive_policer_mode=${COMBINED_ADAPTIVE_POLICER_MODE}"
    echo "combined_adaptive_policer_phases=${COMBINED_ADAPTIVE_POLICER_PHASES}"
    echo "htb_r2q=${HTB_R2Q}"
    echo "htb_quantum=${HTB_QUANTUM}"
    echo "omit=${OMIT}"
    echo "iperf_extra=${IPERF_EXTRA}"
    echo "iperf_connect_timeout_ms=${IPERF_CONNECT_TIMEOUT_MS}"
    echo "queue_profile=${QUEUE_PROFILE}"
    echo "bufferbloat_queue_profile=${BUFFERBLOAT_QUEUE_PROFILE}"
    echo "bufferbloat_queue_profiles_legacy=${BUFFERBLOAT_QUEUE_PROFILES}"
    echo "bufferbloat_deep_packets=${BUFFERBLOAT_DEEP_PACKETS}"
    echo "fq_limit=${FQ_LIMIT}"
    echo "fq_flow_limit=${FQ_FLOW_LIMIT}"
    echo "fq_quantum=${FQ_QUANTUM}"
    echo "fq_initial_quantum=${FQ_INITIAL_QUANTUM}"
    echo "ping_interval=${PING_INTERVAL}"
    echo "bb_ping_deadline_extra=${BB_PING_DEADLINE_EXTRA}"
    echo "bb_sample_valid_min_ratio=${BB_SAMPLE_VALID_MIN_RATIO}"
    echo "bb_idle_seconds=${BB_IDLE_SECONDS}"
    echo "bb_load_duration=${BB_LOAD_DURATION}"
    echo "bb_recovery_seconds=${BB_RECOVERY_SECONDS}"
    echo "bb_sample_queue_stats=${BB_SAMPLE_QUEUE_STATS}"
    echo "bb_queue_sample_interval=${BB_QUEUE_SAMPLE_INTERVAL}"
    echo "ack_limit_rate=${ACK_LIMIT_RATE}"
    echo "ack_loss_rate=${ACK_LOSS_RATE}"
    echo "ack_spike_delay=${ACK_SPIKE_DELAY}"
    echo "adaptive_policer_interval=${ADAPTIVE_POLICER_INTERVAL}"
    echo "adaptive_policer_enable_retrans_per_sec=${ADAPTIVE_POLICER_ENABLE_RETRANS_PER_SEC}"
    echo "adaptive_policer_disable_retrans_per_sec=${ADAPTIVE_POLICER_DISABLE_RETRANS_PER_SEC}"
    echo "adaptive_policer_enable_mbps=${ADAPTIVE_POLICER_ENABLE_MBPS}"
    echo "adaptive_policer_disable_mbps=${ADAPTIVE_POLICER_DISABLE_MBPS}"
    echo "short_flow_count=${SHORT_FLOW_COUNT}"
    echo "short_flow_bytes=${SHORT_FLOW_BYTES}"
    echo "short_flow_gap=${SHORT_FLOW_GAP}"
    echo "short_flow_load_warmup=${SHORT_FLOW_LOAD_WARMUP}"
    echo "short_flow_under_load_duration=${SHORT_FLOW_UNDER_LOAD_DURATION}"
    echo "proxy_china_profile_set=${PROXY_CHINA_PROFILE_SET}"
    echo "proxy_china_direction_set=${PROXY_CHINA_DIRECTION_SET}"
    echo "proxy_china_parallel_set=${PROXY_CHINA_PARALLEL_SET}"
    echo "proxy_china_phase_seconds=${PROXY_CHINA_PHASE_SECONDS}"
    echo "proxy_china_duration=${PROXY_CHINA_DURATION}"
    echo "proxy_china_queue_profile=${PROXY_CHINA_QUEUE_PROFILE}"
    echo "proxy_china_enable_stalls=${PROXY_CHINA_ENABLE_STALLS}"
    echo "proxy_china_stall_seconds=${PROXY_CHINA_STALL_SECONDS}"
    echo "proxy_china_stall_target=${PROXY_CHINA_STALL_TARGET}"
    echo "proxy_china_enable_profile_swing=${PROXY_CHINA_ENABLE_PROFILE_SWING}"
    echo "proxy_china_mobile_typical=down:${PROXY_CHINA_MOBILE_TYPICAL_DOWN_RATE},${PROXY_CHINA_MOBILE_TYPICAL_DOWN_DELAY},jitter:${PROXY_CHINA_MOBILE_TYPICAL_DOWN_JITTER},loss:${PROXY_CHINA_MOBILE_TYPICAL_DOWN_LOSS};up:${PROXY_CHINA_MOBILE_TYPICAL_UP_RATE},${PROXY_CHINA_MOBILE_TYPICAL_UP_DELAY},jitter:${PROXY_CHINA_MOBILE_TYPICAL_UP_JITTER},loss:${PROXY_CHINA_MOBILE_TYPICAL_UP_LOSS};dist:${PROXY_CHINA_MOBILE_TYPICAL_DIST};jitter_corr:${PROXY_CHINA_MOBILE_TYPICAL_JITTER_CORR};loss_corr:${PROXY_CHINA_MOBILE_TYPICAL_LOSS_CORR};slot:${PROXY_CHINA_MOBILE_TYPICAL_SLOT_ARGS}"
    echo "proxy_china_mobile_poor=down:${PROXY_CHINA_MOBILE_POOR_DOWN_RATE},${PROXY_CHINA_MOBILE_POOR_DOWN_DELAY},jitter:${PROXY_CHINA_MOBILE_POOR_DOWN_JITTER},loss:${PROXY_CHINA_MOBILE_POOR_DOWN_LOSS};up:${PROXY_CHINA_MOBILE_POOR_UP_RATE},${PROXY_CHINA_MOBILE_POOR_UP_DELAY},jitter:${PROXY_CHINA_MOBILE_POOR_UP_JITTER},loss:${PROXY_CHINA_MOBILE_POOR_UP_LOSS};dist:${PROXY_CHINA_MOBILE_POOR_DIST};jitter_corr:${PROXY_CHINA_MOBILE_POOR_JITTER_CORR};loss_corr:${PROXY_CHINA_MOBILE_POOR_LOSS_CORR};slot:${PROXY_CHINA_MOBILE_POOR_SLOT_ARGS}"
    echo "proxy_china_lan_typical=down:${PROXY_CHINA_LAN_TYPICAL_DOWN_RATE},${PROXY_CHINA_LAN_TYPICAL_DOWN_DELAY},jitter:${PROXY_CHINA_LAN_TYPICAL_DOWN_JITTER},loss:${PROXY_CHINA_LAN_TYPICAL_DOWN_LOSS};up:${PROXY_CHINA_LAN_TYPICAL_UP_RATE},${PROXY_CHINA_LAN_TYPICAL_UP_DELAY},jitter:${PROXY_CHINA_LAN_TYPICAL_UP_JITTER},loss:${PROXY_CHINA_LAN_TYPICAL_UP_LOSS};dist:${PROXY_CHINA_LAN_TYPICAL_DIST};jitter_corr:${PROXY_CHINA_LAN_TYPICAL_JITTER_CORR};loss_corr:${PROXY_CHINA_LAN_TYPICAL_LOSS_CORR};slot:${PROXY_CHINA_LAN_TYPICAL_SLOT_ARGS}"
    echo "proxy_china_lan_poor=down:${PROXY_CHINA_LAN_POOR_DOWN_RATE},${PROXY_CHINA_LAN_POOR_DOWN_DELAY},jitter:${PROXY_CHINA_LAN_POOR_DOWN_JITTER},loss:${PROXY_CHINA_LAN_POOR_DOWN_LOSS};up:${PROXY_CHINA_LAN_POOR_UP_RATE},${PROXY_CHINA_LAN_POOR_UP_DELAY},jitter:${PROXY_CHINA_LAN_POOR_UP_JITTER},loss:${PROXY_CHINA_LAN_POOR_UP_LOSS};dist:${PROXY_CHINA_LAN_POOR_DIST};jitter_corr:${PROXY_CHINA_LAN_POOR_JITTER_CORR};loss_corr:${PROXY_CHINA_LAN_POOR_LOSS_CORR};slot:${PROXY_CHINA_LAN_POOR_SLOT_ARGS}"
    echo "base_port=${BASE_PORT}"
    echo "server_count=${SERVER_COUNT}"
    echo "port_rotation=${PORT_ROTATION}"
    echo "port_block_size=${PORT_BLOCK_SIZE}"
    echo "available_congestion_control=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || true)"
    echo "schema_version=${SCHEMA_VERSION}"
    echo "data_dir=${DATA_DIR}"
    echo "raw_dir=${RAW_DIR}"
    echo "command_line=$(ps -o args= -p $$ 2>/dev/null | tail -n +2 || true)"
  } > "$META_FILE"

  python3 - "$META_FILE" "$MANIFEST_JSON" "$OUT_DIR" "$DATA_DIR" "$RAW_DIR" "$SCHEMA_VERSION" "$0" <<'PYMANIFEST'
import hashlib, json, os, sys
from datetime import datetime, timezone
meta_file, manifest_file, out_dir, data_dir, raw_dir, schema_version, script_path = sys.argv[1:]
config = {}
try:
    with open(meta_file, encoding='utf-8', errors='replace') as f:
        for line in f:
            line = line.rstrip('\n')
            if not line or '=' not in line:
                continue
            k, v = line.split('=', 1)
            config[k] = v
except FileNotFoundError:
    pass
script_sha256 = ''
try:
    with open(script_path, 'rb') as f:
        script_sha256 = hashlib.sha256(f.read()).hexdigest()
except Exception:
    pass
manifest = {
    'schema_version': str(schema_version),
    'run_id': config.get('run_id', ''),
    'created_at': config.get('date') or datetime.now(timezone.utc).isoformat(),
    'script': {'path': script_path, 'sha256': script_sha256},
    'output_layout': {
        'root': out_dir,
        'report': os.path.join(out_dir, 'report.md'),
        'manifest': manifest_file,
        'data_dir': data_dir,
        'raw_dir': raw_dir,
        'data_files': {
            'runs': os.path.join(data_dir, 'runs.csv'),
            'intervals': os.path.join(data_dir, 'intervals.csv'),
            'events': os.path.join(data_dir, 'events.csv'),
            'rtt_samples': os.path.join(data_dir, 'rtt_samples.csv'),
            'queue_samples': os.path.join(data_dir, 'queue_samples.csv'),
            'metrics': os.path.join(data_dir, 'metrics.csv'),
            'failures': os.path.join(data_dir, 'failures.csv'),
        },
        'raw_dirs': {
            'iperf_json': os.path.join(raw_dir, 'iperf-json'),
            'tcp_ss': os.path.join(raw_dir, 'tcp-ss'),
            'tc': os.path.join(raw_dir, 'tc'),
            'events': os.path.join(raw_dir, 'events'),
            'ping': os.path.join(raw_dir, 'ping'),
            'queue': os.path.join(raw_dir, 'queue'),
            'stderr': os.path.join(raw_dir, 'stderr'),
            'server_logs': os.path.join(raw_dir, 'server-logs'),
        },
    },
    'config': config,
}
with open(manifest_file, 'w', encoding='utf-8') as f:
    json.dump(manifest, f, indent=2, sort_keys=True)
    f.write('\n')
PYMANIFEST
}

setup_topology() {
  cleanup_namespaces

  log "Creating namespaces: $C_NS -> $R_NS -> $S_NS"
  ip netns add "$C_NS"
  ip netns add "$R_NS"
  ip netns add "$S_NS"

  ip link add "$C_IF" type veth peer name "$R_C_IF"
  ip link set "$C_IF" netns "$C_NS"
  ip link set "$R_C_IF" netns "$R_NS"

  ip link add "$S_IF" type veth peer name "$R_S_IF"
  ip link set "$S_IF" netns "$S_NS"
  ip link set "$R_S_IF" netns "$R_NS"

  ip -n "$C_NS" addr add "${C_IP}/24" dev "$C_IF"
  ip -n "$R_NS" addr add "${R_C_IP}/24" dev "$R_C_IF"
  ip -n "$S_NS" addr add "${S_IP}/24" dev "$S_IF"
  ip -n "$R_NS" addr add "${R_S_IP}/24" dev "$R_S_IF"

  for ns in "$C_NS" "$R_NS" "$S_NS"; do
    ip -n "$ns" link set lo up
  done
  ip -n "$C_NS" link set "$C_IF" up
  ip -n "$R_NS" link set "$R_C_IF" up
  ip -n "$S_NS" link set "$S_IF" up
  ip -n "$R_NS" link set "$R_S_IF" up

  ip -n "$C_NS" route add default via "$R_C_IP"
  ip -n "$S_NS" route add default via "$R_S_IP"
  ip netns exec "$R_NS" sysctl -qw net.ipv4.ip_forward=1

  # BBR benefits from fq pacing on the sender interface. Ignore if sch_fq is unavailable.
  ip netns exec "$C_NS" tc qdisc replace dev "$C_IF" root fq 2>/dev/null || true
  ip netns exec "$S_NS" tc qdisc replace dev "$S_IF" root fq 2>/dev/null || true

  # Avoid stale TCP route metrics from influencing sequential runs.
  ip netns exec "$C_NS" sysctl -qw net.ipv4.tcp_no_metrics_save=1 || true
  ip netns exec "$S_NS" sysctl -qw net.ipv4.tcp_no_metrics_save=1 || true

  ip netns exec "$C_NS" ping -c 1 -W 1 "$S_IP" >/dev/null || die "Topology ping failed"
}

load_congestion_modules() {
  modprobe sch_netem 2>/dev/null || true
  modprobe sch_htb 2>/dev/null || true
  modprobe sch_ingress 2>/dev/null || true
  modprobe cls_u32 2>/dev/null || true
  modprobe act_police 2>/dev/null || true
  modprobe sch_fq 2>/dev/null || true
  modprobe sch_fq_codel 2>/dev/null || true
  modprobe sch_cake 2>/dev/null || true
  modprobe sch_tbf 2>/dev/null || true

  local requested=() competitor_requested=()
  read -r -a requested <<< "$ALGOS"
  if [[ "$COMPETITOR_ALGOS" != "auto" ]]; then
    read -r -a competitor_requested <<< "$COMPETITOR_ALGOS"
  fi
  for algo in "${requested[@]}" "${competitor_requested[@]}"; do
    [[ -n "$algo" ]] || continue
    [[ "$algo" == "auto" ]] && continue
    modprobe "tcp_${algo}" 2>/dev/null || true
  done
}

available_algos() {
  cat /proc/sys/net/ipv4/tcp_available_congestion_control
}

select_algos() {
  local available selected=()
  available=" $(available_algos) "
  local requested=()
  read -r -a requested <<< "$ALGOS"
  for algo in "${requested[@]}"; do
    if [[ "$available" == *" ${algo} "* ]]; then
      selected+=("$algo")
    else
      log "Skipping unavailable congestion control: ${algo}. Available: ${available}"
    fi
  done
  ((${#selected[@]})) || die "None of the requested congestion controls are available. Available: ${available}"
  printf '%s\n' "${selected[@]}"
}

select_competitor_algos() {
  local available spec algo
  local -a candidates=() selected=()
  available=" $(available_algos) "
  spec="${COMPETITOR_ALGOS:-auto}"

  if [[ "$spec" == "auto" ]]; then
    candidates=("${SELECTED_ALGOS[@]}")
  else
    read -r -a candidates <<< "$spec"
  fi

  for algo in "${candidates[@]}"; do
    [[ -n "$algo" ]] || continue
    [[ "$algo" == "auto" ]] && continue
    if [[ "$available" != *" ${algo} "* ]]; then
      log "Skipping unavailable competitor congestion control: ${algo}. Available: ${available}"
      continue
    fi
    if [[ " ${selected[*]} " != *" ${algo} "* ]]; then
      selected+=("$algo")
    fi
  done

  if ((${#selected[@]} == 0)); then
    selected=("${SELECTED_ALGOS[@]}")
  fi
  printf '%s\n' "${selected[@]}"
}

start_servers() {
  log "Starting iperf3 servers in $S_NS"
  for ((i=0; i<SERVER_COUNT; i++)); do
    local port=$((BASE_PORT + i))
    ip netns exec "$S_NS" iperf3 -s -p "$port" -D --logfile "${SERVER_LOG_DIR}/iperf3-${port}.log"
  done
  sleep 0.5
}

loss_args_from_spec() {
  local spec="$1"
  if [[ -z "$spec" || "$spec" == "none" || "$spec" == "0" || "$spec" == "0%" ]]; then
    printf '%s\n' "loss random 0%"
  elif [[ "$spec" == loss* || "$spec" == reorder* || "$spec" == duplicate* || "$spec" == corrupt* || "$spec" == slot* || "$spec" == rate* || "$spec" == ecn* ]]; then
    printf '%s\n' "$spec"
  else
    printf '%s\n' "loss random $spec"
  fi
}


normalize_loss_value() {
  local v="$1"
  if [[ -z "$v" || "$v" == "none" || "$v" == "off" || "$v" == "0" || "$v" == "0%" ]]; then
    printf '%s\n' "0%"
  elif [[ "$v" =~ ^[0-9.]+$ ]]; then
    printf '%s%%\n' "$v"
  else
    printf '%s\n' "$v"
  fi
}

sustain_loss_fwd() {
  normalize_loss_value "${SUSTAINED_LOSS_FWD:-${LOSS_FWD:-${SUSTAINED_LOSS:-0.5%}}}"
}

sustain_loss_rev() {
  normalize_loss_value "${SUSTAINED_LOSS_REV:-${LOSS_REV:-${SUSTAINED_LOSS:-0.5%}}}"
}

sustain_loss_label() {
  printf 'fwd:%s;rev:%s\n' "$(sustain_loss_fwd)" "$(sustain_loss_rev)"
}

setup_sustain_loss_shapers() {
  local rate="$1" delay="$2" old_ack_loss
  old_ack_loss="${ACTIVE_ACK_LOSS:-0%}"
  ACTIVE_ACK_LOSS="$(sustain_loss_rev)"
  setup_shapers "$rate" "$delay" "$(sustain_loss_fwd)"
  ACTIVE_ACK_LOSS="$old_ack_loss"
}

change_sustain_loss_shapers() {
  local rate="$1" delay="$2" old_ack_loss
  old_ack_loss="${ACTIVE_ACK_LOSS:-0%}"
  ACTIVE_ACK_LOSS="$(sustain_loss_rev)"
  change_shapers "$rate" "$delay" "$(sustain_loss_fwd)"
  ACTIVE_ACK_LOSS="$old_ack_loss"
}


rate_to_mbps() {
  local rate="$1"
  awk -v r="$rate" 'BEGIN {
    v = r
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
    n = v + 0
    l = tolower(v)
    if (l ~ /gbit|gbps|g/)      printf "%.9f\n", n * 1000
    else if (l ~ /mbit|mbps|m/) printf "%.9f\n", n
    else if (l ~ /kbit|kbps|k/) printf "%.9f\n", n / 1000
    else if (l ~ /bit|bps/)     printf "%.9f\n", n / 1000000
    else                        printf "%.9f\n", n
  }'
}

delay_to_ms() {
  local delay="$1"
  awk -v d="$delay" 'BEGIN {
    v = d
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
    n = v + 0
    l = tolower(v)
    if (l ~ /us|usec/)      printf "%.9f\n", n / 1000
    else if (l ~ /ms|msec/) printf "%.9f\n", n
    else if (l ~ /s|sec/)   printf "%.9f\n", n * 1000
    else                    printf "%.9f\n", n
  }'
}

queue_limit_for() {
  local rate="$1"
  local delay="$2"
  if [[ "$QUEUE_MODE" == "static" || "$QUEUE_MODE" == "fixed" ]]; then
    printf '%s\n' "$QUEUE_PACKETS"
    return
  fi

  local mbps delay_ms
  mbps="$(rate_to_mbps "$rate")"
  delay_ms="$(delay_to_ms "$delay")"
  awk -v mbps="$mbps" -v delay_ms="$delay_ms" \
      -v mtu="$QUEUE_MTU_BYTES" -v mult="$QUEUE_BDP_MULTIPLIER" \
      -v minp="$QUEUE_MIN_PACKETS" -v maxp="$QUEUE_MAX_PACKETS" 'BEGIN {
    # rate in Mbit/s, RTT is two one-way delays. bytes = Mbps*1e6/8 * RTT_seconds.
    rtt_s = (2 * delay_ms) / 1000.0
    packets = int(((mbps * 1000000.0 / 8.0) * rtt_s / mtu) * mult + 0.999999)
    if (packets < minp) packets = minp
    if (maxp > 0 && packets > maxp) packets = maxp
    if (packets < 1) packets = 1
    printf "%d\n", packets
  }'
}

ack_queue_limit_for() {
  local delay="$1"
  local rate="${2:-${ACTIVE_ACK_RATE:-$ACK_RATE}}"
  if [[ "$QUEUE_ACK_PACKETS" != "auto" ]]; then
    printf '%s\n' "$QUEUE_ACK_PACKETS"
  else
    queue_limit_for "$rate" "$delay"
  fi
}

queue_limit_for_profile() {
  local profile="$1" rate="$2" delay="$3" default_limit="$4"
  case "$profile" in
    pfifo_deep|deep_fifo|bufferbloat)
      printf '%s\n' "$BUFFERBLOAT_DEEP_PACKETS"
      ;;
    pfifo_bdp|bdp_fifo)
      QUEUE_BDP_MULTIPLIER="$PFIFO_BDP_MULTIPLIER" queue_limit_for "$rate" "$delay"
      ;;
    *)
      printf '%s\n' "$default_limit"
      ;;
  esac
}

reset_ack_impairment() {
  ACTIVE_ACK_RATE="$ACK_RATE"
  ACTIVE_ACK_DELAY=""
  ACTIVE_ACK_LOSS="0%"
  ACTIVE_ACK_DELAY_EXTRA=""
  ACTIVE_ACK_QUEUE_PROFILE="$QUEUE_PROFILE"
}

set_ack_impairment() {
  ACTIVE_ACK_RATE="${1:-$ACK_RATE}"
  ACTIVE_ACK_DELAY="${2:-}"
  ACTIVE_ACK_LOSS="${3:-0%}"
  ACTIVE_ACK_QUEUE_PROFILE="${4:-$QUEUE_PROFILE}"
}

set_active_queue_profile() {
  ACTIVE_QUEUE_PROFILE="${1:-$QUEUE_PROFILE}"
}

reset_data_delay_extra() {
  ACTIVE_DATA_DELAY_EXTRA=""
}

set_data_delay_extra() {
  ACTIVE_DATA_DELAY_EXTRA="${1:-}"
}


latency_values_for_scenario() {
  local scenario="$1"
  case "$LATENCY_MODE" in
    full)
      printf '%s\n' "$LATENCY_SWEEP"
      return
      ;;
    single)
      printf '%s\n' "$LATENCY_SINGLE_DEFAULT"
      return
      ;;
    smart)
      ;;
    *)
      die "Unknown LATENCY_MODE=${LATENCY_MODE}. Use smart, full, or single."
      ;;
  esac

  case "$scenario" in
    baseline) printf '%s\n' "$LATENCY_BASELINE_SET" ;;
    sustain_loss) printf '%s\n' "$LATENCY_SUSTAIN_LOSS_SET" ;;
    loss_bursts) printf '%s\n' "$LATENCY_LOSS_BURSTS_SET" ;;
    loss_spike) printf '%s\n' "$LATENCY_LOSS_SPIKE_SET" ;;
    latency_spike) printf '%s\n' "$LATENCY_LATENCY_SPIKE_SET" ;;
    latency_reduction) printf '%s\n' "$LATENCY_LATENCY_REDUCTION_SET" ;;
    capacity_drop) printf '%s\n' "$LATENCY_CAPACITY_DROP_SET" ;;
    flow_fairness) printf '%s\n' "$LATENCY_FLOW_FAIRNESS_SET" ;;
    flow_fairness_sustain_loss|flow_fairness_loss_spike|flow_fairness_latency_spike|flow_fairness_capacity_drop|flow_fairness_policer|flow_fairness_ack_limit|flow_fairness_jitter|flow_fairness_reorder) printf '%s\n' "$LATENCY_FLOW_FAIRNESS_IMPAIRMENT_SET" ;;
    policer_static) printf '%s\n' "$LATENCY_POLICER_STATIC_SET" ;;
    policer_spike) printf '%s\n' "$LATENCY_POLICER_SPIKE_SET" ;;
    policer_adaptive_rate|policer_adaptive_retrans) printf '%s\n' "$LATENCY_POLICER_ADAPTIVE_SET" ;;
    bufferbloat_upload|bufferbloat_download|bufferbloat_bidirectional) printf '%s\n' "$LATENCY_BUFFERBLOAT_SET" ;;
    ack_rate_limit|ack_loss|ack_delay_spike|ack_bufferbloat) printf '%s\n' "$LATENCY_ACK_PATH_SET" ;;
    jitter_light|jitter_heavy|jitter_long_tail|reorder_light|reorder_heavy) printf '%s\n' "$LATENCY_JITTER_REORDER_SET" ;;
    short_flow_repeated|short_flow_under_load) printf '%s\n' "$LATENCY_SHORT_FLOW_SET" ;;
    profile_proxy_mobile_china) printf '%s\n' "$PROXY_CHINA_MOBILE_TYPICAL_DOWN_DELAY" ;;
    profile_*) printf '%s\n' "$LATENCY_PROFILE_SET" ;;
    *) printf '%s\n' "$LATENCY_SINGLE_DEFAULT" ;;
  esac
}

max_int() {
  local a="$1" b="$2"
  if (( a >= b )); then printf '%s\n' "$a"; else printf '%s\n' "$b"; fi
}

delay_is_high_latency() {
  local delay="$1" ms
  ms="$(delay_to_ms "$delay")"
  awk -v ms="$ms" -v threshold="$HIGH_LATENCY_THRESHOLD_MS" 'BEGIN { exit !(ms >= threshold) }'
}

duration_for_base_delay() {
  local delay="$1"
  if [[ "$ADAPTIVE_DURATION" == "1" || "$ADAPTIVE_DURATION" == "yes" || "$ADAPTIVE_DURATION" == "true" ]]; then
    if delay_is_high_latency "$delay"; then
      max_int "$BASE_DURATION" "$HIGH_LATENCY_BASE_DURATION"
      return
    fi
  fi
  printf '%s\n' "$BASE_DURATION"
}

duration_for_event_delay() {
  local delay="$1"
  if [[ "$ADAPTIVE_DURATION" == "1" || "$ADAPTIVE_DURATION" == "yes" || "$ADAPTIVE_DURATION" == "true" ]]; then
    if delay_is_high_latency "$delay"; then
      max_int "$EVENT_DURATION" "$HIGH_LATENCY_EVENT_DURATION"
      return
    fi
  fi
  printf '%s\n' "$EVENT_DURATION"
}


duration_for_competition_fairness() {
  if ! is_positive_integer "$COMPETITION_TEST_DURATION"; then
    die "COMPETITION_TEST_DURATION must be a positive integer number of seconds"
  fi
  printf '%s\n' "$COMPETITION_TEST_DURATION"
}

competition_window_value() {
  local value="$1" duration="$2" which="$3" fallback
  if [[ "$value" == "auto" || -z "$value" ]]; then
    fallback=$((duration / 3))
    (( fallback < 1 )) && fallback=1
    printf '%s\n' "$fallback"
    return
  fi
  if ! is_positive_integer "$value"; then
    die "${which} must be auto or a positive integer number of seconds"
  fi
  printf '%s\n' "$value"
}

competition_impairment_window() {
  local duration="$1" at hold
  at="$(competition_window_value "$COMPETITION_EVENT_AT" "$duration" COMPETITION_EVENT_AT)"
  hold="$(competition_window_value "$COMPETITION_EVENT_HOLD" "$duration" COMPETITION_EVENT_HOLD)"
  if (( at >= duration )); then
    at=$((duration / 3))
    (( at < 1 )) && at=1
  fi
  if (( at + hold > duration )); then
    hold=$((duration - at))
    (( hold < 1 )) && hold=1
  fi
  printf '%s %s\n' "$at" "$hold"
}

omit_for_delay() {
  local delay="$1"
  if [[ "$ADAPTIVE_DURATION" == "1" || "$ADAPTIVE_DURATION" == "yes" || "$ADAPTIVE_DURATION" == "true" ]]; then
    if delay_is_high_latency "$delay"; then
      max_int "$OMIT" "$HIGH_LATENCY_OMIT"
      return
    fi
  fi
  printf '%s\n' "$OMIT"
}

clear_policer() {
  ip netns exec "$R_NS" tc qdisc del dev "$R_C_IF" ingress 2>/dev/null || true
}

enable_ingress_policer() {
  local rate="${1:-$POLICE_RATE}"
  local burst="${2:-$POLICE_BURST}"
  local mtu="${3:-$POLICE_MTU}"
  local match_dst="${4:-$POLICE_MATCH_DST}"

  clear_policer
  ip netns exec "$R_NS" tc qdisc add dev "$R_C_IF" handle ffff: ingress
  ip netns exec "$R_NS" tc filter add dev "$R_C_IF" parent ffff: protocol ip prio 10 u32 \
    match ip dst "$match_dst" \
    action police rate "$rate" burst "$burst" mtu "$mtu" conform-exceed drop
}

install_impairment_qdisc() {
  local op="$1" dev="$2" parent="$3" handle="$4" limit="$5" delay="$6" loss_spec="$7" seed="$8" rate="$9" profile="${10:-netem_fifo}"
  local loss_text major child_parent child_handle fq_ecn_args cake_args extra_text
  local -a loss_args extra_args
  loss_text="$(loss_args_from_spec "$loss_spec")"
  read -r -a loss_args <<< "$loss_text"
  extra_text=""
  if [[ "$dev" == "$R_S_IF" ]]; then
    extra_text="${ACTIVE_DATA_DELAY_EXTRA:-}"
  elif [[ "$dev" == "$R_C_IF" ]]; then
    extra_text="${ACTIVE_ACK_DELAY_EXTRA:-}"
  fi
  if [[ -n "$extra_text" ]]; then
    read -r -a extra_args <<< "$extra_text"
  else
    extra_args=()
  fi

  limit="$(queue_limit_for_profile "$profile" "$rate" "$delay" "$limit")"

  # The parent qdisc always supplies delay/loss. Queue profile then either uses
  # netem's built-in FIFO queue, or attempts to attach an AQM child to netem's
  # implicit class. If the kernel/qdisc combination rejects the child, the run
  # continues with FIFO and records the fallback in stderr/tc stats.
  ip netns exec "$R_NS" tc qdisc "$op" dev "$dev" parent "$parent" handle "$handle" netem \
    limit "$limit" delay "$delay" "${extra_args[@]}" "${loss_args[@]}" seed "$seed"

  major="${handle%:}"
  child_parent="${major}:1"
  child_handle="$((10#$major + 100)):"
  case "$profile" in
    fq)
      ip netns exec "$R_NS" tc qdisc replace dev "$dev" parent "$child_parent" handle "$child_handle" fq \
        limit "$FQ_LIMIT" flow_limit "$FQ_FLOW_LIMIT" quantum "$FQ_QUANTUM" initial_quantum "$FQ_INITIAL_QUANTUM" 2>/dev/null || \
        log "fq child attach failed on $dev parent $child_parent; using netem FIFO for this path."
      ;;
    fq_codel|fq-codel)
      fq_ecn_args=()
      if [[ "$FQ_CODEL_ECN" == "1" || "$FQ_CODEL_ECN" == "yes" || "$FQ_CODEL_ECN" == "true" ]]; then
        fq_ecn_args=(ecn)
      fi
      ip netns exec "$R_NS" tc qdisc replace dev "$dev" parent "$child_parent" handle "$child_handle" fq_codel \
        limit "$FQ_CODEL_LIMIT" target "$FQ_CODEL_TARGET" interval "$FQ_CODEL_INTERVAL" "${fq_ecn_args[@]}" 2>/dev/null || \
        log "fq_codel child attach failed on $dev parent $child_parent; using netem FIFO for this path."
      ;;
    cake)
      cake_args=()
      if [[ -n "$CAKE_ECN_MODE" ]]; then
        # shellcheck disable=SC2206
        cake_args=($CAKE_ECN_MODE)
      fi
      # shellcheck disable=SC2086
      ip netns exec "$R_NS" tc qdisc replace dev "$dev" parent "$child_parent" handle "$child_handle" cake bandwidth "$rate" $CAKE_OVERHEAD_MODE "${cake_args[@]}" 2>/dev/null || \
        log "cake child attach failed on $dev parent $child_parent; using netem FIFO for this path."
      ;;
    *)
      ;;
  esac
}

setup_shapers() {
  local rate="$1"
  local delay="$2"
  local loss_spec="$3"
  local ack_rate ack_delay ack_loss data_limit ack_limit
  local -a data_class_args ack_class_args
  ack_rate="${ACTIVE_ACK_RATE:-$ACK_RATE}"
  ack_delay="${ACTIVE_ACK_DELAY:-$delay}"
  [[ -n "$ack_delay" ]] || ack_delay="$delay"
  ack_loss="${ACTIVE_ACK_LOSS:-0%}"
  data_limit="$(queue_limit_for "$rate" "$delay")"
  ack_limit="$(ack_queue_limit_for "$ack_delay" "$ack_rate")"

  data_class_args=(rate "$rate" ceil "$rate")
  ack_class_args=(rate "$ack_rate" ceil "$ack_rate")
  if [[ -n "$HTB_QUANTUM" && "$HTB_QUANTUM" != "auto" ]]; then
    data_class_args+=(quantum "$HTB_QUANTUM")
    ack_class_args+=(quantum "$HTB_QUANTUM")
  fi

  # Data path: client -> router -> server. HTB sets bottleneck rate; netem adds delay/loss.
  ip netns exec "$R_NS" tc qdisc del dev "$R_S_IF" root 2>/dev/null || true
  ip netns exec "$R_NS" tc qdisc add dev "$R_S_IF" root handle 1: htb default 1 r2q "$HTB_R2Q"
  ip netns exec "$R_NS" tc class add dev "$R_S_IF" parent 1: classid 1:1 htb "${data_class_args[@]}"
  install_impairment_qdisc add "$R_S_IF" "1:1" "10:" "$data_limit" "$delay" "$loss_spec" "$NETEM_SEED" "$rate" "${ACTIVE_QUEUE_PROFILE:-$QUEUE_PROFILE}"

  # Reverse path: normally ACKs, but becomes the data bottleneck for iperf3 -R.
  ip netns exec "$R_NS" tc qdisc del dev "$R_C_IF" root 2>/dev/null || true
  ip netns exec "$R_NS" tc qdisc add dev "$R_C_IF" root handle 1: htb default 1 r2q "$HTB_R2Q"
  ip netns exec "$R_NS" tc class add dev "$R_C_IF" parent 1: classid 1:1 htb "${ack_class_args[@]}"
  install_impairment_qdisc add "$R_C_IF" "1:1" "20:" "$ack_limit" "$ack_delay" "$ack_loss" "$ACK_SEED" "$ack_rate" "${ACTIVE_ACK_QUEUE_PROFILE:-$QUEUE_PROFILE}"
}

change_shapers() {
  local rate="$1"
  local delay="$2"
  local loss_spec="$3"
  local ack_rate ack_delay ack_loss data_limit ack_limit
  local -a data_class_args ack_class_args
  ack_rate="${ACTIVE_ACK_RATE:-$ACK_RATE}"
  ack_delay="${ACTIVE_ACK_DELAY:-$delay}"
  [[ -n "$ack_delay" ]] || ack_delay="$delay"
  ack_loss="${ACTIVE_ACK_LOSS:-0%}"
  data_limit="$(queue_limit_for "$rate" "$delay")"
  ack_limit="$(ack_queue_limit_for "$ack_delay" "$ack_rate")"

  data_class_args=(rate "$rate" ceil "$rate")
  ack_class_args=(rate "$ack_rate" ceil "$ack_rate")
  if [[ -n "$HTB_QUANTUM" && "$HTB_QUANTUM" != "auto" ]]; then
    data_class_args+=(quantum "$HTB_QUANTUM")
    ack_class_args+=(quantum "$HTB_QUANTUM")
  fi

  ip netns exec "$R_NS" tc class change dev "$R_S_IF" parent 1: classid 1:1 htb "${data_class_args[@]}"
  ip netns exec "$R_NS" tc class change dev "$R_C_IF" parent 1: classid 1:1 htb "${ack_class_args[@]}" 2>/dev/null || true
  install_impairment_qdisc replace "$R_S_IF" "1:1" "10:" "$data_limit" "$delay" "$loss_spec" "$NETEM_SEED" "$rate" "${ACTIVE_QUEUE_PROFILE:-$QUEUE_PROFILE}"
  install_impairment_qdisc replace "$R_C_IF" "1:1" "20:" "$ack_limit" "$ack_delay" "$ack_loss" "$ACK_SEED" "$ack_rate" "${ACTIVE_ACK_QUEUE_PROFILE:-$QUEUE_PROFILE}"
}


flush_tcp_metrics() {
  ip netns exec "$C_NS" ip tcp_metrics flush all 2>/dev/null || true
  ip netns exec "$S_NS" ip tcp_metrics flush all 2>/dev/null || true
}

safe_name() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

ACTIVE_ONEWAY_DELAY="$ONEWAY_DELAY"
ACTIVE_BASE_RATE="$BASE_RATE"

set_active_latency() {
  ACTIVE_ONEWAY_DELAY="${1:-$ONEWAY_DELAY}"
}

current_delay() {
  printf '%s\n' "${ACTIVE_ONEWAY_DELAY:-$ONEWAY_DELAY}"
}

set_active_rate() {
  ACTIVE_BASE_RATE="${1:-$CONFIGURED_BASE_RATE}"
  BASE_RATE="$ACTIVE_BASE_RATE"
}

current_rate() {
  printf '%s\n' "${ACTIVE_BASE_RATE:-$BASE_RATE}"
}

rate_label_enabled() {
  case "$RATE_LABEL_IN_SCENARIO" in
    1|yes|true|always) return 0 ;;
    0|no|false|never) return 1 ;;
  esac
  [[ "$RATE_MODE" != "single" || "$ENABLE_10G_STRESS" == "1" || "$BASE_RATE" != "$CONFIGURED_BASE_RATE" ]]
}

scenario_with_latency() {
  local scenario="$1"
  local label
  label="${scenario}__lat_$(safe_name "$(current_delay)")"
  if rate_label_enabled; then
    label="${label}__rate_$(safe_name "$(current_rate)")"
  fi
  printf '%s\n' "$label"
}

variant_for_pair() {
  if [[ "$1" == "$2" ]]; then
    printf '%s\n' "same_algo"
  else
    printf '%s\n' "cross_algo"
  fi
}

competition_cooldown() {
  local seconds="${COMPETITION_COOLDOWN:-$RUN_COOLDOWN}"
  if [[ -n "$seconds" && "$seconds" != "0" ]]; then
    sleep "$seconds"
  fi
}

is_positive_integer() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 > 0 ))
}

is_nonnegative_integer() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

port_rotation_enabled() {
  case "${PORT_ROTATION}" in
    1|yes|true|on|rotate) return 0 ;;
    *) return 1 ;;
  esac
}

allocate_port_block() {
  local __out="$1" required="${2:-1}" block offset
  is_positive_integer "$required" || die "allocate_port_block requires a positive required-port count"
  if (( required > SERVER_COUNT )); then
    die "This test needs SERVER_COUNT>=${required}; current SERVER_COUNT=${SERVER_COUNT}"
  fi

  if ! port_rotation_enabled; then
    printf -v "$__out" '%s' "$BASE_PORT"
    return
  fi

  block="${PORT_BLOCK_SIZE:-auto}"
  if [[ -z "$block" || "$block" == "auto" ]]; then
    block="$required"
  fi
  is_positive_integer "$block" || die "PORT_BLOCK_SIZE must be auto or a positive integer"
  if (( block < required )); then
    block="$required"
  fi
  if (( block > SERVER_COUNT )); then
    die "PORT_BLOCK_SIZE=${block} exceeds SERVER_COUNT=${SERVER_COUNT}"
  fi

  offset="$PORT_ROTATION_NEXT_OFFSET"
  if (( offset < 0 || offset >= SERVER_COUNT || offset + block > SERVER_COUNT )); then
    offset=0
  fi
  printf -v "$__out" '%s' "$((BASE_PORT + offset))"
  PORT_ROTATION_NEXT_OFFSET=$((offset + block))
  if (( PORT_ROTATION_NEXT_OFFSET >= SERVER_COUNT )); then
    PORT_ROTATION_NEXT_OFFSET=0
  fi
}

effective_multi_total_flows() {
  is_positive_integer "$MULTI_COMPETITOR_FLOWS" || die "MULTI_COMPETITOR_FLOWS must be a positive integer"
  printf '%s\n' "$((MULTI_COMPETITOR_FLOWS + 1))"
}

effective_combined_total_flows() {
  local total
  if [[ -n "${COMBINED_COMPETITOR_FLOWS}" ]]; then
    is_positive_integer "$COMBINED_COMPETITOR_FLOWS" || die "COMBINED_COMPETITOR_FLOWS must be a positive integer when set"
    total=$((COMBINED_COMPETITOR_FLOWS + 1))
  else
    total="$(effective_multi_total_flows)"
  fi
  printf '%s\n' "$total"
}

is_all_algo_competition_scenario() {
  case "$1" in
    flow_fairness|flow_fairness_*) return 0 ;;
    *) return 1 ;;
  esac
}

competition_algo_list() {
  local algo seen=" "
  for algo in "${SELECTED_ALGOS[@]}" "${COMPETITOR_ALGO_LIST[@]}"; do
    [[ -n "$algo" ]] || continue
    if [[ "$seen" != *" $algo "* ]]; then
      seen+="$algo "
      printf '%s\n' "$algo"
    fi
  done
}

competition_algo_label() {
  local out="" sep="" algo
  for algo in "$@"; do
    [[ -n "$algo" ]] || continue
    out="${out}${sep}${algo}"
    sep="_"
  done
  safe_name "${out:-none}"
}

competition_peer_label() {
  local out="" sep="" algo
  for algo in "$@"; do
    [[ -n "$algo" ]] || continue
    out="${out}${sep}${algo}"
    sep="|"
  done
  printf '%s\n' "all:${out:-none}"
}

should_run_all_algo_competition_once() {
  local algo="$1" first="${SELECTED_ALGOS[0]:-}"
  [[ -n "$first" && "$algo" == "$first" ]]
}


event_log_init() {
  local file="$1"
  mkdir -p "$(dirname "$file")"
  printf 'timestamp,event,rate,oneway_delay,netem_loss,police_rate,police_burst,metric_name,metric_value,extra\n' > "$file"
}

event_log() {
  local file="$1"; shift
  local ts event_id
  ts="$(date -Is)"
  event_id="$(safe_name "$(basename "$file" .csv)")_${BASHPID}_${SECONDS}_${RANDOM}"
  printf '%s,%s\n' "$ts" "$*" >> "$file"
  python3 - "$EVENTS_CSV" "$file" "$SCHEMA_VERSION" "$RUN_ID" "$event_id" "$ts" "$*" <<'PYEVENT'
import csv, os, re, sys
from datetime import datetime
(events_csv, raw_file, schema_version, run_id, event_id, ts, payload) = sys.argv[1:]
fields = next(csv.reader([payload])) if payload else []
fields += [''] * (9 - len(fields))
event_name, rate, oneway_delay, netem_loss, police_rate, police_burst, metric_name, metric_value, extra = fields[:9]
if not extra and not metric_value and ('=' in metric_name or ';' in metric_name):
    extra = metric_name
    metric_name = ''
case_id = os.path.splitext(os.path.basename(raw_file))[0]

def rate_to_mbps(v):
    if not v or str(v).startswith('dynamic:') or (':' in str(v) and not re.match(r'^[0-9.]+\s*[kmg]?bit', str(v), re.I)):
        return ''
    s = str(v).strip().lower()
    m = re.match(r'([0-9.]+)', s)
    if not m:
        return ''
    n = float(m.group(1))
    if 'gbit' in s or 'gbps' in s or re.fullmatch(r'[0-9.]+g', s):
        n *= 1000
    elif 'kbit' in s or 'kbps' in s or re.fullmatch(r'[0-9.]+k', s):
        n /= 1000
    elif 'bit' in s and 'mbit' not in s and 'mbps' not in s:
        n /= 1_000_000
    return f'{n:.9f}'

def delay_to_ms(v):
    if not v or str(v).startswith('dynamic:') or ':' in str(v):
        return ''
    s = str(v).strip().lower()
    m = re.match(r'([0-9.]+)', s)
    if not m:
        return ''
    n = float(m.group(1))
    if 'us' in s or 'usec' in s:
        n /= 1000
    elif re.fullmatch(r'[0-9.]+s(ec)?', s):
        n *= 1000
    return f'{n:.9f}'

def pct(v):
    if not v:
        return ''
    m = re.search(r'([0-9.]+)\s*%', str(v))
    return f'{float(m.group(1)):.9f}' if m else ''

def loss_pair(v):
    s = str(v or '')
    fwd = rev = ''
    if 'fwd:' in s or 'rev:' in s:
        mf = re.search(r'fwd:([^;]+)', s)
        mr = re.search(r'rev:([^;]+)', s)
        fwd = pct(mf.group(1)) if mf else ''
        rev = pct(mr.group(1)) if mr else ''
    else:
        fwd = pct(s)
    return fwd, rev

def infer_phase(name, extra):
    m = re.search(r'(?:^|;)phase=([^;]+)', extra or '')
    if m:
        return m.group(1)
    n = (name or '').lower()
    for token in ['idle', 'loaded', 'recovery', 'latency', 'loss', 'capacity', 'policer', 'ack', 'jitter', 'reorder', 'flow_fairness', 'proxy_mobile']:
        if token in n:
            return token
    return name or ''

def infer_target_parameter(name, extra):
    text = f'{name} {extra}'.lower()
    if 'ack' in text or 'reverse' in text or 'mobile' in text:
        target = 'ack_path' if 'ack' in text else 'data_path'
        if 'loss' in text or 'drop' in text:
            parameter = 'loss'
        elif 'delay' in text or 'latency' in text or 'jitter' in text:
            parameter = 'delay'
        elif 'rate' in text or 'limit' in text:
            parameter = 'rate'
        else:
            parameter = 'path'
    elif 'policer' in text or 'police' in text:
        target, parameter = 'policer', 'policer_rate'
    elif 'queue' in text or 'bufferbloat' in text or 'sqm' in text:
        target, parameter = 'queue', 'queue_profile'
    elif 'loss' in text or 'drop' in text:
        target, parameter = 'data_path', 'loss'
    elif 'latency' in text or 'delay' in text or 'rtt' in text or 'jitter' in text:
        target, parameter = 'data_path', 'delay'
    elif 'capacity' in text or 'rate' in text:
        target, parameter = 'data_path', 'rate'
    elif 'flow' in text or 'competitor' in text:
        target, parameter = 'flow', 'flow_state'
    else:
        target, parameter = 'controller', 'event'
    return target, parameter

def relative_seconds(raw_file, ts):
    try:
        current = datetime.fromisoformat(ts.replace('Z', '+00:00'))
        first = None
        with open(raw_file, encoding='utf-8', errors='replace') as f:
            reader = csv.reader(f)
            next(reader, None)
            for row in reader:
                if row:
                    first = datetime.fromisoformat(row[0].replace('Z', '+00:00'))
                    break
        if first is not None:
            return f'{(current - first).total_seconds():.6f}'
    except Exception:
        pass
    return ''

loss_fwd, loss_rev = loss_pair(netem_loss)
target, parameter = infer_target_parameter(event_name, extra)
with open(events_csv, 'a', newline='') as f:
    w = csv.writer(f)
    w.writerow([schema_version, run_id, case_id, event_id, ts, relative_seconds(raw_file, ts),
                case_id, infer_phase(event_name, extra), event_name, target, parameter, '', '', '',
                rate, rate_to_mbps(rate), oneway_delay, delay_to_ms(oneway_delay), netem_loss,
                loss_fwd, loss_rev, police_rate, rate_to_mbps(police_rate), police_burst,
                metric_name, metric_value, extra, raw_file])
PYEVENT
}

start_ss_logger() {
  local file="$1"
  local duration="$2"
  (
    local end=$((SECONDS + duration + 5))
    while ((SECONDS < end)); do
      printf '### %s\n' "$(date -Ins)"
      ip netns exec "$C_NS" ss -tin dst "$S_IP" || true
      sleep "$SS_INTERVAL"
    done
  ) > "$file" 2>&1 &
  echo $!
}

run_iperf_capture() {
  local json_file="$1"
  local stderr_file="$2"
  local algo="$3"
  local duration="$4"
  local parallel="$5"
  local port="$6"
  local mode="${7:-upload}"
  local omit_seconds
  omit_seconds="$(omit_for_delay "$(current_delay)")"
  local -a timeout_args=() direction_args=()
  if [[ -n "${IPERF_CONNECT_TIMEOUT_MS:-}" && "$IPERF_CONNECT_TIMEOUT_MS" != "0" ]]; then
    timeout_args=(--connect-timeout "$IPERF_CONNECT_TIMEOUT_MS")
  fi
  case "$mode" in
    upload|forward) direction_args=() ;;
    download|reverse) direction_args=(-R) ;;
    bidir|bidirectional) direction_args=(--bidir) ;;
    *) die "Unknown iperf mode: $mode" ;;
  esac

  # shellcheck disable=SC2086
  ip netns exec "$C_NS" iperf3 \
    -c "$S_IP" \
    -p "$port" \
    -t "$duration" \
    -i 1 \
    -O "$omit_seconds" \
    -J \
    -C "$algo" \
    -P "$parallel" \
    "${direction_args[@]}" \
    "${timeout_args[@]}" \
    $IPERF_EXTRA \
    > "$json_file" 2> "$stderr_file"
}

run_iperf_capture_bytes() {
  local json_file="$1"
  local stderr_file="$2"
  local algo="$3"
  local bytes="$4"
  local port="$5"
  local mode="${6:-upload}"
  local -a timeout_args=() direction_args=()
  if [[ -n "${IPERF_CONNECT_TIMEOUT_MS:-}" && "$IPERF_CONNECT_TIMEOUT_MS" != "0" ]]; then
    timeout_args=(--connect-timeout "$IPERF_CONNECT_TIMEOUT_MS")
  fi
  case "$mode" in
    upload|forward) direction_args=() ;;
    download|reverse) direction_args=(-R) ;;
    *) die "Unknown short-flow iperf mode: $mode" ;;
  esac
  # shellcheck disable=SC2086
  ip netns exec "$C_NS" iperf3 \
    -c "$S_IP" \
    -p "$port" \
    -n "$bytes" \
    -i 1 \
    -J \
    -C "$algo" \
    "${direction_args[@]}" \
    "${timeout_args[@]}" \
    $IPERF_EXTRA \
    > "$json_file" 2> "$stderr_file"
}


append_json_results() {
  local json_file="$1"
  local scenario="$2"
  local role="$3"
  local algo="$4"
  local repeat="$5"
  local parallel="$6"
  local requested_seconds="$7"
  local rc="$8"
  local stderr_file="$9"
  local variant="${10:-single}"
  local flow_group="${11:-$(safe_name "${scenario}_${algo}_r${repeat}")}"
  local peer_algo="${12:-}"
  local oneway_delay="${13:-}"
  local rate="${14:-}"
  local netem_loss="${15:-}"
  local police_rate="${16:-}"
  local start_offset_seconds="${17:-0}"
  local ss_file="${18:-}"
  local tc_file="${19:-}"
  local queue_profile_data="${ACTIVE_QUEUE_PROFILE:-$QUEUE_PROFILE}"
  local queue_profile_ack="${ACTIVE_ACK_QUEUE_PROFILE:-$QUEUE_PROFILE}"
  local ack_rate="${ACTIVE_ACK_RATE:-$ACK_RATE}"
  local worker_id="${PARALLEL_WORKER_ID:-}"

  python3 - "$SUMMARY_CSV" "$INTERVALS_CSV" "$SCHEMA_VERSION" "$RUN_ID" "$json_file" "$scenario" "$variant" "$flow_group" "$role" "$algo" "$peer_algo" "$oneway_delay" "$rate" "$ack_rate" "$netem_loss" "$police_rate" "$repeat" "$parallel" "$requested_seconds" "$start_offset_seconds" "$rc" "$stderr_file" "$ss_file" "$tc_file" "$queue_profile_data" "$queue_profile_ack" "$worker_id" <<'PYAPP'
import csv, json, os, re, sys
from datetime import datetime, timezone

(summary_csv, intervals_csv, schema_version, run_id, json_file, scenario, variant,
 flow_group, role, algo, peer_algo, oneway_delay, rate, ack_rate, netem_loss,
 police_rate, repeat, parallel, requested_seconds, start_offset_seconds, rc,
 stderr_file, ss_file, tc_file, queue_profile_data, queue_profile_ack,
 worker_id) = sys.argv[1:]

ts_end = datetime.now(timezone.utc).isoformat()
err = ""
json_parse_failed = False
try:
    if os.path.exists(stderr_file):
        with open(stderr_file, "r", encoding="utf-8", errors="replace") as f:
            err = f.read().replace("\n", " | ")[:500]
except Exception:
    pass

data = None
try:
    with open(json_file, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception as e:
    json_parse_failed = True
    err = (err + " | JSON parse error: " + str(e)).strip(" |")[:500]

iperf_json_error = False
if isinstance(data, dict) and data.get("error"):
    iperf_json_error = True
    err = (err + " | iperf3 JSON error: " + str(data.get("error"))).strip(" |")[:500]

def nval(d, key, default=""):
    try:
        v = d.get(key, default)
        if v is None:
            return default
        return v
    except Exception:
        return default

def ffloat(x):
    try:
        if x == "" or x is None:
            return None
        return float(x)
    except Exception:
        return None

def rate_to_mbps(v):
    if v is None:
        return ""
    s = str(v).strip().lower()
    if not s or s.startswith("dynamic:") or ";" in s or ":" in s:
        return ""
    m = re.match(r"([0-9.]+)", s)
    if not m:
        return ""
    n = float(m.group(1))
    if "gbit" in s or "gbps" in s or re.fullmatch(r"[0-9.]+g", s):
        n *= 1000.0
    elif "mbit" in s or "mbps" in s or re.fullmatch(r"[0-9.]+m", s):
        pass
    elif "kbit" in s or "kbps" in s or re.fullmatch(r"[0-9.]+k", s):
        n /= 1000.0
    elif "bit" in s or "bps" in s:
        n /= 1_000_000.0
    return f"{n:.9f}"

def delay_to_ms(v):
    if v is None:
        return ""
    s = str(v).strip().lower()
    if not s or s.startswith("dynamic:") or ":" in s:
        return ""
    m = re.match(r"([0-9.]+)", s)
    if not m:
        return ""
    n = float(m.group(1))
    if "us" in s or "usec" in s:
        n /= 1000.0
    elif re.fullmatch(r"[0-9.]+s(ec)?", s):
        n *= 1000.0
    return f"{n:.9f}"

def pct(v):
    if not v:
        return ""
    m = re.search(r"([0-9.]+)\s*%", str(v))
    return f"{float(m.group(1)):.9f}" if m else ""

def loss_pair(v):
    s = str(v or "")
    fwd = rev = ""
    if "fwd:" in s or "rev:" in s:
        mf = re.search(r"fwd:([^;]+)", s)
        mr = re.search(r"rev:([^;]+)", s)
        fwd = pct(mf.group(1)) if mf else ""
        rev = pct(mr.group(1)) if mr else ""
    else:
        fwd = pct(s)
    return fwd, rev

def scenario_family_name(s):
    if s.startswith("combined_all"):
        return "combined_all"
    if s.startswith("latency_sweep"):
        return "latency_sweep"
    if "__lat_" in s:
        return s.split("__lat_", 1)[0]
    return s.split("__", 1)[0]

def infer_direction(role, data):
    r = (role or "").lower()
    if "bidirectional" in r or "bidir" in r:
        return "bidirectional"
    if "download" in r or "reverse" in r or "proxy" in r:
        return "download"
    if "upload" in r:
        return "upload"
    try:
        test = ((data or {}).get("start", {}) or {}).get("test_start", {}) or {}
        if str(test.get("bidirectional", "0")) in ("1", "true", "True"):
            return "bidirectional"
        if str(test.get("reverse", "0")) in ("1", "true", "True"):
            return "download"
    except Exception:
        pass
    return "upload"

def timestamp_start(data):
    try:
        ts = ((data or {}).get("start", {}) or {}).get("timestamp", {}) or {}
        seconds = ts.get("timesecs")
        if seconds is not None:
            return datetime.fromtimestamp(float(seconds), timezone.utc).isoformat()
    except Exception:
        pass
    return ts_end

def failure_category(success, receiver_mbps):
    if success == "1":
        return "ok"
    if json_parse_failed:
        return "json_parse_error"
    if iperf_json_error:
        return "iperf_error"
    if str(rc) != "0":
        return "iperf_error"
    if receiver_mbps == "":
        return "missing_receiver_summary"
    try:
        if float(receiver_mbps) == 0.0:
            return "zero_throughput"
    except Exception:
        pass
    return "incomplete"

sender_mbps = receiver_mbps = actual_seconds = retransmits = bytes_sent = bytes_received = ""
receiver_gbits = retrans_per_gbit = ""
success = "0"
if data:
    end = data.get("end", {}) or {}
    sum_sent = end.get("sum_sent", {}) or {}
    sum_received = end.get("sum_received", {}) or {}
    sender_bps = nval(sum_sent, "bits_per_second", "")
    receiver_bps = nval(sum_received, "bits_per_second", "")
    try:
        sender_mbps = f"{float(sender_bps) / 1_000_000:.6f}" if sender_bps != "" else ""
    except Exception:
        sender_mbps = ""
    try:
        receiver_mbps = f"{float(receiver_bps) / 1_000_000:.6f}" if receiver_bps != "" else ""
    except Exception:
        receiver_mbps = ""
    actual_seconds = nval(sum_received, "seconds", nval(sum_sent, "seconds", ""))
    retransmits = nval(sum_sent, "retransmits", "")
    bytes_sent = nval(sum_sent, "bytes", "")
    bytes_received = nval(sum_received, "bytes", "")
    br = ffloat(bytes_received)
    rt = ffloat(retransmits)
    if br and br > 0:
        gb = br * 8.0 / 1_000_000_000.0
        receiver_gbits = f"{gb:.6f}"
        if rt is not None:
            retrans_per_gbit = f"{rt / gb:.3f}"
    if str(rc) == "0" and receiver_mbps != "":
        success = "1"

case_id = flow_group
flow_id = f"{flow_group}:{role}:{algo}"
trial_id = f"{flow_group}:r{repeat}"
direction = infer_direction(role, data)
scenario_family = scenario_family_name(scenario)
oneway_delay_ms = delay_to_ms(oneway_delay)
data_rate_mbps = rate_to_mbps(rate)
ack_rate_mbps = rate_to_mbps(ack_rate)
loss_fwd_pct, loss_rev_pct = loss_pair(netem_loss)
policer_rate_mbps = rate_to_mbps(police_rate)
policer_enabled = "1" if str(police_rate or "").strip() else "0"
utilization_pct = ""
try:
    if receiver_mbps != "" and data_rate_mbps != "" and float(data_rate_mbps) > 0:
        utilization_pct = f"{float(receiver_mbps) / float(data_rate_mbps) * 100.0:.6f}"
except Exception:
    pass
category = failure_category(success, receiver_mbps)

with open(summary_csv, "a", newline="") as f:
    w = csv.writer(f)
    w.writerow([schema_version, run_id, case_id, flow_id, trial_id, repeat, worker_id,
                timestamp_start(data), ts_end, scenario_family, scenario, variant, flow_group,
                role, algo, peer_algo, direction, parallel, parallel, oneway_delay,
                oneway_delay_ms, rate, data_rate_mbps, ack_rate_mbps, netem_loss,
                loss_fwd_pct, loss_rev_pct, police_rate, policer_enabled, policer_rate_mbps,
                queue_profile_data, queue_profile_ack, repeat, requested_seconds,
                start_offset_seconds, actual_seconds, sender_mbps, receiver_mbps,
                utilization_pct, retransmits, bytes_sent, bytes_received, receiver_gbits,
                retrans_per_gbit, success, rc, category, json_file, stderr_file, ss_file,
                tc_file, json_file, err])

if data:
    try:
        offset = float(start_offset_seconds or 0)
    except Exception:
        offset = 0.0
    with open(intervals_csv, "a", newline="") as f:
        w = csv.writer(f)
        for idx, interval in enumerate(data.get("intervals", []) or []):
            s = interval.get("sum", {}) or {}
            bps = nval(s, "bits_per_second", "")
            try:
                mbps = f"{float(bps) / 1_000_000:.6f}" if bps != "" else ""
            except Exception:
                mbps = ""
            start = nval(s, "start", "")
            end = nval(s, "end", "")
            try:
                abs_start = f"{offset + float(start):.6f}" if start != "" else ""
            except Exception:
                abs_start = ""
            try:
                abs_end = f"{offset + float(end):.6f}" if end != "" else ""
            except Exception:
                abs_end = ""
            w.writerow([schema_version, run_id, case_id, flow_id, idx, ts_end,
                        scenario_family, scenario, variant, flow_group, role, algo,
                        peer_algo, direction, oneway_delay, oneway_delay_ms, rate,
                        data_rate_mbps, netem_loss, police_rate, repeat, parallel,
                        parallel, start_offset_seconds, start, end, abs_start, abs_end,
                        nval(s, "seconds", ""), mbps, nval(s, "retransmits", ""),
                        nval(s, "omitted", ""), json_file, json_file, "", ""])
PYAPP
}

ping_count_for_duration() {
  local duration="$1"
  awk -v d="$duration" -v i="$PING_INTERVAL" 'BEGIN {
    if (i <= 0) i = 1;
    # First ping is sent immediately, then one every interval. Add one sample
    # so a requested 8s phase at 0.2s asks for about 41 probes, not 40.
    c = int(d / i + 0.999999) + 1;
    if (c < 1) c = 1;
    printf "%d\n", c;
  }'
}

start_ping_probe() {
  local __pid_var="$1"
  local file="$2"
  local duration="$3"
  local ns="${4:-$C_NS}"
  local target="${5:-$S_IP}"
  local count deadline
  count="$(ping_count_for_duration "$duration")"
  deadline="$(awk -v d="$duration" -v e="$BB_PING_DEADLINE_EXTRA" 'BEGIN {
    if (e < 0) e = 0;
    printf "%d", int(d + e + 0.999999);
  }')"
  ip netns exec "$ns" ping -n -D -i "$PING_INTERVAL" -s "$PING_SIZE" -c "$count" -w "$deadline" "$target" > "$file" 2>&1 &
  printf -v "$__pid_var" '%s' "$!"
}

append_ping_results() {
  local raw_file="$1"
  local scenario="$2"
  local variant="$3"
  local flow_group="$4"
  local phase="$5"
  local role="$6"
  local algo="$7"
  local queue_profile="$8"
  local direction="$9"
  local oneway_delay="${10}"
  local rate="${11}"
  local repeat="${12}"

  python3 - "$PING_CSV" "$SCHEMA_VERSION" "$RUN_ID" "$raw_file" "$scenario" "$variant" "$flow_group" "$phase" "$role" "$algo" "$queue_profile" "$direction" "$oneway_delay" "$rate" "$repeat" <<'PYPING'
import csv, re, sys
from datetime import datetime, timezone
(ping_csv, schema_version, run_id, raw_file, scenario, variant, flow_group, phase,
 role, algo, queue_profile, direction, oneway_delay, rate, repeat) = sys.argv[1:]
ts_now = datetime.now(timezone.utc).isoformat()
line_re = re.compile(r'(?:\[(?P<ts>[0-9]+(?:\.[0-9]+)?)\]\s*)?.*icmp_seq=(?P<seq>\d+).*time[=<](?P<rtt>[0-9.]+)\s*ms')

def rate_to_mbps(v):
    s = str(v or '').strip().lower()
    if not s or s.startswith('dynamic:') or ':' in s or ';' in s:
        return ''
    m = re.match(r'([0-9.]+)', s)
    if not m:
        return ''
    n = float(m.group(1))
    if 'gbit' in s or 'gbps' in s or re.fullmatch(r'[0-9.]+g', s):
        n *= 1000
    elif 'kbit' in s or 'kbps' in s or re.fullmatch(r'[0-9.]+k', s):
        n /= 1000
    elif 'bit' in s and 'mbit' not in s and 'mbps' not in s:
        n /= 1_000_000
    return f'{n:.9f}'

def delay_to_ms(v):
    s = str(v or '').strip().lower()
    if not s or s.startswith('dynamic:') or ':' in s:
        return ''
    m = re.match(r'([0-9.]+)', s)
    if not m:
        return ''
    n = float(m.group(1))
    if 'us' in s or 'usec' in s:
        n /= 1000
    elif re.fullmatch(r'[0-9.]+s(ec)?', s):
        n *= 1000
    return f'{n:.9f}'

rows = []
try:
    with open(raw_file, 'r', encoding='utf-8', errors='replace') as f:
        first_ts = None
        for line in f:
            m = line_re.search(line)
            if not m:
                continue
            icmp_ts = m.group('ts') or ''
            relative = ''
            if icmp_ts:
                try:
                    cur = float(icmp_ts)
                    if first_ts is None:
                        first_ts = cur
                    relative = f'{cur - first_ts:.6f}'
                except Exception:
                    relative = ''
            seq = m.group('seq')
            probe_id = f'{flow_group}:{phase}:{seq}'
            rows.append([schema_version, run_id, flow_group, probe_id, ts_now, relative,
                         phase, scenario, variant, flow_group, role, algo, direction,
                         queue_profile, oneway_delay, delay_to_ms(oneway_delay), rate,
                         rate_to_mbps(rate), repeat, seq, icmp_ts, m.group('rtt'), '0',
                         raw_file, raw_file])
except FileNotFoundError:
    pass
with open(ping_csv, 'a', newline='') as f:
    csv.writer(f).writerows(rows)
PYPING
}

start_queue_probe() {
  local __pid_var="$1"
  local file="$2"
  local duration="$3"
  local interval="${4:-$BB_QUEUE_SAMPLE_INTERVAL}"
  (
    local start_ts now_ts rel sample
    start_ts="$(date +%s.%N)"
    sample=0
    while :; do
      now_ts="$(date +%s.%N)"
      rel="$(awk -v n="$now_ts" -v s="$start_ts" 'BEGIN { printf "%.6f", n - s }')"
      if awk -v r="$rel" -v d="$duration" 'BEGIN { exit !(r > d) }'; then
        break
      fi
      echo "### $(date -Ins) sample=${sample} relative_s=${rel}"
      echo "# path=data dev=${R_S_IF}"
      ip netns exec "$R_NS" tc -s qdisc show dev "$R_S_IF" || true
      echo "# path=ack dev=${R_C_IF}"
      ip netns exec "$R_NS" tc -s qdisc show dev "$R_C_IF" || true
      sample=$((sample + 1))
      sleep "$interval"
    done
  ) > "$file" 2>&1 &
  printf -v "$__pid_var" '%s' "$!"
}

append_queue_results() {
  local raw_file="$1"
  local scenario="$2"
  local variant="$3"
  local flow_group="$4"
  local phase="$5"
  local role="$6"
  local algo="$7"
  local queue_profile="$8"
  local direction="$9"
  local oneway_delay="${10}"
  local rate="${11}"
  local repeat="${12}"

  python3 - "$QUEUE_CSV" "$SCHEMA_VERSION" "$RUN_ID" "$raw_file" "$scenario" "$variant" "$flow_group" "$phase" "$role" "$algo" "$queue_profile" "$direction" "$oneway_delay" "$rate" "$repeat" <<'PYQUEUE'
import csv, re, sys
from datetime import datetime, timezone
(queue_csv, schema_version, run_id, raw_file, scenario, variant, flow_group, phase,
 role, algo, queue_profile, direction, oneway_delay, rate, repeat) = sys.argv[1:]

def rate_to_mbps(v):
    s = str(v or '').strip().lower()
    if not s or s.startswith('dynamic:') or ':' in s or ';' in s:
        return ''
    m = re.match(r'([0-9.]+)', s)
    if not m:
        return ''
    n = float(m.group(1))
    if 'gbit' in s or 'gbps' in s or re.fullmatch(r'[0-9.]+g', s):
        n *= 1000
    elif 'kbit' in s or 'kbps' in s or re.fullmatch(r'[0-9.]+k', s):
        n /= 1000
    elif 'bit' in s and 'mbit' not in s and 'mbps' not in s:
        n /= 1_000_000
    return f'{n:.9f}'

def delay_to_ms(v):
    s = str(v or '').strip().lower()
    if not s or s.startswith('dynamic:') or ':' in s:
        return ''
    m = re.match(r'([0-9.]+)', s)
    if not m:
        return ''
    n = float(m.group(1))
    if 'us' in s or 'usec' in s:
        n /= 1000
    elif re.fullmatch(r'[0-9.]+s(ec)?', s):
        n *= 1000
    return f'{n:.9f}'

def size_to_bytes(v):
    s = str(v or '').strip()
    m = re.match(r'([0-9.]+)\s*([A-Za-z]*)', s)
    if not m:
        return ''
    n = float(m.group(1)); u = m.group(2).lower()
    # tc normally reports backlog as bytes with suffixes such as b/Kb/Mb.
    if u in ('', 'b', 'byte', 'bytes'):
        mult = 1
    elif u in ('k', 'kb', 'kbyte', 'kbytes'):
        mult = 1024
    elif u in ('m', 'mb', 'mbyte', 'mbytes'):
        mult = 1024 ** 2
    elif u in ('g', 'gb', 'gbyte', 'gbytes'):
        mult = 1024 ** 3
    else:
        mult = 1
    return str(int(n * mult))

qdisc_re = re.compile(r'^qdisc\s+(?P<kind>\S+)\s+(?P<handle>\S+)\s+(?P<rest>.*)$')
backlog_re = re.compile(r'backlog\s+(?P<bytes>\S+)\s+(?P<packets>[0-9]+)p')
sent_re = re.compile(r'\(dropped\s+(?P<drops>[0-9]+),\s*overlimits\s+(?P<overlimits>[0-9]+)\s+requeues\s+(?P<requeues>[0-9]+)\)')
header_re = re.compile(r'^###\s+(?P<ts>\S+)\s+sample=(?P<sample>[0-9]+)\s+relative_s=(?P<rel>[0-9.]+)')
path_re = re.compile(r'^#\s+path=(?P<path>\S+)\s+dev=(?P<dev>\S+)')
rows = []
cur_ts = datetime.now(timezone.utc).isoformat()
cur_rel = ''
cur_sample = '0'
cur_path = ''
cur_dev = ''
cur_q = None

def parent_from_rest(rest):
    m = re.search(r'\bparent\s+(\S+)', rest or '')
    if m:
        return m.group(1)
    if 'root' in (rest or '').split():
        return 'root'
    return ''

try:
    with open(raw_file, 'r', encoding='utf-8', errors='replace') as f:
        for raw in f:
            line = raw.rstrip('\n')
            mh = header_re.match(line)
            if mh:
                cur_ts = mh.group('ts'); cur_sample = mh.group('sample'); cur_rel = mh.group('rel'); cur_q = None; continue
            mp = path_re.match(line)
            if mp:
                cur_path = mp.group('path'); cur_dev = mp.group('dev'); cur_q = None; continue
            mq = qdisc_re.match(line)
            if mq:
                rest = mq.group('rest')
                cur_q = {'kind': mq.group('kind'), 'handle': mq.group('handle'), 'parent': parent_from_rest(rest), 'drops': '', 'requeues': '', 'overlimits': '', 'line': line}
                continue
            if cur_q is not None:
                ms = sent_re.search(line)
                if ms:
                    cur_q['drops'] = ms.group('drops'); cur_q['overlimits'] = ms.group('overlimits'); cur_q['requeues'] = ms.group('requeues'); continue
                mb = backlog_re.search(line)
                if mb:
                    sample_id = f'{flow_group}:{phase}:{cur_sample}:{cur_path}:{cur_q.get("kind","")}:{cur_q.get("handle","")}'
                    rows.append([schema_version, run_id, flow_group, sample_id, cur_ts, cur_rel,
                                 phase, scenario, variant, flow_group, role, algo, direction,
                                 queue_profile, oneway_delay, delay_to_ms(oneway_delay), rate,
                                 rate_to_mbps(rate), repeat, cur_sample, cur_path, cur_dev,
                                 cur_q.get('kind',''), cur_q.get('handle',''), cur_q.get('parent',''),
                                 size_to_bytes(mb.group('bytes')), mb.group('packets'),
                                 cur_q.get('drops',''), cur_q.get('requeues',''), cur_q.get('overlimits',''),
                                 cur_q.get('line',''), raw_file, raw_file])
                    continue
except FileNotFoundError:
    pass
with open(queue_csv, 'a', newline='') as f:
    csv.writer(f).writerows(rows)
PYQUEUE
}


capture_tc_state() {
  local file="$1"
  {
    echo "### $(date -Ins) tc -s qdisc/class/filter state"
    echo
    echo "# Router data egress: $R_S_IF"
    ip netns exec "$R_NS" tc -s qdisc show dev "$R_S_IF" || true
    ip netns exec "$R_NS" tc -s class show dev "$R_S_IF" || true
    echo
    echo "# Router client-side egress/ACK path: $R_C_IF"
    ip netns exec "$R_NS" tc -s qdisc show dev "$R_C_IF" || true
    ip netns exec "$R_NS" tc -s class show dev "$R_C_IF" || true
    echo
    echo "# Router client-side ingress policer: $R_C_IF parent ffff:"
    ip netns exec "$R_NS" tc -s filter show dev "$R_C_IF" parent ffff: || true
    echo
    echo "# Interface counters"
    ip -n "$R_NS" -s link show dev "$R_C_IF" || true
    ip -n "$R_NS" -s link show dev "$R_S_IF" || true
  } > "$file" 2>&1
}

run_single_test() {
  local scenario="$1"
  local role="$2"
  local algo="$3"
  local repeat="$4"
  local duration="$5"
  local parallel="$6"
  local port="$7"
  local variant="${8:-single}"
  local flow_group="${9:-$(safe_name "${scenario}_${algo}_r${repeat}")}"
  local peer_algo="${10:-}"
  local oneway_delay="${11:-$ONEWAY_DELAY}"
  local rate="${12:-$BASE_RATE}"
  local netem_loss="${13:-0%}"
  local police_rate="${14:-}"
  local tag
  tag="$(safe_name "${scenario}_${role}_${algo}_r${repeat}_P${parallel}_p${port}")"

  local json_file="${JSON_DIR}/${tag}.json"
  local stderr_file="${STDERR_DIR}/${tag}.stderr"
  local ss_file="${SS_DIR}/${tag}.sslog"
  local tc_file="${TC_DIR}/${tag}.tc"

  flush_tcp_metrics
  local ss_pid
  ss_pid="$(start_ss_logger "$ss_file" "$duration")"

  set +e
  run_iperf_capture "$json_file" "$stderr_file" "$algo" "$duration" "$parallel" "$port"
  local rc=$?
  set -e

  kill "$ss_pid" 2>/dev/null || true
  wait "$ss_pid" 2>/dev/null || true
  capture_tc_state "$tc_file"
  append_json_results "$json_file" "$scenario" "$role" "$algo" "$repeat" "$parallel" "$duration" "$rc" "$stderr_file" \
    "$variant" "$flow_group" "$peer_algo" "$oneway_delay" "$rate" "$netem_loss" "$police_rate" "0" "$ss_file" "$tc_file"
  return 0
}

run_with_dynamic_change() {
  local scenario="$1"
  local algo="$2"
  local repeat="$3"
  local event_kind="$4"
  local duration
  duration="$(duration_for_event_delay "$(current_delay)")"
  local port="$BASE_PORT"
  local flow_group="${scenario}_${algo}_r${repeat}"
  local event_file="${EVENTS_RAW_DIR}/$(safe_name "$flow_group").csv"
  local metadata_delay="dynamic"
  local metadata_rate="$BASE_RATE"
  local metadata_loss="dynamic"
  local metadata_policer=""
  local active_delay high_delay low_delay
  active_delay="$(current_delay)"
  high_delay="$HIGH_DELAY"
  low_delay="$LOW_DELAY"
  if [[ "$event_kind" == "latency_spike" && "$high_delay" == "$active_delay" ]]; then
    high_delay="${FALLBACK_SPIKE_DELAY:-600ms}"
  fi
  if [[ "$event_kind" == latency_spike || "$event_kind" == latency_reduction ]]; then
    duration="$(duration_for_event_delay "$high_delay")"
  fi

  event_log_init "$event_file"
  clear_policer

  case "$event_kind" in
    loss_spike)
      setup_shapers "$BASE_RATE" "$active_delay" "0%"
      event_log "$event_file" "start,${BASE_RATE},${active_delay},0%,,"
      metadata_delay="$active_delay"
      metadata_loss="dynamic:${SUDDEN_LOSS}"
      (
        sleep "$EVENT_AT"
        change_shapers "$BASE_RATE" "$active_delay" "$SUDDEN_LOSS"
        event_log "$event_file" "loss_spike,${BASE_RATE},${active_delay},${SUDDEN_LOSS},,"
        sleep "$EVENT_HOLD"
        change_shapers "$BASE_RATE" "$active_delay" "0%"
        event_log "$event_file" "recover_loss,${BASE_RATE},${active_delay},0%,,"
      ) &
      ;;
    latency_spike)
      setup_shapers "$BASE_RATE" "$active_delay" "0%"
      event_log "$event_file" "start,${BASE_RATE},${active_delay},0%,,"
      metadata_delay="dynamic:${active_delay}->${high_delay}->${active_delay}"
      metadata_loss="0%"
      (
        sleep "$EVENT_AT"
        change_shapers "$BASE_RATE" "$high_delay" "0%"
        event_log "$event_file" "latency_spike,${BASE_RATE},${high_delay},0%,,"
        sleep "$EVENT_HOLD"
        change_shapers "$BASE_RATE" "$active_delay" "0%"
        event_log "$event_file" "latency_restore,${BASE_RATE},${active_delay},0%,,"
      ) &
      ;;
    latency_reduction)
      setup_shapers "$BASE_RATE" "$high_delay" "0%"
      event_log "$event_file" "start_high_latency,${BASE_RATE},${high_delay},0%,,"
      metadata_delay="dynamic:${high_delay}->${active_delay}->${high_delay}"
      metadata_loss="0%"
      (
        sleep "$EVENT_AT"
        change_shapers "$BASE_RATE" "$active_delay" "0%"
        event_log "$event_file" "latency_reduction,${BASE_RATE},${active_delay},0%,,"
        sleep "$EVENT_HOLD"
        change_shapers "$BASE_RATE" "$high_delay" "0%"
        event_log "$event_file" "latency_restore_high,${BASE_RATE},${high_delay},0%,,"
      ) &
      ;;
    capacity_drop)
      setup_shapers "$BASE_RATE" "$active_delay" "0%"
      event_log "$event_file" "start,${BASE_RATE},${active_delay},0%,,"
      metadata_delay="$active_delay"
      metadata_rate="dynamic:${BASE_RATE}->${DROP_RATE}->${BASE_RATE}"
      metadata_loss="0%"
      (
        sleep "$EVENT_AT"
        change_shapers "$DROP_RATE" "$active_delay" "0%"
        event_log "$event_file" "capacity_drop,${DROP_RATE},${active_delay},0%,,"
        sleep "$EVENT_HOLD"
        change_shapers "$BASE_RATE" "$active_delay" "0%"
        event_log "$event_file" "capacity_restore,${BASE_RATE},${active_delay},0%,,"
      ) &
      ;;
    policer_spike)
      setup_shapers "$BASE_RATE" "$active_delay" "0%"
      event_log "$event_file" "start_no_policer,${BASE_RATE},${active_delay},0%,,"
      metadata_delay="$active_delay"
      metadata_loss="0%"
      metadata_policer="dynamic:${POLICE_RATE}"
      (
        sleep "$EVENT_AT"
        enable_ingress_policer "$POLICE_RATE" "$POLICE_BURST" "$POLICE_MTU" "$POLICE_MATCH_DST"
        event_log "$event_file" "enable_policer,${BASE_RATE},${active_delay},0%,${POLICE_RATE},${POLICE_BURST}"
        sleep "$EVENT_HOLD"
        clear_policer
        event_log "$event_file" "disable_policer,${BASE_RATE},${active_delay},0%,,"
      ) &
      ;;
    *)
      die "Unknown dynamic event kind: $event_kind"
      ;;
  esac
  local changer_pid=$!

  run_single_test "$scenario" primary "$algo" "$repeat" "$duration" 1 "$port" dynamic "$flow_group" "" "$metadata_delay" "$metadata_rate" "$metadata_loss" "$metadata_policer"
  wait "$changer_pid" 2>/dev/null || true
  clear_policer
}

run_latency_sweep() {
  local algo="$1"
  local repeat="$2"
  local delay label group

  for delay in $LATENCY_SWEEP_DELAYS; do
    label="latency_sweep__oneway_${delay}"
    if rate_label_enabled; then
      label="${label}__rate_$(safe_name "$(current_rate)")"
    fi
    group="$(safe_name "latency_sweep_${delay}_$(current_rate)_${algo}_r${repeat}")"
    clear_policer
    setup_shapers "$BASE_RATE" "$delay" "0%"
    run_single_test "$label" primary "$algo" "$repeat" "$(duration_for_base_delay "$delay")" 1 "$BASE_PORT" latency_sweep "$group" "" "$delay" "$BASE_RATE" "0%" ""
  done
}

run_all_algo_fairness_impairment() {
  local repeat="$1"
  local scenario_base="$2"
  local impairment="${3:-clean}"
  local active_delay duration total_flows flows_per_algo variant flow_group case_label event_file ss_file tc_file
  local competition_event_at competition_event_hold competition_drop_rate
  active_delay="$(current_delay)"
  duration="$(duration_for_competition_fairness)"
  read -r competition_event_at competition_event_hold < <(competition_impairment_window "$duration")
  competition_drop_rate="${COMPETITION_DROP_RATE:-$DROP_RATE}"

  local -a compete_algos=()
  mapfile -t compete_algos < <(competition_algo_list)
  ((${#compete_algos[@]})) || die "No congestion-control algorithms selected for all-algorithm fairness competition"
  is_positive_integer "$COMPETITION_FLOWS_PER_ALGO" || die "COMPETITION_FLOWS_PER_ALGO must be a positive integer"
  flows_per_algo=$((10#$COMPETITION_FLOWS_PER_ALGO))
  total_flows=$(( ${#compete_algos[@]} * flows_per_algo ))
  if (( total_flows > SERVER_COUNT )); then
    die "${scenario_base} all-algorithm competition needs SERVER_COUNT>=${total_flows}; current SERVER_COUNT=${SERVER_COUNT}"
  fi
  if (( total_flows < 2 )); then
    log "${scenario_base}: only one selected algorithm/flow is available; running the single participant for completeness."
  fi

  local port_base
  allocate_port_block port_base "$total_flows"

  local algos_label peer_label
  algos_label="$(competition_algo_label "${compete_algos[@]}")"
  peer_label="$(competition_peer_label "${compete_algos[@]}")"
  variant="all_algos_${impairment}"
  case_label="${scenario_base}__all_algos_${algos_label}_P${total_flows}"
  flow_group="${case_label}_r${repeat}"
  event_file="${EVENTS_RAW_DIR}/$(safe_name "$flow_group").csv"
  ss_file="${SS_DIR}/$(safe_name "$flow_group").sslog"
  tc_file="${TC_DIR}/$(safe_name "$flow_group").tc"

  local metadata_delay="$active_delay" metadata_rate="$BASE_RATE" metadata_loss="0%" metadata_policer=""
  local changer_pid="" old_ack_rate old_ack_loss old_ack_delay old_ack_queue old_data_extra old_ack_extra old_queue_profile
  old_ack_rate="$ACTIVE_ACK_RATE"
  old_ack_loss="$ACTIVE_ACK_LOSS"
  old_ack_delay="$ACTIVE_ACK_DELAY"
  old_ack_queue="$ACTIVE_ACK_QUEUE_PROFILE"
  old_data_extra="$ACTIVE_DATA_DELAY_EXTRA"
  old_ack_extra="$ACTIVE_ACK_DELAY_EXTRA"
  old_queue_profile="$ACTIVE_QUEUE_PROFILE"

  clear_policer
  reset_ack_impairment
  reset_data_delay_extra
  set_active_queue_profile "$QUEUE_PROFILE"
  event_log_init "$event_file"

  case "$impairment" in
    clean)
      setup_shapers "$BASE_RATE" "$active_delay" "0%"
      event_log "$event_file" "all_algos_start_clean,${BASE_RATE},${active_delay},0%,,,phase=competition;algos=${algos_label};flows=${total_flows};duration=${duration}s;receiver=${COMPETITION_RECEIVER_RATE};event_at=${competition_event_at};event_hold=${competition_event_hold};drop_rate=${competition_drop_rate}"
      ;;
    sustain_loss)
      setup_sustain_loss_shapers "$BASE_RATE" "$active_delay"
      metadata_loss="$(sustain_loss_label)"
      event_log "$event_file" "all_algos_start_sustain_loss,${BASE_RATE},${active_delay},$(sustain_loss_label),,,phase=competition;algos=${algos_label};flows=${total_flows};duration=${duration}s;receiver=${COMPETITION_RECEIVER_RATE};event_at=${competition_event_at};event_hold=${competition_event_hold};drop_rate=${competition_drop_rate}"
      ;;
    loss_spike)
      setup_shapers "$BASE_RATE" "$active_delay" "0%"
      metadata_loss="dynamic:${SUDDEN_LOSS}"
      event_log "$event_file" "all_algos_start_clean_then_loss_spike,${BASE_RATE},${active_delay},0%,,,phase=competition;algos=${algos_label};flows=${total_flows};duration=${duration}s;receiver=${COMPETITION_RECEIVER_RATE};event_at=${competition_event_at};event_hold=${competition_event_hold};drop_rate=${competition_drop_rate}"
      (
        sleep "$competition_event_at"
        change_shapers "$BASE_RATE" "$active_delay" "$SUDDEN_LOSS"
        event_log "$event_file" "loss_spike,${BASE_RATE},${active_delay},${SUDDEN_LOSS},,,phase=loss_spike"
        sleep "$competition_event_hold"
        change_shapers "$BASE_RATE" "$active_delay" "0%"
        event_log "$event_file" "loss_recovery,${BASE_RATE},${active_delay},0%,,,phase=loss_recovery"
      ) & changer_pid=$!
      ;;
    latency_spike)
      setup_shapers "$BASE_RATE" "$active_delay" "0%"
      metadata_delay="dynamic:${active_delay}->${HIGH_DELAY}->${active_delay}"
      event_log "$event_file" "all_algos_start_clean_then_latency_spike,${BASE_RATE},${active_delay},0%,,,phase=competition;algos=${algos_label};flows=${total_flows};duration=${duration}s;receiver=${COMPETITION_RECEIVER_RATE};event_at=${competition_event_at};event_hold=${competition_event_hold};drop_rate=${competition_drop_rate}"
      (
        sleep "$competition_event_at"
        change_shapers "$BASE_RATE" "$HIGH_DELAY" "0%"
        event_log "$event_file" "latency_spike,${BASE_RATE},${HIGH_DELAY},0%,,,phase=latency_spike"
        sleep "$competition_event_hold"
        change_shapers "$BASE_RATE" "$active_delay" "0%"
        event_log "$event_file" "latency_recovery,${BASE_RATE},${active_delay},0%,,,phase=latency_recovery"
      ) & changer_pid=$!
      ;;
    capacity_drop)
      setup_shapers "$BASE_RATE" "$active_delay" "0%"
      metadata_rate="dynamic:${BASE_RATE}->${competition_drop_rate}->${BASE_RATE}"
      event_log "$event_file" "all_algos_start_clean_then_capacity_drop,${BASE_RATE},${active_delay},0%,,,phase=competition;algos=${algos_label};flows=${total_flows};duration=${duration}s;receiver=${COMPETITION_RECEIVER_RATE};event_at=${competition_event_at};event_hold=${competition_event_hold};drop_rate=${competition_drop_rate}"
      (
        sleep "$competition_event_at"
        change_shapers "$competition_drop_rate" "$active_delay" "0%"
        event_log "$event_file" "capacity_drop,${competition_drop_rate},${active_delay},0%,,,phase=capacity_drop"
        sleep "$competition_event_hold"
        change_shapers "$BASE_RATE" "$active_delay" "0%"
        event_log "$event_file" "capacity_recovery,${BASE_RATE},${active_delay},0%,,,phase=capacity_recovery"
      ) & changer_pid=$!
      ;;
    policer)
      setup_shapers "$BASE_RATE" "$active_delay" "0%"
      metadata_policer="dynamic:${POLICE_RATE}"
      event_log "$event_file" "all_algos_start_clean_then_policer,${BASE_RATE},${active_delay},0%,,,phase=competition;algos=${algos_label};flows=${total_flows};duration=${duration}s;receiver=${COMPETITION_RECEIVER_RATE};event_at=${competition_event_at};event_hold=${competition_event_hold};drop_rate=${competition_drop_rate}"
      (
        sleep "$competition_event_at"
        enable_ingress_policer "$POLICE_RATE" "$POLICE_BURST" "$POLICE_MTU" "$POLICE_MATCH_DST"
        event_log "$event_file" "policer_enable,${BASE_RATE},${active_delay},0%,${POLICE_RATE},${POLICE_BURST},phase=policer"
        sleep "$competition_event_hold"
        clear_policer
        event_log "$event_file" "policer_disable,${BASE_RATE},${active_delay},0%,,,phase=policer_recovery"
      ) & changer_pid=$!
      ;;
    ack_limit)
      set_ack_impairment "$ACK_LIMIT_RATE" "" "0%" "$QUEUE_PROFILE"
      setup_shapers "$BASE_RATE" "$active_delay" "0%"
      metadata_policer="ack_rate:${ACK_LIMIT_RATE}"
      event_log "$event_file" "all_algos_ack_rate_limited,${BASE_RATE},${active_delay},0%,,,phase=ack_limit;ack_rate=${ACK_LIMIT_RATE};algos=${algos_label};flows=${total_flows};duration=${duration}s;receiver=${COMPETITION_RECEIVER_RATE};event_at=${competition_event_at};event_hold=${competition_event_hold};drop_rate=${competition_drop_rate}"
      ;;
    jitter)
      set_data_delay_extra "80ms 75% distribution paretonormal"
      setup_shapers "$BASE_RATE" "$active_delay" "0%"
      metadata_delay="${active_delay}+jitter:80ms_75%_paretonormal"
      event_log "$event_file" "all_algos_jitter,${BASE_RATE},${active_delay},0%,,,phase=jitter;jitter=80ms_75%_paretonormal;algos=${algos_label};flows=${total_flows};duration=${duration}s;receiver=${COMPETITION_RECEIVER_RATE};event_at=${competition_event_at};event_hold=${competition_event_hold};drop_rate=${competition_drop_rate}"
      ;;
    reorder)
      local fairness_reorder_spec="reorder 1% 25%"
      setup_shapers "$BASE_RATE" "$active_delay" "$fairness_reorder_spec"
      metadata_loss="$fairness_reorder_spec"
      event_log "$event_file" "all_algos_reorder,${BASE_RATE},${active_delay},${fairness_reorder_spec},,,phase=reorder;algos=${algos_label};flows=${total_flows};duration=${duration}s;receiver=${COMPETITION_RECEIVER_RATE};event_at=${competition_event_at};event_hold=${competition_event_hold};drop_rate=${competition_drop_rate}"
      ;;
    *)
      die "Unknown all-algorithm fairness impairment: ${impairment}"
      ;;
  esac

  flush_tcp_metrics
  local ss_pid
  ss_pid="$(start_ss_logger "$ss_file" "$duration")"

  local -a pids jsons stderrs algos roles rcs
  local idx=0 algo_idx flow_copy port flow_algo role tag peer
  set +e
  for algo_idx in "${!compete_algos[@]}"; do
    flow_algo="${compete_algos[$algo_idx]}"
    for ((flow_copy=1; flow_copy<=flows_per_algo; flow_copy++)); do
      port=$((port_base + idx))
      if (( idx == 0 )); then
        role="primary"
      else
        role="competitor${idx}"
      fi
      if (( flows_per_algo > 1 )); then
        role="${role}_flow${flow_copy}"
      fi
      tag="$(safe_name "${case_label}_${role}_${flow_algo}_r${repeat}_p${port}")"
      jsons[$idx]="${JSON_DIR}/${tag}.json"
      stderrs[$idx]="${STDERR_DIR}/${tag}.stderr"
      algos[$idx]="$flow_algo"
      roles[$idx]="$role"
      run_iperf_capture "${jsons[$idx]}" "${stderrs[$idx]}" "$flow_algo" "$duration" 1 "$port" upload &
      pids[$idx]=$!
      idx=$((idx + 1))
    done
  done

  for ((idx=0; idx<total_flows; idx++)); do
    wait "${pids[$idx]}"
    rcs[$idx]=$?
  done
  set -e

  [[ -n "$changer_pid" ]] && wait "$changer_pid" 2>/dev/null || true
  kill "$ss_pid" 2>/dev/null || true
  wait "$ss_pid" 2>/dev/null || true
  event_log "$event_file" "all_algos_competition_end,${BASE_RATE},${active_delay},${metadata_loss},${metadata_policer},,phase=end;algos=${algos_label};flows=${total_flows};duration=${duration}s;receiver=${COMPETITION_RECEIVER_RATE};event_at=${competition_event_at};event_hold=${competition_event_hold};drop_rate=${competition_drop_rate}"
  capture_tc_state "$tc_file"

  for ((idx=0; idx<total_flows; idx++)); do
    peer="$peer_label"
    append_json_results "${jsons[$idx]}" "$case_label" "${roles[$idx]}" "${algos[$idx]}" "$repeat" "$total_flows" "$duration" "${rcs[$idx]}" "${stderrs[$idx]}" \
      "$variant" "$flow_group" "$peer" "$metadata_delay" "$metadata_rate" "$metadata_loss" "$metadata_policer" "0" "$ss_file" "$tc_file"
  done

  ACTIVE_ACK_RATE="$old_ack_rate"
  ACTIVE_ACK_LOSS="$old_ack_loss"
  ACTIVE_ACK_DELAY="$old_ack_delay"
  ACTIVE_ACK_QUEUE_PROFILE="$old_ack_queue"
  ACTIVE_DATA_DELAY_EXTRA="$old_data_extra"
  ACTIVE_ACK_DELAY_EXTRA="$old_ack_extra"
  ACTIVE_QUEUE_PROFILE="$old_queue_profile"
  reset_ack_impairment
  reset_data_delay_extra
  clear_policer
  set_active_queue_profile "$QUEUE_PROFILE"
  setup_shapers "$BASE_RATE" "$active_delay" "0%" 2>/dev/null || true
  if [[ -n "$POST_IMPAIRMENT_SETTLE" && "$POST_IMPAIRMENT_SETTLE" != "0" ]]; then
    sleep "$POST_IMPAIRMENT_SETTLE"
  fi
}

run_combined_all_test() {
  local scenario_base="combined_all"
  local primary_algo="$1"
  local repeat="$2"
  local competitor_algo="$3"
  local -a latencies
  read -r -a latencies <<< "$COMBINED_LATENCY_LADDER"
  ((${#latencies[@]})) || latencies=("$ONEWAY_DELAY")

  is_positive_integer "$COMBINED_PHASE_SECONDS" || die "COMBINED_PHASE_SECONDS must be a positive integer number of seconds"
  local phase="$COMBINED_PHASE_SECONDS"
  local include_extended=0 enable_rtt=0
  case "$COMBINED_INCLUDE_EXTENDED_PHASES" in 1|yes|true|on) include_extended=1 ;; esac
  case "$COMBINED_ENABLE_RTT_PROBE" in 1|yes|true|on) enable_rtt=1 ;; esac
  if (( include_extended == 1 )); then
    is_positive_integer "$COMBINED_ADAPTIVE_POLICER_PHASES" || die "COMBINED_ADAPTIVE_POLICER_PHASES must be a positive integer"
  fi

  # Base schedule: clean baseline, latency ladder, loss variants, capacity drop,
  # static policer, new competitor, multi-flow competitors, and recovery. The
  # extended schedule adds jitter/reorder, ACK-path pressure, bufferbloat/SQM,
  # and adaptive policer phases before the original competition/recovery stages.
  local base_phase_count=$(( ${#latencies[@]} + 10 ))
  local extended_phase_count=0
  if (( include_extended == 1 )); then
    # jitter, long-tail jitter, reordering, ACK rate/loss, ACK delay spike,
    # bufferbloat queue, plus the adaptive policer window.
    extended_phase_count=$(( 6 + COMBINED_ADAPTIVE_POLICER_PHASES ))
  fi
  local minimum_duration=$(( (base_phase_count + extended_phase_count) * phase ))
  local duration
  if [[ "$COMBINED_DURATION" == "0" || "$COMBINED_DURATION" == "auto" ]]; then
    duration="$minimum_duration"
  else
    is_positive_integer "$COMBINED_DURATION" || die "COMBINED_DURATION must be 0, auto, or a positive integer number of seconds"
    duration="$COMBINED_DURATION"
    if (( duration < minimum_duration )); then
      log "COMBINED_DURATION=${duration}s is shorter than the combined schedule; using ${minimum_duration}s."
      duration="$minimum_duration"
    fi
  fi

  local total_flows
  total_flows="$(effective_combined_total_flows)"
  if (( total_flows < 2 )); then
    total_flows=2
  fi
  if (( total_flows > SERVER_COUNT )); then
    die "combined_all needs SERVER_COUNT>=${total_flows}; current SERVER_COUNT=${SERVER_COUNT}"
  fi
  local port_base
  allocate_port_block port_base "$total_flows"

  local variant case_label flow_group case_tag event_file ss_file tc_file
  variant="$(variant_for_pair "$primary_algo" "$competitor_algo")"
  local rate_suffix=""
  if rate_label_enabled; then
    rate_suffix="__rate_$(safe_name "$(current_rate)")"
  fi
  case_label="${scenario_base}${rate_suffix}__${primary_algo}_vs_${competitor_algo}_P${total_flows}"
  flow_group="${case_label}_r${repeat}"
  case_tag="$(safe_name "$flow_group")"
  event_file="${EVENTS_RAW_DIR}/${case_tag}.csv"
  ss_file="${SS_DIR}/${case_tag}.sslog"
  tc_file="${TC_DIR}/${case_tag}.tc"

  local combined_queue_label combined_delay_label combined_rate_label
  combined_queue_label="dynamic:${QUEUE_PROFILE}->${COMBINED_BUFFERBLOAT_QUEUE_PROFILE}->${COMBINED_RECOVERY_QUEUE_PROFILE}->${QUEUE_PROFILE}"
  combined_delay_label="dynamic:${ONEWAY_DELAY}->${COMBINED_LATENCY_LADDER}->jitter/reorder->${LOW_DELAY}->${ONEWAY_DELAY}"
  combined_rate_label="dynamic:data:${BASE_RATE}->${DROP_RATE}->${BASE_RATE};ack:${ACK_RATE}->${COMBINED_ACK_LIMIT_RATE}->${ACK_RATE}"

  reset_ack_impairment
  reset_data_delay_extra
  set_active_queue_profile "$QUEUE_PROFILE"
  clear_policer
  setup_shapers "$BASE_RATE" "$ONEWAY_DELAY" "0%"
  event_log_init "$event_file"
  event_log "$event_file" "start_clean_baseline,${BASE_RATE},${ONEWAY_DELAY},0%,,,phase=clean_start;queue=${QUEUE_PROFILE}"

  local idle_ping load_ping recovery_ping ping_pid load_ping_pid=""
  idle_ping="${PINGS_RAW_DIR}/${case_tag}_combined_idle.ping"
  load_ping="${PINGS_RAW_DIR}/${case_tag}_combined_loaded.ping"
  recovery_ping="${PINGS_RAW_DIR}/${case_tag}_combined_recovery.ping"
  if (( enable_rtt == 1 )); then
    start_ping_probe ping_pid "$idle_ping" "$BB_IDLE_SECONDS"
    wait "$ping_pid" 2>/dev/null || true
    append_ping_results "$idle_ping" "$case_label" "combined_all" "$flow_group" idle probe "$primary_algo" "$combined_queue_label" combined_all "$combined_delay_label" "$combined_rate_label" "$repeat"
  fi

  flush_tcp_metrics
  local ss_pid
  ss_pid="$(start_ss_logger "$ss_file" "$duration")"

  local -a pids jsons stderrs algos roles durations start_offsets rcs
  local idx port tag peer remaining current_delay t controller_pid controller_window controller_extra_sleep
  current_delay="$ONEWAY_DELAY"
  t=0

  tag="$(safe_name "${case_label}_primary_${primary_algo}_r${repeat}_p${port_base}")"
  jsons[0]="${JSON_DIR}/${tag}.json"
  stderrs[0]="${STDERR_DIR}/${tag}.stderr"
  algos[0]="$primary_algo"
  roles[0]="primary"
  durations[0]="$duration"
  start_offsets[0]=0

  set +e
  run_iperf_capture "${jsons[0]}" "${stderrs[0]}" "$primary_algo" "$duration" 1 "$port_base" &
  pids[0]=$!
  set -e

  if (( enable_rtt == 1 )); then
    start_ping_probe load_ping_pid "$load_ping" "$duration"
  fi

  sleep "$phase"; t=$((t + phase))

  # 1) Clean RTT ladder: exercise BDP/ramp behavior without loss.
  for current_delay in "${latencies[@]}"; do
    reset_data_delay_extra
    change_shapers "$BASE_RATE" "$current_delay" "0%"
    event_log "$event_file" "latency_ladder_${current_delay},${BASE_RATE},${current_delay},0%,,,phase=latency_ladder"
    sleep "$phase"; t=$((t + phase))
  done

  if (( include_extended == 1 )); then
    # 2) Radio/Wi-Fi-like variability: jitter, long-tail jitter, then mild reordering.
    ACTIVE_DATA_DELAY_EXTRA="$COMBINED_JITTER_EXTRA"
    change_shapers "$BASE_RATE" "$current_delay" "0%"
    event_log "$event_file" "jitter_normal,${BASE_RATE},${current_delay},0%,,,phase=jitter;extra=${COMBINED_JITTER_EXTRA}"
    sleep "$phase"; t=$((t + phase))

    ACTIVE_DATA_DELAY_EXTRA="$COMBINED_LONG_TAIL_EXTRA"
    change_shapers "$BASE_RATE" "$current_delay" "0%"
    event_log "$event_file" "jitter_long_tail,${BASE_RATE},${current_delay},0%,,,phase=jitter_long_tail;extra=${COMBINED_LONG_TAIL_EXTRA}"
    sleep "$phase"; t=$((t + phase))

    ACTIVE_DATA_DELAY_EXTRA="$COMBINED_REORDER_EXTRA"
    change_shapers "$BASE_RATE" "$current_delay" "0%"
    event_log "$event_file" "packet_reordering,${BASE_RATE},${current_delay},0%,,,phase=reorder;extra=${COMBINED_REORDER_EXTRA}"
    sleep "$phase"; t=$((t + phase))

    # 3) Reverse/ACK-path stress: ACK bottleneck, ACK loss, and ACK delay spike.
    reset_data_delay_extra
    set_ack_impairment "$COMBINED_ACK_LIMIT_RATE" "$current_delay" "$COMBINED_ACK_LOSS_RATE" "$QUEUE_PROFILE"
    change_shapers "$BASE_RATE" "$current_delay" "0%"
    event_log "$event_file" "ack_rate_limit_and_loss,${BASE_RATE},${current_delay},0%,,,phase=ack_path;ack_rate=${COMBINED_ACK_LIMIT_RATE};ack_loss=${COMBINED_ACK_LOSS_RATE}"
    sleep "$phase"; t=$((t + phase))

    set_ack_impairment "$COMBINED_ACK_LIMIT_RATE" "$COMBINED_ACK_DELAY" "$COMBINED_ACK_LOSS_RATE" "$QUEUE_PROFILE"
    change_shapers "$BASE_RATE" "$current_delay" "0%"
    event_log "$event_file" "ack_delay_spike,${BASE_RATE},${current_delay},0%,,,phase=ack_delay_spike;ack_rate=${COMBINED_ACK_LIMIT_RATE};ack_delay=${COMBINED_ACK_DELAY};ack_loss=${COMBINED_ACK_LOSS_RATE}"
    sleep "$phase"; t=$((t + phase))

    # 4) Bufferbloat: switch to a deep FIFO on both directions while the long
    # flow is active. RTT probes are tagged by primary congestion algorithm.
    set_active_queue_profile "$COMBINED_BUFFERBLOAT_QUEUE_PROFILE"
    set_ack_impairment "$COMBINED_ACK_LIMIT_RATE" "$COMBINED_ACK_DELAY" "$COMBINED_ACK_LOSS_RATE" "$COMBINED_BUFFERBLOAT_QUEUE_PROFILE"
    change_shapers "$BASE_RATE" "$current_delay" "0%"
    event_log "$event_file" "bufferbloat_deep_fifo_under_load,${BASE_RATE},${current_delay},0%,,,phase=bufferbloat;queue=${COMBINED_BUFFERBLOAT_QUEUE_PROFILE};ack_rate=${COMBINED_ACK_LIMIT_RATE};ack_delay=${COMBINED_ACK_DELAY}"
    sleep "$phase"; t=$((t + phase))
  fi

  # 5) Forward/reverse sustained-loss progression, matching benchmark.sh.
  change_sustain_loss_shapers "$BASE_RATE" "$current_delay"
  event_log "$event_file" "sustain_loss,${BASE_RATE},${current_delay},$(sustain_loss_label),,,phase=sustain_loss"
  sleep "$phase"; t=$((t + phase))

  change_shapers "$BASE_RATE" "$current_delay" "$SUDDEN_LOSS"
  event_log "$event_file" "sudden_heavy_loss,${BASE_RATE},${current_delay},${SUDDEN_LOSS},,,phase=loss_spike"
  sleep "$phase"; t=$((t + phase))

  change_shapers "$BASE_RATE" "$current_delay" "$COMBINED_NETEM_LOSS_SPEC"
  event_log "$event_file" "bursty_or_correlated_loss,${BASE_RATE},${current_delay},${COMBINED_NETEM_LOSS_SPEC},,,phase=loss_bursts"
  sleep "$phase"; t=$((t + phase))

  # 6) Capacity collapse while previous path problems remain active.
  change_sustain_loss_shapers "$DROP_RATE" "$current_delay"
  event_log "$event_file" "capacity_drop_plus_sustain_loss,${DROP_RATE},${current_delay},$(sustain_loss_label),,,phase=capacity_drop"
  sleep "$phase"; t=$((t + phase))

  # 7) Adaptive policer feedback-loop test: trigger retransmissions, enable a
  # controller, then release the trigger loss while the controller decides when
  # to release the policer. This is a stress model, not a pure dumb policer.
  if (( include_extended == 1 )); then
    clear_policer
    controller_window=$((phase * COMBINED_ADAPTIVE_POLICER_PHASES))
    change_shapers "$BASE_RATE" "$current_delay" "$ADAPTIVE_POLICER_TRIGGER_LOSS"
    event_log "$event_file" "adaptive_policer_feedback_trigger_loss_start,${BASE_RATE},${current_delay},${ADAPTIVE_POLICER_TRIGGER_LOSS},,,phase=adaptive_policer;mode=${COMBINED_ADAPTIVE_POLICER_MODE};window=${controller_window}s"
    adaptive_policer_controller "$event_file" "$controller_window" "$COMBINED_ADAPTIVE_POLICER_MODE" "$current_delay" &
    controller_pid=$!
    sleep "$phase"; t=$((t + phase))
    change_shapers "$BASE_RATE" "$current_delay" "0%"
    event_log "$event_file" "adaptive_policer_feedback_trigger_loss_released,${BASE_RATE},${current_delay},0%,,,phase=adaptive_policer;mode=${COMBINED_ADAPTIVE_POLICER_MODE}"
    controller_extra_sleep=$(( (COMBINED_ADAPTIVE_POLICER_PHASES - 1) * phase ))
    if (( controller_extra_sleep > 0 )); then
      sleep "$controller_extra_sleep"; t=$((t + controller_extra_sleep))
    fi
    kill "$controller_pid" 2>/dev/null || true
    wait "$controller_pid" 2>/dev/null || true
    clear_policer
  fi

  # 8) Static policer/rate-contract phase.
  change_sustain_loss_shapers "$DROP_RATE" "$current_delay"
  enable_ingress_policer "$POLICE_RATE" "$POLICE_BURST" "$POLICE_MTU" "$POLICE_MATCH_DST"
  event_log "$event_file" "static_policer_enable,${DROP_RATE},${current_delay},$(sustain_loss_label),${POLICE_RATE},${POLICE_BURST},phase=static_policer"
  sleep "$phase"; t=$((t + phase))

  # 9) New competitor starts under degraded conditions.
  idx=1
  remaining=$((duration - t))
  (( remaining < 1 )) && remaining=1
  port=$((port_base + idx))
  tag="$(safe_name "${case_label}_competitor_new_${competitor_algo}_r${repeat}_p${port}")"
  jsons[$idx]="${JSON_DIR}/${tag}.json"
  stderrs[$idx]="${STDERR_DIR}/${tag}.stderr"
  algos[$idx]="$competitor_algo"
  roles[$idx]="competitor_new"
  durations[$idx]="$remaining"
  start_offsets[$idx]="$t"
  event_log "$event_file" "competition_new_flow_start_${competitor_algo},${DROP_RATE},${current_delay},$(sustain_loss_label),${POLICE_RATE},${POLICE_BURST},phase=competition_new_flow"
  set +e
  run_iperf_capture "${jsons[$idx]}" "${stderrs[$idx]}" "$competitor_algo" "$remaining" 1 "$port" &
  pids[$idx]=$!
  set -e
  sleep "$phase"; t=$((t + phase))

  # 10) Multi-flow phase: add the rest of the competitor flows.
  if (( total_flows > 2 )); then
    event_log "$event_file" "flow_fairness_competitors_start_${competitor_algo}_additional_$((total_flows - 2)),${DROP_RATE},${current_delay},$(sustain_loss_label),${POLICE_RATE},${POLICE_BURST},phase=flow_fairness_parallel_extra"
    set +e
    for ((idx=2; idx<total_flows; idx++)); do
      remaining=$((duration - t))
      (( remaining < 1 )) && remaining=1
      port=$((port_base + idx))
      tag="$(safe_name "${case_label}_competitor_multi${idx}_${competitor_algo}_r${repeat}_p${port}")"
      jsons[$idx]="${JSON_DIR}/${tag}.json"
      stderrs[$idx]="${STDERR_DIR}/${tag}.stderr"
      algos[$idx]="$competitor_algo"
      roles[$idx]="competitor_multi${idx}"
      durations[$idx]="$remaining"
      start_offsets[$idx]="$t"
      run_iperf_capture "${jsons[$idx]}" "${stderrs[$idx]}" "$competitor_algo" "$remaining" 1 "$port" &
      pids[$idx]=$!
    done
    set -e
  else
    event_log "$event_file" "flow_fairness_phase_no_extra_competitors,${DROP_RATE},${current_delay},$(sustain_loss_label),${POLICE_RATE},${POLICE_BURST},phase=flow_fairness_parallel_extra"
  fi
  sleep "$phase"; t=$((t + phase))

  # 11) Recovery: remove policing/ACK pressure, move to low latency, then test
  # SQM-style recovery before returning to the configured queue profile.
  clear_policer
  reset_ack_impairment
  reset_data_delay_extra
  current_delay="$LOW_DELAY"
  set_active_queue_profile "$COMBINED_RECOVERY_QUEUE_PROFILE"
  change_shapers "$BASE_RATE" "$current_delay" "0%"
  event_log "$event_file" "recover_low_latency_sqm,${BASE_RATE},${current_delay},0%,,,phase=recovery_sqm;queue=${COMBINED_RECOVERY_QUEUE_PROFILE}"
  sleep "$phase"; t=$((t + phase))

  current_delay="$ONEWAY_DELAY"
  set_active_queue_profile "$QUEUE_PROFILE"
  change_shapers "$BASE_RATE" "$current_delay" "0%"
  event_log "$event_file" "restore_baseline_latency_and_queue,${BASE_RATE},${current_delay},0%,,,phase=final_recovery;queue=${QUEUE_PROFILE}"
  sleep "$phase"; t=$((t + phase))

  remaining=$((duration - t))
  if (( remaining > 0 )); then
    sleep "$remaining"
  fi

  set +e
  for ((idx=0; idx<total_flows; idx++)); do
    wait "${pids[$idx]}"
    rcs[$idx]=$?
  done
  set -e

  if [[ -n "$load_ping_pid" ]]; then
    wait "$load_ping_pid" 2>/dev/null || true
    append_ping_results "$load_ping" "$case_label" "combined_all" "$flow_group" loaded probe "$primary_algo" "$combined_queue_label" combined_all "$combined_delay_label" "$combined_rate_label" "$repeat"
  fi

  event_log "$event_file" "combined_end,${BASE_RATE},${ONEWAY_DELAY},0%,,,phase=end"
  clear_policer
  reset_ack_impairment
  reset_data_delay_extra
  set_active_queue_profile "$QUEUE_PROFILE"
  change_shapers "$BASE_RATE" "$ONEWAY_DELAY" "0%" 2>/dev/null || true
  kill "$ss_pid" 2>/dev/null || true
  wait "$ss_pid" 2>/dev/null || true

  if (( enable_rtt == 1 )); then
    start_ping_probe ping_pid "$recovery_ping" "$BB_RECOVERY_SECONDS"
    wait "$ping_pid" 2>/dev/null || true
    append_ping_results "$recovery_ping" "$case_label" "combined_all" "$flow_group" recovery probe "$primary_algo" "$combined_queue_label" combined_all "$combined_delay_label" "$combined_rate_label" "$repeat"
  fi

  capture_tc_state "$tc_file"

  for ((idx=0; idx<total_flows; idx++)); do
    if [[ "${roles[$idx]}" == "primary" ]]; then
      peer="$competitor_algo"
    else
      peer="$primary_algo"
    fi
    append_json_results "${jsons[$idx]}" "$case_label" "${roles[$idx]}" "${algos[$idx]}" "$repeat" "$total_flows" "${durations[$idx]}" "${rcs[$idx]}" "${stderrs[$idx]}" \
      "$variant" "$flow_group" "$peer" "$combined_delay_label" "$combined_rate_label" "dynamic:sustain_loss=$(sustain_loss_label);spike=${SUDDEN_LOSS};bursts=${COMBINED_NETEM_LOSS_SPEC};adaptive_trigger=${ADAPTIVE_POLICER_TRIGGER_LOSS}" "dynamic:adaptive=${COMBINED_ADAPTIVE_POLICER_MODE};static=${POLICE_RATE}" "${start_offsets[$idx]:-0}"
  done
}

router_data_tx_bytes() {
  ip netns exec "$R_NS" cat "/sys/class/net/${R_S_IF}/statistics/tx_bytes" 2>/dev/null || printf '0\n'
}

tcp_retrans_total() {
  ip netns exec "$C_NS" ss -tin dst "$S_IP" 2>/dev/null | awk '
    BEGIN {sum=0}
    {
      for (i=1; i<=NF; i++) {
        tok=$i
        if (tok ~ /^retrans:/) {
          sub(/^retrans:[^/]*\//, "", tok)
          sub(/[^0-9].*$/, "", tok)
          if (tok != "") sum += tok + 0
        } else if (tok ~ /^bytes_retrans:/) {
          sub(/^bytes_retrans:/, "", tok)
          sub(/[^0-9].*$/, "", tok)
          if (tok != "") sum += (tok + 0) / 1500.0
        }
      }
    }
    END {printf "%.0f\n", sum}
  '
}

adaptive_mbps_threshold() {
  local which="$1" value police_mbps
  if [[ "$which" == "high" ]]; then
    value="$ADAPTIVE_POLICER_ENABLE_MBPS"
  else
    value="$ADAPTIVE_POLICER_DISABLE_MBPS"
  fi
  if [[ "$value" != "auto" ]]; then
    printf '%s\n' "$value"
    return
  fi
  police_mbps="$(rate_to_mbps "$POLICE_RATE")"
  if [[ "$which" == "high" ]]; then
    awk -v p="$police_mbps" 'BEGIN {printf "%.6f\n", p * 1.25}'
  else
    awk -v p="$police_mbps" 'BEGIN {printf "%.6f\n", p * 0.80}'
  fi
}

adaptive_policer_controller() {
  local event_file="$1"
  local duration="$2"
  local mode="$3"
  local active_delay="$4"
  local interval="$ADAPTIVE_POLICER_INTERVAL"
  local high low metric_name enabled above below last_change end now last_total total delta metric last_bytes bytes
  is_positive_integer "$interval" || interval=1
  high="$ADAPTIVE_POLICER_ENABLE_RETRANS_PER_SEC"
  low="$ADAPTIVE_POLICER_DISABLE_RETRANS_PER_SEC"
  metric_name="retrans_per_sec"
  if [[ "$mode" == "rate_triggered" ]]; then
    high="$(adaptive_mbps_threshold high)"
    low="$(adaptive_mbps_threshold low)"
    metric_name="measured_mbps"
  fi
  enabled=0
  above=0
  below=0
  last_change=$SECONDS
  end=$((SECONDS + duration))
  last_total="$(tcp_retrans_total)"
  last_bytes="$(router_data_tx_bytes)"
  event_log "$event_file" "adaptive_controller_start_${mode},${BASE_RATE},${active_delay},0%,,,${metric_name},0,high=${high};low=${low}"

  while (( SECONDS < end )); do
    sleep "$interval"
    now=$SECONDS
    if [[ "$mode" == "rate_triggered" ]]; then
      bytes="$(router_data_tx_bytes)"
      delta=$(( bytes - last_bytes ))
      (( delta < 0 )) && delta=0
      metric="$(awk -v d="$delta" -v i="$interval" 'BEGIN {printf "%.6f", (d * 8.0 / i) / 1000000.0}')"
      last_bytes="$bytes"
    else
      total="$(tcp_retrans_total)"
      delta=$(( total - last_total ))
      (( delta < 0 )) && delta=0
      metric="$(awk -v d="$delta" -v i="$interval" 'BEGIN {printf "%.6f", d / i}')"
      last_total="$total"
    fi

    if awk -v m="$metric" -v h="$high" 'BEGIN {exit !(m >= h)}'; then
      above=$((above + 1))
    else
      above=0
    fi
    if awk -v m="$metric" -v l="$low" 'BEGIN {exit !(m <= l)}'; then
      below=$((below + 1))
    else
      below=0
    fi

    if (( enabled == 0 && above >= ADAPTIVE_POLICER_ENABLE_SAMPLES && now - last_change >= ADAPTIVE_POLICER_COOLDOWN )); then
      enable_ingress_policer "$POLICE_RATE" "$POLICE_BURST" "$POLICE_MTU" "$POLICE_MATCH_DST"
      enabled=1
      below=0
      last_change=$now
      event_log "$event_file" "adaptive_policer_enable_${mode},${BASE_RATE},${active_delay},0%,${POLICE_RATE},${POLICE_BURST},${metric_name},${metric},high=${high}"
    elif (( enabled == 1 && below >= ADAPTIVE_POLICER_DISABLE_SAMPLES && now - last_change >= ADAPTIVE_POLICER_MIN_HOLD )); then
      clear_policer
      enabled=0
      above=0
      last_change=$now
      event_log "$event_file" "adaptive_policer_disable_${mode},${BASE_RATE},${active_delay},0%,,,${metric_name},${metric},low=${low}"
    fi
  done
  if (( enabled == 1 )); then
    clear_policer
    event_log "$event_file" "adaptive_policer_final_clear_${mode},${BASE_RATE},${active_delay},0%,,,${metric_name},0,controller_end"
  fi
}

run_adaptive_policer_test() {
  local scenario="$1"
  local algo="$2"
  local repeat="$3"
  local mode="$4"
  local active_delay duration port flow_group event_file changer_pid controller_pid
  active_delay="$(current_delay)"
  if [[ "$ADAPTIVE_POLICER_DURATION" == "0" || "$ADAPTIVE_POLICER_DURATION" == "auto" ]]; then
    duration="$(duration_for_event_delay "$active_delay")"
  else
    duration="$ADAPTIVE_POLICER_DURATION"
  fi
  port="$BASE_PORT"
  flow_group="${scenario}_${algo}_r${repeat}"
  event_file="${EVENTS_RAW_DIR}/$(safe_name "$flow_group").csv"
  event_log_init "$event_file"
  reset_ack_impairment
  set_active_queue_profile "$QUEUE_PROFILE"
  clear_policer
  setup_shapers "$BASE_RATE" "$active_delay" "0%"
  event_log "$event_file" "start_adaptive_policer_${mode},${BASE_RATE},${active_delay},0%,,,"

  changer_pid=""
  if [[ "$mode" == "retrans_feedback" ]]; then
    (
      sleep "$ADAPTIVE_POLICER_TRIGGER_AT"
      change_shapers "$BASE_RATE" "$active_delay" "$ADAPTIVE_POLICER_TRIGGER_LOSS"
      event_log "$event_file" "trigger_loss_for_retrans_feedback,${BASE_RATE},${active_delay},${ADAPTIVE_POLICER_TRIGGER_LOSS},,,"
      sleep "$ADAPTIVE_POLICER_TRIGGER_HOLD"
      change_shapers "$BASE_RATE" "$active_delay" "0%"
      event_log "$event_file" "trigger_loss_released,${BASE_RATE},${active_delay},0%,,,"
    ) &
    changer_pid=$!
  fi

  adaptive_policer_controller "$event_file" "$duration" "$mode" "$active_delay" &
  controller_pid=$!
  run_single_test "$scenario" primary "$algo" "$repeat" "$duration" 1 "$port" "adaptive_policer" "$flow_group" "" "$active_delay" "$BASE_RATE" "adaptive:${mode}" "adaptive:${POLICE_RATE}"
  kill "$controller_pid" 2>/dev/null || true
  wait "$controller_pid" 2>/dev/null || true
  if [[ -n "$changer_pid" ]]; then
    wait "$changer_pid" 2>/dev/null || true
  fi
  clear_policer
}

run_bufferbloat_test() {
  local scenario="$1"
  local algo="$2"
  local repeat="$3"
  local direction="$4"
  # Control queue behavior to a single unmanaged deep FIFO profile by default.
  # This is intentionally not fq/fq_codel/cake; managed queues should be run as
  # separate comparison experiments, not mixed with the bufferbloat verdict.
  local qp="${5:-$BUFFERBLOAT_QUEUE_PROFILE}"
  qp="${qp%% *}"
  [[ -n "$qp" ]] || qp="pfifo_deep"
  local active_delay case_label variant flow_group event_file ss_file tc_file idle_ping load_ping recovery_ping queue_raw reverse_rate metadata_rate
  local duration="$BB_LOAD_DURATION"
  active_delay="$(current_delay)"
  reverse_rate="${BUFFERBLOAT_REVERSE_RATE:-$BASE_RATE}"
  metadata_rate="$BASE_RATE"
  if [[ "$direction" == "download" || "$direction" == "bidirectional" ]]; then
    metadata_rate="forward:${BASE_RATE};reverse:${reverse_rate}"
  fi
  if delay_is_high_latency "$active_delay"; then
    duration="$(max_int "$duration" "$HIGH_LATENCY_BASE_DURATION")"
  fi

  case_label="${scenario}__queue_$(safe_name "$qp")__${direction}"
  variant="bufferbloat_cc_queueing_${qp}"
  flow_group="${case_label}_${algo}_r${repeat}"
  event_file="${EVENTS_RAW_DIR}/$(safe_name "$flow_group").csv"
  ss_file="${SS_DIR}/$(safe_name "$flow_group").sslog"
  tc_file="${TC_DIR}/$(safe_name "$flow_group").tc"
  idle_ping="${PINGS_RAW_DIR}/$(safe_name "$flow_group")_idle.ping"
  load_ping="${PINGS_RAW_DIR}/$(safe_name "$flow_group")_loaded.ping"
  recovery_ping="${PINGS_RAW_DIR}/$(safe_name "$flow_group")_recovery.ping"
  queue_raw="${QUEUE_RAW_DIR}/$(safe_name "$flow_group")_loaded.queue"

  reset_ack_impairment
  set_active_queue_profile "$qp"
  case "$direction" in
    upload)
      ACTIVE_ACK_QUEUE_PROFILE="$QUEUE_PROFILE"
      ;;
    download|bidirectional)
      set_ack_impairment "$reverse_rate" "" "0%" "$qp"
      ;;
    *) die "Unknown bufferbloat direction: $direction" ;;
  esac

  clear_policer
  setup_shapers "$BASE_RATE" "$active_delay" "0%"
  event_log_init "$event_file"
  event_log "$event_file" "bufferbloat_idle_start_${direction}_${qp},${BASE_RATE},${active_delay},0%,,,phase=idle;queue=${qp};controlled_queue=1"
  local ping_pid queue_pid=""
  start_ping_probe ping_pid "$idle_ping" "$BB_IDLE_SECONDS"
  wait "$ping_pid" 2>/dev/null || true
  append_ping_results "$idle_ping" "$case_label" "$variant" "$flow_group" idle probe "$algo" "$qp" "$direction" "$active_delay" "$metadata_rate" "$repeat"

  event_log "$event_file" "bufferbloat_loaded_start_${direction}_${qp},${BASE_RATE},${active_delay},0%,,,phase=loaded;queue=${qp};controlled_queue=1;algo=${algo}"
  flush_tcp_metrics
  local ss_pid
  ss_pid="$(start_ss_logger "$ss_file" "$duration")"
  start_ping_probe ping_pid "$load_ping" "$duration"
  if [[ "$BB_SAMPLE_QUEUE_STATS" == "1" || "$BB_SAMPLE_QUEUE_STATS" == "yes" || "$BB_SAMPLE_QUEUE_STATS" == "true" || "$BB_SAMPLE_QUEUE_STATS" == "on" ]]; then
    start_queue_probe queue_pid "$queue_raw" "$duration"
  fi

  local -a pids jsons stderrs roles modes rcs ports
  local idx port tag role mode peer
  set +e
  case "$direction" in
    upload)
      idx=0; port="$BASE_PORT"; role="primary_upload"; mode="upload"
      ;;
    download)
      idx=0; port="$BASE_PORT"; role="primary_download"; mode="download"
      ;;
    bidirectional)
      idx=0; port="$BASE_PORT"; role="primary_upload"; mode="upload"
      tag="$(safe_name "${flow_group}_${role}_p${port}")"
      jsons[$idx]="${JSON_DIR}/${tag}.json"; stderrs[$idx]="${STDERR_DIR}/${tag}.stderr"; roles[$idx]="$role"; modes[$idx]="$mode"; ports[$idx]="$port"
      run_iperf_capture "${jsons[$idx]}" "${stderrs[$idx]}" "$algo" "$duration" 1 "$port" "$mode" & pids[$idx]=$!
      idx=1; port=$((BASE_PORT + 1)); role="primary_download"; mode="download"
      ;;
  esac
  tag="$(safe_name "${flow_group}_${role}_p${port}")"
  jsons[$idx]="${JSON_DIR}/${tag}.json"; stderrs[$idx]="${STDERR_DIR}/${tag}.stderr"; roles[$idx]="$role"; modes[$idx]="$mode"; ports[$idx]="$port"
  run_iperf_capture "${jsons[$idx]}" "${stderrs[$idx]}" "$algo" "$duration" 1 "$port" "$mode" & pids[$idx]=$!

  for idx in "${!pids[@]}"; do
    wait "${pids[$idx]}"
    rcs[$idx]=$?
  done
  set -e
  wait "$ping_pid" 2>/dev/null || true
  if [[ -n "$queue_pid" ]]; then
    wait "$queue_pid" 2>/dev/null || true
  fi
  kill "$ss_pid" 2>/dev/null || true
  wait "$ss_pid" 2>/dev/null || true

  append_ping_results "$load_ping" "$case_label" "$variant" "$flow_group" loaded probe "$algo" "$qp" "$direction" "$active_delay" "$metadata_rate" "$repeat"
  if [[ -n "$queue_pid" ]]; then
    append_queue_results "$queue_raw" "$case_label" "$variant" "$flow_group" loaded queue_probe "$algo" "$qp" "$direction" "$active_delay" "$metadata_rate" "$repeat"
  fi
  event_log "$event_file" "bufferbloat_loaded_end_${direction}_${qp},${BASE_RATE},${active_delay},0%,,,phase=loaded_end;queue=${qp};controlled_queue=1;algo=${algo}"

  for idx in "${!jsons[@]}"; do
    peer=""
    append_json_results "${jsons[$idx]}" "$case_label" "${roles[$idx]}" "$algo" "$repeat" 1 "$duration" "${rcs[$idx]:-1}" "${stderrs[$idx]}" \
      "$variant" "$flow_group" "$peer" "$active_delay" "$metadata_rate" "0%" "" "$BB_IDLE_SECONDS"
  done

  event_log "$event_file" "bufferbloat_recovery_start_${direction}_${qp},${BASE_RATE},${active_delay},0%,,,phase=recovery;queue=${qp};controlled_queue=1"
  start_ping_probe ping_pid "$recovery_ping" "$BB_RECOVERY_SECONDS"
  wait "$ping_pid" 2>/dev/null || true
  append_ping_results "$recovery_ping" "$case_label" "$variant" "$flow_group" recovery probe "$algo" "$qp" "$direction" "$active_delay" "$metadata_rate" "$repeat"
  capture_tc_state "$tc_file"
  reset_ack_impairment
  set_active_queue_profile "$QUEUE_PROFILE"
}

run_with_loss_bursts() {
  local scenario="$1"
  local algo="$2"
  local repeat="$3"
  local active_delay
  active_delay="$(current_delay)"
  local duration
  duration="$(duration_for_event_delay "$active_delay")"
  local required_duration=$((BURST_START + BURST_COUNT * (BURST_ON_SECONDS + BURST_OFF_SECONDS) + EVENT_RECOVERY_POST))
  if (( duration < required_duration )); then
    duration="$required_duration"
  fi

  local port="$BASE_PORT"
  local flow_group="${scenario}_${algo}_r${repeat}"
  local event_file="${EVENTS_RAW_DIR}/$(safe_name "$flow_group").csv"
  event_log_init "$event_file"
  clear_policer
  setup_shapers "$BASE_RATE" "$active_delay" "0%"
  event_log "$event_file" "start_no_loss,${BASE_RATE},${active_delay},0%,,"

  (
    sleep "$BURST_START"
    local i
    for ((i=1; i<=BURST_COUNT; i++)); do
      change_shapers "$BASE_RATE" "$active_delay" "$BURST_LOSS_RATE"
      event_log "$event_file" "burst_loss_${i},${BASE_RATE},${active_delay},${BURST_LOSS_RATE},,"
      sleep "$BURST_ON_SECONDS"
      change_shapers "$BASE_RATE" "$active_delay" "0%"
      event_log "$event_file" "burst_recover_${i},${BASE_RATE},${active_delay},0%,,"
      sleep "$BURST_OFF_SECONDS"
    done
  ) &
  local changer_pid=$!

  run_single_test "$scenario" primary "$algo" "$repeat" "$duration" 1 "$port" dynamic "$flow_group" "" "$active_delay" "$BASE_RATE" "dynamic_bursts:${BURST_LOSS_RATE}" ""
  wait "$changer_pid" 2>/dev/null || true
}
run_ack_path_test() {
  local scenario="$1" algo="$2" repeat="$3" kind="$4"
  local active_delay duration flow_group event_file
  active_delay="$(current_delay)"
  duration="$(duration_for_event_delay "$active_delay")"
  flow_group="${scenario}_${algo}_r${repeat}"
  event_file="${EVENTS_RAW_DIR}/$(safe_name "$flow_group").csv"
  event_log_init "$event_file"
  clear_policer
  reset_ack_impairment
  set_active_queue_profile "$QUEUE_PROFILE"

  case "$kind" in
    ack_rate_limit)
      set_ack_impairment "$ACK_LIMIT_RATE" "" "0%" "$QUEUE_PROFILE"
      setup_shapers "$BASE_RATE" "$active_delay" "0%"
      event_log "$event_file" "ack_rate_limit,${BASE_RATE},${active_delay},0%,,,ack_rate=${ACK_LIMIT_RATE}"
      run_single_test "$scenario" primary "$algo" "$repeat" "$duration" 1 "$BASE_PORT" ack_path "$flow_group" "" "$active_delay" "$BASE_RATE" "0%" "ack_rate:${ACK_LIMIT_RATE}"
      ;;
    ack_loss)
      set_ack_impairment "$ACK_RATE" "" "$ACK_LOSS_RATE" "$QUEUE_PROFILE"
      setup_shapers "$BASE_RATE" "$active_delay" "0%"
      event_log "$event_file" "ack_loss,${BASE_RATE},${active_delay},0%,,,ack_loss=${ACK_LOSS_RATE}"
      run_single_test "$scenario" primary "$algo" "$repeat" "$duration" 1 "$BASE_PORT" ack_path "$flow_group" "" "$active_delay" "$BASE_RATE" "ack:${ACK_LOSS_RATE}" ""
      ;;
    ack_bufferbloat)
      set_ack_impairment "$ACK_BUFFERBLOAT_RATE" "" "0%" "$ACK_BUFFERBLOAT_QUEUE_PROFILE"
      setup_shapers "$BASE_RATE" "$active_delay" "0%"
      event_log "$event_file" "ack_bufferbloat,${BASE_RATE},${active_delay},0%,,,ack_rate=${ACK_BUFFERBLOAT_RATE};ack_queue=${ACK_BUFFERBLOAT_QUEUE_PROFILE}"
      run_single_test "$scenario" primary "$algo" "$repeat" "$duration" 1 "$BASE_PORT" ack_path "$flow_group" "" "$active_delay" "$BASE_RATE" "0%" "ack_bufferbloat:${ACK_BUFFERBLOAT_RATE}"
      ;;
    ack_delay_spike)
      setup_shapers "$BASE_RATE" "$active_delay" "0%"
      event_log "$event_file" "ack_delay_spike_start,${BASE_RATE},${active_delay},0%,,,"
      (
        sleep "$EVENT_AT"
        ACTIVE_ACK_DELAY="$ACK_SPIKE_DELAY" ACTIVE_ACK_LOSS="0%" change_shapers "$BASE_RATE" "$active_delay" "0%"
        event_log "$event_file" "ack_delay_spike,${BASE_RATE},${active_delay},0%,,,ack_delay=${ACK_SPIKE_DELAY}"
        sleep "$EVENT_HOLD"
        ACTIVE_ACK_DELAY="" ACTIVE_ACK_LOSS="0%" change_shapers "$BASE_RATE" "$active_delay" "0%"
        event_log "$event_file" "ack_delay_restore,${BASE_RATE},${active_delay},0%,,,"
      ) &
      local changer_pid=$!
      run_single_test "$scenario" primary "$algo" "$repeat" "$duration" 1 "$BASE_PORT" dynamic "$flow_group" "" "dynamic_ack:${active_delay}->${ACK_SPIKE_DELAY}->${active_delay}" "$BASE_RATE" "0%" ""
      wait "$changer_pid" 2>/dev/null || true
      ;;
    *) die "Unknown ACK-path scenario: $kind" ;;
  esac
  reset_ack_impairment
}

run_jitter_reorder_test() {
  local scenario="$1" algo="$2" repeat="$3" kind="$4"
  local active_delay duration flow_group extra loss_spec
  active_delay="$(current_delay)"
  duration="$(duration_for_event_delay "$active_delay")"
  flow_group="${scenario}_${algo}_r${repeat}"
  extra=""
  loss_spec="0%"
  case "$kind" in
    jitter_light) extra="5ms 25% distribution normal" ;;
    jitter_heavy) extra="25ms 50% distribution normal" ;;
    jitter_long_tail) extra="80ms 75% distribution paretonormal" ;;
    reorder_light) loss_spec="reorder 1% 25%" ;;
    reorder_heavy) loss_spec="reorder 5% 50%" ;;
    *) die "Unknown jitter/reorder scenario: $kind" ;;
  esac
  reset_ack_impairment
  set_active_queue_profile "$QUEUE_PROFILE"
  set_data_delay_extra "$extra"
  clear_policer
  setup_shapers "$BASE_RATE" "$active_delay" "$loss_spec"
  run_single_test "$scenario" primary "$algo" "$repeat" "$duration" 1 "$BASE_PORT" jitter_reorder "$flow_group" "" "$active_delay" "$BASE_RATE" "${kind}:${loss_spec}${extra:+;delay_jitter=${extra}}" ""
  reset_data_delay_extra
}

run_short_flow_repeated() {
  local scenario="$1" algo="$2" repeat="$3"
  local active_delay flow_group event_file i tag json_file stderr_file rc port
  active_delay="$(current_delay)"
  flow_group="${scenario}_${algo}_r${repeat}"
  event_file="${EVENTS_RAW_DIR}/$(safe_name "$flow_group").csv"
  event_log_init "$event_file"
  reset_ack_impairment
  set_active_queue_profile "$QUEUE_PROFILE"
  clear_policer
  setup_shapers "$BASE_RATE" "$active_delay" "0%"
  event_log "$event_file" "short_flow_repeated_start,${BASE_RATE},${active_delay},0%,,,count=${SHORT_FLOW_COUNT};bytes=${SHORT_FLOW_BYTES}"
  for ((i=1; i<=SHORT_FLOW_COUNT; i++)); do
    port="$BASE_PORT"
    tag="$(safe_name "${flow_group}_short${i}_${algo}_p${port}")"
    json_file="${JSON_DIR}/${tag}.json"
    stderr_file="${STDERR_DIR}/${tag}.stderr"
    flush_tcp_metrics
    set +e
    run_iperf_capture_bytes "$json_file" "$stderr_file" "$algo" "$SHORT_FLOW_BYTES" "$port" upload
    rc=$?
    set -e
    append_json_results "$json_file" "$scenario" "short_${i}" "$algo" "$repeat" 1 "bytes:${SHORT_FLOW_BYTES}" "$rc" "$stderr_file" \
      short_flow "$flow_group" "" "$active_delay" "$BASE_RATE" "0%" "" "0"
    sleep "$SHORT_FLOW_GAP"
  done
  event_log "$event_file" "short_flow_repeated_end,${BASE_RATE},${active_delay},0%,,,"
}

run_short_flow_under_load() {
  local scenario="$1" algo="$2" repeat="$3"
  local active_delay duration flow_group event_file ss_file tc_file
  active_delay="$(current_delay)"
  duration="$SHORT_FLOW_UNDER_LOAD_DURATION"
  if ! is_positive_integer "$duration"; then
    duration="$(duration_for_event_delay "$active_delay")"
  fi
  local min_duration
  min_duration=$((SHORT_FLOW_LOAD_WARMUP + SHORT_FLOW_COUNT + 2))
  if (( duration < min_duration )); then
    duration="$min_duration"
  fi

  flow_group="${scenario}_${algo}_r${repeat}"
  event_file="${EVENTS_RAW_DIR}/$(safe_name "$flow_group").csv"
  ss_file="${SS_DIR}/$(safe_name "$flow_group").sslog"
  tc_file="${TC_DIR}/$(safe_name "$flow_group").tc"
  event_log_init "$event_file"
  reset_ack_impairment
  set_active_queue_profile "$QUEUE_PROFILE"
  clear_policer
  setup_shapers "$BASE_RATE" "$active_delay" "0%"
  event_log "$event_file" "short_flow_under_load_start,${BASE_RATE},${active_delay},0%,,,count=${SHORT_FLOW_COUNT};bytes=${SHORT_FLOW_BYTES};warmup=${SHORT_FLOW_LOAD_WARMUP}"

  flush_tcp_metrics
  local ss_pid primary_json primary_stderr primary_tag primary_pid primary_rc
  ss_pid="$(start_ss_logger "$ss_file" "$duration")"
  primary_tag="$(safe_name "${flow_group}_filler_${algo}_p${BASE_PORT}")"
  primary_json="${JSON_DIR}/${primary_tag}.json"
  primary_stderr="${STDERR_DIR}/${primary_tag}.stderr"

  set +e
  run_iperf_capture "$primary_json" "$primary_stderr" "$algo" "$duration" 1 "$BASE_PORT" upload &
  primary_pid=$!
  set -e

  sleep "$SHORT_FLOW_LOAD_WARMUP"
  local i port tag json_file stderr_file rc start_offset
  port=$((BASE_PORT + 1))
  for ((i=1; i<=SHORT_FLOW_COUNT; i++)); do
    # Use an explicit relative offset based on warmup plus serialized flow index.
    start_offset="$(awk -v w="$SHORT_FLOW_LOAD_WARMUP" -v n="$i" -v gap="$SHORT_FLOW_GAP" 'BEGIN { printf "%.3f", w + (n-1)*gap }')"
    tag="$(safe_name "${flow_group}_short_under_load_${i}_${algo}_p${port}")"
    json_file="${JSON_DIR}/${tag}.json"
    stderr_file="${STDERR_DIR}/${tag}.stderr"
    set +e
    run_iperf_capture_bytes "$json_file" "$stderr_file" "$algo" "$SHORT_FLOW_BYTES" "$port" upload
    rc=$?
    set -e
    append_json_results "$json_file" "$scenario" "short_under_load_${i}" "$algo" "$repeat" 1 "bytes:${SHORT_FLOW_BYTES}" "$rc" "$stderr_file" \
      short_flow_under_load "$flow_group" "filler:${algo}" "$active_delay" "$BASE_RATE" "under_load" "" "$start_offset"
    sleep "$SHORT_FLOW_GAP"
  done

  set +e
  wait "$primary_pid"; primary_rc=$?
  set -e
  kill "$ss_pid" 2>/dev/null || true
  wait "$ss_pid" 2>/dev/null || true
  capture_tc_state "$tc_file"
  append_json_results "$primary_json" "$scenario" filler "$algo" "$repeat" 1 "$duration" "$primary_rc" "$primary_stderr" \
    short_flow_under_load "$flow_group" "short_flows" "$active_delay" "$BASE_RATE" "0%" "" "0"
  event_log "$event_file" "short_flow_under_load_end,${BASE_RATE},${active_delay},0%,,,"
}



proxy_china_bool_enabled() {
  case "${1:-0}" in
    1|yes|true|on|enable|enabled) return 0 ;;
    *) return 1 ;;
  esac
}

proxy_china_is_mobile_profile() {
  case "$1" in
    mobile_typical|mobile_poor) return 0 ;;
    *) return 1 ;;
  esac
}

proxy_china_degraded_profile_for() {
  case "$1" in
    mobile_typical) printf '%s\n' mobile_poor ;;
    lan_typical) printf '%s\n' lan_poor ;;
    *) printf '%s\n' "$1" ;;
  esac
}

proxy_china_profile_params() {
  local profile="$1"
  case "$profile" in
    mobile_typical)
      PROXY_CHINA_DOWN_RATE="$PROXY_CHINA_MOBILE_TYPICAL_DOWN_RATE"
      PROXY_CHINA_UP_RATE="$PROXY_CHINA_MOBILE_TYPICAL_UP_RATE"
      PROXY_CHINA_DOWN_DELAY="$PROXY_CHINA_MOBILE_TYPICAL_DOWN_DELAY"
      PROXY_CHINA_UP_DELAY="$PROXY_CHINA_MOBILE_TYPICAL_UP_DELAY"
      PROXY_CHINA_DOWN_JITTER="$PROXY_CHINA_MOBILE_TYPICAL_DOWN_JITTER"
      PROXY_CHINA_UP_JITTER="$PROXY_CHINA_MOBILE_TYPICAL_UP_JITTER"
      PROXY_CHINA_DOWN_LOSS="$PROXY_CHINA_MOBILE_TYPICAL_DOWN_LOSS"
      PROXY_CHINA_UP_LOSS="$PROXY_CHINA_MOBILE_TYPICAL_UP_LOSS"
      PROXY_CHINA_DIST="$PROXY_CHINA_MOBILE_TYPICAL_DIST"
      PROXY_CHINA_JITTER_CORR="$PROXY_CHINA_MOBILE_TYPICAL_JITTER_CORR"
      PROXY_CHINA_LOSS_CORR="$PROXY_CHINA_MOBILE_TYPICAL_LOSS_CORR"
      PROXY_CHINA_LIMIT="$PROXY_CHINA_MOBILE_TYPICAL_LIMIT"
      PROXY_CHINA_SLOT_ARGS="$PROXY_CHINA_MOBILE_TYPICAL_SLOT_ARGS"
      ;;
    mobile_poor)
      PROXY_CHINA_DOWN_RATE="$PROXY_CHINA_MOBILE_POOR_DOWN_RATE"
      PROXY_CHINA_UP_RATE="$PROXY_CHINA_MOBILE_POOR_UP_RATE"
      PROXY_CHINA_DOWN_DELAY="$PROXY_CHINA_MOBILE_POOR_DOWN_DELAY"
      PROXY_CHINA_UP_DELAY="$PROXY_CHINA_MOBILE_POOR_UP_DELAY"
      PROXY_CHINA_DOWN_JITTER="$PROXY_CHINA_MOBILE_POOR_DOWN_JITTER"
      PROXY_CHINA_UP_JITTER="$PROXY_CHINA_MOBILE_POOR_UP_JITTER"
      PROXY_CHINA_DOWN_LOSS="$PROXY_CHINA_MOBILE_POOR_DOWN_LOSS"
      PROXY_CHINA_UP_LOSS="$PROXY_CHINA_MOBILE_POOR_UP_LOSS"
      PROXY_CHINA_DIST="$PROXY_CHINA_MOBILE_POOR_DIST"
      PROXY_CHINA_JITTER_CORR="$PROXY_CHINA_MOBILE_POOR_JITTER_CORR"
      PROXY_CHINA_LOSS_CORR="$PROXY_CHINA_MOBILE_POOR_LOSS_CORR"
      PROXY_CHINA_LIMIT="$PROXY_CHINA_MOBILE_POOR_LIMIT"
      PROXY_CHINA_SLOT_ARGS="$PROXY_CHINA_MOBILE_POOR_SLOT_ARGS"
      ;;
    lan_typical)
      PROXY_CHINA_DOWN_RATE="$PROXY_CHINA_LAN_TYPICAL_DOWN_RATE"
      PROXY_CHINA_UP_RATE="$PROXY_CHINA_LAN_TYPICAL_UP_RATE"
      PROXY_CHINA_DOWN_DELAY="$PROXY_CHINA_LAN_TYPICAL_DOWN_DELAY"
      PROXY_CHINA_UP_DELAY="$PROXY_CHINA_LAN_TYPICAL_UP_DELAY"
      PROXY_CHINA_DOWN_JITTER="$PROXY_CHINA_LAN_TYPICAL_DOWN_JITTER"
      PROXY_CHINA_UP_JITTER="$PROXY_CHINA_LAN_TYPICAL_UP_JITTER"
      PROXY_CHINA_DOWN_LOSS="$PROXY_CHINA_LAN_TYPICAL_DOWN_LOSS"
      PROXY_CHINA_UP_LOSS="$PROXY_CHINA_LAN_TYPICAL_UP_LOSS"
      PROXY_CHINA_DIST="$PROXY_CHINA_LAN_TYPICAL_DIST"
      PROXY_CHINA_JITTER_CORR="$PROXY_CHINA_LAN_TYPICAL_JITTER_CORR"
      PROXY_CHINA_LOSS_CORR="$PROXY_CHINA_LAN_TYPICAL_LOSS_CORR"
      PROXY_CHINA_LIMIT="$PROXY_CHINA_LAN_TYPICAL_LIMIT"
      PROXY_CHINA_SLOT_ARGS="$PROXY_CHINA_LAN_TYPICAL_SLOT_ARGS"
      ;;
    lan_poor)
      PROXY_CHINA_DOWN_RATE="$PROXY_CHINA_LAN_POOR_DOWN_RATE"
      PROXY_CHINA_UP_RATE="$PROXY_CHINA_LAN_POOR_UP_RATE"
      PROXY_CHINA_DOWN_DELAY="$PROXY_CHINA_LAN_POOR_DOWN_DELAY"
      PROXY_CHINA_UP_DELAY="$PROXY_CHINA_LAN_POOR_UP_DELAY"
      PROXY_CHINA_DOWN_JITTER="$PROXY_CHINA_LAN_POOR_DOWN_JITTER"
      PROXY_CHINA_UP_JITTER="$PROXY_CHINA_LAN_POOR_UP_JITTER"
      PROXY_CHINA_DOWN_LOSS="$PROXY_CHINA_LAN_POOR_DOWN_LOSS"
      PROXY_CHINA_UP_LOSS="$PROXY_CHINA_LAN_POOR_UP_LOSS"
      PROXY_CHINA_DIST="$PROXY_CHINA_LAN_POOR_DIST"
      PROXY_CHINA_JITTER_CORR="$PROXY_CHINA_LAN_POOR_JITTER_CORR"
      PROXY_CHINA_LOSS_CORR="$PROXY_CHINA_LAN_POOR_LOSS_CORR"
      PROXY_CHINA_LIMIT="$PROXY_CHINA_LAN_POOR_LIMIT"
      PROXY_CHINA_SLOT_ARGS="$PROXY_CHINA_LAN_POOR_SLOT_ARGS"
      ;;
    *) die "Unknown PROXY_CHINA profile: ${profile}. Use mobile_typical, mobile_poor, lan_typical, lan_poor." ;;
  esac
}

proxy_china_extra_args() {
  local jitter="$1" corr="$2" dist="$3" slot_args="$4" out=""
  if [[ -n "$jitter" && "$jitter" != "0" && "$jitter" != "0ms" ]]; then
    out="$jitter $corr distribution $dist"
  fi
  if [[ -n "$slot_args" ]]; then
    out="${out:+$out }$slot_args"
  fi
  printf '%s\n' "$out"
}

proxy_china_loss_spec() {
  local loss="$1" corr="$2"
  if [[ -z "$loss" || "$loss" == "0" || "$loss" == "0%" || "$loss" == "none" ]]; then
    printf '%s\n' "loss random 0%"
  else
    printf '%s\n' "loss random $loss $corr"
  fi
}

proxy_china_apply_profile() {
  local profile="$1" op="${2:-change}"
  local up_loss down_loss
  proxy_china_profile_params "$profile"
  QUEUE_MODE="static"
  QUEUE_PACKETS="$PROXY_CHINA_LIMIT"
  QUEUE_ACK_PACKETS="$PROXY_CHINA_LIMIT"
  set_active_rate "$PROXY_CHINA_UP_RATE"
  set_active_latency "$PROXY_CHINA_UP_DELAY"
  set_active_queue_profile "$PROXY_CHINA_QUEUE_PROFILE"
  ACTIVE_ACK_QUEUE_PROFILE="$PROXY_CHINA_QUEUE_PROFILE"
  ACTIVE_DATA_DELAY_EXTRA="$(proxy_china_extra_args "$PROXY_CHINA_UP_JITTER" "$PROXY_CHINA_JITTER_CORR" "$PROXY_CHINA_DIST" "$PROXY_CHINA_SLOT_ARGS")"
  ACTIVE_ACK_DELAY_EXTRA="$(proxy_china_extra_args "$PROXY_CHINA_DOWN_JITTER" "$PROXY_CHINA_JITTER_CORR" "$PROXY_CHINA_DIST" "$PROXY_CHINA_SLOT_ARGS")"
  up_loss="$(proxy_china_loss_spec "$PROXY_CHINA_UP_LOSS" "$PROXY_CHINA_LOSS_CORR")"
  down_loss="$(proxy_china_loss_spec "$PROXY_CHINA_DOWN_LOSS" "$PROXY_CHINA_LOSS_CORR")"
  set_ack_impairment "$PROXY_CHINA_DOWN_RATE" "$PROXY_CHINA_DOWN_DELAY" "$down_loss" "$PROXY_CHINA_QUEUE_PROFILE"
  case "$op" in
    setup) setup_shapers "$PROXY_CHINA_UP_RATE" "$PROXY_CHINA_UP_DELAY" "$up_loss" ;;
    change) change_shapers "$PROXY_CHINA_UP_RATE" "$PROXY_CHINA_UP_DELAY" "$up_loss" ;;
    *) die "Unknown proxy_china_apply_profile op: $op" ;;
  esac
}

proxy_china_apply_stall() {
  local profile="$1" target="$2"
  local up_loss down_loss stall_up_loss stall_down_loss
  proxy_china_profile_params "$profile"
  up_loss="$(proxy_china_loss_spec "$PROXY_CHINA_UP_LOSS" "$PROXY_CHINA_LOSS_CORR")"
  down_loss="$(proxy_china_loss_spec "$PROXY_CHINA_DOWN_LOSS" "$PROXY_CHINA_LOSS_CORR")"
  stall_up_loss="$up_loss"
  stall_down_loss="$down_loss"
  case "$target" in
    client_bound|down|download) stall_down_loss="loss random 100%" ;;
    proxy_bound|up|upload) stall_up_loss="loss random 100%" ;;
    both) stall_up_loss="loss random 100%"; stall_down_loss="loss random 100%" ;;
    *) die "Unknown PROXY_CHINA_STALL_TARGET=${target}. Use client_bound, proxy_bound, or both." ;;
  esac
  QUEUE_MODE="static"
  QUEUE_PACKETS="$PROXY_CHINA_LIMIT"
  QUEUE_ACK_PACKETS="$PROXY_CHINA_LIMIT"
  set_active_rate "$PROXY_CHINA_UP_RATE"
  set_active_latency "$PROXY_CHINA_UP_DELAY"
  set_active_queue_profile "$PROXY_CHINA_QUEUE_PROFILE"
  ACTIVE_ACK_QUEUE_PROFILE="$PROXY_CHINA_QUEUE_PROFILE"
  ACTIVE_DATA_DELAY_EXTRA="$(proxy_china_extra_args "$PROXY_CHINA_UP_JITTER" "$PROXY_CHINA_JITTER_CORR" "$PROXY_CHINA_DIST" "$PROXY_CHINA_SLOT_ARGS")"
  ACTIVE_ACK_DELAY_EXTRA="$(proxy_china_extra_args "$PROXY_CHINA_DOWN_JITTER" "$PROXY_CHINA_JITTER_CORR" "$PROXY_CHINA_DIST" "$PROXY_CHINA_SLOT_ARGS")"
  set_ack_impairment "$PROXY_CHINA_DOWN_RATE" "$PROXY_CHINA_DOWN_DELAY" "$stall_down_loss" "$PROXY_CHINA_QUEUE_PROFILE"
  change_shapers "$PROXY_CHINA_UP_RATE" "$PROXY_CHINA_UP_DELAY" "$stall_up_loss"
}

proxy_china_case_duration() {
  local profile="$1" phase="$2" count=2
  if proxy_china_bool_enabled "$PROXY_CHINA_ENABLE_PROFILE_SWING"; then
    count=$((count + 1))
  fi
  if proxy_china_is_mobile_profile "$profile" && proxy_china_bool_enabled "$PROXY_CHINA_ENABLE_STALLS" && (( PROXY_CHINA_STALL_SECONDS > 0 )); then
    count=$((count + 1))
  fi
  printf '%s\n' "$((phase * count))"
}

run_profile_proxy_mobile_china_case() {
  local scenario="$1" algo="$2" repeat="$3" profile="$4" direction="$5" parallel="$6"
  local phase="$PROXY_CHINA_PHASE_SECONDS"
  local min_duration duration degraded active_profile mode role case_label flow_group case_tag event_file ss_file tc_file tag json_file stderr_file port pid ss_pid rc t remaining stall_remainder data_rate_label data_delay_label loss_label

  min_duration="$(proxy_china_case_duration "$profile" "$phase")"
  if [[ "$PROXY_CHINA_DURATION" == "0" || "$PROXY_CHINA_DURATION" == "auto" ]]; then
    duration="$min_duration"
  else
    is_positive_integer "$PROXY_CHINA_DURATION" || die "PROXY_CHINA_DURATION must be 0, auto, or a positive integer"
    duration="$PROXY_CHINA_DURATION"
    if (( duration < min_duration )); then
      log "PROXY_CHINA_DURATION=${duration}s is shorter than the ${profile}/${direction} schedule; using ${min_duration}s."
      duration="$min_duration"
    fi
  fi

  case "$direction" in
    download|reverse|client_bound) mode="download"; role="china_download"; direction="download" ;;
    upload|forward|proxy_bound) mode="upload"; role="china_upload"; direction="upload" ;;
    bidir|bidirectional) mode="bidir"; role="china_bidirectional"; direction="bidirectional" ;;
    *) die "Unknown PROXY_CHINA direction: ${direction}. Use download, upload, or bidirectional." ;;
  esac
  is_positive_integer "$parallel" || die "PROXY_CHINA_PARALLEL_SET entries must be positive integers; got ${parallel}"
  allocate_port_block port 1

  case_label="${scenario}__china_${profile}__${direction}__P${parallel}"
  flow_group="${case_label}_${algo}_r${repeat}"
  case_tag="$(safe_name "$flow_group")"
  event_file="${EVENTS_RAW_DIR}/${case_tag}.csv"
  ss_file="${SS_DIR}/${case_tag}.sslog"
  tc_file="${TC_DIR}/${case_tag}.tc"
  tag="$(safe_name "${flow_group}_${role}_${algo}_p${port}")"
  json_file="${JSON_DIR}/${tag}.json"
  stderr_file="${STDERR_DIR}/${tag}.stderr"

  clear_policer
  event_log_init "$event_file"
  proxy_china_apply_profile "$profile" setup
  proxy_china_profile_params "$profile"
  event_log "$event_file" "proxy_china_start_${profile}_${direction},client_bound:${PROXY_CHINA_DOWN_RATE};proxy_bound:${PROXY_CHINA_UP_RATE},client_bound:${PROXY_CHINA_DOWN_DELAY};proxy_bound:${PROXY_CHINA_UP_DELAY},client_bound:${PROXY_CHINA_DOWN_LOSS};proxy_bound:${PROXY_CHINA_UP_LOSS},,,phase=start;profile=${profile};direction=${direction};parallel=${parallel};queue=${PROXY_CHINA_QUEUE_PROFILE};jitter_down=${PROXY_CHINA_DOWN_JITTER};jitter_up=${PROXY_CHINA_UP_JITTER};slot=${PROXY_CHINA_SLOT_ARGS}"

  flush_tcp_metrics
  ss_pid="$(start_ss_logger "$ss_file" "$duration")"
  set +e
  run_iperf_capture "$json_file" "$stderr_file" "$algo" "$duration" "$parallel" "$port" "$mode" &
  pid=$!
  set -e

  t=0
  sleep "$phase"; t=$((t + phase))
  active_profile="$profile"

  if proxy_china_bool_enabled "$PROXY_CHINA_ENABLE_PROFILE_SWING"; then
    degraded="$(proxy_china_degraded_profile_for "$profile")"
    active_profile="$degraded"
    proxy_china_apply_profile "$active_profile" change
    proxy_china_profile_params "$active_profile"
    event_log "$event_file" "proxy_china_profile_swing_${profile}_to_${active_profile},client_bound:${PROXY_CHINA_DOWN_RATE};proxy_bound:${PROXY_CHINA_UP_RATE},client_bound:${PROXY_CHINA_DOWN_DELAY};proxy_bound:${PROXY_CHINA_UP_DELAY},client_bound:${PROXY_CHINA_DOWN_LOSS};proxy_bound:${PROXY_CHINA_UP_LOSS},,,phase=profile_swing;from=${profile};to=${active_profile};direction=${direction};jitter_down=${PROXY_CHINA_DOWN_JITTER};jitter_up=${PROXY_CHINA_UP_JITTER};slot=${PROXY_CHINA_SLOT_ARGS}"
    sleep "$phase"; t=$((t + phase))
  fi

  if proxy_china_is_mobile_profile "$profile" && proxy_china_bool_enabled "$PROXY_CHINA_ENABLE_STALLS" && (( PROXY_CHINA_STALL_SECONDS > 0 )); then
    proxy_china_apply_stall "$active_profile" "$PROXY_CHINA_STALL_TARGET"
    proxy_china_profile_params "$active_profile"
    event_log "$event_file" "proxy_china_mobile_stall_${PROXY_CHINA_STALL_TARGET},client_bound:${PROXY_CHINA_DOWN_RATE};proxy_bound:${PROXY_CHINA_UP_RATE},client_bound:${PROXY_CHINA_DOWN_DELAY};proxy_bound:${PROXY_CHINA_UP_DELAY},stall:100%,,,phase=mobile_stall;profile=${active_profile};target=${PROXY_CHINA_STALL_TARGET};stall_seconds=${PROXY_CHINA_STALL_SECONDS}"
    sleep "$PROXY_CHINA_STALL_SECONDS"
    proxy_china_apply_profile "$active_profile" change
    proxy_china_profile_params "$active_profile"
    event_log "$event_file" "proxy_china_mobile_stall_recovery,client_bound:${PROXY_CHINA_DOWN_RATE};proxy_bound:${PROXY_CHINA_UP_RATE},client_bound:${PROXY_CHINA_DOWN_DELAY};proxy_bound:${PROXY_CHINA_UP_DELAY},client_bound:${PROXY_CHINA_DOWN_LOSS};proxy_bound:${PROXY_CHINA_UP_LOSS},,,phase=mobile_stall_recovery;profile=${active_profile};target=${PROXY_CHINA_STALL_TARGET}"
    stall_remainder=$((phase - PROXY_CHINA_STALL_SECONDS))
    if (( stall_remainder > 0 )); then
      sleep "$stall_remainder"
    fi
    t=$((t + phase))
  fi

  proxy_china_apply_profile "$profile" change
  proxy_china_profile_params "$profile"
  event_log "$event_file" "proxy_china_restore_${profile},client_bound:${PROXY_CHINA_DOWN_RATE};proxy_bound:${PROXY_CHINA_UP_RATE},client_bound:${PROXY_CHINA_DOWN_DELAY};proxy_bound:${PROXY_CHINA_UP_DELAY},client_bound:${PROXY_CHINA_DOWN_LOSS};proxy_bound:${PROXY_CHINA_UP_LOSS},,,phase=restore;profile=${profile};direction=${direction}"
  sleep "$phase"; t=$((t + phase))

  remaining=$((duration - t))
  if (( remaining > 0 )); then
    sleep "$remaining"
  fi

  set +e
  wait "$pid"; rc=$?
  set -e
  kill "$ss_pid" 2>/dev/null || true
  wait "$ss_pid" 2>/dev/null || true
  capture_tc_state "$tc_file"
  event_log "$event_file" "proxy_china_end_${profile}_${direction},client_bound:${PROXY_CHINA_DOWN_RATE};proxy_bound:${PROXY_CHINA_UP_RATE},client_bound:${PROXY_CHINA_DOWN_DELAY};proxy_bound:${PROXY_CHINA_UP_DELAY},client_bound:${PROXY_CHINA_DOWN_LOSS};proxy_bound:${PROXY_CHINA_UP_LOSS},,,phase=end;profile=${profile};direction=${direction};parallel=${parallel}"

  case "$direction" in
    download)
      data_rate_label="$PROXY_CHINA_DOWN_RATE"
      data_delay_label="$PROXY_CHINA_DOWN_DELAY"
      ;;
    upload)
      data_rate_label="$PROXY_CHINA_UP_RATE"
      data_delay_label="$PROXY_CHINA_UP_DELAY"
      ;;
    *)
      data_rate_label="fwd:${PROXY_CHINA_UP_RATE};rev:${PROXY_CHINA_DOWN_RATE}"
      data_delay_label="fwd:${PROXY_CHINA_UP_DELAY};rev:${PROXY_CHINA_DOWN_DELAY}"
      ;;
  esac
  loss_label="fwd:${PROXY_CHINA_UP_LOSS};rev:${PROXY_CHINA_DOWN_LOSS};loss_corr:${PROXY_CHINA_LOSS_CORR};stall_target:${PROXY_CHINA_STALL_TARGET};swing:${PROXY_CHINA_ENABLE_PROFILE_SWING};stall:${PROXY_CHINA_ENABLE_STALLS}"
  append_json_results "$json_file" "$case_label" "$role" "$algo" "$repeat" "$parallel" "$duration" "$rc" "$stderr_file" \
    "real_world_proxy_mobile_china_${profile}" "$flow_group" "china_client" \
    "$data_delay_label" \
    "$data_rate_label" \
    "$loss_label" "" "0" "$ss_file" "$tc_file"
}

run_profile_proxy_mobile_china() {
  local scenario="$1" algo="$2" repeat="$3"
  local save_rate save_active save_delay save_ack save_ack_delay save_ack_loss save_queue save_ack_queue save_data_extra save_ack_extra save_queue_mode save_queue_packets save_queue_ack_packets
  save_rate="$BASE_RATE"
  save_active="$ACTIVE_BASE_RATE"
  save_delay="$ACTIVE_ONEWAY_DELAY"
  save_ack="$ACTIVE_ACK_RATE"
  save_ack_delay="$ACTIVE_ACK_DELAY"
  save_ack_loss="$ACTIVE_ACK_LOSS"
  save_queue="$ACTIVE_QUEUE_PROFILE"
  save_ack_queue="$ACTIVE_ACK_QUEUE_PROFILE"
  save_data_extra="$ACTIVE_DATA_DELAY_EXTRA"
  save_ack_extra="$ACTIVE_ACK_DELAY_EXTRA"
  save_queue_mode="$QUEUE_MODE"
  save_queue_packets="$QUEUE_PACKETS"
  save_queue_ack_packets="$QUEUE_ACK_PACKETS"

  is_positive_integer "$PROXY_CHINA_PHASE_SECONDS" || die "PROXY_CHINA_PHASE_SECONDS must be a positive integer"
  is_nonnegative_integer "$PROXY_CHINA_STALL_SECONDS" || die "PROXY_CHINA_STALL_SECONDS must be a non-negative integer"

  local profile direction parallel
  for profile in $PROXY_CHINA_PROFILE_SET; do
    # Validate profile early and populate globals for metadata/logging.
    proxy_china_profile_params "$profile"
    for direction in $PROXY_CHINA_DIRECTION_SET; do
      for parallel in $PROXY_CHINA_PARALLEL_SET; do
        run_profile_proxy_mobile_china_case "$scenario" "$algo" "$repeat" "$profile" "$direction" "$parallel"
        competition_cooldown
      done
    done
  done

  BASE_RATE="$save_rate"
  ACTIVE_BASE_RATE="$save_active"
  ACTIVE_ONEWAY_DELAY="$save_delay"
  ACTIVE_ACK_RATE="$save_ack"
  ACTIVE_ACK_DELAY="$save_ack_delay"
  ACTIVE_ACK_LOSS="$save_ack_loss"
  ACTIVE_QUEUE_PROFILE="$save_queue"
  ACTIVE_ACK_QUEUE_PROFILE="$save_ack_queue"
  ACTIVE_DATA_DELAY_EXTRA="$save_data_extra"
  ACTIVE_ACK_DELAY_EXTRA="$save_ack_extra"
  QUEUE_MODE="$save_queue_mode"
  QUEUE_PACKETS="$save_queue_packets"
  QUEUE_ACK_PACKETS="$save_queue_ack_packets"
  clear_policer
}

run_scenario() {
  local scenario="$1"
  local algo="$2"
  local repeat="$3"
  local active_delay scenario_label comp_algo impairment
  active_delay="$(current_delay)"
  scenario_label="$(scenario_with_latency "$scenario")"

  if is_all_algo_competition_scenario "$scenario" && ! should_run_all_algo_competition_once "$algo"; then
    log "Scenario=${scenario} latency=${active_delay} rate=${BASE_RATE} already runs all algorithms together; skipping duplicate driver algo=${algo} repeat=${repeat}"
    return 0
  fi

  log "Scenario=${scenario} latency=${active_delay} rate=${BASE_RATE} algo=${algo} repeat=${repeat}"
  reset_ack_impairment
  reset_data_delay_extra
  set_active_queue_profile "$QUEUE_PROFILE"

  case "$scenario" in
    baseline)
      clear_policer
      setup_shapers "$BASE_RATE" "$active_delay" "0%"
      run_single_test "$scenario_label" primary "$algo" "$repeat" "$(duration_for_base_delay "$active_delay")" 1 "$BASE_PORT" single "${scenario_label}_${algo}_r${repeat}" "" "$active_delay" "$BASE_RATE" "0%" ""
      ;;
    latency_sweep)
      run_latency_sweep "$algo" "$repeat"
      ;;
    sustain_loss)
      clear_policer
      setup_sustain_loss_shapers "$BASE_RATE" "$active_delay"
      run_single_test "$scenario_label" primary "$algo" "$repeat" "$(duration_for_base_delay "$active_delay")" 1 "$BASE_PORT" single "${scenario_label}_${algo}_r${repeat}" "" "$active_delay" "$BASE_RATE" "$(sustain_loss_label)" ""
      ;;
    loss_bursts)
      run_with_loss_bursts "$scenario_label" "$algo" "$repeat"
      ;;
    loss_spike)
      run_with_dynamic_change "$scenario_label" "$algo" "$repeat" loss_spike
      ;;
    latency_spike)
      run_with_dynamic_change "$scenario_label" "$algo" "$repeat" latency_spike
      ;;
    latency_reduction)
      run_with_dynamic_change "$scenario_label" "$algo" "$repeat" latency_reduction
      ;;
    capacity_drop)
      run_with_dynamic_change "$scenario_label" "$algo" "$repeat" capacity_drop
      ;;
    flow_fairness)
      run_all_algo_fairness_impairment "$repeat" "$scenario_label" clean
      ;;
    flow_fairness_sustain_loss)
      run_all_algo_fairness_impairment "$repeat" "$scenario_label" sustain_loss
      ;;
    flow_fairness_loss_spike)
      run_all_algo_fairness_impairment "$repeat" "$scenario_label" loss_spike
      ;;
    flow_fairness_latency_spike)
      run_all_algo_fairness_impairment "$repeat" "$scenario_label" latency_spike
      ;;
    flow_fairness_capacity_drop)
      run_all_algo_fairness_impairment "$repeat" "$scenario_label" capacity_drop
      ;;
    flow_fairness_policer)
      run_all_algo_fairness_impairment "$repeat" "$scenario_label" policer
      ;;
    flow_fairness_ack_limit)
      run_all_algo_fairness_impairment "$repeat" "$scenario_label" ack_limit
      ;;
    flow_fairness_jitter)
      run_all_algo_fairness_impairment "$repeat" "$scenario_label" jitter
      ;;
    flow_fairness_reorder)
      run_all_algo_fairness_impairment "$repeat" "$scenario_label" reorder
      ;;
    policer_static)
      setup_shapers "$BASE_RATE" "$active_delay" "0%"
      enable_ingress_policer "$POLICE_RATE" "$POLICE_BURST" "$POLICE_MTU" "$POLICE_MATCH_DST"
      run_single_test "$scenario_label" primary "$algo" "$repeat" "$(duration_for_base_delay "$active_delay")" 1 "$BASE_PORT" single "${scenario_label}_${algo}_r${repeat}" "" "$active_delay" "$BASE_RATE" "0%" "$POLICE_RATE"
      clear_policer
      ;;
    policer_spike)
      run_with_dynamic_change "$scenario_label" "$algo" "$repeat" policer_spike
      ;;
    policer_adaptive_rate)
      run_adaptive_policer_test "$scenario_label" "$algo" "$repeat" rate_triggered
      ;;
    policer_adaptive_retrans)
      run_adaptive_policer_test "$scenario_label" "$algo" "$repeat" retrans_feedback
      ;;
    bufferbloat_upload)
      run_bufferbloat_test "$scenario_label" "$algo" "$repeat" upload
      ;;
    bufferbloat_download)
      run_bufferbloat_test "$scenario_label" "$algo" "$repeat" download
      ;;
    bufferbloat_bidirectional)
      run_bufferbloat_test "$scenario_label" "$algo" "$repeat" bidirectional
      ;;
    ack_rate_limit|ack_loss|ack_delay_spike|ack_bufferbloat)
      run_ack_path_test "$scenario_label" "$algo" "$repeat" "$scenario"
      ;;
    jitter_light|jitter_heavy|jitter_long_tail|reorder_light|reorder_heavy)
      run_jitter_reorder_test "$scenario_label" "$algo" "$repeat" "$scenario"
      ;;
    short_flow_repeated)
      run_short_flow_repeated "$scenario_label" "$algo" "$repeat"
      ;;
    short_flow_under_load)
      run_short_flow_under_load "$scenario_label" "$algo" "$repeat"
      ;;
    profile_proxy_mobile_china)
      run_profile_proxy_mobile_china "$scenario_label" "$algo" "$repeat"
      ;;
    combined_all)
      for comp_algo in "${COMPETITOR_ALGO_LIST[@]}"; do
        run_combined_all_test "$algo" "$repeat" "$comp_algo"
        competition_cooldown
      done
      ;;
    *)
      log "Skipping unknown scenario: $scenario"
      ;;
  esac
}


generate_analysis_reports() {
  python3 - "$SCHEMA_VERSION" "$RUN_ID" "$SUMMARY_CSV" "$INTERVALS_CSV" "$SCENARIO_ALGO_CSV" "$FLOW_FAIRNESS_CSV" "$FAILURES_CSV" "$PING_CSV" "$QUEUE_CSV" "$BUFFERBLOAT_CSV" "$BUFFERBLOAT_ALGO_CSV" "$BUFFERBLOAT_QUEUE_CSV" "$METRICS_CSV" "$ANALYSIS_REPORT" "$PING_INTERVAL" "$BB_IDLE_SECONDS" "$BB_LOAD_DURATION" "$BB_RECOVERY_SECONDS" "$BB_SAMPLE_VALID_MIN_RATIO" "$HIGH_LATENCY_THRESHOLD_MS" "$HIGH_LATENCY_BASE_DURATION" <<'PYREPORT'
import csv, math, re, statistics, sys
from collections import defaultdict

(schema_version, run_id, summary_path, intervals_path, scenario_algo_csv, fairness_csv,
 failures_csv, ping_csv, queue_csv, bufferbloat_csv,
 bufferbloat_algo_csv, bufferbloat_queue_csv, metrics_csv, analysis_report,
 ping_interval_s, bb_idle_seconds, bb_load_duration, bb_recovery_seconds,
 bb_sample_valid_min_ratio, high_latency_threshold_ms,
 high_latency_base_duration) = sys.argv[1:]

def read_csv(path):
    try:
        with open(path, newline="") as f:
            return list(csv.DictReader(f))
    except FileNotFoundError:
        return []

rows = read_csv(summary_path)
intervals = read_csv(intervals_path)
pings = read_csv(ping_csv)
queue_samples = read_csv(queue_csv)

def fnum(v):
    try:
        if v is None or v == "":
            return None
        return float(v)
    except Exception:
        return None

def expected_ping_count(seconds):
    try:
        interval = float(ping_interval_s)
        duration = float(seconds)
        if interval <= 0:
            interval = 1.0
        # Must match ping_count_for_duration() in bash.
        return max(1, int(math.ceil(duration / interval)) + 1)
    except Exception:
        return 1

def delay_text_to_ms(v):
    s = str(v or '').strip().lower()
    if not s or s.startswith('dynamic:') or ':' in s:
        return None
    m = re.match(r'([0-9.]+)', s)
    if not m:
        return None
    n = float(m.group(1))
    if 'us' in s or 'usec' in s:
        n /= 1000.0
    elif re.fullmatch(r'[0-9.]+s(ec)?', s):
        n *= 1000.0
    return n

def rate_text_to_mbps_values(v):
    vals = []
    for part in re.split(r'[;,:]+', str(v or '')):
        s = part.strip().lower()
        m = re.search(r'([0-9.]+)\s*([kmg]?)(?:bit|bps|b)?', s)
        if not m:
            continue
        n = float(m.group(1)); unit = m.group(2)
        if unit == 'g':
            n *= 1000.0
        elif unit == 'k':
            n /= 1000.0
        vals.append(n)
    return [x for x in vals if x > 0]

def estimated_queue_kbytes(delta_ms, rate_text):
    if delta_ms is None:
        return None
    rates = rate_text_to_mbps_values(rate_text)
    if not rates:
        return None
    # Use the smallest positive bottleneck rate if metadata contains fwd/rev.
    mbps = min(rates)
    return max(0.0, (delta_ms / 1000.0) * (mbps * 1_000_000.0 / 8.0) / 1024.0)

def is_success(r):
    return r.get("success") == "1" or (r.get("rc") == "0" and fnum(r.get("receiver_mbps")) is not None)

def percentile(vals, pct):
    vals = sorted(vals)
    if not vals:
        return ""
    if len(vals) == 1:
        return vals[0]
    k = (len(vals) - 1) * pct / 100.0
    lo = math.floor(k)
    hi = math.ceil(k)
    if lo == hi:
        return vals[int(k)]
    return vals[lo] * (hi - k) + vals[hi] * (k - lo)

def scenario_family(s):
    if s.startswith("combined_all"):
        return "combined_all"
    if s.startswith("latency_sweep"):
        return "latency_sweep"
    if "__lat_" in s:
        return s.split("__lat_", 1)[0]
    return s.split("__", 1)[0]

def jain(vals):
    vals = [v for v in vals if v is not None and v >= 0]
    if not vals:
        return ""
    den = len(vals) * sum(v*v for v in vals)
    if den == 0:
        return ""
    return (sum(vals) ** 2) / den

# Failures.
failures = [r for r in rows if not is_success(r)]
with open(failures_csv, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["schema_version", "run_id", "case_id", "flow_id", "scenario_family", "scenario", "variant", "flow_group", "role", "algo", "peer_algo", "oneway_delay", "oneway_delay_ms", "rate", "data_rate_mbps", "failure_category", "rc", "error", "json_path", "stderr_path"])
    for r in failures:
        w.writerow([schema_version, run_id, r.get("case_id", r.get("flow_group", "")), r.get("flow_id", ""), r.get("scenario_family", scenario_family(r.get("scenario", ""))), r.get("scenario",""), r.get("variant",""), r.get("flow_group",""), r.get("role",""), r.get("algo",""), r.get("peer_algo",""), r.get("oneway_delay",""), r.get("oneway_delay_ms", ""), r.get("rate", ""), r.get("data_rate_mbps", ""), r.get("failure_category", ""), r.get("rc",""), r.get("error",""), r.get("json_path", r.get("json_file", "")), r.get("stderr_path", "")])

# Scenario/algo primary summaries.
groups = defaultdict(list)
for r in rows:
    fam = r.get("scenario_family") or scenario_family(r.get("scenario", ""))
    variant = r.get("variant", "")
    # Pairwise-era summaries only counted the primary row because each algorithm
    # became primary in a separate case. All-algorithm fairness cases run once,
    # so include every participant algorithm in the per-algo summary.
    include_row = r.get("role") == "primary" or (fam.startswith("flow_fairness") and variant.startswith("all_algos_"))
    if not include_row:
        continue
    key = (fam, r.get("algo",""), variant)
    groups[key].append(r)
with open(scenario_algo_csv, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["scenario_family", "algo", "variant", "runs", "successes", "failures", "mean_rx_mbps", "median_rx_mbps", "p10_rx_mbps", "p90_rx_mbps", "mean_retrans_per_gbit"])
    for key in sorted(groups):
        rs = groups[key]
        succ = [r for r in rs if is_success(r)]
        vals = [fnum(r.get("receiver_mbps")) for r in succ]
        vals = [v for v in vals if v is not None]
        rpg = [fnum(r.get("retrans_per_gbit")) for r in succ]
        rpg = [v for v in rpg if v is not None]
        w.writerow([*key, len(rs), len(succ), len(rs)-len(succ),
                    f"{statistics.mean(vals):.6f}" if vals else "",
                    f"{statistics.median(vals):.6f}" if vals else "",
                    f"{percentile(vals,10):.6f}" if vals else "",
                    f"{percentile(vals,90):.6f}" if vals else "",
                    f"{statistics.mean(rpg):.3f}" if rpg else ""])

# Fairness for simultaneously-started flow_fairness groups.
by_flow_group = defaultdict(list)
for r in rows:
    if is_success(r):
        by_flow_group[r.get("flow_group","")].append(r)
with open(fairness_csv, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["scenario", "variant", "flow_group", "flow_count", "total_rx_mbps", "jain_fairness", "primary_rx_mbps", "competitor_rx_mbps_sum", "algos"])
    for fg, rs in sorted(by_flow_group.items()):
        scen = rs[0].get("scenario","") if rs else ""
        if "flow_fairness" not in scen:
            continue
        vals = [fnum(r.get("receiver_mbps")) for r in rs]
        vals = [v for v in vals if v is not None]
        primary = sum(fnum(r.get("receiver_mbps")) or 0 for r in rs if r.get("role") == "primary")
        comp = sum(fnum(r.get("receiver_mbps")) or 0 for r in rs if r.get("role","").startswith("competitor"))
        algos = ";".join(f"{r.get('role')}:{r.get('algo')}" for r in rs)
        w.writerow([scen, rs[0].get("variant",""), fg, len(vals), f"{sum(vals):.6f}", f"{jain(vals):.6f}" if vals else "", f"{primary:.6f}", f"{comp:.6f}", algos])

# Bufferbloat / latency-under-load summaries from ping probes.
ping_groups = defaultdict(list)
for p in pings:
    key = (p.get("scenario",""), p.get("variant",""), p.get("flow_group",""),
           p.get("algo",""), p.get("queue_profile",""), p.get("direction",""),
           p.get("oneway_delay",""), p.get("rate",""), p.get("repeat",""))
    ping_groups[key].append(p)

bufferbloat_rows = []
bufferbloat_summary_records = []
with open(bufferbloat_csv, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["scenario", "variant", "flow_group", "algo", "queue_profile", "direction", "oneway_delay", "rate", "repeat",
                "idle_samples", "loaded_samples", "recovery_samples", "idle_p50_ms", "loaded_p50_ms", "loaded_p95_ms",
                "loaded_p99_ms", "loaded_max_ms", "bufferbloat_delta_p50_ms", "bufferbloat_delta_p95_ms",
                "queue_est_p50_kbytes", "queue_est_p95_kbytes", "queue_est_p95_packets_1500b", "recovery_p50_ms",
                "expected_idle_samples", "expected_loaded_samples", "expected_recovery_samples", "sample_valid", "sample_warning"])
    min_ratio = fnum(bb_sample_valid_min_ratio)
    if min_ratio is None or min_ratio <= 0 or min_ratio > 1:
        min_ratio = 0.80
    idle_expected = expected_ping_count(bb_idle_seconds)
    recovery_expected = expected_ping_count(bb_recovery_seconds)
    for key, ps in sorted(ping_groups.items()):
        by_phase = defaultdict(list)
        for p in ps:
            rtt = fnum(p.get("rtt_ms"))
            if rtt is not None:
                by_phase[p.get("phase","")].append(rtt)
        idle = by_phase.get("idle", [])
        loaded = by_phase.get("loaded", [])
        recovery = by_phase.get("recovery", [])
        delay_ms = delay_text_to_ms(key[6])
        loaded_seconds = fnum(bb_load_duration) or 0.0
        threshold_ms = fnum(high_latency_threshold_ms)
        high_latency_seconds = fnum(high_latency_base_duration)
        if delay_ms is not None and threshold_ms is not None and high_latency_seconds is not None and delay_ms >= threshold_ms:
            loaded_seconds = max(loaded_seconds, high_latency_seconds)
        loaded_expected = expected_ping_count(loaded_seconds)
        idle_min = max(1, int(math.ceil(idle_expected * min_ratio)))
        loaded_min = max(1, int(math.ceil(loaded_expected * min_ratio)))
        recovery_min = max(1, int(math.ceil(recovery_expected * min_ratio)))
        warnings = []
        if len(idle) < idle_min:
            warnings.append(f"idle_samples<{idle_min}/{idle_expected}")
        if len(loaded) < loaded_min:
            warnings.append(f"loaded_samples<{loaded_min}/{loaded_expected}")
        if len(recovery) < recovery_min:
            warnings.append(f"recovery_samples<{recovery_min}/{recovery_expected}")
        sample_valid = "1" if not warnings else "0"
        idle_p50 = percentile(idle, 50) if idle else None
        loaded_p50 = percentile(loaded, 50) if loaded else None
        loaded_p95 = percentile(loaded, 95) if loaded else None
        loaded_p99 = percentile(loaded, 99) if loaded else None
        loaded_max = max(loaded) if loaded else None
        recovery_p50 = percentile(recovery, 50) if recovery else None
        delta_p50 = (loaded_p50 - idle_p50) if loaded_p50 is not None and idle_p50 is not None else None
        delta_p95 = (loaded_p95 - idle_p50) if loaded_p95 is not None and idle_p50 is not None else None
        queue_est_p50 = estimated_queue_kbytes(delta_p50, key[7])
        queue_est_p95 = estimated_queue_kbytes(delta_p95, key[7])
        queue_est_p95_packets = (queue_est_p95 * 1024.0 / 1500.0) if queue_est_p95 is not None else None
        row = [*key, len(idle), len(loaded), len(recovery),
               f"{idle_p50:.3f}" if idle_p50 is not None else "",
               f"{loaded_p50:.3f}" if loaded_p50 is not None else "",
               f"{loaded_p95:.3f}" if loaded_p95 is not None else "",
               f"{loaded_p99:.3f}" if loaded_p99 is not None else "",
               f"{loaded_max:.3f}" if loaded_max is not None else "",
               f"{delta_p50:.3f}" if delta_p50 is not None else "",
               f"{delta_p95:.3f}" if delta_p95 is not None else "",
               f"{queue_est_p50:.3f}" if queue_est_p50 is not None else "",
               f"{queue_est_p95:.3f}" if queue_est_p95 is not None else "",
               f"{queue_est_p95_packets:.3f}" if queue_est_p95_packets is not None else "",
               f"{recovery_p50:.3f}" if recovery_p50 is not None else "",
               idle_expected, loaded_expected, recovery_expected, sample_valid, ";".join(warnings)]
        w.writerow(row)
        bufferbloat_summary_records.append({
            "scenario": key[0], "variant": key[1], "flow_group": key[2], "algo": key[3],
            "queue_profile": key[4], "direction": key[5], "oneway_delay": key[6],
            "rate": key[7], "repeat": key[8], "idle_samples": len(idle),
            "loaded_samples": len(loaded), "recovery_samples": len(recovery),
            "idle_p50_ms": idle_p50, "loaded_p50_ms": loaded_p50, "loaded_p95_ms": loaded_p95,
            "loaded_p99_ms": loaded_p99, "loaded_max_ms": loaded_max,
            "bufferbloat_delta_p50_ms": delta_p50, "bufferbloat_delta_p95_ms": delta_p95,
            "queue_est_p50_kbytes": queue_est_p50, "queue_est_p95_kbytes": queue_est_p95,
            "queue_est_p95_packets_1500b": queue_est_p95_packets, "recovery_p50_ms": recovery_p50,
            "expected_idle_samples": idle_expected, "expected_loaded_samples": loaded_expected,
            "expected_recovery_samples": recovery_expected, "sample_valid": sample_valid,
            "sample_warning": ";".join(warnings),
        })
        if delta_p95 is not None:
            bufferbloat_rows.append((delta_p95, row))

# Direct qdisc backlog summaries for the bufferbloat loaded phase.
queue_groups = defaultdict(list)
for q in queue_samples:
    if q.get("phase") != "loaded":
        continue
    key = (q.get("scenario",""), q.get("variant",""), q.get("flow_group",""), q.get("algo",""),
           q.get("queue_profile",""), q.get("direction",""), q.get("repeat",""), q.get("path",""),
           q.get("dev",""), q.get("qdisc_kind",""), q.get("handle",""))
    queue_groups[key].append(q)
with open(bufferbloat_queue_csv, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["scenario", "variant", "flow_group", "algo", "queue_profile", "direction", "repeat", "path", "dev", "qdisc_kind", "handle",
                "samples", "p50_backlog_bytes", "p95_backlog_bytes", "p99_backlog_bytes", "max_backlog_bytes",
                "p50_backlog_packets", "p95_backlog_packets", "max_backlog_packets", "drops_max", "overlimits_max", "requeues_max"])
    for key, qs in sorted(queue_groups.items()):
        bytes_vals = [fnum(q.get("backlog_bytes")) for q in qs]
        bytes_vals = [v for v in bytes_vals if v is not None]
        pkt_vals = [fnum(q.get("backlog_packets")) for q in qs]
        pkt_vals = [v for v in pkt_vals if v is not None]
        drops = [fnum(q.get("drops")) for q in qs]; drops = [v for v in drops if v is not None]
        over = [fnum(q.get("overlimits")) for q in qs]; over = [v for v in over if v is not None]
        req = [fnum(q.get("requeues")) for q in qs]; req = [v for v in req if v is not None]
        w.writerow([*key, len(qs),
                    f"{percentile(bytes_vals,50):.0f}" if bytes_vals else "",
                    f"{percentile(bytes_vals,95):.0f}" if bytes_vals else "",
                    f"{percentile(bytes_vals,99):.0f}" if bytes_vals else "",
                    f"{max(bytes_vals):.0f}" if bytes_vals else "",
                    f"{percentile(pkt_vals,50):.0f}" if pkt_vals else "",
                    f"{percentile(pkt_vals,95):.0f}" if pkt_vals else "",
                    f"{max(pkt_vals):.0f}" if pkt_vals else "",
                    f"{max(drops):.0f}" if drops else "",
                    f"{max(over):.0f}" if over else "",
                    f"{max(req):.0f}" if req else ""])

# Aggregated view specifically for comparing congestion algorithms' effect on
# latency under load. It keeps queue profile, direction, delay, and rate fixed.
algo_bb_groups = defaultdict(list)
for r in bufferbloat_summary_records:
    key = (scenario_family(r.get("scenario", "")), r.get("queue_profile", ""),
           r.get("direction", ""), r.get("oneway_delay", ""), r.get("rate", ""),
           r.get("algo", ""))
    algo_bb_groups[key].append(r)
with open(bufferbloat_algo_csv, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["scenario_family", "queue_profile", "direction", "oneway_delay", "rate", "algo",
                "runs", "runs_with_loaded_samples", "valid_sample_runs", "mean_loaded_p50_ms", "median_loaded_p50_ms",
                "mean_loaded_p95_ms", "median_loaded_p95_ms", "mean_delta_p95_ms",
                "median_delta_p95_ms", "mean_queue_est_p95_kbytes", "median_queue_est_p95_kbytes", "mean_loaded_max_ms"])
    for key in sorted(algo_bb_groups):
        rs = algo_bb_groups[key]
        loaded_p50 = [x["loaded_p50_ms"] for x in rs if x.get("loaded_p50_ms") is not None]
        loaded_p95 = [x["loaded_p95_ms"] for x in rs if x.get("loaded_p95_ms") is not None]
        delta = [x["bufferbloat_delta_p95_ms"] for x in rs if x.get("bufferbloat_delta_p95_ms") is not None]
        loaded_max = [x["loaded_max_ms"] for x in rs if x.get("loaded_max_ms") is not None]
        queue_est_p95 = [x["queue_est_p95_kbytes"] for x in rs if x.get("queue_est_p95_kbytes") is not None]
        loaded_runs = sum(1 for x in rs if (x.get("loaded_samples") or 0) > 0)
        valid_sample_runs = sum(1 for x in rs if str(x.get("sample_valid", "")) == "1")
        w.writerow([*key, len(rs), loaded_runs, valid_sample_runs,
                    f"{statistics.mean(loaded_p50):.3f}" if loaded_p50 else "",
                    f"{statistics.median(loaded_p50):.3f}" if loaded_p50 else "",
                    f"{statistics.mean(loaded_p95):.3f}" if loaded_p95 else "",
                    f"{statistics.median(loaded_p95):.3f}" if loaded_p95 else "",
                    f"{statistics.mean(delta):.3f}" if delta else "",
                    f"{statistics.median(delta):.3f}" if delta else "",
                    f"{statistics.mean(queue_est_p95):.3f}" if queue_est_p95 else "",
                    f"{statistics.median(queue_est_p95):.3f}" if queue_est_p95 else "",
                    f"{statistics.mean(loaded_max):.3f}" if loaded_max else ""])

# Long-format canonical metrics table. Convenience wide CSVs remain available,
# but metrics.csv is easier to concatenate and plot across benchmark runs.
def add_metric(writer, case_id, metric_scope, metric_family, scen_family, scenario,
               variant, flow_group, algo, peer_algo, role, direction, queue_profile,
               oneway_delay_ms, data_rate_mbps, statistic, metric_name, value, unit,
               sample_count, source_table):
    if value is None or value == "":
        return
    writer.writerow([schema_version, run_id, case_id, metric_scope, metric_family,
                     scen_family, scenario, variant, flow_group, algo, peer_algo,
                     role, direction, queue_profile, oneway_delay_ms, data_rate_mbps,
                     statistic, metric_name, value, unit, sample_count, source_table])

with open(metrics_csv, "w", newline="") as f:
    mw = csv.writer(f)
    mw.writerow(["schema_version", "run_id", "case_id", "metric_scope", "metric_family", "scenario_family", "scenario", "variant", "flow_group", "algo", "peer_algo", "role", "direction", "queue_profile", "oneway_delay_ms", "data_rate_mbps", "statistic", "metric_name", "value", "unit", "sample_count", "source_table"])

    for r in read_csv(scenario_algo_csv):
        case_id = f"scenario_algo:{r.get('scenario_family','')}:{r.get('algo','')}:{r.get('variant','')}"
        for stat, name, unit in [("mean", "rx_mbps", "mbps"), ("median", "rx_mbps", "mbps"), ("p10", "rx_mbps", "mbps"), ("p90", "rx_mbps", "mbps"), ("mean", "retrans_per_gbit", "count_per_gbit")]:
            src_col = {("mean", "rx_mbps"): "mean_rx_mbps", ("median", "rx_mbps"): "median_rx_mbps", ("p10", "rx_mbps"): "p10_rx_mbps", ("p90", "rx_mbps"): "p90_rx_mbps", ("mean", "retrans_per_gbit"): "mean_retrans_per_gbit"}[(stat, name)]
            add_metric(mw, case_id, "scenario_algo", "throughput" if name == "rx_mbps" else "retransmit", r.get("scenario_family", ""), "", r.get("variant", ""), "", r.get("algo", ""), "", "primary", "", "", "", "", stat, name, r.get(src_col, ""), unit, r.get("successes", ""), "scenario-algo-summary.csv")
        add_metric(mw, case_id, "scenario_algo", "run_count", r.get("scenario_family", ""), "", r.get("variant", ""), "", r.get("algo", ""), "", "primary", "", "", "", "", "count", "failures", r.get("failures", ""), "count", r.get("runs", ""), "scenario-algo-summary.csv")

    for r in read_csv(fairness_csv):
        scen = r.get("scenario", ""); sf = scenario_family(scen); case_id = r.get("flow_group", "")
        add_metric(mw, case_id, "flow_fairness", "fairness", sf, scen, r.get("variant", ""), r.get("flow_group", ""), "", "", "", "", "", "", "", "value", "jain_fairness", r.get("jain_fairness", ""), "ratio", r.get("flow_count", ""), "flow-fairness.csv")
        add_metric(mw, case_id, "flow_fairness", "throughput", sf, scen, r.get("variant", ""), r.get("flow_group", ""), "", "", "", "", "", "", "", "sum", "total_rx_mbps", r.get("total_rx_mbps", ""), "mbps", r.get("flow_count", ""), "flow-fairness.csv")

    for r in read_csv(bufferbloat_csv):
        scen = r.get("scenario", ""); sf = scenario_family(scen); case_id = r.get("flow_group", "")
        for stat, col, name, unit in [("p50", "idle_p50_ms", "idle_rtt", "ms"), ("p50", "loaded_p50_ms", "loaded_rtt", "ms"), ("p95", "loaded_p95_ms", "loaded_rtt", "ms"), ("p99", "loaded_p99_ms", "loaded_rtt", "ms"), ("max", "loaded_max_ms", "loaded_rtt", "ms"), ("delta_p50", "bufferbloat_delta_p50_ms", "loaded_minus_idle", "ms"), ("delta_p95", "bufferbloat_delta_p95_ms", "loaded_minus_idle", "ms"), ("p95_est", "queue_est_p95_kbytes", "estimated_queue", "kbytes"), ("p50", "recovery_p50_ms", "recovery_rtt", "ms")]:
            add_metric(mw, case_id, "bufferbloat", "rtt" if unit == "ms" else "queue", sf, scen, r.get("variant", ""), r.get("flow_group", ""), r.get("algo", ""), "", "probe", r.get("direction", ""), r.get("queue_profile", ""), "", "", stat, name, r.get(col, ""), unit, r.get("loaded_samples", ""), "bufferbloat-summary.csv")

    for r in read_csv(bufferbloat_algo_csv):
        case_id = f"bufferbloat_algo:{r.get('scenario_family','')}:{r.get('queue_profile','')}:{r.get('direction','')}:{r.get('oneway_delay','')}:{r.get('rate','')}:{r.get('algo','')}"
        for stat, col, name, unit in [("mean_p50", "mean_loaded_p50_ms", "loaded_rtt", "ms"), ("median_p50", "median_loaded_p50_ms", "loaded_rtt", "ms"), ("mean_p95", "mean_loaded_p95_ms", "loaded_rtt", "ms"), ("median_p95", "median_loaded_p95_ms", "loaded_rtt", "ms"), ("mean_delta_p95", "mean_delta_p95_ms", "loaded_minus_idle", "ms"), ("median_delta_p95", "median_delta_p95_ms", "loaded_minus_idle", "ms"), ("mean_queue_est_p95", "mean_queue_est_p95_kbytes", "estimated_queue", "kbytes"), ("median_queue_est_p95", "median_queue_est_p95_kbytes", "estimated_queue", "kbytes"), ("mean_max", "mean_loaded_max_ms", "loaded_rtt", "ms")]:
            add_metric(mw, case_id, "bufferbloat_algo", "rtt" if unit == "ms" else "queue", r.get("scenario_family", ""), "", "", "", r.get("algo", ""), "", "probe", r.get("direction", ""), r.get("queue_profile", ""), "", "", stat, name, r.get(col, ""), unit, r.get("runs_with_loaded_samples", ""), "bufferbloat-algo-summary.csv")

# Human-readable report.
primary_success = [r for r in rows if r.get("role") == "primary" and is_success(r)]
with open(analysis_report, "w") as f:
    f.write("# Netem congestion-control benchmark analysis\n\n")
    f.write("## Run summary\n\n")
    f.write(f"- Run ID: `{run_id}`\n")
    f.write(f"- Schema version: `{schema_version}`\n")
    f.write(f"- Flow/run rows: {len(rows)}\n")
    f.write(f"- Failed rows: {len(failures)}\n")
    f.write(f"- Primary successful rows: {len(primary_success)}\n\n")
    f.write("## Canonical data files\n\n")
    f.write(f"- `{summary_path}` — one row per iperf3 flow/run.\n")
    f.write(f"- `{intervals_path}` — one row per iperf3 interval.\n")
    f.write(f"- `{ping_csv}` — parsed RTT probe samples.\n")
    f.write(f"- `{queue_csv}` — direct qdisc backlog samples during loaded bufferbloat phases.\n")
    f.write(f"- `{metrics_csv}` — long-format aggregate metrics.\n")
    f.write(f"- `{failures_csv}` — failed or incomplete iperf3 rows.\n\n")
    f.write("## Convenience analysis views\n\n")
    f.write(f"- `{scenario_algo_csv}`\n")
    f.write(f"- `{fairness_csv}`\n")
    f.write(f"- `{bufferbloat_csv}`\n")
    f.write(f"- `{bufferbloat_algo_csv}`\n")
    f.write(f"- `{bufferbloat_queue_csv}`\n\n")
    if failures:
        f.write("## Failure count by scenario family\n\n")
        fam_fail = defaultdict(int)
        for r in failures:
            fam_fail[r.get("scenario_family") or scenario_family(r.get("scenario", ""))] += 1
        for fam, count in sorted(fam_fail.items(), key=lambda x: (-x[1], x[0])):
            f.write(f"- {fam}: {count}\n")
        f.write("\n")
    if bufferbloat_rows:
        f.write("## Worst bufferbloat deltas\n\n")
        f.write("Loaded p95 RTT minus idle p50 RTT, highest first.\n\n")
        for delta, row in sorted(bufferbloat_rows, key=lambda x: -x[0])[:10]:
            f.write(f"- {row[0]} / algo={row[3]} / queue={row[4]} / direction={row[5]}: delta_p95={delta:.3f} ms, loaded_p95={row[14]} ms, est_queue_p95={row[20]} KiB, valid_samples={row[26]}\n")
        f.write("\n")
    f.write("## Notes\n\n")
    f.write("- Bufferbloat scenarios now default to `pfifo_deep`, an unmanaged deep FIFO implemented as a deep netem FIFO at the router bottleneck. Use `BUFFERBLOAT_QUEUE_PROFILE=fq|fq_codel|cake` only for separate managed-queue comparisons.\n")
    f.write("- Bufferbloat views include RTT inflation, estimated queue size from RTT inflation, sample-count validity flags, and direct qdisc backlog samples from `data/queue_samples.csv`.\n")
    f.write("- For flow_fairness, use `data/flow-fairness.csv` or `data/metrics.csv` rows with `metric_name=jain_fairness`. Values closer to 1.0 are fairer.\n")
    f.write("- `retrans_per_gbit` in `data/runs.csv` normalizes retransmissions by delivered data.\n")
    f.write("- Bufferbloat views compare idle RTT with loaded RTT; `delta_p95` is loaded p95 minus idle p50.\n")

with open(analysis_report, "r") as f:
    print(f.read(), end="")
PYREPORT
}
scenario_in_list() {
  local needle="$1" item
  shift
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

expand_test_groups() {
  local -a out=()
  local group item items
  for group in $1; do
    case "$group" in
      standard)
        items="baseline latency_spike latency_reduction jitter_long_tail capacity_drop sustain_loss loss_spike policer_static policer_spike policer_adaptive_rate policer_adaptive_retrans ack_rate_limit flow_fairness short_flow_under_load bufferbloat_upload bufferbloat_download bufferbloat_bidirectional profile_proxy_mobile_china"
        ;;
      core)
        items="baseline latency_spike latency_reduction capacity_drop"
        ;;
      latency)
        items="baseline latency_spike latency_reduction jitter_light jitter_heavy jitter_long_tail reorder_light reorder_heavy"
        ;;
      loss)
        items="sustain_loss loss_bursts loss_spike jitter_light jitter_heavy jitter_long_tail reorder_light reorder_heavy"
        ;;
      policing)
        items="policer_static policer_spike policer_adaptive_rate policer_adaptive_retrans"
        ;;
      competition)
        items="flow_fairness flow_fairness_sustain_loss flow_fairness_loss_spike flow_fairness_latency_spike flow_fairness_capacity_drop flow_fairness_policer flow_fairness_ack_limit flow_fairness_jitter flow_fairness_reorder"
        ;;
      flow_fairness)
        items="flow_fairness flow_fairness_sustain_loss flow_fairness_loss_spike flow_fairness_latency_spike flow_fairness_capacity_drop flow_fairness_policer flow_fairness_ack_limit flow_fairness_jitter flow_fairness_reorder"
        ;;
      bufferbloat)
        items="bufferbloat_upload bufferbloat_download bufferbloat_bidirectional"
        ;;
      ack_path)
        items="ack_rate_limit ack_loss ack_delay_spike ack_bufferbloat"
        ;;
      short_flow)
        items="short_flow_repeated short_flow_under_load"
        ;;
      real_world_profiles)
        items="profile_proxy_mobile_china"
        ;;
      combined)
        items="combined_all"
        ;;
      all)
        items="baseline latency_spike latency_reduction jitter_light jitter_heavy jitter_long_tail reorder_light reorder_heavy capacity_drop sustain_loss loss_bursts loss_spike policer_static policer_spike policer_adaptive_rate policer_adaptive_retrans ack_rate_limit ack_loss ack_delay_spike ack_bufferbloat flow_fairness flow_fairness_sustain_loss flow_fairness_loss_spike flow_fairness_latency_spike flow_fairness_capacity_drop flow_fairness_policer flow_fairness_ack_limit flow_fairness_jitter flow_fairness_reorder short_flow_repeated short_flow_under_load bufferbloat_upload bufferbloat_download bufferbloat_bidirectional profile_proxy_mobile_china combined_all"
        ;;
      *)
        items="$group"
        ;;
    esac
    for item in $items; do
      if [[ " ${out[*]} " != *" ${item} "* ]]; then
        out+=("$item")
      fi
    done
  done
  printf '%s\n' "${out[*]}"
}

rate_values_for_scenario() {
  local scenario="$1"
  local values="$CONFIGURED_BASE_RATE"
  case "$RATE_MODE" in
    single)
      values="$CONFIGURED_BASE_RATE"
      ;;
    sweep)
      values="$RATE_SWEEP"
      ;;
    scenario)
      values="$CONFIGURED_BASE_RATE"
      ;;
    *)
      die "Unknown RATE_MODE=${RATE_MODE}. Use single, sweep, or scenario."
      ;;
  esac
  case "$scenario" in
    flow_fairness|flow_fairness_*) values="$COMPETITION_RECEIVER_RATE" ;;
    profile_proxy_mobile_china) values="$PROXY_BACKHAUL_RATE" ;;
  esac

  if [[ "$ENABLE_10G_STRESS" == "1" || "$ENABLE_10G_STRESS" == "yes" || "$ENABLE_10G_STRESS" == "true" ]]; then
    local item should_add=0
    for item in $TEN_G_SCENARIOS; do
      if [[ "$scenario" == "$item" ]]; then
        should_add=1
        break
      fi
    done
    if (( should_add == 1 )) && [[ " $values " != *" $TEN_G_RATE "* ]]; then
      values="$values $TEN_G_RATE"
    fi
  fi
  printf '%s\n' "$values"
}


load_algo_lists() {
  local selected_text competitor_text
  selected_text="$(select_algos)" || return 1
  mapfile -t SELECTED_ALGOS <<< "$selected_text"
  competitor_text="$(select_competitor_algos)" || return 1
  mapfile -t COMPETITOR_ALGO_LIST <<< "$competitor_text"
}

is_parallel_lightweight_scenario() {
  local needle="$1" item
  for item in $PARALLEL_LIGHTWEIGHT_SCENARIOS; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

requested_has_parallel_scenario() {
  local scenario
  for scenario in $SCENARIOS; do
    if is_parallel_lightweight_scenario "$scenario"; then
      return 0
    fi
  done
  return 1
}

parallel_worker_count() {
  local workers="${PARALLEL_WORKERS:-1}" cores
  if [[ "$workers" == "auto" ]]; then
    cores="$(nproc 2>/dev/null || printf '2\n')"
    if is_positive_integer "$cores"; then
      workers=$(( cores / 2 ))
      if (( workers < 1 )); then
        workers=1
      fi
    else
      workers=1
    fi
  fi
  if ! is_positive_integer "$workers"; then
    workers=1
  fi
  printf '%s\n' "$workers"
}

lightweight_parallel_enabled() {
  [[ "${PARALLEL_CHILD:-0}" == "1" ]] && return 1
  case "${LIGHTWEIGHT_PARALLEL:-0}" in
    1|yes|true|on|auto) ;;
    *) return 1 ;;
  esac
  local workers
  workers="$(parallel_worker_count)"
  (( workers > 1 ))
}

parallel_worker_ips() {
  local worker_id="$1" prefix="$2"
  local net1 net2 a2 a3 b2 b3
  net1=$((1 + 2 * worker_id))
  net2=$((2 + 2 * worker_id))
  a2=$((10 + net1 / 256)); a3=$((net1 % 256))
  b2=$((10 + net2 / 256)); b3=$((net2 % 256))
  if (( a2 > 250 || b2 > 250 )); then
    die "Too many parallel worker IDs generated for automatic namespace IP allocation"
  fi
  printf -v "${prefix}_C_IP" '10.%d.%d.2' "$a2" "$a3"
  printf -v "${prefix}_R_C_IP" '10.%d.%d.1' "$a2" "$a3"
  printf -v "${prefix}_S_IP" '10.%d.%d.2' "$b2" "$b3"
  printf -v "${prefix}_R_S_IP" '10.%d.%d.1' "$b2" "$b3"
}

spawn_lightweight_child() {
  local worker_id="$1"
  local scenarios_for_child="$2"
  local algos_for_child="$3"
  local child_out="$4"
  local script_path
  local child_C_IP child_R_C_IP child_S_IP child_R_S_IP

  script_path="$(readlink -f "$0" 2>/dev/null || printf '%s\n' "$0")"
  parallel_worker_ips "$worker_id" child
  mkdir -p "$child_out"

  log "Starting parallel worker ${worker_id}: scenarios='${scenarios_for_child}' algos='${algos_for_child}' out=${child_out}"
  (
    export PARALLEL_CHILD=1
    export PARALLEL_WORKER_ID="$worker_id"
    export LIGHTWEIGHT_PARALLEL=0
    export OUT_DIR="$child_out"
    export RUN_ID="$(basename "$child_out")"
    export SCENARIOS="$scenarios_for_child"
    export ALGOS="$algos_for_child"

    # Unique namespace and veth names prevent child workers from touching each
    # other's topology. Interface names stay below Linux's 15-character limit.
    export C_NS="${C_NS}_pw${worker_id}"
    export R_NS="${R_NS}_pw${worker_id}"
    export S_NS="${S_NS}_pw${worker_id}"
    export C_IF="c${worker_id}x"
    export R_C_IF="rc${worker_id}x"
    export S_IF="s${worker_id}x"
    export R_S_IF="rs${worker_id}x"
    export C_IP="$child_C_IP"
    export R_C_IP="$child_R_C_IP"
    export S_IP="$child_S_IP"
    export R_S_IP="$child_R_S_IP"

    exec bash "$script_path"
  )
}

append_csv_body() {
  local src="$1" dst="$2"
  if [[ -f "$src" ]]; then
    tail -n +2 "$src" >> "$dst"
  fi
}

merge_lightweight_parallel_outputs() {
  local workers_root="$1"
  local child_dir
  for child_dir in "$workers_root"/*; do
    [[ -d "$child_dir" ]] || continue
    append_csv_body "${child_dir}/data/runs.csv" "$SUMMARY_CSV"
    append_csv_body "${child_dir}/data/intervals.csv" "$INTERVALS_CSV"
    append_csv_body "${child_dir}/data/rtt_samples.csv" "$PING_CSV"
    append_csv_body "${child_dir}/data/queue_samples.csv" "$QUEUE_CSV"
    append_csv_body "${child_dir}/data/events.csv" "$EVENTS_CSV"
    if [[ -f "${child_dir}/report.md" ]]; then
      printf 'worker_report=%s\n' "${child_dir}/report.md" >> "$META_FILE"
    fi
  done
}

run_lightweight_parallel_parent() {
  local workers workers_root scenario algo child_out status active failures job_id
  local -a parallel_scenarios=() sequential_scenarios=()

  workers="$(parallel_worker_count)"
  setup_dirs
  load_congestion_modules
  load_algo_lists

  for scenario in $SCENARIOS; do
    if is_parallel_lightweight_scenario "$scenario"; then
      parallel_scenarios+=("$scenario")
    else
      sequential_scenarios+=("$scenario")
    fi
  done

  workers_root="${OUT_DIR}/parallel-workers"
  mkdir -p "$workers_root"
  {
    echo "parallel_mode=parent"
    echo "parallel_effective_workers=${workers}"
    echo "parallel_selected_algos=${SELECTED_ALGOS[*]}"
    echo "parallel_selected_lightweight_scenarios=${parallel_scenarios[*]}"
    echo "parallel_sequential_scenarios=${sequential_scenarios[*]}"
    echo "parallel_workers_root=${workers_root}"
  } >> "$META_FILE"

  log "Selected congestion controls: ${SELECTED_ALGOS[*]}"
  log "Competitor congestion controls: ${COMPETITOR_ALGO_LIST[*]}"
  log "Lightweight multiprocessing enabled: workers=${workers}; parallel scenarios: ${parallel_scenarios[*]}"
  if ((${#sequential_scenarios[@]})); then
    log "Non-lightweight scenarios kept sequential: ${sequential_scenarios[*]}"
  fi
  log "Results: ${OUT_DIR}"

  active=0
  failures=0
  job_id=0
  for scenario in "${parallel_scenarios[@]}"; do
    for algo in "${SELECTED_ALGOS[@]}"; do
      job_id=$((job_id + 1))
      child_out="${workers_root}/w$(printf '%03d' "$job_id")_$(safe_name "$scenario")_$(safe_name "$algo")"
      spawn_lightweight_child "$job_id" "$scenario" "$algo" "$child_out" &
      active=$((active + 1))
      if (( active >= workers )); then
        set +e
        wait -n
        status=$?
        set -e
        if (( status != 0 )); then
          failures=$((failures + 1))
        fi
        active=$((active - 1))
      fi
    done
  done

  while (( active > 0 )); do
    set +e
    wait -n
    status=$?
    set -e
    if (( status != 0 )); then
      failures=$((failures + 1))
    fi
    active=$((active - 1))
  done

  # Run dynamic, competition, bufferbloat, profile, and other high-noise tests
  # after the parallel static workers so their results are not affected by host
  # CPU pressure from unrelated iperf3 jobs.
  if ((${#sequential_scenarios[@]})); then
    job_id=$((job_id + 1))
    child_out="${workers_root}/w$(printf '%03d' "$job_id")_sequential_remaining"
    set +e
    spawn_lightweight_child "$job_id" "${sequential_scenarios[*]}" "${SELECTED_ALGOS[*]}" "$child_out"
    status=$?
    set -e
    if (( status != 0 )); then
      failures=$((failures + 1))
    fi
  fi

  merge_lightweight_parallel_outputs "$workers_root"
  generate_analysis_reports
  log "Analysis reports: ${ANALYSIS_REPORT}, ${SCENARIO_ALGO_CSV}, ${FLOW_FAIRNESS_CSV}, ${FAILURES_CSV}, ${METRICS_CSV}, ${BUFFERBLOAT_CSV}, ${BUFFERBLOAT_ALGO_CSV}, ${BUFFERBLOAT_QUEUE_CSV}"
  if (( failures > 0 )); then
    log "Done with ${failures} failed worker process(es). Results saved in ${OUT_DIR}"
    return 1
  fi
  log "Done. Results saved in ${OUT_DIR}"
  return 0
}

main() {
  require_root
  require_cmds
  if [[ -n "$TEST_GROUPS" && "$USER_SCENARIOS_SET" == "0" ]]; then
    SCENARIOS="$(expand_test_groups "$TEST_GROUPS")"
  fi
  set_active_rate "$CONFIGURED_BASE_RATE"
  if lightweight_parallel_enabled && requested_has_parallel_scenario; then
    local parallel_status=0
    run_lightweight_parallel_parent || parallel_status=$?
    return "$parallel_status"
  fi
  setup_dirs
  load_congestion_modules
  load_algo_lists
  setup_topology
  start_servers

  log "Selected congestion controls: ${SELECTED_ALGOS[*]}"
  log "Competitor congestion controls: ${COMPETITOR_ALGO_LIST[*]}"
  log "Latency mode: ${LATENCY_MODE}; full latency set: ${LATENCY_SWEEP_DELAYS}"
  log "Scenarios: ${SCENARIOS}"
  log "Results: ${OUT_DIR}"

  local scenario algo repeat latency rate scenario_latencies scenario_rates
  for repeat in $(seq 1 "$REPEATS"); do
    for scenario in $SCENARIOS; do
      scenario_rates="$(rate_values_for_scenario "$scenario")"
      log "Scenario=${scenario} rate-list: ${scenario_rates}"
      for rate in $scenario_rates; do
        set_active_rate "$rate"
        case "$scenario" in
          latency_sweep|combined_all)
            set_active_latency "$ONEWAY_DELAY"
            for algo in "${SELECTED_ALGOS[@]}"; do
              run_scenario "$scenario" "$algo" "$repeat"
              sleep "$RUN_COOLDOWN"
            done
            ;;
          *)
            scenario_latencies="$(latency_values_for_scenario "$scenario")"
            log "Scenario=${scenario} rate=${rate} latency-list: ${scenario_latencies}"
            for latency in $scenario_latencies; do
              set_active_latency "$latency"
              for algo in "${SELECTED_ALGOS[@]}"; do
                run_scenario "$scenario" "$algo" "$repeat"
                sleep "$RUN_COOLDOWN"
              done
            done
            ;;
        esac
      done
      set_active_rate "$CONFIGURED_BASE_RATE"
    done
  done

  # Generate the compact, decision-oriented report last. It replaces the old
  # enormous row dump and also writes the derived CSVs used for fairness,
  # retransmit-efficiency and failure analysis.
  generate_analysis_reports
  log "Analysis reports: ${ANALYSIS_REPORT}, ${SCENARIO_ALGO_CSV}, ${FLOW_FAIRNESS_CSV}, ${FAILURES_CSV}, ${METRICS_CSV}, ${BUFFERBLOAT_CSV}, ${BUFFERBLOAT_ALGO_CSV}, ${BUFFERBLOAT_QUEUE_CSV}"
  log "Done. Results saved in ${OUT_DIR}"
}


main "$@"
