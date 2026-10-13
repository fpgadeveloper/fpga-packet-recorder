/* SPDX-License-Identifier: MIT */
/*
 * Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
 *
 * pktrec_format.h -- capture record stream and capture file format of the
 * FPGA Packet Recorder (record format v1, M1).
 *
 * RECORD STREAM
 * -------------
 * The capture hardware (Vivado/src/hdl/pktrec_cap_*.sv) turns every frame it
 * captures into one RECORD and the records of all ports are merged into one
 * byte stream that the recorder datapath (fdrec_core -> AXI DMA -> hugepage
 * ring) writes to memory 16 bytes (one 128-bit beat) at a time:
 *
 *     record = struct pktrec_rec_hdr (16 bytes)
 *            + cap_len frame bytes (destination MAC first, FCS NOT included)
 *            + 0..15 zero bytes so that the record is a multiple of 16 bytes
 *
 *     PKTREC_REC_BYTES(cap_len) = 16 + ((cap_len + 15) & ~15)
 *
 * Records follow each other back to back; every record starts on a 16-byte
 * boundary of the stream. The stream has NO relation to the DMA buffer
 * boundaries: a record may span two (or more) recorder buffers, so a reader
 * must treat the buffers as one continuous byte stream.
 *
 * Fill units: at a record boundary the stream may contain any number of
 * 16-byte units that are ALL ZERO ("fill", PKTREC_CTRL_FILL is used to push the
 * last data through the DMA when a capture stops; see pktrec_regs.h). A fill
 * unit has flags = 0, so it can never be mistaken for a header (the marker
 * nibble of a header is always 0xA). Readers skip them.
 *
 * Record order: records of one port are in arrival order (seq increments by
 * one per frame). Records of different ports are interleaved in the order the
 * merge granted them (round robin over whole records), which is NOT strict
 * timestamp order: a reader that needs timestamp order (the pcapng exporter)
 * reorders within a bounded window. The bound: a record leaves the hardware at
 * most (per-port FIFO size / port line rate) after the frame ended, plus the
 * back-pressure time of the recorder; 16 KB per port at 1 Gb/s = 131 us of
 * frame data, i.e. a window of a few ms is ample.
 *
 * Validity checks for a header (all must hold; otherwise the reader has lost
 * framing -- count it and re-synchronise by scanning forward 16 bytes at a time
 * for the next unit that passes them, preferring one whose seq continues the
 * port's sequence):
 *     (flags & PKTREC_REC_MARKER_MASK) == PKTREC_REC_MARKER
 *     port < PKTREC_NUM_PORTS
 *     cap_len >= 1 and cap_len + 4 <= orig_len
 *     truncated flag == (cap_len + 4 < orig_len)
 *
 * Sequence numbers: seq is assigned to EVERY frame that starts while the port
 * is enabled for capture -- including frames that are then dropped by the
 * hardware -- so a gap in a port's seq (modulo 2^16) is exactly the number of
 * frames the hardware dropped there (also counted in PKTREC_CAP_P_FRAMES_DROP).
 * seq restarts at 0 on PKTREC_CAP_CTRL_CLEAR.
 *
 * Timestamps: ts_ns is the value of the shared 64-bit nanosecond timebase
 * (pktrec_timebase, registers PKTREC_CAP_TB_*) at the frame's start of frame
 * delimiter. Since capture register map 1.2 (M2) it is the time at which the
 * PHY indicated the SFD on its RX SFD pin (PKTREC_REC_FLAG_TS_MAC = 0; ~1 ns
 * resolution, + PKTREC_SFD_P_RX_OFFSET, see PKTREC_SFD_* in pktrec_regs.h).
 * A frame without a matching SFD indication falls back to the Taxi MAC
 * timestamp (TS_MAC = 1): 16 ns quantisation (one 62.5 MHz MAC clock) plus
 * MAC_OFFSET; with MAC_OFFSET calibrated (= RX_OFFSET - median RX_DELTA) it is
 * on the same scale as the SFD timestamps, within ~+-16 ns. (In M1 images
 * every record has TS_MAC = 1.) If software set the timebase to
 * CLOCK_REALTIME (TB_SET), ts_ns is nanoseconds since the Unix epoch.
 *
 * Byte order: all multi-byte fields are little-endian (beat byte k = TDATA bits
 * [8k+7:8k]); frame bytes are in wire order.
 *
 * CAPTURE FILE
 * ------------
 *     offset 0      struct pktrec_file_header (4096 bytes, zero-padded)
 *     offset 4096   the record stream, data_bytes bytes (fill units allowed)
 *
 * The 4 KB header keeps the data O_DIRECT-aligned (same scheme as
 * fdrec_file.h). The capture app writes it at the start (flags without
 * COMPLETE) and rewrites it at the end with the final counts.
 *
 * Plain C, no includes beyond stdint.h; sizes checked at compile time.
 */

#ifndef PKTREC_FORMAT_H
#define PKTREC_FORMAT_H

#include <stdint.h>

