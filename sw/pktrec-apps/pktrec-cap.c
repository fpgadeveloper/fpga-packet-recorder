// SPDX-License-Identifier: MIT
/*
 * pktrec-cap -- FPGA Packet Recorder: capture control and recording.
 *
 * Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
 *
 *   pktrec-cap [record] [options] <file>   capture to <file>
 *   pktrec-cap stats [--watch S] [--clear] [--json]  capture counters (no capture)
 *   pktrec-cap info [--records N] <file>   print a capture file's header
 *
 * Recording reuses the FPGA Drive Recorder datapath and its zero-copy loop
 * (sw/fdrec-apps/fdrec.c): the AXI DMA fills hugepage buffers, io_uring
 * writes the same buffers to the file with O_DIRECT. The source is the
 * capture block's record stream (PKTREC_CAP_CTRL.SRC_SEL = 1), not the test
 * pattern generator. Start and stop follow the protocol in pktrec_regs.h:
 *
 *   start: SRC_SEL; [timebase := CLOCK_REALTIME]; CLEAR; PORT_EN, SNAPLEN;
 *          FDREC_IOC_START (no TPG); ENABLE
 *   stop:  ENABLE off -> keep writing buffers until STATUS.IDLE -> read
 *          BYTES_OUT and the counters -> FILL on -> keep collecting buffers
 *          until BYTES_OUT bytes are in hand -> FDREC_IOC_STOP -> FILL off;
 *          the file is truncated to header + BYTES_OUT (no fill units).
 *
 * Exit codes: 0 = complete, no frame dropped anywhere;
 *             2 = complete, but frames were dropped (hardware FIFOs) or the
 *                 recorder lost data -- the capture is not lossless;
 *             1 = error.
 */

#define _GNU_SOURCE
#include <ctype.h>
#include <dirent.h>
#include <endian.h>
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <inttypes.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/timex.h>
#include <liburing.h>

#include "fdrec_uapi.h"
#include "pktrec_regs.h"
#include "pktrec_common.h"

#ifndef PKTREC_TARGET
#define PKTREC_TARGET "unknown"
#endif

#ifndef MAP_HUGE_2MB
#define MAP_HUGE_2MB    (21 << 26)
#endif

const char *prog_name = "pktrec-cap";

#define DEF_DEVICE      "/dev/fdrec0"
#define DEF_BUFFERS     32
#define DEF_BUF_SIZE    (8ull << 20)
#define DEF_QD          8
#define DEF_TIMEOUT     10.0    /* s with writes in flight and none completing */
#define IDLE_TIMEOUT    5.0     /* s to wait for STATUS.IDLE at stop */
#define FILL_TIMEOUT    10.0    /* s to collect the tail with FILL on */
#define HDR_SIZE        PKTREC_FILE_HEADER_SIZE
#define UD_POLL         ((uint64_t)-1)
#define ALL_PORTS       ((1u << PKTREC_NUM_PORTS) - 1)
#define TB_STATE_FILE   "/run/pktrec/tb.json"   /* pktrec-tb daemon state */

static volatile sig_atomic_t g_stop;

static void on_signal(int sig)
{
	(void)sig;
	g_stop = 1;
}

/* ------------------------------------------------------------------------ */
/* register access (generic-uio or /dev/mem)                                */

struct regs {
	volatile uint32_t *p;
	size_t size;
	char src[64];
};

static int find_uio(uint64_t base, char *dev, size_t len, size_t *size)
{
	DIR *d = opendir("/sys/class/uio");
	struct dirent *de;
	int found = -1;

	if (!d)
		return -1;
	while ((de = readdir(d))) {
		char path[300], buf[64];
		FILE *f;
		unsigned long long a = 0, s = 0;

		if (strncmp(de->d_name, "uio", 3))
			continue;
		snprintf(path, sizeof(path), "/sys/class/uio/%s/maps/map0/addr", de->d_name);
		f = fopen(path, "r");
		if (!f)
			continue;
		if (fgets(buf, sizeof(buf), f))
			a = strtoull(buf, NULL, 16);
		fclose(f);
		if (a != base)
			continue;
		snprintf(path, sizeof(path), "/sys/class/uio/%s/maps/map0/size", de->d_name);
		f = fopen(path, "r");
		if (f) {
			if (fgets(buf, sizeof(buf), f))
				s = strtoull(buf, NULL, 16);
			fclose(f);
		}
		snprintf(dev, len, "/dev/%.32s", de->d_name);
		*size = s;
		found = 0;
		break;
	}
	closedir(d);
	return found;
}

static int regs_map(struct regs *r, uint64_t base, size_t size, bool devmem, const char *what)
{
	char dev[64];
	size_t usize = 0;
	off_t off = 0;
	void *p;
	int fd;

	if (devmem) {
		snprintf(dev, sizeof(dev), "/dev/mem");
		off = (off_t)base;
	} else if (find_uio(base, dev, sizeof(dev), &usize)) {
		err_msg("no UIO device maps the %s registers at 0x%" PRIx64
			" (generic-uio binding missing from the device tree? try --devmem)",
			what, base);
		return -1;
	} else if (usize && usize < size) {
		size = usize;
	}
	fd = open(dev, O_RDWR | O_SYNC | O_CLOEXEC);
	if (fd < 0) {
		perr("open %s (%s registers)", dev, what);
		return -1;
	}
	p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, off);
	close(fd);
	if (p == MAP_FAILED) {
		perr("mmap %s (%s registers)", dev, what);
		return -1;
	}
	r->p = p;
	r->size = size;
	snprintf(r->src, sizeof(r->src), "%s", dev);
	return 0;
}

static void regs_unmap(struct regs *r)
{
	if (r->p)
		munmap((void *)r->p, r->size);
	r->p = NULL;
}

static inline uint32_t rd(const struct regs *r, uint32_t off)
{
	return r->p[off / 4];
}

static inline void wr(const struct regs *r, uint32_t off, uint32_t v)
{
	r->p[off / 4] = v;
}

/* 64-bit counter: reading _LO latches _HI */
static inline uint64_t rd64(const struct regs *r, uint32_t off_lo)
{
	uint32_t lo = rd(r, off_lo);

	return ((uint64_t)rd(r, off_lo + 4) << 32) | lo;
}

struct hw {
	struct regs cap;
	struct regs eth;        /* optional: link state for the header */
	struct regs m0;         /* optional: TAP/monitor pair mode for the header (M3) */
};

static int hw_open(struct hw *hw, bool devmem, bool need_eth)
{
	uint32_t id;

	memset(hw, 0, sizeof(*hw));
	if (regs_map(&hw->cap, PKTREC_CAP_BASE, PKTREC_CAP_SIZE, devmem, "capture"))
		return -1;
	id = rd(&hw->cap, PKTREC_CAP_ID);
	if (id != PKTREC_CAP_ID_VALUE) {
		err_msg("capture block ID 0x%08x, expected 0x%08x (wrong bitstream?)", id,
			PKTREC_CAP_ID_VALUE);
		regs_unmap(&hw->cap);
		return -1;
	}
	if (need_eth && regs_map(&hw->eth, PKTREC_ETH_BASE, 0x1000, devmem, "eth_ports"))
		fprintf(stderr, "%s: note: link state not recorded\n", prog_name);
	if (need_eth && regs_map(&hw->m0, PKTREC_M0_BASE, PKTREC_M0_SIZE, devmem, "port datapath"))
		fprintf(stderr, "%s: note: pair mode not recorded (monitor assumed)\n", prog_name);
	return 0;
}

static void hw_close(struct hw *hw)
{
	regs_unmap(&hw->cap);
	regs_unmap(&hw->eth);
	regs_unmap(&hw->m0);
}

/* File-header pair_mode (bit p = pair p in TAP mode) from the datapath's
 * PAIR_MODE register (map 1.2, set by pktrec-phy mode); older bitstreams:
 * a pair whose two ports both forward (PATH_CTRL = FWD) counts as TAP. */
static uint32_t pair_mode(const struct hw *hw)
{
	uint32_t pm = 0, v, path;
	unsigned p;

	if (!hw->m0.p || rd(&hw->m0, PKTREC_M0_ID) != PKTREC_M0_ID_VALUE)
		return PKTREC_PAIR_MODE_MONITOR;
	v = rd(&hw->m0, PKTREC_M0_VERSION);
	path = rd(&hw->m0, PKTREC_M0_PATH_CTRL);
	for (p = 0; p < PKTREC_NUM_PORTS / 2; p++) {
		bool tap;

		if (v >= PKTREC_M0_VERSION_1_2)
			tap = ((rd(&hw->m0, PKTREC_M0_PAIR_MODE) >> PKTREC_M0_PAIR_SHIFT(p)) & 3u) ==
			      PKTREC_M0_PAIR_TAP;
		else
			tap = ((path >> PKTREC_M0_PATH_SHIFT(2 * p)) & 3u) == PKTREC_M0_PATH_FWD &&
			      ((path >> PKTREC_M0_PATH_SHIFT(2 * p + 1)) & 3u) == PKTREC_M0_PATH_FWD;
		if (tap)
			pm |= PKTREC_PAIR_MODE_TAP << p;
	}
	return pm;
}

/* Link state of port n from the port shell: speed in Mb/s, 0 = down */
static uint32_t port_speed(const struct hw *hw, unsigned n)
{
	uint32_t st;
	static const uint32_t mbps[4] = { 10, 100, 1000, 0 };

	if (!hw->eth.p)
		return 0;
	st = rd(&hw->eth, PKTREC_ETH_PORT(n) + PKTREC_ETH_P_STATUS);
	if (!(st & PKTREC_ETH_STATUS_LINK_UP))
		return 0;
	return mbps[(st >> PKTREC_ETH_STATUS_SPEED_SHIFT) & 3];
}

