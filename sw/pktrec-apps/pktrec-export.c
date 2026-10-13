// SPDX-License-Identifier: MIT
/*
 * pktrec-export -- FPGA Packet Recorder: capture file -> pcapng (streaming).
 *
 * Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
 *
 * Reads a capture file (4 KB header + record stream) sequentially and writes
 * a pcapng file to a file or stdout, without seeking, so a web server can
 * convert while it sends the download.
 *
 *   SHB  shb_hardware / shb_os / shb_userappl, capture summary as opt_comment
 *   IDB  one per captured port: if_name "P<n>", if_description,
 *        if_tsresol 9 (ns), if_fcslen 0, snaplen, LINKTYPE_ETHERNET
 *   EPB  per record, in timestamp order: 64-bit ns timestamp, caplen = the
 *        stored bytes (FCS excluded), len = the length on the wire INCLUDING
 *        the FCS, epb_flags (inbound, reception type, CRC error bit 24)
 *   ISB  per interface at the end: isb_starttime/endtime, isb_ifrecv,
 *        isb_ifdrop (frames the port dropped), isb_filteraccept (records
 *        the hardware wrote), isb_usrdeliv (EPBs written by this export)
 *
 * Records arrive in the order the hardware's round-robin arbiter took them,
 * not in timestamp order: a short frame on one port can be recorded before a
 * long frame that started earlier on another port, and a port's frame FIFO
 * can hold frames while the others are served. A bounded reorder window (a
 * min-heap on the timestamp) restores timestamp order: a record is written
 * once more than --window-records records or --window-bytes bytes are held.
 *
 * Corruption (a record header that fails the checks: marker nibble, port,
 * lengths) starts a resynchronisation: scan forward in 16-byte steps for a
 * header that passes the checks AND is followed by another valid header (or
 * the end of the data). All-zero 16-byte blocks between records are padding
 * and skipped silently.
 *
 * Exit codes: 0 = clean, 2 = written but with anomalies (resyncs, records
 * later than the window, a truncated tail), 1 = error.
 */

#define _GNU_SOURCE
#include <endian.h>
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <inttypes.h>
#include <limits.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/utsname.h>

#include "pktrec_common.h"

const char *prog_name = "pktrec-export";

/*
 * Default window. Records of different ports can only be out of timestamp
 * order by what the per-port frame FIFOs hold while the arbiter serves the
 * other ports: at most 4 ports x FIFO depth. With 16 KB FIFOs that is 64 KB,
 * i.e. at most ~820 minimum-size (80-byte) records. The defaults are far
 * above that (x64) so that a deeper FIFO in a later design does not need a
 * new option; the memory cost is the held bytes (4 MB) plus ~48 bytes per
 * held record.
 */
#define DEF_WINDOW_RECORDS      65536u
#define DEF_WINDOW_BYTES        (4u << 20)
#define DEF_MAX_FRAME           9622u   /* jumbo frame incl. FCS + VLAN tags */
#define RD_BUF_SIZE             (8u << 20)
#define MAX_REC_LEN             (PKTREC_REC_HDR_SIZE + 65536u)
/* how far a record's timestamp may lie before the newest one seen before a
 * resynchronisation counts it as plausible */
#define RESYNC_TS_BACK_NS       1000000000ull

#define LINKTYPE_ETHERNET       1
#define BT_SHB                  0x0A0D0D0Au
#define BT_IDB                  0x00000001u
#define BT_EPB                  0x00000006u
#define BT_ISB                  0x00000005u
#define OPT_ENDOFOPT            0
#define OPT_COMMENT             1
#define SHB_HARDWARE            2
#define SHB_OS                  3
#define SHB_USERAPPL            4
#define IF_NAME                 2
#define IF_DESCRIPTION          3
#define IF_TSRESOL              9
#define IF_FCSLEN               13
#define EPB_FLAGS               2
#define ISB_STARTTIME           2
#define ISB_ENDTIME             3
#define ISB_IFRECV              4
#define ISB_IFDROP              5
#define ISB_FILTERACCEPT        6
#define ISB_USRDELIV            8

/* epb_flags */
#define EPBF_INBOUND            1u
#define EPBF_RX_UNICAST         (1u << 2)
#define EPBF_RX_MULTICAST       (2u << 2)
#define EPBF_RX_BROADCAST       (3u << 2)
#define EPBF_RX_PROMISC         (4u << 2)
#define EPBF_CRC_ERROR          (1u << 24)

struct opts {
	const char *input;
	const char *output;
	uint32_t window_records;
	uint64_t window_bytes;
	uint32_t max_frame;
	uint32_t port_filter;   /* ports to export (bit n), default all captured */
	bool raw_ts;
	bool no_isb;
	bool comments;
	bool force;
	bool quiet;
};

