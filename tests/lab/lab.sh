#!/bin/bash
# PC only (WSL, root). A closed ZeroTier lab for the access-guard tests: four nodes, each in its own network
# namespace on one private bridge. Nothing leaves the PC: the bridge has no uplink, so ZeroTier's public servers are
# unreachable for every node, and a lab node of our own (M, a "moon") plays their part. Every node has an identity
# generated here; no router's identity, network id or setting is used.
#
#   M  10.99.0.1   stands in for ZeroTier's root servers
#   C  10.99.0.2   network controller (what my.zerotier.com is for the real fleet)
#   B  10.99.0.3   an ordinary member: plays the administrator's PC
#   A  10.99.0.10  the router under test: the real OpenWrt program run under qemu in a copy of the router's root
#
# Each node also has its own process namespace: a program inside sees only that node's processes, as on a router
# (pidof zerotier-one finds one daemon, not the daemons of the other nodes and labs on this PC).
# Several labs can run side by side: ZT_LAB_NAME gives each its own namespaces and state directory.
# usage: . lab.sh   (it only defines functions; tests/lab/*.sh call them)
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
L=${ZT_LAB_DIR:-/var/tmp/zt-guard-lab}
LAB=${ZT_LAB_NAME:-}
NS=ztl${LAB:+-$LAB}
N=$L/nodes${LAB:+-$LAB}
QEMU=/usr/bin/qemu-aarch64-static
LAB_SH=${BASH_SOURCE[0]}
lab_ip() { case "$1" in M) echo 10.99.0.1 ;; C) echo 10.99.0.2 ;; B) echo 10.99.0.3 ;; A) echo 10.99.0.10 ;; esac; }

lab_node_pids() {  # the node's processes, without the two that hold its process namespace open
	local keep=" $(cat "$N/$1/holder" "$N/$1/holder-parent" 2>/dev/null | tr '\n' ' ')"
	for p in $(ip netns pids "$NS-$1" 2>/dev/null); do case "$keep" in *" $p "*) ;; *) echo "$p" ;; esac; done
}
lab_kill_ns() {  # every process of one node, politely first
	local p
	p=$(lab_node_pids "$1" | tr '\n' ' ')
	[ -n "$p" ] && kill $p 2>/dev/null
	for _ in 1 2 3 4 5 6; do [ -z "$(lab_node_pids "$1")" ] && return 0; sleep 0.5; done
	p=$(lab_node_pids "$1" | tr '\n' ' ')
	[ -n "$p" ] && kill -9 $p 2>/dev/null
	return 0
}

lab_down() {
	for n in A B C M; do
		lab_kill_ns "$n"
		kill -9 $(cat "$N/$n/holder" "$N/$n/holder-parent" 2>/dev/null) 2>/dev/null
	done
	for n in M C B A hub; do ip netns del "$NS-$n" 2>/dev/null || true; done
	rm -rf "$N"
}

lab_up() {
	lab_down
	mkdir -p "$N"
	ip netns add "$NS-hub"
	ip -n "$NS-hub" link add br0 type bridge
	ip -n "$NS-hub" link set br0 up
	for n in M C B A; do
		ip netns add "$NS-$n"
		ip link add "vh$n" netns "$NS-hub" type veth peer name eth0 netns "$NS-$n"
		ip -n "$NS-hub" link set "vh$n" master br0 up
		ip -n "$NS-$n" link set lo up
		ip -n "$NS-$n" addr add "$(lab_ip "$n")/24" dev eth0
		ip -n "$NS-$n" link set eth0 up
		# a default route, so that the node tries ZeroTier's public servers like a router does (they do not answer here)
		ip -n "$NS-$n" route add default via 10.99.0.254
		mkdir -p "$N/$n/home"
		# the node's process namespace lives as long as this sleeping process, its first one
		ip netns exec "$NS-$n" setsid unshare --pid --fork sleep 100000000 > /dev/null 2>&1 < /dev/null &
		echo $! > "$N/$n/holder-parent"
		disown 2>/dev/null || true
	done
	sleep 1
	for n in M C B A; do
		pgrep -P "$(pgrep -P "$(cat "$N/$n/holder-parent")" | head -1)" | head -1 > "$N/$n/holder"
		[ -s "$N/$n/holder" ] || pgrep -P "$(cat "$N/$n/holder-parent")" | head -1 > "$N/$n/holder"
	done
}