struct port_cnt {
	uint64_t frames_rx, frames_bad, frames_drop, bytes_rx, bytes_drop, frames_trunc, records;
	uint32_t fifo_hwm;
};

static void read_port(const struct hw *hw, unsigned n, struct port_cnt *c)
{
	uint32_t b = PKTREC_CAP_PORT(n);

	c->frames_rx = rd64(&hw->cap, b + PKTREC_CAP_P_FRAMES_RX_LO);
	c->frames_bad = rd64(&hw->cap, b + PKTREC_CAP_P_FRAMES_BAD_LO);
	c->frames_drop = rd64(&hw->cap, b + PKTREC_CAP_P_FRAMES_DROP_LO);
	c->bytes_rx = rd64(&hw->cap, b + PKTREC_CAP_P_BYTES_RX_LO);
	c->bytes_drop = rd64(&hw->cap, b + PKTREC_CAP_P_BYTES_DROP_LO);
	c->frames_trunc = rd64(&hw->cap, b + PKTREC_CAP_P_FRAMES_TRUNC_LO);
	c->records = rd64(&hw->cap, b + PKTREC_CAP_P_RECORDS_LO);
	c->fifo_hwm = rd(&hw->cap, b + PKTREC_CAP_P_FIFO_HWM);
}

/* "0,1,3" / "0-3" / "all" -> mask */
static int parse_ports(const char *s, uint32_t *mask)
{
	uint32_t m = 0;
	const char *p = s;

	if (!strcmp(s, "all")) {
		*mask = ALL_PORTS;
		return 0;
	}
	while (*p) {
		char *end;
		long a, b;

		if (*p == 'P' || *p == 'p')
			p++;
		a = strtol(p, &end, 10);
		if (end == p || a < 0 || a >= PKTREC_NUM_PORTS)
			return -1;
		b = a;
		p = end;
		if (*p == '-') {
			p++;
			if (*p == 'P' || *p == 'p')
				p++;
			b = strtol(p, &end, 10);
			if (end == p || b < a || b >= PKTREC_NUM_PORTS)
				return -1;
			p = end;
		}
		for (; a <= b; a++)
			m |= 1u << a;
		if (*p == ',')
			p++;
		else if (*p)
			return -1;
	}
	if (!m)
		return -1;
	*mask = m;
	return 0;
}

static void fmt_rate(double v, const char *unit, char *buf, size_t len)
{
	if (v >= 1e9)
		snprintf(buf, len, "%.2fG%s", v / 1e9, unit);
	else if (v >= 1e6)
		snprintf(buf, len, "%.2fM%s", v / 1e6, unit);
	else if (v >= 1e3)
		snprintf(buf, len, "%.1fk%s", v / 1e3, unit);
	else
		snprintf(buf, len, "%.0f%s", v, unit);
}

/* ------------------------------------------------------------------------ */
/* timebase discipline state (pktrec-tb daemon, /run/pktrec/tb.json)          */

struct tb_disc {
	bool valid;             /* state file read */
	bool fresh;             /* written recently by a live daemon */
	bool locked;
	double interval_s;
	int64_t offset_ns;      /* daemon's last offset */
	uint64_t updated_ns, locked_since_ns;
};

/* Minimal lookup in the flat JSON object pktrec-tb writes ("key": value) */
static const char *json_val(const char *buf, const char *key)
{
	char pat[64];
	const char *p;

	snprintf(pat, sizeof(pat), "\"%s\":", key);
	p = strstr(buf, pat);
	if (!p)
		return NULL;
	p += strlen(pat);
	while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r')
		p++;
	return strncmp(p, "null", 4) ? p : NULL;
}

static bool json_num(const char *buf, const char *key, double *v)
{
	const char *p = json_val(buf, key);
	char *end;

	if (!p)
		return false;
	*v = strtod(p, &end);
	return end != p;
}

static bool json_u64(const char *buf, const char *key, uint64_t *v)
{
	const char *p = json_val(buf, key);
	char *end;

	if (!p || *p == '-')
		return false;
	*v = strtoull(p, &end, 10);
	return end != p;
}

static bool json_true(const char *buf, const char *key)
{
	const char *p = json_val(buf, key);

	return p && !strncmp(p, "true", 4);
}

static void tb_disc_read(struct tb_disc *d, const char *path)
{
	char buf[8192];
	ssize_t n;
	double pid = 0, off = 0;
	uint64_t now = realtime_ns();
	int fd;

	memset(d, 0, sizeof(*d));
	fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0)
		return;
	n = read(fd, buf, sizeof(buf) - 1);
	close(fd);
	if (n <= 0)
		return;
	buf[n] = 0;
	d->valid = true;
	if (!json_num(buf, "interval_s", &d->interval_s) || d->interval_s <= 0)
		d->interval_s = 1.0;
	json_u64(buf, "updated_ns", &d->updated_ns);
	json_u64(buf, "locked_since_ns", &d->locked_since_ns);
	if (json_num(buf, "offset_ns", &off))
		d->offset_ns = (int64_t)off;
	d->locked = json_true(buf, "locked");
	d->fresh = json_true(buf, "running") && d->updated_ns &&
		   (double)now < (double)d->updated_ns + (3 * d->interval_s + 5) * 1e9 &&
		   now + 5000000000ull > d->updated_ns;
	if (d->fresh && json_num(buf, "pid", &pid) && pid > 0 &&
	    kill((pid_t)pid, 0) < 0 && errno == ESRCH)
		d->fresh = false;
}

/* System clock synchronised (adjtimex returns TIME_ERROR while STA_UNSYNC) */
static bool ntp_synced(void)
{
	struct timex tx;
	int st;

	memset(&tx, 0, sizeof(tx));
	st = adjtimex(&tx);
	return st >= 0 && st != TIME_ERROR;
}

/* INC (32.32 ns) relative to the nominal 1e9 / DP_CLK_HZ, in ppb */
static double tb_freq_ppb(const struct regs *cap)
{
	uint64_t inc = ((uint64_t)(rd(cap, PKTREC_CAP_TB_INC_NS) & 0xFF) << 32) |
		       rd(cap, PKTREC_CAP_TB_INC_FRAC);
	double hz = rd(cap, PKTREC_CAP_DP_CLK_HZ);
	double nominal = hz > 0 ? 4294967296.0 * 1e9 / hz : (double)inc;

	return nominal > 0 ? ((double)inc / nominal - 1.0) * 1e9 : 0;
}

/* timebase - CLOCK_REALTIME: the read pair with the shortest latency of 7 */
static int64_t tb_offset(const struct regs *cap, uint64_t *when)
{
	int64_t best_off = 0;
	uint64_t best_lat = UINT64_MAX;
	unsigned i;

	for (i = 0; i < 7; i++) {
		uint64_t t1 = realtime_ns();
		uint64_t tb = rd64(cap, PKTREC_CAP_TB_NOW_LO);
		uint64_t t2 = realtime_ns();

		if (t2 - t1 < best_lat) {
			best_lat = t2 - t1;
			best_off = (int64_t)(tb - (t1 + best_lat / 2));
			*when = t2;
		}
	}
	return best_off;
}

/* ------------------------------------------------------------------------ */
/* record                                                                    */

struct opts {
	const char *device;
	const char *output;
	const char *target;
	const char *design;
	const char *stop_file;
	uint32_t ports;
	uint32_t snaplen;
	uint64_t size;
	double duration;
	unsigned buffers;
	uint64_t buf_size;
	unsigned qd;
	double stats;
	double timeout;
	bool tb_set;
	bool devmem;
	bool quiet;
	int stats_json_fd;      /* --stats-json[=fd]: -1 = off */
	const char *tb_state;   /* pktrec-tb state file */
};

enum phase { RUN, DISABLING, FILLING, STOPPED };

struct rec {
	struct opts o;
	struct hw hw;
	int dev;
	int out;
	struct fdrec_info info;
	uint8_t *mem;
	size_t mem_len;
	struct io_uring ring;
	bool fixed;
	struct pktrec_file_header *hdr;
	FILE *sj;               /* --stats-json stream */
	struct tb_disc tbd;

	enum phase phase;
	unsigned inflight;
	bool poll_armed;
	bool dev_hup;
	bool fdrec_stopped;
	int error;
	uint32_t stop_flags;    /* PKTREC_FILE_FLAG_LIMIT_* */

	uint64_t bytes_filled;  /* bytes the DMA delivered to us (incl. fill) */
	uint64_t bytes_submitted;
	uint64_t bytes_written;
	uint64_t bytes_out;     /* BYTES_OUT at stop: valid stream bytes */
	uint64_t records_out;
	uint64_t next_fill_seq;
	uint64_t last_drop;
	struct fdrec_stats final;
	struct port_cnt pc[PKTREC_NUM_PORTS];

	double t0, t_last, t_phase, t_write;
	uint64_t bytes_last;
	struct port_cnt pc_last[PKTREC_NUM_PORTS];
	uint64_t bp_last;
	/* BP_CYCLES when the stream ended (snapshot_counters): the fill phase after
	 * it makes the counter run on with no traffic, so later stats use this */
	uint64_t bp_stop;
	double t_bp_stop;
	bool have_bp_stop;
	unsigned max_inflight;
};

static void set_error(struct rec *r, int err)
{
	if (!r->error)
		r->error = err;
}

