# SPDX-License-Identifier: GPL-2.0
# External module Makefile for DKMS builds.

ifneq ($(KBUILD_EXTMOD),)
obj-m += tcp_bbrw_brutal.o

# Detect tcp_congestion_ops API from the target kernel headers, not from
# LINUX_VERSION_CODE. This keeps the module buildable on stock distribution
# kernels and on BBRv3/L4S kernels whose TCP CC API differs from upstream.
bbrwb_tcp_h := $(firstword $(wildcard \
	$(KDIR)/include/net/tcp.h \
	$(KDIR)/source/include/net/tcp.h \
	$(srctree)/include/net/tcp.h \
	$(objtree)/include/net/tcp.h \
	/lib/modules/$(KERNELRELEASE)/build/include/net/tcp.h \
	/lib/modules/$(KERNELRELEASE)/source/include/net/tcp.h))

bbrwb_api_cflags := ${shell if [ -n "$(bbrwb_tcp_h)" ]; then \
	perl -0777 -ne '''\
		print "-DBBRWB_TCP_CA_PROBED "; \
		print "-DBBRWB_TCP_CA_HAS_TSO_SEGS " \
			if /\(\s*\*\s*tso_segs\s*\)\s*\(/s; \
		print "-DBBRWB_TCP_CA_TSO_SEGS_1_ARG " \
			if /\(\s*\*\s*tso_segs\s*\)\s*\(\s*struct\s+sock\s*\*\s*\w*\s*\)/s; \
		print "-DBBRWB_TCP_CA_HAS_MIN_TSO_SEGS " \
			if /\(\s*\*\s*min_tso_segs\s*\)\s*\(/s; \
		print "-DBBRWB_TCP_CA_HAS_CWND_EVENT " \
			if /\(\s*\*\s*cwnd_event\s*\)\s*\(/s; \
		print "-DBBRWB_TCP_CA_HAS_CWND_EVENT_TX_START " \
			if /\(\s*\*\s*cwnd_event_tx_start\s*\)\s*\(/s; \
		print "-DBBRWB_TCP_HAS_CA_EVENT_TX_START " \
			if /\bCA_EVENT_TX_START\b/s; \
		print "-DBBRWB_TCP_CA_CONG_CONTROL_4_ARGS " \
			if /\(\s*\*\s*cong_control\s*\)\s*\(\s*struct\s+sock\s*\*\s*\w*\s*,\s*u32\s+\w+\s*,\s*(?:int|u32)\s+\w+\s*,\s*const\s+struct\s+rate_sample\s*\*\s*\w*\s*\)/s; \
		print "-DBBRWB_TCP_CA_CONG_CONTROL_2_ARGS " \
			if /\(\s*\*\s*cong_control\s*\)\s*\(\s*struct\s+sock\s*\*\s*\w*\s*,\s*const\s+struct\s+rate_sample\s*\*\s*\w*\s*\)/s; \
		''' "$(bbrwb_tcp_h)" 2>/dev/null; \
	fi}

ccflags-y += $(bbrwb_api_cflags)

else
KDIR ?= /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)

.PHONY: all modules clean
all modules:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
endif
