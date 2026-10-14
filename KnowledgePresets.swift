import Foundation

enum KnowledgePresets {
    // Append-only order: IDs are persisted in assignments and encrypted archives.
    static let items: [KnowledgeItem] = {
        var result: [KnowledgeItem] = []
        func add(_ kind: KnowledgeKind, _ group: String, _ title: String, _ summary: String, _ content: String, variables: [KnowledgeVariable] = [], steps: [KnowledgeStep] = []) {
            var item = KnowledgeItem(); item.id = KnowledgeCatalog.stableID(result.count + 1); item.kind = kind; item.group = group; item.title = title; item.summary = summary; item.content = content; item.variables = variables; item.steps = steps; result.append(item)
        }
        add(.instruction, "Debian", "Перед обновлением Debian", "Проверка места, состояния пакетов и плана обновления.", """
        # План обслуживания {{name}}
        1. Сохрани резервную копию данных и конфигурации вне сервера. Проверь возможность восстановления и доступ к консоли.
        2. Проверь свободное место: `df -h` и `df -i`.
        3. Проверь пакеты: `dpkg --audit` и `apt-mark showhold`.
        4. После осознанного обновления индексов APT изучи план `apt-get -s upgrade`.
        5. Выполняй обновление в согласованное окно. После него проверь службы и приложения.
        Источник: https://www.debian.org/releases/stable/releasenotes
        """)
        add(.instruction, "Proxmox", "Проверка перед обслуживанием Proxmox", "Узлы, хранилища, ВМ и резервные копии.", """
        # Proxmox: {{host}}
        1. Запиши версии: `pveversion -v`.
        2. Проверь `pvesm status`, `qm list`, `pct list`. Для кластера отдельно проверь кворум.
        3. Убедись в наличии проверенных резервных копий вне узла; снимок ВМ не заменяет резервную копию.
        4. Согласуй остановку или миграцию нагрузок. Не меняй сеть и хранилища без плана возврата.
        5. После работ сравни состояния и проверь доступность приложений.
        Документация: https://pve.proxmox.com/pve-docs/
        """)
        add(.instruction, "Home Assistant", "Резервная копия и восстановление Home Assistant", "План для Home Assistant OS с проверкой копии вне устройства.", """
        # Home Assistant
        1. В настройках открой «Система → Резервные копии», создай копию и проверь её состав.
        2. Сохрани копию вне устройства. При шифровании отдельно сохрани аварийный комплект восстановления.
        3. Перед восстановлением изучи требования текущей версии; выбери нужные компоненты и дождись завершения.
        4. Проверь интеграции, автоматизации и журналы; убедись, что оборудование доступно.
        Руководство: https://www.home-assistant.io/common-tasks/general/
        """)
        add(.instruction, "Wiren Board", "Поиск ошибки RS-485 на Wiren Board", "Порядок проверки драйвера и линии без изменения выходов.", """
        # RS-485
        1. Зафиксируй версию прошивки и настройки порта в веб-интерфейсе.
        2. Проверь состояние `wb-mqtt-serial` и последние сообщения его журнала.
        3. Сопоставь ошибки с адресами устройств; проверь питание, полярность, скорость, чётность и терминаторы по документации оборудования.
        4. Для диагностики не запускай второй master на порту, занятом драйвером. Изменения конфигурации выполняй отдельно с резервной копией.
        Документация: https://wiki.wirenboard.com/wiki/Wb-mqtt-serial_driver
        """)
        add(.instruction, "UniFi", "Проверка устройства UniFi перед изменениями", "Контроллер, версия, связь и возможность возврата.", """
        # UniFi
        1. Проверь версию устройства, его состояние и управляющий адрес в UniFi Network.
        2. Сохрани резервную копию контроллера и текущие настройки сети.
        3. Проверь VLAN управления, DNS, время, маршрут к контроллеру и питание PoE.
        4. Запиши последствия для клиентов перед изменением uplink/VLAN. Проверь доступ после применения.
        Документация: https://help.ui.com/
        """)
        add(.instruction, "Docker", "Разбор перезапусков контейнера", "Состояние, ресурсы, завершение и журнал.", """
        # Контейнер {{container}}
        1. Сверь `docker ps -a` и `docker stats --no-stream`.
        2. Изучи последние строки `docker logs --tail 100 ИМЯ` и код завершения в `docker inspect`.
        3. Проверь место, лимит памяти, зависимости и параметры healthcheck.
        4. Сохрани нужный вывод до пересоздания контейнера. Изменение restart policy не устраняет причину сбоя.
        Документация: https://docs.docker.com/reference/cli/docker/
        """, variables: [KnowledgeVariable(name: "container", value: "app")])
        add(.instruction, "Git", "Проверка изменений перед публикацией", "Diff, секреты, тесты и состав коммита.", """
        # Рабочий репозиторий
        1. Проверь `git status --short --branch`.
        2. Изучи `git diff` и `git diff --cached`; убедись, что нет ключей, токенов и данных окружения.
        3. Запусти проверки проекта, добавь только нужные файлы, проверь итоговый diff.
        4. Создай коммит с описанием результата. Перед push проверь ветку и remote.
        Руководство: https://git-scm.com/docs
        """)
        func config(_ group: String, _ title: String, _ summary: String, _ content: String, _ vars: [(String,String)]) { add(.configuration, group, title, summary, content, variables: vars.map { KnowledgeVariable(name: $0.0, value: $0.1) }) }
        config("Nginx", "HTTP reverse proxy", "Заготовка HTTP; настрой TLS отдельно перед публикацией сервиса.", "server {\n    listen 80;\n    server_name {{domain}};\n    location / {\n        proxy_pass http://{{backend}};\n        proxy_set_header Host $host;\n        proxy_set_header X-Real-IP $remote_addr;\n        proxy_set_header X-Forwarded-Proto $scheme;\n    }\n}\n", [("domain","panel.example.test"),("backend","127.0.0.1:8123")])
        config("Docker", "Compose: сервис на loopback", "Локальная публикация порта, постоянный том; замени образ и пути.", "services:\n  app:\n    image: {{image}}\n    restart: unless-stopped\n    ports:\n      - \"127.0.0.1:{{local_port}}:{{container_port}}\"\n    volumes:\n      - app_data:{{data_path}}\nvolumes:\n  app_data:\n", [("image","example/app:1.0"),("local_port","8080"),("container_port","80"),("data_path","/var/lib/app")])
        config("systemd", "Служба systemd", "Непривилегированный сервис с каталогом и перезапуском при сбое.", "[Unit]\nDescription={{service_title}}\nAfter=network-online.target\nWants=network-online.target\n\n[Service]\nType=simple\nUser={{service_user}}\nWorkingDirectory={{workdir}}\nExecStart={{executable}}\nRestart=on-failure\nNoNewPrivileges=true\n\n[Install]\nWantedBy=multi-user.target\n", [("service_title","Application"),("service_user","app"),("workdir","/opt/app"),("executable","/opt/app/bin/server")])
        config("SSH", "SSH-алиас через шлюз", "IdentityFile — только путь к ключу, содержимое ключа не вставляется.", "Host {{alias}}\n    HostName {{host}}\n    User {{user}}\n    Port {{port}}\n    IdentityFile {{identity_path}}\n    IdentitiesOnly yes\n    ProxyJump {{gateway}}\n", [("alias","internal-server"),("identity_path","~/.ssh/id_ed25519"),("gateway","bastion")])
        config("MQTT", "Mosquitto: локальный listener", "Без удалённого доступа; аутентификацию и TLS настрой по своему проекту.", "listener {{mqtt_port}} 127.0.0.1\nallow_anonymous false\npassword_file {{password_file}}\npersistence true\npersistence_location /var/lib/mosquitto/\n", [("mqtt_port","1883"),("password_file","/etc/mosquitto/passwd")])
        config("Git", "Базовый .gitignore", "Исключение временных файлов и окружения; уже tracked-файлы не скрываются.", ".DS_Store\n.env\n.env.*\n!.env.example\n*.log\nwork/\nbuild/\ndist/\n", [])
        config("Home Assistant", "HTTP за reverse proxy", "Укажи только доверенный прокси и проверь актуальную документацию HA.", "http:\n  use_x_forwarded_for: true\n  trusted_proxies:\n    - {{proxy_address}}\n", [("proxy_address","127.0.0.1")])
        func step(_ title: String, _ command: String, _ explanation: String, _ warning: String = "") -> KnowledgeStep { KnowledgeStep(title: title, command: command, explanation: explanation, warningContains: warning) }
        func diagnostic(_ group: String, _ title: String, _ summary: String, _ steps: [KnowledgeStep], _ vars: [(String,String)] = []) {
            add(.diagnostic, group, title, summary, "Проверки собирают сведения; отсутствие предупреждений не гарантирует исправность. Ненулевой код может означать недостаток прав или отсутствие утилиты. Изучи вывод и пояснение каждого шага.", variables: vars.map { KnowledgeVariable(name: $0.0, value: $0.1) }, steps: steps)
        }
        diagnostic("Linux", "Сервер тормозит", "Linux: нагрузка, память, процессы, дисковый ввод-вывод.", [step("Нагрузка", "uptime", "Сравни load average с числом ядер."), step("Память", "free -h", "Смотри available и использование swap."), step("CPU и I/O", "vmstat 1 5", "wa — ожидание I/O; si/so — обмен со swap."), step("Процессы", "ps aux --sort=-%cpu | head -n 21", "Снимок потребления CPU; GNU ps.")])
        diagnostic("Linux", "Заканчивается место", "Заполнение файловых систем, inode и системного журнала.", [step("Файловые системы", "df -h", "Найди заполненные разделы."), step("Inode", "df -i", "Исчерпание inode блокирует создание файлов."), step("Журнал", "journalctl --disk-usage", "Размер systemd journal; очистка не выполняется."), step("Диски", "lsblk -f", "Сопоставь разделы и точки монтирования.")])
        diagnostic("Debian", "Состояние APT и dpkg", "Неполные установки, удержанные пакеты, план обновления без установки.", [step("Аудит dpkg", "dpkg --audit", "Непустой вывод требует разбора."), step("Hold", "apt-mark showhold", "Пакеты с запретом автоматического обновления."), step("План", "apt-get -s upgrade", "Используется имеющийся кэш, ничего не устанавливается.")])
        diagnostic("systemd", "Проблема службы", "Состояние, свойства и последние события выбранного unit.", [step("Состояние", "systemctl status --no-pager -- {{unit}}", "Ненулевой код ожидаем для неактивной службы.", "failed"), step("Свойства", "systemctl show -p ActiveState -p SubState -p Result -- {{unit}}", "Result объясняет последнюю ошибку.", "Result=exit-code"), step("Журнал", "journalctl -u {{unit}} -n 100 --no-pager", "Сопоставь время ошибки с журналом.")], [("unit","ssh.service")])
        diagnostic("Docker", "Контейнер перезапускается", "Сведения контейнера, ресурсы и последние сообщения; Docker CLI на сервере.", [step("Контейнеры", "docker ps -a", "Состояние и число перезапусков."), step("Состояние контейнера", "docker inspect --format '{{json .State}}' {{container}}", "ExitCode, OOMKilled, Error и Health."), step("Ресурсы", "docker stats --no-stream {{container}}", "CPU и лимит памяти."), step("Журнал", "docker logs --tail 100 {{container}}", "Причину завершения ищи в последних сообщениях.")], [("container","app")])
        diagnostic("Wiren Board", "MQTT и RS-485", "Службы и журналы контроллера; выходы и правила не изменяются.", [step("Драйвер", "systemctl status wb-mqtt-serial --no-pager", "Проверь active и причины отказа.", "failed"), step("RS-485", "journalctl -u wb-mqtt-serial -n 100 --no-pager", "Ошибки связи и адрес устройства."), step("MQTT", "systemctl status mosquitto --no-pager", "Состояние брокера.", "failed"), step("Правила", "journalctl -u wb-rules -n 100 --no-pager", "Ошибки пользовательских правил.")])
        diagnostic("Home Assistant", "Состояние Home Assistant OS", "Нужен доступный CLI ha; до 100 строк журналов.", [step("Core", "ha core info", "Версия и состояние Core."), step("Supervisor", "ha supervisor info", "Состояние управления HAOS."), step("Журнал Core", "ha core logs | tail -n 100", "Последние события Core; полный журнал может быть большим.")])
        diagnostic("Proxmox", "Состояние узла Proxmox", "Версии, хранилища, ВМ и LXC.", [step("Версии", "pveversion -v", "Сверь совместимость пакетов."), step("Хранилища", "pvesm status", "Active и заполнение."), step("ВМ", "qm list", "Состояния QEMU-машин."), step("Контейнеры", "pct list", "Состояния LXC.")])
        diagnostic("Сеть", "Сеть Linux", "Интерфейсы, маршруты, DNS и слушающие сокеты.", [step("Адреса", "ip -br address", "Адрес и состояние интерфейса."), step("Маршруты", "ip route show", "Default route и маршрут к нужной сети."), step("DNS", "cat /etc/resolv.conf", "Настроенный resolver."), step("Сокеты", "ss -lntup", "Порт должен слушать нужный адрес.")])
        diagnostic("Git", "Состояние репозитория", "Изменения и последний коммит в явно выбранной папке.", [step("Состояние", "git -C {{directory}} status --short --branch", "Незакоммиченные изменения и ветка."), step("Diff", "git -C {{directory}} --no-pager diff --stat", "Сводка изменений."), step("Последний коммит", "git -C {{directory}} --no-pager log -1 --oneline", "Проверь ожидаемую ревизию.")], [("directory","/opt/project")])
        for (title, port, local, group) in [("RDP через шлюз",3389,13389,"Windows"),("VNC через шлюз",5900,15900,"VNC"),("Home Assistant",8123,18123,"Home Assistant"),("Proxmox",8006,18006,"Proxmox"),("UniFi",443,18443,"UniFi"),("PostgreSQL",5432,15432,"Базы данных"),("MQTT",1883,11883,"MQTT")] {
            var item = KnowledgeItem(); item.id = KnowledgeCatalog.stableID(result.count + 1); item.kind = .tunnel; item.title = title; item.group = group; item.summary = "Локальный проброс через выбранный SSH-шлюз; адрес сервиса задаётся со стороны шлюза."; item.destinationPort = port; item.localPort = local; item.content = "Для встроенного RDP, VNC и веба автоматический туннель с жизненным циклом вкладки задаётся в редакторе записи. Этот шаблон создаёт отдельный управляемый профиль в разделе SSH-туннелей."; result.append(item)
        }
        var socks = KnowledgeItem(); socks.id = KnowledgeCatalog.stableID(result.count + 1); socks.kind = .tunnel; socks.title = "SOCKS5 через SSH"; socks.group = "Сеть"; socks.summary = "SOCKS5 на loopback для явно настроенных приложений."; socks.tunnelKind = .socks; socks.localPort = 1080; result.append(socks)
        return result
    }()
}