# Run a command inside a node's namespace and the given root, with the node's state at the router's own paths:
#   $N/<node>/home  -> /var/lib/zerotier-one       (RAM on a router)
#   $N/<node>/varlib -> /var/lib, instead of home, when the directory exists: a start-up script that replaces
#                       /var/lib/zerotier-one with a link of its own (a vendor firmware) needs the directory above it
#   $N/<node>/flash -> /etc/zerotier-support       (flash on a router), when the directory exists
#   $N/<node>/ram   -> /tmp/zerotier-support
#   $N/<node>/over/<path> is put over the root's own <path> (single files: stand-ins for procd, reboot, ...)
lab_in() {  # <node> <root: 24.10|25.12> <ash command>
	local n=$1 R=$L/root-$2 cmd=$3 h enter
	h=$(lab_holder "$n")
	if [ -n "$h" ] && kill -0 "$h" 2>/dev/null; then enter="nsenter -t $h -n -p"; else enter="ip netns exec $NS-$n"; fi
	$enter unshare --mount bash -c '
		R=$1; D=$2; cmd=$3; Q=$4
		mount --make-rprivate /
		mount -t proc proc "$R/proc"
		mount -t tmpfs -o size=32m tmpfs "$R/tmp"
		mkdir -p "$R/tmp/lib" "$R/tmp/lock" "$R/tmp/run" "$R/tmp/state" "$R/tmp/log" "$R/tmp/zerotier-support"
		if [ -d "$D/varlib" ]; then mount --bind "$D/varlib" "$R/tmp/lib"
		else mkdir -p "$R/tmp/lib/zerotier-one"; mount --bind "$D/home" "$R/tmp/lib/zerotier-one"; fi
		[ -d "$D/ram" ] && mount --bind "$D/ram" "$R/tmp/zerotier-support"
		[ -d "$D/tmp" ] && { mkdir -p "$R/tmp/lab"; mount --bind "$D/tmp" "$R/tmp/lab"; }
		if [ -d "$D/flash" ]; then mkdir -p "$R/etc/zerotier-support"; mount --bind "$D/flash" "$R/etc/zerotier-support"; fi
		if [ -d "$D/over" ]; then
			( cd "$D/over" && find . -type f ) | while read -r f; do
				f=${f#./}
				[ -e "$R/$f" ] && mount --bind "$D/over/$f" "$R/$f"
			done
		fi
		exec chroot "$R" "$Q" /bin/ash -c "$cmd"
	' _ "$R" "$N/$n" "$cmd" "$QEMU"
}

lab_holder() {  # the process whose namespaces the node's programs join: the sleep that is pid 1 of the node
	local h
	for h in $(cat "$N/$1/holder" 2>/dev/null) $(pgrep -P "$(cat "$N/$1/holder-parent" 2>/dev/null)" 2>/dev/null); do
		[ "$(cat "/proc/$h/comm" 2>/dev/null)" = sleep ] && { echo "$h"; return 0; }
	done
	echo "$(cat "$N/$1/holder" 2>/dev/null)"
}

lab_start() {  # <node> <root>: the bare daemon, the way procd runs it
	local n=$1 r=$2
	echo "$r" > "$N/$n/root"
	ZT_LAB_NAME=$LAB ZT_LAB_DIR=$L setsid bash -c ". '$LAB_SH'; lab_in $n $r 'exec /usr/bin/zerotier-one -p9993 /var/lib/zerotier-one'" \
		> "$N/$n/daemon.log" 2>&1 < /dev/null &
	echo $! > "$N/$n/pid"
}

lab_stop() {  # <node>
	lab_kill_ns "$1"
	rm -f "$N/$1/pid"
}

lab_cli() {  # <node> <zerotier-cli arguments>
	local n=$1; shift
	lab_in "$n" "$(cat "$N/$n/root")" "zerotier-cli $*"
}

# a node's ZeroTier address: the first field of its identity (the daemon does not write identity.public again after
# a start the stock init script's way, so the saved identity is read; the secret part is never printed)
lab_addr() { cut -d: -f1 "$N/$1/identity.secret" 2>/dev/null || cut -d: -f1 "$N/$1/home/identity.secret"; }
lab_token() { cat "$N/$1/home/authtoken.secret"; }

# the controller's own HTTP interface, called from inside C's namespace
lab_ctl() {  # <method> <path> [json]
	ip netns exec "$NS-C" curl -s -m 10 -X "$1" -H "X-ZT1-Auth: $(lab_token C)" ${3:+-d "$3"} "http://127.0.0.1:9993$2"
}

lab_wait() {  # <seconds> <description> <command...>: poll until the command succeeds
	local t=$1 what=$2 i=0; shift 2
	while [ "$i" -lt "$t" ]; do
		if "$@" >/dev/null 2>&1; then echo "  ok after ${i}s: $what"; return 0; fi
		sleep 1; i=$((i + 1))
	done
	echo "  NOT within ${t}s: $what"; return 1
}

lab_isolate() { ip -n "$NS-hub" link set "vh$1" down; }   # pull the node's cable
lab_connect() { ip -n "$NS-hub" link set "vh$1" up; }

# ---- what every experiment starts with: the stand-in root, the controller with one private network, member B
lab_base() {  # sets NW
	lab_up
	lab_first_start M 24.10
	lab_in M 24.10 'cd /var/lib/zerotier-one && zerotier-idtool initmoon identity.public > moon.json && sed -i "s#\"stableEndpoints\": \[\]#\"stableEndpoints\": [\"10.99.0.1/9993\"]#" moon.json && zerotier-idtool genmoon moon.json >/dev/null && mkdir -p moons.d && mv *.moon moons.d/' >/dev/null 2>&1
	lab_stop M; lab_start M 24.10
	lab_first_start C 24.10
	lab_wait 60 "controller is ONLINE through the stand-in root" lab_online C || return 1
	NW=$(lab_ctl POST "/controller/network/$(lab_addr C)______" '{"name":"guard-lab","private":true,"v4AssignMode":{"zt":true},"ipAssignmentPools":[{"ipRangeStart":"10.244.0.10","ipRangeEnd":"10.244.0.200"}],"routes":[{"target":"10.244.0.0/24"}]}' | jq -r .id)
	[ "${#NW}" = 16 ] || return 1
	lab_first_start B 24.10
	lab_stock_start B
	lab_ctl POST "/controller/network/$NW/member/$(lab_addr B)" '{"authorized":true}' >/dev/null
}
lab_first_start() {  # a node's very first start: lets it make its identity, then keeps a copy (the router keeps it in UCI)
	local n=$1 r=$2 H=$N/$1/home
	echo "$r" > "$N/$n/root"
	mkdir -p "$H/moons.d"; [ "$n" = M ] || cp "$N/M/home/moons.d/"*.moon "$H/moons.d/"
	lab_start "$n" "$r"
	lab_wait 40 "$n has an identity" test -s "$H/identity.secret"
	cp "$H/identity.secret" "$N/$n/identity.secret"
}
# the stock init script's start, by hand: state emptied, an empty <network>.conf (or a kept one, $2), the allow* lines
lab_stock_start() {
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
lab_net_json() { lab_cli "$1" -j listnetworks 2>/dev/null; }
lab_st() { lab_net_json "$1" | jq -r '.[0].status // "-"' 2>/dev/null; }
lab_zt_ip() { lab_net_json "$1" | jq -r '.[0].assignedAddresses[0] // "-"' 2>/dev/null | cut -d/ -f1; }
lab_has_ok() { [ "$(lab_st "$1")" = OK ] && [ "$(lab_zt_ip "$1")" != "-" ]; }
lab_online() { lab_cli "$1" info 2>/dev/null | grep -q ' ONLINE'; }
lab_ping_from_b() { ip netns exec "$NS-B" ping -c 3 -W 2 -q "$1" >/dev/null 2>&1; }
lab_dev_addr() { ip -n "$NS-A" -o -4 addr show 2>/dev/null | awk '$2 ~ /^zt/ {print $4}' | head -1; }
lab_key() { grep -a "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2-; }   # one key of a kept network configuration
