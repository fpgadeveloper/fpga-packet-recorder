// SPDX-License-Identifier: MIT
/*
 * pktrec-replay -- FPGA Packet Recorder: replay a capture out of a port.
 *
 * Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
 *
 *   pktrec-replay <capture.cap> --iface P<n> --port <m> [options]
 *
 * Reads a capture file (pktrec-cap; pcapng is not accepted: the exporter
 * direction is one-way), selects the records of ONE capture interface (port
 * P<n>: the frames received on that port) and streams them -- 16-byte record
 * headers included, contiguous, fill dropped -- through the recorder's
 * playback path (hugepage buffers -> fdrec driver PLAY_* ioctls -> AXI DMA
 * MM2S -> fdrec_core egress FIFO) into the replay block (pktrec_replay,
 * PKTREC_RPL_*). The block keeps whole frames in its 128 KB store and releases
 * each into the TX MAC of port <m> (path mode 4 REPLAY, PKTREC_M0_PATH_RPL)
 * when the shared timebase reaches the frame's target:
 *
 *   default      original timing: target = T0 + (ts - ts_first)
 *   --rate X     intervals divided by X (2 = twice as fast, 0.5 = half speed)
 *   --topspeed   back to back, as fast as the MAC sends (line rate)
 *   --gap NS     fixed start-to-start interval
 *
 * The file is read with io_uring (O_DIRECT, read-ahead); the selected records
 * are copied into the DMA buffers (the CPU filters, the timing is all in
 * hardware). Timing is never corrected in software: a frame the DMA could not
 * deliver in time is sent late and counted (UNDERRUNS / LATE), and the exit
 * code says so.
 *
 * --preload: load the selected frames into the replay store first (up to
 * 128 KB / 2048 frames), stop the DMA and release /dev/fdrec0, then start
 * (optionally once pktrec-cap has started a capture: --wait-capture). The
 * recorder DMA serves one direction at a time (one open, one direction per
 * session, and stopping either channel resets the whole AXI DMA), so this is
 * how a replay runs WHILE the recorder captures, e.g. the timing test "replay
 * out of P2, capture on P3" (test/compare_replay.py).
 *
 * Exit codes: 0 = every selected frame sent, no underrun, no parse error;
 *             2 = completed, but underruns / parse errors / missing frames;
 *             1 = error (or interrupted).
 */

#define _GNU_SOURCE
#include <dirent.h>
#include <endian.h>
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <inttypes.h>
#include <math.h>
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
#ifndef PKTREC_NO_URING
#include <liburing.h>
#else
/* host test build (make pktrec-replay-host): synchronous pread instead of
 * io_uring, for --dry-run on a PC without liburing */
struct io_uring { int unused; };
#endif

#include "fdrec_uapi.h"
#include "pktrec_regs.h"
#include "pktrec_common.h"

#ifndef MAP_HUGE_2MB
#define MAP_HUGE_2MB    (21 << 26)
#endif

const char *prog_name = "pktrec-replay";

#define DEF_DEVICE      "/dev/fdrec0"
#define DEF_BUFFERS     8
#define DEF_BUF_SIZE    (4ull << 20)
#define STAGE_SIZE      (4u << 20)      /* file read chunk (O_DIRECT) */
#define NSTAGE          4               /* read-ahead */
#define HDR_SIZE        PKTREC_FILE_HEADER_SIZE
#define RUN_DIR         "/run/pktrec"
#define META_FRAMES     2048            /* replay metadata FIFO (frames) */

static volatile sig_atomic_t g_stop;

static void on_signal(int sig)
{
	(void)sig;
	g_stop = 1;
}

/* ------------------------------------------------------------------------ */
/* register access (generic-uio or /dev/mem), as pktrec-cap                 */

struct regs {
	volatile uint32_t *p;
	size_t size;
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
			" (bitstream without replay / generic-uio binding missing? try --devmem)",
			what, base);
		return -1;
	} else if (usize && usize < size) {
		size = usize;
	}
	fd = open(dev, O_RDWR | O_SYNC | O_CLOEXEC);
	if (fd < 0) {
		if (errno == EACCES || errno == EPERM)
			err_msg("needs root (sudo): %s: permission denied", dev);
		else
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
	return 0;
}

static inline uint32_t rd(const struct regs *r, uint32_t off) { return r->p[off / 4]; }
static inline void wr(const struct regs *r, uint32_t off, uint32_t v) { r->p[off / 4] = v; }
static inline uint64_t rd64(const struct regs *r, uint32_t off_lo)
{
	uint32_t lo = rd(r, off_lo);

	return ((uint64_t)rd(r, off_lo + 4) << 32) | lo;
}

/* ------------------------------------------------------------------------ */
/* options                                                                  */

struct opts {
	const char *input;
	const char *device;
	int iface;              /* capture interface (port) to replay */
	int port;               /* output port */
	double rate;            /* speed factor (TIMED) */
	bool topspeed;
	uint64_t gap_ns;        /* FIXED mode when != 0 */
	unsigned loops;
	double start_delay_ms;
	int bad_mode;           /* PKTREC_RPL_BAD_* */
	uint32_t late_thresh;
	bool preload;
	double wait_capture;    /* s, 0 = do not wait */
	bool force;
	bool keep_path;
	bool devmem;
	bool json;
	bool quiet;
	bool dry_run;
	unsigned buffers;
	uint64_t buf_size;
};