struct ent {
	uint64_t ts;            /* raw timebase value */
	uint64_t arrival;       /* tie-break: arrival order */
	uint8_t *data;
	uint16_t seq;
	uint16_t cap_len;
	uint16_t orig_len;
	uint8_t port;
	uint8_t flags;
};

struct port_st {
	uint64_t records;       /* parsed */
	uint64_t written;       /* EPBs written */
	uint64_t bad;
	uint64_t trunc;
	uint64_t seq_gaps;
	uint64_t seq_missing;
	uint64_t first_ts, last_ts;
	uint16_t last_seq;
	bool have_seq;
};

struct exp {
	struct opts o;
	struct pktrec_file_header h;
	int in;
	FILE *out;
	/* reader */
	uint8_t *buf;
	size_t len, pos;
	bool eof;
	uint64_t remain;        /* data bytes still to read from the file */
	uint64_t offset;        /* stream offset of buf[pos] */
	/* window */
	struct ent *heap;
	size_t nheap, heap_cap;
	uint64_t held_bytes;
	uint64_t arrival;
	size_t max_held;
	uint64_t max_disp;      /* largest arrival - output position: window needed */
	uint64_t last_out_ts;
	bool have_out;
	/* interfaces */
	int ifid[PKTREC_NUM_PORTS_FILE];        /* -1 = not exported */
	uint32_t ports;                         /* captured ports (mask) */
	/* stats */
	struct port_st ps[PKTREC_NUM_PORTS_FILE];
	uint64_t records, out_records, pad_bytes, resyncs, skipped_bytes, late;
	uint64_t tail_bytes, filtered;
	uint64_t newest_ts;
	bool have_newest;
	bool resyncing;
	uint64_t resync_start;
	int64_t ts_offset;      /* added to the raw timestamp for the output */
};

static volatile sig_atomic_t g_stop;

static void on_signal(int sig)
{
	(void)sig;
	g_stop = 1;
}

static void usage(FILE *f)
{
	fprintf(f,
"Usage: pktrec-export [options] <capture-file|-> [-o <out.pcapng|->]\n"
"\n"
"Convert an FPGA Packet Recorder capture file to pcapng, streaming (no seeks,\n"
"no temporary file): frames in timestamp order, one interface per port,\n"
"nanosecond timestamps, per-port drop statistics.\n"
"\n"
"Options:\n"
"  -o, --output <file>       output file, '-' = stdout (default; refused on a\n"
"                            terminal unless --force)\n"
"  --port <n>                export only port n (repeatable; default: every\n"
"                            captured port)\n"
"  --window-records <n>      reorder window: records held (default %u)\n"
"  --window-bytes <bytes>    reorder window: frame bytes held (default %uM)\n"
"  --max-frame <bytes>       largest plausible frame incl. FCS (default %u)\n"
"  --raw-ts                  write the raw timebase values instead of wall-clock\n"
"                            time (start time + offset from the start)\n"
"  --comments                per-packet opt_comment for records flagged with a\n"
"                            MAC (not SFD) timestamp or an SFD mismatch\n"
"  --no-isb                  no Interface Statistics Blocks\n"
"  --force                   write binary output to a terminal\n"
"  -q, --quiet               no summary on stderr\n"
"  -h, --help                this help\n"
"\n"
"The pcapng packet length (len) is the frame length on the wire INCLUDING the\n"
"4-byte FCS; the captured bytes never include the FCS (if_fcslen = 0), so an\n"
"untruncated frame has caplen = len - 4.\n"
"\n"
"Exit code: 0 = clean, 2 = written with anomalies (corrupt stretches skipped,\n"
"records outside the reorder window, truncated tail), 1 = error.\n",
		DEF_WINDOW_RECORDS, DEF_WINDOW_BYTES >> 20, DEF_MAX_FRAME);
}