#ifndef PKTREC_NUM_PORTS
#define PKTREC_NUM_PORTS                4
#endif

/* ------------------------------------------------------------------------- */
/* Record header (16 bytes)                                                   */
/* ------------------------------------------------------------------------- */

#define PKTREC_REC_FORMAT_VERSION       1
#define PKTREC_REC_HDR_BYTES            16
#define PKTREC_REC_ALIGN                16
#define PKTREC_REC_BYTES(cap_len)       (PKTREC_REC_HDR_BYTES + \
                                         (((uint32_t)(cap_len) + 15u) & ~15u))
#define PKTREC_FCS_BYTES                4       /* orig_len includes it, cap_len never */

/* flags */
#define PKTREC_REC_FLAG_BAD             (1u << 0)  /* MAC flagged the frame: FCS error,
                                                      framing/symbol error or oversize */
#define PKTREC_REC_FLAG_TRUNC           (1u << 1)  /* truncated by SNAPLEN */
#define PKTREC_REC_FLAG_TS_MAC          (1u << 2)  /* ts source: 1 = MAC (fallback /
                                                      M1), 0 = PHY SFD (M2) */
#define PKTREC_REC_FLAG_SFD_MISMATCH    (1u << 3)  /* SFD resync: while this frame was
                                                      matched, one or more queued SFD
                                                      indications older than the window
                                                      (pulses without a frame) were
                                                      discarded (PKTREC_SFD_P_RX_STALE).
                                                      Independent of bit2: the frame
                                                      itself may still have its SFD
                                                      timestamp. 0 in M1. */
#define PKTREC_REC_FLAG_SFD_RESYNC      PKTREC_REC_FLAG_SFD_MISMATCH
#define PKTREC_REC_MARKER_MASK          0xF0u
#define PKTREC_REC_MARKER               0xA0u      /* flags[7:4] == 0xA in every header */

struct pktrec_rec_hdr {
	uint64_t ts_ns;       /* bytes 0-7:   shared timebase, ns, at SFD */
	uint16_t cap_len;     /* bytes 8-9:   frame bytes stored (FCS excluded) */
	uint16_t orig_len;    /* bytes 10-11: length on the wire incl. FCS */
	uint8_t  port;        /* byte 12:     receiving port 0..3 (OP080 P0..P3) */
	uint8_t  flags;       /* byte 13:     PKTREC_REC_FLAG_* | PKTREC_REC_MARKER */
	uint16_t seq;         /* bytes 14-15: per-port frame sequence (wraps) */
} __attribute__((packed));

/* ------------------------------------------------------------------------- */
/* Capture file header (4096 bytes)                                           */
/* ------------------------------------------------------------------------- */

#define PKTREC_FILE_MAGIC               "PKTRCAP\0"   /* 8 bytes incl. NUL */
#define PKTREC_FILE_MAGIC_LEN           8
#define PKTREC_FILE_HEADER_VERSION      1
#define PKTREC_FILE_HEADER_SIZE         4096

/* pktrec_file_header.flags */
#define PKTREC_FILE_FLAG_COMPLETE       (1u << 0)  /* header rewritten at stop */
#define PKTREC_FILE_FLAG_TB_REALTIME    (1u << 1)  /* timebase was set from
                                                      CLOCK_REALTIME before start */
#define PKTREC_FILE_FLAG_LIMIT_SIZE     (1u << 2)  /* stopped by the size limit */
#define PKTREC_FILE_FLAG_LIMIT_TIME     (1u << 3)  /* stopped by the duration limit */
#define PKTREC_FILE_FLAG_DMA_ERROR      (1u << 4)  /* a DMA/IO error ended the capture */

/* pktrec_file_header.tb_disc_flags: state of the timebase discipline daemon
 * (pktrec-tb, /run/pktrec/tb.json) when the capture started. Carved out of the
 * reserved bytes without a header version change: files written before have
 * zeros there (= "not recorded"). */
#define PKTREC_TBD_VALID                (1u << 0)  /* the tb_disc_* fields are filled in */
#define PKTREC_TBD_DAEMON               (1u << 1)  /* pktrec-tb daemon running (state fresh) */
#define PKTREC_TBD_LOCKED               (1u << 2)  /* timebase locked to CLOCK_REALTIME */
#define PKTREC_TBD_NTP_SYNC             (1u << 3)  /* system clock NTP-synchronised */
#define PKTREC_TBD_SET_AT_START         (1u << 4)  /* pktrec-cap did TB_SET at start (the
                                                      daemon was not locked) */

/* pktrec_file_header.pair_mode: bit p = mode of pair p (P0/P1 = 0, P2/P3 = 1) */
#define PKTREC_PAIR_MODE_MONITOR        0u
#define PKTREC_PAIR_MODE_TAP            1u

/* Per-port statistics: copies of the PKTREC_CAP_P_* counters at stop (after
 * PKTREC_CAP_STATUS.IDLE), and the port state at start. */
