#!/bin/sh
set -eu

SOURCE_DIR="${1:-/tmp/zrs-files}"
OVERLAY_DIR="${SOURCE_DIR}/openwrt"
PUBKEY_FILE="${SOURCE_DIR}/router-support-ed25519.pub"
HELPER_DIR="${ZRS_HELPER_DIR:-/usr/libexec/zerotier-support}"
RPC_UCODE_DIR="${ZRS_RPC_UCODE_DIR:-/usr/share/rpcd/ucode}"
RPC_ACL_DIR="${ZRS_RPC_ACL_DIR:-/usr/share/rpcd/acl.d}"
LUCI_MENU_DIR="${ZRS_LUCI_MENU_DIR:-/usr/share/luci/menu.d}"
LUCI_VIEW_BASE="${ZRS_LUCI_VIEW_BASE:-/www/luci-static/resources/view}"
LUCI_VIEW_DIR="${LUCI_VIEW_BASE}/services"
KEEP_DIR="${ZRS_KEEP_DIR:-/lib/upgrade/keep.d}"

if [ ! -d "$OVERLAY_DIR" ]; then
	echo "Missing OpenWrt overlay directory: $OVERLAY_DIR" >&2
	exit 1
fi

if [ "$(id -u)" != 0 ]; then
	echo "Запустите установку от root на OpenWrt." >&2
	exit 1
fi

if [ ! -f /etc/openwrt_release ]; then
	echo "Это не похоже на OpenWrt: нет /etc/openwrt_release." >&2
	exit 1
fi

echo "== System =="
cat /etc/openwrt_release 2>/dev/null || true
ubus call system board 2>/dev/null || true

echo "== Backup =="
umask 077
ts="$(date +%Y%m%d-%H%M%S)"
backup_dir="$(mktemp -d /tmp/zt-support-backup.XXXXXX)" || exit 1
case "$backup_dir" in /tmp/zt-support-backup.??????) ;; *) echo "Небезопасный путь резервной копии" >&2; exit 1 ;; esac
mkdir -p "${backup_dir}/config" "${backup_dir}/transport"
sysupgrade -b "${backup_dir}/openwrt-config-before-zerotier-support-${ts}.tar.gz" >/dev/null
for f in network firewall dropbear zerotier; do
	if [ -e "/etc/config/${f}" ]; then
		cp "/etc/config/${f}" "${backup_dir}/config/${f}"
	fi
done
for f in /etc/zerotier-router-support.conf /etc/nftables.d/20-podkop-zerotier-bypass.nft; do
	if [ -e "$f" ]; then
		cp -p "$f" "${backup_dir}/transport/$(basename "$f")"
	fi
done
existing_local_conf="$(uci -q get zerotier.global.local_conf_path 2>/dev/null || true)"
if [ -n "$existing_local_conf" ] && [ -f "$existing_local_conf" ]; then
	cp -p "$existing_local_conf" "${backup_dir}/transport/existing-local.conf"
	printf '%s\n' "$existing_local_conf" > "${backup_dir}/transport/existing-local-conf-path"
fi
backup_archive="/tmp/zt-support-backup-${ts}-$$.zrs.tar.gz"
tar -czf "$backup_archive" -C "$backup_dir" .
rm -rf "$backup_dir"
printf '%s\n' "$backup_archive" > /tmp/zt-support-last-backup-path
echo "BACKUP_FILE=$backup_archive"
# Keep three recent archives created by this installer. Older formats are untouched.
ls -1t /tmp/zt-support-backup-*.zrs.tar.gz 2>/dev/null | sed -n '4,$p' | while IFS= read -r old_archive; do
	case "$old_archive" in /tmp/zt-support-backup-*.zrs.tar.gz) rm -f "$old_archive" ;; esac
done

