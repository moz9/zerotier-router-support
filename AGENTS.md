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

Поведение сторожа доступа проверяет `tests/guard-scenarios.sh` (модель роутера вокруг настоящего сценария). На Windows `node --test` запускает из него только три коротких сценария: запуск процесса там медленный. Полный набор — на Linux/CI, либо в WSL вместе с оболочками самих роутеров и shellcheck:

```sh
wsl -d Ubuntu-24.04 -u root -- bash tests/lab/guard-ash.sh      # из корня репозитория
```

Опыты с настоящими программами ZeroTier — `tests/lab/` (см. `tests/lab/README.md`). Сценарий, который уже запущен в WSL, править нельзя: bash читает файл по ходу выполнения.

## Особенности проекта

- Скрипты на роутере выполняются BusyBox `ash`: только POSIX sh, без bash-измов.
- `install.sh` выполняется на Mac/Linux администратора и требует bash.
- Тексты для пользователя и README — на русском.
- Не добавляйте в репозиторий Network ID, ключи, пароли и прочие данные клиентов (см. `SECURITY.md`).
- Сторож (`openwrt/usr/libexec/zerotier-support/guard`) не меняет настройки: никаких `uci set/commit`, пакетов, чужих файлов. На роутерах нет `timeout`, `stat`, дробного `sleep`. Любое изменение сторожа — с проверкой в `tests/guard-scenarios.sh`.