static void usage_record(FILE *f)
{
	fprintf(f,
"Usage: pktrec-cap [record] [options] <output-file>\n"
"       pktrec-cap stats [--watch <sec>] [--clear] [--json] [--devmem]\n"
"       pktrec-cap info [--records <n>] <capture-file>\n"
"\n"
"Capture the Ethernet FMC Max ports (monitor mode) to <output-file>: a 4 KB\n"
"header with the capture metadata followed by the record stream (see\n"
"include/pktrec_format.h). Convert it with pktrec-export.\n"
"\n"
"Capture options:\n"
"  --ports <list>        ports to capture: 0,1,2,3 / 0-3 / all (default all)\n"
"  --snaplen <bytes>     store at most this many bytes per frame, FCS excluded\n"
"                        (0 = whole frames, default)\n"
"  --duration <sec>      stop after this many seconds\n"
"  --size <bytes>        stop once this much has been written (suffixes K/M/G/T;\n"
"                        the capture ends at the next buffer boundary)\n"
"  --stop-file <path>    stop when this file appears (it is removed)\n"
"  --no-tb-set           leave the hardware timebase alone (default: set it to\n"
"                        CLOCK_REALTIME before the start, so timestamps are UTC,\n"
"                        unless the pktrec-tb daemon has it locked to\n"
"                        CLOCK_REALTIME already: then it is never stepped)\n"
"  --stats <sec>         live statistics interval, 0 = off (default 1)\n"
"  --stats-json[=<fd>]   also write each statistics interval as one JSON object\n"
"                        per line to stdout or file descriptor <fd>, and a final\n"
"                        {\"type\":\"result\",...} line (independent of -q)\n"
"  --tb-state <path>     pktrec-tb daemon state (default " TB_STATE_FILE ")\n"
"  --buffers <n>         ring buffers (default %d)\n"
"  --buf-size <bytes>    buffer size, multiple of 2 MB (default 8M)\n"
"  --qd <n>              io_uring writes in flight (default %d)\n"
"  --timeout <sec>       abort when writes are in flight and none completes for\n"
"                        this long (SSD stall; default %.0f). An idle network is\n"
"                        not a stall.\n"
"  --device <path>       recorder device (default %s)\n"
"  --target <name>       target name for the header (default %s)\n"
"  --design <string>     design version string for the header\n"
"  --devmem              map registers through /dev/mem instead of generic-uio\n"
"  -q, --quiet           no live statistics\n"
"  -h, --help            this help\n"
"\n"
"Stops on --duration, --size, --stop-file, Ctrl-C or SIGTERM; every frame that\n"
"started before the stop is in the file.\n"
"\n"
"Exit code: 0 = complete and lossless, 2 = complete but frames were dropped\n"
"(per-port FIFO overflow) or the recorder lost data, 1 = error.\n",
		DEF_BUFFERS, DEF_QD, DEF_TIMEOUT, DEF_DEVICE, PKTREC_TARGET);
}

static int parse_record_args(int argc, char **argv, struct opts *o)
{
	static const struct option lo[] = {
		{ "ports", required_argument, NULL, 'p' },
		{ "snaplen", required_argument, NULL, 'n' },
		{ "duration", required_argument, NULL, 'd' },
		{ "size", required_argument, NULL, 's' },
		{ "stop-file", required_argument, NULL, 'F' },
		{ "no-tb-set", no_argument, NULL, 'T' },
		{ "stats", required_argument, NULL, 'S' },
		{ "stats-json", optional_argument, NULL, 'J' },
		{ "tb-state", required_argument, NULL, 'X' },
		{ "buffers", required_argument, NULL, 'b' },
		{ "buf-size", required_argument, NULL, 'B' },
		{ "qd", required_argument, NULL, 'Q' },
		{ "timeout", required_argument, NULL, 't' },
		{ "device", required_argument, NULL, 'D' },
		{ "target", required_argument, NULL, 'g' },
		{ "design", required_argument, NULL, 'G' },
		{ "devmem", no_argument, NULL, 'M' },
		{ "quiet", no_argument, NULL, 'q' },
		{ "help", no_argument, NULL, 'h' },
		{ NULL, 0, NULL, 0 },
	};
	int c;
	uint64_t v;

	memset(o, 0, sizeof(*o));
	o->device = DEF_DEVICE;
	o->target = PKTREC_TARGET;
	o->design = "";
	o->ports = ALL_PORTS;
	o->buffers = DEF_BUFFERS;
	o->buf_size = DEF_BUF_SIZE;
	o->qd = DEF_QD;
	o->stats = 1.0;
	o->timeout = DEF_TIMEOUT;
	o->tb_set = true;
	o->stats_json_fd = -1;
	o->tb_state = TB_STATE_FILE;

	while ((c = getopt_long(argc, argv, "qh", lo, NULL)) != -1) {
		switch (c) {
		case 'p':
			if (parse_ports(optarg, &o->ports))
				return die_usage("invalid --ports '%s' (e.g. 0,1 or 0-3 or all)", optarg);
			break;
		case 'n':
			if (parse_size(optarg, &v) || v > 0xFFFF)
				return die_usage("--snaplen must be 0..65535");
			o->snaplen = (uint32_t)v;
			break;
		case 'd':
			if (parse_double(optarg, &o->duration) || o->duration <= 0)
				return die_usage("invalid --duration '%s'", optarg);
			break;
		case 's':
			if (parse_size(optarg, &o->size) || !o->size)
				return die_usage("invalid --size '%s'", optarg);
			break;
		case 'F':
			o->stop_file = optarg;
			break;
		case 'T':
			o->tb_set = false;
			break;
		case 'S':
			if (parse_double(optarg, &o->stats) || o->stats < 0)
				return die_usage("invalid --stats '%s'", optarg);
			break;
		case 'J':
			if (!optarg) {
				o->stats_json_fd = 1;
			} else {
				char *end;
				long fd = strtol(optarg, &end, 10);

				if (*end || end == optarg || fd < 1 || fd > 1023 ||
				    fcntl((int)fd, F_GETFD) < 0)
					return die_usage("--stats-json=<fd>: '%s' is not an open file descriptor",
							 optarg);
				o->stats_json_fd = (int)fd;
			}
			break;
		case 'X':
			o->tb_state = optarg;
			break;
		case 'b':
			if (parse_size(optarg, &v) || v < 2 || v > FDREC_MAX_BUFS)
				return die_usage("--buffers must be 2..%d", FDREC_MAX_BUFS);
			o->buffers = (unsigned)v;
			break;
		case 'B':
			if (parse_size(optarg, &o->buf_size) || !o->buf_size ||
			    o->buf_size % FDREC_BUF_ALIGN || o->buf_size > FDREC_MAX_BUF_SIZE)
				return die_usage("--buf-size must be a non-zero multiple of 2 MB, at most 62 MB");
			break;
		case 'Q':
			if (parse_size(optarg, &v) || v < 1 || v > 256)
				return die_usage("--qd must be 1..256");
			o->qd = (unsigned)v;
			break;
		case 't':
			if (parse_double(optarg, &o->timeout) || o->timeout <= 0)
				return die_usage("invalid --timeout '%s'", optarg);
			break;
		case 'D':
			o->device = optarg;
			break;
		case 'g':
			o->target = optarg;
			break;
		case 'G':
			o->design = optarg;
			break;
		case 'M':
			o->devmem = true;
			break;
		case 'q':
			o->quiet = true;
			break;
		case 'h':
			usage_record(stdout);
			exit(0);
		default:
			usage_record(stderr);
			return -1;
		}
	}
	if (optind != argc - 1)
		return die_usage("exactly one <output-file> is required");
	o->output = argv[optind];
	if (o->qd > o->buffers)
		o->qd = o->buffers;
	return 0;
}

static int arm_poll(struct rec *r)
{
	struct io_uring_sqe *sqe;

	if (r->poll_armed || r->dev_hup)
		return 0;
	sqe = io_uring_get_sqe(&r->ring);
	if (!sqe)
		return -EBUSY;
	io_uring_prep_poll_add(sqe, r->dev, POLLIN);
	io_uring_sqe_set_data64(sqe, UD_POLL);
	r->poll_armed = true;
	return 0;
}

static void release_buf(struct rec *r, unsigned idx)
{
	struct fdrec_release rel = { .index = idx };

	if (ioctl(r->dev, FDREC_IOC_RELEASE, &rel) < 0) {
		perr("FDREC_IOC_RELEASE");
		set_error(r, -errno);
	}
}

/* How many stream bytes are still wanted from the DMA (UINT64_MAX while the
 * capture runs; after the stop counters are read, up to BYTES_OUT). */
static uint64_t bytes_wanted(const struct rec *r)
{
	if (r->phase == RUN || r->phase == DISABLING)
		return UINT64_MAX;
	if (r->phase == STOPPED)
		return 0;
	return r->bytes_out > r->bytes_filled ? r->bytes_out - r->bytes_filled : 0;
}

