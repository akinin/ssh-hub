import SwiftUI

extension NetworkTool {
    var defaultDescription: String {
        switch self {
        case .nmap: return "Поиск доступных узлов, TCP-портов и версий сервисов через установленный Nmap. Расширенный NSE содержит разрешённые скрипты и готовые профили. Скорость, таймауты и состав проверки задаются вручную. Запуски для записи попадают в общую историю."
        case .nuclei: return "Проверка выбранной записи по официальным шаблонам Nuclei: CVE, критичность и CVSS. Ограничения нагрузки и времени, остановка, история и экспорт. Не использует пароли записи; SSH/VPN-маршрут не обходится."
        case .lynis: return "Аудит Linux/Unix через SSH: настройки системы и рекомендации Lynis. На сервере нужны Python 3 и Lynis. Без автоматического sudo, исправления настроек и plugins. Аудит обычного пользователя имеет ограниченное покрытие."
        case .trivy: return "Проверка пакетов и конфигураций системы, каталога или контейнерного образа через SSH. На сервере нужны Python 3 и Trivy. Базы и образы могут загружаться из интернета. Сканер секретов отключён."
        case .checks: return "Общая история Nmap/NSE, Nuclei, Lynis и Trivy по записи. Сравнение сопоставимых проверок, статусы находок, комментарии, KEV/EPSS и экспорт JSON/CSV/TXT. Частичная проверка не подтверждает устранение."
        case .dns: return "DNS-записи указанного типа, выбор и сравнение резолверов. Запросы выполняются с Mac. Полезно для диагностики имён и различий между DNS-серверами."
        case .ports: return "Проверка доступности выбранных TCP-портов с Mac или через SSH-шлюз. Открытый порт подтверждает соединение, но не успешную авторизацию или исправность приложения."
        case .tls: return "Проверка доверия TLS, соответствия имени, цепочки, SAN, отпечатков и срока сертификата. Недоверенный сертификат показывается без создания исключения. Прямой TLS с Mac, без STARTTLS."
        case .ip: return "Расчёт IPv4/IPv6-подсети: сеть, маска, диапазон адресов, разбиение на подсети и проверка принадлежности IP. Работает локально без сетевых запросов."
        case .route: return "Ping и диагностика маршрута до узла. Задержка и потери помогают найти проблемы связи; отсутствие ответа может означать фильтрацию ICMP."
        case .http: return "Код ответа HTTP, заголовки, перенаправления и времена DNS/TCP/TLS/первого байта. Тело не сохраняется. Без cookies и паролей записи; HTTPS проверяет сертификат."
        case .wake: return "Отправка Wake-on-LAN magic packet по MAC-адресу на заданный broadcast и UDP-порт. На устройстве и в сети должна быть включена поддержка Wake-on-LAN."
        case .speed: return "Замер пропускной способности через iperf3: TCP/UDP, направление, длительность и параллельные потоки. Нужны установленный iperf3 на Mac и сервер iperf3 на другой стороне. Создаёт заметную нагрузку на сеть."
        case .registration: return "Регистрационные сведения о домене или IP через Whois/RDAP. Запрос передаётся внешнему реестру; состав и полнота ответа зависят от сервера и политики реестра."
        case .bonjour: return "Обнаружение Bonjour/mDNS-сервисов в локальной сети по выбранному типу. Устройство должно публиковать сервис; маршрутизаторы обычно не передают mDNS между подсетями."
        case .ssh: return "Диагностика SSH: эффективные параметры и проверка соединения с сохранением штатной проверки ключа сервера. Может запросить подтверждение нового ключа или учётные данные."
        case .passwords: return "Локальный генератор паролей с выбором длины и набора символов. Генерация не меняет пароли на серверах и не сохраняет их автоматически."
        case .transform: return "Локальные преобразования текста и контрольные суммы: кодирование, декодирование и проверка хешей. Входные данные не отправляются в сеть."
        case .descriptions: return "Справочник всех инструментов. Описания можно изменить, сохранить для текущего профиля или вернуть к исходному тексту. Редактирование справочника не меняет команды и параметры запуска."
        }
    }
}
struct ToolDescriptionsView: View {
    @EnvironmentObject var store: AliasStore
    @State private var selected = NetworkTool.nmap
    @State private var values: [String: String] = [:]
    @State private var expected: [String: String] = [:]
    @State private var text = ""
    @State private var error: String?
    private var file: HubFeatureFile { HubFeatureFile(feature: "ToolDescriptions", config: store.config.url, profile: store.profiles.active, limit: 200_000) }
    private func load() {
        do { values = try file.load([String: String].self, fallback: [:]); expected = values; text = values[selected.rawValue] ?? selected.defaultDescription; error = nil }
        catch { self.error = error.localizedDescription }
    }
    var body: some View {
        HStack(spacing: 0) {
            List(NetworkTool.allCases, selection: $selected) { tool in
                Label(tool.title, systemImage: tool.icon).padding(.vertical, 6).tag(tool)
            }.frame(width: 240)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Label(selected.title, systemImage: selected.icon).font(.title2).bold()
                Text("Описание можно отредактировать. Параметры работы инструмента сохраняются отдельно.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $text).font(.body).padding(8).overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)) }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                VStack(alignment: .leading, spacing: 8) {
                    Button("Исходное описание") { text = selected.defaultDescription }
                    HStack {
                    Spacer(minLength: 0)
                    Button("Отменить изменения") { text = values[selected.rawValue] ?? selected.defaultDescription }
                    Button("Сохранить") {
                        do {
                            guard !AppAccess.shared.locked, try file.load([String: String].self, fallback: [:]) == expected else { throw ConfigError.message("Настройки изменились. Открой справочник заново.") }
                            var next = values; next[selected.rawValue] = text == selected.defaultDescription ? nil : text
                            try file.write(next); values = next; expected = next; error = nil
                        } catch { self.error = error.localizedDescription }
                    }.buttonStyle(.borderedProminent).disabled(text.count > 8000 || text == (values[selected.rawValue] ?? selected.defaultDescription))
                    }
                }
            }.padding(18).frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).onAppear { load() }.onChange(of: selected) { _, _ in text = values[selected.rawValue] ?? selected.defaultDescription; error = nil }
            .onChange(of: store.profiles.active) { _, _ in load() }.onChange(of: store.config.url) { _, _ in load() }
    }
}
