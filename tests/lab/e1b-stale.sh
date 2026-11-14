#!/bin/bash
# PC only (WSL, root). The second half of the question "does a kept network configuration help when the controller
# cannot be reached": what if the kept one is OLD? Every member of a private network carries a pass issued by the
# controller; two members talk only while the issue times of their passes are within a window (30 minutes on the
# user's network and on the lab's controller). Here A's configuration is kept, A is switched off, the other member
# stays in touch with the controller for longer than the window, then the controller goes away and A comes back with
# the kept configuration.
# usage: e1b-stale.sh <24.10|25.12> [minutes A stays off, default 34]      about 40 minutes
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
ver=${1:-25.12}; mins=${2:-34}
export ZT_LAB_NAME=stale${ver//./}
. "$here/lab.sh"
say() { echo "[$(date +%H:%M:%S)] $*"; }
hex2s() { echo $(( 16#${1:-0} / 1000 )); }
say "=== old kept configuration, ZeroTier of OpenWrt $ver"
lab_base || { say "LAB BROKEN"; lab_down; exit 1; }
lab_first_start A "$ver"; lab_stock_start A; sleep 6
lab_ctl POST "/controller/network/$NW/member/$(lab_addr A)" '{"authorized":true}' >/dev/null
lab_wait 90 "A is in the network" lab_has_ok A; lab_wait 90 "B is in the network" lab_has_ok B
A_IP=$(lab_zt_ip A)
lab_wait 60 "B reaches A (ping)" lab_ping_from_b "$A_IP" || { say "LAB BROKEN: no baseline ping"; lab_down; exit 1; }
F=$N/A/home/networks.d/$NW.conf
cp "$F" "$N/A/cache.old"
w=$(hex2s "$(lab_key "$F" ctmd)")
say "A's configuration kept; the pass window is $w s. A is switched off for $mins minutes; B stays with the controller"
lab_stop A
sleep $(( mins * 60 ))
FB=$N/B/home/networks.d/$NW.conf
d=$(( $(hex2s "$(lab_key "$FB" ts)") - $(hex2s "$(lab_key "$N/A/cache.old" ts)") ))
say "B's pass is now $d s newer than the one in A's kept configuration (window $w s)"
lab_stop C; sleep 3
lab_stock_start A "$N/A/cache.old"
lab_wait 60 "A has status OK and its address from the old kept configuration" lab_has_ok A
sleep 30
say "FINDING S1 controller unreachable, kept configuration $d s older than the other member's (window $w s): status=$(lab_st A), address=$(lab_zt_ip A), on the interface=$(lab_dev_addr); ping from B: $(lab_ping_from_b "$A_IP" && echo works || echo fails)"
sleep 60
say "FINDING S2 a minute and a half later: ping from B: $(lab_ping_from_b "$A_IP" && echo works || echo fails)"
lab_start C 24.10
lab_wait 60 "controller is back" lab_online C
lab_wait 180 "B reaches A again (ping)" lab_ping_from_b "$A_IP" && say "FINDING S3 once the controller answers again, access returns by itself (no restart)"
lab_down
say E1B_DONE
