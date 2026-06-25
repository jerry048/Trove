/* TCP BBR-Brutal congestion control
 *
 * BBR-Brutal is an out-of-tree DKMS TCP congestion-control module derived from
 * Linux TCP BBR. It keeps BBR-style STARTUP, DRAIN, and PROBE_RTT, but
 * replaces the standard steady-state PROBE_BW cycle with the Brutal cycle.
 *
 *   bottleneck_bandwidth = windowed_max(delivered / elapsed, 10 rounds)
 *   min_rtt              = windowed_min(rtt, 10 seconds)
 *   pacing_rate          = effective_pacing_gain * bottleneck_bandwidth
 *   cwnd                 = cwnd_gain * bottleneck_bandwidth * min_rtt,
 *                          floored at 4 packets
 *
 * The Brutal PROBE_BW cycle has eight phases:
 *
 *   CRUISE[0..5]: pacing_gain = 1.00 with Brutal loss compensation
 *   PROBE_UP:     pacing_gain = 1.25, no Brutal loss compensation; exit when
 *                 the current loss sample is higher than the approximate P95
 *                 loss observed during the last CRUISE phase, or when
 *                 estimated in-flight reaches 1.25 * BDP
 *   DRAIN:        pacing_gain = 0.75, no Brutal loss compensation, until
 *                 in-flight is <= estimated BDP
 *
 * If LOSS_GUARD is active or the long-term policer estimator is using lt_bw,
 * gain cycling stops, Brutal compensation is disabled, and BBR's
 * packet-conservation loss-recovery behavior is armed.
 *
 * This variant keeps BBRv1-style PROBE_RTT. When the min_rtt filter expires
 * on a continuously busy flow, it temporarily caps cwnd to 4 packets for at
 * least 200 ms and one packet-timed round, then returns to STARTUP or
 * BBR-Brutal PROBE_BW.
 *
 * This remains experimental and is intended for controlled testing.
 */
#include <linux/module.h>
#include <linux/version.h>
#include <net/tcp.h>
#include <linux/inet_diag.h>
#include <linux/inet.h>
#include <linux/random.h>
#include <linux/win_minmax.h>


/*
 * DKMS/out-of-tree compatibility notes:
 * - Linux < 5.19 did not have tcp_snd_cwnd()/tcp_snd_cwnd_set().
 * - Linux < 6.2 used prandom_u32_max() where newer kernels use
 *   get_random_u32_below().
 * - Some older kernels use GSO_MAX_SIZE instead of GSO_LEGACY_MAX_SIZE.
 * - Linux >= 6.10 changed tcp_congestion_ops.cong_control() signature.
 * - Linux >= 7.1 split CA_EVENT_TX_START into cwnd_event_tx_start().
 * - BBRv3/L4S kernels can carry TCP congestion-control API changes without
 *   matching upstream LINUX_VERSION_CODE, so the Makefile probes the target
 *   include/net/tcp.h and passes BBRB_TCP_CA_* feature macros.
 */
#ifndef GSO_LEGACY_MAX_SIZE
#define GSO_LEGACY_MAX_SIZE GSO_MAX_SIZE
#endif

#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 19, 0)
static inline u32 bbr_brutal_tcp_snd_cwnd(const struct tcp_sock *tp)
{
	return tp->snd_cwnd;
}

static inline void bbr_brutal_tcp_snd_cwnd_set(struct tcp_sock *tp, u32 val)
{
	/* Match upstream semantics as closely as possible for older kernels. */
	WARN_ON_ONCE((int)val <= 0);
	WRITE_ONCE(tp->snd_cwnd, val);
}

#define tcp_snd_cwnd(tp) bbr_brutal_tcp_snd_cwnd(tp)
#define tcp_snd_cwnd_set(tp, val) bbr_brutal_tcp_snd_cwnd_set(tp, val)
#endif

static inline u32 bbr_brutal_random_u32_below(u32 ceil)
{
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 2, 0)
	return get_random_u32_below(ceil);
#else
	return prandom_u32_max(ceil);
#endif
}

/* Scale factor for rate in pkt/uSec unit to avoid truncation in bandwidth
 * estimation. The rate unit ~= (1500 bytes / 1 usec / 2^24) ~= 715 bps.
 * This handles bandwidths from 0.06pps (715bps) to 256Mpps (3Tbps) in a u32.
 * Since the minimum window is >=4 packets, the lower bound isn't
 * an issue. The upper bound isn't an issue with existing technologies.
 */
#define BW_SCALE 24
#define BW_UNIT (1 << BW_SCALE)

#define BBR_SCALE 8	/* scaling factor for fractions in BBR (e.g. gains) */
#define BBR_UNIT (1 << BBR_SCALE)

/* BBR-Brutal uses these top-level modes. */
enum bbr_mode {
	BBR_STARTUP,	/* ramp up sending rate rapidly to fill pipe */
	BBR_DRAIN,	/* drain any queue created during startup */
	BBR_PROBE_BW,	/* steady-state ProbeBW with Brutal CRUISE */
	BBR_PROBE_RTT,	/* cut inflight to min to probe min_rtt */
};

enum bbr_brutal_cycle_phase {
	BBR_BRUTAL_CRUISE_0 = 0,
	BBR_BRUTAL_CRUISE_1,
	BBR_BRUTAL_CRUISE_2,
	BBR_BRUTAL_CRUISE_3,
	BBR_BRUTAL_CRUISE_4,
	BBR_BRUTAL_CRUISE_5,
	BBR_BRUTAL_PROBE_UP,
	BBR_BRUTAL_DRAIN,
};

/* BBR congestion control block */
struct bbr {
	u32	min_rtt_us;	        /* min RTT in bbr_min_rtt_win_sec window */
	u32	min_rtt_stamp;	        /* timestamp of min_rtt_us */
	u32	probe_rtt_done_stamp;   /* end time for BBR_PROBE_RTT mode */
	u16	cruise_loss_bins_lo; /* 2-bit loss-pct histogram bins 0..7 */
	u16	cruise_loss_bins_hi; /* 2-bit loss-pct histogram bins 8..15 */
	struct minmax bw;	/* Max recent delivery rate in pkts/uS << 24 */
	u32	rtt_cnt;	    /* count of packet-timed rounds elapsed */
	u32     next_rtt_delivered; /* scb->tx.delivered at end of round */
	u64	cycle_mstamp;	     /* time of this cycle phase start */
	u32     mode:2,	             /* current bbr_mode in state machine */
		prev_ca_state:3,     /* CA state on previous ACK */
		packet_conservation:1,  /* use packet conservation? */
		round_start:1,	     /* start of packet-timed tx->ack round? */
		idle_restart:1,	     /* restarting after idle? */
		probe_rtt_round_done:1,  /* a BBR_PROBE_RTT round at min cwnd? */
		loss_guard:1,        /* loss_guard or lt_bw packet conservation? */
		brutal_loss_pct:7,   /* current loss sample percentage, 0..100 */
		unused:7,
		lt_is_sampling:1,    /* taking long-term ("LT") samples now? */
		lt_rtt_cnt:6,	     /* round trips in long-term interval */
		lt_use_bw:1;	     /* use lt_bw as our bw estimate? */
	u32	lt_bw;		     /* LT est delivery rate in pkts/uS << 24 */
	u32	lt_last_delivered;   /* LT intvl start: tp->delivered */
	u32	lt_last_stamp;	     /* LT intvl start: tp->delivered_mstamp */
	u32	lt_last_lost;	     /* LT intvl start: tp->lost */
	u32	pacing_gain:11,	/* current gain for setting pacing rate */
		cwnd_gain:11,	/* current gain for setting cwnd */
		full_bw_reached:1,   /* reached full bw in Startup? */
		full_bw_cnt:4,	/* number of rounds without large bw gains */
		cycle_idx:3,	/* current index in pacing_gain cycle array */
		has_seen_rtt:1, /* have we seen an RTT sample yet? */
		brutal_recovery:1; /* loss_guard/LT packet conservation */
	u32	prior_cwnd;	/* prior cwnd upon entering loss recovery */
	u32	full_bw;	/* recent bw, to estimate if pipe is full */

	/* For tracking ACK aggregation: */
	u64	ack_epoch_mstamp;	/* start of ACK sampling epoch */
	u16	extra_acked[2];		/* max excess data ACKed in epoch */
	u32	ack_epoch_acked:20,	/* packets (S)ACKed in sampling epoch */
		extra_acked_win_rtts:5,	/* age of extra_acked, in round trips */
		extra_acked_win_idx:1,	/* current index in extra_acked array */
		unused_c:6;
};