static void usage(FILE *f)
{
	fprintf(f,
"Usage: pktrec-replay <capture.cap> --iface P<n> --port <m> [options]\n"
"\n"
"Replay the frames one interface (port P<n>) received in a capture file out of\n"
"port <m>, with the original timing (or scaled, back to back, or at a fixed\n"
"interval), scheduled in hardware against the recorder's timebase.\n"
"\n"
"  --iface P<n>        capture interface to replay (P0..P3; a TAP-mode capture\n"
"                      has one interface per direction: replay each with its own\n"
"                      run, or run two pktrec-replay processes is NOT possible:\n"
"                      one replay at a time)\n"
"  --port <m>          output port 0..3 (put into path mode 4 REPLAY for the run)\n"
"  --rate <x>          speed factor: intervals / x (2 = twice as fast, 0.5 = half)\n"
"  --topspeed          back to back at line rate (ignore the timestamps)\n"
"  --gap <ns>          fixed start-to-start interval (ignore the timestamps)\n"
"  --loop <n>          play the selection n times (timestamps continue; default 1)\n"
"  --start-delay <ms>  first frame this long after the start (default 10)\n"
"  --keep-bad          send frames captured with an error as errored frames\n"
"                      (the FCS is replaced by an error code; the receiver counts\n"
"                      an RX error). Default: such frames are skipped\n"
"  --bad-as-good       send them as good frames (with a new, valid FCS)\n"
"  --late-thresh <ns>  a frame released later than its target + this counts as\n"
"                      LATE (default 100)\n"
"  --preload           load the frames into the replay store (<= 128 KB, 2048\n"
"                      frames; the rest is ignored), release the recorder DMA,\n"
"                      then start: lets pktrec-cap capture during the replay\n"
"  --wait-capture <s>  with --preload: start only once a capture is running\n"
"                      (pktrec-cap CTRL.ENABLE), wait at most <s> seconds\n"
"  --force             replay although the output pair is in TAP mode, the port\n"
"                      has no link or another replay seems active\n"
"  --keep-path         leave the port in REPLAY mode afterwards\n"
"  --buffers <n> --buf-size <bytes>   DMA ring (default %d x 4M)\n"
"  --device <path>     recorder device (default %s)\n"
"  --devmem            map registers through /dev/mem instead of generic-uio\n"
"  --json              final summary as one JSON object on stdout\n"
"  --dry-run           only read the file: frames selected, time span, no hardware\n"
"  -q, --quiet         no progress line\n"
"  -h, --help          this help\n"
"\n"
"Frames go out as captured: the captured bytes (FCS excluded) plus a new FCS from\n"
"the MAC; frames shorter than 60 bytes as runts; snaplen-truncated frames\n"
"truncated. Exit: 0 all sent in time, 2 underruns / parse errors / missing frames,\n"
"1 error.\n",
		DEF_BUFFERS, DEF_DEVICE);
}

/* ------------------------------------------------------------------------ */
/* state                                                                    */

struct rp {
	struct opts o;
	struct regs rpl, m0, cap;
	bool have_cap;
	int in;                 /* capture file (O_DIRECT) */
	int dev;                /* /dev/fdrec0 */
	uint64_t data_bytes;
	/* reading */
	struct io_uring ring;
	bool ring_ok;
	uint8_t *stage;         /* NSTAGE x STAGE_SIZE */
	int stage_len[NSTAGE];  /* bytes read, -1 = pending, -2 = idle */
	uint64_t next_read;     /* next chunk to read */
	uint64_t nchunks;
	/* DMA buffers */
	uint8_t *mem;
	size_t mem_len;
	int *freeq;
	unsigned nfree;
	int cur;                /* buffer being filled, -1 = none */
	uint64_t fill;
	unsigned inflight;
	bool registered, play_started, go_done;
	/* record parser (file side) */
	uint64_t rem;           /* bytes of the current record still to handle */
	bool copying;
	bool resync;
	uint64_t ts_off;        /* added to every ts (loops) */
	uint64_t first_ts, last_ts;
	bool have_ts;
	/* totals */
	uint64_t sel_records, sel_bytes, file_records, file_perr;
	uint64_t streamed_bytes;
	uint64_t pre_beats;     /* --preload: store beats used */
	bool preload_full;
	/* restore */
	uint32_t old_path, old_rpl;
	bool path_set, hold_made;
	char hold[96];
	double t_start;
};

static void report_progress(struct rp *p, bool final);

/* ------------------------------------------------------------------------ */
/* replay block helpers                                                     */

static unsigned rpl_state(struct rp *p)
{
	return rd(&p->rpl, PKTREC_RPL_STATUS) & PKTREC_RPL_ST_STATE_MASK;
}

static int prime_and_go(struct rp *p)
{
	uint32_t lv, last = 0xffffffffu;
	double t0 = now_s(), t_same = t0;

	if (p->go_done)
		return 0;
	/* let the stream fill the store (it stalls the DMA once full) */
	while (now_s() - t0 < 0.5) {
		lv = rd(&p->rpl, PKTREC_RPL_STORE_LEVEL);
		if ((lv & 0xffff) >= rd(&p->rpl, PKTREC_RPL_STORE_BEATS) - 64 ||
		    (lv >> 16) >= META_FRAMES - 4)
			break;
		if (lv != last) {
			last = lv;
			t_same = now_s();
		} else if (now_s() - t_same > 0.005) {
			break;
		}
		usleep(200);
	}
	wr(&p->rpl, PKTREC_RPL_CMD, PKTREC_RPL_CMD_GO);
	p->go_done = true;
	p->t_start = now_s();
	return 0;
}

/* ------------------------------------------------------------------------ */
/* DMA output stream                                                        */

static int wait_done(struct rp *p, int timeout_ms)
{
	struct fdrec_play_done d = { .timeout_ms = timeout_ms };

	if (ioctl(p->dev, FDREC_IOC_PLAY_WAIT_DONE, &d) < 0) {
		if (errno == ETIMEDOUT || errno == EINTR)
			return 0;
		perr("FDREC_IOC_PLAY_WAIT_DONE");
		return -1;
	}
	p->freeq[p->nfree++] = (int)d.index;
	p->inflight--;
	if (d.flags & FDREC_DONE_ERROR) {
		err_msg("DMA error on buffer %u", d.index);
		return -1;
	}
	return 1;
}

static int submit_cur(struct rp *p)
{
	struct fdrec_play_submit s = { .index = (uint32_t)p->cur, .bytes = p->fill };

	if (p->cur < 0 || !p->fill)
		return 0;
	if (ioctl(p->dev, FDREC_IOC_PLAY_SUBMIT, &s) < 0) {
		perr("FDREC_IOC_PLAY_SUBMIT (buffer %d)", p->cur);
		return -1;
	}
	p->streamed_bytes += p->fill;
	p->inflight++;
	p->cur = -1;
	p->fill = 0;
	return 0;
}

/* a free buffer to fill; GO the replay before blocking on the DMA */
static int get_buffer(struct rp *p)
{
	while (!p->nfree) {
		int r;

		if (g_stop)
			return -1;
		if (!p->go_done && !p->o.preload)
			prime_and_go(p);
		r = wait_done(p, 500);
		if (r < 0)
			return -1;
		if (!r && !p->o.quiet)
			report_progress(p, false);
	}
	p->cur = p->freeq[--p->nfree];
	p->fill = 0;
	return 0;
}

