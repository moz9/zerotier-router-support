#!/bin/bash
# PC only (WSL, root). Builds the two throw-away router roots the lab runs the routers' own programs in:
#   root-25.12: OpenWrt 25.12 with ZeroTier 1.16 (apk), unpacked from a sysupgrade image;
#   root-24.10: OpenWrt 24.10 with ZeroTier 1.14 (opkg), an unpacked root plus the ZeroTier package files.
# Where they come from is given from outside, so nothing of a particular setup is written here:
#   ZT_LAB_IMAGE_2512  an OpenWrt 25.12 aarch64 "...squashfs-sysupgrade.bin" (tar) that contains zerotier
#   ZT_LAB_JQ_IMAGE    optional: another such image to take jq from, when the first has none (e4 needs jq)
#   ZT_LAB_ROOT_2410   a directory with an unpacked OpenWrt 24.10 aarch64 root
#   ZT_LAB_ZT_2410     a directory laid out like a router's root with the zerotier 1.14 files in it
#                      (usr/bin/zerotier-one, etc/init.d/zerotier, usr/lib/lib{miniupnpc,natpmp,stdc++,atomic}*,
#                      optionally usr/bin/jq with usr/lib/lib{jq,onig}*), e.g. the unpacked ipk files
# A root that already exists is kept; delete it to build it again. Settings, keys, identities and personal data of
# the sources are removed from the roots (only the programs are needed).
# usage: lab-roots.sh [lab-dir]
set -Eeuo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
L=${1:-${ZT_LAB_DIR:-/var/tmp/zt-guard-lab}}
mkdir -p "$L"; chmod 700 "$L"
need() { [ -n "${!1:-}" ] && [ -e "${!1}" ] || { echo "$1 is not set or does not exist: $2" >&2; exit 2; }; }

clean_root() {  # nothing of the source router stays in a lab root
	local R=$1 f
	rm -rf "$R/etc/dropbear" "$R/etc/shadow" "$R/etc/crontabs" "$R/etc/podkop" "$R/etc/podkop-subs" "$R/etc/sing-box" \
	       "$R/etc/zerotier-support" "$R/etc/zerotier-router-support.conf" "$R/root" "$R/www/luci-static/resources/view/podkop"*
	for f in "$R"/etc/config/*; do
		case "${f##*/}" in system|firewall|luci|ucitrack|rpcd|uhttpd) ;; *) rm -f "$f" ;; esac
	done
	mkdir -p "$R/root"
}
unpack_image() {  # <image> <dir>: the image's root file system
	local T; T=$(mktemp -d)
	tar -xf "$1" -C "$T"
	unsquashfs -q -d "$2" "$(find "$T" -name root -type f | head -1)" >/dev/null
	rm -rf "$T"
}

if [ ! -x "$L/root-25.12/usr/bin/zerotier-one" ]; then
	need ZT_LAB_IMAGE_2512 'an OpenWrt 25.12 sysupgrade image with zerotier'
	rm -rf "$L/root-25.12"
	unpack_image "$ZT_LAB_IMAGE_2512" "$L/root-25.12"
	[ -x "$L/root-25.12/usr/bin/zerotier-one" ] || { echo "the image has no zerotier" >&2; exit 2; }
	clean_root "$L/root-25.12"
fi
if [ ! -x "$L/root-25.12/usr/bin/jq" ] && [ -n "${ZT_LAB_JQ_IMAGE:-}" ]; then
	T=$(mktemp -d); unpack_image "$ZT_LAB_JQ_IMAGE" "$T/r"
	cp -a "$T/r/usr/bin/jq" "$L/root-25.12/usr/bin/" && cp -a "$T"/r/usr/lib/libjq* "$T"/r/usr/lib/libonig* "$L/root-25.12/usr/lib/" 2>/dev/null || true
	rm -rf "$T"
fi

if [ ! -x "$L/root-24.10/usr/bin/zerotier-one" ]; then
	need ZT_LAB_ROOT_2410 'an unpacked OpenWrt 24.10 root'
	need ZT_LAB_ZT_2410 'the zerotier 1.14 files laid out like a root'
	rm -rf "$L/root-24.10"
	cp -a "$ZT_LAB_ROOT_2410" "$L/root-24.10"
	Z=$ZT_LAB_ZT_2410
	cp -a "$Z/usr/bin/zerotier-one" "$L/root-24.10/usr/bin/"
	ln -sf zerotier-one "$L/root-24.10/usr/bin/zerotier-cli"; ln -sf zerotier-one "$L/root-24.10/usr/bin/zerotier-idtool"
	cp -a "$Z/etc/init.d/zerotier" "$L/root-24.10/etc/init.d/zerotier"
	for f in "$Z"/usr/lib/libminiupnpc* "$Z"/usr/lib/libnatpmp* "$Z"/usr/lib/libstdc++* "$Z"/usr/lib/libatomic* \
	         "$Z"/usr/lib/libjq* "$Z"/usr/lib/libonig*; do
		[ -e "$f" ] && cp -a "$f" "$L/root-24.10/usr/lib/" || true
	done
	[ -e "$Z/usr/bin/jq" ] && cp -a "$Z/usr/bin/jq" "$L/root-24.10/usr/bin/" || true
	clean_root "$L/root-24.10"
fi

for r in root-24.10 root-25.12; do
	R=$L/$r
	cp /usr/bin/qemu-aarch64-static "$R/usr/bin/qemu-aarch64-static"
	mkdir -p "$R/dev/net" "$R/proc" "$R/sys" "$R/tmp" "$R/var"
	for d in "null c 1 3" "zero c 1 5" "urandom c 1 9" "random c 1 8" "net/tun c 10 200"; do set -- $d; [ -e "$R/dev/$1" ] || mknod -m 666 "$R/dev/$1" $2 $3 $4; done
	v=$(chroot "$R" /usr/bin/qemu-aarch64-static /usr/bin/zerotier-one -v 2>&1 | head -1)
	bb=$(strings "$R/bin/busybox" | grep -m1 'BusyBox v' | cut -d' ' -f1-2)
	rel=$(. "$R/etc/openwrt_release"; echo "$DISTRIB_RELEASE")
	echo "$r: OpenWrt $rel, ZeroTier $v, $bb, jq: $([ -x "$R/usr/bin/jq" ] && echo yes || echo no), uci: $([ -x "$R/sbin/uci" ] && echo yes || echo no), jsonfilter: $([ -e "$R/usr/bin/jsonfilter" ] && echo yes || echo no)"
done
echo LAB_ROOTS_DONE