#define CYCLE_LEN	8	/* CRUISE x6, PROBE_UP, DRAIN */
#define BBR_BRUTAL_CRUISE_PHASES	6
#define BBR_BRUTAL_LOSS_BINS	16

/* Window length of the bottleneck-bandwidth max filter, in packet-timed
 * rounds. This is 10 rounds in this variant.
 */
static const int bbr_bw_rtts = 10;
/* Window length of the min_rtt filter, in seconds. */
static const u32 bbr_min_rtt_win_sec = 10;
/* Minimum time spent at the cwnd floor in BBR_PROBE_RTT mode, in ms. */
static const u32 bbr_probe_rtt_mode_ms = 200;
/* Skip TSO below the following bandwidth (bits/sec): */
static const int bbr_min_tso_rate = 1200000;

/* Brutal variants use no pacing margin so the configured gains remain exact.
 * Brutal loss compensation is applied separately in CRUISE.
 */
static const int bbr_pacing_margin_percent = 0;

/* Brutal compensation uses ack_percent = 100 - loss_percent, floored at 80%,
 * giving a maximum compensation multiplier of 1.25x. LOSS_GUARD disables the
 * compensation when the last completed packet-timed round had >20% loss.
 */
static unsigned int bbr_brutal_min_ack_percent = 80;
module_param_named(min_ack_percent, bbr_brutal_min_ack_percent, uint, 0644);
MODULE_PARM_DESC(min_ack_percent,
			 "minimum ACK success percent for Brutal compensation");

static unsigned int bbr_brutal_loss_guard_percent = 20;
module_param_named(loss_guard_percent, bbr_brutal_loss_guard_percent, uint, 0644);
MODULE_PARM_DESC(loss_guard_percent,
			 "loss percent above which Brutal compensation is disabled");

/* We use a high_gain value of 2/ln(2) because it's the smallest pacing gain
 * that will allow a smoothly increasing pacing rate that will double each RTT
 * and send the same number of packets per RTT that an un-paced, slow-starting
 * Reno or CUBIC flow would:
 */
static const int bbr_high_gain  = BBR_UNIT * 2885 / 1000 + 1;
/* The pacing gain of 1/high_gain in BBR_DRAIN is calculated to typically drain
 * the queue created in BBR_STARTUP in a single round:
 */
static const int bbr_drain_gain = BBR_UNIT * 1000 / 2885;
/* The gain for deriving steady-state cwnd tolerates delayed/stretched ACKs: */
static const int bbr_cwnd_gain  = BBR_UNIT * 2;
/* Brutal PROBE_BW gain cycle: six CRUISE phases, then PROBE_UP and DRAIN. */
static const int bbr_pacing_gain[] = {
	[BBR_BRUTAL_CRUISE_0] = BBR_UNIT,		/* 1.00 + Brutal comp */
	[BBR_BRUTAL_CRUISE_1] = BBR_UNIT,		/* 1.00 + Brutal comp */
	[BBR_BRUTAL_CRUISE_2] = BBR_UNIT,		/* 1.00 + Brutal comp */
	[BBR_BRUTAL_CRUISE_3] = BBR_UNIT,		/* 1.00 + Brutal comp */
	[BBR_BRUTAL_CRUISE_4] = BBR_UNIT,		/* 1.00 + Brutal comp */
	[BBR_BRUTAL_CRUISE_5] = BBR_UNIT,		/* 1.00 + Brutal comp */
	[BBR_BRUTAL_PROBE_UP] = BBR_UNIT * 5 / 4,	/* 1.25, no comp */
	[BBR_BRUTAL_DRAIN]    = BBR_UNIT * 3 / 4,	/* 0.75 until <= BDP */
};
/* Percentile of last-CRUISE loss used as the PROBE_UP loss exit threshold. */
static const u32 bbr_brutal_loss_percentile = 95;

/* Keep at least four packets in flight when possible. This supports
 * ACK-every-other-packet delayed ACK behavior and is also the PROBE_RTT cwnd
 * cap in variants that implement PROBE_RTT.
 */
static const u32 bbr_cwnd_min_target = 4;

/* To estimate if BBR_STARTUP mode (i.e. high_gain) has filled pipe... */
/* If bw has increased by at least 25%, there may be more bw available. */
static const u32 bbr_full_bw_thresh = BBR_UNIT * 5 / 4;
/* After 3 rounds without that growth, estimate the pipe is full. */
static const u32 bbr_full_bw_cnt = 3;

/* "long-term" ("LT") bandwidth estimator parameters... */
/* The minimum number of rounds in an LT bw sampling interval: */
static const u32 bbr_lt_intvl_min_rtts = 4;
/* If lost/delivered ratio > 20%, interval is "lossy" and we may be policed: */
static const u32 bbr_lt_loss_thresh = 50;
/* If 2 intervals have a bw ratio <= 1/8, their bw is "consistent". */
static const u32 bbr_lt_bw_ratio = BBR_UNIT / 8;
/* If 2 intervals have a bw diff <= 4 Kbit/sec, their bw is "consistent". */
static const u32 bbr_lt_bw_diff = 4000 / 8;
/* If we estimate we're policed, use lt_bw for this many round trips: */
static const u32 bbr_lt_bw_max_rtts = 48;

/* Gain factor for adding extra_acked to target cwnd: */
static const int bbr_extra_acked_gain = BBR_UNIT;
/* Window length of extra_acked window. */
static const u32 bbr_extra_acked_win_rtts = 5;
/* Max allowed val for ack_epoch_acked, after which sampling epoch is reset. */
static const u32 bbr_ack_epoch_acked_reset_thresh = 1U << 20;
/* Time period for clamping cwnd increment due to ACK aggregation. */
static const u32 bbr_extra_acked_max_us = 100 * 1000;

static void bbr_check_probe_rtt_done(struct sock *sk);

/* Do we estimate that STARTUP filled the pipe? */
static bool bbr_full_bw_reached(const struct sock *sk)
{
	const struct bbr *bbr = inet_csk_ca(sk);

	return bbr->full_bw_reached;
}

/* Return the windowed max recent bandwidth sample, in pkts/uS << BW_SCALE. */
static u32 bbr_max_bw(const struct sock *sk)
{
	struct bbr *bbr = inet_csk_ca(sk);

	return minmax_get(&bbr->bw);
}

/* Return the estimated bandwidth of the path, in pkts/uS << BW_SCALE. */
static u32 bbr_bw(const struct sock *sk)
{
	struct bbr *bbr = inet_csk_ca(sk);

	return bbr->lt_use_bw ? bbr->lt_bw : bbr_max_bw(sk);
}

/* Return maximum extra acked in past k-2k round trips,
 * where k = bbr_extra_acked_win_rtts.
 */
static u16 bbr_extra_acked(const struct sock *sk)
{
	struct bbr *bbr = inet_csk_ca(sk);

	return max(bbr->extra_acked[0], bbr->extra_acked[1]);
}

/* Return rate in bytes per second, optionally with a gain.
 * The order here is chosen carefully to avoid overflow of u64. This should
 * work for input rates of up to 2.9Tbit/sec and gain of 2.89x.
 */
static u64 bbr_rate_bytes_per_sec(struct sock *sk, u64 rate, int gain)
{
	unsigned int mss = tcp_sk(sk)->mss_cache;

	rate *= mss;
	rate *= gain;
	rate >>= BBR_SCALE;
	rate *= USEC_PER_SEC / 100 * (100 - bbr_pacing_margin_percent);
	return rate >> BW_SCALE;
}

/* Convert a BBR bw and gain factor to a pacing rate in bytes per second. */
static unsigned long bbr_bw_to_pacing_rate(struct sock *sk, u32 bw, int gain)
{
	u64 rate = bw;

	rate = bbr_rate_bytes_per_sec(sk, rate, gain);
	rate = min_t(u64, rate, sk->sk_max_pacing_rate);
	return rate;
}

static bool bbr_brutal_is_cruise_phase_idx(u32 cycle_idx)
{
	return cycle_idx < BBR_BRUTAL_CRUISE_PHASES;
}

static bool bbr_brutal_is_cruise_phase(const struct bbr *bbr)
{
	return bbr_brutal_is_cruise_phase_idx(bbr->cycle_idx);
}