static int out_put(struct rp *p, const uint8_t *src, uint64_t len)
{
	if (p->o.dry_run) {
		p->streamed_bytes += len;
		return 0;
	}
	while (len) {
		uint64_t n;

		if (p->cur < 0 && get_buffer(p))
			return -1;
		n = p->o.buf_size - p->fill;
		if (n > len)
			n = len;
		memcpy(p->mem + (size_t)p->cur * p->o.buf_size + p->fill, src, n);
		p->fill += n;
		src += n;
		len -= n;
		if (p->fill == p->o.buf_size && submit_cur(p))
			return -1;
	}
	return 0;
}

/* ------------------------------------------------------------------------ */
/* file reading (io_uring, O_DIRECT, read-ahead)                            */

static int queue_reads(struct rp *p)
{
#ifdef PKTREC_NO_URING
	while (p->next_read < p->nchunks) {
		unsigned slot = (unsigned)(p->next_read % NSTAGE);
		ssize_t n;

		if (p->stage_len[slot] != -2)
			break;
		n = pread(p->in, p->stage + (size_t)slot * STAGE_SIZE, STAGE_SIZE,
			  (off_t)(HDR_SIZE + p->next_read * STAGE_SIZE));
		if (n < 0) {
			perr("read %s", p->o.input);
			return -1;
		}
		p->stage_len[slot] = (int)n;
		p->next_read++;
	}
	return 0;
#else
	unsigned queued = 0;

	while (p->next_read < p->nchunks) {
		unsigned slot = (unsigned)(p->next_read % NSTAGE);
		uint64_t off = HDR_SIZE + p->next_read * STAGE_SIZE;
		struct io_uring_sqe *sqe;

		if (p->stage_len[slot] != -2)
			break;
		sqe = io_uring_get_sqe(&p->ring);
		if (!sqe)
			break;
		io_uring_prep_read(sqe, p->in, p->stage + (size_t)slot * STAGE_SIZE, STAGE_SIZE, off);
		io_uring_sqe_set_data64(sqe, p->next_read);
		p->stage_len[slot] = -1;
		p->next_read++;
		queued++;
	}
	if (queued && io_uring_submit(&p->ring) < 0) {
		err_msg("io_uring_submit failed");
		return -1;
	}
	return 0;
#endif
}

/* wait until chunk k is in its stage slot; returns its valid length */
static int64_t get_chunk(struct rp *p, uint64_t k)
{
	unsigned slot = (unsigned)(k % NSTAGE);

#ifndef PKTREC_NO_URING
	while (p->stage_len[slot] == -1) {
		struct io_uring_cqe *cqe;
		int e = io_uring_wait_cqe(&p->ring, &cqe);

		if (e < 0) {
			if (e == -EINTR && !g_stop)
				continue;
			err_msg("io_uring_wait_cqe: %s", strerror(-e));
			return -1;
		}
		uint64_t c = io_uring_cqe_get_data64(cqe);
		int res = cqe->res;

		io_uring_cqe_seen(&p->ring, cqe);
		if (res < 0) {
			err_msg("read %s at chunk %" PRIu64 ": %s", p->o.input, c, strerror(-res));
			return -1;
		}
		p->stage_len[c % NSTAGE] = res;
	}
#endif
	{
		uint64_t want = p->data_bytes - k * STAGE_SIZE;
		int64_t len = p->stage_len[slot];

		if (want > STAGE_SIZE)
			want = STAGE_SIZE;
		if ((uint64_t)len < want) {
			err_msg("%s: short read in chunk %" PRIu64 " (%" PRId64 " of %" PRIu64 " bytes)",
				p->o.input, k, len, want);
			return -1;
		}
		return (int64_t)want;
	}
}

static bool hdr_ok(const struct pktrec_rec_hdr *h)
{
	uint16_t cap = le16toh(h->cap_len), orig = le16toh(h->orig_len);

	return (h->flags & PKTREC_REC_MARKER_MASK) == PKTREC_REC_MARKER &&
	       h->port < PKTREC_NUM_PORTS && cap >= 1 && (uint32_t)cap + 4 <= orig &&
	       !!(h->flags & PKTREC_REC_FLAG_TRUNC) == ((uint32_t)cap + 4 < orig);
}

/*
 * One pass over the file: copy the records of the selected interface into the
 * DMA stream, timestamps + ts_off. --preload: stop at the first record that
 * does not fit the store (returns 1 then).
 */
static int stream_pass(struct rp *p)
{
	static const uint8_t zero16[16];
	uint64_t k;

	p->rem = 0;
	p->copying = false;
	p->resync = false;
	p->next_read = 0;
	for (k = 0; k < NSTAGE; k++)
		p->stage_len[k] = -2;
	if (queue_reads(p))
		return -1;

	for (k = 0; k < p->nchunks; k++) {
		int64_t len = get_chunk(p, k);
		const uint8_t *c = p->stage + (size_t)(k % NSTAGE) * STAGE_SIZE;
		uint64_t off = 0;

		if (len < 0)
			return -1;
		while (off < (uint64_t)len) {
			if (g_stop)
				return -1;
			if (p->rem) {
				uint64_t n = (uint64_t)len - off;

				if (n > p->rem)
					n = p->rem;
				if (p->copying && out_put(p, c + off, n))
					return -1;
				off += n;
				p->rem -= n;
				continue;
			}
			/* a record header, a fill unit or garbage (16-byte aligned) */
			const struct pktrec_rec_hdr *h = (const void *)(c + off);

			if (!memcmp(h, zero16, 16)) {
				off += 16;
				continue;
			}
			if (!hdr_ok(h)) {
				if (!p->resync)
					p->file_perr++;
				p->resync = true;
				off += 16;
				continue;
			}
			p->resync = false;
			p->file_records++;
			{
				uint16_t cap = le16toh(h->cap_len);
				uint64_t body = PKTREC_REC_BYTES(cap) - PKTREC_REC_HDR_BYTES;

				if (k * STAGE_SIZE + off + 16 + body > p->data_bytes) {
					/* the file ends inside this record: never send a
					 * partial record (the replay block would wait for
					 * the rest of it) */
					fprintf(stderr, "%s: note: the file ends inside the last record; it is not replayed\n",
						prog_name);
					p->file_records--;
					return 0;
				}
				p->copying = h->port == p->o.iface;
				if (p->copying && p->o.preload) {
					uint64_t beats = body / 16;

					if (p->pre_beats + beats > (p->o.dry_run ? 8192u :
								    rd(&p->rpl, PKTREC_RPL_STORE_BEATS)) ||
					    p->sel_records + 1 > META_FRAMES) {
						p->preload_full = true;
						return 1;
					}
					p->pre_beats += beats;
				}
				if (p->copying) {
					struct pktrec_rec_hdr o = *h;
					uint64_t ts = le64toh(h->ts_ns);

					if (!p->have_ts) {
						p->first_ts = ts;
						p->have_ts = true;
					}
					if (ts > p->last_ts || p->sel_records == 0)
						p->last_ts = ts;
					o.ts_ns = htole64(ts + p->ts_off);
					if (out_put(p, (const uint8_t *)&o, sizeof(o)))
						return -1;
					p->sel_records++;
					p->sel_bytes += cap;
				}
				off += 16;
				p->rem = body;
			}
		}
		/* this slot is consumed: read further ahead */
		p->stage_len[k % NSTAGE] = -2;
		if (queue_reads(p))
			return -1;
	}
	return 0;
}