/* Take every filled buffer we can submit a write for (non-blocking) */
static void take_filled(struct rec *r)
{
	while (r->phase != STOPPED && bytes_wanted(r) && r->inflight < r->o.qd) {
		struct fdrec_filled f = { .timeout_ms = 0 };
		struct io_uring_sqe *sqe;
		uint64_t len, want;
		uint8_t *buf;

		if (ioctl(r->dev, FDREC_IOC_WAIT_FILLED, &f) < 0) {
			if (errno == ETIMEDOUT || errno == EINTR)
				return;
			if (errno == ENODATA) {
				r->dev_hup = true;
				return;
			}
			if (errno == EIO)
				err_msg("DMA error reported for buffer %u (fill #%" PRIu64 ")",
					f.index, (uint64_t)f.seq);
			else
				perr("FDREC_IOC_WAIT_FILLED");
			set_error(r, -errno);
			r->stop_flags |= PKTREC_FILE_FLAG_DMA_ERROR;
			g_stop = 1;
			return;
		}
		if (f.seq != r->next_fill_seq) {
			err_msg("buffer fill sequence jumped from %" PRIu64 " to %" PRIu64,
				r->next_fill_seq, (uint64_t)f.seq);
			set_error(r, -EPROTO);
		}
		r->next_fill_seq = f.seq + 1;
		if (f.flags & FDREC_FILLED_SHORT) {
			err_msg("buffer %u holds %" PRIu64 " of %" PRIu64 " bytes (TLAST early?)",
				f.index, (uint64_t)f.bytes, r->o.buf_size);
			set_error(r, -EPROTO);
		}
		r->last_drop = f.drop_count;
		want = bytes_wanted(r);
		len = f.bytes;
		r->bytes_filled += f.bytes;
		if (len > want) {
			/* the last buffer of the capture: the rest is fill. Write
			 * whole 4 KB blocks (O_DIRECT); ftruncate trims the file. */
			len = (want + 4095) & ~4095ull;
		}
		buf = r->mem + (size_t)f.index * r->o.buf_size;
		sqe = io_uring_get_sqe(&r->ring);
		if (!sqe) {
			io_uring_submit(&r->ring);
			sqe = io_uring_get_sqe(&r->ring);
		}
		if (!sqe) {
			err_msg("io_uring submission queue full");
			set_error(r, -EBUSY);
			release_buf(r, f.index);
			g_stop = 1;
			return;
		}
		if (r->fixed)
			io_uring_prep_write_fixed(sqe, r->out, buf, (unsigned)len,
						  HDR_SIZE + r->bytes_submitted, (int)f.index);
		else
			io_uring_prep_write(sqe, r->out, buf, (unsigned)len,
					    HDR_SIZE + r->bytes_submitted);
		io_uring_sqe_set_data64(sqe, ((uint64_t)f.index << 32) | (uint32_t)len);
		r->bytes_submitted += len;
		/* the stall watchdog measures from the last completion OR, when the
		 * ring was idle, from the first new submission */
		if (r->inflight++ == 0)
			r->t_write = now_s();
		if (r->inflight > r->max_inflight)
			r->max_inflight = r->inflight;
	}
}

static void handle_cqe(struct rec *r, struct io_uring_cqe *cqe)
{
	uint64_t ud = io_uring_cqe_get_data64(cqe);
	unsigned idx, len;

	if (ud == UD_POLL) {
		r->poll_armed = false;
		if (cqe->res < 0 && cqe->res != -ECANCELED) {
			errno = -cqe->res;
			perr("poll on the recorder device");
			set_error(r, cqe->res);
			g_stop = 1;
		} else if (cqe->res > 0 && (cqe->res & (POLLHUP | POLLERR)) &&
			   !(cqe->res & POLLIN)) {
			r->dev_hup = true;
		}
		return;
	}
	idx = (unsigned)(ud >> 32);
	len = (unsigned)(ud & 0xffffffffu);
	r->inflight--;
	if (cqe->res != (int)len) {
		if (cqe->res < 0) {
			errno = -cqe->res;
			perr("write to %s", r->o.output);
			set_error(r, cqe->res);
		} else {
			err_msg("short write to %s (%d of %u bytes)", r->o.output, cqe->res, len);
			set_error(r, -EIO);
		}
		r->stop_flags |= PKTREC_FILE_FLAG_DMA_ERROR;
		g_stop = 1;
	} else {
		r->bytes_written += len;
	}
	r->t_write = now_s();
	release_buf(r, idx);
}

static void print_stats(struct rec *r, bool final)
{
	struct fdrec_stats st;
	double now = now_s(), el = now - r->t0, dt = now - r->t_last;
	char line[512], jports[1024];
	int k, jk = 0;
	unsigned i;
	uint64_t drops = 0, bp;
	double dp_hz = rd(&r->hw.cap, PKTREC_CAP_DP_CLK_HZ), bp_dt = dt, bp_pct;

	if (ioctl(r->dev, FDREC_IOC_GET_STATS, &st) < 0)
		memset(&st, 0, sizeof(st));
	bp = rd64(&r->hw.cap, PKTREC_CAP_BP_CYCLES_LO);
	if (r->have_bp_stop) {
		/* after the stream ended: back-pressure up to the end of the stream only
		 * (the fill beats of the stop sequence wait for the recorder too, which
		 * showed as 'bp 56-63 %' on the final line with no traffic) */
		bp = r->bp_stop;
		bp_dt = r->t_bp_stop - r->t_last;
	}
	bp_pct = bp_dt > 0 && dp_hz > 0 && bp >= r->bp_last ?
		 100.0 * (double)(bp - r->bp_last) / (bp_dt * dp_hz) : 0.0;
	if (bp_pct > 100.0)
		bp_pct = 100.0;
	k = snprintf(line, sizeof(line), "%7.1fs %7.1f MB/s %9.3f GB ring %2u/%u bp %4.1f%%",
		     el, dt > 0 ? (r->bytes_written - r->bytes_last) / dt / 1e6 : 0,
		     r->bytes_written / 1e9, st.bufs_ready + st.bufs_user,
		     r->o.buffers, bp_pct);
	for (i = 0; i < PKTREC_NUM_PORTS; i++) {
		struct port_cnt c;
		char fps[16], bps[16];

		if (!(r->o.ports & (1u << i)))
			continue;
		read_port(&r->hw, i, &c);
		fmt_rate(dt > 0 ? (c.frames_rx - r->pc_last[i].frames_rx) / dt : 0, "", fps,
			 sizeof(fps));
		fmt_rate(dt > 0 ? (c.bytes_rx - r->pc_last[i].bytes_rx) * 8.0 / dt : 0, "b",
			 bps, sizeof(bps));
		if (k > 0 && (size_t)k < sizeof(line))
			k += snprintf(line + k, sizeof(line) - k, " | P%u %s/s %s/s d%" PRIu64,
				      i, fps, bps, c.frames_drop);
		if (r->sj)
			jk += snprintf(jports + jk, sizeof(jports) - jk,
				       "%s\"%u\":{\"frames_s\":%.1f,\"bits_s\":%.1f,\"drops\":%" PRIu64
				       ",\"frames_rx\":%" PRIu64 ",\"bytes_rx\":%" PRIu64
				       ",\"fifo_hwm\":%u}", jk ? "," : "", i,
				       dt > 0 ? (c.frames_rx - r->pc_last[i].frames_rx) / dt : 0.0,
				       dt > 0 ? (c.bytes_rx - r->pc_last[i].bytes_rx) * 8.0 / dt : 0.0,
				       c.frames_drop, c.frames_rx, c.bytes_rx, c.fifo_hwm);
		drops += c.frames_drop;
		r->pc_last[i] = c;
	}
	if (!r->o.quiet) {
		fprintf(stderr, "%s%s%s", isatty(2) ? "\r" : "", line,
			(isatty(2) && !final) ? "\033[K" : "\n");
		fflush(stderr);
	}
	if (r->sj) {
		/* the same fields as the text line, one object per interval */
		fprintf(r->sj, "{\"type\":\"stats\",\"final\":%s,\"elapsed_s\":%.3f,"
			"\"write_mb_s\":%.3f,\"written_bytes\":%" PRIu64 ",\"written_gb\":%.6f,"
			"\"ring_used\":%u,\"ring_total\":%u,\"backpressure_pct\":%.2f,"
			"\"drops\":%" PRIu64 ",\"ports\":{%s}}\n", final ? "true" : "false", el,
			dt > 0 ? (r->bytes_written - r->bytes_last) / dt / 1e6 : 0.0,
			r->bytes_written, r->bytes_written / 1e9, st.bufs_ready + st.bufs_user,
			r->o.buffers, bp_pct, drops, jports);
		fflush(r->sj);
	}
	r->t_last = now;
	r->bytes_last = r->bytes_written;
	r->bp_last = bp;
}

static int alloc_buffers(struct rec *r)
{
	r->mem_len = (size_t)r->o.buffers * r->o.buf_size;
	r->mem = mmap(NULL, r->mem_len, PROT_READ | PROT_WRITE,
		      MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB | MAP_HUGE_2MB | MAP_POPULATE,
		      -1, 0);
	if (r->mem == MAP_FAILED) {
		int e = errno;

		r->mem = NULL;
		err_msg("cannot allocate %u x %" PRIu64 " MB from 2 MB hugepages: %s",
			r->o.buffers, r->o.buf_size >> 20, strerror(e));
		err_msg("need %zu free hugepages, %lu free; raise with: echo <N> > /proc/sys/vm/nr_hugepages",
			r->mem_len / FDREC_BUF_ALIGN, hugepages_free());
		return -e;
	}
	return 0;
}

static int write_header(struct rec *r)
{
	struct pktrec_file_header *le;
	ssize_t n;
	int ret = 0;

	if (posix_memalign((void **)&le, 4096, HDR_SIZE))
		return -ENOMEM;
	memcpy(le, r->hdr, HDR_SIZE);
	pktrec_hdr_swap(le);            /* host -> little-endian */
	n = pwrite(r->out, le, HDR_SIZE, 0);
	if (n != HDR_SIZE) {
		perr("write header to %s", r->o.output);
		ret = n < 0 ? -errno : -EIO;
	}
	free(le);
	return ret;
}

static void cap_ctrl(struct rec *r, uint32_t v)
{
	wr(&r->hw.cap, PKTREC_CAP_CTRL, v);
}

/* Read the counters into r->pc / the header once the hardware is idle */
static void snapshot_counters(struct rec *r)
{
	unsigned i;

	r->bytes_out = rd64(&r->hw.cap, PKTREC_CAP_BYTES_OUT_LO);
	r->records_out = rd64(&r->hw.cap, PKTREC_CAP_RECORDS_OUT_LO);
	for (i = 0; i < PKTREC_NUM_PORTS; i++)
		read_port(&r->hw, i, &r->pc[i]);
	r->hdr->tb_stop_ns = rd64(&r->hw.cap, PKTREC_CAP_TB_NOW_LO);
	r->hdr->stop_time_ns = realtime_ns();
	r->bp_stop = rd64(&r->hw.cap, PKTREC_CAP_BP_CYCLES_LO);
	r->t_bp_stop = now_s();
	r->have_bp_stop = true;
}

