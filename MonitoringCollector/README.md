# Серверный мониторинг SSH Hub

Коллектор работает на постоянно включённом сервере независимо от Mac. Он проверяет явно заданные TCP-порты и HTTP-ответы, сохраняет историю в SQLite и предоставляет приложению read-only API. Python 3.9+; внешних Python-пакетов, root-прав для работы и доступа к SSH-паролям не требуется.

## Первый запуск

1. Скопируй эту папку на сервер и `config.example.json` в `config.json`.
2. Замени демонстрационные адреса в `targets` на свои. `192.0.2.x` — адреса для примеров. Сохраняй стабильный `id` цели: он связывает историю после перезапуска.
3. Создай случайный токен в приватном файле. Значение не передаётся в аргументах процесса и не выводится в терминал:

   ```sh
   umask 077
   python3 - <<'PY'
   import os, secrets
   fd = os.open('token', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
   with os.fdopen(fd, 'w') as output:
       output.write(secrets.token_urlsafe(48) + '\n')
   PY
   ```

4. Запусти коллектор:

   ```sh
   SSH_HUB_MONITOR_TOKEN_FILE="$PWD/token" python3 collector.py --config config.json --database data/history.sqlite
   ```

5. Для подключения с другого компьютера поставь перед ним TLS reverse proxy с доверенным сертификатом. Пример Caddy — в `Caddyfile.example`: замени домен и настрой его DNS. HTTP listener коллектора намеренно доступен только на `127.0.0.1`/`::1`. Не публикуй порт 8787 напрямую.
6. В SSH Hub открой «Мониторинг» → настройки, укажи конечный HTTPS-адрес и вставь токен из защищённого файла. Сохрани и нажми «Подключиться». Для теста на этом же Mac разрешён `http://127.0.0.1:8787`.

Токен приложения хранится в Связке ключей с отдельной привязкой к профилю, SSH-конфигу и endpoint. Он не входит в JSON-настройки и архивы приложения. Коллектор не пишет токен, заголовки запросов, URL целей или тела HTTP-ответов в логи. Для ротации замени файл токена, перезапусти сервис и обнови значение в приложении.

## Постоянный сервис Linux/systemd

В `ssh-hub-monitor.service` используется отдельный системный пользователь `ssh-hub-monitor` без входа в систему. Пример установки для Debian/Ubuntu, после настройки и проверки `config.json`:

```sh
sudo useradd --system --home /var/lib/ssh-hub-monitor --shell /usr/sbin/nologin ssh-hub-monitor
sudo install -d -m 0755 /opt/ssh-hub-monitor
sudo install -m 0644 collector.py /opt/ssh-hub-monitor/collector.py
sudo install -d -o ssh-hub-monitor -g ssh-hub-monitor -m 0700 /etc/ssh-hub-monitor
sudo install -o ssh-hub-monitor -g ssh-hub-monitor -m 0600 config.json /etc/ssh-hub-monitor/config.json
sudo install -o ssh-hub-monitor -g ssh-hub-monitor -m 0600 token /etc/ssh-hub-monitor/token
sudo install -m 0644 ssh-hub-monitor.service /etc/systemd/system/ssh-hub-monitor.service
sudo systemctl daemon-reload
sudo systemctl enable --now ssh-hub-monitor
```

`StateDirectory` создаёт каталог базы. Процесс не может изменять системные файлы, домашние каталоги или папку программы. Конфиг меняется вручную; затем `sudo systemctl restart ssh-hub-monitor`. Статус и ошибки запуска видны через `systemctl status ssh-hub-monitor`; секреты туда не выводятся. Само приложение не устанавливает сервис на сервер без выбранного пользователем места размещения.

## Цели и интерпретация