static int parse_args(int argc, char **argv, struct opts *o)
{
	static const struct option lo[] = {
		{ "output", required_argument, NULL, 'o' },
		{ "port", required_argument, NULL, 'p' },
		{ "window-records", required_argument, NULL, 'W' },
		{ "window-bytes", required_argument, NULL, 'B' },
		{ "max-frame", required_argument, NULL, 'M' },
		{ "raw-ts", no_argument, NULL, 'r' },
		{ "comments", no_argument, NULL, 'c' },
		{ "no-isb", no_argument, NULL, 'I' },
		{ "force", no_argument, NULL, 'f' },
		{ "quiet", no_argument, NULL, 'q' },
		{ "help", no_argument, NULL, 'h' },
		{ NULL, 0, NULL, 0 },
	};
	int c;
	uint64_t v;

	memset(o, 0, sizeof(*o));
	o->output = "-";
	o->window_records = DEF_WINDOW_RECORDS;
	o->window_bytes = DEF_WINDOW_BYTES;
	o->max_frame = DEF_MAX_FRAME;

	while ((c = getopt_long(argc, argv, "o:qh", lo, NULL)) != -1) {
		switch (c) {
		case 'o':
			o->output = optarg;
			break;
		case 'p':
			if (parse_size(optarg, &v) || v >= PKTREC_NUM_PORTS_FILE)
				return die_usage("--port must be 0..%d", PKTREC_NUM_PORTS_FILE - 1);
			o->port_filter |= 1u << v;
			break;
		case 'W':
			if (parse_size(optarg, &v) || v > 64u << 20)
				return die_usage("invalid --window-records '%s'", optarg);
			o->window_records = (uint32_t)v;
			break;
		case 'B':
			if (parse_size(optarg, &v))
				return die_usage("invalid --window-bytes '%s'", optarg);
			o->window_bytes = v;
			break;
		case 'M':
			if (parse_size(optarg, &v) || v < 64 || v > 65535)
				return die_usage("--max-frame must be 64..65535");
			o->max_frame = (uint32_t)v;
			break;
		case 'r':
			o->raw_ts = true;
			break;
		case 'c':
			o->comments = true;
			break;
		case 'I':
			o->no_isb = true;
			break;
		case 'f':
			o->force = true;
			break;
		case 'q':
			o->quiet = true;
			break;
		case 'h':
			usage(stdout);
			exit(0);
		default:
			usage(stderr);
			return -1;
		}
	}
	if (optind != argc - 1)
		return die_usage("exactly one <capture-file> is required");
	o->input = argv[optind];
	return 0;
}

/* ------------------------------------------------------------------------ */
/* pcapng writer                                                            */

static int put(struct exp *e, const void *p, size_t n)
{
	if (n && fwrite(p, 1, n, e->out) != n)
		return -1;
	return 0;
}

static int put32(struct exp *e, uint32_t v)
{
	return put(e, &v, 4);
}

static size_t opt_len(size_t vlen)
{
	return 4 + ((vlen + 3) & ~(size_t)3);
}

static int put_opt(struct exp *e, uint16_t code, const void *val, size_t vlen)
{
	static const uint8_t zero[4];
	uint16_t h[2] = { code, (uint16_t)vlen };

	if (put(e, h, 4) || put(e, val, vlen))
		return -1;
	return put(e, zero, ((vlen + 3) & ~(size_t)3) - vlen);
}

static int put_opt_str(struct exp *e, uint16_t code, const char *s)
{
	return put_opt(e, code, s, strlen(s));
}

static int put_opt_u64(struct exp *e, uint16_t code, uint64_t v)
{
	return put_opt(e, code, &v, 8);
}

/* timestamps in options are stored like the EPB's: high word, low word */
static int put_opt_ts(struct exp *e, uint16_t code, uint64_t ts)
{
	uint32_t w[2] = { (uint32_t)(ts >> 32), (uint32_t)ts };

	return put_opt(e, code, w, 8);
}

static int put_endofopt(struct exp *e)
{
	return put32(e, 0);
}

static uint64_t out_ts(const struct exp *e, uint64_t raw)
{
	return (uint64_t)((int64_t)raw + e->ts_offset);
}

