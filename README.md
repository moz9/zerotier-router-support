# ZeroTier-поддержка для OpenWrt

Небольшой установщик и LuCI-панель для удаленного доступа к OpenWrt-роутерам через приватную ZeroTier-сеть.

Установщик не содержит Network ID, пароли, приватные ключи, маршруты или DNS-настройки. Network ID вводится позже в LuCI.

## Что устанавливается

- Пакет `zerotier` через `apk` или `opkg`.
- Страница LuCI: **Службы -> ZeroTier**.
- Отдельный SSH-ключ поддержки, созданный локально на вашем компьютере.
- Отдельная firewall-зона для ZeroTier:
  - разрешены только TCP-порты `22`, `80`, `443` к самому роутеру;
  - forwarding из ZeroTier в LAN/WAN выключен;
  - SSH в интернет через WAN не открывается.
- Безопасные настройки ZeroTier:
  - managed addresses включены;
  - global routes выключены;
  - default route override выключен;
  - DNS override выключен.

## Команды установки

### Быстрый вариант прямо на OpenWrt

Подключитесь к роутеру по SSH и выполните:

```sh
wget -qO- https://raw.githubusercontent.com/moz9/zerotier-router-support/main/router-direct-install.sh | sh
```

Если на прошивке нет `wget`, но есть `curl`:

```sh
curl -fsSL https://raw.githubusercontent.com/moz9/zerotier-router-support/main/router-direct-install.sh | sh
```

После установки откройте LuCI: **Службы -> ZeroTier**, введите Network ID и авторизуйте роутер в ZeroTier Central.

### С Mac на роутер по SSH

Этот вариант удобнее для первичной поддержки: он сам создает SSH-ключ на Mac и добавляет публичный ключ на роутер.

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/moz9/zerotier-router-support/main/install.sh)
```

Скрипт спросит:

- IP или имя роутера;
- SSH-порт;
- пароль root, либо пустое значение, если ключ поддержки уже установлен.

Network ID на этом шаге не вводится.

## Удаление

Перед удалением убедитесь, что у вас есть другой доступ к роутеру. После остановки ZeroTier удаленный вход через ZeroTier пропадет.

### Удалить панель и настройки поддержки

Выполните на роутере:

```sh
ZT_NET="$(uci -q get zerotier.router_support.id || true)"
[ -n "$ZT_NET" ] && zerotier-cli leave "$ZT_NET" 2>/dev/null || true

/etc/init.d/zerotier stop 2>/dev/null || true
/etc/init.d/zerotier disable 2>/dev/null || true

uci -q delete zerotier.router_support || true
uci -q delete firewall.zt_support || true
uci -q delete firewall.allow_zt_support_router || true
uci commit zerotier 2>/dev/null || true
uci commit firewall 2>/dev/null || true

rm -f \
  /usr/libexec/zerotier-support/helper \
  /usr/share/rpcd/ucode/zerotier.support \
  /usr/share/rpcd/acl.d/zerotier-support.json \
  /usr/share/luci/menu.d/zerotier-support.json \
  /www/luci-static/resources/view/services/zerotier.js \
  /www/luci-static/resources/view/system/zerotier-support.js
rmdir /usr/libexec/zerotier-support 2>/dev/null || true
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache

/etc/init.d/firewall reload 2>/dev/null || /etc/init.d/firewall restart 2>/dev/null || true
/etc/init.d/rpcd restart 2>/dev/null || true
/etc/init.d/uhttpd restart 2>/dev/null || true
```

### Полностью удалить пакет ZeroTier

Если ZeroTier больше не нужен на роутере:

```sh
if command -v apk >/dev/null 2>&1; then
  apk del zerotier
elif command -v opkg >/dev/null 2>&1; then
  opkg remove zerotier
fi
```

## Совместимость OpenWrt

Скрипт не привязан к архитектуре роутера. Архитектуру определяет сам пакетный менеджер OpenWrt, а наши файлы панели являются обычными текстовыми файлами.

Поддержка пакетных менеджеров:

- OpenWrt 24.10.x и старее: используется `opkg`;
- OpenWrt 25.12.x и новее: используется `apk`;
- если `zerotier` уже установлен, пакетный менеджер не вызывается.

Пути LuCI/RPC определяются и создаются на роутере:

- меню LuCI: `/usr/share/luci/menu.d`;
- JS-страница LuCI: `/www/luci-static/resources/view/services`;
- rpcd ucode: `/usr/share/rpcd/ucode`;
- ACL rpcd: `/usr/share/rpcd/acl.d`;
- helper: `/usr/libexec/zerotier-support/helper`.

Если LuCI не установлена, скрипт остановится с понятной ошибкой. CLI-часть ZeroTier можно поставить, но графическая панель требует LuCI.

## Настройка в LuCI

1. Откройте LuCI на роутере.
2. Перейдите в **Службы -> ZeroTier**.
3. Введите Network ID.
4. Нажмите **Подключить / сохранить**.
5. Откройте ZeroTier Central и авторизуйте новый роутер.
6. Вернитесь в LuCI и нажмите **Обновить**.

## Что показывает диагностика

Сначала отображается понятный итог:

- работает ли ZeroTier;
- авторизован ли роутер в сети;
- какой ZeroTier IP выдан;
- как подключиться по SSH и LuCI;
- не перехватывает ли ZeroTier default route, DNS или global routes;
- не попал ли ZeroTier в source-интерфейсы podkop;
- есть ли опасный forwarding из ZeroTier в LAN/WAN.

Технические детали остаются ниже, но секрет ZeroTier скрывается как `<hidden>`.

## Как подключаться

SSH:

```sh
ssh -i ~/.ssh/zerotier-router-support-ed25519 root@<ROUTER_ZEROTIER_IP>
```

LuCI:

```text
http://<ROUTER_ZEROTIER_IP>/cgi-bin/luci/
```

## Отключение входа по паролю

Делайте это только после проверки SSH по ключу через ZeroTier:

```sh
ssh -i ~/.ssh/zerotier-router-support-ed25519 root@<ROUTER_ZEROTIER_IP> \
  "uci set dropbear.main.PasswordAuth=off; \
   uci set dropbear.main.RootPasswordAuth=off; \
   uci commit dropbear; \
   /etc/init.d/dropbear restart"
```

## Совместимость с podkop

Схема не должна мешать podkop:

- ZeroTier-трафик создается самим роутером.
- LAN-клиенты не получают forwarding в ZeroTier по умолчанию.
- Панель показывает source-интерфейсы podkop и output-routing, чтобы быстро заметить опасные изменения.

Если нужно, чтобы клиенты за одним роутером ходили к другому роутеру через ZeroTier, это настраивается отдельно и узко. Установщик специально этого не включает.
