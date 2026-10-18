import Foundation
import Combine
import CryptoKit
import CoreFoundation

enum LoginNotificationAction: String, CaseIterable {
    case inspect, install, configure, enable, disable, remove
    var title: String {
        switch self {
        case .inspect: return "Проверить состояние"
        case .install: return "Установить уведомления"
        case .configure: return "Сохранить настройки"
        case .enable: return "Включить уведомления"
        case .disable: return "Отключить уведомления"
        case .remove: return "Удалить уведомления"
        }
    }
}
struct LoginNotificationConfiguration: Codable, Equatable {
    var chatID = ""
    var hostLabel = ""
    var tag = "SSH_Login"
    var messageThreadID: Int?
    enum CodingKeys: String, CodingKey { case chatID = "chat_id", hostLabel = "host_label", tag, messageThreadID = "message_thread_id" }
    var validation: String? {
        guard chatID.utf8.count <= 64, !chatID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains), SSHConfig.matches(chatID, "^(?:-?[1-9][0-9]{0,18}|@[A-Za-z][A-Za-z0-9_]{4,31})$") else { return "Укажи числовой Telegram chat_id или @имя канала." }
        guard !hostLabel.trimmingCharacters(in: .whitespaces).isEmpty, hostLabel.utf8.count <= 200, !hostLabel.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return "Укажи название узла до 200 байт без управляющих символов." }
        guard tag.utf8.count <= 80, tag.isEmpty || tag.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" }), messageThreadID.map({ (1...2_147_483_647).contains($0) }) ?? true else { return "Тег — до 80 байт: буквы, цифры, дефис и подчёркивание; номер темы — от 1 до 2147483647." }
        return nil
    }
    static func validToken(_ token: String) -> Bool { !token.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) && SSHConfig.matches(token, "^[0-9]{4,20}:[A-Za-z0-9_-]{20,200}$") }
}
struct LoginNotificationDelivery: Decodable, Equatable { var state: String; var date: String? }
struct LoginNotificationStatus: Decodable, Equatable {
    var schema: Int
    var state: String
    var enabled: Bool
    var hasToken: Bool
    var configuration: LoginNotificationConfiguration
    var revision: String
    var paths: [String]
    var warnings: [String]
    var delivery: LoginNotificationDelivery?
    enum CodingKeys: String, CodingKey { case schema, state, enabled, hasToken = "has_token", configuration, revision, paths, warnings, delivery }
    func validate() throws {
        guard schema == 1, ["absent", "managed", "legacy", "foreign"].contains(state), revision.utf8.count == 64, SSHConfig.matches(revision, "^[a-f0-9]{64}$"), paths.count <= 32,
              paths.allSatisfy({ $0.utf8.count <= 512 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }),
              warnings.count <= 20, warnings.allSatisfy({ $0.utf8.count <= 1000 }),
              configuration.chatID.utf8.count <= 100, configuration.hostLabel.utf8.count <= 200, configuration.tag.utf8.count <= 100,
              delivery.map({ $0.state.utf8.count <= 100 && ($0.date?.utf8.count ?? 0) <= 100 }) ?? true else { throw ConfigError.message("Сервер вернул неподдерживаемое состояние уведомлений.") }
    }
}
struct LoginNotificationPlan: Identifiable {
    let id = UUID()
    let action: LoginNotificationAction
    let entry: SSHAlias
    let fingerprint: String
    let snapshot: MaintenanceConfigSnapshot
    let revision: String
    let configuration: LoginNotificationConfiguration
    let newToken: String?
    let adoptLegacy: Bool
    let manager: String
    let helper: Data
    let previous: LoginNotificationStatus
    init(action: LoginNotificationAction, entry: SSHAlias, fingerprint: String, snapshot: MaintenanceConfigSnapshot, revision: String, configuration: LoginNotificationConfiguration, newToken: String?, adoptLegacy: Bool, manager: String, helper: Data, previous: LoginNotificationStatus) {
        self.action = action; self.entry = entry; self.fingerprint = fingerprint; self.snapshot = snapshot; self.revision = revision
        let editsSettings = action == .install || action == .configure
        self.configuration = editsSettings ? configuration : previous.configuration
        self.newToken = editsSettings ? newToken : nil
        self.adoptLegacy = adoptLegacy; self.manager = manager; self.helper = helper; self.previous = previous
    }
    var remoteCommand: String { "/usr/bin/python3 -I -B -c " + SSHConfig.shellQuote(manager) }
    var reviewText: String {
        let configText = String(decoding: (try? JSONEncoder().encode(configuration)) ?? Data(), as: UTF8.self)
        let tokenText = action == .remove ? "удалить с сервера" : newToken == nil ? "сохранить текущий на сервере" : "заменить введённым значением"
        let changes: String
        switch action {
        case .install: changes = adoptLegacy ? "Перенести распознанную схему: сохранить настройки и токен на сервере, заменить только известный SSH-хук и его файлы управляемой службой." : "Установить собственный PAM-хук, локальную очередь и службу доставки Telegram."
        case .configure: changes = "Обновить только настройки управляемых уведомлений. Пустой токен сохраняет текущий серверный токен."
        case .enable: changes = "Включить уведомления с сохранёнными настройками."
        case .disable: changes = "Отключить уведомления. Настройки и токен останутся на сервере."
        case .remove: changes = "Удалить управляемый PAM-хук, службу, очередь и настройки, включая серверный токен."
        case .inspect: changes = "Прочитать состояние без изменения файлов."
        }
        return "\(action.title)\n\nСервер: \(entry.user)@\(entry.host):\(entry.port)\n\n\(changes)\n\nЦелевые пути:\n/etc/pam.d/sshd — только строка уведомлений\n/usr/local/lib/ssh-hub-login-notify/\n/etc/ssh-hub-login-notify/\n/var/lib/ssh-hub-login-notify/\n/var/lib/ssh-hub-login-notify.lock\n/run/ssh-hub-login-notify/\n/var/lib/.ssh-hub-login-transaction-* — временные файлы отката\n/etc/systemd/system/ssh-hub-login-notify.service\n" + (adoptLegacy ? "/usr/local/sbin/ssh-login-telegram\n/etc/ssh-login-telegram.conf\n" : "") + "\nНастройки:\n\(configText)\nТокен: \(tokenText)\n\nНужны Linux, root, Python 3.9+ и systemd. Настройки входа SSH, пакеты, firewall и общие уведомления Proxmox не меняются. PAM только передаёт событие через локальный сокет без ожидания сети; очередь и доставка выполняются отдельно. При недоступной службе событие пропускается. Временные копии отката закрыты правами root и удаляются после успеха.\n\nПроверяемая ревизия: \(revision)\nSHA-256 notify.py: \(SHA256.hash(data: helper).map { String(format: "%02x", $0) }.joined())\n\nТочная команда управления (настройки и секрет передаются отдельно через stdin):\n\(remoteCommand)\n\nИсходник notify.py:\n\(String(decoding: helper, as: UTF8.self))"
    }
    func payload() throws -> Data {
        var object: [String: Any] = ["schema": 1, "action": action.rawValue, "expected_revision": revision,
            "config": try JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)), "adopt_legacy": adoptLegacy,
            "helper": helper.base64EncodedString(), "helper_sha256": SHA256.hash(data: helper).map { String(format: "%02x", $0) }.joined()]
        if let newToken { object["token"] = newToken }
        let data = try JSONSerialization.data(withJSONObject: object)
        guard data.count <= 262_144 else { throw ConfigError.message("План уведомлений превышает допустимый размер.") }; return data
    }
}

