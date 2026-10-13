/* SPDX-License-Identifier: MIT */
/*
 * Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
 *
 * pktrec_common.h -- capture file header helpers shared by pktrec-cap and
 * pktrec-export (header-only). Generic helpers (err_msg, parse_size, ...)
 * come from the recorder's fdrec_common.h.
 */

#ifndef PKTREC_COMMON_H
#define PKTREC_COMMON_H

#include <endian.h>
#include <errno.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "fdrec_common.h"
#include "pktrec_format_draft.h"

#define PKTREC_APPS_VERSION     "1.0"

static inline const char *pktrec_mode_name(uint32_t mode)
{
	switch (mode) {
	case PKTREC_MODE_MONITOR: return "monitor";
	case PKTREC_MODE_TAP: return "tap";
	default: return "unknown";
	}
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

/* Header in host byte order (the file is little-endian) */
static inline void pktrec_hdr_to_host(struct pktrec_file_header *h)
{
	unsigned i;

	h->header_version = le32toh(h->header_version);
	h->header_size = le32toh(h->header_size);
	h->record_version = le32toh(h->record_version);
	h->flags = le32toh(h->flags);
	h->cap_id = le32toh(h->cap_id);
	h->cap_version = le32toh(h->cap_version);
	h->fdrec_version = le32toh(h->fdrec_version);
	h->mode = le32toh(h->mode);
	h->port_mask = le32toh(h->port_mask);
	h->snaplen = le32toh(h->snaplen);
	h->start_time_ns = le64toh(h->start_time_ns);
	h->start_timebase_ns = le64toh(h->start_timebase_ns);
	h->stop_time_ns = le64toh(h->stop_time_ns);
	h->stop_timebase_ns = le64toh(h->stop_timebase_ns);
	h->data_bytes = le64toh(h->data_bytes);
	h->ring_drops = le64toh(h->ring_drops);
	for (i = 0; i < PKTREC_NUM_PORTS_FILE; i++) {
		struct pktrec_file_port *p = &h->port[i];

		p->rx_good = le64toh(p->rx_good);
		p->rx_bad = le64toh(p->rx_bad);
		p->dropped = le64toh(p->dropped);
		p->bytes = le64toh(p->bytes);
		p->records = le64toh(p->records);
	}
}

/* The inverse (it is its own inverse on little-endian hosts) */
static inline void pktrec_hdr_to_le(struct pktrec_file_header *h)
{
	pktrec_hdr_to_host(h);  /* leXXtoh and htoleXX are the same swap */
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
	pktrec_hdr_to_host(h);
	if (h->header_size != PKTREC_FILE_HEADER_SIZE) {
		err_msg("%s: header size %u, expected %u", name, h->header_size,
			PKTREC_FILE_HEADER_SIZE);
		return -1;
	}
	if (h->record_version != 1) {
		err_msg("%s: record format version %u, this tool reads version 1", name,
			h->record_version);
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
	fprintf(f, "header version   %u (record format %u)%s\n", h->header_version,
		h->record_version,
		(h->flags & PKTREC_FILE_FLAG_COMPLETE) ? "" :
		"  ** NOT COMPLETE: capture did not stop cleanly; counters missing **");
	fprintf(f, "target / host    %.32s / %.64s\n", h->target, h->hostname);
	fprintf(f, "design           capture ID 0x%08x version 0x%08x, fdrec 0x%08x\n",
		h->cap_id, h->cap_version, h->fdrec_version);
	fprintf(f, "mode             %s\n", pktrec_mode_name(h->mode));
	fprintf(f, "ports            ");
	for (i = 0; i < PKTREC_NUM_PORTS_FILE; i++)
		if (h->port_mask & (1u << i))
			fprintf(f, "P%u ", i);
	fprintf(f, "(mask 0x%x)\n", h->port_mask);
	if (h->snaplen)
		fprintf(f, "snaplen          %u bytes\n", h->snaplen);
	else
		fprintf(f, "snaplen          none (whole frames)\n");
	fprintf(f, "start            %s (timebase %" PRIu64 " ns%s)\n", t0,
		h->start_timebase_ns,
		(h->flags & PKTREC_FILE_FLAG_TS_WALL) ? ", wall clock" : "");
	fprintf(f, "stop             %s (timebase %" PRIu64 " ns), %.3f s\n", t1,
		h->stop_timebase_ns, el);
	fprintf(f, "data             %" PRIu64 " bytes of records\n", h->data_bytes);
	fprintf(f, "ring drops       %" PRIu64 " beats%s\n", h->ring_drops,
		h->ring_drops ? "  ** the record stream has gaps **" : "");
	fprintf(f, "port   %14s %10s %12s %16s %14s\n", "rx_good", "rx_bad", "dropped",
		"bytes", "records");
	for (i = 0; i < PKTREC_NUM_PORTS_FILE; i++) {
		const struct pktrec_file_port *p = &h->port[i];

		if (!(h->port_mask & (1u << i)) && !p->rx_good && !p->rx_bad)
			continue;
		fprintf(f, "P%u     %14" PRIu64 " %10" PRIu64 " %12" PRIu64 " %16" PRIu64
			" %14" PRIu64 "%s\n", i, p->rx_good, p->rx_bad, p->dropped, p->bytes,
			p->records, (h->port_mask & (1u << i)) ? "" : "  (not captured)");
	}
}

#endif /* PKTREC_COMMON_H */