static bool bbr_brutal_is_loss_reference_phase(const struct bbr *bbr)
{
	return bbr->cycle_idx == BBR_BRUTAL_CRUISE_5;
}

static void bbr_brutal_reset_cruise_loss_p95(struct bbr *bbr)
{
	bbr->cruise_loss_bins_lo = 0;
	bbr->cruise_loss_bins_hi = 0;
}

static u32 bbr_brutal_cruise_loss_bins(const struct bbr *bbr)
{
	return (u32)bbr->cruise_loss_bins_lo |
	       ((u32)bbr->cruise_loss_bins_hi << 16);
}

static void bbr_brutal_store_cruise_loss_bins(struct bbr *bbr, u32 bins)
{
	bbr->cruise_loss_bins_lo = (u16)bins;
	bbr->cruise_loss_bins_hi = (u16)(bins >> 16);
}

static u32 bbr_brutal_loss_bin(u32 loss_pct)
{
	return min_t(u32, loss_pct * BBR_BRUTAL_LOSS_BINS / 101, BBR_BRUTAL_LOSS_BINS - 1);
}

static u32 bbr_brutal_loss_bin_upper(u32 bin)
{
	return min_t(u32, 100,
		     DIV_ROUND_UP((bin + 1) * 101, BBR_BRUTAL_LOSS_BINS) - 1);
}

static void bbr_brutal_update_cruise_loss_p95(struct bbr *bbr, u32 loss_pct)
{
	u32 bins = bbr_brutal_cruise_loss_bins(bbr);
	u32 bin = bbr_brutal_loss_bin(loss_pct);
	u32 shift = bin * 2;
	u32 count = (bins >> shift) & 0x3;

	if (count < 3)
		bins += 1U << shift;
	bbr_brutal_store_cruise_loss_bins(bbr, bins);
}

static u32 bbr_brutal_cruise_loss_p95(const struct bbr *bbr)
{
	u32 bins = bbr_brutal_cruise_loss_bins(bbr);
	u32 total = 0, cumulative = 0, target;
	u32 bin;

	for (bin = 0; bin < BBR_BRUTAL_LOSS_BINS; bin++)
		total += (bins >> (bin * 2)) & 0x3;
	if (!total)
		return 0;

	target = DIV_ROUND_UP(total * bbr_brutal_loss_percentile, 100);
	for (bin = 0; bin < BBR_BRUTAL_LOSS_BINS; bin++) {
		cumulative += (bins >> (bin * 2)) & 0x3;
		if (cumulative >= target)
			return bbr_brutal_loss_bin_upper(bin);
	}
	return 100;
}

static u32 bbr_brutal_sample_acked(const struct rate_sample *rs)
{
	return rs->acked_sacked > 0 ? (u32)rs->acked_sacked : 0;
}

static u32 bbr_brutal_sample_losses(const struct rate_sample *rs)
{
	return rs->losses > 0 ? (u32)rs->losses : 0;
}

static u32 bbr_brutal_sample_total(const struct rate_sample *rs)
{
	return bbr_brutal_sample_acked(rs) + bbr_brutal_sample_losses(rs);
}

static bool bbr_brutal_has_loss_sample(const struct rate_sample *rs)
{
	return bbr_brutal_sample_total(rs) > 0;
}

static u32 bbr_brutal_sample_loss_pct(const struct rate_sample *rs)
{
	u32 losses = bbr_brutal_sample_losses(rs);
	u32 total = bbr_brutal_sample_total(rs);

	return total ? min_t(u32, 100, losses * 100 / total) : 0;
}

static bool bbr_brutal_loss_guard_sample(const struct rate_sample *rs)
{
	u32 losses = bbr_brutal_sample_losses(rs);
	u32 total = bbr_brutal_sample_total(rs);
	u32 guard = clamp_t(u32, bbr_brutal_loss_guard_percent, 1, 100);

	return total && (u64)losses * 100 > (u64)total * guard;
}

static bool bbr_brutal_probe_up_loss_too_high(struct sock *sk,
					       const struct rate_sample *rs)
{
	struct bbr *bbr = inet_csk_ca(sk);

	return bbr_brutal_has_loss_sample(rs) &&
	       bbr_brutal_sample_loss_pct(rs) > bbr_brutal_cruise_loss_p95(bbr);
}

static bool bbr_brutal_can_compensate(struct sock *sk)
{
	struct bbr *bbr = inet_csk_ca(sk);

	return bbr->mode == BBR_PROBE_BW &&
	       bbr_brutal_is_cruise_phase(bbr) &&
	       !bbr->loss_guard &&
	       !bbr->lt_use_bw &&
	       inet_csk(sk)->icsk_ca_state < TCP_CA_Recovery;
}

/* Return the effective pacing gain. In CRUISE, apply Brutal compensation:
 * effective_gain = base_gain / ack_success_rate, where ack_success_rate is
 * floored by min_ack_percent. With the default floor of 80%, the maximum
 * compensation multiplier is 1.25x.
 */
static int bbr_brutal_effective_pacing_gain(struct sock *sk, int gain)
{
	struct bbr *bbr = inet_csk_ca(sk);
	u32 min_ack, loss_percent, ack_percent;

	if (!bbr_brutal_can_compensate(sk))
		return gain;

	min_ack = clamp_t(u32, bbr_brutal_min_ack_percent, 80, 100);
	loss_percent = min_t(u32, bbr->brutal_loss_pct, 100 - min_ack);
	if (!loss_percent)
		return gain;

	ack_percent = max_t(u32, 100 - loss_percent, min_ack);
	return DIV_ROUND_UP(gain * 100, ack_percent);
}

/* Initialize pacing rate to: high_gain * init_cwnd / RTT. */
static void bbr_init_pacing_rate_from_rtt(struct sock *sk)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct bbr *bbr = inet_csk_ca(sk);
	u64 bw;
	u32 rtt_us;

	if (tp->srtt_us) {		/* any RTT sample yet? */
		rtt_us = max(tp->srtt_us >> 3, 1U);
		bbr->has_seen_rtt = 1;
	} else {			 /* no RTT sample yet */
		rtt_us = USEC_PER_MSEC;	 /* use nominal default RTT */
	}
	bw = (u64)tcp_snd_cwnd(tp) * BW_UNIT;
	do_div(bw, rtt_us);
	sk->sk_pacing_rate = bbr_bw_to_pacing_rate(sk, bw, bbr_high_gain);
}

/* Pace using current bw estimate and a gain factor. */
static void bbr_set_pacing_rate(struct sock *sk, u32 bw, int gain)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct bbr *bbr = inet_csk_ca(sk);
	unsigned long rate = bbr_bw_to_pacing_rate(sk, bw, gain);

	if (unlikely(!bbr->has_seen_rtt && tp->srtt_us))
		bbr_init_pacing_rate_from_rtt(sk);
	if (bbr_full_bw_reached(sk) || rate > sk->sk_pacing_rate)
		sk->sk_pacing_rate = rate;
}

/* Minimum TSO/GSO segments for BBR-style low-rate pacing. */
static u32 bbr_min_tso_segs(struct sock *sk)
{
	return sk->sk_pacing_rate < (bbr_min_tso_rate >> 3) ? 1 : 2;
}

static u32 bbr_tso_segs_generic(struct sock *sk, unsigned int mss_now)
{
	u32 segs, bytes;

	/* Sort of tcp_tso_autosize() but ignoring
	 * driver provided sk_gso_max_size.
	 */
	bytes = min_t(unsigned long,
		      sk->sk_pacing_rate >> READ_ONCE(sk->sk_pacing_shift),
		      GSO_LEGACY_MAX_SIZE - 1 - MAX_TCP_HEADER);
	mss_now = max_t(unsigned int, mss_now, 1U);
	segs = max_t(u32, bytes / mss_now, bbr_min_tso_segs(sk));

	return min(segs, 0x7FU);
}

static u32 bbr_tso_segs_goal(struct sock *sk)
{
	return bbr_tso_segs_generic(sk, tcp_sk(sk)->mss_cache);
}

#if defined(BBRB_TCP_CA_HAS_TSO_SEGS)
#if defined(BBRB_TCP_CA_TSO_SEGS_1_ARG)
static u32 bbr_tso_segs(struct sock *sk)
{
	return bbr_tso_segs_goal(sk);
}
#else
/* BBRv3/L4S kernels usually use .tso_segs(sk, mss_now), not .min_tso_segs(sk). */
static u32 bbr_tso_segs(struct sock *sk, unsigned int mss_now)
{
	return bbr_tso_segs_generic(sk, mss_now);
}
#endif
#endif