static int write_shb(struct exp *e)
{
	char hw[256], os[160], appl[64], comment[1024], t0[64];
	struct utsname u;
	size_t blen;
	unsigned i, n = 0;
	int k;

	snprintf(hw, sizeof(hw),
		 "Opsero FPGA Packet Recorder (Ethernet FMC Max OP080), target %.32s, capture block 0x%08x v0x%08x, fdrec v0x%08x",
		 e->h.target[0] ? e->h.target : "unknown", e->h.cap_id, e->h.cap_version,
		 e->h.fdrec_version);
	if (uname(&u) == 0)
		snprintf(os, sizeof(os), "%s %s", u.sysname, u.release);
	else
		snprintf(os, sizeof(os), "Linux");
	snprintf(appl, sizeof(appl), "pktrec-export %s", PKTREC_APPS_VERSION);
	pktrec_fmt_time(e->h.start_time_ns, t0, sizeof(t0));
	k = snprintf(comment, sizeof(comment),
		     "Captured on %.64s in %s mode, ports", e->h.hostname[0] ? e->h.hostname : "?",
		     pktrec_mode_name(e->h.mode));
	for (i = 0; i < PKTREC_NUM_PORTS_FILE; i++)
		if (e->ports & (1u << i) && k > 0 && (size_t)k < sizeof(comment))
			k += snprintf(comment + k, sizeof(comment) - k, "%s P%u", n++ ? "," : "", i);
	if (k > 0 && (size_t)k < sizeof(comment))
		k += snprintf(comment + k, sizeof(comment) - k,
			      ", snaplen %u, started %s%s%s", e->h.snaplen, t0,
			      e->o.raw_ts ? "; timestamps are raw timebase values" : "",
			      (e->h.flags & PKTREC_FILE_FLAG_COMPLETE) ? "" :
			      "; capture file NOT finalised (no stop counters)");
	(void)k;

	blen = 24 + opt_len(strlen(hw)) + opt_len(strlen(os)) + opt_len(strlen(appl)) +
	       opt_len(strlen(comment)) + 4 + 4;
	{
		uint32_t b[3] = { BT_SHB, (uint32_t)blen, 0x1A2B3C4D };
		uint16_t ver[2] = { 1, 0 };
		int64_t slen = -1;

		if (put(e, b, 12) || put(e, ver, 4) || put(e, &slen, 8))
			return -1;
	}
	if (put_opt_str(e, OPT_COMMENT, comment) || put_opt_str(e, SHB_HARDWARE, hw) ||
	    put_opt_str(e, SHB_OS, os) || put_opt_str(e, SHB_USERAPPL, appl) ||
	    put_endofopt(e) || put32(e, (uint32_t)blen))
		return -1;
	return 0;
}

static int write_idb(struct exp *e, unsigned port)
{
	char name[8], desc[160];
	uint8_t tsresol = 9, fcslen = 0;
	uint32_t snap = e->h.snaplen ? e->h.snaplen : 65535;
	size_t blen;

	snprintf(name, sizeof(name), "P%u", port);
	snprintf(desc, sizeof(desc),
		 "Ethernet FMC Max port P%u, %s mode, inbound (frames received on P%u)%s",
		 port, pktrec_mode_name(e->h.mode), port,
		 e->h.snaplen ? ", truncated to snaplen" : "");
	blen = 20 + opt_len(strlen(name)) + opt_len(strlen(desc)) + opt_len(1) + opt_len(1) + 4;
	{
		uint32_t b[2] = { BT_IDB, (uint32_t)blen };
		uint16_t lt[2] = { LINKTYPE_ETHERNET, 0 };

		if (put(e, b, 8) || put(e, lt, 4) || put32(e, snap))
			return -1;
	}
	if (put_opt_str(e, IF_NAME, name) || put_opt_str(e, IF_DESCRIPTION, desc) ||
	    put_opt(e, IF_TSRESOL, &tsresol, 1) || put_opt(e, IF_FCSLEN, &fcslen, 1) ||
	    put_endofopt(e) || put32(e, (uint32_t)blen))
		return -1;
	return 0;
}

static int write_epb(struct exp *e, const struct ent *r)
{
	static const uint8_t zero[4];
	uint64_t ts = out_ts(e, r->ts);
	uint32_t flags = EPBF_INBOUND;
	uint32_t pad = ((r->cap_len + 3u) & ~3u) - r->cap_len;
	char comment[96] = "";
	size_t blen;
	uint32_t b[7];

	if (r->cap_len >= 6) {
		if (!memcmp(r->data, "\xff\xff\xff\xff\xff\xff", 6))
			flags |= EPBF_RX_BROADCAST;
		else if (r->data[0] & 1)
			flags |= EPBF_RX_MULTICAST;
		else
			flags |= EPBF_RX_PROMISC;
	}
	if (r->flags & PKTREC_REC_F_BAD)
		flags |= EPBF_CRC_ERROR;
	if (e->o.comments && (r->flags & (PKTREC_REC_F_TS_MAC | PKTREC_REC_F_SFD_MISMATCH)))
		snprintf(comment, sizeof(comment), "pktrec: %s%s%s, seq %u",
			 (r->flags & PKTREC_REC_F_TS_MAC) ? "MAC timestamp" : "SFD timestamp",
			 (r->flags & PKTREC_REC_F_SFD_MISMATCH) ? ", SFD mismatch" : "",
			 (r->flags & PKTREC_REC_F_BAD) ? ", bad frame" : "", r->seq);

	blen = 32 + r->cap_len + pad + opt_len(4) + (comment[0] ? opt_len(strlen(comment)) : 0) + 4;
	b[0] = BT_EPB;
	b[1] = (uint32_t)blen;
	b[2] = (uint32_t)e->ifid[r->port];
	b[3] = (uint32_t)(ts >> 32);
	b[4] = (uint32_t)ts;
	b[5] = r->cap_len;
	b[6] = r->orig_len;
	if (put(e, b, sizeof(b)) || put(e, r->data, r->cap_len) || put(e, zero, pad) ||
	    put_opt(e, EPB_FLAGS, &flags, 4) ||
	    (comment[0] && put_opt_str(e, OPT_COMMENT, comment)) ||
	    put_endofopt(e) || put32(e, (uint32_t)blen))
		return -1;
	return 0;
}

