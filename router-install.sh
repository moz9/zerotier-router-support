#!/bin/sh
set -eu

SOURCE_DIR="${1:-/tmp/zrs-files}"
OVERLAY_DIR="${SOURCE_DIR}/openwrt"
PUBKEY_FILE="${SOURCE_DIR}/router-support-ed25519.pub"

if [ ! -d "$OVERLAY_DIR" ]; then
	echo "Missing OpenWrt overlay directory: $OVERLAY_DIR" >&2
	exit 1
fi

echo "== System =="
cat /etc/openwrt_release 2>/dev/null || true
ubus call system board 2>/dev/null || true

echo "== Backup =="
ts="$(date +%Y%m%d-%H%M%S)"
backup_dir="/tmp/zt-support-backup-${ts}"
mkdir -p "${backup_dir}/config"
sysupgrade -b "${backup_dir}/openwrt-config-before-zerotier-support-${ts}.tar.gz" >/dev/null
for f in network firewall dropbear zerotier; do
	[ -e "/etc/config/${f}" ] && cp "/etc/config/${f}" "${backup_dir}/config/${f}" || true
done
tar -czf "/tmp/zt-support-backup-${ts}.tar.gz" -C "${backup_dir}" .
printf '%s\n' "/tmp/zt-support-backup-${ts}.tar.gz" > /tmp/zt-support-last-backup-path
echo "BACKUP_FILE=/tmp/zt-support-backup-${ts}.tar.gz"

echo "== Install ZeroTier package =="
if command -v zerotier-cli >/dev/null 2>&1; then
	echo "ZeroTier already installed."
elif command -v apk >/dev/null 2>&1; then
	apk add zerotier
elif command -v opkg >/dev/null 2>&1; then
	opkg update
	opkg install zerotier
else
	echo "No supported package manager found: expected apk or opkg." >&2
	exit 1
fi

echo "== Install LuCI panel files =="
cp -R "${OVERLAY_DIR}/"* /
chmod 0755 /usr/libexec/zerotier-support/helper
chmod 0644 /usr/share/rpcd/ucode/zerotier.support
chmod 0644 /usr/share/rpcd/acl.d/zerotier-support.json
chmod 0644 /usr/share/luci/menu.d/zerotier-support.json
chmod 0644 /www/luci-static/resources/view/services/zerotier.js

echo "== SSH support key =="
if [ -s "$PUBKEY_FILE" ]; then
	mkdir -p /etc/dropbear
	touch /etc/dropbear/authorized_keys
	chmod 700 /etc/dropbear
	chmod 600 /etc/dropbear/authorized_keys
	pubkey="$(cat "$PUBKEY_FILE")"
	if ! grep -qxF "$pubkey" /etc/dropbear/authorized_keys; then
		printf '%s\n' "$pubkey" >> /etc/dropbear/authorized_keys
	fi
	grep -F 'codex-router-support' /etc/dropbear/authorized_keys || true
else
	echo "No support public key supplied; skipping authorized_keys update."
fi

echo "== Prepare firewall =="
/usr/libexec/zerotier-support/helper install

rm -rf /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null || true
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart 2>/dev/null || true
/etc/init.d/dropbear restart 2>/dev/null || true

echo
echo "Панель ZeroTier-поддержки установлена."
echo "Откройте LuCI: Службы -> ZeroTier"
echo "Введите там Network ID, затем авторизуйте роутер в ZeroTier Central."