- `kind`: `tcp`, `http` или `wan`. WAN — явная метка цели для отдельных строк и уведомлений.
- TCP: `host` и `port`; открытый порт означает возможность TCP-соединения, без проверки входа или состояния всей службы.
- HTTP: `url` и `expected_status` (по умолчанию 200/204); выполняется HEAD без редиректов, cookies, паролей или тела ответа. Сертификаты HTTPS проверяются. URL с userinfo, query или fragment запрещены. Если сервис не поддерживает HEAD, выбери TCP-проверку или совместимый health endpoint.
- `interval_seconds`: 10–86400; `timeout_seconds`: 0.2–15. До 256 целей и 16 одновременных проверок. DNS и сеть ограничены дополнительным жёстким deadline отдельного процесса.
- Проверки идут с сервера коллектора, через его текущую маршрутизацию. Метка «WAN2» сама по себе не направляет трафик во второй WAN и не определяет режим failover. Для отдельной оценки каждой линии размести коллектор на соответствующей стороне или настрой маршрутизацию сервера. Неработающая резервная линия и линия в ожидании различаются по данным маршрутизатора; TCP-проверка их не подменяет.
- «Доступность 24 ч» — доля успешных **собранных измерений**, а не гарантированная доля времени. Пропуск сбора не считается успешным измерением. При остановке сервиса история сохраняется, а приложение помечает измерения старше трёх интервалов (минимум двух минут) как устаревшие.
- Задержка TCP — установка соединения; HTTP — время до заголовков HEAD. Это разные метрики, их нужно сравнивать внутри одной цели.

Хранятся 1–90 дней (30 по умолчанию), максимум 500 000 измерений на коллектор. При достижении лимита удаляются самые старые. API отдаёт последние 1–1000 измерений, приложение запрашивает 250. Удаление старых строк не обязательно сразу уменьшает размер SQLite; освободившееся место используется повторно. Копируй базу согласованно средствами SQLite, если нужна серверная резервная копия.

Уведомления macOS отправляются только после разрешения пользователя, при подключённом клиенте и реальном новом изменении свежего статуса. Первое подключение, перезапуск коллектора и загрузка старых измерений не создают уведомлений о якобы произошедших событиях. Пока Mac выключен, сервер сохраняет историю; push-уведомления через внешний сервис в эту версию не входят.

## API v1

Все GET-запросы требуют `Authorization: Bearer <token>`; запросы изменений возвращают 405. API не принимает новые цели, команды или настройки от клиентов.

- `GET /v1/snapshot`: `version`, `generated_at`/`started_at` (Unix seconds), `retention_days`, `healthy`, `targets`.
- Каждая цель: `id`, `name`, `kind`, `interval_seconds`, `latest`, `samples_24h`, `availability_24h`.
- `GET /v1/history?target=<id>&limit=250`: `version`, `target_id`, `samples` от новых к старым.
- Измерение: `id`, `target_id`, `checked_at`, `reachable`, `latency_ms`, `detail`, `status_code`.
- `detail`: `tcp_open`, `http_ok`, `http_status`, `timeout`, `tls_error`, `unreachable`. Нет необработанных сообщений исключений, адресов или тел ответов.

Нет CORS, управления через веб-страницу, редиректов и отправки данных сторонним системам. Ограничены число клиентов, длительность запроса и размер JSON. Не передавай токен через URL.

## Проверка

```sh
python3 MonitoringCollector/test_collector.py /path/to/compiled-monitoring-tests
```

Запускай из корня репозитория; без пути к Swift-тестам проверяется только Python-часть. Все проверки используют временные каталоги и собственные localhost TCP/HTTP-сервера: конфигурацию, аутентификацию, read-only API, реальный сбор и завершение процессов, retention/лимит строк, deadline заблокированной пробы, обработку HTTP ошибок/редиректов. Нативные тесты также проверяют scope, запрет небезопасных endpoint, устаревание, некорректные ответы, size limit и отмену с drain URLSession.

Использованные интерфейсы: [Python multiprocessing](https://docs.python.org/3/library/multiprocessing.html), [systemd.exec](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html), [Caddy reverse_proxy](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy).
