#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Opsero Electronic Design Inc.
#
# board_pktgen.sh - sequence-numbered test traffic from the Linux kernel packet
# generator (pktgen). Runs on the board (installed as /usr/bin/pktrec-pktgen;
# CONFIG_NET_PKTGEN=y in the reference image) or on any Linux test machine
# with the pktgen module. Needs root.
#
# pktgen puts its own header at the start of the UDP payload:
#   magic 0xbe9be955 | sequence number (u32, +1 per frame) | tv_sec | tv_usec
# check_pcap.py recognises it (stream = source MAC + UDP source port).
#
# clone_skb and burst are forced to 1: a cloned/burst skb is sent unchanged,
# i.e. with the same sequence number, which would look like duplicates.
#
# Usage: board_pktgen.sh -i <iface> -d <dst-mac> [-s <size>] [-c <count>]
#                        [-r <Mb/s> | -p <frames/s>] [-D <dst-ip>] [-S <src-ip>]
#                        [-u <udp-port>] [-o <summary.json>] [-C <cpu>]
#   -s  frame size on the wire incl. FCS, 64..1518 (default 64)
#   -c  frames to send (default 1000000; 0 = until stopped with Ctrl-C)
#   -r  rate in Mb/s on the wire (pktgen "rate"), -p rate in frames/s ("ratep");
#       neither = as fast as the CPU and NIC go
#   -o  write a JSON summary for check_pcap.py --sent
#   -C  CPU whose pktgen thread is used (default 0)
#
# Line rate at 1 Gb/s: 64 B = 1 488 095 frames/s, 1518 B = 81 274 frames/s.
# Without clone_skb, one A53 core of the ZCU106 builds every skb itself:
# expect it to reach 1518-byte line rate but NOT 64-byte line rate from the
# board's GEM (measure it; the summary prints the achieved rate). For 64-byte
# line rate use a PC (this script, or tcpreplay with gen_seq.py --mode pcap).
#
# Examples (board, frames flood through the router to OP080 P0 when the
# destination MAC is unknown to the switch):
#   sudo pktrec-pktgen -i end0 -d 02:00:00:00:00:99 -s 1518 -c 1000000
#   sudo pktrec-pktgen -i end0 -d 02:00:00:00:00:99 -s 64 -c 1000000 -p 100000

set -e

IFACE=
DST_MAC=
SIZE=64
COUNT=1000000
RATE_MBPS=
RATE_PPS=
DST_IP=192.0.2.2
SRC_IP=192.0.2.1
UDP_PORT=9
SUMMARY=
CPU=0

die() { echo "board_pktgen: $*" >&2; exit 1; }

while getopts "i:d:s:c:r:p:D:S:u:o:C:h" opt; do
	case "$opt" in
	i) IFACE=$OPTARG ;;
	d) DST_MAC=$OPTARG ;;
	s) SIZE=$OPTARG ;;
	c) COUNT=$OPTARG ;;
	r) RATE_MBPS=$OPTARG ;;
	p) RATE_PPS=$OPTARG ;;
	D) DST_IP=$OPTARG ;;
	S) SRC_IP=$OPTARG ;;
	u) UDP_PORT=$OPTARG ;;
	o) SUMMARY=$OPTARG ;;
	C) CPU=$OPTARG ;;
	h) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) die "bad option (see -h)" ;;
	esac
done

[ -n "$IFACE" ] || die "-i <iface> is required"
[ -n "$DST_MAC" ] || die "-d <dst-mac> is required"
[ -d "/sys/class/net/$IFACE" ] || die "no interface $IFACE"
[ "$SIZE" -ge 64 ] && [ "$SIZE" -le 1518 ] || die "-s must be 64..1518"
[ "$(id -u)" -eq 0 ] || die "must run as root"
if [ ! -d /proc/net/pktgen ]; then
	modprobe pktgen 2>/dev/null || true
fi
[ -d /proc/net/pktgen ] || die "pktgen not available (CONFIG_NET_PKTGEN)"

PG=/proc/net/pktgen
THR=$PG/kpktgend_$CPU
DEV=$PG/$IFACE
[ -e "$THR" ] || die "no pktgen thread for CPU $CPU"

# write one command, fail on a pktgen error
pgset() {
	echo "$2" > "$1"
	if grep -q "Result: " "$1" && ! grep -q "Result: OK" "$1"; then
		r=$(grep "Result: " "$1")
		die "pktgen rejected '$2' ($1): $r"
	fi
}

PKT_SIZE=$((SIZE - 4))          # pktgen pkt_size excludes the FCS
SRC_MAC=$(cat "/sys/class/net/$IFACE/address")

# Stop anything left over and bind the interface to one thread
echo stop > $PG/pgctrl 2>/dev/null || true
for t in $PG/kpktgend_*; do pgset "$t" "rem_device_all"; done
pgset "$THR" "add_device $IFACE"

pgset "$DEV" "count $COUNT"
pgset "$DEV" "clone_skb 0"
pgset "$DEV" "burst 1"
pgset "$DEV" "pkt_size $PKT_SIZE"
pgset "$DEV" "dst_mac $DST_MAC"
pgset "$DEV" "dst $DST_IP"
pgset "$DEV" "src_min $SRC_IP"
pgset "$DEV" "src_max $SRC_IP"
pgset "$DEV" "udp_src_min $UDP_PORT"
pgset "$DEV" "udp_src_max $UDP_PORT"
pgset "$DEV" "udp_dst_min $UDP_PORT"
pgset "$DEV" "udp_dst_max $UDP_PORT"
if [ -n "$RATE_PPS" ]; then
	pgset "$DEV" "ratep $RATE_PPS"
elif [ -n "$RATE_MBPS" ]; then
	pgset "$DEV" "rate $RATE_MBPS"
else
	pgset "$DEV" "delay 0"
fi

if [ -n "$RATE_PPS" ]; then RATE_DESC="$RATE_PPS frames/s"
elif [ -n "$RATE_MBPS" ]; then RATE_DESC="$RATE_MBPS Mb/s"
else RATE_DESC="max rate"; fi
echo "board_pktgen: $IFACE -> $DST_MAC: $COUNT frames of $SIZE B at $RATE_DESC" >&2
trap 'echo stop > $PG/pgctrl' INT TERM
echo start > $PG/pgctrl         # blocks until count frames are sent (or stop)
trap - INT TERM

RESULT=$(grep -A2 "Result:" "$DEV" | tr -s ' \n' ' ')
echo "board_pktgen: $RESULT" >&2
SENT=$(sed -n 's/.*sofar: \([0-9]*\).*/\1/p' "$DEV" | head -n 1)
PPS=$(echo "$RESULT" | sed -n 's/.* \([0-9]*\)pps.*/\1/p')
[ -n "$SENT" ] || SENT=$COUNT

if [ -n "$SUMMARY" ]; then
	cat > "$SUMMARY" <<JSON
{
 "generator": "board_pktgen.sh",
 "interface": "$IFACE",
 "size": $SIZE,
 "rate_pps": ${PPS:-0},
 "streams": [ { "key": "pktgen:$SRC_MAC:$UDP_PORT", "first": null, "count": $SENT } ]
}
JSON
	echo "board_pktgen: summary in $SUMMARY" >&2
fi
pgset "$THR" "rem_device_all"
echo "SENT $SENT"
