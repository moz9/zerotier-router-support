#!/bin/sh
set -eu

BASE_URL="${ZRS_BASE_URL:-https://raw.githubusercontent.com/moz9/zerotier-router-support/main}"
TMP_DIR="$(mktemp -d /tmp/zrs-direct.XXXXXX)"

cleanup() {
	rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

need_root() {
	if [ "$(id -u)" != 0 ]; then
		echo "Запустите установку от root на OpenWrt." >&2
		exit 1
	fi
}

need_openwrt() {
	if [ ! -f /etc/openwrt_release ]; then
		echo "Это не похоже на OpenWrt: нет /etc/openwrt_release." >&2
		exit 1
	fi
}

download() {
	url="$1"
	dest="$2"
	mkdir -p "$(dirname "$dest")"

	if command -v curl >/dev/null 2>&1; then
		curl -fsSL "$url" -o "$dest"
	elif command -v wget >/dev/null 2>&1; then
		wget -qO "$dest" "$url"
	elif command -v uclient-fetch >/dev/null 2>&1; then
		uclient-fetch -q -O "$dest" "$url"
	else
		echo "Не найдена команда для скачивания: нужен wget, curl или uclient-fetch." >&2
		exit 1
	fi
}

fetch_file() {
	path="$1"
	download "${BASE_URL}/${path}" "${TMP_DIR}/${path}"
}

need_root
need_openwrt

echo "== Загрузка установщика ZeroTier =="
fetch_file "router-install.sh"
fetch_file "openwrt/usr/libexec/zerotier-support/helper"
fetch_file "openwrt/usr/share/rpcd/ucode/zerotier.support"
fetch_file "openwrt/usr/share/rpcd/acl.d/zerotier-support.json"
fetch_file "openwrt/usr/share/luci/menu.d/zerotier-support.json"
fetch_file "openwrt/www/luci-static/resources/view/services/zerotier.js"

if [ -n "${ZRS_PUBKEY:-}" ]; then
	printf '%s\n' "$ZRS_PUBKEY" > "${TMP_DIR}/router-support-ed25519.pub"
fi

chmod 0755 "${TMP_DIR}/router-install.sh"
chmod 0755 "${TMP_DIR}/openwrt/usr/libexec/zerotier-support/helper"

sh "${TMP_DIR}/router-install.sh" "$TMP_DIR"
