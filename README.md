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

## Установка с GitHub

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/moz9/zerotier-router-support/main/install.sh)
```

Скрипт спросит:

- IP или имя роутера;
- SSH-порт;
- пароль root, либо пустое значение, если ключ поддержки уже установлен.

Network ID на этом шаге не вводится.

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