static int write_isb(struct exp *e, unsigned port)
{
	const struct pktrec_file_port *hp = &e->h.port[port];
	const struct port_st *ps = &e->ps[port];
	bool counters = e->h.flags & PKTREC_FILE_FLAG_COMPLETE;
	uint64_t start, end, ts;
	size_t blen;

	if (e->o.raw_ts) {
		start = e->h.start_timebase_ns;
		end = e->h.stop_timebase_ns;
	} else {
		start = e->h.start_time_ns;
		end = e->h.stop_time_ns;
	}
	if (!counters || end < start)
		end = e->have_out ? out_ts(e, e->last_out_ts) : start;
	ts = end;
	blen = 12 + 8 + opt_len(8) * 3 + (counters ? opt_len(8) * 3 : 0) + 4 + 4;
	{
		uint32_t b[5] = { BT_ISB, (uint32_t)blen, (uint32_t)e->ifid[port],
				  (uint32_t)(ts >> 32), (uint32_t)ts };

		if (put(e, b, sizeof(b)))
			return -1;
	}
	if (put_opt_ts(e, ISB_STARTTIME, start) || put_opt_ts(e, ISB_ENDTIME, end))
		return -1;
	if (counters &&
	    (put_opt_u64(e, ISB_IFRECV, hp->rx_good + hp->rx_bad) ||
	     put_opt_u64(e, ISB_IFDROP, hp->dropped) ||
	     put_opt_u64(e, ISB_FILTERACCEPT, hp->records)))
		return -1;
	if (put_opt_u64(e, ISB_USRDELIV, ps->written) || put_endofopt(e) ||
	    put32(e, (uint32_t)blen))
		return -1;
	return 0;
}

/* ------------------------------------------------------------------------ */
/* reorder window: binary min-heap on (ts, arrival)                         */

static bool ent_less(const struct ent *a, const struct ent *b)
{
	return a->ts < b->ts || (a->ts == b->ts && a->arrival < b->arrival);
}

static int heap_push(struct exp *e, const struct ent *n)
{
	size_t i;

	if (e->nheap == e->heap_cap) {
		size_t nc = e->heap_cap ? e->heap_cap * 2 : 1024;
		struct ent *nh = realloc(e->heap, nc * sizeof(*nh));

		if (!nh)
			return -1;
		e->heap = nh;
		e->heap_cap = nc;
	}
	i = e->nheap++;
	while (i) {
		size_t p = (i - 1) / 2;

		if (!ent_less(n, &e->heap[p]))
			break;
		e->heap[i] = e->heap[p];
		i = p;
	}
	e->heap[i] = *n;
	return 0;
}

static struct ent heap_pop(struct exp *e)
{
	struct ent top = e->heap[0], last = e->heap[--e->nheap];
	size_t i = 0, n = e->nheap;

	for (;;) {
		size_t c = 2 * i + 1;

		if (c >= n)
			break;
		if (c + 1 < n && ent_less(&e->heap[c + 1], &e->heap[c]))
			c++;
		if (!ent_less(&e->heap[c], &last))
			break;
		e->heap[i] = e->heap[c];
		i = c;
	}
	if (n)
		e->heap[i] = last;
	return top;
}

static int emit_one(struct exp *e)
{
	struct ent r = heap_pop(e);
	int ret;

	e->held_bytes -= r.cap_len;
	if (e->have_out && r.ts < e->last_out_ts)
		e->late++;
	else
		e->last_out_ts = r.ts;
	e->have_out = true;
	if (r.arrival > e->out_records && r.arrival - e->out_records > e->max_disp)
		e->max_disp = r.arrival - e->out_records;
	ret = write_epb(e, &r);
	e->ps[r.port].written++;
	e->out_records++;
	free(r.data);
	return ret;
}

