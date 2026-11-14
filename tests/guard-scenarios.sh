#!/bin/sh
# Behaviour tests of the access guard, in plain POSIX sh so that the very same file runs
#   - on the developer's PC and in CI (sh, dash, bash), through tests/guard.test.mjs;
#   - under the routers' own BusyBox ash 1.36 (OpenWrt 24.10) and 1.37 (25.12), through tests/lab/guard-ash.sh.
# The router around the guard is a model: every program the guard calls is a small stand-in that reads the model's
# files in $W and writes what it was asked to do to $W/actions. The daemon is a real process (a sleeping one), so a
# real kill and a real "new pid" happen. Time is given to the guard from outside, so hours pass in milliseconds.
#
# usage: sh tests/guard-scenarios.sh <path to the guard> [only-this-scenario]
set -u
GUARD="${1:?path to the guard}"
ONLY="${2:-}"
SH="${ZRS_TEST_SH:-sh}"
REAL_SLEEP="$(command -v sleep)"
REAL_PATH="$PATH"
ID=0123456789abcdef
PASS=0; FAIL=0; CUR=''
TOP="$(mktemp -d "${TMPDIR:-/tmp}/zrs-guard-test.XXXXXX")" || exit 1
trap 'cleanup' EXIT INT TERM
cleanup() {
	for p in $(cat "$TOP"/*/world/allpids 2>/dev/null); do kill "$p" 2>/dev/null; done
	rm -rf "$TOP"
}

ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL [$CUR] $*"; }
check() { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
actions() { tr '\n' ';' < "$W/actions" 2>/dev/null | sed 's/;$//'; }
count() { grep -c "^$1\$" "$W/actions" 2>/dev/null; }
expect_actions() { check "${2:-actions}" "$(actions)" "$1"; }
log_has() { if grep -q "$1" "$T/tmp/zerotier-support/guard.log" 2>/dev/null; then ok; else bad "log lacks: $1"; fi; }
state_of() { sed -n "s/^$1=//p" "$T/tmp/zerotier-support/guard.state" 2>/dev/null; }

new_daemon() {  # a real process stands in for zerotier-one
	"$REAL_SLEEP" 100000 > /dev/null 2>&1 &
	echo $! > "$W/pid"; echo $! >> "$W/allpids"
}
conf_text() {  # a network configuration as the daemon keeps it: stable lines plus a timestamp and a pass
	printf 'v=7\nnwid=%s\nts=%s\nctmd=00000000001b7740\nr=1\nid=00000000abcdef0123\nn=lab\nC=pass-%s\nI=%s\nRT=route\n' "$ID" "$1" "$1" "${2:-10.9.8.7/24}"
}

# a fresh model router: ZeroTier healthy, Podkop running, firewall state in place
world() {
	CUR="$1"
	T="$TOP/$1"; W="$T/world"; B="$T/bin"
	mkdir -p "$W" "$B" "$T/etc/init.d" "$T/etc/zerotier-support" "$T/etc/nftables.d" "$T/usr/libexec/zerotier-support" \
		"$T/var/lib/zerotier-one/networks.d" "$T/tmp" "$T/etc/sing-box"
	: > "$W/actions"; : > "$W/allpids"; : > "$W/procs"
	echo ONLINE > "$W/state"; echo OK > "$W/status"; echo 10.9.8.7/24 > "$W/ips"; echo ztlab0 > "$W/dev"
	echo '    inet 10.9.8.7/24 brd 10.9.8.255 scope global ztlab0' > "$W/dev_ips"
	printf '200 peers\n<ztaddr>   <ver>  <role> <lat> <link>   <lastTX> <lastRX> <path>\n778cde7190 -      PLANET   41 DIRECT 1200     1100     103.195.103.66/9993\ncafe04eba9 -      PLANET   -1 RELAY\n' > "$W/peers"
	: > "$W/zt_boot"; : > "$W/bypass_chain"; : > "$W/ssh_rule"; : > "$W/podkop_table"; : > "$W/podkop_boot"; : > "$W/dropbear_boot"
	echo 777 > "$W/dropbear_pid"
	printf 'zerotier.global.enabled=1\nzerotier.router_support.allow_managed=1\nfirewall.allow_zt_support_router.target=ACCEPT\n' > "$W/uci"
	printf "zerotier.global=zerotier\nzerotier.global.enabled='1'\nzerotier.router_support=network\nzerotier.router_support.id='%s'\n" "$ID" > "$W/uci_show"
	printf 'REBOOT=1\nCLI_TIMEOUT=0\n' > "$T/etc/zerotier-support/guard.conf"   # the reboot step is off by default
	echo 'set podkop_zerotier_udp_ports { }' > "$T/usr/libexec/zerotier-support/20-podkop-zerotier-bypass.nft"
	cp "$T/usr/libexec/zerotier-support/20-podkop-zerotier-bypass.nft" "$T/etc/nftables.d/20-podkop-zerotier-bypass.nft"
	conf_text 1000 > "$T/var/lib/zerotier-one/networks.d/$ID.conf"
	new_daemon
	stub zerotier-cli 'case "$1" in
	info) [ -e "$W/cli_fail" ] && exit 1; if [ "${2:-}" = -j ]; then echo "{}"; else echo "200 info abcdef0123 1.16.2 $(cat "$W/state")"; fi ;;
	listnetworks) [ -e "$W/cli_fail" ] && exit 1; echo "[{}]" ;;
	peers) cat "$W/peers" ;;
esac'
	stub jsonfilter 'cat > /dev/null; case "$2" in
	*.status) cat "$W/status" ;;
	*assignedAddresses*) cat "$W/ips" ;;
	*.portDeviceName) cat "$W/dev" ;;
	*respawn.retry*) cat "$W/respawn" 2>/dev/null ;;
esac; exit 0'
	stub pidof 'case "$1" in
	zerotier-one) p="$(cat "$W/pid" 2>/dev/null)"; [ -n "$p" ] && kill -0 "$p" 2>/dev/null && echo "$p" ;;
	dropbear) cat "$W/dropbear_pid" 2>/dev/null ;;
	sing-box) [ -e "$W/podkop_table" ] && echo 999 ;;
esac; exit 0'
	stub pgrep 'if [ "$1" = -x ]; then grep -Eq "^$2( |\$)" "$W/procs"; else grep -Eq "$2" "$W/procs"; fi'
	stub pkill 'exit 0'
	stub ubus 'echo "{}"'
	echo 5 > "$W/respawn"                       # procd starts the daemon again by itself, as the stock script asks
	stub logger 'exit 0'
	stub sync 'exit 0'
	stub reboot 'echo reboot >> "$W/actions"'
	stub sleep '[ -f "$W/on_sleep" ] && . "$W/on_sleep"; exit 0'
	stub uci 'case "$2" in
	get) v="$(sed -n "s/^$3=//p" "$W/uci")"; [ -n "$v" ] || exit 1; echo "$v" ;;
	show) cat "$W/uci_show" ;;
	*) echo "uci $*" >> "$W/actions" ;;
esac'
	echo 'default via 10.0.0.1 dev wan' > "$W/route"
	stub ip 'case "$*" in *route*) cat "$W/route" ;; *) cat "$W/dev_ips" ;; esac'
	stub ping '[ ! -e "$W/no_internet" ]'
	stub nft 'case "$*" in
	"list chain inet fw4 podkop_zerotier_bypass"|"list set inet fw4 podkop_zerotier_udp_ports") [ -e "$W/bypass_chain" ] ;;
	"list chain inet fw4 input_zt_support") [ -e "$W/ssh_rule" ] && echo "tcp dport { 22, 80, 443 } counter accept comment \"!fw4: Allow-ZeroTier-Support-To-Router\"" ;;
	"list table inet PodkopTable") [ -e "$W/podkop_table" ] ;;
	-c*) exit 0 ;;
	-f*) echo "nft sync" >> "$W/actions" ;;
esac'
	initd zerotier 'case "$1" in
	enabled) [ -e "$W/zt_boot" ]; exit $? ;;
	restart|start) echo "zerotier $1" >> "$W/actions"
		p="$(cat "$W/pid" 2>/dev/null)"; [ -n "$p" ] && kill "$p" 2>/dev/null
		: > "$T/var/lib/zerotier-one/networks.d/'"$ID"'.conf"
		if [ ! -e "$W/no_start" ]; then "'"$REAL_SLEEP"'" 100000 > /dev/null 2>&1 & echo $! > "$W/pid"; echo $! >> "$W/allpids"; fi
		[ -f "$W/on_restart" ] && . "$W/on_restart" ;;
esac; exit 0'
	initd firewall 'case "$1" in enabled) exit 0 ;; reload) echo "firewall reload" >> "$W/actions"; [ -f "$W/on_reload" ] && . "$W/on_reload" ;; esac; exit 0'
	initd dropbear 'case "$1" in enabled) [ -e "$W/dropbear_boot" ] ;; start) echo "dropbear start" >> "$W/actions"; echo 778 > "$W/dropbear_pid" ;; esac'
	initd podkop 'case "$1" in
	enabled) [ -e "$W/podkop_boot" ] ;;
	stop) echo "podkop stop" >> "$W/actions"; rm -f "$W/podkop_table" ;;
	start) echo "podkop start" >> "$W/actions"; : > "$W/podkop_table" ;;
esac'
}
stub() { printf '#!/bin/sh\nW="%s"; T="%s"\n%s\n' "$W" "$T" "$2" > "$B/$1"; chmod +x "$B/$1"; }
initd() { printf '#!/bin/sh\nW="%s"; T="%s"\n%s\n' "$W" "$T" "$2" > "$T/etc/init.d/$1"; chmod +x "$T/etc/init.d/$1"; }

# one check by the guard at the given uptime (seconds); the wall clock runs with it from a fixed start
at() {
	ZRS_GUARD_ROOT="$T" ZRS_GUARD_UPTIME="$1" ZRS_GUARD_EPOCH="$(( ${EPOCH0:-1790000000} + $1 ))" ZRS_GUARD_NO_WAIT=1 \
		PATH="$B:$REAL_PATH" "$SH" "$GUARD" run > "$W/last.out" 2>&1 || bad "the guard exited with an error at $1 s: $(head -3 "$W/last.out")"
}
span() {  # <from> <to> [step]: checks at from, from+step, ... up to and including to (a minute apart by default)
	sp_t=$1
	while [ "$sp_t" -le "$2" ]; do at "$sp_t"; sp_t=$((sp_t + ${3:-60})); done
}
guard_cmd() { ZRS_GUARD_ROOT="$T" ZRS_GUARD_UPTIME="${GUP:-100}" ZRS_GUARD_EPOCH=$(( 1790000000 + ${GUP:-100} )) PATH="$B:$REAL_PATH" "$SH" "$GUARD" "$@"; }
want() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }
cache="etc/zerotier-support/network-$ID.cache"
break_zt() { echo OFFLINE > "$W/state"; }
fix_zt() { echo ONLINE > "$W/state"; }

# ------------------------------------------------------------------------------------------------ scenarios
if want healthy; then world healthy
	span 60 3600 300
	expect_actions '' 'a healthy router is left alone'
	check 'state' "$(state_of S_HEALTH)" ok
	[ -s "$T/$cache" ] && ok || bad 'the network settings were not kept on flash'
fi

if want daemon-dead; then world daemon-dead
	at 60
	kill "$(cat "$W/pid")"; : > "$W/pid"; echo 'echo REQUESTING_CONFIGURATION > "$W/status"' > "$W/on_restart"
	touch "$W/no_start"                        # the program dies again at once, every time
	at 120; expect_actions 'zerotier restart' 'a dead daemon is started at the first check'
	at 150; expect_actions 'zerotier restart' 'not again within the back-off'
	at 180; check 'second start after 60 s' "$(count 'zerotier restart')" 2
	at 240; at 300; check 'third start after 120 s more' "$(count 'zerotier restart')" 3
	span 360 2100; span 2400 7200 300
	n=$(count 'zerotier restart')
	[ "$n" -ge 9 ] && [ "$n" -le 14 ] && ok || bad "starts in two hours with back-off: $n (expected 9..14, never unlimited-fast)"
	check 'reboot after half an hour of a dead daemon, once' "$(count reboot)" 1
	rm -f "$W/no_start"; echo 'echo OK > "$W/status"; cat "$W/conf.ok" > "$T/var/lib/zerotier-one/networks.d/'"$ID"'.conf"' > "$W/on_restart"; conf_text 2000 > "$W/conf.ok"
	span 7260 7500; span 8100 11400 600
	check 'state after the daemon stays up' "$(state_of S_HEALTH)" ok
	grep -q '^state=recovered' "$T/tmp/zerotier-support/last-incident" && ok || bad 'the incident is not marked recovered'
fi

if want offline-ladder; then world offline-ladder
	at 60; break_zt
	at 120; at 180; expect_actions '' 'nothing in the first minutes of OFFLINE'
	at 240; at 300; expect_actions 'zerotier restart' 'restart after three minutes'
	span 360 480; expect_actions 'zerotier restart;firewall reload;nft sync' 'then the live firewall state'
	span 540 780; expect_actions 'zerotier restart;firewall reload;nft sync;zerotier restart' 'second restart'
	span 840 900; expect_actions 'zerotier restart;firewall reload;nft sync;zerotier restart;podkop stop' 'then Podkop is paused'
	span 960 1140
	expect_actions 'zerotier restart;firewall reload;nft sync;zerotier restart;podkop stop;zerotier restart;podkop start' 'a restart while Podkop is paused, then Podkop comes back by itself'
	span 1200 1860; check 'no reboot before half an hour of failure' "$(count reboot)" 0
	span 1920 1980; check 'one reboot after half an hour' "$(count reboot)" 1
	grep -q '^count=1' "$T/etc/zerotier-support/reboots" && ok || bad 'the reboot is not counted on flash'
	grep -q '^state=rebooted' "$T/etc/zerotier-support/last-incident" && grep -q 'steps=restart,reapply,podkop-pause,reboot' "$T/etc/zerotier-support/last-incident" && ok || bad "last-incident on flash: $(tr '\n' ' ' < "$T/etc/zerotier-support/last-incident")"
	check 'no uci write, ever' "$(grep -c '^uci ' "$W/actions")" 0
fi

if want recovers; then world recovers
	at 60; echo '' > "$W/ips"                  # network OK, but no address
	span 120 300
	expect_actions 'zerotier restart' 'a network without an address gets a restart'
	check 'reason' "$(state_of S_REASON)" no-address
	echo 10.9.8.7/24 > "$W/ips"
	span 360 1020 120
	expect_actions 'zerotier restart' 'nothing more once it is back'
	check 'state' "$(state_of S_HEALTH)" ok
	grep -q '^state=recovered' "$T/etc/zerotier-support/last-incident" && ok || bad 'recovery did not reach the flash record'
	check 'one line in the history of incidents' "$(wc -l < "$T/etc/zerotier-support/incidents" | tr -d ' ')" 1
	grep -q 'reason=no-address steps=restart state=recovered' "$T/etc/zerotier-support/incidents" && ok || bad "history line: $(cat "$T/etc/zerotier-support/incidents")"
	echo '    inet 10.1.1.1/24 scope global ztlab0' > "$W/dev_ips"
	at 1060; check 'address missing on the interface is seen' "$(state_of S_REASON)" address-not-on-interface
fi

if want history-wait; then world history-wait
	# two incidents close together: the second line waits in RAM and reaches the flash ten minutes after the first
	at 60; echo '' > "$W/ips"; span 120 300; echo 10.9.8.7/24 > "$W/ips"; at 360
	check 'the first line is on flash at once' "$(wc -l < "$T/etc/zerotier-support/incidents" | tr -d ' ')" 1
	echo '' > "$W/ips"; span 420 660; echo 10.9.8.7/24 > "$W/ips"; at 720
	check 'the second line waits while the flash was written less than ten minutes ago' "$(wc -l < "$T/etc/zerotier-support/incidents" | tr -d ' ')" 1
	GUP=730 guard_cmd status > "$W/status.out" 2>&1
	grep -q 'последние происшествия (всего 2)' "$W/status.out" && ok || bad 'status does not show the waiting line'
	span 780 1020
	check 'and reaches the flash once ten minutes have passed' "$(wc -l < "$T/etc/zerotier-support/incidents" | tr -d ' ')" 2
	GUP=1030 guard_cmd save > /dev/null 2>&1
	check 'nothing is lost or doubled at shutdown' "$(wc -l < "$T/etc/zerotier-support/incidents" | tr -d ' ')" 2
fi

if want kept-settings; then world kept-settings
	span 60 120                        # healthy: the settings are kept
	payload="$(tail -n +2 "$T/$cache" | sha256sum | cut -c1-64)"
	# the controller goes away and the daemon restarts the stock way: empty settings, waiting
	echo 'echo REQUESTING_CONFIGURATION > "$W/status"; echo "" > "$W/ips"' > "$W/on_restart"
	"$SH" "$T/etc/init.d/zerotier" restart; : > "$W/actions"
	old="$(cat "$W/pid")"
	# procd starts the program again after the guard's kill; it then reads the settings put back
	cat > "$W/on_sleep" <<EOF
p="\$(cat "$W/pid")"
if ! kill -0 "\$p" 2>/dev/null && [ "\$(wc -c < "$T/var/lib/zerotier-one/networks.d/$ID.conf")" -gt 64 ]; then
	"$REAL_SLEEP" 100000 > /dev/null 2>&1 & echo \$! > "$W/pid"; echo \$! >> "$W/allpids"
	echo OK > "$W/status"; echo 10.9.8.7/24 > "$W/ips"
fi
EOF
	at 180; at 240; expect_actions '' 'not before the network has waited two minutes'
	at 300
	expect_actions '' 'the kept settings need no init script, no firewall, no reboot'
	check 'the daemon was restarted by a plain kill (new pid)' "$([ "$(cat "$W/pid")" != "$old" ] && echo new)" new
	check 'the settings the daemon reads are the kept ones' "$(sha256sum < "$T/var/lib/zerotier-one/networks.d/$ID.conf" | cut -c1-64)" "$payload"
	at 360; check 'state' "$(state_of S_HEALTH)" ok
	log_has 'kept network settings put back'
fi

if want kept-settings-damaged; then
	for kind in garbage cut-short other-network too-old flipped-byte; do
		world "damaged-$kind"; CUR="kept-settings-damaged/$kind"
		span 60 120
		f="$T/$cache"
		case "$kind" in
			garbage) head -c 300 /dev/urandom > "$f" ;;
			cut-short) head -c 150 "$f" > "$f.x"; mv "$f.x" "$f" ;;
			other-network) sed '1s/'"$ID"'/fedcba9876543210/' "$f" > "$f.x"; mv "$f.x" "$f" ;;
			too-old) sed "1s/ [0-9]*\$/ 1000000000/" "$f" > "$f.x"; mv "$f.x" "$f" ;;
			flipped-byte) sed '2,$s/route/r0ute/' "$f" > "$f.x"; mv "$f.x" "$f" ;;
		esac
		echo 'echo REQUESTING_CONFIGURATION > "$W/status"; echo "" > "$W/ips"' > "$W/on_restart"
		"$SH" "$T/etc/init.d/zerotier" restart; : > "$W/actions"
		old="$(cat "$W/pid")"
		span 180 300
		check 'a damaged copy is not given to the daemon' "$(wc -c < "$T/var/lib/zerotier-one/networks.d/$ID.conf" | tr -d ' ')" 0
		check 'the daemon is not killed for it' "$(cat "$W/pid")" "$old"
		span 360 420
		expect_actions 'zerotier restart' 'the ordinary steps go on instead'
		case "$kind" in too-old) log_has 'too old' ;; other-network|garbage) ok ;; *) log_has 'damaged' ;; esac
	done
fi

if want refused; then world refused
	span 60 120
	echo ACCESS_DENIED > "$W/status"; echo '' > "$W/ips"; break_zt
	span 180 9000 600
	expect_actions '' 'a node the controller refuses is not repaired and not rebooted'
	[ ! -e "$T/$cache" ] && ok || bad 'the kept settings of a refused node were not removed'
	[ -e "$T/etc/zerotier-support/refused-$ID" ] && ok || bad 'the refusal is not remembered'
	check 'state' "$(state_of S_HEALTH)" refused
	# after a restart the daemon only says "waiting": still not guarded, because the refusal is remembered
	echo REQUESTING_CONFIGURATION > "$W/status"
	span 9060 12000 600
	expect_actions '' 'still left alone while it only waits'
	echo OK > "$W/status"; echo 10.9.8.7/24 > "$W/ips"; fix_zt
	at 12060
	[ ! -e "$T/etc/zerotier-support/refused-$ID" ] && ok || bad 'the refusal is not forgotten once the node is let in'
	break_zt; span 12120 12420
	expect_actions 'zerotier restart' 'guarded again after it was let in'
fi

if want busy; then world busy
	at 60; break_zt
	echo '/bin/sh /sbin/sysupgrade -n -v /tmp/firmware.bin' > "$W/procs"
	span 120 3000 240
	expect_actions '' 'no step at all while a firmware upgrade runs'
	log_has 'held back: firmware upgrade'
	echo 'apk add zerotier' > "$W/procs"
	span 3060 3300; expect_actions '' 'none while a package is being installed'
	echo 'sh /usr/share/fleet-firstboot/podkop-pe.run' > "$W/procs"
	span 3360 3600; expect_actions '' 'none while the Podkop installer runs'
	kill "$(cat "$W/pid")"; : > "$W/pid"
	at 3660; expect_actions 'zerotier restart' 'a dead daemon is still started'
	: > "$W/procs"; : > "$W/actions"
	at 3720; at 3780
	expect_actions 'zerotier restart' 'once the upgrade is over the steps begin, the lightest first'
	at 3840; at 3900
	check 'and no reboot is taken out of turn' "$(count reboot)" 0
fi

if want reboot-limit; then world reboot-limit
	printf 'REBOOT=1\nPODKOP=0\nCLI_TIMEOUT=0\n' > "$T/etc/zerotier-support/guard.conf"
	at 60; break_zt
	span 120 1740 180; span 1800 1980; check 'first reboot' "$(count reboot)" 1
	# the router comes up again and ZeroTier is still down
	: > "$W/actions"
	span 60 21000 1800; at 21540; check 'no second reboot in the first six hours of uptime' "$(count reboot)" 0
	span 21600 21720; check 'second reboot after six hours' "$(count reboot)" 1
	grep -q '^count=2' "$T/etc/zerotier-support/reboots" && ok || bad 'count is not 2'
	: > "$W/actions"
	span 60 43000 3600; at 43140; check 'no third reboot in twelve hours' "$(count reboot)" 0
	span 43200 43320; check 'third reboot after twelve hours' "$(count reboot)" 1
	: > "$W/actions"; fix_zt
	span 60 3720 300
	grep -q '^count=0' "$T/etc/zerotier-support/reboots" && ok || bad 'the counter is not cleared after a healthy hour'
	# and with reboots switched off
	printf 'REBOOT=0\nPODKOP=0\nCLI_TIMEOUT=0\n' > "$T/etc/zerotier-support/guard.conf"
	break_zt; span 3780 30000 1800
	check 'REBOOT=0 means never' "$(count reboot)" 0
fi

if want late-check; then world late-check
	at 60; break_zt; at 120
	at 7200                                    # the guard did not get to run for two hours
	expect_actions 'zerotier restart' 'after a long gap the first step is still the lightest one'
	at 7260; expect_actions 'zerotier restart' 'the daemon just restarted is given time to come up'
	at 7320; at 7380
	expect_actions 'zerotier restart;firewall reload;nft sync;podkop stop' 'then one step per check'
	span 7440 7740
	expect_actions 'zerotier restart;firewall reload;nft sync;podkop stop;zerotier restart;podkop start;reboot' 'the reboot is last and waits until Podkop is running again'
fi

if want just-started; then world just-started
	# ZeroTier needs up to a minute after a start to get online: a start by anyone resets the patience
	at 60; break_zt
	at 120; at 180; at 240                      # three minutes of OFFLINE: a restart would be due at the next check
	"$SH" "$T/etc/init.d/zerotier" restart; : > "$W/actions"    # somebody else (the helper, procd) starts it anew
	at 300; at 360
	expect_actions '' 'a daemon started a moment ago is not restarted again'
	at 420
	expect_actions 'zerotier restart' 'but it is once it has had its time'
fi

if want just-booted; then world just-booted
	# the first minutes after a boot: WAN and ZeroTier are still coming up, nothing is restarted yet
	break_zt
	span 20 260 60
	expect_actions '' 'no step in the first five minutes of uptime'
	at 320
	expect_actions 'zerotier restart' 'the first step once the router has been up five minutes'
	world just-booted-dead; CUR=just-booted/dead-daemon
	kill "$(cat "$W/pid")"; : > "$W/pid"
	at 30; expect_actions 'zerotier restart' 'a daemon that is not running is started even right after the boot'
	world just-booted-seed; CUR=just-booted/kept-settings
	at 20                                       # settings are kept
	echo 'echo REQUESTING_CONFIGURATION > "$W/status"; echo "" > "$W/ips"' > "$W/on_restart"
	"$SH" "$T/etc/init.d/zerotier" restart; : > "$W/actions"
	cat > "$W/on_sleep" <<EOF
p="\$(cat "$W/pid")"
if ! kill -0 "\$p" 2>/dev/null && [ "\$(wc -c < "$T/var/lib/zerotier-one/networks.d/$ID.conf")" -gt 64 ]; then
	"$REAL_SLEEP" 100000 > /dev/null 2>&1 & echo \$! > "$W/pid"; echo \$! >> "$W/allpids"
	echo OK > "$W/status"; echo 10.9.8.7/24 > "$W/ips"
fi
EOF
	at 40; at 100; at 160; at 220
	check 'the kept settings are put back within the first minutes of uptime' "$(state_of S_HEALTH)" ok
	expect_actions '' 'and without any other step'
	log_has 'kept network settings put back'
fi

# the controller goes away for this node: the daemon restarts empty when the init script is used, and reads the
# kept settings when procd starts it again after the guard's kill
controller_gone() {
	echo 'echo REQUESTING_CONFIGURATION > "$W/status"; echo "" > "$W/ips"' > "$W/on_restart"
	cat > "$W/on_sleep" <<EOF
p="\$(cat "$W/pid")"
if ! kill -0 "\$p" 2>/dev/null && [ "\$(wc -c < "$T/var/lib/zerotier-one/networks.d/$ID.conf")" -gt 64 ]; then
	"$REAL_SLEEP" 100000 > /dev/null 2>&1 & echo \$! > "$W/pid"; echo \$! >> "$W/allpids"
	echo OK > "$W/status"; echo 10.9.8.7/24 > "$W/ips"
fi
EOF
}
refreshed() {  # the controller answered at second $1: the daemon rewrote the settings then
	conf_text "$1" > "$T/var/lib/zerotier-one/networks.d/$ID.conf"
	touch -d "@$(( 1790000000 + $1 ))" "$T/var/lib/zerotier-one/networks.d/$ID.conf"
}

if want controller-silent; then world controller-silent
	conf="$T/var/lib/zerotier-one/networks.d/$ID.conf"
	t=60; while [ "$t" -le 600 ]; do refreshed "$t"; at "$t"; t=$((t + 60)); done
	expect_actions '' 'a controller that keeps refreshing the settings: nothing to do'
	controller_gone                              # from now on nothing fresh arrives; the router still says OK and ONLINE
	span 660 1440; expect_actions '' 'nothing in the first fifteen minutes of silence'
	at 1500; check 'the silence is noticed after fifteen minutes' "$(state_of S_REASON)" controller-silent
	span 1560 1620; expect_actions '' 'the fresh start waits three more minutes'
	old="$(cat "$W/pid")"
	span 1680 2100
	expect_actions 'zerotier restart' 'one fresh start of the daemon'
	check 'the kept settings were put back after it' "$([ "$(wc -c < "$conf" | tr -d ' ')" -gt 64 ] && [ "$(cat "$W/pid")" != "$old" ] && echo yes)" yes
	check 'the silence is still known (the settings are the kept ones)' "$(state_of S_REASON)" controller-silent
	span 2160 8820 300
	expect_actions 'zerotier restart' 'no further start for two hours; never a Podkop pause, a firewall reload or a reboot for this'
	span 8880 9300
	check 'a second fresh start two hours after the first' "$(count 'zerotier restart')" 2
	check 'still no reboot and Podkop untouched' "$(grep -c 'reboot\|podkop' "$W/actions")" 0
	refreshed 9360; echo OK > "$W/status"; echo 10.9.8.7/24 > "$W/ips"; at 9360
	check 'healthy again as soon as the controller answers' "$(state_of S_HEALTH)" ok
	grep -q 'reason=controller-silent' "$T/etc/zerotier-support/incidents" && ok || bad 'the silence is not in the history of incidents'
	GUP=9370 guard_cmd status > "$W/status.out" 2>&1
	grep -q 'последние происшествия' "$W/status.out" && grep -q 'Корневые серверы ZeroTier: видно 1 из 2' "$W/status.out" && ok || bad 'status lacks the history or the root servers'

	world controller-silent-nocopy; CUR=controller-silent/no-kept-copy
	printf 'CACHE=0\nCLI_TIMEOUT=0\n' > "$T/etc/zerotier-support/guard.conf"
	t=60; while [ "$t" -le 300 ]; do refreshed "$t"; at "$t"; t=$((t + 60)); done
	controller_gone; span 360 9000 300
	expect_actions '' 'without a kept copy the daemon is left alone: a restart would only lose the settings it still has'
	check 'but the silence is seen' "$(state_of S_REASON)" controller-silent

	world controller-silent-off; CUR=controller-silent/notice-only
	printf 'CONTROLLER_RESTART=0\nCLI_TIMEOUT=0\n' > "$T/etc/zerotier-support/guard.conf"
	t=60; while [ "$t" -le 300 ]; do refreshed "$t"; at "$t"; t=$((t + 60)); done
	controller_gone; span 360 9000 300
	expect_actions '' 'CONTROLLER_RESTART=0: noticed and recorded, nothing done'
fi

if want kept-settings-first; then world kept-settings-first
	# the daemon is seen dead first and without settings only a check later: the kept settings must still come
	# before the restart of the ladder, whatever the order in which the symptoms showed
	span 60 120
	controller_gone
	old="$(cat "$W/pid")"; kill "$old"; : > "$W/pid"
	at 180                                      # daemon dead: started through the init script (that is its own step)
	expect_actions 'zerotier restart' 'a dead daemon is started'
	: > "$W/actions"
	at 240; at 300; at 360
	expect_actions '' 'no restart of the ladder while the kept settings are still to be put back'
	log_has 'kept network settings put back'
	at 420; check 'and the router is in its network again' "$(state_of S_HEALTH)" ok
fi

if want no-respawn; then world no-respawn
	# a router whose start-up script does not ask procd to start the daemon again (one such router in the fleet)
	: > "$W/respawn"
	span 60 120
	controller_gone
	"$SH" "$T/etc/init.d/zerotier" restart; : > "$W/actions"
	old="$(cat "$W/pid")"
	span 180 300
	check 'the daemon is not killed where nothing would start it again' "$(cat "$W/pid")" "$old"
	log_has 'not started again by the system'
	span 360 420
	expect_actions 'zerotier restart' 'the ordinary steps go on'
	kill "$(cat "$W/pid")"; : > "$W/pid"; : > "$W/actions"
	at 480
	expect_actions 'zerotier restart' 'and a daemon that died there is started by the guard'
fi

if want no-internet; then world no-internet
	# the line is cut: no root server and no public address answers
	at 60; break_zt
	printf '200 peers\n<ztaddr> <ver> <role> <lat> <link> <lastTX> <lastRX> <path>\n778cde7190 - PLANET -1 RELAY\ncafe04eba9 - PLANET -1 RELAY\n' > "$W/peers"
	: > "$W/no_internet"
	span 120 9000 300
	expect_actions '' 'no step at all while there is no internet'
	check 'reason' "$(state_of S_REASON)" no-internet
	log_has 'repair steps wait until it is back'
	kill "$(cat "$W/pid")"; : > "$W/pid"
	at 9060; expect_actions 'zerotier restart' 'a daemon that died is still started'
	: > "$W/actions"
	rm -f "$W/no_internet"                     # the internet is back, ZeroTier is still offline: the steps begin
	span 9120 9240
	expect_actions '' 'ZeroTier first gets the usual three minutes to find its way'
	span 9300 9360
	expect_actions 'zerotier restart' 'then the steps begin from the first one'
	span 9420 9600
	expect_actions 'zerotier restart;firewall reload;nft sync' 'and go on at their usual pace'
	world no-route; CUR=no-internet/no-default-route
	: > "$W/route"; at 60; break_zt; span 120 6000 300
	expect_actions '' 'no default route: no step'
	check 'reason' "$(state_of S_REASON)" no-internet
	world no-internet-history; CUR=no-internet/history
	at 60; break_zt; : > "$W/no_internet"
	printf '200 peers\n<ztaddr> <ver> <role> <lat> <link> <lastTX> <lastRX> <path>\n778cde7190 - PLANET -1 RELAY\n' > "$W/peers"
	span 120 1200
	rm -f "$W/no_internet"; fix_zt
	printf '200 peers\n<ztaddr> <ver> <role> <lat> <link> <lastTX> <lastRX> <path>\n778cde7190 -      PLANET   41 DIRECT 1200     1100     103.195.103.66/9993\n' > "$W/peers"
	at 1260
	check 'healthy again' "$(state_of S_HEALTH)" ok
	grep -q 'reason=no-internet steps=none state=recovered' "$T/etc/zerotier-support/incidents" && ok || bad "history: $(cat "$T/etc/zerotier-support/incidents" 2>/dev/null)"
	world blocked-roots; CUR=no-internet/roots-blocked-but-internet
	# only the roots are blocked, the internet answers: that is not "no internet", the steps go on
	at 60; break_zt
	printf '200 peers\n<ztaddr> <ver> <role> <lat> <link> <lastTX> <lastRX> <path>\n778cde7190 - PLANET -1 RELAY\n' > "$W/peers"
	span 120 300
	expect_actions 'zerotier restart' 'blocked roots with working internet still get the steps'
fi

if want state-file; then world state-file
	# only keys made of capitals and underscores are taken from the saved state
	at 60
	printf 'S_A;touch %s/pwned=1\nS_X$(touch %s/pwned2)=1\n' "$W" "$W" >> "$T/tmp/zerotier-support/guard.state"
	at 120
	[ ! -e "$W/pwned" ] && [ ! -e "$W/pwned2" ] && ok || bad 'a line of the state file was run as a command'
	check 'the guard goes on' "$(state_of S_HEALTH)" ok
fi

if want restart-backoff; then world restart-backoff
	printf 'REBOOT=0\nPODKOP=0\nCLI_TIMEOUT=0\n' > "$T/etc/zerotier-support/guard.conf"
	break_zt; at 1000
	n=0
	for t in 180 540 1260 2700 5580 9180 12780; do   # 3 min, then 6, 12, 24, 48, 60 and 60 min apart
		at $((1000 + t - 60)); check "no restart a minute before $t s" "$(count 'zerotier restart')" "$n"
		n=$((n + 1))
		at $((1000 + t)); check "restart #$n at $t s" "$(count 'zerotier restart')" "$n"
	done
fi

if want default-no-reboot; then world default-no-reboot
	# the settings as shipped: no reboot, whatever happens
	printf 'CLI_TIMEOUT=0\n' > "$T/etc/zerotier-support/guard.conf"
	at 60; break_zt; span 120 2400; span 2700 30000 900
	check 'OFFLINE for eight hours: no reboot' "$(count reboot)" 0
	check 'the restarts go on, an hour apart' "$([ "$(count 'zerotier restart')" -ge 8 ] && echo yes)" yes
	[ ! -e "$T/etc/zerotier-support/reboots" ] && ok || bad 'a reboot counter was written'
	world default-no-reboot-dead; CUR=default-no-reboot/dead-daemon
	printf 'CLI_TIMEOUT=0\n' > "$T/etc/zerotier-support/guard.conf"
	kill "$(cat "$W/pid")"; : > "$W/pid"; touch "$W/no_start"
	span 60 2400; span 2700 20000 900
	check 'a daemon that never stays up: no reboot' "$(count reboot)" 0
	world default-no-reboot-upgrade; CUR=default-no-reboot/unconfirmed-upgrade
	printf 'CLI_TIMEOUT=0\n' > "$T/etc/zerotier-support/guard.conf"
	echo pending > "$T/etc/zerotier-support/upgrade-pending"
	span 60 2640
	expect_actions 'zerotier restart;firewall reload;nft sync;zerotier restart;podkop stop;zerotier restart;podkop start' 'an unconfirmed upgrade: the steps once, without a reboot'
	span 2700 2820
	grep -q '^used ' "$T/etc/zerotier-support/upgrade-pending" && ok || bad 'the marker is not spent'
	: > "$W/actions"; span 2880 20000 900
	expect_actions '' 'after that nothing more'
fi

if want upgrade-not-confirmed; then world upgrade-not-confirmed
	echo pending > "$T/etc/zerotier-support/upgrade-pending"
	span 60 1020 120
	expect_actions '' 'nothing while the PC still has time to confirm'
	span 1080 1140; expect_actions 'zerotier restart' 'first step three minutes after the deadline'
	span 1200 2640
	expect_actions 'zerotier restart;firewall reload;nft sync;zerotier restart;podkop stop;zerotier restart;podkop start' 'the same steps as for a fault'
	span 2700 2760; check 'one reboot' "$(count reboot)" 1
	grep -q '^used ' "$T/etc/zerotier-support/upgrade-pending" && ok || bad 'the marker is not spent'
	: > "$W/actions"
	span 60 30000 1800
	expect_actions '' 'after that reboot the marker does nothing more'
fi

if want upgrade-confirmed; then world upgrade-confirmed
	echo pending > "$T/etc/zerotier-support/upgrade-pending"
	span 60 300
	GUP=310 guard_cmd confirm > "$W/confirm.out"
	[ ! -e "$T/etc/zerotier-support/upgrade-pending" ] && ok || bad 'confirm did not clear the marker'
	span 360 9000 600
	expect_actions '' 'a confirmed upgrade needs no step'
	# confirmation that arrives late, in the middle of the steps
	world upgrade-confirmed-late; CUR=upgrade-confirmed/late
	echo pending > "$T/etc/zerotier-support/upgrade-pending"
	span 60 1140; expect_actions 'zerotier restart'
	GUP=1150 guard_cmd confirm > /dev/null
	span 1200 9000 600
	expect_actions 'zerotier restart' 'the steps stop when the PC confirms'
	check 'state' "$(state_of S_HEALTH)" ok
fi

if want podkop; then
	for kind in not-running own-failsafe busy switched-off absent; do
		world "podkop-$kind"; CUR="podkop/$kind"
		case "$kind" in
			not-running) rm -f "$W/podkop_table" ;;
			own-failsafe) echo x > "$T/etc/sing-box/failsafe.last" ;;
			busy) mkdir -p "$T/tmp/podkop-subscription-action.lock.d" ;;
			switched-off) printf 'PODKOP=0\nCLI_TIMEOUT=0\n' > "$T/etc/zerotier-support/guard.conf" ;;
			absent) rm -f "$T/etc/init.d/podkop" ;;
		esac
		at 60; break_zt; span 120 1500 120
		check 'Podkop is not touched' "$(grep -c '^podkop' "$W/actions")" 0
	done
	world podkop-once; CUR=podkop/once-in-six-hours
	printf 'REBOOT=0\nCLI_TIMEOUT=0\n' > "$T/etc/zerotier-support/guard.conf"
	at 60; break_zt; span 120 1200; span 1800 21000 1800
	check 'one pause in the first six hours' "$(count 'podkop stop')" 1
	check 'and Podkop was started again' "$(count 'podkop start')" 1
	span 21060 23000
	check 'a second pause only after six hours' "$(count 'podkop stop')" 2
	check 'started again too' "$(count 'podkop start')" 2
	world podkop-recovers; CUR=podkop/recovers-during-pause
	at 60; break_zt; span 120 840
	check 'paused' "$(count 'podkop stop')" 1
	fix_zt; span 900 1260
	check 'Podkop comes back although ZeroTier already works' "$(count 'podkop start')" 1
	grep -q 'came back while Podkop was paused' "$T/tmp/zerotier-support/last-incident" && ok || bad 'the record does not say Podkop was in the way'
fi

if want switched-off; then world switched-off
	sed -i 's/^zerotier.global.enabled=1/zerotier.global.enabled=0/' "$W/uci"
	kill "$(cat "$W/pid")"; : > "$W/pid"
	span 60 9000 1800
	expect_actions '' 'ZeroTier switched off in the settings is left off'
	check 'state' "$(state_of S_HEALTH)" idle
	world no-network; CUR=switched-off/no-network
	printf "zerotier.global=zerotier\n" > "$W/uci_show"; break_zt
	span 60 9000 1800; expect_actions '' 'no network configured: nothing to guard'
	world not-at-boot; CUR=switched-off/not-enabled-at-boot
	rm -f "$W/zt_boot"; break_zt
	span 60 9000 1800; expect_actions '' 'service not enabled at boot: nothing to guard'
fi

if want flash-writes; then world flash-writes
	f="$T/$cache"; n=0; last=''; t=60
	while [ "$t" -le 3600 ]; do
		conf_text "$t" > "$T/var/lib/zerotier-one/networks.d/$ID.conf"     # a new timestamp and pass every minute
		at "$t"
		h="$(head -n 1 "$f")"; [ "$h" = "$last" ] || n=$((n + 1)); last="$h"
		t=$((t + 60))
	done
	check 'an hour, the pass changing every minute: one write per ten minutes' "$n" 6
	world flash-writes-still; CUR=flash-writes/unchanged
	f="$T/$cache"; n=0; last=''; t=60
	while [ "$t" -le 7200 ]; do at "$t"; h="$(head -n 1 "$f")"; [ "$h" = "$last" ] || n=$((n + 1)); last="$h"; t=$((t + 300)); done
	check 'two hours, nothing changing: one write' "$n" 1
	conf_text 1000 10.9.8.99/24 > "$T/var/lib/zerotier-one/networks.d/$ID.conf"; echo 10.9.8.99/24 > "$W/ips"
	echo '    inet 10.9.8.99/24 scope global ztlab0' > "$W/dev_ips"
	at 7260
	tail -n +2 "$f" | grep -q '10.9.8.99' && ok || bad 'a changed address is not written at the next check'
	log_has 'settings changed'
	[ "$(ls "$T/etc/zerotier-support" | tr '\n' ' ')" = "guard.conf network-$ID.cache " ] && ok || bad "a healthy router has more on flash than the kept settings: $(ls "$T/etc/zerotier-support" | tr '\n' ' ')"
	check 'the kept copy is private' "$(ls -l "$f" | cut -c1-10)" '-rw-------'
fi

if want live-state; then world live-state
	at 60; rm -f "$W/bypass_chain"; echo ': > "$W/bypass_chain"' > "$W/on_reload"
	at 120; expect_actions 'firewall reload;nft sync' 'a missing bypass chain is put back at once'
	rm -f "$W/bypass_chain" "$W/on_reload"; : > "$W/actions"
	span 180 360; expect_actions '' 'a state that is lost again is not put back within five minutes'
	span 420 480; check 'second try after five minutes' "$(count 'firewall reload')" 1
	span 540 960; check 'not again in the next ten minutes' "$(count 'firewall reload')" 1
	span 1020 1080; check 'third try ten minutes later' "$(count 'firewall reload')" 2
	span 1140 9000 240; n=$(count 'firewall reload')
	[ "$n" -ge 4 ] && [ "$n" -le 6 ] && ok || bad "reloads in two and a half hours of a state that will not come back: $n (expected 4..6)"
	: > "$W/bypass_chain"; at 9060              # in place again: the patience starts anew
	: > "$W/actions"; rm -f "$T/etc/nftables.d/20-podkop-zerotier-bypass.nft" "$W/ssh_rule"
	span 9120 9180
	cmp -s "$T/etc/nftables.d/20-podkop-zerotier-bypass.nft" "$T/usr/libexec/zerotier-support/20-podkop-zerotier-bypass.nft" && ok || bad 'the bypass file was not restored from the template'
	check 'state stays healthy' "$(state_of S_HEALTH)" ok
	world ssh; CUR=live-state/ssh-server
	: > "$W/dropbear_pid"
	at 60; expect_actions 'dropbear start' 'a stopped SSH server is started'
	: > "$W/dropbear_pid"; at 120; at 180; expect_actions 'dropbear start' 'not hammered'
	world ssh-off; CUR=live-state/ssh-server-disabled
	: > "$W/dropbear_pid"; rm -f "$W/dropbear_boot"
	at 60; expect_actions '' 'an SSH server that is switched off stays off'
fi

if want no-answer; then world no-answer
	at 60; : > "$W/cli_fail"
	span 120 300
	expect_actions 'zerotier restart' 'a daemon that does not answer is restarted like an offline one'
	check 'reason' "$(state_of S_REASON)" no-answer
	world no-root; CUR=no-answer/no-root
	printf '200 peers\n<ztaddr>   <ver>  <role> <lat> <link>   <lastTX> <lastRX> <path>\n778cde7190 -      PLANET   -1 RELAY\ncafe04eba9 -      PLANET   -1 RELAY\n1234567890 1.14.1 LEAF     12 DIRECT 100 100 192.0.2.1/9993\n' > "$W/peers"
	at 60; check 'no root server reachable is a fault' "$(state_of S_REASON)" no-root
fi

if want status-text; then world status-text
	span 60 120; break_zt; span 180 400
	GUP=410 guard_cmd status > "$W/status.out" 2>&1
	grep -q 'Сторож доступа ZeroTier' "$W/status.out" && grep -q 'ZeroTier не в сети' "$W/status.out" && grep -q 'сделано: restart' "$W/status.out" && ok || bad "status text: $(head -5 "$W/status.out" | tr '\n' '|')"
	grep -q "$ID" "$W/status.out" && bad 'status prints the whole network id' || ok
fi

echo "guard scenarios: passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
