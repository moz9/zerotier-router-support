#!/bin/bash
# PC only (WSL, root). How long does ZeroTier itself need to notice that it is cut off from everything?
# A (ZeroTier 1.16.2) and B (1.14.1) are healthy members; then both cables are pulled and each node is asked every
# ten seconds what it thinks: its own state (ONLINE/OFFLINE) and whether it still shows a live path to the root.
# usage: e3-cut.sh      about 12 minutes
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
export ZT_LAB_NAME=cut
. "$here/lab.sh"
say() { echo "[$(date +%H:%M:%S)] $*"; }
lab_base || { say "LAB BROKEN"; lab_down; exit 1; }
lab_first_start A 25.12; lab_stock_start A; sleep 6
lab_ctl POST "/controller/network/$NW/member/$(lab_addr A)" '{"authorized":true}' >/dev/null
lab_wait 90 "A is in the network" lab_has_ok A; lab_wait 90 "B is in the network" lab_has_ok B
sleep 60
state() { lab_cli "$1" info 2>/dev/null | awk '{print $5}'; }
root() { lab_cli "$1" peers 2>/dev/null | awk '($3=="MOON"||$3=="PLANET") && $5=="DIRECT" && $4>=0 {ok=1} END{print ok?"live":"stale"}'; }
say "before: A $(state A)/root $(root A), B $(state B)/root $(root B)"
lab_isolate A; lab_isolate B
t0=$(date +%s); a_root=''; a_off=''; b_root=''; b_off=''
while [ $(( $(date +%s) - t0 )) -lt 660 ]; do
	t=$(( $(date +%s) - t0 ))
	[ -n "$a_root" ] || { [ "$(root A)" = stale ] && a_root=$t; }
	[ -n "$a_off" ] || { [ "$(state A)" = OFFLINE ] && a_off=$t; }
	[ -n "$b_root" ] || { [ "$(root B)" = stale ] && b_root=$t; }
	[ -n "$b_off" ] || { [ "$(state B)" = OFFLINE ] && b_off=$t; }
	[ -n "$a_off" ] && [ -n "$b_off" ] && [ -n "$a_root" ] && [ -n "$b_root" ] && break
	sleep 10
done
say "FINDING C1 ZeroTier 1.16.2 after the cut: root path shown as dead after ${a_root:-more than 660} s, node says OFFLINE after ${a_off:-more than 660} s"
say "FINDING C2 ZeroTier 1.14.1 after the cut: root path shown as dead after ${b_root:-more than 660} s, node says OFFLINE after ${b_off:-more than 660} s"
lab_down
say E3_DONE