/* ------------------------------------------------------------------------ */
/* progress / summary                                                       */

static void report_progress(struct rp *p, bool final)
{
	uint64_t frames = rd64(&p->rpl, PKTREC_RPL_FRAMES);
	uint64_t under = rd64(&p->rpl, PKTREC_RPL_UNDERRUNS);
	uint64_t late = rd64(&p->rpl, PKTREC_RPL_LATE);
	uint32_t lv = rd(&p->rpl, PKTREC_RPL_STORE_LEVEL);
	static double last;
	double t = now_s();

	if (!final && t - last < 1.0)
		return;
	last = t;
	fprintf(stderr, "\r%s: %" PRIu64 "/%" PRIu64 " frames sent, store %u frames, %" PRIu64
		" underruns, %" PRIu64 " late, max late %u ns   %s",
		prog_name, frames, p->sel_records, lv >> 16, under, late,
		rd(&p->rpl, PKTREC_RPL_MAX_LATE), final ? "\n" : "");
	fflush(stderr);
}

/* ------------------------------------------------------------------------ */
/* setup / cleanup                                                          */

static int check_paths(struct rp *p)
{
	uint32_t ver = rd(&p->m0, PKTREC_M0_VERSION);
	uint32_t pm = rd(&p->m0, PKTREC_M0_PAIR_MODE);
	uint32_t eff = rd(&p->m0, PKTREC_M0_EFF_PATH);
	uint32_t io = rd(&p->m0, PKTREC_M0_IO_STATUS);
	unsigned pair = (unsigned)p->o.port / 2, a = pair * 2, b = a + 1;
	bool tap = ((pm >> PKTREC_M0_PAIR_SHIFT(pair)) & 3) == PKTREC_M0_PAIR_TAP ||
		   ((eff >> PKTREC_M0_PATH_SHIFT(a)) & 3) == PKTREC_M0_PATH_FWD ||
		   ((eff >> PKTREC_M0_PATH_SHIFT(b)) & 3) == PKTREC_M0_PATH_FWD;
	unsigned st;

	if (ver < PKTREC_M0_VERSION_1_3) {
		err_msg("port datapath VERSION 0x%08x has no replay path (needs >= 1.3)", ver);
		return -1;
	}
	if (tap) {
		if (!p->o.force) {
			err_msg("pair %u (P%u/P%u) is in TAP mode (forwarding): replay and TAP forwarding on the same pair are mutually exclusive -- switch it with 'pktrec-phy mode %u monitor' (or --force)",
				pair, a, b, pair);
			return -1;
		}
		fprintf(stderr, "%s: warning: pair %u is in TAP mode, replaying anyway (--force)\n",
			prog_name, pair);
	}
	if (!(io & (1u << (16 + p->o.port)))) {
		if (!p->o.force) {
			err_msg("P%d has no link (or --force)", p->o.port);
			return -1;
		}
		fprintf(stderr, "%s: warning: P%d has no link\n", prog_name, p->o.port);
	}
	st = rpl_state(p);
	if (st == PKTREC_RPL_STATE_ARMED || st == PKTREC_RPL_STATE_RUNNING ||
	    st == PKTREC_RPL_STATE_ABORTING) {
		if (!p->o.force) {
			err_msg("the replay block is busy (state %u): another pktrec-replay running? (--force aborts it)", st);
			return -1;
		}
		wr(&p->rpl, PKTREC_RPL_CMD, PKTREC_RPL_CMD_ABORT);
		usleep(100000);
	}
	return 0;
}

static int set_path(struct rp *p)
{
	unsigned n = (unsigned)p->o.port;
	double t0;

	p->old_path = rd(&p->m0, PKTREC_M0_PATH_CTRL);
	p->old_rpl = rd(&p->m0, PKTREC_M0_PATH_RPL);
	wr(&p->m0, PKTREC_M0_PATH_CTRL,
	   p->old_path & ~(3u << PKTREC_M0_PATH_SHIFT(n)));   /* IDLE underneath */
	wr(&p->m0, PKTREC_M0_PATH_RPL, p->old_rpl | (1u << n));
	p->path_set = true;
	t0 = now_s();
	while (!(rd(&p->m0, PKTREC_M0_EFF_PATH) & PKTREC_M0_EFF_RPL(n))) {
		if (now_s() - t0 > 0.5) {
			err_msg("P%u did not switch to the replay path (EFF_PATH 0x%x; frame in flight / no TX clock?)",
				n, rd(&p->m0, PKTREC_M0_EFF_PATH));
			return -1;
		}
		usleep(1000);
	}
	return 0;
}

