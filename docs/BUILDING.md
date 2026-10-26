# Сборка и проверки SSH Hub

Все команды выполняются из корня репозитория на macOS. Готовые приложения доступны в [GitHub Releases](https://github.com/akinin/ssh-hub/releases/latest).

## Зависимости

- Xcode Command Line Tools: Swift, Clang, macOS SDK и системные инструменты упаковки.
- CMake, make, Perl и curl для FreeRDP/OpenSSL.
- Rust и Cargo через rustup; обе целевые платформы для универсальной сборки.
- Go 1.24 или новее; проверенная версия CI — 1.27.3. Свой путь к Go можно передать через `SSH_HUB_GO`.
- Python 3, пакет `cryptography` и `keepassxc-cli` для соответствующих интеграционных проверок KeePass.

```sh
rustup target add aarch64-apple-darwin x86_64-apple-darwin
```

SwiftTerm и изменённая keepass-rs включены в `Vendor/`, Go-зависимости — в `WireGuardHelper/vendor/`. Сохраняй версии, контрольные суммы и лицензии этих зависимостей. Набор vendored-исходников включает платформы, отличные от macOS: это содержимое закреплённых зависимостей, а не мусор сборки.

Первая сборка скачивает закреплённые исходные архивы FreeRDP/OpenSSL с проверкой SHA-256 и зависимости Cargo по `KDBXHelper/Cargo.lock`. Кэши RDP и Swift для разных архитектур разделены.

## Подпись

Для релизной сборки нужен сертификат с приватным ключом, чей публичный отпечаток закреплён в `signing-identity.sha1`. Приватный ключ в репозиторий не входит. Отсутствие сертификата останавливает сборку; автоматического перехода на ad-hoc нет.

Для собственной локальной разработки можно явно выбрать ad-hoc:

```sh
SSH_HUB_SIGN_IDENTITY=- zsh build.sh /private/tmp/ssh-hub-dev
```

Такую сборку не следует публиковать как официальный подписанный релиз. Устройство подписи и установка публичного сертификата описаны в [Signing/README.md](../Signing/README.md).

## Универсальная сборка

```sh
zsh build.sh /private/tmp/ssh-hub-build
zsh package-dmg.sh /private/tmp/ssh-hub-build /private/tmp/ssh-hub-dist --skip-build
```

`build.sh` запускает проверки, собирает приложение и помощники для обеих архитектур, объединяет `arm64` и `x86_64`, затем подписывает комплект. Результат: `/private/tmp/ssh-hub-build/SSH Hub.app`. `package-dmg.sh` проверяет подпись и архитектуры перед упаковкой DMG.

Для SwiftPM используется `--build-system native`; этот флаг нужен и при ручном повторении команд из скрипта. Минимальная целевая версия — macOS 14. Если установлен SDK macOS 26.5, скрипт предпочитает его SDK из `xcrun`.

## Проверки

Файлы самостоятельных проверок и стендов лежат в `Tests/`. Тесты Go и Rust остаются в своих проектах, консольная проверка SwiftPM — в `RuntimeTests/`.

Пример короткой проверки без доступа к пользовательским данным:

```sh
swiftc -parse-as-library -swift-version 5 ApplicationDefaults.swift Tests/ApplicationDefaultsTests.swift -o /private/tmp/ssh-hub-defaults-tests
/private/tmp/ssh-hub-defaults-tests
```

Проверка подписанной универсальной сборки:

```sh
python3 Tests/UniversalBuildTests.py '/private/tmp/ssh-hub-build/SSH Hub.app'
```

Ручной workflow **Universal macOS smoke** запускает опубликованный предварительный релиз на стандартных GitHub runners Intel и Apple Silicon, проверяет помощники, обновление, настройки и WireGuard loopback. Вход `source_ref` должен совпадать с коммитом, из которого запущен workflow. Права репозитория в CI — только на чтение. Временное доверие публичному сертификату настраивается только внутри одноразовой GitHub-машины; этот сценарий нельзя переносить на пользовательский Mac.

Интеграционные проверки используют временные конфиги и локальные стенды. Не запускай их против пользовательских серверов, подсетей, SSH-конфигов или паролей. Ручные UI-стенды также используют отдельные тестовые данные.

## Файлы релиза

Публикуемый комплект содержит универсальные ZIP и DMG, архив исходников точного тега, публичный `SSHHub-CodeSigning.cer`, инструкцию `SIGNING-SETUP-RU.md` и `SHA256SUMS`. Встроенное обновление ожидает стабильный Latest с тегом `vX.Y.Z` и файлом `SSH-Hub-macOS.zip`, содержащим `SSH Hub.app`.

Сборки, кэши, тестовые результаты и пользовательские данные не добавляются в Git. Готовые приложения размещаются в Releases. При подготовке новой версии обновляются версия и номер сборки в `Info.plist`, а описание изменений помещается в релиз. README остаётся описанием приложения.
