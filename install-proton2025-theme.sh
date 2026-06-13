#!/bin/sh
set -eu

REPO="${PROTON2025_REPO:-ChesterGoodiny/luci-theme-proton2025}"
API_URL="https://api.github.com/repos/${REPO}/releases/latest"
TMP_DIR="$(mktemp -d /tmp/proton2025.XXXXXX)"

cleanup() {
	rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

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

download() {
	url="$1"
	dest="$2"

	if command -v curl >/dev/null 2>&1; then
		curl -fsSL -H 'User-Agent: openwrt-proton2025-installer' "$url" -o "$dest"
	elif command -v wget >/dev/null 2>&1; then
		wget -q -O "$dest" "$url"
	elif command -v uclient-fetch >/dev/null 2>&1; then
		uclient-fetch -q -O "$dest" "$url"
	else
		echo "Не найдена команда для скачивания: нужен wget, curl или uclient-fetch." >&2
		exit 1
	fi
}

json_value() {
	key="$1"
	tr ',' '\n' < "$TMP_DIR/release.json" | sed -n 's/^[[:space:]]*"'$key'":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
}

asset_url() {
	pattern="$1"
	tr ',' '\n' < "$TMP_DIR/release.json" | sed -n 's/.*"browser_download_url":[[:space:]]*"\([^"]*\)".*/\1/p' | grep "$pattern" | head -n 1
}

install_package() {
	package_file="$1"

	if command -v apk >/dev/null 2>&1; then
		apk add --allow-untrusted "$package_file"
	elif command -v opkg >/dev/null 2>&1; then
		opkg install "$package_file"
	else
		echo "Не найден пакетный менеджер: нужен apk или opkg." >&2
		exit 1
	fi
}

enable_theme() {
	if command -v uci >/dev/null 2>&1; then
		uci set luci.main.mediaurlbase='/luci-static/proton2025'
		uci commit luci
	fi

	/etc/init.d/uhttpd restart 2>/dev/null || true
	rm -rf /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null || true
}

need_root
need_openwrt

echo "== Proton2025: поиск последнего релиза =="
download "$API_URL" "$TMP_DIR/release.json"

tag="$(json_value tag_name)"
if [ -z "$tag" ]; then
	echo "Не удалось определить последнюю версию Proton2025." >&2
	exit 1
fi

if command -v apk >/dev/null 2>&1; then
	url="$(asset_url '\.apk$')"
elif command -v opkg >/dev/null 2>&1; then
	url="$(asset_url '_all\.ipk$')"
else
	echo "Не найден пакетный менеджер: нужен apk или opkg." >&2
	exit 1
fi

if [ -z "$url" ]; then
	echo "В релизе ${tag} не найден подходящий пакет для этого роутера." >&2
	exit 1
fi

package_file="${TMP_DIR}/$(basename "$url")"

echo "Версия: ${tag}"
echo "Пакет: $(basename "$package_file")"
download "$url" "$package_file"

echo "== Установка пакета =="
install_package "$package_file"

echo "== Включение темы =="
enable_theme

echo
echo "Готово. Тема Proton2025 установлена и включена."
echo "Если браузер показывает старую тему, сделайте жесткое обновление страницы."