static int add_record(struct exp *e, const struct pktrec_rec_hdr *h, const uint8_t *data)
{
	struct ent n;
	struct port_st *ps = &e->ps[h->port];

	e->records++;
	ps->records++;
	if (h->flags & PKTREC_REC_F_BAD)
		ps->bad++;
	if (h->flags & PKTREC_REC_F_TRUNC)
		ps->trunc++;
	/* per-port sequence: the port's records arrive in order (one FIFO) */
	if (ps->have_seq && h->seq != (uint16_t)(ps->last_seq + 1)) {
		ps->seq_gaps++;
		ps->seq_missing += (uint16_t)(h->seq - ps->last_seq - 1);
	}
	ps->last_seq = h->seq;
	ps->have_seq = true;
	if (!ps->first_ts)
		ps->first_ts = h->ts_ns;
	ps->last_ts = h->ts_ns;
	if (!e->have_newest || h->ts_ns > e->newest_ts)
		e->newest_ts = h->ts_ns;
	e->have_newest = true;

	if (!(e->o.port_filter & (1u << h->port))) {
		e->filtered++;
		return 0;
	}
	n.ts = h->ts_ns;
	n.arrival = e->arrival++;
	n.cap_len = h->cap_len;
	n.orig_len = h->orig_len;
	n.port = h->port;
	n.flags = h->flags;
	n.seq = h->seq;
	n.data = malloc(h->cap_len ? h->cap_len : 1);
	if (!n.data)
		return -1;
	memcpy(n.data, data, h->cap_len);
	if (heap_push(e, &n)) {
		free(n.data);
		return -1;
	}
	e->held_bytes += h->cap_len;
	if (e->nheap > e->max_held)
		e->max_held = e->nheap;
	while (e->nheap && (e->nheap > e->o.window_records || e->held_bytes > e->o.window_bytes))
		if (emit_one(e))
			return -1;
	return 0;
}

/* ------------------------------------------------------------------------ */
/* record stream parser                                                     */

/* Make at least `need` bytes available at buf[pos] unless the data ends.
 * Returns the bytes available. */
static size_t fill(struct exp *e, size_t need)
{
	size_t avail = e->len - e->pos;

	if (avail >= need || e->eof)
		return avail;
	if (e->pos) {
		memmove(e->buf, e->buf + e->pos, avail);
		e->len = avail;
		e->pos = 0;
	}
	while (e->len < RD_BUF_SIZE && !e->eof && e->len - e->pos < need) {
		size_t want = RD_BUF_SIZE - e->len;
		ssize_t n;

		if (want > e->remain)
			want = (size_t)e->remain;
		if (!want) {
			e->eof = true;
			break;
		}
		n = read(e->in, e->buf + e->len, want);
		if (n < 0 && errno == EINTR) {
			if (g_stop)
				e->eof = true;
			continue;
		}
		if (n < 0) {
			perr("read %s", e->o.input);
			e->eof = true;
			break;
		}
		if (n == 0) {
			e->eof = true;
			break;
		}
		e->len += (size_t)n;
		e->remain -= (uint64_t)n;
	}
	return e->len - e->pos;
}

static bool is_zero16(const uint8_t *p)
{
	static const uint8_t z[16];

	return !memcmp(p, z, 16);
}

static void get_hdr(const uint8_t *p, struct pktrec_rec_hdr *h)
{
	memcpy(h, p, sizeof(*h));
	h->ts_ns = le64toh(h->ts_ns);
	h->cap_len = le16toh(h->cap_len);
	h->orig_len = le16toh(h->orig_len);
	h->seq = le16toh(h->seq);
}

/* Plausibility of a record header (the resynchronisation criteria) */
static bool hdr_ok(const struct exp *e, const struct pktrec_rec_hdr *h, bool strict_ts)
{
	if ((h->flags & PKTREC_REC_MARKER_MASK) != PKTREC_REC_MARKER)
		return false;
	if (h->port >= PKTREC_NUM_PORTS_FILE || !(e->ports & (1u << h->port)))
		return false;
	if (h->orig_len == 0 || h->orig_len > e->o.max_frame || h->cap_len > h->orig_len)
		return false;
	if (e->h.snaplen && h->cap_len > e->h.snaplen)
		return false;
	if (!(h->flags & (PKTREC_REC_F_BAD | PKTREC_REC_F_TRUNC))) {
		/* a good, whole frame: everything but the FCS is stored */
		if ((uint32_t)h->cap_len + 4 != h->orig_len)
			return false;
	} else if ((h->flags & PKTREC_REC_F_TRUNC) && (uint32_t)h->cap_len + 4 >= h->orig_len) {
		return false;
	}
	if (strict_ts && e->have_newest && h->ts_ns + RESYNC_TS_BACK_NS < e->newest_ts)
		return false;
	return true;
}

/* A header at p (avail bytes from p) that is followed by another valid header,
 * zero padding, or exactly the end of the data */
