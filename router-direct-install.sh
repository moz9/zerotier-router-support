#!/bin/sh
set -eu

BASE_URL="${ZRS_BASE_URL:-https://raw.githubusercontent.com/moz9/zerotier-router-support/main}"
TMP_DIR="$(mktemp -d /tmp/zrs-direct.XXXXXX)"

cleanup() {
	rm -rf "$TMP_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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
fetch_file "openwrt/usr/libexec/zerotier-support/20-podkop-zerotier-bypass.nft"
fetch_file "openwrt/usr/libexec/zerotier-support/zerotier-router-support.conf"
fetch_file "openwrt/usr/share/rpcd/ucode/zerotier.support"
fetch_file "openwrt/usr/share/rpcd/acl.d/zerotier-support.json"
fetch_file "openwrt/usr/share/luci/menu.d/zerotier-support.json"
fetch_file "openwrt/www/luci-static/resources/view/services/zerotier.js"
fetch_file "openwrt/lib/upgrade/keep.d/zerotier-router-support"
fetch_file "openwrt/usr/libexec/zerotier-support/guard"
fetch_file "openwrt/etc/init.d/zerotier-guard"
fetch_file "openwrt/lib/upgrade/keep.d/zerotier-guard"

# Nothing is installed from an incomplete or damaged download: every file is compared with the list of
# checksums published in the same revision (the upgrade usually runs over ZeroTier itself, on any kind of line).
fetch_file "openwrt/MANIFEST.sha256"
echo "== Проверка загруженных файлов =="
verify_download() {
	vd_bad=0; vd_n=0
	while read -r vd_want vd_path; do
		case "$vd_want" in ''|'#'*) continue ;; esac
		vd_n=$((vd_n + 1))
		if [ ! -f "${TMP_DIR}/${vd_path}" ]; then echo "Не загружен: ${vd_path}" >&2; vd_bad=1; continue; fi
		vd_have="$(sha256sum "${TMP_DIR}/${vd_path}" | cut -d' ' -f1)"
		[ "$vd_have" = "$vd_want" ] || { echo "Повреждён при загрузке: ${vd_path}" >&2; vd_bad=1; }
	done < "${TMP_DIR}/openwrt/MANIFEST.sha256"
	[ "$vd_n" -ge 8 ] || { echo "Список контрольных сумм неполон." >&2; vd_bad=1; }
	return "$vd_bad"
}
if ! verify_download; then
	echo "Установка не начиналась: загрузка неполная или повреждена. На роутере ничего не изменено. Повторите позже." >&2
	exit 1
fi
echo "Все файлы загружены целиком: $(sed -n '1s/^# *//p' "${TMP_DIR}/openwrt/MANIFEST.sha256")"

if [ -n "${ZRS_PUBKEY:-}" ]; then
	printf '%s\n' "$ZRS_PUBKEY" > "${TMP_DIR}/router-support-ed25519.pub"
fi

chmod 0755 "${TMP_DIR}/router-install.sh"
chmod 0755 "${TMP_DIR}/openwrt/usr/libexec/zerotier-support/helper"

sh "${TMP_DIR}/router-install.sh" "$TMP_DIR"
