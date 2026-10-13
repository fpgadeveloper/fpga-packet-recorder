/* SPDX-License-Identifier: MIT */
/*
 * Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
 *
 * pktrec_format_draft.h -- PROVISIONAL capture record + file header layout,
 * written from the campaign decision (record format v1) before the hardware
 * side committed include/pktrec_format.h. To be replaced by that header.
 */

#ifndef PKTREC_FORMAT_DRAFT_H
#define PKTREC_FORMAT_DRAFT_H

#include <stdint.h>

/* ---- capture record (16-byte header + frame bytes padded to 16 B) ---- */
struct pktrec_rec_hdr {
	uint64_t ts_ns;         /* shared timebase, ns */
	uint16_t cap_len;       /* bytes stored after the header, FCS excluded */
	uint16_t orig_len;      /* length on the wire incl. FCS */
	uint8_t  port;          /* 0..3 */
	uint8_t  flags;         /* PKTREC_REC_F_* | marker */
	uint16_t seq;           /* per-port frame sequence, wraps */
} __attribute__((packed));

#define PKTREC_REC_HDR_SIZE         16
#define PKTREC_REC_ALIGN            16
#define PKTREC_REC_F_BAD            (1u << 0)   /* bad frame / FCS error */
#define PKTREC_REC_F_TRUNC          (1u << 1)   /* truncated by snaplen */
#define PKTREC_REC_F_TS_MAC         (1u << 2)   /* ts source: 0 = SFD, 1 = MAC */
#define PKTREC_REC_F_SFD_MISMATCH   (1u << 3)   /* SFD mismatch / resync */
#define PKTREC_REC_MARKER_MASK      0xF0u
#define PKTREC_REC_MARKER           0xA0u
#define PKTREC_REC_LEN(cap_len)     ((PKTREC_REC_HDR_SIZE + (cap_len) + 15u) & ~15u)

/* ---- 4 KB capture file header ---- */
#define PKTREC_FILE_MAGIC           "PKTREC\0\0"
#define PKTREC_FILE_MAGIC_LEN       8
#define PKTREC_FILE_HEADER_VERSION  1
#define PKTREC_FILE_HEADER_SIZE     4096
#define PKTREC_FILE_FLAG_COMPLETE   (1u << 1)   /* header rewritten at stop */
#define PKTREC_FILE_FLAG_TS_WALL    (1u << 2)   /* timebase was set to wall-clock time */
#define PKTREC_MODE_MONITOR         0
#define PKTREC_MODE_TAP             1
#define PKTREC_NUM_PORTS_FILE       4

struct pktrec_file_port {
	uint64_t rx_good;       /* frames received OK by the MAC (counter delta) */
	uint64_t rx_bad;        /* frames received with an error */
	uint64_t dropped;       /* whole frames dropped before recording */
	uint64_t bytes;         /* bytes received (wire length incl. FCS) */
	uint64_t records;       /* records written to the stream */
	uint64_t reserved[3];
} __attribute__((packed));

struct pktrec_file_header {
	char     magic[8];          /* "PKTREC\0\0" */
	uint32_t header_version;    /* 1 */
	uint32_t header_size;       /* 4096 */
	uint32_t record_version;    /* 1 */
	uint32_t flags;             /* PKTREC_FILE_FLAG_* */
	uint32_t cap_id;            /* capture block ID register */
	uint32_t cap_version;       /* capture block VERSION register */
	uint32_t fdrec_version;     /* fdrec_core VERSION */
	uint32_t mode;              /* PKTREC_MODE_* */
	uint32_t port_mask;         /* bit n = port n enabled */
	uint32_t snaplen;           /* 0 = no limit */
	uint64_t start_time_ns;     /* CLOCK_REALTIME at start */
	uint64_t start_timebase_ns; /* timebase read at start */
	uint64_t stop_time_ns;      /* CLOCK_REALTIME at stop */
	uint64_t stop_timebase_ns;  /* timebase read at stop */
	uint64_t data_bytes;        /* record stream bytes after the header */
	uint64_t ring_drops;        /* fdrec ingest drop count (beats; expect 0) */
	char     target[32];
	char     hostname[64];
	struct pktrec_file_port port[PKTREC_NUM_PORTS_FILE];
	uint8_t  reserved[PKTREC_FILE_HEADER_SIZE - 8 - 10 * 4 - 6 * 8 - 32 - 64 -
			  PKTREC_NUM_PORTS_FILE * 64];
} __attribute__((packed));

_Static_assert(sizeof(struct pktrec_rec_hdr) == 16, "record header must be 16 bytes");
_Static_assert(sizeof(struct pktrec_file_header) == PKTREC_FILE_HEADER_SIZE,
	       "file header must be 4096 bytes");

#endif
