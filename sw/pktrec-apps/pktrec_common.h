/* SPDX-License-Identifier: MIT */
/*
 * Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
 *
 * pktrec_common.h -- capture file header helpers shared by pktrec-cap and
 * pktrec-export (header-only). Generic helpers (err_msg, parse_size, ...)
 * come from the recorder's fdrec_common.h; the formats from
 * include/pktrec_format.h.
 */

#ifndef PKTREC_COMMON_H
#define PKTREC_COMMON_H

#include <endian.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "fdrec_common.h"
#include "pktrec_format.h"

#define PKTREC_APPS_VERSION     "1.0"

/*
 * The recorder device (/dev/fdrec0) has one user at a time: pktrec-cap holds
 * it for a whole capture, pktrec-replay for a streamed replay or, with
 * --preload, only while it loads the replay store (well under a second).
 * Both tools retry a busy (EBUSY) open for PKTREC_DEV_BUSY_WAIT_S, so the
 * documented "replay during a capture" sequence (pktrec-replay --preload
 * --wait-capture ... &, then pktrec-cap record) does not depend on which
 * process reaches the device first.
 */
#define PKTREC_DEV_BUSY_WAIT_S  5.0

static inline double pktrec_mono_s(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec + ts.tv_nsec * 1e-9;
}

/* open(dev, O_RDWR); while it fails with EBUSY retry every 50 ms for up to
 * wait_s seconds, saying so once (busy_why: who probably holds it). Returns
 * the fd, or -1 with errno from the last open(). */
static inline int pktrec_open_dev(const char *dev, double wait_s, const char *busy_why)
{
	double t0 = pktrec_mono_s();
	bool told = false;
	int fd;

	for (;;) {
		fd = open(dev, O_RDWR | O_CLOEXEC);
		if (fd >= 0 || errno != EBUSY || pktrec_mono_s() - t0 >= wait_s)
			return fd;
		if (!told) {
			fprintf(stderr, "%s: %s is busy (%s); retrying for up to %.0f s\n",
				prog_name, dev, busy_why, wait_s);
			told = true;
		}
		usleep(50000);
	}
}

/* pktrec_file_port.flags */
#define PKTREC_FPORT_ENABLED    (1u << 0)
#define PKTREC_FPORT_LINK_UP    (1u << 1)

/* Mode of the pair a port belongs to */
static inline const char *pktrec_port_mode(const struct pktrec_file_header *h, unsigned port)
{
	return (h->pair_mode >> (port / 2)) & 1 ? "TAP" : "monitor";
}

/* "2026-10-13 12:34:56.123456789 UTC" */
static inline void pktrec_fmt_time(uint64_t ns, char *buf, size_t len)
{
	time_t s = (time_t)(ns / 1000000000ull);
	struct tm tm;

	if (!ns || !gmtime_r(&s, &tm)) {
		snprintf(buf, len, "-");
		return;
	}
	snprintf(buf, len, "%04d-%02d-%02d %02d:%02d:%02d.%09" PRIu64 " UTC",
		 tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, tm.tm_hour, tm.tm_min,
		 tm.tm_sec, (uint64_t)(ns % 1000000000ull));
}

/* Byte-swap every multi-byte field between little-endian (file) and host
 * order; the same swap works in both directions. */