enum LoginNotificationFailure {
    static func message(_ data: Data) -> String {
        let code = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String
        switch code {
        case "revision_changed", "stale_revision", "revision_mismatch", "state_changed": return "Состояние на сервере изменилось. Проверь его заново и повторно просмотри действие."
        case "root_linux_required": return "Нужен Linux и сохранённая SSH-запись root. Пароль sudo приложение не запрашивает."
        case "unsupported", "dependencies_required", "systemd_required": return "Нужны Python 3.9+ и запущенный systemd. Установи зависимости на сервере и повтори проверку."
        case "pam_disabled", "unsupported_pam": return "SSH-сервер не использует поддерживаемый PAM-сервис sshd. Параметры аутентификации автоматически не меняются."
        case "legacy_requires_adoption": return "Сначала явно перенеси существующую схему в управление SSH Hub."
        case "foreign_installation", "unsafe_path", "unrecognized_legacy", "ownership_mismatch", "conflict": return "Обнаружены неизвестные или изменённые файлы уведомлений. Автоматическая перезапись и удаление запрещены."
        case "invalid_configuration", "invalid_payload", "invalid_config", "invalid_token", "token_required", "invalid_request", "invalid_helper": return "Проверь токен бота, chat_id, название узла и тему сообщения."
        case "service_failed", "verification_failed", "operation_failed", "interrupted", "recovery_required", "systemd_failed", "apply_failed", "rollback_failed": return "Сервер не подтвердил изменение службы. Проверь состояние заново; сведения о восстановлении доступны на сервере."
        case "busy": return "На сервере уже выполняется действие с уведомлениями. Дождись завершения и проверь состояние."
        case "already_installed", "not_installed": return "Установка изменилась. Проверь состояние заново."
        case "response_limit": return "Ответ сервера превысил допустимый размер. Проверь состояние заново."
        default: return "Действие не подтверждено. После обрыва SSH оно могло завершиться: проверь состояние перед повтором."
        }
    }
    private static func safeObject(_ value: Any, depth: Int = 0) -> Bool {
        guard depth <= 16 else { return false }
        if let string = value as? String {
            guard string.utf8.count <= 4000, !string.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return false }
            return (try? NSRegularExpression(pattern: "[0-9]{4,20}:[A-Za-z0-9_-]{20,200}").firstMatch(in: string, range: NSRange(string.startIndex..., in: string))) == nil
        }
        if let object = value as? [String: Any] {
            let forbidden: Set<String> = ["token", "bottoken", "telegrambottoken", "password", "secret", "authorization", "credentials", "apikey", "botkey"]
            return object.count <= 50 && object.allSatisfy { key, item in
                let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
                return (normalized == "hastoken" || !forbidden.contains(where: { normalized.contains($0) })) && safeObject(key, depth: depth + 1) && safeObject(item, depth: depth + 1)
            }
        }
        if let array = value as? [Any] { return array.count <= 100 && array.allSatisfy { safeObject($0, depth: depth + 1) } }
        return value is NSNumber || value is NSNull
    }
    static func decode(_ data: Data) throws -> LoginNotificationStatus {
        guard data.count <= 16_384, let text = String(data: data, encoding: .utf8), !text.contains("\u{0}"),
              !text.contains(where: { $0 == "\u{1b}" }),
              (try? NSRegularExpression(pattern: "[0-9]{4,20}:[A-Za-z0-9_-]{20,200}").firstMatch(in: text, range: NSRange(text.startIndex..., in: text))) == nil,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], safeObject(object),
              let ok = object["ok"] as? NSNumber, CFGetTypeID(ok) == CFBooleanGetTypeID(), ok.boolValue,
              let raw = object["status"] else { throw ConfigError.message(message(data)) }
        let value = try JSONDecoder().decode(LoginNotificationStatus.self, from: JSONSerialization.data(withJSONObject: raw))
        try value.validate(); return value
    }
}