/* Save "last known good" cwnd so we can restore it after losses or PROBE_RTT. */
static void bbr_save_cwnd(struct sock *sk)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct bbr *bbr = inet_csk_ca(sk);

	if (bbr->prev_ca_state < TCP_CA_Recovery && bbr->mode != BBR_PROBE_RTT)
		bbr->prior_cwnd = tcp_snd_cwnd(tp);  /* this cwnd is good enough */
	else  /* loss recovery or BBR_PROBE_RTT have temporarily cut cwnd */
		bbr->prior_cwnd = max(bbr->prior_cwnd, tcp_snd_cwnd(tp));
}

static void bbr_enter_loss_guard_recovery(struct sock *sk)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct bbr *bbr = inet_csk_ca(sk);

	if (!bbr->brutal_recovery) {
		bbr_save_cwnd(sk);
		bbr->brutal_recovery = 1;
	}
	bbr->packet_conservation = 1;
	bbr->next_rtt_delivered = tp->delivered;
}

static void bbr_exit_loss_guard_recovery(struct sock *sk)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct bbr *bbr = inet_csk_ca(sk);

	if (!bbr->brutal_recovery)
		return;
	bbr->brutal_recovery = 0;
	if (inet_csk(sk)->icsk_ca_state < TCP_CA_Recovery) {
		tcp_snd_cwnd_set(tp, max(tcp_snd_cwnd(tp), bbr->prior_cwnd));
		bbr->packet_conservation = 0;
	}
}

static void bbr_cwnd_event_tx_start_common(struct sock *sk)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct bbr *bbr = inet_csk_ca(sk);

	if (tp->app_limited) {
		bbr->idle_restart = 1;
		bbr->ack_epoch_mstamp = tp->tcp_mstamp;
		bbr->ack_epoch_acked = 0;
		/* Avoid pointless buffer overflows: pace at est. bw if we don't
		 * need more speed (we're restarting from idle and app-limited).
		 */
		if (bbr->mode == BBR_PROBE_BW)
			bbr_set_pacing_rate(sk, bbr_bw(sk), BBR_UNIT);
		else if (bbr->mode == BBR_PROBE_RTT)
			bbr_check_probe_rtt_done(sk);
	}
}

#if (defined(BBRB_TCP_CA_HAS_CWND_EVENT) && defined(BBRB_TCP_HAS_CA_EVENT_TX_START)) || 	!defined(BBRB_TCP_CA_PROBED)
static void bbr_cwnd_event(struct sock *sk, enum tcp_ca_event event)
{
	if (event == CA_EVENT_TX_START)
		bbr_cwnd_event_tx_start_common(sk);
}
#endif

#if defined(BBRB_TCP_CA_HAS_CWND_EVENT_TX_START) || 	(!defined(BBRB_TCP_CA_PROBED) && 	 LINUX_VERSION_CODE >= KERNEL_VERSION(7, 1, 0))
static void bbr_cwnd_event_tx_start(struct sock *sk)
{
	bbr_cwnd_event_tx_start_common(sk);
}
#endif

/* Calculate bdp based on min RTT and the estimated bottleneck bandwidth:
 *
 * bdp = ceil(bw * min_rtt * gain)
 *
 * The key factor, gain, controls the amount of queue. While a small gain
 * builds a smaller queue, it becomes more vulnerable to noise in RTT
 * measurements (e.g., delayed ACKs or other ACK compression effects). This
 * noise may cause BBR to under-estimate the rate.
 */
static u32 bbr_bdp(struct sock *sk, u32 bw, int gain)
{
	struct bbr *bbr = inet_csk_ca(sk);
	u32 bdp;
	u64 w;

	/* If we've never had a valid RTT sample, cap cwnd at the initial
	 * default. This should only happen when the connection is not using TCP
	 * timestamps and has retransmitted all of the SYN/SYNACK/data packets
	 * ACKed so far. In this case, an RTO can cut cwnd to 1, in which
	 * case we need to slow-start up toward something safe: TCP_INIT_CWND.
	 */
	if (unlikely(bbr->min_rtt_us == ~0U))	 /* no valid RTT samples yet? */
		return TCP_INIT_CWND;  /* be safe: cap at default initial cwnd*/

	w = (u64)bw * bbr->min_rtt_us;

	/* Apply a gain to the given value, remove the BW_SCALE shift, and
	 * round the value up to avoid a negative feedback loop.
	 */
	bdp = (((w * gain) >> BBR_SCALE) + BW_UNIT - 1) / BW_UNIT;

	return bdp;
}

/* To achieve full performance in high-speed paths, budget enough cwnd to
 * fit full-sized skbs in-flight on both end hosts to fully utilize the path:
 *   - one skb in sending host Qdisc,
 *   - one skb in sending host TSO/GSO engine
 *   - one skb being received by receiver host LRO/GRO/delayed-ACK engine
 * At low rates this TSO/GSO budget remains small because tso_segs_goal is 1.
 * The configured cwnd floor is applied later by bbr_set_cwnd().
 */
static u32 bbr_quantization_budget(struct sock *sk, u32 cwnd)
{
	struct bbr *bbr = inet_csk_ca(sk);

	/* Allow enough full-sized skbs in flight to utilize end systems. */
	cwnd += 3 * bbr_tso_segs_goal(sk);

	/* Reduce delayed ACKs by rounding up cwnd to the next even number. */
	cwnd = (cwnd + 1) & ~1U;

	/* Ensure gain cycling gets inflight above BDP even for small BDPs. */
	if (bbr->mode == BBR_PROBE_BW && bbr->cycle_idx == BBR_BRUTAL_PROBE_UP)
		cwnd += 2;

	return cwnd;
}

/* Find inflight based on min RTT and the estimated bottleneck bandwidth. */
static u32 bbr_inflight(struct sock *sk, u32 bw, int gain)
{
	u32 inflight;

	inflight = bbr_bdp(sk, bw, gain);
	inflight = bbr_quantization_budget(sk, inflight);

	return inflight;
}

/* With pacing at lower layers, there's often less data "in the network" than
 * "in flight". With TSQ and departure time pacing at lower layers (e.g. fq),
 * we often have several skbs queued in the pacing layer with a pre-scheduled
 * earliest departure time (EDT). BBR adapts its pacing rate based on the
 * inflight level that it estimates has already been "baked in" by previous
 * departure time decisions. We calculate a rough estimate of the number of our
 * packets that might be in the network at the earliest departure time for the
 * next skb scheduled:
 *   in_network_at_edt = inflight_at_edt - (EDT - now) * bw
 * If we're increasing inflight, then we want to know if the transmit of the
 * EDT skb will push inflight above the target, so inflight_at_edt includes
 * bbr_tso_segs_goal() from the skb departing at EDT. If decreasing inflight,
 * then estimate if inflight will sink too low just before the EDT transmit.
 */
static u32 bbr_packets_in_net_at_edt(struct sock *sk, u32 inflight_now)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct bbr *bbr = inet_csk_ca(sk);
	u64 now_ns, edt_ns, interval_us;
	u32 interval_delivered, inflight_at_edt;

	now_ns = tp->tcp_clock_cache;
	edt_ns = max(tp->tcp_wstamp_ns, now_ns);
	interval_us = div_u64(edt_ns - now_ns, NSEC_PER_USEC);
	interval_delivered = (u64)bbr_bw(sk) * interval_us >> BW_SCALE;
	inflight_at_edt = inflight_now;
	if (bbr->pacing_gain > BBR_UNIT)              /* increasing inflight */
		inflight_at_edt += bbr_tso_segs_goal(sk);  /* include EDT skb */
	if (interval_delivered >= inflight_at_edt)
		return 0;
	return inflight_at_edt - interval_delivered;
}

/* Find the cwnd increment based on estimated ACK aggregation. */
static u32 bbr_ack_aggregation_cwnd(struct sock *sk)
{
	u32 max_aggr_cwnd, aggr_cwnd = 0;

	if (bbr_extra_acked_gain && bbr_full_bw_reached(sk)) {
		max_aggr_cwnd = ((u64)bbr_bw(sk) * bbr_extra_acked_max_us)
				/ BW_UNIT;
		aggr_cwnd = (bbr_extra_acked_gain * bbr_extra_acked(sk))
			     >> BBR_SCALE;
		aggr_cwnd = min(aggr_cwnd, max_aggr_cwnd);
	}

	return aggr_cwnd;
}

