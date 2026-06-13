#!/usr/bin/env bash
set -euo pipefail

REPO_RAW_URL="${ZRS_BASE_URL:-https://raw.githubusercontent.com/moz9/zerotier-router-support/main}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
KEY_PATH="${ZRS_KEY_PATH:-${HOME}/.ssh/zerotier-router-support-ed25519}"
KNOWN_HOSTS="${ZRS_KNOWN_HOSTS:-${HOME}/.ssh/known_hosts}"

FILES=(
  "router-install.sh"
  "openwrt/usr/libexec/zerotier-support/helper"
  "openwrt/usr/share/rpcd/ucode/zerotier.support"
  "openwrt/usr/share/rpcd/acl.d/zerotier-support.json"
  "openwrt/usr/share/luci/menu.d/zerotier-support.json"
  "openwrt/www/luci-static/resources/view/services/zerotier.js"
)

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Не найдена нужная команда: $1" >&2
    exit 1
  fi
}

need_cmd ssh
need_cmd scp
need_cmd ssh-keygen
need_cmd expect

if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
  echo "Не найдена нужная команда: curl или wget" >&2
  exit 1
fi

download_file() {
  url="$1"
  dest="$2"
  mkdir -p "$(dirname "$dest")"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$dest"
  else
    wget -qO "$dest" "$url"
  fi
}

copy_or_download_tree() {
  dest="$1"

  for file in "${FILES[@]}"; do
    if [ -f "${SCRIPT_DIR}/${file}" ]; then
      mkdir -p "${dest}/$(dirname "$file")"
      cp "${SCRIPT_DIR}/${file}" "${dest}/${file}"
    else
      download_file "${REPO_RAW_URL}/${file}" "${dest}/${file}"
    fi
  done

  chmod 0755 "${dest}/router-install.sh"
  chmod 0755 "${dest}/openwrt/usr/libexec/zerotier-support/helper"
}

mkdir -p "$(dirname "$KEY_PATH")" "$(dirname "$KNOWN_HOSTS")"

if [ ! -f "$KEY_PATH" ]; then
  echo "Создаю SSH-ключ поддержки: $KEY_PATH"
  ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -C "codex-router-support-$(date +%Y-%m-%d)" >/dev/null
fi

chmod 600 "$KEY_PATH"
chmod 644 "${KEY_PATH}.pub"

read -r -p "IP или имя роутера: " ROUTER_HOST
if [ -z "$ROUTER_HOST" ]; then
  echo "Нужно указать IP или имя роутера." >&2
  exit 1
fi

read -r -p "SSH-порт [22]: " ROUTER_PORT
ROUTER_PORT="${ROUTER_PORT:-22}"

printf "Пароль root для %s (оставьте пустым, если ключ уже установлен): " "$ROUTER_HOST"
if [ -t 0 ]; then
  stty -echo
  IFS= read -r ROUTER_PASS || true
  stty echo
else
  IFS= read -r ROUTER_PASS || true
fi
printf "\n"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PAYLOAD_DIR="${TMP_DIR}/zrs-files"
copy_or_download_tree "$PAYLOAD_DIR"
cp "${KEY_PATH}.pub" "${PAYLOAD_DIR}/router-support-ed25519.pub"

run_expect_scp_password() {
  export ROUTER_HOST ROUTER_PORT ROUTER_PASS KNOWN_HOSTS PAYLOAD_DIR
  expect <<'EXPECT'
set timeout 180
set password $env(ROUTER_PASS)
spawn ssh -p $env(ROUTER_PORT) -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$env(KNOWN_HOSTS) root@$env(ROUTER_HOST) "rm -rf /tmp/zrs-files && mkdir -p /tmp/zrs-files"
expect {
  -re "(?i)password:" { send -- "$password\r"; exp_continue }
  eof {}
  timeout { exit 2 }
}
spawn scp -O -P $env(ROUTER_PORT) -r -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$env(KNOWN_HOSTS) $env(PAYLOAD_DIR)/* root@$env(ROUTER_HOST):/tmp/zrs-files/
expect {
  -re "(?i)password:" { send -- "$password\r"; exp_continue }
  eof {}
  timeout { exit 2 }
}
EXPECT
}

run_expect_ssh_password() {
  export ROUTER_HOST ROUTER_PORT ROUTER_PASS KNOWN_HOSTS
  expect <<'EXPECT'
set timeout 420
set password $env(ROUTER_PASS)
spawn ssh -p $env(ROUTER_PORT) -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$env(KNOWN_HOSTS) root@$env(ROUTER_HOST) "sh /tmp/zrs-files/router-install.sh /tmp/zrs-files; echo __ZRS_DONE__"
expect {
  -re "(?i)password:" { send -- "$password\r" }
  eof { exit 1 }
  timeout { exit 2 }
}
expect "__ZRS_DONE__"
expect eof
EXPECT
}

run_scp_key() {
  ssh -p "$ROUTER_PORT" \
    -i "$KEY_PATH" \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$KNOWN_HOSTS" \
    "root@${ROUTER_HOST}" "rm -rf /tmp/zrs-files && mkdir -p /tmp/zrs-files"

  scp -O -P "$ROUTER_PORT" -r \
    -i "$KEY_PATH" \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$KNOWN_HOSTS" \
    "${PAYLOAD_DIR}/"* "root@${ROUTER_HOST}:/tmp/zrs-files/"
}

run_ssh_key() {
  ssh -p "$ROUTER_PORT" \
    -i "$KEY_PATH" \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$KNOWN_HOSTS" \
    "root@${ROUTER_HOST}" "sh /tmp/zrs-files/router-install.sh /tmp/zrs-files; echo __ZRS_DONE__"
}

echo
echo "Устанавливаю панель ZeroTier-поддержки на ${ROUTER_HOST}:${ROUTER_PORT}"
echo "Network ID здесь специально не запрашивается."
echo

if [ -n "$ROUTER_PASS" ]; then
  run_expect_scp_password
  run_expect_ssh_password
else
  run_scp_key
  run_ssh_key
fi

echo
echo "Готово."
echo "Откройте LuCI на роутере: Службы -> ZeroTier"
echo "Введите Network ID в панели и нажмите Подключить / сохранить."
echo
echo "После авторизации роутера в ZeroTier Central подключайтесь так:"
echo "  ssh -i '${KEY_PATH}' root@<ROUTER_ZEROTIER_IP>"
echo
echo "LuCI через ZeroTier:"
echo "  http://<ROUTER_ZEROTIER_IP>/cgi-bin/luci/"