/*
 * Set the timebase to CLOCK_REALTIME. Register map 1.1: SET applies on the next
 * dp_clk cycle and the MAC clock domains follow at once (cycle-count copies, no
 * lock); TB_STATUS only says which MAC clock domains are out of reset, so a
 * port without link is reported, not treated as an error.
 */
static int tb_set_realtime(struct rec *r)
{
	uint64_t t = realtime_ns();
	uint32_t st;

	wr(&r->hw.cap, PKTREC_CAP_TB_SET_LO, (uint32_t)t);
	wr(&r->hw.cap, PKTREC_CAP_TB_SET_HI, (uint32_t)(t >> 32));
	wr(&r->hw.cap, PKTREC_CAP_TB_CTRL, PKTREC_CAP_TB_CTRL_SET);
	st = rd(&r->hw.cap, PKTREC_CAP_TB_STATUS);
	if ((st & r->o.ports) != r->o.ports)
		fprintf(stderr, "pktrec-cap: note: RX clock domain of port(s) 0x%x in reset (no link?), TB_STATUS 0x%02x\n",
			r->o.ports & ~st & 0xF, st);
	return 0;
}

static int cmd_record(int argc, char **argv)
{
	struct rec rr, *r = &rr;
	struct fdrec_bufs reg;
	struct fdrec_start start;
	struct sigaction sa;
	uint64_t *addrs = NULL;
	struct iovec *iov = NULL;
	double next_stats, deadline = 0;
	uint64_t drops = 0;
	double res_el = 0;
	uint32_t res_fixups = 0;
	int ret = 1, e;
	unsigned i;

	memset(r, 0, sizeof(*r));
	r->dev = r->out = -1;
	if (parse_record_args(argc, argv, &r->o))
		return 1;
	if (r->o.stats_json_fd == 1) {
		r->sj = stdout;
	} else if (r->o.stats_json_fd == 2) {
		r->sj = stderr;
	} else if (r->o.stats_json_fd > 2) {
		r->sj = fdopen(r->o.stats_json_fd, "w");
		if (!r->sj) {
			perr("--stats-json=%d", r->o.stats_json_fd);
			return 1;
		}
	}
	if (r->o.size % 4096)
		r->o.size = (r->o.size + 4095) & ~4095ull;

	if (hw_open(&r->hw, r->o.devmem, true))
		return 1;
	/* The recorder device is exclusive: holding it means no other capture
	 * (or fdrec/fdplay) runs, so an ENABLE left set is a killed capture's. */
	r->dev = open(r->o.device, O_RDWR | O_CLOEXEC);
	if (r->dev < 0) {
		perr("open %s (is the fdrec module loaded? is another capture running?)",
		     r->o.device);
		goto out;
	}
	if (rd(&r->hw.cap, PKTREC_CAP_CTRL) & (PKTREC_CAP_CTRL_ENABLE | PKTREC_CAP_CTRL_FILL)) {
		fprintf(stderr, "pktrec-cap: note: a previous capture did not stop cleanly "
			"(CTRL 0x%08x); resetting the capture block\n", rd(&r->hw.cap, PKTREC_CAP_CTRL));
		cap_ctrl(r, PKTREC_CAP_CTRL_SRC_SEL);
	}
	if (ioctl(r->dev, FDREC_IOC_GET_INFO, &r->info) < 0) {
		perr("FDREC_IOC_GET_INFO");
		goto out;
	}
	if (r->info.api_version != FDREC_API_VERSION) {
		err_msg("driver API version %u, this pktrec-cap expects %u",
			r->info.api_version, FDREC_API_VERSION);
		goto out;
	}

	if (alloc_buffers(r))
		goto out;
	addrs = calloc(r->o.buffers, sizeof(*addrs));
	iov = calloc(r->o.buffers, sizeof(*iov));
	if (!addrs || !iov) {
		err_msg("out of memory");
		goto out;
	}
	for (i = 0; i < r->o.buffers; i++) {
		addrs[i] = (uintptr_t)(r->mem + (size_t)i * r->o.buf_size);
		iov[i].iov_base = r->mem + (size_t)i * r->o.buf_size;
		iov[i].iov_len = r->o.buf_size;
	}
	memset(&reg, 0, sizeof(reg));
	reg.addrs = (uintptr_t)addrs;
	reg.buf_size = r->o.buf_size;
	reg.count = r->o.buffers;
	reg.flags = FDREC_DIR_RECORD;
	if (ioctl(r->dev, FDREC_IOC_REGISTER_BUFS, &reg) < 0) {
		perr("FDREC_IOC_REGISTER_BUFS (%u x %" PRIu64 " MB)", r->o.buffers,
		     r->o.buf_size >> 20);
		goto out;
	}

	r->out = open(r->o.output, O_CREAT | O_WRONLY | O_TRUNC | O_DIRECT | O_CLOEXEC, 0644);
	if (r->out < 0) {
		perr("open %s with O_DIRECT", r->o.output);
		goto out;
	}
	if (posix_memalign((void **)&r->hdr, 4096, HDR_SIZE)) {
		err_msg("out of memory");
		goto out;
	}
	memset(r->hdr, 0, HDR_SIZE);
	memcpy(r->hdr->magic, PKTREC_FILE_MAGIC, PKTREC_FILE_MAGIC_LEN);
	r->hdr->header_version = PKTREC_FILE_HEADER_VERSION;
	r->hdr->header_size = HDR_SIZE;
	r->hdr->record_format = PKTREC_REC_FORMAT_VERSION;
	r->hdr->cap_version = rd(&r->hw.cap, PKTREC_CAP_VERSION);
	r->hdr->fdrec_version = r->info.hw_version;
	r->hdr->num_ports = PKTREC_NUM_PORTS;
	r->hdr->port_mask = r->o.ports;
	r->hdr->pair_mode = pair_mode(&r->hw);   /* from PAIR_MODE (pktrec-phy mode) */
	r->hdr->snaplen = r->o.snaplen;
	strncpy(r->hdr->target, r->o.target, sizeof(r->hdr->target) - 1);
	gethostname(r->hdr->hostname, sizeof(r->hdr->hostname) - 1);
	strncpy(r->hdr->design, r->o.design, sizeof(r->hdr->design) - 1);
	for (i = 0; i < PKTREC_NUM_PORTS; i++) {
		struct pktrec_file_port *p = &r->hdr->port[i];

		snprintf(p->if_name, sizeof(p->if_name), "P%u", i);
		p->speed_mbps = port_speed(&r->hw, i);
		p->flags = ((r->o.ports & (1u << i)) ? PKTREC_FPORT_ENABLED : 0) |
			   (p->speed_mbps ? PKTREC_FPORT_LINK_UP : 0);
		if ((r->o.ports & (1u << i)) && r->hw.eth.p && !p->speed_mbps)
			fprintf(stderr, "pktrec-cap: note: P%u link is down\n", i);
	}

	if (io_uring_queue_init(r->o.qd + 2, &r->ring, 0) < 0) {
		err_msg("io_uring_queue_init failed (CONFIG_IO_URING?)");
		goto out;
	}
	r->fixed = io_uring_register_buffers(&r->ring, iov, r->o.buffers) == 0;

	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = on_signal;
	sigaction(SIGINT, &sa, NULL);
	sigaction(SIGTERM, &sa, NULL);

	/* ---- start protocol (pktrec_regs.h) ---- */
	cap_ctrl(r, PKTREC_CAP_CTRL_SRC_SEL);
	tb_disc_read(&r->tbd, r->o.tb_state);
	if (r->tbd.fresh && r->tbd.locked) {
		/* pktrec-tb keeps the timebase on CLOCK_REALTIME: never step it */
		r->hdr->flags |= PKTREC_FILE_FLAG_TB_REALTIME;
	} else if (r->o.tb_set) {
		if (tb_set_realtime(r))
			goto out_idle;
		r->hdr->flags |= PKTREC_FILE_FLAG_TB_REALTIME;
		r->hdr->tb_disc_flags |= PKTREC_TBD_SET_AT_START;
	}
	cap_ctrl(r, PKTREC_CAP_CTRL_SRC_SEL | PKTREC_CAP_CTRL_CLEAR);
	wr(&r->hw.cap, PKTREC_CAP_PORT_EN, r->o.ports);
	wr(&r->hw.cap, PKTREC_CAP_SNAPLEN, r->o.snaplen);
	for (i = 0; i < PKTREC_NUM_PORTS; i++)
		wr(&r->hw.cap, PKTREC_CAP_PORT(i) + PKTREC_CAP_P_FIFO_HWM, 0);
	r->hdr->tb_inc = ((uint64_t)(rd(&r->hw.cap, PKTREC_CAP_TB_INC_NS) & 0xFF) << 32) |
			 rd(&r->hw.cap, PKTREC_CAP_TB_INC_FRAC);
	{
		/* timebase discipline state at start (header tb_disc_*) */
		uint64_t when = 0;
		double ppb = tb_freq_ppb(&r->hw.cap);
		struct pktrec_file_header *h = r->hdr;

		h->tb_disc_offset_ns = tb_offset(&r->hw.cap, &when);
		h->tb_disc_time_ns = when;
		h->tb_disc_freq_ppb = (int64_t)(ppb + (ppb < 0 ? -0.5 : 0.5));
		h->tb_disc_flags |= PKTREC_TBD_VALID |
				    (r->tbd.fresh ? PKTREC_TBD_DAEMON : 0) |
				    (r->tbd.fresh && r->tbd.locked ? PKTREC_TBD_LOCKED : 0) |
				    (ntp_synced() ? PKTREC_TBD_NTP_SYNC : 0);
		if ((h->tb_disc_flags & PKTREC_TBD_LOCKED) && r->tbd.locked_since_ns &&
		    when > r->tbd.locked_since_ns)
			h->tb_disc_locked_s = (uint32_t)((when - r->tbd.locked_since_ns) / 1000000000ull);
		if (!r->o.quiet)
			fprintf(stderr, "pktrec-cap: timebase %s, offset %+.3f us vs CLOCK_REALTIME, "
				"trim %+.3f ppm%s\n",
				(h->tb_disc_flags & PKTREC_TBD_LOCKED) ? "disciplined by pktrec-tb (locked)" :
				(h->tb_disc_flags & PKTREC_TBD_SET_AT_START) ?
				(r->tbd.fresh ? "set from CLOCK_REALTIME (pktrec-tb not locked yet)" :
				 "set from CLOCK_REALTIME (pktrec-tb not running)") :
				"left as is (--no-tb-set)",
				(double)h->tb_disc_offset_ns / 1e3, ppb / 1e3,
				(h->tb_disc_flags & PKTREC_TBD_NTP_SYNC) ? "" : ", system clock NOT NTP-synced");
	}

	memset(&start, 0, sizeof(start));
	start.flags = 0;                /* no TPG: the capture block is the source */
	if (ioctl(r->dev, FDREC_IOC_START, &start) < 0) {
		perr("FDREC_IOC_START");
		goto out_idle;
	}
	cap_ctrl(r, PKTREC_CAP_CTRL_SRC_SEL | PKTREC_CAP_CTRL_ENABLE);
	r->hdr->tb_start_ns = rd64(&r->hw.cap, PKTREC_CAP_TB_NOW_LO);
	r->hdr->start_time_ns = realtime_ns();
	r->t0 = r->t_last = r->t_write = now_s();
	r->bp_last = rd64(&r->hw.cap, PKTREC_CAP_BP_CYCLES_LO);
	if (write_header(r)) {
		set_error(r, -EIO);
		g_stop = 1;
	}

	if (!r->o.quiet) {
		fprintf(stderr, "pktrec-cap: capturing ports");
		for (i = 0; i < PKTREC_NUM_PORTS; i++)
			if (r->o.ports & (1u << i))
				fprintf(stderr, " P%u", i);
		fprintf(stderr, " to %s (snaplen %u, %u x %" PRIu64 " MB buffers, qd %u)%s\n",
			r->o.output, r->o.snaplen, r->o.buffers, r->o.buf_size >> 20, r->o.qd,
			isatty(2) ? " -- Ctrl-C to stop" : "");
	}
	if (r->o.duration > 0)
		deadline = r->t0 + r->o.duration;
	next_stats = r->t0 + (r->o.stats > 0 ? r->o.stats : 1e30);

	/* ---- main loop ---- */
	for (;;) {
		struct io_uring_cqe *cqe;
		struct __kernel_timespec ts;
		double now = now_s(), wait_s;
		unsigned head, seen;

		/* stop conditions */
		if (r->phase == RUN) {
			bool stop = g_stop;

			if (deadline && now >= deadline) {
				stop = true;
				r->stop_flags |= PKTREC_FILE_FLAG_LIMIT_TIME;
			}
			if (r->o.size && r->bytes_submitted >= r->o.size) {
				stop = true;
				r->stop_flags |= PKTREC_FILE_FLAG_LIMIT_SIZE;
			}
			if (r->o.stop_file && access(r->o.stop_file, F_OK) == 0) {
				stop = true;
				unlink(r->o.stop_file);
			}
			if (stop) {
				cap_ctrl(r, PKTREC_CAP_CTRL_SRC_SEL);   /* no new frames */
				r->phase = DISABLING;
				r->t_phase = now;
			}
		}
		if (r->phase == DISABLING) {
			bool idle = rd(&r->hw.cap, PKTREC_CAP_STATUS) & PKTREC_CAP_STATUS_IDLE;

			if (!idle && now - r->t_phase > IDLE_TIMEOUT) {
				err_msg("capture block not idle %.0f s after the stop (STATUS 0x%08x); "
					"finishing with what was handed over",
					IDLE_TIMEOUT, rd(&r->hw.cap, PKTREC_CAP_STATUS));
				set_error(r, -ETIMEDOUT);
				idle = true;
			}
			if (idle) {
				snapshot_counters(r);
				cap_ctrl(r, PKTREC_CAP_CTRL_SRC_SEL | PKTREC_CAP_CTRL_FILL);
				r->phase = FILLING;
				r->t_phase = now;
			}
		}
		if (r->phase == FILLING) {
			if (!bytes_wanted(r) || r->error || r->dev_hup ||
			    now - r->t_phase > FILL_TIMEOUT) {
				if (bytes_wanted(r) && !r->error) {
					err_msg("only %" PRIu64 " of %" PRIu64 " stream bytes collected "
						"%.0f s after the stop", r->bytes_filled, r->bytes_out,
						FILL_TIMEOUT);
					set_error(r, -ETIMEDOUT);
				}
				/* FILL keeps the DMA fed, so the driver's drain completes */
				if (ioctl(r->dev, FDREC_IOC_STOP, &r->final) < 0) {
					perr("FDREC_IOC_STOP");
					set_error(r, -errno);
				}
				r->fdrec_stopped = true;
				/* FILL off; recorder source back to the TPG (reset state) */
				cap_ctrl(r, 0);
				r->phase = STOPPED;
			}
		}

		if (r->phase != STOPPED)
			take_filled(r);
		if (r->phase == STOPPED && r->inflight == 0)
			break;

		/* SSD stall watchdog: writes in flight and none completing */
		if (r->inflight && now - r->t_write > r->o.timeout && r->phase != STOPPED) {
			err_msg("recording stalled: no write completed for %.0f s (%u in flight)",
				r->o.timeout, r->inflight);
			set_error(r, -ETIMEDOUT);
			g_stop = 1;
			if (r->phase == RUN) {
				cap_ctrl(r, PKTREC_CAP_CTRL_SRC_SEL);
				r->phase = DISABLING;
				r->t_phase = now;
			}
		}
		if (r->phase != STOPPED && r->inflight < r->o.qd)
			arm_poll(r);
		io_uring_submit(&r->ring);

		if ((!r->o.quiet || r->sj) && r->o.stats > 0 && now >= next_stats) {
			print_stats(r, false);
			while (next_stats <= now)
				next_stats += r->o.stats;
		}
		wait_s = (r->o.stats > 0 ? next_stats : now + 0.2) - now;
		if (r->phase != RUN)
			wait_s = 0.005;
		if (deadline && r->phase == RUN && deadline - now < wait_s)
			wait_s = deadline - now;
		if (wait_s < 0.001)
			wait_s = 0.001;
		if (wait_s > 0.2)
			wait_s = 0.2;   /* stop file / signal latency */
		ts.tv_sec = (long long)wait_s;
		ts.tv_nsec = (long long)((wait_s - (double)ts.tv_sec) * 1e9);
		e = io_uring_wait_cqe_timeout(&r->ring, &cqe, &ts);
		if (e < 0 && e != -ETIME && e != -EINTR) {
			errno = -e;
			perr("io_uring_wait_cqe");
			set_error(r, e);
			g_stop = 1;
		}
		seen = 0;
		io_uring_for_each_cqe(&r->ring, head, cqe) {
			handle_cqe(r, cqe);
			seen++;
		}
		io_uring_cq_advance(&r->ring, seen);
	}

	if (r->poll_armed) {
		struct io_uring_sqe *sqe = io_uring_get_sqe(&r->ring);

		if (sqe) {
			io_uring_prep_poll_remove(sqe, UD_POLL);
			io_uring_submit(&r->ring);
		}
	}
	if ((!r->o.quiet || r->sj) && r->o.stats > 0)
		print_stats(r, true);

	/* ---- final header ---- */
	{
		uint64_t valid = r->bytes_out < r->bytes_written ? r->bytes_out : r->bytes_written;

		if (valid < r->bytes_out)
			err_msg("the file holds %" PRIu64 " of %" PRIu64 " stream bytes",
				valid, r->bytes_out);
		r->hdr->data_bytes = valid;
		r->hdr->records = r->records_out;
		r->hdr->rec_drop_beats = r->final.drop_count > r->last_drop ?
					 r->final.drop_count : r->last_drop;
		r->hdr->dma_errors = r->final.dma_errors;
		r->hdr->flags |= PKTREC_FILE_FLAG_COMPLETE | r->stop_flags;
		for (i = 0; i < PKTREC_NUM_PORTS; i++) {
			struct pktrec_file_port *p = &r->hdr->port[i];

			p->frames_rx = r->pc[i].frames_rx;
			p->frames_bad = r->pc[i].frames_bad;
			p->frames_drop = r->pc[i].frames_drop;
			p->bytes_rx = r->pc[i].bytes_rx;
			p->bytes_drop = r->pc[i].bytes_drop;
			p->frames_trunc = r->pc[i].frames_trunc;
			p->records = r->pc[i].records;
			drops += r->pc[i].frames_drop;
		}
		if (write_header(r))
			set_error(r, -EIO);
		if (ftruncate(r->out, HDR_SIZE + valid) < 0) {
			perr("ftruncate %s", r->o.output);
			set_error(r, -errno);
		}
		if (fsync(r->out) < 0) {
			perr("fsync %s", r->o.output);
			set_error(r, -errno);
		}
	}

	{
		double el = (double)(r->hdr->stop_time_ns - r->hdr->start_time_ns) / 1e9;
		uint32_t len_fixups = rd(&r->hw.cap, PKTREC_CAP_LEN_FIXUPS);
		uint32_t aborts = rd(&r->hw.cap, PKTREC_CAP_SRST_ABORTS);

		printf("pktrec-cap: %s: %" PRIu64 " records, %" PRIu64 " bytes in %.2f s (%.1f MB/s)\n",
		       r->o.output, r->records_out, r->hdr->data_bytes, el,
		       el > 0 ? r->hdr->data_bytes / el / 1e6 : 0.0);
		for (i = 0; i < PKTREC_NUM_PORTS; i++) {
			const struct pktrec_file_port *p = &r->hdr->port[i];

			if (!(r->o.ports & (1u << i)))
				continue;
			printf("  P%u: frames %" PRIu64 " (bad %" PRIu64 ", truncated %" PRIu64
			       "), dropped %" PRIu64 ", records %" PRIu64 ", %" PRIu64
			       " bytes, FIFO high-water %u bytes\n", i, p->frames_rx, p->frames_bad,
			       p->frames_trunc, p->frames_drop, p->records, p->bytes_rx,
			       r->pc[i].fifo_hwm);
		}
		printf("  recorder: dropped beats %" PRIu64 ", DMA errors %" PRIu64
		       ", max writes in flight %u; capture block: length fixups %u, reset aborts %u\n",
		       r->hdr->rec_drop_beats, r->hdr->dma_errors, r->max_inflight, len_fixups,
		       aborts);
		printf("RESULT bytes=%" PRIu64 " records=%" PRIu64 " seconds=%.3f drops=%" PRIu64
		       " rec_drop_beats=%" PRIu64 " len_fixups=%u error=%d\n", r->hdr->data_bytes,
		       r->records_out, el, drops, r->hdr->rec_drop_beats, len_fixups, r->error);
		res_el = el;
		res_fixups = len_fixups;
		if (len_fixups)
			drops += len_fixups;
	}
	if (r->error)
		ret = 1;
	else if (drops || r->hdr->rec_drop_beats || r->hdr->dma_errors)
		ret = 2;
	else
		ret = 0;
	if (ret == 2)
		fprintf(stderr, "pktrec-cap: WARNING: frames were dropped -- the capture is not lossless\n");
	if (r->sj) {
		/* the RESULT line as JSON */
		fprintf(r->sj, "{\"type\":\"result\",\"exit_code\":%d,\"bytes\":%" PRIu64
			",\"records\":%" PRIu64 ",\"seconds\":%.3f,\"drops\":%" PRIu64
			",\"rec_drop_beats\":%" PRIu64 ",\"dma_errors\":%" PRIu64
			",\"len_fixups\":%u,\"error\":%d}\n", ret, r->hdr->data_bytes,
			r->records_out, res_el, drops - res_fixups, r->hdr->rec_drop_beats,
			r->hdr->dma_errors, res_fixups, r->error);
		fflush(r->sj);
	}
	goto out;

out_idle:
	cap_ctrl(r, 0);
out:
	if (r->ring.ring_fd > 0)
		io_uring_queue_exit(&r->ring);
	if (r->out >= 0)
		close(r->out);
	if (r->dev >= 0) {
		if (!r->fdrec_stopped && r->phase != RUN)
			ioctl(r->dev, FDREC_IOC_STOP, &r->final);
		close(r->dev);  /* driver stops, unpins and resets */
	}
	if (r->hw.cap.p && !r->fdrec_stopped && r->phase != RUN)
		cap_ctrl(r, 0);
	hw_close(&r->hw);
	if (r->mem)
		munmap(r->mem, r->mem_len);
	free(r->hdr);
	if (r->sj && r->sj != stdout && r->sj != stderr)
		fclose(r->sj);
	free(addrs);
	free(iov);
	return ret;
}