/* An optimization in BBR to reduce losses: On the first round of recovery, we
 * follow the packet conservation principle: send P packets per P packets acked.
 * After that, we slow-start and send at most 2*P packets per P packets acked.
 * After recovery finishes, or upon undo, we restore the cwnd we had when
 * recovery started (capped by the target cwnd based on estimated BDP).
 *
 * TODO(ycheng/ncardwell): implement a rate-based approach.
 */
static bool bbr_set_cwnd_to_recover_or_restore(
	struct sock *sk, const struct rate_sample *rs, u32 acked, u32 *new_cwnd)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct bbr *bbr = inet_csk_ca(sk);
	u8 prev_state = bbr->prev_ca_state, state = inet_csk(sk)->icsk_ca_state;
	u32 cwnd = tcp_snd_cwnd(tp);

	/* An ACK for P pkts should release at most 2*P packets. We do this
	 * in two steps. First, here we deduct the number of lost packets.
	 * Then, in bbr_set_cwnd() we slow start up toward the target cwnd.
	 */
	if (rs->losses > 0)
		cwnd = max_t(s32, cwnd - rs->losses, 1);

	if (state == TCP_CA_Recovery && prev_state != TCP_CA_Recovery) {
		/* Starting 1st round of Recovery, so do packet conservation. */
		bbr->packet_conservation = 1;
		bbr->next_rtt_delivered = tp->delivered;  /* start round now */
		/* Preserve existing cwnd while enabling packet conservation. */
		cwnd = max(cwnd, tcp_packets_in_flight(tp) + acked);
	} else if (prev_state >= TCP_CA_Recovery && state < TCP_CA_Recovery) {
		/* Exiting loss recovery; restore cwnd saved before recovery. */
		cwnd = max(cwnd, bbr->prior_cwnd);
		bbr->packet_conservation = 0;
	}
	bbr->prev_ca_state = state;

	if (bbr->packet_conservation) {
		*new_cwnd = max(cwnd, tcp_packets_in_flight(tp) + acked);
		return true;	/* yes, using packet conservation */
	}
	*new_cwnd = cwnd;
	return false;
}

/* Slow-start up toward target cwnd (if bw estimate is growing, or packet loss
 * has drawn us down below target), or snap down to target if we're above it.
 */
static void bbr_set_cwnd(struct sock *sk, const struct rate_sample *rs,
			 u32 acked, u32 bw, int gain)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct bbr *bbr = inet_csk_ca(sk);
	u32 cwnd = tcp_snd_cwnd(tp), target_cwnd = 0;

	if (!acked)
		goto done;  /* no packet fully ACKed; just apply caps */

	if (bbr_set_cwnd_to_recover_or_restore(sk, rs, acked, &cwnd))
		goto done;

	target_cwnd = bbr_bdp(sk, bw, gain);

	/* Increment the cwnd to account for excess ACKed data that seems
	 * due to aggregation (of data and/or ACKs) visible in the ACK stream.
	 */
	target_cwnd += bbr_ack_aggregation_cwnd(sk);
	target_cwnd = bbr_quantization_budget(sk, target_cwnd);

	/* If we're below target cwnd, slow start cwnd toward target cwnd. */
	if (bbr_full_bw_reached(sk))  /* only cut cwnd if we filled the pipe */
		cwnd = min(cwnd + acked, target_cwnd);
	else if (cwnd < target_cwnd || tp->delivered < TCP_INIT_CWND)
		cwnd = cwnd + acked;
	cwnd = max(cwnd, bbr_cwnd_min_target);

done:
	tcp_snd_cwnd_set(tp, min(cwnd, tp->snd_cwnd_clamp));	/* apply global cap */
	if (bbr->mode == BBR_PROBE_RTT)  /* drain queue, refresh min_rtt */
		tcp_snd_cwnd_set(tp, min(tcp_snd_cwnd(tp), bbr_cwnd_min_target));
}

/* End cycle phase if it is time and/or we hit the phase's target. */
static bool bbr_is_next_cycle_phase(struct sock *sk,
				    const struct rate_sample *rs)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct bbr *bbr = inet_csk_ca(sk);
	bool is_full_length =
		tcp_stamp_us_delta(tp->delivered_mstamp, bbr->cycle_mstamp) >
		bbr->min_rtt_us;
	u32 inflight, bw;

	if (bbr->loss_guard || bbr->lt_use_bw)
		return false;

	/* Each CRUISE phase runs for one min_rtt with Brutal compensation. */
	if (bbr_brutal_is_cruise_phase(bbr))
		return is_full_length;

	inflight = bbr_packets_in_net_at_edt(sk, rs->prior_in_flight);
	bw = bbr_max_bw(sk);

	/* PROBE_UP uses gain 1.25 and no Brutal compensation. */
	if (bbr->cycle_idx == BBR_BRUTAL_PROBE_UP)
		return bbr_brutal_probe_up_loss_too_high(sk, rs) ||
		       inflight >= bbr_inflight(sk, bw, bbr->pacing_gain);

	/* DRAIN uses gain 0.75 until in-flight is <= estimated BDP. */
	return inflight <= bbr_inflight(sk, bw, BBR_UNIT);
}

static void bbr_advance_cycle_phase(struct sock *sk)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct bbr *bbr = inet_csk_ca(sk);

	bbr->cycle_idx = (bbr->cycle_idx + 1) % CYCLE_LEN;
	bbr->cycle_mstamp = tp->delivered_mstamp;

	/* The PROBE_UP loss threshold is the P95 from the last CRUISE phase. */
	if (bbr->cycle_idx == BBR_BRUTAL_CRUISE_5 || bbr->cycle_idx == BBR_BRUTAL_CRUISE_0)
		bbr_brutal_reset_cruise_loss_p95(bbr);
}

/* Gain cycling: cycle pacing gain to converge to fair share of available bw. */
static void bbr_update_cycle_phase(struct sock *sk,
				   const struct rate_sample *rs)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct bbr *bbr = inet_csk_ca(sk);

	if (bbr->mode != BBR_PROBE_BW)
		return;

	if (bbr->loss_guard || bbr->lt_use_bw) {
		bbr_enter_loss_guard_recovery(sk);
		bbr->cycle_idx = BBR_BRUTAL_CRUISE_0;
		bbr->cycle_mstamp = tp->delivered_mstamp;
		bbr_brutal_reset_cruise_loss_p95(bbr);
		return;
	}

	bbr_exit_loss_guard_recovery(sk);
	if (bbr_is_next_cycle_phase(sk, rs))
		bbr_advance_cycle_phase(sk);
}

static void bbr_reset_startup_mode(struct sock *sk)
{
	struct bbr *bbr = inet_csk_ca(sk);

	bbr->mode = BBR_STARTUP;
}

static void bbr_reset_probe_bw_mode(struct sock *sk)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct bbr *bbr = inet_csk_ca(sk);

	bbr->mode = BBR_PROBE_BW;
	bbr->cycle_idx = BBR_BRUTAL_CRUISE_0;
	bbr->cycle_mstamp = tp->delivered_mstamp;
	bbr_brutal_reset_cruise_loss_p95(bbr);
}

static void bbr_reset_mode(struct sock *sk)
{
	if (!bbr_full_bw_reached(sk))
		bbr_reset_startup_mode(sk);
	else
		bbr_reset_probe_bw_mode(sk);
}

/* Start a new long-term sampling interval. */
static void bbr_reset_lt_bw_sampling_interval(struct sock *sk)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct bbr *bbr = inet_csk_ca(sk);

	bbr->lt_last_stamp = div_u64(tp->delivered_mstamp, USEC_PER_MSEC);
	bbr->lt_last_delivered = tp->delivered;
	bbr->lt_last_lost = tp->lost;
	bbr->lt_rtt_cnt = 0;
}

/* Completely reset long-term bandwidth sampling. */
static void bbr_reset_lt_bw_sampling(struct sock *sk)
{
	struct bbr *bbr = inet_csk_ca(sk);

	bbr->lt_bw = 0;
	bbr->lt_use_bw = 0;
	bbr->lt_is_sampling = false;
	bbr_reset_lt_bw_sampling_interval(sk);
}

