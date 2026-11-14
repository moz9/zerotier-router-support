#!/bin/bash
# PC only (WSL, root). The real guard against the real things, as far as a PC allows:
#   - the router's own ZeroTier daemon (1.14.1 of OpenWrt 24.10 or 1.16.2 of 25.12) in a real ZeroTier network of the
#     closed lab (lab.sh), started and stopped by the STOCK /etc/init.d/zerotier through the router's own
#     /etc/rc.common, shell, uci and jsonfilter;
#   - the guard running as a daemon in that same root.
# Stand-ins (tests/lab/stand-ins): procd (keeps procd's respawn rules), ubus, reboot (only writes down the request),
# nft and the firewall init script (qemu cannot pass nftables through). Podkop is absent. Times are shortened
# through the guard's own settings file, so that a half-hour ladder takes minutes.
# What this cannot show: real procd, real firewall reload, a real reboot, Podkop. Those need a router.
# usage: e2-guard.sh <24.10|25.12>      about 15 minutes; prints "CHECK ok|FAIL ..." lines and a summary
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); repo=$(cd "$here/../.." && pwd)
ver=${1:-25.12}
export ZT_LAB_NAME=guard${ver//./}
. "$here/lab.sh"
R=$L/root-$ver
PASS=0; FAIL=0
say() { echo "[$(date +%H:%M:%S)] $*"; }
ok() { PASS=$((PASS + 1)); echo "CHECK ok   $*"; }
bad() { FAIL=$((FAIL + 1)); echo "CHECK FAIL $*"; }
check() { if "${@:2}" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
A() { lab_in A "$ver" "export PATH=/tmp/lab/bin:/usr/sbin:/usr/bin:/sbin:/bin; $1"; }     # a command on the "router"
glog() { cat "$N/A/ram/guard.log" 2>/dev/null; }
steps() { glog | grep -c "step: $1"; }
wait_log() { lab_wait "$1" "guard log: $2" bash -c "grep -q '$2' '$N/A/ram/guard.log'"; }
zt_pid() { cat "$N/A/tmp/procd/zerotier.pid" 2>/dev/null; }
reboots() { wc -l < "$N/A/tmp/reboots" 2>/dev/null || echo 0; }
reboots_over() { [ "$(reboots)" -gt "$1" ]; }
st_is() { [ "$(lab_st A)" = "$1" ]; }
new_log_line() { tail -n +$(( $1 + 1 )) "$N/A/ram/guard.log" 2>/dev/null | grep -q "$2"; }   # a line after line $1

say "=== the guard with the real ZeroTier of OpenWrt $ver"
lab_base || { say "LAB BROKEN"; lab_down; exit 1; }

# ---- the "router": the app's files and the guard in the root, lab settings, stand-ins
mkdir -p "$R/usr/libexec/zerotier-support" "$R/etc/config" "$R/etc/rc.d"
tr -d '\r' < "$repo/openwrt/usr/libexec/zerotier-support/guard" > "$R/usr/libexec/zerotier-support/guard"; chmod 755 "$R/usr/libexec/zerotier-support/guard"
tr -d '\r' < "$repo/openwrt/usr/libexec/zerotier-support/20-podkop-zerotier-bypass.nft" > "$R/usr/libexec/zerotier-support/20-podkop-zerotier-bypass.nft"
[ -e "$R/etc/rc.d/S90zerotier" ] || ln -s ../init.d/zerotier "$R/etc/rc.d/S90zerotier"
# the app's bypass file, where its installer puts it
mkdir -p "$R/etc/nftables.d"; cp "$R/usr/libexec/zerotier-support/20-podkop-zerotier-bypass.nft" "$R/etc/nftables.d/20-podkop-zerotier-bypass.nft"
[ -e "$R/etc/config/zerotier" ] || : > "$R/etc/config/zerotier"
lab_first_start A "$ver"; lab_stop A
mkdir -p "$N/A/flash" "$N/A/ram" "$N/A/tmp/procd" "$N/A/tmp/bin" "$N/A/tmp/moon" "$N/A/over/etc/config" "$N/A/over/etc/init.d"
cp "$N/M/home/moons.d/"*.moon "$N/A/tmp/moon/"
for s in ubus reboot nft mini-procd; do cp "$here/stand-ins/$s" "$N/A/tmp/bin/$s"; done
cp "$here/stand-ins/initd-firewall" "$N/A/over/etc/init.d/firewall"; cp "$here/stand-ins/initd-off" "$N/A/over/etc/init.d/dropbear"
chmod 755 "$N/A/tmp/bin/"* "$N/A/over/etc/init.d/"*
cat > "$N/A/over/etc/config/zerotier" <<EOF
config zerotier 'global'
	option enabled '1'
	option secret '$(cat "$N/A/identity.secret")'
	option port '9993'

config network 'router_support'
	option id '$NW'
	option allow_managed '1'
	option allow_global '0'
	option allow_default '0'
	option allow_dns '0'
EOF
chmod 600 "$N/A/over/etc/config/zerotier"
cat > "$N/A/flash/guard.conf" <<'EOF'
INTERVAL=5
FAIL_RESTART=20
FAIL_REAPPLY=35
FAIL_PODKOP=50
FAIL_REBOOT=90
REBOOT=1
REBOOT_MIN_UPTIME=1
REBOOT_GAP=1000000000
RESTART_GAP=30
RESTART_GAP_MAX=60
GRACE=10
BOOT_GRACE=0
CONTROLLER_RESTART=0
HISTORY_GAP=5
SEED_AFTER=15
CACHE_REFRESH=20
CACHE_MIN_GAP=10
CONFIRM=1
EOF
bg() { ZT_LAB_NAME=$LAB ZT_LAB_DIR=$L setsid bash -c ". '$LAB_SH'; lab_in A $ver 'export PATH=/tmp/lab/bin:/usr/sbin:/usr/bin:/sbin:/bin; $2'" > "$N/A/$1.log" 2>&1 < /dev/null & }
echo "$ver" > "$N/A/root"
bg mini-procd 'exec /bin/ash /tmp/lab/bin/mini-procd'
A '/etc/init.d/zerotier start' > "$N/A/init-start.log" 2>&1
lab_wait 30 "the stock init script started the daemon through rc.common" test -s "$N/A/tmp/procd/zerotier.pid"
sleep 6
lab_ctl POST "/controller/network/$NW/member/$(lab_addr A)" '{"authorized":true}' >/dev/null
lab_wait 90 "A is in the network with an address" lab_has_ok A || { say "LAB BROKEN: A did not join"; tail -5 "$N/A/init-start.log"; lab_down; exit 1; }
A_IP=$(lab_zt_ip A)
lab_wait 60 "B reaches A (ping)" lab_ping_from_b "$A_IP"
check "the stock init script is the router's own, unchanged" cmp -s "$R/etc/init.d/zerotier" "$L/root-24.10/etc/init.d/zerotier"
check "pidof finds the daemon in this root" test "$(A 'pidof zerotier-one')" = "$(A 'cat /tmp/lab/procd/zerotier.pid')"

say "--- G1 a healthy router"
bg guard 'exec /usr/libexec/zerotier-support/guard daemon'
wait_log 40 'guard started'
lab_wait 60 "the network settings are kept on flash" test -s "$N/A/flash/network-$NW.cache"
sleep 20
check "G1 a healthy router: no step taken" test "$(glog | grep -c 'step:')" = 0
check "G1 the kept copy is whole (header, checksum, this network)" bash -c "h=\$(head -n1 '$N/A/flash/network-$NW.cache'); set -- \$h; [ \"\$1\" = zrs-cache-v1 ] && [ \"\$4\" = '$NW' ] && [ \"\$(tail -n +2 '$N/A/flash/network-$NW.cache' | sha256sum | cut -c1-64)\" = \"\$2\" ]"
check "G1 nothing else on flash" test "$(ls "$N/A/flash" | tr '\n' ' ')" = "guard.conf network-$NW.cache "
A '/usr/libexec/zerotier-support/guard status 3' > "$N/A/status.txt" 2>&1
check "G1 status says all is well" grep -q 'всё в порядке' "$N/A/status.txt"
h1=$(head -n1 "$N/A/flash/network-$NW.cache"); sleep 75; h2=$(head -n1 "$N/A/flash/network-$NW.cache")
check "G1 the kept copy is refreshed while the controller keeps issuing passes" test "$h1" != "$h2"

say "--- G2 the daemon keeps dying"
# first with the guard watching: it steps in as soon as it sees the daemon down twice in ten seconds
for i in 1 2 3; do
	p=$(zt_pid); [ -n "$p" ] || break
	A "kill -9 $p" 2>/dev/null
	lab_wait 20 "kill #$i: the daemon is started again" bash -c "p2=\$(cat '$N/A/tmp/procd/zerotier.pid' 2>/dev/null); [ -n \"\$p2\" ] && [ \"\$p2\" != '$p' ]" || break
done
lab_wait 90 "the daemon is back and in its network" lab_has_ok A && ok "G2 killed three times with the guard watching: back in its network" || bad "G2 not back after three kills"
lab_wait 120 "the guard sees a healthy router again" bash -c "tail -n 3 '$N/A/ram/guard.log' | grep -q 'ZeroTier is back\|brought it back'"
# then the case the stock system cannot handle: the guard is not running, procd uses up its five tries and gives up
A 'kill $(cat /tmp/zerotier-support/guard.pid)' 2>/dev/null; sleep 2
for i in 1 2 3 4 5 6 7; do
	p=$(zt_pid); [ -n "$p" ] || break
	A "kill -9 $p" 2>/dev/null
	lab_wait 12 "kill #$i without the guard: procd's stand-in starts it again" bash -c "p2=\$(cat '$N/A/tmp/procd/zerotier.pid' 2>/dev/null); [ -n \"\$p2\" ] && [ \"\$p2\" != '$p' ]" || break
done
check "G2 procd gave up after its limit, as on a router" grep -q 'crash loop' "$N/A/tmp/procd/log"
sleep 15
check "G2 and without the guard the daemon stays down" test -z "$(A 'pidof zerotier-one')"
bg guard 'exec /usr/libexec/zerotier-support/guard daemon'
wait_log 60 'the ZeroTier daemon is not running, starting it'
lab_wait 90 "the daemon is back and in its network" lab_has_ok A
check "G2 the guard started the dead daemon through the init script" grep -q 'service set by its init script' <(tail -n 3 "$N/A/tmp/procd/log")
lab_wait 60 "B reaches A (ping)" lab_ping_from_b "$A_IP" && ok "G2 access is back after procd had given up" || bad "G2 no access after the guard's start"

say "--- G3 the controller is unreachable and the daemon is restarted the stock way"
lab_wait 120 "the guard sees a healthy router again" bash -c "tail -n 1 '$N/A/ram/guard.log' | grep -q 'ZeroTier is back'"
sleep 25
r0=$(steps 'restart'); s0=$(steps 'the ZeroTier daemon is not running')
lab_stop C; sleep 2
A '/etc/init.d/zerotier restart' > /dev/null 2>&1
lab_wait 12 "after the stock restart the network waits for settings" st_is REQUESTING_CONFIGURATION || true
t0=$(date +%s)
wait_log 90 'kept network settings put back'
lab_wait 60 "A has its address again without the controller" lab_has_ok A && ok "G3 address back $(( $(date +%s) - t0 )) s after the restart, from the kept settings" || bad "G3 no address from the kept settings"
lab_wait 60 "B reaches A (ping)" lab_ping_from_b "$A_IP" && ok "G3 B reaches A while the controller is still unreachable" || bad "G3 no access with the kept settings"
check "G3 no init-script restart was needed for it" test "$(steps 'restart')" = "$r0"
check "G3 procd's stand-in restarted the program without the init script" grep -q 'instance exited' <(tail -n 4 "$N/A/tmp/procd/log")

say "--- G4 the kept settings are damaged, the controller still unreachable"
sleep 20
head -c 150 "$N/A/flash/network-$NW.cache" > "$N/A/flash/x" && mv "$N/A/flash/x" "$N/A/flash/network-$NW.cache"
rb0=$(reboots); r0=$(steps 'restart')
A '/etc/init.d/zerotier restart' > /dev/null 2>&1
wait_log 90 'kept network settings not used: damaged'
# (the file is absent for a moment whenever the init script is starting the daemon anew: that counts as empty)
check "G4 the damaged copy was not given to the daemon" test "$(cat "$N/A/home/networks.d/$NW.conf" 2>/dev/null | wc -c)" -le 1
lab_wait 180 "the reboot is asked for, as the last step" reboots_over "$rb0"
check "G4 a restart and the firewall state were tried before the reboot" bash -c "[ \$(grep -c 'step: restart' '$N/A/ram/guard.log') -gt $r0 ] && grep -q 'step: re-apply' '$N/A/ram/guard.log'"
check "G4 the reboot is counted on flash" grep -q '^count=1' "$N/A/flash/reboots"
check "G4 the last incident is on flash" grep -q '^state=rebooted' "$N/A/flash/last-incident"
sleep 60
check "G4 no second reboot follows" test "$(reboots)" = $((rb0 + 1))
lab_start C 24.10
lab_wait 60 "controller is back" lab_online C
lab_wait 150 "A is in its network again" lab_has_ok A
wait_log 60 'ZeroTier is back'
lab_wait 60 "B reaches A (ping)" lab_ping_from_b "$A_IP" && ok "G4 access returns when the controller does" || bad "G4 no access after the controller returned"
rm -f "$N/A/flash/reboots"

say "--- G5 a firmware upgrade is running while ZeroTier is cut off"
sleep 30
bg fake-upgrade 'echo "sleep 400" > /tmp/sysupgrade; exec /bin/ash /tmp/sysupgrade -n /tmp/firmware.bin'
sleep 3
n0=$(glog | grep -c 'step:'); rb0=$(reboots)
ln0=$(glog | wc -l)
lab_isolate A
# ZeroTier itself needs minutes to see that it is cut off: the root server's path goes stale after about four
# and a half minutes, the node says OFFLINE only after more than eight
t0=$(date +%s)
lab_wait 600 "the guard notices that ZeroTier is cut off" new_log_line "$ln0" 'problem' && say "noticed $(( $(date +%s) - t0 )) s after the cable was pulled: $(tail -n +$((ln0 + 1)) "$N/A/ram/guard.log" | grep -m1 problem | cut -d' ' -f3-)"
sleep 130
check "G5 no step while the upgrade runs (cut off for more than the whole ladder)" test "$(glog | grep -c 'step:')" = "$n0"
check "G5 the guard says why it holds back" bash -c "grep -q 'held back: firmware upgrade' '$N/A/ram/guard.log'"
check "G5 no reboot during the upgrade" test "$(reboots)" = "$rb0"
A 'pkill -f "ash /tmp/sysupgrade"' 2>/dev/null    # inside the node: another lab on this PC may have its own
sleep 75
# with the cable pulled the router has no way out at all (no root server, no public address answers): after the
# upgrade the steps still wait, because nothing on the router could help
check "G5 after the upgrade, still no step: with the cable pulled there is no internet at all" test "$(glog | grep -c 'step:')" = "$n0"
check "G5 the guard says there is no internet" bash -c "grep -q 'no internet (' '$N/A/ram/guard.log'"
lab_connect A
lab_wait 150 "cable back: A is in its network" lab_has_ok A
lab_wait 90 "B reaches A (ping)" lab_ping_from_b "$A_IP" && ok "G5 access returns after the cable is back" || bad "G5 no access after the cable is back"
wait_log 90 'ZeroTier is back'
rm -f "$N/A/flash/reboots"

say "--- G6 a firmware upgrade that nobody confirms, then the PC confirms"
sleep 20
n0=$(glog | grep -c 'step:')
echo pending > "$N/A/flash/upgrade-pending"
wait_log 60 'did not confirm the firmware upgrade'
lab_wait 60 "the first step for an unconfirmed upgrade" bash -c "[ \$(grep -c 'step:' '$N/A/ram/guard.log') -gt $n0 ]"
ln0=$(glog | wc -l)
A '/usr/libexec/zerotier-support/guard confirm' > "$N/A/confirm.txt" 2>&1
check "G6 confirm answers and removes the marker" bash -c "grep -q 'Подтверждено' '$N/A/confirm.txt' && [ ! -e '$N/A/flash/upgrade-pending' ]"
lab_wait 90 "the guard closes the matter" new_log_line "$ln0" 'the upgrade was confirmed\|ZeroTier is back'
n1=$(glog | grep -c 'step:'); sleep 45
check "G6 no further step after the confirmation" test "$(glog | grep -c 'step:')" = "$n1"
lab_wait 60 "A is in its network" lab_has_ok A
lab_wait 60 "B reaches A (ping)" lab_ping_from_b "$A_IP" && ok "G6 the router is reachable at the end" || bad "G6 not reachable at the end"

say "--- G7 the controller stops refreshing the settings while the router itself stays in the network"
sleep 30
ln0=$(glog | wc -l); r0=$(steps 'restart'); rb0=$(reboots)
printf 'CONTROLLER_RESTART=1\nCONTROLLER_SILENT=30\nCONTROLLER_RETRY=600\n' >> "$N/A/flash/guard.conf"
lab_stop C
lab_wait 150 "the guard notices that nothing fresh arrives" new_log_line "$ln0" 'problem: controller-silent' && ok "G7 the silence is noticed although the node says ONLINE and OK" || bad "G7 the silence was not noticed"
lab_wait 90 "one fresh start of the daemon" new_log_line "$ln0" 'step: restart ZeroTier (#[0-9]*, controller-silent)' && ok "G7 the daemon gets a fresh start" || bad "G7 no fresh start"
lab_wait 120 "the kept settings are put back" new_log_line "$ln0" 'kept network settings put back' && ok "G7 the kept settings are put back after it" || bad "G7 the kept settings were not put back"
lab_wait 90 "the router has its address" lab_has_ok A
lab_wait 60 "B reaches A (ping)" lab_ping_from_b "$A_IP" && ok "G7 the router stays reachable with the controller still away" || bad "G7 not reachable after the fresh start"
sleep 75
check "G7 one fresh start only, and no reboot for this" test "$(steps 'restart')" = "$((r0 + 1))" -a "$(reboots)" = "$rb0"
A '/usr/libexec/zerotier-support/guard status 3' > "$N/A/status7.txt" 2>&1
check "G7 status names the trouble and shows the root servers" bash -c "grep -q 'перестал обновлять' '$N/A/status7.txt' && grep -q 'Корневые серверы ZeroTier: видно' '$N/A/status7.txt'"
lab_start C 24.10
lab_wait 60 "controller is back" lab_online C
lab_wait 180 "the guard sees fresh settings again" new_log_line "$ln0" 'ZeroTier is back' && ok "G7 the matter closes by itself when the controller answers" || bad "G7 the incident did not close"
lab_wait 30 "the incident reaches the history on flash" grep -q 'reason=controller-silent' "$N/A/flash/incidents" && ok "G7 the incident is in the history kept on flash" || bad "G7 the incident is not in the history kept on flash"

mkdir -p "$L/results"
cp "$N/A/ram/guard.log" "$L/results/e2-$ver-guard.log" 2>/dev/null
cp "$N/A/tmp/procd/log" "$L/results/e2-$ver-procd.log" 2>/dev/null
lab_down
say "E2_DONE passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