/* ------------------------------------------------------------------------ */
/* stats                                                                     */

static void print_hw_stats(const struct hw *hw, const struct port_cnt *prev, double dt,
			   struct port_cnt *now)
{
	uint32_t ctrl = rd(&hw->cap, PKTREC_CAP_CTRL), st = rd(&hw->cap, PKTREC_CAP_STATUS);
	uint32_t en = rd(&hw->cap, PKTREC_CAP_PORT_EN), snap = rd(&hw->cap, PKTREC_CAP_SNAPLEN);
	uint64_t tb = rd64(&hw->cap, PKTREC_CAP_TB_NOW_LO);
	char t[64];
	unsigned i;

	pktrec_fmt_time(tb, t, sizeof(t));
	printf("capture  version 0x%08x  CTRL 0x%08x (%s%s%s)  STATUS 0x%08x (%s)\n",
	       rd(&hw->cap, PKTREC_CAP_VERSION), ctrl,
	       (ctrl & PKTREC_CAP_CTRL_ENABLE) ? "ENABLED" : "disabled",
	       (ctrl & PKTREC_CAP_CTRL_SRC_SEL) ? ", source = capture" : ", source = TPG",
	       (ctrl & PKTREC_CAP_CTRL_FILL) ? ", FILL" : "", st,
	       (st & PKTREC_CAP_STATUS_IDLE) ? "idle" : "busy");
	printf("ports    enabled 0x%x, snaplen %u, FIFO %u bytes/port, dp_clk %u Hz\n", en,
	       snap, rd(&hw->cap, PKTREC_CAP_PORT_FIFO_BYTES), rd(&hw->cap, PKTREC_CAP_DP_CLK_HZ));
	printf("timebase %" PRIu64 " ns (%s if set from CLOCK_REALTIME), inc %u + %u/2^32 ns, "
	       "TB_STATUS 0x%02x\n", tb, t, rd(&hw->cap, PKTREC_CAP_TB_INC_NS) & 0xFF,
	       rd(&hw->cap, PKTREC_CAP_TB_INC_FRAC), rd(&hw->cap, PKTREC_CAP_TB_STATUS));
	printf("merge    %" PRIu64 " records, %" PRIu64 " bytes out, %" PRIu64
	       " fill units, back-pressure %" PRIu64 " cycles, reset aborts %u, length fixups %u\n",
	       rd64(&hw->cap, PKTREC_CAP_RECORDS_OUT_LO), rd64(&hw->cap, PKTREC_CAP_BYTES_OUT_LO),
	       rd64(&hw->cap, PKTREC_CAP_FILL_BEATS_LO), rd64(&hw->cap, PKTREC_CAP_BP_CYCLES_LO),
	       rd(&hw->cap, PKTREC_CAP_SRST_ABORTS), rd(&hw->cap, PKTREC_CAP_LEN_FIXUPS));
	printf("port link  %14s %10s %10s %10s %16s %14s %9s %6s%s\n", "frames_rx", "bad",
	       "dropped", "truncated", "bytes_rx", "records", "fifo_hwm", "seq",
	       prev ? "      frames/s        bits/s" : "");
	for (i = 0; i < PKTREC_NUM_PORTS; i++) {
		struct port_cnt c;
		uint32_t sp = port_speed(hw, i);
		char link[8];

		read_port(hw, i, &c);
		if (hw->eth.p)
			snprintf(link, sizeof(link), "%s", sp ? (sp == 1000 ? "1G" : sp == 100 ? "100M" : "10M") : "down");
		else
			snprintf(link, sizeof(link), "?");
		printf("P%u   %-5s %14" PRIu64 " %10" PRIu64 " %10" PRIu64 " %10" PRIu64 " %16" PRIu64
		       " %14" PRIu64 " %9u %6u", i, link, c.frames_rx, c.frames_bad, c.frames_drop,
		       c.frames_trunc, c.bytes_rx, c.records, c.fifo_hwm,
		       rd(&hw->cap, PKTREC_CAP_PORT(i) + PKTREC_CAP_P_SEQ_NEXT) & 0xFFFF);
		if (prev && dt > 0)
			printf(" %13.0f %13.0f", (c.frames_rx - prev[i].frames_rx) / dt,
			       (c.bytes_rx - prev[i].bytes_rx) * 8.0 / dt);
		printf("%s\n", (en & (1u << i)) ? "" : "  (not enabled)");
		if (now)
			now[i] = c;
	}
}