/* Long-term bw sampling interval is done. Estimate whether we're policed. */
static void bbr_lt_bw_interval_done(struct sock *sk, u32 bw)
{
	struct bbr *bbr = inet_csk_ca(sk);
	u32 diff;

	if (bbr->lt_bw) {  /* do we have bw from a previous interval? */
		/* Is new bw close to the lt_bw from the previous interval? */
		diff = abs(bw - bbr->lt_bw);
		if ((diff * BBR_UNIT <= bbr_lt_bw_ratio * bbr->lt_bw) ||
		    (bbr_rate_bytes_per_sec(sk, diff, BBR_UNIT) <=
		     bbr_lt_bw_diff)) {
			/* All criteria are met; estimate we're policed. */
			bbr->lt_bw = (bw + bbr->lt_bw) >> 1;  /* avg 2 intvls */
			bbr->lt_use_bw = 1;
			bbr->pacing_gain = BBR_UNIT;  /* try to avoid drops */
			bbr->lt_rtt_cnt = 0;
			return;
		}
	}
	bbr->lt_bw = bw;
	bbr_reset_lt_bw_sampling_interval(sk);
}

/* Token-bucket traffic policers are common (see "An Internet-Wide Analysis of
 * Traffic Policing", SIGCOMM 2016). BBR detects token-bucket policers and
 * explicitly models their policed rate, to reduce unnecessary losses. We
 * estimate that we're policed if we see 2 consecutive sampling intervals with
 * consistent throughput and high packet loss. If we think we're being policed,
 * set lt_bw to the "long-term" average delivery rate from those 2 intervals.
 */
static void bbr_lt_bw_sampling(struct sock *sk, const struct rate_sample *rs)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct bbr *bbr = inet_csk_ca(sk);
	u32 lost, delivered;
	u64 bw;
	u32 t;

	if (bbr->lt_use_bw) {	/* already using long-term rate, lt_bw? */
		if (bbr->mode == BBR_PROBE_BW && bbr->round_start &&
		    ++bbr->lt_rtt_cnt >= bbr_lt_bw_max_rtts) {
			bbr_reset_lt_bw_sampling(sk);    /* stop using lt_bw */
			bbr_reset_probe_bw_mode(sk);  /* restart gain cycling */
		}
		return;
	}

	/* Wait for the first loss before sampling, to let the policer exhaust
	 * its tokens and estimate the steady-state rate allowed by the policer.
	 * Starting samples earlier includes bursts that over-estimate the bw.
	 */
	if (!bbr->lt_is_sampling) {
		if (!rs->losses)
			return;
		bbr_reset_lt_bw_sampling_interval(sk);
		bbr->lt_is_sampling = true;
	}

	/* To avoid underestimates, reset sampling if we run out of data. */
	if (rs->is_app_limited) {
		bbr_reset_lt_bw_sampling(sk);
		return;
	}

	if (bbr->round_start)
		bbr->lt_rtt_cnt++;	/* count round trips in this interval */
	if (bbr->lt_rtt_cnt < bbr_lt_intvl_min_rtts)
		return;		/* sampling interval needs to be longer */
	if (bbr->lt_rtt_cnt > 4 * bbr_lt_intvl_min_rtts) {
		bbr_reset_lt_bw_sampling(sk);  /* interval is too long */
		return;
	}

	/* End sampling interval when a packet is lost, so we estimate the
	 * policer tokens were exhausted. Stopping the sampling before the
	 * tokens are exhausted under-estimates the policed rate.
	 */
	if (!rs->losses)
		return;

	/* Calculate packets lost and delivered in sampling interval. */
	lost = tp->lost - bbr->lt_last_lost;
	delivered = tp->delivered - bbr->lt_last_delivered;
	/* Is loss rate (lost/delivered) >= lt_loss_thresh? If not, wait. */
	if (!delivered || (lost << BBR_SCALE) < bbr_lt_loss_thresh * delivered)
		return;

	/* Find average delivery rate in this sampling interval. */
	t = div_u64(tp->delivered_mstamp, USEC_PER_MSEC) - bbr->lt_last_stamp;
	if ((s32)t < 1)
		return;		/* interval is less than one ms, so wait */
	/* Check if can multiply without overflow */
	if (t >= ~0U / USEC_PER_MSEC) {
		bbr_reset_lt_bw_sampling(sk);  /* interval too long; reset */
		return;
	}
	t *= USEC_PER_MSEC;
	bw = (u64)delivered * BW_UNIT;
	do_div(bw, t);
	bbr_lt_bw_interval_done(sk, bw);
}

/* Estimate the bandwidth based on how fast packets are delivered. */
static void bbr_update_bw(struct sock *sk, const struct rate_sample *rs)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct bbr *bbr = inet_csk_ca(sk);
	u64 bw;

	bbr->round_start = 0;
	if (rs->delivered < 0 || rs->interval_us <= 0)
		return; /* Not a valid observation */

	/* See if we've reached the next RTT */
	if (!before(rs->prior_delivered, bbr->next_rtt_delivered)) {
		bbr->next_rtt_delivered = tp->delivered;
		bbr->rtt_cnt++;
		bbr->round_start = 1;
		bbr->packet_conservation = 0;
	}

	bbr_lt_bw_sampling(sk, rs);

	/* Divide delivered by the interval to find a (lower bound) bottleneck
	 * bandwidth sample. Delivered is in packets and interval_us in uS and
	 * ratio will be <<1 for most connections. So delivered is first scaled.
	 */
	bw = div64_long((u64)rs->delivered * BW_UNIT, rs->interval_us);

	/* If this sample is application-limited, it is likely to have a very
	 * low delivered count that represents application behavior rather than
	 * the available network rate. Such a sample could drag down estimated
	 * bw, causing needless slow-down. Thus, to continue to send at the
	 * last measured network rate, we filter out app-limited samples unless
	 * they describe the path bw at least as well as our bw model.
	 *
	 * So the goal during app-limited phase is to proceed with the best
	 * network rate no matter how long. We automatically leave this
	 * phase when app writes faster than the network can deliver :)
	 */
	if (!rs->is_app_limited || bw >= bbr_max_bw(sk)) {
		/* Incorporate new sample into our max bw filter. */
		minmax_running_max(&bbr->bw, bbr_bw_rtts, bbr->rtt_cnt, bw);
	}
}

/* Estimate the windowed max degree of ACK aggregation.
 * This provisions extra in-flight data to keep sending during inter-ACK
 * silences. ACK aggregation is estimated as excess data ACKed beyond the
 * expected amount from max_bw over the sampling interval:
 *
 *   max_extra_acked = max_recent(acked - max_bw * interval)
 *   cwnd += max_extra_acked
 *
 * Max extra_acked is clamped by cwnd and bw * bbr_extra_acked_max_us. With
 * this variant's constants, that clamp is 100 ms and the max filter is an
 * approximate sliding window of 5-10 packet-timed round trips.
 */
static void bbr_update_ack_aggregation(struct sock *sk,
				       const struct rate_sample *rs)
{
	u32 epoch_us, expected_acked, extra_acked;
	struct bbr *bbr = inet_csk_ca(sk);
	struct tcp_sock *tp = tcp_sk(sk);

	if (!bbr_extra_acked_gain || rs->acked_sacked <= 0 ||
	    rs->delivered < 0 || rs->interval_us <= 0)
		return;

	if (bbr->round_start) {
		bbr->extra_acked_win_rtts = min(0x1F,
						bbr->extra_acked_win_rtts + 1);
		if (bbr->extra_acked_win_rtts >= bbr_extra_acked_win_rtts) {
			bbr->extra_acked_win_rtts = 0;
			bbr->extra_acked_win_idx = bbr->extra_acked_win_idx ?
						   0 : 1;
			bbr->extra_acked[bbr->extra_acked_win_idx] = 0;
		}
	}

	/* Compute how many packets we expected to be delivered over epoch. */
	epoch_us = tcp_stamp_us_delta(tp->delivered_mstamp,
				      bbr->ack_epoch_mstamp);
	expected_acked = ((u64)bbr_bw(sk) * epoch_us) / BW_UNIT;

	/* Reset the aggregation epoch if ACK rate is below expected rate or
	 * significantly large no. of ack received since epoch (potentially
	 * quite old epoch).
	 */
	if (bbr->ack_epoch_acked <= expected_acked ||
	    (bbr->ack_epoch_acked + rs->acked_sacked >=
	     bbr_ack_epoch_acked_reset_thresh)) {
		bbr->ack_epoch_acked = 0;
		bbr->ack_epoch_mstamp = tp->delivered_mstamp;
		expected_acked = 0;
	}

	/* Compute excess data delivered, beyond what was expected. */
	bbr->ack_epoch_acked = min_t(u32, 0xFFFFF,
				     bbr->ack_epoch_acked + rs->acked_sacked);
	extra_acked = bbr->ack_epoch_acked - expected_acked;
	extra_acked = min(extra_acked, tcp_snd_cwnd(tp));
	if (extra_acked > bbr->extra_acked[bbr->extra_acked_win_idx])
		bbr->extra_acked[bbr->extra_acked_win_idx] = extra_acked;
}