static bool chain_ok(const struct exp *e, const uint8_t *p, size_t avail)
{
	struct pktrec_rec_hdr h, n;
	size_t rl;

	get_hdr(p, &h);
	if (!hdr_ok(e, &h, true))
		return false;
	rl = PKTREC_REC_LEN(h.cap_len);
	if (rl > avail)
		return false;
	if (rl == avail)
		return e->eof;
	if (avail - rl < 16)
		return false;
	if (is_zero16(p + rl))
		return true;
	get_hdr(p + rl, &n);
	return hdr_ok(e, &n, true);
}

static int parse_stream(struct exp *e)
{
	for (;;) {
		size_t avail;
		const uint8_t *p;
		struct pktrec_rec_hdr h;
		size_t rl;

		if (g_stop)
			return -1;
		avail = fill(e, 2 * MAX_REC_LEN);
		if (avail < 16) {
			e->tail_bytes += avail;
			e->pos += avail;
			return 0;
		}
		p = e->buf + e->pos;
		if (is_zero16(p)) {
			if (e->resyncing)
				e->skipped_bytes += 16;
			else
				e->pad_bytes += 16;
			e->pos += 16;
			e->offset += 16;
			continue;
		}
		get_hdr(p, &h);
		if (e->resyncing ? chain_ok(e, p, avail) : hdr_ok(e, &h, false)) {
			rl = PKTREC_REC_LEN(h.cap_len);
			if (rl > avail) {
				/* the data ends inside this record */
				e->tail_bytes += avail;
				e->pos += avail;
				return 0;
			}
			if (e->resyncing && !e->o.quiet)
				err_msg("resynchronised at stream offset %" PRIu64 " after %" PRIu64
					" bytes", e->offset, e->offset - e->resync_start);
			e->resyncing = false;
			if (add_record(e, &h, p + PKTREC_REC_HDR_SIZE)) {
				err_msg("out of memory (reorder window)");
				return -1;
			}
			e->pos += rl;
			e->offset += rl;
			if (ferror(e->out))
				return -1;
			continue;
		}
		if (!e->resyncing) {
			e->resyncing = true;
			e->resyncs++;
			e->resync_start = e->offset;
			if (!e->o.quiet)
				err_msg("invalid record header at stream offset %" PRIu64
					" (file offset %" PRIu64 "): resynchronising",
					e->offset, e->offset + PKTREC_FILE_HEADER_SIZE);
		}
		e->skipped_bytes += 16;
		e->pos += 16;
		e->offset += 16;
	}
}

static void print_summary(struct exp *e)
{
	unsigned i;

	fprintf(stderr, "pktrec-export: %" PRIu64 " records read, %" PRIu64
		" packets written%s%s\n", e->records, e->out_records,
		e->filtered ? " (other ports filtered out)" : "",
		e->o.raw_ts ? ", raw timestamps" : "");
	for (i = 0; i < PKTREC_NUM_PORTS_FILE; i++) {
		struct port_st *ps = &e->ps[i];

		if (!(e->ports & (1u << i)))
			continue;
		fprintf(stderr, "  P%u: %" PRIu64 " records, %" PRIu64 " bad, %" PRIu64
			" truncated, sequence gaps %" PRIu64 " (%" PRIu64 " numbers)",
			i, ps->records, ps->bad, ps->trunc, ps->seq_gaps, ps->seq_missing);
		if (e->h.flags & PKTREC_FILE_FLAG_COMPLETE)
			fprintf(stderr, "; hardware: %" PRIu64 " records, %" PRIu64 " dropped%s",
				e->h.port[i].records, e->h.port[i].dropped,
				e->h.port[i].records != ps->records ? "  ** record count mismatch **" : "");
		fputc('\n', stderr);
	}
	fprintf(stderr, "  reorder window: limit %u records / %" PRIu64 " bytes; largest reorder"
		" distance %" PRIu64 " records; records later than the window: %" PRIu64 "\n",
		e->o.window_records, e->o.window_bytes, e->max_disp, e->late);
	fprintf(stderr, "  padding %" PRIu64 " bytes; resyncs %" PRIu64 " (%" PRIu64
		" bytes skipped); truncated tail %" PRIu64 " bytes\n",
		e->pad_bytes, e->resyncs, e->skipped_bytes, e->tail_bytes);
	if (e->h.ring_drops)
		fprintf(stderr, "  WARNING: the recorder dropped %" PRIu64
			" beats: the record stream has gaps\n", e->h.ring_drops);
	if (!(e->h.flags & PKTREC_FILE_FLAG_COMPLETE))
		fprintf(stderr, "  WARNING: capture not finalised: no stop counters, data read to the end of the file\n");
}

