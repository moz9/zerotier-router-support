#!/bin/bash
# PC only (WSL, root). What does ZeroTier keep, and does a node use a kept network configuration when the
# controller cannot be reached? Asked of the routers' own programs: ZeroTier 1.14.1 (OpenWrt 24.10) and
# 1.16.2 (OpenWrt 25.12), run in the closed lab of lab.sh. The controller, the stand-in root and the second member
# always run 1.14.1 (the 1.16.2 package has no controller); the node under test (A) runs the version asked for.
# A is started the way the stock /etc/init.d/zerotier starts it: state directory emptied, an empty <network>.conf,
# the four allow* lines, the identity written from a saved copy.
# usage: e1-cache.sh <24.10|25.12>     about 20 minutes; prints findings as "FINDING ..." lines
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lab.sh"
ver=${1:-25.12}
say() { echo "[$(date +%H:%M:%S)] $*"; }
key() { grep -a "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2-; }   # one key of a kept network configuration
hex2s() { echo $(( 16#${1:-0} / 1000 )); }

net_json() { lab_cli "$1" -j listnetworks 2>/dev/null; }
st() { net_json "$1" | jq -r '.[0].status // "-"' 2>/dev/null; }
addr() { net_json "$1" | jq -r '.[0].assignedAddresses[0] // "-"' 2>/dev/null | cut -d/ -f1; }
has_ok() { [ "$(st "$1")" = OK ] && [ "$(addr "$1")" != "-" ]; }
online() { lab_cli "$1" info 2>/dev/null | grep -q ' ONLINE'; }
ping_ab() { ip netns exec "$NS-B" ping -c 3 -W 2 -q "$1" >/dev/null 2>&1; }
dev_addr() { ip -n "$NS-A" -o -4 addr show 2>/dev/null | awk '$2 ~ /^zt/ {print $4}' | head -1; }

# the stock init script's start, for node $1; $2 = a kept configuration to put in place first ("" = none)
stock_start() {
	local n=$1 seed=${2:-} H=$N/$1/home
	lab_stop "$n"
	rm -rf "$H"/* "$H"/.[!.]* 2>/dev/null
	mkdir -p "$H/networks.d" "$H/moons.d"
	cp "$N/M/home/moons.d/"*.moon "$H/moons.d/"            # lab plumbing: where our stand-in root lives
	cp "$N/$n/identity.secret" "$H/identity.secret"
	if [ -n "$seed" ]; then cp "$seed" "$H/networks.d/$NW.conf"; else : > "$H/networks.d/$NW.conf"; fi
	printf 'allowManaged=1\nallowGlobal=0\nallowDefault=0\nallowDNS=0\n' > "$H/networks.d/$NW.local.conf"
	lab_start "$n" "$(cat "$N/$n/root")"
}
first_start() {  # a node's very first start: lets it make its identity, then keeps a copy (the router keeps it in UCI)
	local n=$1 r=$2 H=$N/$1/home
	echo "$r" > "$N/$n/root"
	mkdir -p "$H/moons.d"; [ "$n" = M ] || cp "$N/M/home/moons.d/"*.moon "$H/moons.d/"
	lab_start "$n" "$r"
	lab_wait 40 "$n has an identity" test -s "$H/identity.secret"
	cp "$H/identity.secret" "$N/$n/identity.secret"
}
dummy_deauth() {  # authorise and de-authorise a member that does not exist: the controller then issues short-lived passes
	lab_ctl POST "/controller/network/$NW/member/$1" '{"authorized":true}' >/dev/null
	sleep 1
	lab_ctl POST "/controller/network/$NW/member/$1" '{"authorized":false}' >/dev/null
}

say "=== ZeroTier of OpenWrt $ver in the lab"
lab_up
first_start M 24.10
lab_in M 24.10 'cd /var/lib/zerotier-one && zerotier-idtool initmoon identity.public > moon.json && sed -i "s#\"stableEndpoints\": \[\]#\"stableEndpoints\": [\"10.99.0.1/9993\"]#" moon.json && zerotier-idtool genmoon moon.json >/dev/null && mkdir -p moons.d && mv *.moon moons.d/' >/dev/null 2>&1
lab_stop M; lab_start M 24.10
first_start C 24.10
lab_wait 60 "controller is ONLINE through the stand-in root" online C || { say "LAB BROKEN"; lab_down; exit 1; }
NW=$(lab_ctl POST "/controller/network/$(lab_addr C)______" '{"name":"guard-lab","private":true,"v4AssignMode":{"zt":true},"ipAssignmentPools":[{"ipRangeStart":"10.244.0.10","ipRangeEnd":"10.244.0.200"}],"routes":[{"target":"10.244.0.0/24"}]}' | jq -r .id)
say "lab network created on the controller: ${NW:0:6}… (private)"
first_start B 24.10
first_start A "$ver"
say "A runs: $(lab_cli A info | awk '{print $4}')"
stock_start B; stock_start A
sleep 6
for n in A B; do lab_ctl POST "/controller/network/$NW/member/$(lab_addr $n)" '{"authorized":true}' >/dev/null; done
lab_wait 90 "A is in the network with an address" has_ok A
lab_wait 90 "B is in the network with an address" has_ok B
A_IP=$(addr A); B_IP=$(addr B)
lab_wait 60 "B reaches A through ZeroTier (ping)" ping_ab "$A_IP" && say "FINDING 0 baseline: A status=$(st A) address on its interface=$(dev_addr), ping from B works"

F=$N/A/home/networks.d/$NW.conf
say "--- 1. what the daemon keeps in its state directory (RAM on the routers)"
say "FINDING 1 entries: $(cd "$N/A/home" && ls -A | sed -E 's/[0-9a-f]{10,16}/<id>/g' | tr '\n' ' ')"
say "FINDING 1 networks.d: $(ls "$N/A/home/networks.d" | sed -E 's/[0-9a-f]{16}/<network>/g' | tr '\n' ' '); peers.d: $(ls "$N/A/home/peers.d" 2>/dev/null | wc -l) files"
say "FINDING 1 <network>.conf: $(stat -c %s "$F") bytes, keys: $(sed 's/=.*//' "$F" | grep -aE '^[A-Za-z0-9]{1,8}$' | tr '\n' ' ')"
say "FINDING 1 pass validity window (ctmd) = $(hex2s "$(key "$F" ctmd)") s; type t=$(key "$F" t) (0 = private)"

say "--- 2. how often the kept configuration changes while nothing changes in the network (3 minutes)"
cp "$F" "$N/A/conf.first"; n_ts=0; last=
for i in $(seq 1 18); do t=$(key "$F" ts); [ "$t" != "$last" ] && n_ts=$((n_ts + 1)); last=$t; sleep 10; done
changed=$(for k in $(sed 's/=.*//' "$F" | grep -aE '^[A-Za-z0-9]{1,8}$'); do [ "$(key "$F" "$k")" = "$(key "$N/A/conf.first" "$k")" ] || printf '%s ' "$k"; done)
say "FINDING 2 in 180 s the file was rewritten with a new timestamp $((n_ts - 1)) times; keys that changed: ${changed:-none}"

say "--- 3. controller unreachable, A restarted the stock way (state emptied): no kept configuration"
cp "$F" "$N/A/cache.fresh"
lab_stop C
sleep 3
ping_ab "$A_IP" && say "FINDING 3a while A keeps running, it stays reachable without the controller (configuration is in its memory)"
stock_start A
lab_wait 20 "A answers" lab_cli A info
sleep 60
say "FINDING 3b after a restart without the controller: node $(lab_cli A info | awk '{print $5}'), network status=$(st A), address=$(addr A), interface address=$(dev_addr || true); ping from B: $(ping_ab "$A_IP" && echo works || echo fails); conf file is $(stat -c %s "$F") bytes"

say "--- 4. controller still unreachable, A restarted with the configuration kept a few minutes ago put back"
t0=$(date +%s)
stock_start A "$N/A/cache.fresh"
lab_wait 60 "A has status OK and its address from the kept configuration" has_ok A
t1=$(date +%s)
lab_wait 60 "B reaches A (ping)" ping_ab "$A_IP"; r=$?
say "FINDING 4 kept configuration $(( t0 - $(date -r "$N/A/cache.fresh" +%s) )) s old: status=$(st A), address=$(addr A) after $((t1 - t0)) s, interface=$(dev_addr); ping from B: $([ $r = 0 ] && echo works || echo fails)"

say "--- 5. the kept configuration is older than the pass validity window (controller issues short passes here)"
lab_start C 24.10
lab_wait 60 "controller is back" online C
dummy_deauth 1111111111
sleep 75
lab_wait 60 "A refreshed" has_ok A
cp "$F" "$N/A/cache.stale"
w=$(hex2s "$(key "$N/A/cache.stale" ctmd)")
say "A's kept configuration now carries a pass with a window of $w s; A is stopped, B stays in touch with the controller"
lab_stop A
wait_s=$((w + 100)); [ "$wait_s" -gt 900 ] && wait_s=900
sleep $((wait_s - 80))
dummy_deauth 2222222222
sleep 80
FB=$N/B/home/networks.d/$NW.conf
say "B's pass now: window $(hex2s "$(key "$FB" ctmd)") s, issued $(( $(hex2s "$(key "$FB" ts)") - $(hex2s "$(key "$N/A/cache.stale" ts)") )) s after A's kept one"
lab_stop C
sleep 3
t0=$(date +%s)
stock_start A "$N/A/cache.stale"
lab_wait 60 "A has status OK and its address from the old kept configuration" has_ok A
sleep 25
say "FINDING 5 kept configuration older than the window, controller unreachable: status=$(st A), address=$(addr A), interface=$(dev_addr); ping from B: $(ping_ab "$A_IP" && echo works || echo fails)"
lab_start C 24.10
lab_wait 60 "controller is back" online C
lab_wait 150 "after the controller is back B reaches A again (ping)" ping_ab "$A_IP" && say "FINDING 5b access returns by itself once the controller is reachable again"

say "--- 6. no ZeroTier server reachable at all (A's cable pulled), A restarted with a kept configuration"
cp "$F" "$N/A/cache.fresh2"
lab_isolate A
stock_start A "$N/A/cache.fresh2"
lab_wait 30 "A answers" lab_cli A info
sleep 20
say "FINDING 6 isolated: node $(lab_cli A info | awk '{print $5}'), network status=$(st A), address=$(addr A), interface=$(dev_addr)"
lab_connect A
lab_wait 90 "cable back: B reaches A (ping)" ping_ab "$A_IP" && say "FINDING 6b after the cable is back A is reachable without a restart"

say "--- 7. damaged kept configurations, controller unreachable"
lab_stop C; sleep 2
head -c 40 /dev/urandom > "$N/A/cache.garbage"
head -c $(( $(stat -c %s "$N/A/cache.fresh2") * 6 / 10 )) "$N/A/cache.fresh2" > "$N/A/cache.cut"
sed 's/^nwid=.*/nwid=00000000deadbeef/' "$N/A/cache.fresh2" > "$N/A/cache.othernet"
for c in garbage cut othernet; do
	stock_start A "$N/A/cache.$c"
	lab_wait 30 "A answers" lab_cli A info >/dev/null
	sleep 15
	say "FINDING 7 $c: daemon $(lab_cli A info >/dev/null 2>&1 && echo alive || echo DEAD), network status=$(st A), address=$(addr A), interface=$(dev_addr); file afterwards: $(stat -c %s "$F") bytes"
done

say "--- 8. the controller refuses the node (member de-authorised)"
lab_start C 24.10
lab_wait 60 "controller is back" online C
stock_start A "$N/A/cache.fresh2"
lab_wait 90 "A back in the network" has_ok A
lab_ctl POST "/controller/network/$NW/member/$(lab_addr A)" '{"authorized":false}' >/dev/null
lab_wait 150 "A learns it was refused" bash -c ". $here/lab.sh; [ \"\$(lab_cli A -j listnetworks | jq -r '.[0].status')\" = ACCESS_DENIED ]"
say "FINDING 8 refused: status=$(st A), address=$(addr A), interface=$(dev_addr); conf file $(stat -c %s "$F") bytes, still has a pass: $(grep -ac '^C=' "$F")"
cp "$F" "$N/A/cache.denied" 2>/dev/null
lab_stop C; sleep 2
stock_start A "$N/A/cache.fresh2"
lab_wait 30 "A answers" lab_cli A info >/dev/null; sleep 20
say "FINDING 8b refused node restarted with an OLD kept configuration while the controller is unreachable: status=$(st A), address=$(addr A); ping from B: $(ping_ab "$A_IP" && echo works || echo fails)"

lab_down
say E1_DONE