/* Track sample-level loss for Brutal compensation, LOSS_GUARD, and the
 * approximate P95 loss during the last CRUISE phase before PROBE_UP.
 */
static void bbr_update_brutal_loss(struct sock *sk, const struct rate_sample *rs)
{
	struct bbr *bbr = inet_csk_ca(sk);
	bool has_sample = bbr_brutal_has_loss_sample(rs);
	u32 loss_pct = has_sample ? bbr_brutal_sample_loss_pct(rs) : 0;

	if (has_sample)
		bbr->brutal_loss_pct = loss_pct;
	else if (bbr->round_start && bbr->brutal_loss_pct)
		bbr->brutal_loss_pct = (bbr->brutal_loss_pct * 7) >> 3;

	if (bbr->mode == BBR_PROBE_BW &&
	    bbr_brutal_is_loss_reference_phase(bbr) && has_sample)
		bbr_brutal_update_cruise_loss_p95(bbr, loss_pct);

	bbr->loss_guard = bbr->lt_use_bw || bbr_brutal_loss_guard_sample(rs);
}

/* Estimate when STARTUP has filled the pipe using delivery-rate growth.
 * If the max bandwidth has not increased by bbr_full_bw_thresh for
 * bbr_full_bw_cnt non-app-limited rounds, mark the pipe full.
 */
static void bbr_check_full_bw_reached(struct sock *sk,
				      const struct rate_sample *rs)
{
	struct bbr *bbr = inet_csk_ca(sk);
	u32 bw_thresh;

	if (bbr_full_bw_reached(sk) || !bbr->round_start || rs->is_app_limited)
		return;

	bw_thresh = (u64)bbr->full_bw * bbr_full_bw_thresh >> BBR_SCALE;
	if (bbr_max_bw(sk) >= bw_thresh) {
		bbr->full_bw = bbr_max_bw(sk);
		bbr->full_bw_cnt = 0;
		return;
	}
	++bbr->full_bw_cnt;
	bbr->full_bw_reached = bbr->full_bw_cnt >= bbr_full_bw_cnt;
}

/* If pipe is probably full, drain the queue and then enter steady-state. */
static void bbr_check_drain(struct sock *sk, const struct rate_sample *rs)
{
	struct bbr *bbr = inet_csk_ca(sk);

	if (bbr->mode == BBR_STARTUP && bbr_full_bw_reached(sk)) {
		bbr->mode = BBR_DRAIN;	/* drain queue we created */
		tcp_sk(sk)->snd_ssthresh =
				bbr_inflight(sk, bbr_max_bw(sk), BBR_UNIT);
	}	/* fall through to check if in-flight is already small: */
	if (bbr->mode == BBR_DRAIN &&
	    bbr_packets_in_net_at_edt(sk, tcp_packets_in_flight(tcp_sk(sk))) <=
	    bbr_inflight(sk, bbr_max_bw(sk), BBR_UNIT))
		bbr_reset_probe_bw_mode(sk);  /* we estimate queue is drained */
}

static void bbr_check_probe_rtt_done(struct sock *sk)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct bbr *bbr = inet_csk_ca(sk);

	if (!(bbr->probe_rtt_done_stamp &&
	      after(tcp_jiffies32, bbr->probe_rtt_done_stamp)))
		return;

	bbr->min_rtt_stamp = tcp_jiffies32;  /* wait a while until PROBE_RTT */
	tcp_snd_cwnd_set(tp, max(tcp_snd_cwnd(tp), bbr->prior_cwnd));
	bbr_reset_mode(sk);
}

/* This variant keeps BBRv1-style PROBE_RTT. If a continuously busy flow has
 * not refreshed its min_rtt estimate within bbr_min_rtt_win_sec, temporarily
 * cap cwnd to bbr_cwnd_min_target for at least bbr_probe_rtt_mode_ms and one
 * packet-timed round, then resume STARTUP or BBR-Brutal PROBE_BW.
 */
static void bbr_update_min_rtt(struct sock *sk, const struct rate_sample *rs)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct bbr *bbr = inet_csk_ca(sk);
	bool filter_expired;

	filter_expired = after(tcp_jiffies32,
			       bbr->min_rtt_stamp + bbr_min_rtt_win_sec * HZ);
	if (rs->rtt_us >= 0 &&
	    (rs->rtt_us < bbr->min_rtt_us ||
	     (filter_expired && !rs->is_ack_delayed))) {
		bbr->min_rtt_us = rs->rtt_us;
		bbr->min_rtt_stamp = tcp_jiffies32;
	}

	if (bbr_probe_rtt_mode_ms > 0 && filter_expired &&
	    !bbr->idle_restart && bbr->mode != BBR_PROBE_RTT) {
		bbr->mode = BBR_PROBE_RTT;  /* dip, drain queue */
		bbr_save_cwnd(sk);
		bbr->probe_rtt_done_stamp = 0;
	}

	if (bbr->mode == BBR_PROBE_RTT) {
		/* Ignore low-rate samples during this mode. */
		tp->app_limited = (tp->delivered + tcp_packets_in_flight(tp)) ? : 1;
		/* Maintain min packets in flight for max(200 ms, 1 round). */
		if (!bbr->probe_rtt_done_stamp &&
		    tcp_packets_in_flight(tp) <= bbr_cwnd_min_target) {
			bbr->probe_rtt_done_stamp = tcp_jiffies32 +
				msecs_to_jiffies(bbr_probe_rtt_mode_ms);
			bbr->probe_rtt_round_done = 0;
			bbr->next_rtt_delivered = tp->delivered;
		} else if (bbr->probe_rtt_done_stamp) {
			if (bbr->round_start)
				bbr->probe_rtt_round_done = 1;
			if (bbr->probe_rtt_round_done)
				bbr_check_probe_rtt_done(sk);
		}
	}

	/* Restart after idle ends only once we process a new S/ACK for data. */
	if (rs->delivered > 0)
		bbr->idle_restart = 0;
}

static void bbr_update_gains(struct sock *sk)
{
	struct bbr *bbr = inet_csk_ca(sk);

	switch (bbr->mode) {
	case BBR_STARTUP:
		bbr->pacing_gain = bbr_high_gain;
		bbr->cwnd_gain	 = bbr_high_gain;
		break;
	case BBR_DRAIN:
		bbr->pacing_gain = bbr_drain_gain;	/* slow, to drain */
		bbr->cwnd_gain	 = bbr_high_gain;	/* keep cwnd */
		break;
	case BBR_PROBE_BW:
		bbr->pacing_gain = (bbr->lt_use_bw || bbr->loss_guard) ?
				    BBR_UNIT : bbr_pacing_gain[bbr->cycle_idx];
		bbr->cwnd_gain	 = bbr_cwnd_gain;
		break;
	case BBR_PROBE_RTT:
		bbr->pacing_gain = BBR_UNIT;
		bbr->cwnd_gain	 = BBR_UNIT;
		break;
	default:
		WARN_ONCE(1, "BBR bad mode: %u\n", bbr->mode);
		break;
	}
}

static void bbr_update_model(struct sock *sk, const struct rate_sample *rs)
{
	bbr_update_bw(sk, rs);
	bbr_update_brutal_loss(sk, rs);
	bbr_update_ack_aggregation(sk, rs);
	bbr_update_cycle_phase(sk, rs);
	bbr_check_full_bw_reached(sk, rs);
	bbr_check_drain(sk, rs);
	bbr_update_min_rtt(sk, rs);
	bbr_update_gains(sk);
}