static inline void pktrec_hdr_swap(struct pktrec_file_header *h)
{
	unsigned i;

	h->header_version = le32toh(h->header_version);
	h->header_size = le32toh(h->header_size);
	h->record_format = le32toh(h->record_format);
	h->flags = le32toh(h->flags);
	h->cap_version = le32toh(h->cap_version);
	h->fdrec_version = le32toh(h->fdrec_version);
	h->num_ports = le32toh(h->num_ports);
	h->port_mask = le32toh(h->port_mask);
	h->pair_mode = le32toh(h->pair_mode);
	h->snaplen = le32toh(h->snaplen);
	h->start_time_ns = le64toh(h->start_time_ns);
	h->stop_time_ns = le64toh(h->stop_time_ns);
	h->tb_start_ns = le64toh(h->tb_start_ns);
	h->tb_stop_ns = le64toh(h->tb_stop_ns);
	h->tb_inc = le64toh(h->tb_inc);
	h->data_bytes = le64toh(h->data_bytes);
	h->records = le64toh(h->records);
	h->rec_drop_beats = le64toh(h->rec_drop_beats);
	h->dma_errors = le64toh(h->dma_errors);
	for (i = 0; i < PKTREC_NUM_PORTS; i++) {
		struct pktrec_file_port *p = &h->port[i];

		p->frames_rx = le64toh(p->frames_rx);
		p->frames_bad = le64toh(p->frames_bad);
		p->frames_drop = le64toh(p->frames_drop);
		p->bytes_rx = le64toh(p->bytes_rx);
		p->bytes_drop = le64toh(p->bytes_drop);
		p->frames_trunc = le64toh(p->frames_trunc);
		p->records = le64toh(p->records);
		p->speed_mbps = le32toh(p->speed_mbps);
		p->flags = le32toh(p->flags);
	}
	h->tb_disc_flags = le32toh(h->tb_disc_flags);
	h->tb_disc_locked_s = le32toh(h->tb_disc_locked_s);
	h->tb_disc_offset_ns = (int64_t)le64toh((uint64_t)h->tb_disc_offset_ns);
	h->tb_disc_freq_ppb = (int64_t)le64toh((uint64_t)h->tb_disc_freq_ppb);
	h->tb_disc_time_ns = le64toh(h->tb_disc_time_ns);
}

/* Read and check the header from fd (at its current position). Returns 0, or
 * -1 with a message. The header is converted to host byte order. */
static inline int pktrec_read_header(int fd, const char *name, struct pktrec_file_header *h)
{
	size_t got = 0;

	while (got < sizeof(*h)) {
		ssize_t n = read(fd, (char *)h + got, sizeof(*h) - got);

		if (n < 0 && errno == EINTR)
			continue;
		if (n < 0) {
			perr("read %s", name);
			return -1;
		}
		if (n == 0)
			break;
		got += (size_t)n;
	}
	if (got < sizeof(*h)) {
		err_msg("%s: too short for a capture file header (%zu bytes)", name, got);
		return -1;
	}
	if (memcmp(h->magic, PKTREC_FILE_MAGIC, PKTREC_FILE_MAGIC_LEN)) {
		if (!memcmp(h->magic, "FDREC", 5))
			err_msg("%s: an fdrec recording, not a packet capture", name);
		else
			err_msg("%s: not a packet capture file (bad magic)", name);
		return -1;
	}
	pktrec_hdr_swap(h);
	if (h->header_size != PKTREC_FILE_HEADER_SIZE) {
		err_msg("%s: header size %u, expected %u", name, h->header_size,
			PKTREC_FILE_HEADER_SIZE);
		return -1;
	}
	if (h->record_format != PKTREC_REC_FORMAT_VERSION) {
		err_msg("%s: record format version %u, this tool reads version %u", name,
			h->record_format, PKTREC_REC_FORMAT_VERSION);
		return -1;
	}
	return 0;
}

