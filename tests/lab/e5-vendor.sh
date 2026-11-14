#!/bin/bash
# PC only (WSL, root). The app on a router whose firmware starts ZeroTier its own way (a vendor start-up script like
# RouteRich's: ZeroTier's home on flash, networks in "list join", no respawn, a "stop" that deletes the networks'
# settings; see stand-ins/initd-zerotier-vendor). The installer is run the way a management tool runs it:
# router-direct-install.sh of a revision, pointed at that revision (file:// as in e4: TCP between the lab's
# namespaces does not work in this WSL).
#   V1  the published revision (BASE, default 6896e83) on such a router: what happened on the real one;
#   V2  the new revision, the install killed half-way: the tool must still offer the update;
#   V3  the new revision: the install must finish, the fixed ports apply the firmware's way, the guard is on;
#   V4  the guard starts a daemon that died (nothing else starts it there) without the script's stop;
#   V5  the firmware's own restart while the controller is away: the guard puts the kept settings back.
# Real: the router's shell, rc.common, uci, jq, curl, reload_config, the helper, both installers, ZeroTier, the guard.
# Stand-ins: procd/ubus, nft, fw4, the firewall init script, sysupgrade -b, the vendor's start-up script itself.
# usage: e5-vendor.sh [24.10|25.12] [base revision]      about 15 minutes
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); repo=$(cd "$here/../.." && pwd)
ver=${1:-24.10}; BASE=${2:-6896e83}; tag=vd${ver//./}
export ZT_LAB_NAME=$tag
. "$here/lab.sh"
RU=$L/root-$tag
PASS=0; FAIL=0
say() { echo "[$(date +%H:%M:%S)] $*"; }
ok() { PASS=$((PASS + 1)); echo "CHECK ok   $*"; }
bad() { FAIL=$((FAIL + 1)); echo "CHECK FAIL $*"; }
check() { if "${@:2}" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
A() { lab_in A "$tag" "export PATH=/tmp/lab/bin:/usr/sbin:/usr/bin:/sbin:/bin; $1"; }
G="git -c safe.directory=* -C $repo"
sha() { sha256sum "$1" 2>/dev/null | cut -c1-64; }
zt_pid() { cat "$N/A/tmp/procd/zerotier.pid" 2>/dev/null; }   # a pid inside the router's own process namespace
zt_alive() { A 'pidof zerotier-one' > /dev/null 2>&1; }          # so it is looked for and killed only from inside
zt_dead() { ! zt_alive; }
HOME_F=$RU/etc/config/zero
TRACKED="usr/libexec/zerotier-support/helper usr/libexec/zerotier-support/20-podkop-zerotier-bypass.nft usr/share/rpcd/ucode/zerotier.support usr/share/rpcd/acl.d/zerotier-support.json usr/share/luci/menu.d/zerotier-support.json www/luci-static/resources/view/services/zerotier.js"
tool_says() {  # what a checksum-comparing management tool would conclude: six files, against a revision's files
	local f; for f in $TRACKED; do [ "$(sha "$RU/$f")" = "$(sha "$1/openwrt/$f")" ] || { echo update; return; }; done; echo current
}
ports() { lab_cli A info -j 2>/dev/null | jq -r '[.config.settings.primaryPort, .config.settings.secondaryPort, .config.settings.tertiaryPort] | map(tostring) | join(" ")'; }
guard_on() { ls "$RU/etc/rc.d" | grep -q zerotier-guard; }
diag() {  # what the lab looked like when something basic failed
	echo "--- procd:"; tail -8 "$N/A/tmp/procd/log" 2>/dev/null; cat "$N/A/tmp/procd/zerotier.cmd" 2>/dev/null; echo
	echo "--- vendor script:"; tail -5 "$N/A/tmp/vendor-init-calls" 2>/dev/null; tail -5 "$N/A/init-start.log" 2>/dev/null
	echo "--- home:"; ls -la "$N/A/varlib/" "$HOME_F" "$HOME_F/networks.d" 2>&1 | sed -E 's/[0-9a-f]{16}/<id>/g' | head -20
	echo "--- daemon:"; A 'pidof zerotier-one; zerotier-cli info; zerotier-cli listnetworks' 2>&1 | sed -E 's/[0-9a-f]{16}/<id>/g' | head -8
}
conf_kept() { [ "$(wc -c < "$HOME_F/networks.d/$NW.conf" 2>/dev/null || echo 0)" -gt 64 ]; }
uci_has() { grep -q "$1" "$RU/etc/config/zerotier"; }

say "=== the app on a vendor start-up script, OpenWrt $ver, published revision $BASE"
lab_base || { say "LAB BROKEN"; lab_down; exit 1; }

# ---- the router: a private copy of the lab root with the vendor's start-up script and no app yet
rm -rf "$RU"; cp -a "$L/root-$ver" "$RU"
[ -x "$RU/usr/bin/jq" ] || { say "the lab root $ver has no jq: build it with ZT_LAB_JQ_IMAGE, see lab-roots.sh"; lab_down; exit 1; }
cp "$here/stand-ins/initd-zerotier-vendor" "$RU/etc/init.d/zerotier"; chmod 755 "$RU/etc/init.d/zerotier"
rm -f "$RU"/etc/rc.d/*zerotier*; ln -s ../init.d/zerotier "$RU/etc/rc.d/S99zerotier"
cp "$here/stand-ins/initd-firewall" "$RU/etc/init.d/firewall"; chmod 755 "$RU/etc/init.d/firewall"
mkdir -p "$RU/usr/share/luci/menu.d" "$RU/www/luci-static/resources/view" "$RU/etc/nftables.d"
rm -rf "$RU/usr/libexec/zerotier-support" "$RU/etc/zerotier-router-support.conf" "$HOME_F"
lab_first_start A "$ver"; lab_stop A
mkdir -p "$N/A/varlib" "$N/A/flash" "$N/A/ram" "$N/A/tmp/procd" "$N/A/tmp/bin" "$N/A/tmp/moon" "$N/A/tmp/job"
# as on the real router: the vendor's own section, plus two left by an older version of the panel ("global" holds
# only enabled=1 and makes the vendor script start a second program that fails at once)
cat > "$RU/etc/config/zerotier" <<EOF
config zerotier 'sample_config'
	option enabled '1'
	list join '$NW'
	option nat '1'
	option secret '$(cat "$N/A/identity.secret")'

config zerotier 'global'
	option enabled '1'

config network 'router_support'
	option id '$NW'
	option allow_managed '1'
	option allow_global '0'
	option allow_default '0'
	option allow_dns '0'
EOF
cp "$N/M/home/moons.d/"*.moon "$N/A/tmp/moon/"
for s in ubus reboot nft fw4 sysupgrade mini-procd; do cp "$here/stand-ins/$s" "$N/A/tmp/bin/$s"; done; chmod 755 "$N/A/tmp/bin/"*
echo "$tag" > "$N/A/root"
bg() { ZT_LAB_NAME=$LAB ZT_LAB_DIR=$L setsid bash -c ". '$LAB_SH'; lab_in A $tag 'export PATH=/tmp/lab/bin:/usr/sbin:/usr/bin:/sbin:/bin; $2'" > "$N/A/$1.log" 2>&1 < /dev/null & }
bg mini-procd 'exec /bin/ash /tmp/lab/bin/mini-procd'
A '/etc/init.d/zerotier start' > "$N/A/init-start.log" 2>&1
lab_wait 30 "the vendor script started the daemon" test -s "$N/A/tmp/procd/zerotier.pid"; sleep 6
lab_ctl POST "/controller/network/$NW/member/$(lab_addr A)" '{"authorized":true}' >/dev/null
lab_wait 90 "the router is in its network" lab_has_ok A || { say "LAB BROKEN: no network"; diag; lab_down; rm -rf "$RU"; exit 1; }
A_IP=$(lab_zt_ip A); lab_wait 60 "the other member reaches the router" lab_ping_from_b "$A_IP"
check "V0 ZeroTier's home is the vendor's, on flash" test -L "$N/A/varlib/zerotier-one" -a -s "$HOME_F/identity.secret"
check "V0 procd was not asked to start the program again (no respawn)" test ! -e "$N/A/tmp/procd/zerotier.respawn"
say "ports before: $(ports)"

# ---- a revision, served as GitHub serves it (Unix line endings)
serve() {  # <dir> <git revision | "work">
	rm -rf "$1"; mkdir -p "$1"
	local f list
	if [ "$2" = work ]; then list=$(grep -o '^fetch_file "[^"]*"' "$repo/router-direct-install.sh" | cut -d'"' -f2)
	else list=$($G show "$2:router-direct-install.sh" | grep -o '^fetch_file "[^"]*"' | cut -d'"' -f2); fi
	for f in router-direct-install.sh openwrt/MANIFEST.sha256 $list; do
		mkdir -p "$1/$(dirname "$f")"
		if [ "$2" = work ]; then tr -d '\r' < "$repo/$f" > "$1/$f"; else $G show "$2:$f" > "$1/$f"; fi
	done
}
upgrade() {  # <served dir, under /tmp/lab>: as a management tool's job does; reload_config before and after, as LuCI
	cp "$N/A/tmp/$1/router-direct-install.sh" "$N/A/tmp/job/install.sh"; rm -f "$N/A/tmp/job/exitcode"
	A "reload_config; cd /tmp/lab/job && ZRS_BASE_URL=file:///tmp/lab/$1 sh ./install.sh > job.log 2>&1; echo \$? > exitcode; : > /tmp/lab/ubus-calls; reload_config"
	cat "$N/A/tmp/job/exitcode" 2>/dev/null
}
serve "$N/A/tmp/www-old" "$BASE"
serve "$N/A/tmp/www" work

say "--- V1 the published revision on this firmware"
: > "$N/A/tmp/vendor-init-calls"
rc=$(upgrade www-old)
say "exit $rc; the installer said: $(grep -E 'порты|откат|Восстанавлива' "$N/A/tmp/job/job.log" | head -3 | tr '\n' '|')"
cp "$N/A/tmp/job/job.log" "$N/A/v1-job.log"
check "V1 reproduced: the published installer ends with an error (exit $rc)" test "$rc" != 0
check "V1 reproduced: it says the fixed ports did not apply and rolls back" grep -q 'постоянные порты не применились' "$N/A/v1-job.log"
check "V1 reproduced: the guard's files are there, the guard is off" bash -c "[ -x '$RU/usr/libexec/zerotier-support/guard' ] && ! ls '$RU/etc/rc.d' | grep -q zerotier-guard"
check "V1 reproduced: a checksum-comparing tool would call it current" test "$(tool_says "$N/A/tmp/www-old")" = current
check "V1 its restarts went through the vendor's stop (the networks' settings were deleted)" grep -q 'stop sample_config' "$N/A/tmp/vendor-init-calls"
lab_wait 90 "V1 the router is back in its network after the rollback" lab_has_ok A && ok "V1 the router is in its network again" || bad "V1 the router did not come back"
# the state the real router is in now, kept to start V3 from it
cp -p "$RU/etc/config/zerotier" "$N/after-v1.uci"
zt_ready() { lab_online A && lab_has_ok A; }
like_after_v1() {  # back to that state: its settings, no local.conf anywhere (as on the real router), the program anew
	cp -p "$N/after-v1.uci" "$RU/etc/config/zerotier"
	rm -f "$HOME_F/local.conf" "$RU/etc/zerotier-router-support.conf" "$RU/etc/nftables.d/20-podkop-zerotier-bypass.nft"
	A 'kill $(pidof zerotier-one) 2>/dev/null; sleep 3; /etc/init.d/zerotier start' > /dev/null 2>&1
	sleep 5; lab_wait 90 "the router is ONLINE and in its network (state after V1)" zt_ready; sleep 5
}

say "--- V2 the new revision, the install killed half-way"
: > "$N/A/tmp/die-once"
rc=$(upgrade www)
check "V2 the run ended with an error (exit $rc)" test "$rc" != 0
check "V2 the guard is not switched on by a half-finished install" bash -c "! ls '$RU/etc/rc.d' | grep -q zerotier-guard"
check "V2 a checksum-comparing tool still offers the update (the old helper is in place)" test "$(tool_says "$N/A/tmp/www")" = update
cp "$N/A/tmp/job/job.log" "$N/A/v2-job.log"; cp "$N/A/tmp/firewall-calls" "$N/A/v2-firewall-calls" 2>/dev/null
say "after the kill: section 'global' $(grep -q "zerotier 'global'" "$RU/etc/config/zerotier" && echo 'still there (rolled back or not reached)' || echo removed), local.conf in the home: $(readlink "$HOME_F/local.conf" || echo none), ports $(ports); the installer's last lines: $(tail -2 "$N/A/v2-job.log" | tr '\n' '|' | cut -c1-200)"
check "V2 the installer was really killed (no rollback of its own)" bash -c "! grep -q 'автоматический откат' '$N/A/v2-job.log'"
sleep 20; say "20 s later the ports are: $(ports) (does ZeroTier take a new local.conf without a restart?)"
check "V2 reload_config afterwards does not restart ZeroTier (the settings and its record agree)" bash -c "! grep -q zerotier '$N/A/tmp/ubus-calls'"
rm -f "$N/A/tmp/die-once"

say "--- V3 the new revision, from the state of the real router after V1, with the other member pinging the router"
like_after_v1
say "ports before V3: $(ports)"
PID0=$(zt_pid); : > "$N/A/tmp/vendor-init-calls"; : > "$N/A/tmp/firewall-calls"
ip netns exec "$NS-B" ping -i 1 -w 240 -W 2 -q "$A_IP" > "$N/ping.log" 2>&1 &
pingpid=$!
t0=$(date +%s); rc=$(upgrade www); t1=$(date +%s)
sleep 5; kill -INT $pingpid 2>/dev/null; wait $pingpid 2>/dev/null
cp "$N/A/tmp/job/job.log" "$N/A/v3-job.log"
say "the install took $((t1 - t0)) s; ping during it: $(grep -o '[0-9]* packets transmitted, [0-9]* received' "$N/ping.log"); ports now: $(ports)"
say "the installer said: $(grep -E 'ZeroTier (вернулся|работает)|Удалена секция|порт' "$N/A/v3-job.log" | head -4 | tr '\n' '|')"
check "V3 the installer finished without an error" test "$rc" = 0
check "V3 the fixed ports apply on this firmware (9993 25534 34923)" test "$(ports)" = "9993 25534 34923"
check "V3 ZeroTier reads them from its own home: local.conf there points to the app's settings" test "$(readlink "$HOME_F/local.conf")" = /etc/zerotier-router-support.conf
check "V3 the stray section 'global' is gone, the vendor's own and the network section are kept" bash -c "! grep -q \"zerotier 'global'\" '$RU/etc/config/zerotier' && grep -q \"list join '$NW'\" '$RU/etc/config/zerotier' && grep -q \"config network 'router_support'\" '$RU/etc/config/zerotier'"
check "V3 no uci setting of the stock package was written on this firmware" bash -c "! grep -Eq 'local_conf_path|option port' '$RU/etc/config/zerotier'"
cp "$N/A/tmp/vendor-init-calls" "$N/A/v3-vendor-init-calls"; tail -12 "$N/A/tmp/procd/log" > "$N/A/v3-procd.log"
say "pid before $PID0, after $(zt_pid); the vendor's script was asked: $(cut -d' ' -f2- "$N/A/v3-vendor-init-calls" | tr '\n' '|')"
say "$( [ "$(zt_pid)" != "$PID0" ] && echo 'ZeroTier was restarted by the installer' || echo 'ZeroTier was not restarted: it took the new local.conf by itself')"
check "V3 never through the vendor's stop" bash -c "! grep -q stop '$N/A/v3-vendor-init-calls'"
check "V3 at most one start of the vendor's section, and a new program only with it" bash -c "n=\$(grep -c 'start sample_config' '$N/A/v3-vendor-init-calls'); [ \"\$n\" -le 1 ] && { [ \"\$n\" = 1 ] || [ '$(zt_pid)' = '$PID0' ]; }"
check "V3 the network's settings on flash were never deleted" conf_kept
check "V3 one program only: the failing second instance is not started any more" bash -c "! grep -q 'start global' '$N/A/tmp/vendor-init-calls'"
check "V3 reload_config afterwards does not restart ZeroTier" bash -c "! grep -q 'zerotier' '$N/A/tmp/ubus-calls'"
lost=$(awk '/packets transmitted/{print $1 - $4}' "$N/ping.log")
check "V3 at most a short gap in the pings during the one restart (lost: ${lost:-?})" test "${lost:-99}" -le 20
check "V3 the router is in its network with the same address" test "$(lab_zt_ip A)" = "$A_IP"
check "V3 the guard is switched on" guard_on
check "V3 a checksum-comparing tool now says: current" test "$(tool_says "$N/A/tmp/www")" = current
check "V3 no staged helper is left behind" test ! -e "$RU/usr/libexec/zerotier-support/helper.new"
PID3=$(zt_pid); rc=$(upgrade www)
check "V3 a second run succeeds and does not restart ZeroTier" bash -c "[ '$rc' = 0 ] && [ \"\$(cat '$N/A/tmp/procd/zerotier.pid')\" = '$PID3' ] && grep -q 'перезапуск не требуется' '$N/A/tmp/job/job.log'"
say "second run: exit $rc; $(grep -E 'перезапуск|без перезапуска|вернулся|работает в своих' "$N/A/tmp/job/job.log" | head -2 | tr '\n' '|')"

say "--- V4 the guard at work; the daemon dies and nothing but the guard starts it again here"
printf 'INTERVAL=15\nGRACE=30\nSEED_AFTER=60\nCACHE_MIN_GAP=30\n' > "$N/A/flash/guard.conf"
bg guard 'exec /usr/libexec/zerotier-support/guard daemon'
lab_wait 60 "the guard started" bash -c "grep -q 'guard started' '$N/A/ram/guard.log'"
sleep 45
check "V4 the guard finds a healthy router and takes no step" bash -c "! grep -q 'step:' '$N/A/ram/guard.log'"
check "V4 the network settings are kept on flash" test -s "$N/A/flash/network-$NW.cache"
: > "$N/A/tmp/vendor-init-calls"; A 'kill $(pidof zerotier-one)'
lab_wait 20 "the daemon is gone" zt_dead
lab_wait 60 "the guard started the daemon again" zt_alive && ok "V4 the guard started the daemon again" || bad "V4 the daemon stays dead"
check "V4 procd did not start it by itself (no respawn asked for); the guard did" bash -c "grep -q 'no respawn asked for' '$N/A/tmp/procd/log' && grep -q 'daemon is not running, starting it' '$N/A/ram/guard.log'"
check "V4 through the script's start, never its stop" bash -c "grep -q 'start sample_config' '$N/A/tmp/vendor-init-calls' && ! grep -q stop '$N/A/tmp/vendor-init-calls'"
check "V4 the network's settings on flash were not deleted" conf_kept
lab_wait 60 "the router is in its network again" lab_has_ok A && ok "V4 the router is in its network again" || bad "V4 no network after the start"
lab_wait 60 "the other member reaches the router" lab_ping_from_b "$A_IP" && ok "V4 reachable" || bad "V4 not reachable"

say "--- V5 the firmware's own restart while the controller is away"
sleep 40   # a fresh copy of the settings on flash
lab_isolate C
: > "$N/A/tmp/vendor-init-calls"
A '/etc/init.d/zerotier restart' > /dev/null 2>&1
check "V5 the vendor's restart deleted the network's settings (the daemon waits for them)" bash -c "! [ \"\$(wc -c < '$HOME_F/networks.d/$NW.conf')\" -gt 64 ]"
lab_wait 240 "the guard put the kept settings back and the router is in its network without the controller" lab_has_ok A &&
	ok "V5 in its network again while the controller is away" || bad "V5 no network without the controller"
check "V5 the guard says why" grep -q 'kept network settings put back' "$N/A/ram/guard.log"
check "V5 the guard used the script's start, not its stop" bash -c "[ \"\$(grep -c stop '$N/A/tmp/vendor-init-calls')\" = 1 ]"
lab_wait 60 "the other member reaches the router" lab_ping_from_b "$A_IP" && ok "V5 reachable without the controller" || bad "V5 not reachable"
lab_connect C

mkdir -p "$L/results"
for f in v1-job.log v2-job.log v2-firewall-calls v3-job.log v3-vendor-init-calls v3-procd.log; do cp "$N/A/$f" "$L/results/e5-$ver-$f" 2>/dev/null; done
cp "$N/A/ram/guard.log" "$L/results/e5-$ver-guard.log" 2>/dev/null
lab_down; rm -rf "$RU"
say "E5_DONE passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