static void bbr_main_common(struct sock *sk, const struct rate_sample *rs)
{
	struct bbr *bbr = inet_csk_ca(sk);
	u32 bw;

	bbr_update_model(sk, rs);

	bw = bbr_bw(sk);
	bbr_set_pacing_rate(sk, bw, bbr_brutal_effective_pacing_gain(sk,
						   bbr->pacing_gain));
	bbr_set_cwnd(sk, rs, rs->acked_sacked, bw, bbr->cwnd_gain);
}


/*
 * Do not key this only off LINUX_VERSION_CODE. Some BBRv3/L4S trees carry
 * a 6.x version number while keeping the older two-argument cong_control hook.
 * The Makefile probes include/net/tcp.h and passes BBRB_TCP_CA_* feature macros.
 */
#if defined(BBRB_TCP_CA_CONG_CONTROL_4_ARGS) || 	(!defined(BBRB_TCP_CA_PROBED) && 	 LINUX_VERSION_CODE >= KERNEL_VERSION(6, 10, 0))
static void bbr_main(struct sock *sk, u32 ack, int flag,
		     const struct rate_sample *rs)
{
	bbr_main_common(sk, rs);
}
#else
static void bbr_main(struct sock *sk, const struct rate_sample *rs)
{
	bbr_main_common(sk, rs);
}
#endif

static void bbr_init(struct sock *sk)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct bbr *bbr = inet_csk_ca(sk);

	bbr->prior_cwnd = 0;
	tp->snd_ssthresh = TCP_INFINITE_SSTHRESH;
	bbr->rtt_cnt = 0;
	bbr->next_rtt_delivered = tp->delivered;
	bbr->prev_ca_state = TCP_CA_Open;
	bbr->packet_conservation = 0;

	bbr->probe_rtt_done_stamp = 0;
	bbr->probe_rtt_round_done = 0;
	bbr->loss_guard = 0;
	bbr->brutal_loss_pct = 0;
	bbr->brutal_recovery = 0;
	bbr_brutal_reset_cruise_loss_p95(bbr);
	bbr->min_rtt_us = tcp_min_rtt(tp);
	bbr->min_rtt_stamp = tcp_jiffies32;

	minmax_reset(&bbr->bw, bbr->rtt_cnt, 0);  /* init max bw to 0 */

	bbr->has_seen_rtt = 0;
	bbr_init_pacing_rate_from_rtt(sk);

	bbr->round_start = 0;
	bbr->idle_restart = 0;
	bbr->full_bw_reached = 0;
	bbr->full_bw = 0;
	bbr->full_bw_cnt = 0;
	bbr->cycle_mstamp = 0;
	bbr->cycle_idx = 0;
	bbr_reset_lt_bw_sampling(sk);
	bbr_reset_startup_mode(sk);

	bbr->ack_epoch_mstamp = tp->tcp_mstamp;
	bbr->ack_epoch_acked = 0;
	bbr->extra_acked_win_rtts = 0;
	bbr->extra_acked_win_idx = 0;
	bbr->extra_acked[0] = 0;
	bbr->extra_acked[1] = 0;

	cmpxchg(&sk->sk_pacing_status, SK_PACING_NONE, SK_PACING_NEEDED);
}

static u32 bbr_sndbuf_expand(struct sock *sk)
{
	/* Provision 3 * cwnd since BBR may slow-start even during recovery. */
	return 3;
}

/* In theory BBR does not need to undo the cwnd since it does not
 * always reduce cwnd on losses (see bbr_main()). Keep it for now.
 */
static u32 bbr_undo_cwnd(struct sock *sk)
{
	struct bbr *bbr = inet_csk_ca(sk);

	bbr->full_bw = 0;   /* spurious slow-down; reset full pipe detection */
	bbr->full_bw_cnt = 0;
	bbr_reset_lt_bw_sampling(sk);
	return tcp_snd_cwnd(tcp_sk(sk));
}

/* Entering loss recovery, so save cwnd for when we exit or undo recovery. */
static u32 bbr_ssthresh(struct sock *sk)
{
	bbr_save_cwnd(sk);
	return tcp_sk(sk)->snd_ssthresh;
}

static size_t bbr_get_info(struct sock *sk, u32 ext, int *attr,
			   union tcp_cc_info *info)
{
	if (ext & (1 << (INET_DIAG_BBRINFO - 1)) ||
	    ext & (1 << (INET_DIAG_VEGASINFO - 1))) {
		struct tcp_sock *tp = tcp_sk(sk);
		struct bbr *bbr = inet_csk_ca(sk);
		u64 bw = bbr_bw(sk);

		bw = bw * tp->mss_cache * USEC_PER_SEC >> BW_SCALE;
		memset(&info->bbr, 0, sizeof(info->bbr));
		info->bbr.bbr_bw_lo		= (u32)bw;
		info->bbr.bbr_bw_hi		= (u32)(bw >> 32);
		info->bbr.bbr_min_rtt		= bbr->min_rtt_us;
		info->bbr.bbr_pacing_gain	= bbr_brutal_effective_pacing_gain(sk,
								     bbr->pacing_gain);
		info->bbr.bbr_cwnd_gain		= bbr->cwnd_gain;
		*attr = INET_DIAG_BBRINFO;
		return sizeof(info->bbr);
	}
	return 0;
}

static void bbr_set_state(struct sock *sk, u8 new_state)
{
	struct bbr *bbr = inet_csk_ca(sk);

	if (new_state == TCP_CA_Loss) {
		struct rate_sample rs = { .losses = 1 };

		bbr_enter_loss_guard_recovery(sk);
		bbr->prev_ca_state = TCP_CA_Loss;
		bbr->full_bw = 0;
		bbr->round_start = 1;	/* treat RTO like end of a round */
		bbr->loss_guard = 1;
		bbr->brutal_loss_pct = 100;
		bbr->cycle_idx = BBR_BRUTAL_CRUISE_0;
		bbr_brutal_reset_cruise_loss_p95(bbr);
		bbr_lt_bw_sampling(sk, &rs);
	}
}

static struct tcp_congestion_ops tcp_bbr_brutal_cong_ops __read_mostly = {
	.flags		= TCP_CONG_NON_RESTRICTED,
	.name		= "bbr_brutal",
	.owner		= THIS_MODULE,
	.init		= bbr_init,
	.cong_control	= bbr_main,
	.sndbuf_expand	= bbr_sndbuf_expand,
	.undo_cwnd	= bbr_undo_cwnd,
#if (defined(BBRB_TCP_CA_HAS_CWND_EVENT) && defined(BBRB_TCP_HAS_CA_EVENT_TX_START)) || 	!defined(BBRB_TCP_CA_PROBED)
	.cwnd_event	= bbr_cwnd_event,
#endif
#if defined(BBRB_TCP_CA_HAS_CWND_EVENT_TX_START) || 	(!defined(BBRB_TCP_CA_PROBED) && 	 LINUX_VERSION_CODE >= KERNEL_VERSION(7, 1, 0))
	.cwnd_event_tx_start = bbr_cwnd_event_tx_start,
#endif
	.ssthresh	= bbr_ssthresh,
#if defined(BBRB_TCP_CA_HAS_TSO_SEGS)
	.tso_segs	= bbr_tso_segs,
#elif defined(BBRB_TCP_CA_HAS_MIN_TSO_SEGS) || !defined(BBRB_TCP_CA_PROBED)
	.min_tso_segs	= bbr_min_tso_segs,
#endif
	.get_info	= bbr_get_info,
	.set_state	= bbr_set_state,
};

static int __init bbr_brutal_register(void)
{
	BUILD_BUG_ON(sizeof(struct bbr) > ICSK_CA_PRIV_SIZE);
	return tcp_register_congestion_control(&tcp_bbr_brutal_cong_ops);
}

static void __exit bbr_brutal_unregister(void)
{
	tcp_unregister_congestion_control(&tcp_bbr_brutal_cong_ops);
}

module_init(bbr_brutal_register);
module_exit(bbr_brutal_unregister);

MODULE_AUTHOR("Van Jacobson <vanj@google.com>");
MODULE_AUTHOR("Neal Cardwell <ncardwell@google.com>");
MODULE_AUTHOR("Yuchung Cheng <ycheng@google.com>");
MODULE_AUTHOR("Soheil Hassas Yeganeh <soheil@google.com>");
MODULE_LICENSE("Dual BSD/GPL");
MODULE_DESCRIPTION("TCP BBR-Brutal (BBRv1 ProbeRTT with Brutal-style ProbeBW)");
MODULE_VERSION("0.1.1");