static inline void pktrec_print_header(FILE *f, const struct pktrec_file_header *h)
{
	char t0[64], t1[64];
	double el = h->stop_time_ns > h->start_time_ns ?
		    (double)(h->stop_time_ns - h->start_time_ns) / 1e9 : 0;
	unsigned i;

	pktrec_fmt_time(h->start_time_ns, t0, sizeof(t0));
	pktrec_fmt_time(h->stop_time_ns, t1, sizeof(t1));
	fprintf(f, "header version   %u, record format %u%s\n", h->header_version,
		h->record_format,
		(h->flags & PKTREC_FILE_FLAG_COMPLETE) ? "" :
		"  ** NOT COMPLETE: the capture did not stop cleanly; no stop counters **");
	fprintf(f, "target / host    %.32s / %.64s\n", h->target, h->hostname);
	fprintf(f, "design           %.32s (capture block 0x%08x, fdrec_core 0x%08x)\n",
		h->design[0] ? h->design : "-", h->cap_version, h->fdrec_version);
	fprintf(f, "pair modes       P0/P1 %s, P2/P3 %s\n", pktrec_port_mode(h, 0),
		pktrec_port_mode(h, 2));
	fprintf(f, "ports            ");
	for (i = 0; i < PKTREC_NUM_PORTS; i++)
		if (h->port_mask & (1u << i))
			fprintf(f, "P%u ", i);
	fprintf(f, "(mask 0x%x)\n", h->port_mask);
	if (h->snaplen)
		fprintf(f, "snaplen          %u bytes\n", h->snaplen);
	else
		fprintf(f, "snaplen          none (whole frames)\n");
	fprintf(f, "start            %s (timebase %" PRIu64 " ns%s)\n", t0, h->tb_start_ns,
		(h->flags & PKTREC_FILE_FLAG_TB_REALTIME) ? ", set from CLOCK_REALTIME" : "");
	fprintf(f, "stop             %s (timebase %" PRIu64 " ns), %.3f s%s%s%s\n", t1,
		h->tb_stop_ns, el,
		(h->flags & PKTREC_FILE_FLAG_LIMIT_SIZE) ? ", size limit" : "",
		(h->flags & PKTREC_FILE_FLAG_LIMIT_TIME) ? ", duration limit" : "",
		(h->flags & PKTREC_FILE_FLAG_DMA_ERROR) ? ", ENDED BY A DMA/IO ERROR" : "");
	fprintf(f, "timebase inc     %.6f ns/cycle\n", (double)h->tb_inc / 4294967296.0);
	if (h->tb_disc_flags & PKTREC_TBD_VALID)
		fprintf(f, "tb discipline    %s%s, offset %+.3f us, trim %+.3f ppm%s%s\n",
			(h->tb_disc_flags & PKTREC_TBD_DAEMON) ? "pktrec-tb " : "no daemon",
			(h->tb_disc_flags & PKTREC_TBD_DAEMON) ?
			((h->tb_disc_flags & PKTREC_TBD_LOCKED) ? "locked" : "not locked") : "",
			(double)h->tb_disc_offset_ns / 1e3, (double)h->tb_disc_freq_ppb / 1e3,
			(h->tb_disc_flags & PKTREC_TBD_NTP_SYNC) ? ", NTP synced" : ", NTP not synced",
			(h->tb_disc_flags & PKTREC_TBD_SET_AT_START) ? ", TB_SET at start" : "");
	else
		fprintf(f, "tb discipline    not recorded\n");
	fprintf(f, "data             %" PRIu64 " bytes, %" PRIu64 " records\n", h->data_bytes,
		h->records);
	fprintf(f, "recorder         %" PRIu64 " dropped beats, %" PRIu64 " DMA errors%s\n",
		h->rec_drop_beats, h->dma_errors,
		(h->rec_drop_beats || h->dma_errors) ? "  ** the record stream has gaps **" : "");
	fprintf(f, "port  link      %12s %10s %12s %14s %10s %12s\n", "frames_rx", "bad",
		"dropped", "bytes_rx", "truncated", "records");
	for (i = 0; i < PKTREC_NUM_PORTS; i++) {
		const struct pktrec_file_port *p = &h->port[i];
		char link[16];

		if (!(h->port_mask & (1u << i)))
			continue;
		if (p->flags & PKTREC_FPORT_LINK_UP)
			snprintf(link, sizeof(link), "%uM", p->speed_mbps);
		else
			snprintf(link, sizeof(link), "down");
		fprintf(f, "%-5.16s %-9s %12" PRIu64 " %10" PRIu64 " %12" PRIu64 " %14" PRIu64
			" %10" PRIu64 " %12" PRIu64 "\n", p->if_name[0] ? p->if_name : "?", link,
			p->frames_rx, p->frames_bad, p->frames_drop, p->bytes_rx,
			p->frames_trunc, p->records);
	}
}

#endif /* PKTREC_COMMON_H */