echo "== Install ZeroTier package =="
install_packages=""
command -v zerotier-cli >/dev/null 2>&1 || install_packages=zerotier
command -v jq >/dev/null 2>&1 || install_packages="${install_packages:+$install_packages }jq"
if [ -n "$install_packages" ]; then
	if command -v apk >/dev/null 2>&1; then
		apk update || true
		apk add $install_packages
	elif command -v opkg >/dev/null 2>&1; then
		opkg update
		opkg install $install_packages
	else
		echo "No supported package manager found: expected apk or opkg." >&2
		exit 1
	fi
fi

echo "== Detect LuCI and rpcd paths =="
if [ ! -d "$LUCI_MENU_DIR" ] || [ ! -d "$LUCI_VIEW_BASE" ]; then
	echo "LuCI не найдена. Нужна прошивка OpenWrt с LuCI или установленный luci-base." >&2
	echo "Ожидались пути: $LUCI_MENU_DIR и $LUCI_VIEW_BASE" >&2
	exit 1
fi

mkdir -p "$HELPER_DIR" "$RPC_UCODE_DIR" "$RPC_ACL_DIR" "$LUCI_MENU_DIR" "$LUCI_VIEW_DIR" "$KEEP_DIR"
echo "HELPER_DIR=$HELPER_DIR"
echo "RPC_UCODE_DIR=$RPC_UCODE_DIR"
echo "RPC_ACL_DIR=$RPC_ACL_DIR"
echo "LUCI_MENU_DIR=$LUCI_MENU_DIR"
echo "LUCI_VIEW_DIR=$LUCI_VIEW_DIR"

echo "== Install LuCI panel files =="
cp "${OVERLAY_DIR}/usr/libexec/zerotier-support/helper" "${HELPER_DIR}/helper"
cp "${OVERLAY_DIR}/usr/libexec/zerotier-support/20-podkop-zerotier-bypass.nft" "${HELPER_DIR}/20-podkop-zerotier-bypass.nft"
cp "${OVERLAY_DIR}/usr/libexec/zerotier-support/zerotier-router-support.conf" "${HELPER_DIR}/zerotier-router-support.conf"
cp "${OVERLAY_DIR}/usr/share/rpcd/ucode/zerotier.support" "${RPC_UCODE_DIR}/zerotier.support"
cp "${OVERLAY_DIR}/usr/share/rpcd/acl.d/zerotier-support.json" "${RPC_ACL_DIR}/zerotier-support.json"
cp "${OVERLAY_DIR}/usr/share/luci/menu.d/zerotier-support.json" "${LUCI_MENU_DIR}/zerotier-support.json"
cp "${OVERLAY_DIR}/www/luci-static/resources/view/services/zerotier.js" "${LUCI_VIEW_DIR}/zerotier.js"
cp "${OVERLAY_DIR}/lib/upgrade/keep.d/zerotier-router-support" "${KEEP_DIR}/zerotier-router-support"

chmod 0755 "${HELPER_DIR}/helper"
chmod 0644 "${HELPER_DIR}/20-podkop-zerotier-bypass.nft"
chmod 0600 "${HELPER_DIR}/zerotier-router-support.conf"
chmod 0644 "${RPC_UCODE_DIR}/zerotier.support"
chmod 0644 "${RPC_ACL_DIR}/zerotier-support.json"
chmod 0644 "${LUCI_MENU_DIR}/zerotier-support.json"
chmod 0644 "${LUCI_VIEW_DIR}/zerotier.js"
chmod 0644 "${KEEP_DIR}/zerotier-router-support"
rm -f "${LUCI_VIEW_BASE}/system/zerotier-support.js" 2>/dev/null || true

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
"${HELPER_DIR}/helper" install

rm -rf /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null || true
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart 2>/dev/null || true

echo
echo "Панель ZeroTier-поддержки установлена."
echo "Откройте LuCI: Службы -> ZeroTier"
echo "Введите там Network ID, затем авторизуйте роутер в ZeroTier Central."