/* The same fields as print_hw_stats, as one JSON object on one line */
static void print_hw_stats_json(const struct hw *hw, const struct port_cnt *prev, double dt,
				struct port_cnt *now)
{
	uint32_t ctrl = rd(&hw->cap, PKTREC_CAP_CTRL), st = rd(&hw->cap, PKTREC_CAP_STATUS);
	uint32_t en = rd(&hw->cap, PKTREC_CAP_PORT_EN);
	uint32_t inc_ns = rd(&hw->cap, PKTREC_CAP_TB_INC_NS) & 0xFF;
	uint32_t inc_frac = rd(&hw->cap, PKTREC_CAP_TB_INC_FRAC);
	uint64_t t = realtime_ns(), tb = rd64(&hw->cap, PKTREC_CAP_TB_NOW_LO);
	char ts[64];
	unsigned i;

	pktrec_fmt_time(tb, ts, sizeof(ts));
	printf("{\"time_ns\":%" PRIu64 ",\"cap_version\":\"0x%08x\",\"ctrl\":\"0x%08x\","
	       "\"enabled\":%s,\"source\":\"%s\",\"fill\":%s,\"status\":\"0x%08x\",\"idle\":%s,"
	       "\"port_en\":%u,\"snaplen\":%u,\"fifo_bytes\":%u,\"dp_clk_hz\":%u,"
	       "\"timebase_ns\":%" PRIu64 ",\"timebase\":\"%s\",\"tb_inc_ns\":%u,"
	       "\"tb_inc_frac\":%u,\"tb_inc\":%.9f,\"tb_freq_ppb\":%.1f,\"tb_status\":\"0x%02x\","
	       "\"merge\":{\"records\":%" PRIu64 ",\"bytes_out\":%" PRIu64 ",\"fill_units\":%"
	       PRIu64 ",\"bp_cycles\":%" PRIu64 ",\"srst_aborts\":%u,\"len_fixups\":%u},"
	       "\"ports\":[",
	       t, rd(&hw->cap, PKTREC_CAP_VERSION), ctrl,
	       (ctrl & PKTREC_CAP_CTRL_ENABLE) ? "true" : "false",
	       (ctrl & PKTREC_CAP_CTRL_SRC_SEL) ? "capture" : "TPG",
	       (ctrl & PKTREC_CAP_CTRL_FILL) ? "true" : "false", st,
	       (st & PKTREC_CAP_STATUS_IDLE) ? "true" : "false", en,
	       rd(&hw->cap, PKTREC_CAP_SNAPLEN), rd(&hw->cap, PKTREC_CAP_PORT_FIFO_BYTES),
	       rd(&hw->cap, PKTREC_CAP_DP_CLK_HZ), tb, ts, inc_ns, inc_frac,
	       inc_ns + inc_frac / 4294967296.0, tb_freq_ppb(&hw->cap),
	       rd(&hw->cap, PKTREC_CAP_TB_STATUS),
	       rd64(&hw->cap, PKTREC_CAP_RECORDS_OUT_LO), rd64(&hw->cap, PKTREC_CAP_BYTES_OUT_LO),
	       rd64(&hw->cap, PKTREC_CAP_FILL_BEATS_LO), rd64(&hw->cap, PKTREC_CAP_BP_CYCLES_LO),
	       rd(&hw->cap, PKTREC_CAP_SRST_ABORTS), rd(&hw->cap, PKTREC_CAP_LEN_FIXUPS));
	for (i = 0; i < PKTREC_NUM_PORTS; i++) {
		struct port_cnt c;
		uint32_t sp = port_speed(hw, i);
		const char *link = !hw->eth.p ? "?" : !sp ? "down" : sp == 1000 ? "1G" :
				   sp == 100 ? "100M" : "10M";

		read_port(hw, i, &c);
		printf("%s{\"port\":%u,\"link\":\"%s\",\"enabled\":%s,\"frames_rx\":%" PRIu64
		       ",\"frames_bad\":%" PRIu64 ",\"frames_drop\":%" PRIu64 ",\"frames_trunc\":%"
		       PRIu64 ",\"bytes_rx\":%" PRIu64 ",\"bytes_drop\":%" PRIu64 ",\"records\":%"
		       PRIu64 ",\"fifo_hwm\":%u,\"seq\":%u", i ? "," : "", i, link,
		       (en & (1u << i)) ? "true" : "false", c.frames_rx, c.frames_bad,
		       c.frames_drop, c.frames_trunc, c.bytes_rx, c.bytes_drop, c.records,
		       c.fifo_hwm, rd(&hw->cap, PKTREC_CAP_PORT(i) + PKTREC_CAP_P_SEQ_NEXT) & 0xFFFF);
		if (prev && dt > 0)
			printf(",\"frames_s\":%.1f,\"bits_s\":%.1f",
			       (c.frames_rx - prev[i].frames_rx) / dt,
			       (c.bytes_rx - prev[i].bytes_rx) * 8.0 / dt);
		else
			printf(",\"frames_s\":null,\"bits_s\":null");
		printf("}");
		if (now)
			now[i] = c;
	}
	printf("]}\n");
}

