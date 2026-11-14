# Инструкции для агентов

## Открытые замечания ревью

В начале сеанса прочитайте [`docs/review-findings.md`](docs/review-findings.md): там список найденных проблем с приоритетами и предложениями по исправлению.

- Если задача затрагивает код из замечания, учтите его или исправьте заодно, не расширяя изменение без нужды.
- Исправив пункт, удалите его из файла в том же коммите (или отметьте, почему он не актуален).
- Когда список опустеет, удалите файл и этот раздел.

## Проверки перед коммитом

```sh
node --test tests/*.mjs
sh tests/local-conf.sh openwrt/usr/libexec/zerotier-support/helper
shellcheck -s sh openwrt/usr/libexec/zerotier-support/helper router-install.sh router-direct-install.sh
shellcheck install.sh
```

`node --test tests/` (с каталогом) на Node 22 не работает — передавайте файлы.

## Особенности проекта

- Скрипты на роутере выполняются BusyBox `ash`: только POSIX sh, без bash-измов.
- `install.sh` выполняется на Mac/Linux администратора и требует bash.
- Тексты для пользователя и README — на русском.
- Не добавляйте в репозиторий Network ID, ключи, пароли и прочие данные клиентов (см. `SECURITY.md`).
