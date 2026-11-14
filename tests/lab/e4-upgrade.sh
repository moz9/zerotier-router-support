#!/bin/bash
# PC only (WSL, root). The upgrade of an EXISTING install to the version with the guard, the way a management tool
# updates the app on a router: router-direct-install.sh of the new revision, run on the router with ZRS_BASE_URL
# pointing at that revision; it downloads the files, then runs router-install.sh. The tool is assumed to tell
# "update available" by comparing the checksums of six files on the router with the published ones.
#
# The "router" is a copy of a router root (OpenWrt 24.10 or 25.12) with the PUBLISHED version of the app in it
# (the files of origin/main), a working ZeroTier in the lab's network, and a member
# of that network pinging it throughout. The new revision is handed to the installer as a file:// address: TCP
# between the lab's namespaces does not work in this WSL, so the download itself goes through curl's file reader
# instead of HTTP. Everything after the download is as on a router.
# Real: the router's shell, curl, uci, jq, the helper, both installers, ZeroTier, the stock init scripts.
# Stand-ins: procd/ubus, nft, fw4, the firewall init script, sysupgrade -b (see stand-ins/).
# usage: e4-upgrade.sh <24.10|25.12>      about 10 minutes
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); repo=$(cd "$here/../.." && pwd)
ver=${1:-25.12}; tag=up${ver//./}
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
zt_pid() { cat "$N/A/tmp/procd/zerotier.pid" 2>/dev/null; }
TRACKED="usr/libexec/zerotier-support/helper usr/libexec/zerotier-support/20-podkop-zerotier-bypass.nft usr/share/rpcd/ucode/zerotier.support usr/share/rpcd/acl.d/zerotier-support.json usr/share/luci/menu.d/zerotier-support.json www/luci-static/resources/view/services/zerotier.js"
tool_says() {  # what a checksum-comparing management tool would conclude: six files, against a revision's files
	local f; for f in $TRACKED; do [ "$(sha "$RU/$f")" = "$(sha "$1/openwrt/$f")" ] || { echo update; return; }; done; echo current
}

say "=== upgrade of an existing install, OpenWrt $ver"
lab_base || { say "LAB BROKEN"; lab_down; exit 1; }

# ---- the router: a private copy of the lab root with the published app in it
rm -rf "$RU"; cp -a "$L/root-$ver" "$RU"
[ -x "$RU/usr/bin/jq" ] || { say "the lab root $ver has no jq (the installer needs it): build it with ZT_LAB_JQ_IMAGE, see lab-roots.sh"; lab_down; exit 1; }
mkdir -p "$N/old" "$RU/usr/libexec/zerotier-support" "$RU/etc/nftables.d" "$RU/etc/rc.d"
for f in $TRACKED usr/libexec/zerotier-support/zerotier-router-support.conf; do
	mkdir -p "$N/old/openwrt/$(dirname "$f")" "$RU/$(dirname "$f")"
	$G show "origin/main:openwrt/$f" > "$N/old/openwrt/$f"
	cp "$N/old/openwrt/$f" "$RU/$f"
done
chmod 755 "$RU/usr/libexec/zerotier-support/helper"
rm -f "$RU/usr/libexec/zerotier-support/guard" "$RU/etc/init.d/zerotier-guard" "$RU/lib/upgrade/keep.d/zerotier-guard" "$RU"/etc/rc.d/*zerotier-guard
cp "$RU/usr/libexec/zerotier-support/20-podkop-zerotier-bypass.nft" "$RU/etc/nftables.d/20-podkop-zerotier-bypass.nft"
printf '{\n  "settings": {\n    "secondaryPort": 25534,\n    "tertiaryPort": 34923,\n    "softwareUpdate": "disable"\n  }\n}\n' > "$RU/etc/zerotier-router-support.conf"
[ -e "$RU/etc/rc.d/S90zerotier" ] || ln -s ../init.d/zerotier "$RU/etc/rc.d/S90zerotier"
cp "$here/stand-ins/initd-firewall" "$RU/etc/init.d/firewall"; chmod 755 "$RU/etc/init.d/firewall"
lab_first_start A "$ver"; lab_stop A
cat > "$RU/etc/config/zerotier" <<EOF
config zerotier 'global'
	option enabled '1'
	option secret '$(cat "$N/A/identity.secret")'
	option port '9993'
	option local_conf_path '/etc/zerotier-router-support.conf'

config network 'router_support'
	option id '$NW'
	option allow_managed '1'
	option allow_global '0'
	option allow_default '0'
	option allow_dns '0'
EOF
mkdir -p "$N/A/flash" "$N/A/ram" "$N/A/tmp/procd" "$N/A/tmp/bin" "$N/A/tmp/moon" "$N/A/tmp/job"
cp "$N/M/home/moons.d/"*.moon "$N/A/tmp/moon/"
for s in ubus reboot nft fw4 sysupgrade mini-procd; do cp "$here/stand-ins/$s" "$N/A/tmp/bin/$s"; done; chmod 755 "$N/A/tmp/bin/"*
echo "$tag" > "$N/A/root"
bg() { ZT_LAB_NAME=$LAB ZT_LAB_DIR=$L setsid bash -c ". '$LAB_SH'; lab_in A $tag 'export PATH=/tmp/lab/bin:/usr/sbin:/usr/bin:/sbin:/bin; $2'" > "$N/A/$1.log" 2>&1 < /dev/null & }
bg mini-procd 'exec /bin/ash /tmp/lab/bin/mini-procd'
A '/etc/init.d/zerotier start' > "$N/A/init-start.log" 2>&1
lab_wait 30 "the stock init script started the daemon" test -s "$N/A/tmp/procd/zerotier.pid"; sleep 6
lab_ctl POST "/controller/network/$NW/member/$(lab_addr A)" '{"authorized":true}' >/dev/null
lab_wait 90 "the router is in its network" lab_has_ok A || { say "LAB BROKEN: no network"; lab_down; exit 1; }
A_IP=$(lab_zt_ip A); lab_wait 60 "the other member reaches the router" lab_ping_from_b "$A_IP"
sleep 20   # let the daemon settle on its fixed ports

# ---- the new revision, served as GitHub serves it (Unix line endings)
serve_new() {
	rm -rf "$N/A/tmp/www"; mkdir -p "$N/A/tmp/www"
	local f
	for f in router-direct-install.sh openwrt/MANIFEST.sha256 $(grep -o '^fetch_file "[^"]*"' "$repo/router-direct-install.sh" | cut -d'"' -f2); do
		mkdir -p "$N/A/tmp/www/$(dirname "$f")"; tr -d '\r' < "$repo/$f" > "$N/A/tmp/www/$f"
	done
}
serve_new
upgrade() {  # as a management tool's job does: the installer of the new revision, pointed at that revision
	cp "$N/A/tmp/www/router-direct-install.sh" "$N/A/tmp/job/install.sh"; rm -f "$N/A/tmp/job/exitcode"
	A 'cd /tmp/lab/job && ZRS_BASE_URL=file:///tmp/lab/www sh ./install.sh > job.log 2>&1; echo $? > exitcode'
	cat "$N/A/tmp/job/exitcode" 2>/dev/null
}
state() { echo "$(sha "$RU/usr/libexec/zerotier-support/helper" | cut -c1-8) guard=$([ -e "$RU/usr/libexec/zerotier-support/guard" ] && echo yes || echo no) init=$([ -e "$RU/etc/init.d/zerotier-guard" ] && echo yes || echo no) on=$(ls "$RU/etc/rc.d" | grep -c zerotier-guard) zt=$(sha "$RU/etc/config/zerotier" | cut -c1-8) pid=$(zt_pid)"; }

OLD_HELPER=$(sha "$N/old/openwrt/usr/libexec/zerotier-support/helper")
PID0=$(zt_pid); UCI0=$(sha "$RU/etc/config/zerotier"); ADDR0=$(lab_cli A info | awk '{print $3}')
S0=$(state)
say "before: published helper ${OLD_HELPER:0:8}…, the tool would say: $(tool_says "$N/old") against the published revision, $(tool_says "$N/A/tmp/www") against the new one"
check "U0 the router runs the published version and no guard" test "$(sha "$RU/usr/libexec/zerotier-support/helper")" = "$OLD_HELPER" -a ! -e "$RU/usr/libexec/zerotier-support/guard"
check "U0 a checksum-comparing tool can tell: the new revision shows as an update" test "$(tool_says "$N/A/tmp/www")" = update

say "--- U1 a damaged download (one file cut short on the way)"
head -c 2000 "$N/A/tmp/www/openwrt/usr/libexec/zerotier-support/guard" > "$N/A/tmp/www/x" && mv "$N/A/tmp/www/x" "$N/A/tmp/www/openwrt/usr/libexec/zerotier-support/guard"
rc=$(upgrade)
check "U1 the installer refuses (exit $rc) and says nothing was changed" bash -c "[ '$rc' != 0 ] && grep -q 'ничего не изменено' '$N/A/tmp/job/job.log'"
check "U1 the router is exactly as before" test "$(state)" = "$S0"
serve_new

say "--- U2 a file that cannot be downloaded at all"
rm -f "$N/A/tmp/www/openwrt/etc/init.d/zerotier-guard"
rc=$(upgrade)
check "U2 the installer stops (exit $rc)" test "$rc" != 0
check "U2 the router is exactly as before" test "$(state)" = "$S0"
serve_new

say "--- U3 the installer is killed in the middle (after the new files are in place, before the service is switched on)"
: > "$N/A/tmp/die-once"
rc=$(upgrade)
say "state after the kill: $(state)"
check "U3 the run ended with an error (exit $rc)" test "$rc" != 0
check "U3 the guard is not switched on by a half-finished install" test "$(ls "$RU/etc/rc.d" | grep -c zerotier-guard)" = 0
check "U3 a checksum-comparing tool still offers the update (the old helper is in place)" test "$(tool_says "$N/A/tmp/www")" = update
check "U3 ZeroTier was not touched: same process, same settings" test "$(zt_pid)" = "$PID0" -a "$(sha "$RU/etc/config/zerotier")" = "$UCI0"
lab_ping_from_b "$A_IP" && ok "U3 the router is still reachable" || bad "U3 the router is not reachable after the kill"

say "--- U4 the upgrade itself, with the other member pinging the router throughout"
ip netns exec "$NS-B" ping -i 1 -c 75 -W 2 -q "$A_IP" > "$N/ping.log" 2>&1 &
pingpid=$!
t0=$(date +%s); rc=$(upgrade); t1=$(date +%s)
wait $pingpid
say "the upgrade took $((t1 - t0)) s; ping during it: $(grep -o '[0-9]* packets transmitted, [0-9]* received' "$N/ping.log")"
check "U4 the installer finished without an error" test "$rc" = 0
check "U4 downloads were checked before the install" grep -q 'Все файлы загружены целиком' "$N/A/tmp/job/job.log"
check "U4 ZeroTier was not restarted (same process)" test "$(zt_pid)" = "$PID0"
check "U4 the node identity, the network and its switches are unchanged" test "$(sha "$RU/etc/config/zerotier")" = "$UCI0" -a "$(lab_cli A info | awk '{print $3}')" = "$ADDR0"
check "U4 the local settings keep their own keys and the fixed ports" bash -c "chroot '$RU' $QEMU /usr/bin/jq -e '.settings.softwareUpdate == \"disable\" and .settings.secondaryPort == 25534 and .settings.tertiaryPort == 34923' /etc/zerotier-router-support.conf"
lost=$(awk '/packets transmitted/{print $1 - $4}' "$N/ping.log")
check "U4 no ping was lost during the upgrade (lost: ${lost:-?})" test "${lost:-9}" -le 1
check "U4 the router is in its network with the same address" test "$(lab_zt_ip A)" = "$A_IP"
check "U4 the tool would now say: current" test "$(tool_says "$N/A/tmp/www")" = current
check "U4 the helper and the guard report the new version" bash -c "v=\$(sed -n 's/^ZRS_VERSION=\"\\(.*\\)\"/\\1/p' '$repo/openwrt/usr/libexec/zerotier-support/helper'); [ \"\$(chroot '$RU' $QEMU /bin/ash /usr/libexec/zerotier-support/helper version)\" = \"\$v\" ] && [ \"\$(chroot '$RU' $QEMU /bin/ash /usr/libexec/zerotier-support/guard version)\" = \"\$v\" ]"
check "U4 the guard's files are in place with their modes" bash -c "[ \"\$(stat -c %a '$RU/usr/libexec/zerotier-support/guard')\" = 755 ] && [ \"\$(stat -c %a '$RU/etc/init.d/zerotier-guard')\" = 755 ] && [ \"\$(stat -c %a '$RU/lib/upgrade/keep.d/zerotier-guard')\" = 644 ] && cmp -s '$RU/usr/libexec/zerotier-support/guard' '$N/A/tmp/www/openwrt/usr/libexec/zerotier-support/guard'"
check "U4 the guard service is switched on: starts after ZeroTier, has a stop link" bash -c "[ -L '$RU/etc/rc.d/S91zerotier-guard' ] && [ -L '$RU/etc/rc.d/K05zerotier-guard' ]"
check "U4 procd was asked to run the guard with unlimited respawn" bash -c "grep 'zerotier-guard' '$N/A/tmp/ubus-calls' | grep -q 'guard.*daemon' && grep 'zerotier-guard' '$N/A/tmp/ubus-calls' | tr -d ' \"' | grep -q 'respawn:\\[3600,5,0\\]'"
check "U4 no half-written files are left behind" bash -c "! ls '$RU/usr/libexec/zerotier-support/'*.new '$RU/etc/init.d/'*.new '$RU/lib/upgrade/keep.d/'*.new 2>/dev/null | grep -q ."

say "--- U5 the same upgrade once more (the tool repeats it, or the user does)"
rc=$(upgrade)
check "U5 a second run succeeds and changes nothing in ZeroTier" test "$rc" = 0 -a "$(zt_pid)" = "$PID0" -a "$(sha "$RU/etc/config/zerotier")" = "$UCI0"
lab_ping_from_b "$A_IP" && ok "U5 the router is reachable" || bad "U5 the router is not reachable"

say "--- U6 the connection to the router is lost while the installer runs"
( sleep 6; lab_isolate A ) &
iso=$!
rc=$(upgrade); wait $iso
check "U6 the installer still finishes by itself (exit $rc)" test "$rc" = 0
check "U6 ZeroTier was not restarted" test "$(zt_pid)" = "$PID0"
lab_connect A
lab_wait 120 "the router is reachable again after the line is back" lab_ping_from_b "$A_IP" && ok "U6 access returns without anyone touching the router" || bad "U6 no access after the line came back"

say "--- U7 the installed guard at work"
bg guard 'exec /usr/libexec/zerotier-support/guard daemon'
lab_wait 60 "the guard started" bash -c "grep -q 'guard started' '$N/A/ram/guard.log'"
sleep 75
check "U7 the guard finds a healthy router and takes no step" bash -c "! grep -q 'step:' '$N/A/ram/guard.log'"
check "U7 the network settings are kept on flash" test -s "$N/A/flash/network-$NW.cache"
A '/usr/libexec/zerotier-support/helper status' > "$N/A/helper-status.txt" 2>&1
check "U7 the helper's status page shows the guard and the version" bash -c "grep -q 'Сторож доступа ZeroTier' '$N/A/helper-status.txt' && grep -q 'всё в порядке' '$N/A/helper-status.txt' && grep -q 'Пакет поддержки ZeroTier: версия' '$N/A/helper-status.txt'"

mkdir -p "$L/results"; cp "$N/A/tmp/job/job.log" "$L/results/e4-$ver-job.log" 2>/dev/null
lab_down; rm -rf "$RU"
say "E4_DONE passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