int main(int argc, char **argv)
{
	struct exp ee, *e = &ee;
	struct sigaction sa;
	struct stat st;
	unsigned i;
	int ret = 1, nif = 0;

	memset(e, 0, sizeof(*e));
	e->in = -1;
	if (parse_args(argc, argv, &e->o))
		return 1;

	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = on_signal;
	sigaction(SIGINT, &sa, NULL);
	sigaction(SIGTERM, &sa, NULL);
	signal(SIGPIPE, SIG_IGN);       /* EPIPE: the reader went away */

	if (!strcmp(e->o.input, "-")) {
		e->in = STDIN_FILENO;
	} else {
		e->in = open(e->o.input, O_RDONLY | O_CLOEXEC);
		if (e->in < 0) {
			perr("open %s", e->o.input);
			return 1;
		}
		posix_fadvise(e->in, 0, 0, POSIX_FADV_SEQUENTIAL);
	}
	if (pktrec_read_header(e->in, e->o.input, &e->h))
		goto out;

	e->remain = UINT64_MAX;
	if (e->h.flags & PKTREC_FILE_FLAG_COMPLETE) {
		e->remain = e->h.data_bytes;
		if (e->in != STDIN_FILENO && fstat(e->in, &st) == 0 && S_ISREG(st.st_mode) &&
		    (uint64_t)st.st_size < PKTREC_FILE_HEADER_SIZE + e->h.data_bytes)
			err_msg("warning: %s is shorter than its header says (%" PRIu64 " of %" PRIu64
				" data bytes)", e->o.input,
				(uint64_t)st.st_size - PKTREC_FILE_HEADER_SIZE, e->h.data_bytes);
	}
	e->ports = e->h.port_mask & ((1u << PKTREC_NUM_PORTS_FILE) - 1);
	if (!e->ports)
		e->ports = (1u << PKTREC_NUM_PORTS_FILE) - 1;   /* unknown: allow all */
	if (!e->o.port_filter)
		e->o.port_filter = e->ports;
	if (e->o.port_filter & ~e->ports) {
		err_msg("--port: the capture has ports mask 0x%x", e->ports);
		goto out;
	}
	if (!e->o.raw_ts && !(e->h.flags & PKTREC_FILE_FLAG_TS_WALL))
		e->ts_offset = (int64_t)(e->h.start_time_ns - e->h.start_timebase_ns);

	if (!strcmp(e->o.output, "-")) {
		if (isatty(STDOUT_FILENO) && !e->o.force) {
			err_msg("refusing to write pcapng to a terminal (use -o <file> or --force)");
			goto out;
		}
		e->out = stdout;
	} else {
		e->out = fopen(e->o.output, "wb");
		if (!e->out) {
			perr("open %s", e->o.output);
			goto out;
		}
	}
	setvbuf(e->out, NULL, _IOFBF, 1 << 20);
	e->buf = malloc(RD_BUF_SIZE);
	if (!e->buf) {
		err_msg("out of memory");
		goto out;
	}

	for (i = 0; i < PKTREC_NUM_PORTS_FILE; i++)
		e->ifid[i] = (e->o.port_filter & (1u << i)) ? nif++ : -1;
	if (write_shb(e))
		goto werr;
	for (i = 0; i < PKTREC_NUM_PORTS_FILE; i++)
		if (e->ifid[i] >= 0 && write_idb(e, i))
			goto werr;

	if (parse_stream(e)) {
		if (g_stop)
			err_msg("interrupted");
		else if (ferror(e->out))
			goto werr;
		goto out;
	}
	while (e->nheap)
		if (emit_one(e))
			goto werr;
	if (!e->o.no_isb)
		for (i = 0; i < PKTREC_NUM_PORTS_FILE; i++)
			if (e->ifid[i] >= 0 && write_isb(e, i))
				goto werr;
	if (fflush(e->out) || ferror(e->out))
		goto werr;
	if (e->out != stdout) {
		if (fclose(e->out)) {
			e->out = NULL;
			goto werr;
		}
		e->out = NULL;
	}
	if (!e->o.quiet)
		print_summary(e);
	ret = (e->resyncs || e->late || e->tail_bytes || e->h.ring_drops) ? 2 : 0;
	goto out;
werr:
	if (errno == EPIPE)
		err_msg("output closed by the reader");
	else
		perr("write %s", e->o.output);
	ret = 1;
out:
	while (e->nheap) {
		struct ent r = heap_pop(e);

		free(r.data);
	}
	free(e->heap);
	free(e->buf);
	if (e->out && e->out != stdout)
		fclose(e->out);
	if (e->in > STDIN_FILENO)
		close(e->in);
	return ret;
}
