#!/bin/sh
set -eu

need_root() {
	if [ "$(id -u)" != 0 ]; then
		echo "Запустите скрипт от root на OpenWrt." >&2
		exit 1
	fi
}

need_openwrt() {
	if [ ! -f /etc/openwrt_release ]; then
		echo "Это не похоже на OpenWrt: нет /etc/openwrt_release." >&2
		exit 1
	fi
}

remove_package() {
	if command -v apk >/dev/null 2>&1; then
		apk del luci-theme-proton2025 || true
	elif command -v opkg >/dev/null 2>&1; then
		opkg remove luci-theme-proton2025 || true
	else
		echo "Не найден пакетный менеджер: нужен apk или opkg." >&2
		exit 1
	fi
}

need_root
need_openwrt

echo "== Откат на стандартную тему LuCI =="
uci set luci.main.mediaurlbase='/luci-static/bootstrap' 2>/dev/null || true
uci commit luci 2>/dev/null || true

echo "== Удаление Proton2025 =="
remove_package

rm -rf /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null || true
/etc/init.d/uhttpd restart 2>/dev/null || true

echo
echo "Готово. Proton2025 удалена, LuCI переключена на стандартную тему."