@MainActor final class LoginNotificationModel: ObservableObject, Identifiable {
    private static var active: [UUID: LoginNotificationModel] = [:]
    static var pending: Bool { !active.isEmpty }
    static func stopAll() { Array(active.values).forEach { $0.stop() } }
    let id = UUID()
    let entryTitle: String
    let destination: String
    let entry: SSHAlias
    private let config: URL
    private let resolveEntry: () -> SSHAlias?
    private let resources: URL?
    @Published var configuration = LoginNotificationConfiguration()
    @Published var token = ""
    @Published var adoptLegacy = false
    @Published private(set) var status: LoginNotificationStatus?
    @Published private(set) var review: LoginNotificationPlan?
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var message = ""
    @Published private(set) var operation = ""
    private var task: Task<Void, Never>?
    private var worker: MonitoringInstallProcess?
    private var login: SSHLoginServer?
    private var inspectedFingerprint: String?
    private var inspectedSnapshot: MaintenanceConfigSnapshot?
    init(entry: SSHAlias, title: String, config: URL, resources: URL? = nil, resolveEntry: @escaping () -> SSHAlias?) {
        self.entry = entry; entryTitle = title; destination = entry.user + "@" + entry.host + ":" + entry.port
        self.config = config; self.resources = resources ?? Bundle.main.resourceURL?.appendingPathComponent("LoginNotifications"); self.resolveEntry = resolveEntry
        configuration.hostLabel = title
    }
    private func current() throws -> SSHAlias {
        guard let latest = resolveEntry(), latest.favoriteID == entry.favoriteID, latest.canSSH, !latest.isQuickConnection else { throw ConfigError.message("Запись или профиль изменились. Открой уведомления заново.") }
        let value = try SSHPasswordStore.preparedEntry(for: latest, config: config)
        guard value.user == "root" else { throw ConfigError.message("Для управления уведомлениями нужна сохранённая SSH-запись с пользователем root.") }
        guard MaintenancePlan.fingerprint(value) == MaintenancePlan.fingerprint(entry) else { throw ConfigError.message("Параметры записи или общих учётных данных изменились. Открой уведомления заново.") }; return value
    }
    private func sources() throws -> (String, Data) {
        guard let resources else { throw ConfigError.message("Не найден пакет управления уведомлениями.") }
        let manager = try Data(contentsOf: resources.appendingPathComponent("manage.py")), helper = try Data(contentsOf: resources.appendingPathComponent("notify.py"))
        guard manager.count <= 100_000, helper.count <= 100_000, let source = String(data: manager, encoding: .utf8) else { throw ConfigError.message("Повреждён пакет управления уведомлениями.") }; return (source, helper)
    }
    func inspect() {
        guard !busy else { return }
        do {
            let entry = try current(), source = try sources().0
            let snapshot = try MaintenanceConfigSnapshot.capture(roots: [entry.source, config, entry.preparedConfigSource ?? entry.connectionConfig(fallback: config)])
            review = nil
            start(entry: entry, snapshot: snapshot, command: "/usr/bin/python3 -I -B -c " + SSHConfig.shellQuote(source), payload: try JSONSerialization.data(withJSONObject: ["schema": 1, "action": "inspect"]), action: .inspect)
        } catch { self.error = error.localizedDescription }
    }
    func prepare(_ action: LoginNotificationAction) {
        guard !busy, action != .inspect else { return }
        do {
            let entry = try current(), sources = try sources()
            guard let status, let snapshot = inspectedSnapshot, inspectedFingerprint == MaintenancePlan.fingerprint(entry) else { throw ConfigError.message("Сначала проверь текущее состояние этой записи.") }
            try snapshot.validate()
            guard status.state != "foreign", (status.state != "legacy" || (action == .install && adoptLegacy)), (status.state != "absent" || action == .install), (status.state != "managed" || action != .install) else { throw ConfigError.message("Выбранное действие недоступно для текущего состояния. Для известной старой схемы сначала подтверди перенос в SSH Hub.") }
            if action == .install || action == .configure {
                if let issue = configuration.validation { throw ConfigError.message(issue) }
                guard token.isEmpty || LoginNotificationConfiguration.validToken(token), !token.isEmpty || status.hasToken else { throw ConfigError.message("Укажи корректный токен Telegram-бота. Пустое поле сохраняет существующий токен на сервере.") }
            }
            let editsSettings = action == .install || action == .configure
            review = LoginNotificationPlan(action: action, entry: entry, fingerprint: MaintenancePlan.fingerprint(entry), snapshot: snapshot, revision: status.revision, configuration: editsSettings ? configuration : status.configuration, newToken: editsSettings && !token.isEmpty ? token : nil, adoptLegacy: status.state == "legacy" && adoptLegacy, manager: sources.0, helper: sources.1, previous: status)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    func dismissReview() { if !busy { review = nil } }
    func applyReviewed() {
        guard !busy, let plan = review else { return }
        do {
            let current = try current()
            guard MaintenancePlan.fingerprint(current) == plan.fingerprint, status?.revision == plan.revision else { throw ConfigError.message("Параметры изменились после просмотра. Проверь состояние заново.") }
            try plan.snapshot.validate()
            start(entry: current, snapshot: plan.snapshot, command: plan.remoteCommand, payload: try plan.payload(), action: plan.action)
        } catch { self.error = error.localizedDescription }
    }
    private func start(entry: SSHAlias, snapshot: MaintenanceConfigSnapshot, command: String, payload: Data, action: LoginNotificationAction) {
        busy = true; error = nil; message = ""; operation = action.title + " через SSH…"; Self.active[id] = self
        task = Task {
            var directory: URL?
            defer { login?.stop(); login = nil; worker = nil; task = nil; busy = false; Self.active[id] = nil; if let directory { try? FileManager.default.removeItem(at: directory) } }
            do {
                let fingerprint = MaintenancePlan.fingerprint(entry)
                guard MaintenancePlan.fingerprint(try current()) == fingerprint else { throw ConfigError.message("Параметры записи изменились.") }
                try snapshot.validate()
                let allowed = entry.authentication.usesPassword ? await SSHLoginPolicy.permitsSavedPassword(for: entry, config: config) : false
                try Task.checkCancellation()
                let password = allowed ? try SSHPasswordStore.password(for: entry, config: entry.credentialConfig(fallback: config)) : nil
                let login = try SSHLoginServer(password: password, destination: "Уведомления о входе · " + destination); self.login = login
                guard let helper = Bundle.main.url(forAuxiliaryExecutable: "SSHLoginAskpass") else { throw ConfigError.message("Не найден помощник входа SSH.") }
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("login-notify-" + UUID().uuidString); directory = root
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let wrapper = try TunnelCommands.temporaryConfig(original: entry.connectionConfig(fallback: config), directory: root, interactive: true)
                var args = ConnectionProbe.arguments(config: wrapper, alias: entry.sshTarget); args.removeFirst(); args.removeLast(); args.append(command)
                for index in args.indices where args[index] == "BatchMode=yes" { args[index] = "BatchMode=no" }
                for index in args.indices where args[index] == "StrictHostKeyChecking=yes" { args[index] = "StrictHostKeyChecking=ask" }
                try snapshot.validate(); guard MaintenancePlan.fingerprint(try current()) == fingerprint else { throw ConfigError.message("Параметры записи изменились перед запуском.") }
                let worker = MonitoringInstallProcess(); self.worker = worker
                let data = try await worker.run(arguments: args, environment: ["SSH_ASKPASS": helper.path, "SSH_ASKPASS_REQUIRE": "force", "SSH_HUB_LOGIN_SOCKET": login.path], payload: payload, failureMapper: { LoginNotificationFailure.message($0) })
                try Task.checkCancellation()
                guard MaintenancePlan.fingerprint(try current()) == fingerprint else { throw ConfigError.message("Контекст записи изменился. Результат проверь заново.") }
                let result = try LoginNotificationFailure.decode(data)
                status = result; configuration = result.configuration
                if configuration.hostLabel.isEmpty { configuration.hostLabel = entryTitle }
                inspectedFingerprint = fingerprint; inspectedSnapshot = snapshot; adoptLegacy = false; review = nil; token = ""
                message = action == .inspect ? "Состояние прочитано. Настройки на сервере не менялись." : "Действие подтверждено сервером."
            } catch is CancellationError {
                message = action == .inspect ? "Проверка остановлена." : "Действие остановлено. Оно могло завершиться на сервере: проверь состояние перед повтором."
                if action != .inspect { status = nil; inspectedSnapshot = nil; inspectedFingerprint = nil; review = nil }
            } catch {
                self.error = error.localizedDescription
                if action != .inspect { status = nil; inspectedSnapshot = nil; inspectedFingerprint = nil; review = nil }
            }
            operation = ""
        }
    }
    func refreshBinding() {
        do { _ = try current(); try inspectedSnapshot?.validate() }
        catch { close(); status = nil; inspectedFingerprint = nil; inspectedSnapshot = nil; self.error = error.localizedDescription }
    }
    func stop() { task?.cancel(); worker?.cancel(); login?.stop() }
    func close() { stop(); token = ""; review = nil }
}