static int cmd_stats(int argc, char **argv)
{
	static const struct option lo[] = {
		{ "watch", required_argument, NULL, 'w' },
		{ "clear", no_argument, NULL, 'c' },
		{ "json", no_argument, NULL, 'j' },
		{ "devmem", no_argument, NULL, 'M' },
		{ "help", no_argument, NULL, 'h' },
		{ NULL, 0, NULL, 0 },
	};
	struct hw hw;
	struct port_cnt prev[PKTREC_NUM_PORTS], cur[PKTREC_NUM_PORTS];
	double watch = 0, t_prev = 0;
	bool clear = false, devmem = false, have_prev = false, json = false;
	struct sigaction sa;
	int c;

	while ((c = getopt_long(argc, argv, "h", lo, NULL)) != -1) {
		switch (c) {
		case 'w':
			if (parse_double(optarg, &watch) || watch <= 0)
				return die_usage("invalid --watch '%s'", optarg);
			break;
		case 'c':
			clear = true;
			break;
		case 'j':
			json = true;
			break;
		case 'M':
			devmem = true;
			break;
		case 'h':
			printf("Usage: pktrec-cap stats [--watch <sec>] [--clear] [--json] [--devmem]\n\n"
			       "Show the capture block's state and counters without capturing.\n"
			       "--watch repeats every <sec> seconds with frame and bit rates;\n"
			       "--clear clears the counters (refused while a capture runs);\n"
			       "--json prints the same fields as one JSON object per line.\n");
			return 0;
		default:
			return 1;
		}
	}
	if (hw_open(&hw, devmem, true))
		return 1;
	if (clear) {
		uint32_t ctrl = rd(&hw.cap, PKTREC_CAP_CTRL);

		if (ctrl & PKTREC_CAP_CTRL_ENABLE) {
			err_msg("a capture is running; not clearing the counters");
			hw_close(&hw);
			return 1;
		}
		wr(&hw.cap, PKTREC_CAP_CTRL, ctrl | PKTREC_CAP_CTRL_CLEAR);
	}
	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = on_signal;
	sigaction(SIGINT, &sa, NULL);
	sigaction(SIGTERM, &sa, NULL);
	do {
		double t = now_s();

		if (json)
			print_hw_stats_json(&hw, have_prev ? prev : NULL, t - t_prev, cur);
		else
			print_hw_stats(&hw, have_prev ? prev : NULL, t - t_prev, cur);
		memcpy(prev, cur, sizeof(prev));
		have_prev = true;
		t_prev = t;
		if (watch > 0 && !g_stop) {
			if (!json)
				printf("\n");
			fflush(stdout);
			usleep((useconds_t)(watch * 1e6));
		}
	} while (watch > 0 && !g_stop);
	hw_close(&hw);
	return 0;
}

/* ------------------------------------------------------------------------ */
/* info                                                                      */

static int cmd_info(int argc, char **argv)
{
	static const struct option lo[] = {
		{ "records", required_argument, NULL, 'r' },
		{ "help", no_argument, NULL, 'h' },
		{ NULL, 0, NULL, 0 },
	};
	struct pktrec_file_header h;
	uint64_t nrec = 0, v;
	int c, fd;

	while ((c = getopt_long(argc, argv, "h", lo, NULL)) != -1) {
		switch (c) {
		case 'r':
			if (parse_size(optarg, &v))
				return die_usage("invalid --records '%s'", optarg);
			nrec = v;
			break;
		case 'h':
			printf("Usage: pktrec-cap info [--records <n>] <capture-file>\n\n"
			       "Print the capture file header; --records also lists the first <n>\n"
			       "record headers of the stream.\n");
			return 0;
		default:
			return 1;
		}
	}
	if (optind != argc - 1)
		return die_usage("exactly one <capture-file> is required");
	fd = open(argv[optind], O_RDONLY | O_CLOEXEC);
	if (fd < 0) {
		perr("open %s", argv[optind]);
		return 1;
	}
	if (pktrec_read_header(fd, argv[optind], &h)) {
		close(fd);
		return 1;
	}
	pktrec_print_header(stdout, &h);
	if (nrec)
		printf("\n%10s %20s %4s %7s %8s %5s %5s %s\n", "offset", "ts_ns", "port",
		       "cap_len", "orig_len", "seq", "flags", "");
	for (v = 0; nrec; ) {
		struct pktrec_rec_hdr r;
		uint8_t skip[16];
		ssize_t n = pread(fd, &r, sizeof(r), (off_t)(HDR_SIZE + v));

		if (n != (ssize_t)sizeof(r))
			break;
		memcpy(skip, &r, 16);
		if (!memcmp(skip, "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0", 16)) {
			v += 16;        /* fill unit */
			continue;
		}
		r.ts_ns = le64toh(r.ts_ns);
		r.cap_len = le16toh(r.cap_len);
		r.orig_len = le16toh(r.orig_len);
		r.seq = le16toh(r.seq);
		printf("%10" PRIu64 " %20" PRIu64 " %4u %7u %8u %5u  0x%02x %s%s%s%s%s\n", v,
		       r.ts_ns, r.port, r.cap_len, r.orig_len, r.seq, r.flags,
		       (r.flags & PKTREC_REC_MARKER_MASK) != PKTREC_REC_MARKER ? "BAD MARKER " : "",
		       (r.flags & PKTREC_REC_FLAG_BAD) ? "bad " : "",
		       (r.flags & PKTREC_REC_FLAG_TRUNC) ? "trunc " : "",
		       (r.flags & PKTREC_REC_FLAG_TS_MAC) ? "ts=MAC " : "ts=SFD ",
		       (r.flags & PKTREC_REC_FLAG_SFD_MISMATCH) ? "sfd-mismatch" : "");
		if ((r.flags & PKTREC_REC_MARKER_MASK) != PKTREC_REC_MARKER)
			break;
		v += PKTREC_REC_BYTES(r.cap_len);
		nrec--;
	}
	close(fd);
	return 0;
}

int main(int argc, char **argv)
{
	if (argc >= 2 && !strcmp(argv[1], "stats")) {
		prog_name = "pktrec-cap stats";
		return cmd_stats(argc - 1, argv + 1);
	}
	if (argc >= 2 && !strcmp(argv[1], "info")) {
		prog_name = "pktrec-cap info";
		return cmd_info(argc - 1, argv + 1);
	}
	if (argc >= 2 && !strcmp(argv[1], "record"))
		return cmd_record(argc - 1, argv + 1);
	return cmd_record(argc, argv);
}