static void make_hold(struct rp *p)
{
	int fd;

	if (mkdir(RUN_DIR, 0755) && errno != EEXIST)
		return;
	snprintf(p->hold, sizeof(p->hold), RUN_DIR "/tb-hold.%d", (int)getpid());
	fd = open(p->hold, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
	if (fd < 0) {
		fprintf(stderr, "%s: warning: cannot create %s (%s): the timebase daemon may step the timebase during the replay\n",
			prog_name, p->hold, strerror(errno));
		return;
	}
	dprintf(fd, "pktrec-replay\n");
	close(fd);
	p->hold_made = true;
}

static void dev_close(struct rp *p)
{
	if (p->dev >= 0) {
		if (p->play_started) {
			struct fdrec_play_stats st;

			ioctl(p->dev, FDREC_IOC_PLAY_STOP, &st);
			p->play_started = false;
		}
		close(p->dev);      /* unregisters the buffers */
		p->dev = -1;
	}
}

static void cleanup(struct rp *p)
{
	if (p->rpl.p) {
		unsigned st = rpl_state(p);

		if (st != PKTREC_RPL_STATE_IDLE && st != PKTREC_RPL_STATE_DONE) {
			wr(&p->rpl, PKTREC_RPL_CMD, PKTREC_RPL_CMD_ABORT);
			for (int i = 0; i < 100 && rpl_state(p) != PKTREC_RPL_STATE_IDLE; i++)
				usleep(1000);
		}
	}
	dev_close(p);
	if (p->rpl.p)
		wr(&p->rpl, PKTREC_RPL_CTRL, 0);        /* stream back to the checker */
	if (p->path_set && !p->o.keep_path && p->m0.p) {
		unsigned n = (unsigned)p->o.port;
		uint32_t pc = rd(&p->m0, PKTREC_M0_PATH_CTRL) & ~(3u << PKTREC_M0_PATH_SHIFT(n));

		wr(&p->m0, PKTREC_M0_PATH_CTRL, pc | (p->old_path & (3u << PKTREC_M0_PATH_SHIFT(n))));
		wr(&p->m0, PKTREC_M0_PATH_RPL, rd(&p->m0, PKTREC_M0_PATH_RPL) & ~(1u << n));
	}
	if (p->hold_made)
		unlink(p->hold);
#ifndef PKTREC_NO_URING
	if (p->ring_ok)
		io_uring_queue_exit(&p->ring);
#endif
	if (p->mem)
		munmap(p->mem, p->mem_len);
	if (p->stage)
		free(p->stage);
	if (p->in >= 0)
		close(p->in);
}

static int open_device(struct rp *p)
{
	struct fdrec_info info;
	struct fdrec_bufs reg;
	uint64_t *addrs;
	unsigned i;

	p->dev = pktrec_open_dev(p->o.device, PKTREC_DEV_BUSY_WAIT_S, "a capture running?");
	if (p->dev < 0) {
		if (errno == EBUSY)
			err_msg("%s is still busy after %.0f s: the recorder serves one user at a time "
				"(a capture running? to replay during a capture, start pktrec-replay "
				"--preload --wait-capture first and pktrec-cap after it)",
				p->o.device, PKTREC_DEV_BUSY_WAIT_S);
		else if (errno == EACCES || errno == EPERM)
			err_msg("needs root (sudo): %s: permission denied", p->o.device);
		else
			perr("open %s", p->o.device);
		return -1;
	}
	if (ioctl(p->dev, FDREC_IOC_GET_INFO, &info) < 0) {
		perr("FDREC_IOC_GET_INFO");
		return -1;
	}
	if (!(info.caps & FDREC_CAP_MM2S)) {
		err_msg("%s has no playback channel (FDREC_CAP_MM2S)", p->o.device);
		return -1;
	}
	if (!p->mem) {
		p->mem_len = (size_t)p->o.buffers * p->o.buf_size;
		p->mem = mmap(NULL, p->mem_len, PROT_READ | PROT_WRITE,
			      MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB | MAP_HUGE_2MB | MAP_POPULATE,
			      -1, 0);
		if (p->mem == MAP_FAILED) {
			p->mem = NULL;
			err_msg("cannot allocate %u x %" PRIu64 " MB from 2 MB hugepages (%lu free): %s",
				p->o.buffers, p->o.buf_size >> 20, hugepages_free(), strerror(errno));
			return -1;
		}
	}
	addrs = calloc(p->o.buffers, sizeof(*addrs));
	if (!addrs)
		return -1;
	for (i = 0; i < p->o.buffers; i++)
		addrs[i] = (uint64_t)(uintptr_t)(p->mem + (size_t)i * p->o.buf_size);
	reg = (struct fdrec_bufs){ .addrs = (uint64_t)(uintptr_t)addrs,
				   .buf_size = p->o.buf_size, .count = p->o.buffers,
				   .flags = FDREC_DIR_PLAY };
	if (ioctl(p->dev, FDREC_IOC_REGISTER_BUFS, &reg) < 0) {
		perr("FDREC_IOC_REGISTER_BUFS (%u x %" PRIu64 " MB, playback)", p->o.buffers,
		     p->o.buf_size >> 20);
		free(addrs);
		return -1;
	}
	free(addrs);
	p->nfree = 0;
	for (i = 0; i < p->o.buffers; i++)
		p->freeq[p->nfree++] = (int)(p->o.buffers - 1 - i);
	p->cur = -1;
	p->fill = 0;
	p->inflight = 0;
	return 0;
}

static int play_start(struct rp *p)
{
	struct fdrec_play_start s = { .flags = 0 };   /* no checker: no recorder soft reset */

	if (ioctl(p->dev, FDREC_IOC_PLAY_START, &s) < 0) {
		perr("FDREC_IOC_PLAY_START");
		return -1;
	}
	p->play_started = true;
	return 0;
}

/* flush the partial buffer and wait until the DMA has read everything */
static int drain_dma(struct rp *p)
{
	if (submit_cur(p))
		return -1;
	while (p->inflight) {
		int r;

		if (g_stop)
			return -1;
		if (!p->go_done && !p->o.preload)
			prime_and_go(p);
		r = wait_done(p, 500);
		if (r < 0)
			return -1;
		if (!r && !p->o.quiet && p->go_done)
			report_progress(p, false);
	}
	return 0;
}

static int parse_args(int argc, char **argv, struct opts *o)
{
	static const struct option lo[] = {
		{ "iface", required_argument, NULL, 'i' },
		{ "port", required_argument, NULL, 'p' },
		{ "rate", required_argument, NULL, 'r' },
		{ "topspeed", no_argument, NULL, 't' },
		{ "gap", required_argument, NULL, 'g' },
		{ "loop", required_argument, NULL, 'l' },
		{ "start-delay", required_argument, NULL, 'd' },
		{ "keep-bad", no_argument, NULL, 'k' },
		{ "bad-as-good", no_argument, NULL, 'G' },
		{ "late-thresh", required_argument, NULL, 'L' },
		{ "preload", no_argument, NULL, 'P' },
		{ "wait-capture", required_argument, NULL, 'W' },
		{ "force", no_argument, NULL, 'f' },
		{ "keep-path", no_argument, NULL, 'K' },
		{ "buffers", required_argument, NULL, 'b' },
		{ "buf-size", required_argument, NULL, 'B' },
		{ "device", required_argument, NULL, 'D' },
		{ "devmem", no_argument, NULL, 'M' },
		{ "json", no_argument, NULL, 'j' },
		{ "dry-run", no_argument, NULL, 'n' },
		{ "quiet", no_argument, NULL, 'q' },
		{ "help", no_argument, NULL, 'h' },
		{ NULL, 0, NULL, 0 }
	};
	int c;
	uint64_t v;
	double d;

	*o = (struct opts){ .device = DEF_DEVICE, .iface = -1, .port = -1, .rate = 1.0,
			    .loops = 1, .start_delay_ms = 10.0, .bad_mode = PKTREC_RPL_BAD_SKIP,
			    .late_thresh = 100, .buffers = DEF_BUFFERS, .buf_size = DEF_BUF_SIZE };
	while ((c = getopt_long(argc, argv, "qh", lo, NULL)) != -1) {
		switch (c) {
		case 'i': {
			const char *s = optarg;

			if (*s == 'P' || *s == 'p')
				s++;
			if (s[0] < '0' || s[0] > '3' || s[1])
				return die_usage("--iface: P0..P3");
			o->iface = s[0] - '0';
			break;
		}
		case 'p': {
			const char *s = optarg;

			if (*s == 'P' || *s == 'p')
				s++;
			if (s[0] < '0' || s[0] > '3' || s[1])
				return die_usage("--port: 0..3");
			o->port = s[0] - '0';
			break;
		}
		case 'r':
			if (parse_double(optarg, &d) || d < 1.0 / 65536 || d > 65536)
				return die_usage("--rate: 1/65536 .. 65536");
			o->rate = d;
			break;
		case 't': o->topspeed = true; break;
		case 'g':
			if (parse_size(optarg, &v) || !v || v > 0xffffffffu)
				return die_usage("--gap: 1 .. 4294967295 ns");
			o->gap_ns = v;
			break;
		case 'l':
			if (parse_size(optarg, &v) || !v || v > 1000000)
				return die_usage("--loop: 1 .. 1000000");
			o->loops = (unsigned)v;
			break;
		case 'd':
			if (parse_double(optarg, &d) || d < 0 || d > 4000)
				return die_usage("--start-delay: 0 .. 4000 ms");
			o->start_delay_ms = d;
			break;
		case 'k': o->bad_mode = PKTREC_RPL_BAD_ERROR; break;
		case 'G': o->bad_mode = PKTREC_RPL_BAD_GOOD; break;
		case 'L':
			if (parse_size(optarg, &v) || v > 0xffffffffu)
				return die_usage("--late-thresh: ns");
			o->late_thresh = (uint32_t)v;
			break;
		case 'P': o->preload = true; break;
		case 'W':
			if (parse_double(optarg, &d) || d <= 0)
				return die_usage("--wait-capture: seconds > 0");
			o->wait_capture = d;
			break;
		case 'f': o->force = true; break;
		case 'K': o->keep_path = true; break;
		case 'b':
			if (parse_size(optarg, &v) || v < 2 || v > FDREC_MAX_BUFS)
				return die_usage("--buffers: 2 .. %d", FDREC_MAX_BUFS);
			o->buffers = (unsigned)v;
			break;
		case 'B':
			if (parse_size(optarg, &v) || !v || v % FDREC_BUF_ALIGN || v > FDREC_MAX_BUF_SIZE)
				return die_usage("--buf-size: a multiple of 2M");
			o->buf_size = v;
			break;
		case 'D': o->device = optarg; break;
		case 'M': o->devmem = true; break;
		case 'j': o->json = true; break;
		case 'n': o->dry_run = true; break;
		case 'q': o->quiet = true; break;
		case 'h': usage(stdout); exit(0);
		default: return die_usage("unknown option");
		}
	}
	if (optind != argc - 1)
		return die_usage("one capture file expected");
	o->input = argv[optind];
	if (o->iface < 0 || o->port < 0)
		return die_usage("--iface and --port are required");
	if ((o->topspeed && o->gap_ns) || ((o->topspeed || o->gap_ns) && o->rate != 1.0))
		return die_usage("--rate, --topspeed and --gap are alternatives");
	if (o->wait_capture && !o->preload)
		return die_usage("--wait-capture needs --preload");
	return 0;
}

/* ------------------------------------------------------------------------ */

/* Final summary from the replay block's counters; also printed when the replay
 * is aborted (SIGINT / SIGTERM) after the block was armed. -> true if lossless. */
static bool print_summary(struct rp *p, uint32_t mode, bool aborted)
{
	uint64_t frames = rd64(&p->rpl, PKTREC_RPL_FRAMES);
	uint64_t bytes = rd64(&p->rpl, PKTREC_RPL_BYTES);
	uint64_t recs = rd64(&p->rpl, PKTREC_RPL_RECORDS);
	uint64_t skip = rd64(&p->rpl, PKTREC_RPL_SKIPPED);
	uint64_t perr = rd64(&p->rpl, PKTREC_RPL_PARSE_ERRORS);
	uint64_t under = rd64(&p->rpl, PKTREC_RPL_UNDERRUNS);
	uint64_t late = rd64(&p->rpl, PKTREC_RPL_LATE);
	uint64_t lsum = rd64(&p->rpl, PKTREC_RPL_LATE_SUM);
	uint64_t bad = rd64(&p->rpl, PKTREC_RPL_BAD_SENT);
	uint32_t maxl = rd(&p->rpl, PKTREC_RPL_MAX_LATE);
	double mean = frames && mode != PKTREC_RPL_MODE_B2B ? (double)lsum / (double)frames : 0;
	double el = p->t_start > 0 ? now_s() - p->t_start : 0.0;
	bool ok = !aborted && !under && !perr && frames + skip == p->sel_records &&
		  recs == p->sel_records;

	if (p->o.json) {
		printf("{\"file\":\"%s\",\"iface\":%d,\"port\":%d,\"mode\":\"%s\",\"rate\":%g,"
		       "\"selected\":%" PRIu64 ",\"records\":%" PRIu64 ",\"frames\":%" PRIu64
		       ",\"bytes\":%" PRIu64 ",\"skipped\":%" PRIu64 ",\"bad_sent\":%" PRIu64
		       ",\"parse_errors\":%" PRIu64 ",\"underruns\":%" PRIu64 ",\"late\":%" PRIu64
		       ",\"late_thresh_ns\":%u,\"max_late_ns\":%u,\"mean_late_ns\":%.2f,"
		       "\"file_parse_errors\":%" PRIu64 ",\"seconds\":%.3f,\"aborted\":%s,\"ok\":%s}\n",
		       p->o.input, p->o.iface, p->o.port,
		       mode == PKTREC_RPL_MODE_B2B ? "topspeed" : mode == PKTREC_RPL_MODE_FIXED ? "gap" : "timed",
		       p->o.rate, p->sel_records, recs, frames, bytes, skip, bad, perr, under, late,
		       p->o.late_thresh, maxl, mean, p->file_perr, el, aborted ? "true" : "false",
		       ok ? "true" : "false");
	} else {
		printf("%s P%d of %s out of P%d (%s%s)\n", aborted ? "ABORTED: replay of" : "replayed",
		       p->o.iface, p->o.input, p->o.port,
		       mode == PKTREC_RPL_MODE_B2B ? "back to back" :
		       mode == PKTREC_RPL_MODE_FIXED ? "fixed gap" : "timed",
		       mode == PKTREC_RPL_MODE_TIMED && p->o.rate != 1.0 ? ", scaled" : "");
		printf("  selected     %" PRIu64 " records (%" PRIu64 " bytes), %u loop(s)%s\n",
		       p->sel_records, p->sel_bytes, p->o.loops,
		       aborted ? " (read from the file before the abort)" : "");
		printf("  sent         %" PRIu64 " frames, %" PRIu64 " bytes (+ FCS), %" PRIu64
		       " sent as errored, %" PRIu64 " skipped\n", frames, bytes, bad, skip);
		printf("  underruns    %" PRIu64 "%s\n", under,
		       under ? "  ** the stream could not keep up: frames went out late **" : "");
		if (mode != PKTREC_RPL_MODE_B2B)
			printf("  lateness     max %u ns, mean %.1f ns, %" PRIu64 " frames > %u ns\n",
			       maxl, mean, late, p->o.late_thresh);
		printf("  parse errors %" PRIu64 " (hardware), %" PRIu64 " (file)\n", perr, p->file_perr);
		printf("  duration     %.3f s\n", el);
	}
	return ok;
}

int main(int argc, char **argv)
{
	struct rp rp = { .in = -1, .dev = -1, .cur = -1 };
	struct rp *p = &rp;
	struct pktrec_file_header fh;
	struct stat sb;
	uint32_t mode = 0, ctrl, ver;
	int ret = 1;
	bool armed = false;
	unsigned loop;

	if (parse_args(argc, argv, &p->o))
		return 1;
	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);

	/* ---- capture file ---- */
	p->in = open(p->o.input, O_RDONLY | O_CLOEXEC);
	if (p->in < 0) {
		perr("open %s", p->o.input);
		goto out;
	}
	if (pktrec_read_header(p->in, p->o.input, &fh))
		goto out;
	if (fstat(p->in, &sb)) {
		perr("stat %s", p->o.input);
		goto out;
	}
	p->data_bytes = (fh.flags & PKTREC_FILE_FLAG_COMPLETE) ? fh.data_bytes :
			(uint64_t)(sb.st_size > HDR_SIZE ? sb.st_size - HDR_SIZE : 0);
	if (p->data_bytes > (uint64_t)sb.st_size - HDR_SIZE)
		p->data_bytes = (uint64_t)sb.st_size - HDR_SIZE;
	p->data_bytes &= ~15ull;
	if (!p->data_bytes) {
		err_msg("%s: no records", p->o.input);
		goto out;
	}
	if (!(fh.port_mask & (1u << p->o.iface)))
		fprintf(stderr, "%s: warning: P%d was not enabled in this capture (port mask 0x%x)\n",
			prog_name, p->o.iface, fh.port_mask);
	if ((fh.pair_mode >> (p->o.iface / 2)) & 1)
		fprintf(stderr, "%s: note: TAP-mode capture: P%d holds the direction received on P%d only (the frames P%d forwarded); the other direction is interface P%d\n",
			prog_name, p->o.iface, p->o.iface, p->o.iface, p->o.iface ^ 1);
	close(p->in);
	p->in = open(p->o.input, O_RDONLY | O_DIRECT | O_CLOEXEC);
	if (p->in < 0) {
		perr("open %s with O_DIRECT", p->o.input);
		goto out;
	}
	p->nchunks = (p->data_bytes + STAGE_SIZE - 1) / STAGE_SIZE;
	if (posix_memalign((void **)&p->stage, 4096, (size_t)NSTAGE * STAGE_SIZE)) {
		p->stage = NULL;
		err_msg("out of memory");
		goto out;
	}
#ifndef PKTREC_NO_URING
	if (io_uring_queue_init(NSTAGE * 2, &p->ring, 0) < 0) {
		err_msg("io_uring_queue_init failed (CONFIG_IO_URING?)");
		goto out;
	}
	p->ring_ok = true;
#endif
	p->freeq = calloc(p->o.buffers, sizeof(int));
	if (!p->freeq)
		goto out;

	if (p->o.dry_run) {
		for (loop = 0; loop < p->o.loops; loop++) {
			if (loop == 1)
				p->ts_off = (p->last_ts - p->first_ts) +
					    (p->sel_records > 1 ? (p->last_ts - p->first_ts) / (p->sel_records - 1) : 1000000);
			else if (loop > 1)
				p->ts_off += p->ts_off / (loop - 1);
			if (stream_pass(p) < 0)
				goto out;
			if (p->preload_full)
				break;
		}
		printf("%s: %" PRIu64 " records in the file (%" PRIu64 " framing errors), P%d: %" PRIu64
		       " records, %" PRIu64 " frame bytes, %" PRIu64 " stream bytes, span %.6f s%s\n",
		       p->o.input, p->file_records, p->file_perr, p->o.iface, p->sel_records, p->sel_bytes,
		       p->streamed_bytes, p->have_ts ? (double)(p->last_ts - p->first_ts) / 1e9 : 0.0,
		       p->preload_full ? " (preload: store full)" : "");
		ret = p->sel_records ? 0 : 2;
		goto out;
	}

	/* ---- hardware ---- */
	if (regs_map(&p->rpl, PKTREC_RPL_BASE, PKTREC_RPL_SIZE, p->o.devmem, "replay") ||
	    regs_map(&p->m0, PKTREC_M0_BASE, PKTREC_M0_SIZE, p->o.devmem, "port datapath"))
		goto out;
	p->have_cap = !regs_map(&p->cap, PKTREC_CAP_BASE, PKTREC_CAP_SIZE, p->o.devmem, "capture");
	if (rd(&p->rpl, PKTREC_RPL_ID) != PKTREC_RPL_ID_VALUE) {
		err_msg("no replay block at 0x%llx (ID 0x%08x)", (unsigned long long)PKTREC_RPL_BASE,
			rd(&p->rpl, PKTREC_RPL_ID));
		goto out;
	}
	ver = rd(&p->rpl, PKTREC_RPL_VERSION);
	if ((ver >> 16) != 1) {
		err_msg("replay block VERSION 0x%08x not supported", ver);
		goto out;
	}
	if (p->o.wait_capture && !p->have_cap)
		goto out;
	if (check_paths(p))
		goto out;
	make_hold(p);
	if (set_path(p))
		goto out;

	mode = p->o.topspeed ? PKTREC_RPL_MODE_B2B : p->o.gap_ns ? PKTREC_RPL_MODE_FIXED :
	       PKTREC_RPL_MODE_TIMED;
	ctrl = PKTREC_RPL_CTRL_SEL | (mode << PKTREC_RPL_CTRL_MODE_SHIFT) |
	       ((uint32_t)p->o.bad_mode << PKTREC_RPL_CTRL_BAD_SHIFT) |
	       PKTREC_RPL_CTRL_FILTER_EN | ((uint32_t)p->o.iface << PKTREC_RPL_CTRL_FILTER_SHIFT) |
	       ((uint32_t)p->o.port << PKTREC_RPL_CTRL_TXPORT_SHIFT);
	wr(&p->rpl, PKTREC_RPL_CTRL, ctrl);
	wr(&p->rpl, PKTREC_RPL_RATE_INV, (uint32_t)lround(65536.0 / p->o.rate));
	wr(&p->rpl, PKTREC_RPL_GAP_NS, (uint32_t)p->o.gap_ns);
	wr(&p->rpl, PKTREC_RPL_START_DELAY, (uint32_t)llround(p->o.start_delay_ms * 1e6));
	wr(&p->rpl, PKTREC_RPL_LATE_THRESH, p->o.late_thresh);
	wr(&p->rpl, PKTREC_RPL_EXPECT_LO, 0);
	wr(&p->rpl, PKTREC_RPL_EXPECT_HI, 0);
	usleep(1000);                   /* SEL reaches the egress side */
	wr(&p->rpl, PKTREC_RPL_CMD, PKTREC_RPL_CMD_ARM);
	armed = true;

	if (open_device(p) || play_start(p))
		goto out;

	/* ---- stream ---- */
	for (loop = 0; loop < p->o.loops; loop++) {
		int r;

		if (loop == 1) {
			uint64_t span = p->last_ts - p->first_ts;
			uint64_t n = p->sel_records;

			/* one mean interval between the last frame and the next loop */
			p->ts_off = span + (n > 1 ? span / (n - 1) : 1000000);
		} else if (loop > 1) {
			p->ts_off += p->ts_off / (loop - 1);
		}
		r = stream_pass(p);
		if (r < 0)
			goto out;
		if (loop == 0 && !p->sel_records) {
			err_msg("%s: no records of P%d (%" PRIu64 " records in the file)", p->o.input,
				p->o.iface, p->file_records);
			goto out;
		}
		if (r == 1)
			break;          /* --preload: the store is full */
	}
	if (p->preload_full)
		fprintf(stderr, "%s: --preload: the store holds the first %" PRIu64 " frames (%" PRIu64
			" KB); the rest is not replayed\n", prog_name, p->sel_records,
			p->pre_beats * 16 / 1024);
	if (drain_dma(p))
		goto out;

	if (p->o.preload) {
		double t0 = now_s();

		/* every frame is in the store: release the DMA for a capture */
		wr(&p->rpl, PKTREC_RPL_EXPECT_LO, (uint32_t)p->sel_records);
		wr(&p->rpl, PKTREC_RPL_EXPECT_HI, (uint32_t)(p->sel_records >> 32));
		while (rd64(&p->rpl, PKTREC_RPL_RECORDS_DONE) < p->sel_records) {
			if (now_s() - t0 > 1.0 || g_stop) {
				err_msg("--preload: only %u of %" PRIu64 " frames reached the store",
					rd(&p->rpl, PKTREC_RPL_STORE_LEVEL) >> 16, p->sel_records);
				goto out;
			}
			usleep(1000);
		}
		dev_close(p);
		if (p->o.wait_capture) {
			t0 = now_s();
			if (!p->o.quiet)
				fprintf(stderr, "%s: %" PRIu64 " frames preloaded; waiting for a capture to start\n",
					prog_name, p->sel_records);
			while (!(rd(&p->cap, PKTREC_CAP_CTRL) & PKTREC_CAP_CTRL_ENABLE)) {
				if (now_s() - t0 > p->o.wait_capture || g_stop) {
					err_msg("no capture started within %.1f s", p->o.wait_capture);
					goto out;
				}
				usleep(1000);
			}
		}
		prime_and_go(p);
	} else {
		/* every buffer is read by the DMA: no more input */
		wr(&p->rpl, PKTREC_RPL_CMD, PKTREC_RPL_CMD_STOP);
	}

	/* ---- wait for the end ---- */
	{
		double t_idle = 0;
		uint64_t last_frames = (uint64_t)-1;

		while (rpl_state(p) != PKTREC_RPL_STATE_DONE) {
			uint32_t st = rd(&p->rpl, PKTREC_RPL_STATUS);
			uint64_t f = rd64(&p->rpl, PKTREC_RPL_FRAMES);

			if (g_stop)
				goto out;
			if ((st & PKTREC_RPL_ST_STATE_MASK) != PKTREC_RPL_STATE_RUNNING) {
				err_msg("replay block left RUNNING (status 0x%08x)", st);
				goto out;
			}
			/* nothing stored, nothing scheduled, no progress: the end
			 * condition cannot be met (lost records) */
			if (f == last_frames && !(st & (PKTREC_RPL_ST_STORE_FRAMES | PKTREC_RPL_ST_SCHED_BUSY))) {
				if (!t_idle)
					t_idle = now_s();
				else if (now_s() - t_idle > 5.0) {
					err_msg("replay stalled: %" PRIu64 " of %" PRIu64 " frames sent, store empty",
						f, p->sel_records);
					break;
				}
			} else {
				t_idle = 0;
			}
			last_frames = f;
			if (!p->o.quiet)
				report_progress(p, false);
			usleep(20000);
		}
	}
	if (!p->o.quiet)
		report_progress(p, true);

	/* ---- summary ---- */
	ret = print_summary(p, mode, false) ? 0 : 2;
out:
	if (armed && g_stop) {
		/* interrupted: report what was sent before the block is stopped */
		if (!p->o.quiet)
			report_progress(p, true);
		print_summary(p, mode, true);
		fflush(stdout);
	}
	cleanup(p);
	return ret;
}