struct pktrec_file_port {
	uint64_t frames_rx;     /* PKTREC_CAP_P_FRAMES_RX: frames seen while enabled */
	uint64_t frames_bad;    /* PKTREC_CAP_P_FRAMES_BAD */
	uint64_t frames_drop;   /* PKTREC_CAP_P_FRAMES_DROP: dropped by the hardware
	                           (pcapng isb_ifdrop) */
	uint64_t bytes_rx;      /* PKTREC_CAP_P_BYTES_RX (wire bytes incl. FCS) */
	uint64_t bytes_drop;    /* PKTREC_CAP_P_BYTES_DROP */
	uint64_t frames_trunc;  /* PKTREC_CAP_P_FRAMES_TRUNC */
	uint64_t records;       /* PKTREC_CAP_P_RECORDS: records in the stream */
	uint32_t speed_mbps;    /* link speed at start (0 = link down) */
	uint32_t flags;         /* bit 0: enabled for capture, bit 1: link up at start */
	char     if_name[16];   /* "P0".."P3", NUL-padded (pcapng if_name) */
} __attribute__((packed));                                     /* 80 bytes */

struct pktrec_file_header {
	char     magic[8];          /* PKTREC_FILE_MAGIC */
	uint32_t header_version;    /* PKTREC_FILE_HEADER_VERSION */
	uint32_t header_size;       /* 4096 */
	uint32_t record_format;     /* PKTREC_REC_FORMAT_VERSION */
	uint32_t flags;             /* PKTREC_FILE_FLAG_* */
	uint32_t cap_version;       /* PKTREC_CAP_VERSION register */
	uint32_t fdrec_version;     /* fdrec_core VERSION (FDREC_IOC info) */
	uint32_t num_ports;         /* PKTREC_NUM_PORTS */
	uint32_t port_mask;         /* PKTREC_CAP_PORT_EN at start */
	uint32_t pair_mode;         /* PKTREC_PAIR_MODE_* per pair */
	uint32_t snaplen;           /* PKTREC_CAP_SNAPLEN (0 = whole frames) */
	uint64_t start_time_ns;     /* CLOCK_REALTIME at start */
	uint64_t stop_time_ns;      /* CLOCK_REALTIME at stop */
	uint64_t tb_start_ns;       /* timebase (PKTREC_CAP_TB_NOW) right after start */
	uint64_t tb_stop_ns;        /* timebase at stop */
	uint64_t tb_inc;            /* timebase increment per dp_clk, ns in 32.32 */
	uint64_t data_bytes;        /* valid record-stream bytes after the header
	                               (= PKTREC_CAP_BYTES_OUT at stop) */
	uint64_t records;           /* PKTREC_CAP_RECORDS_OUT at stop */
	uint64_t rec_drop_beats;    /* fdrec ING_DROP_COUNT (0 by design in capture mode) */
	uint64_t dma_errors;        /* fdrec driver DMA error count */
	char     target[32];        /* e.g. "zcu106", NUL-padded */
	char     hostname[64];      /* NUL-padded */
	char     design[32];        /* e.g. git describe of the design, NUL-padded */
	struct pktrec_file_port port[PKTREC_NUM_PORTS];          /* 320 bytes */
	/* timebase discipline at start (PKTREC_TBD_*; all zero = not recorded) */
	uint32_t tb_disc_flags;     /* PKTREC_TBD_* */
	uint32_t tb_disc_locked_s;  /* seconds the daemon had been locked (0 = not locked) */
	int64_t  tb_disc_offset_ns; /* timebase - CLOCK_REALTIME, measured by the capture app
	                               right before ENABLE */
	int64_t  tb_disc_freq_ppb;  /* INC at start vs nominal 1e9/DP_CLK_HZ, ppb */
	uint64_t tb_disc_time_ns;   /* CLOCK_REALTIME of the offset measurement */
	uint8_t  reserved[PKTREC_FILE_HEADER_SIZE - 8 - 10 * 4 - 9 * 8 - 32 - 64 - 32
	                  - PKTREC_NUM_PORTS * 80 - 32];
} __attribute__((packed));

#ifdef __cplusplus
static_assert(sizeof(struct pktrec_rec_hdr) == PKTREC_REC_HDR_BYTES,
	      "pktrec_rec_hdr must be 16 bytes");
static_assert(sizeof(struct pktrec_file_port) == 80, "pktrec_file_port must be 80 bytes");
static_assert(sizeof(struct pktrec_file_header) == PKTREC_FILE_HEADER_SIZE,
	      "pktrec_file_header must be 4096 bytes");
#else
_Static_assert(sizeof(struct pktrec_rec_hdr) == PKTREC_REC_HDR_BYTES,
	       "pktrec_rec_hdr must be 16 bytes");
_Static_assert(sizeof(struct pktrec_file_port) == 80, "pktrec_file_port must be 80 bytes");
_Static_assert(sizeof(struct pktrec_file_header) == PKTREC_FILE_HEADER_SIZE,
	       "pktrec_file_header must be 4096 bytes");
#endif

#endif /* PKTREC_FORMAT_H */
