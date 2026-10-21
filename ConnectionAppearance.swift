import Foundation
import Darwin

struct ConnectionAppearance: Codable, Equatable {
    var name = ""
    var logo: Data?
    var addresses: RecordAddressPair? = nil
    var actionTiles: [RecordActionStyle]? = nil
    var pinnedFields: [String]? = nil
    var reminders: [RecordReminder]? = nil
    var reminderAppearance: RecordReminderAppearance? = nil
    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isEmpty: Bool { trimmedName.isEmpty && logo == nil && addresses == nil && (actionTiles?.isEmpty != false) && pinnedFields == nil && (reminders?.isEmpty != false) && reminderAppearance == nil }
    func title(fallback: String) -> String { trimmedName.isEmpty ? fallback : trimmedName }
    var validation: String? {
        if name.count > 80 || name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return "Название должно занимать одну строку до 80 символов."
        }
        if let addresses, !addresses.valid { return "Укажи домен без протокола и порта, корректный IPv4/IPv6 и заполни выбранный адрес подключения." }
        if let actionTiles, actionTiles.count > RecordActionStyle.limit || Set(actionTiles.map(\.id)).count != actionTiles.count || !actionTiles.allSatisfy(\.valid) { return "Некорректные настройки плиток." }
        if let fields = pinnedFields, fields.count > RecordPinnedField.allCases.count || Set(fields).count != fields.count || !fields.allSatisfy({ RecordPinnedField(rawValue: $0) != nil }) { return "Некорректный набор полей карточки." }
        if let reminders, reminders.count > 20 || Set(reminders.map(\.id)).count != reminders.count || !reminders.allSatisfy(\.valid) { return "Некорректные лицензии или оплаты: до 20 сроков на запись." }
        if let reminderAppearance, !reminderAppearance.valid { return "Некорректное оформление напоминаний." }
        if let logo, !Self.validLogo(logo) { return "Логотип должен быть PNG до 256 × 256 пикселей и 256 КБ." }
        return nil
    }
    static func validLogo(_ data: Data) -> Bool {
        guard data.count >= 33, data.count <= 262_144,
              Array(data.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10],
              Array(data[8..<16]) == [0, 0, 0, 13, 73, 72, 68, 82] else { return false }
        func size(_ offset: Int) -> UInt32 { data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } }
        return (1...256).contains(size(16)) && (1...256).contains(size(20))
    }
    static func decode(_ data: Data?) -> [String: Self] {
        guard let data, let value = try? JSONDecoder().decode([String: Self].self, from: data) else { return [:] }
        return value.filter { $0.value.validation == nil && !$0.value.isEmpty }
    }
    static func setting(_ value: Self, for id: String, in values: [String: Self]) -> [String: Self] {
        var values = values
        var value = value; value.name = value.trimmedName
        values[id] = value.isEmpty ? nil : value
        return values
    }
    static func moving(from old: String, to new: String, in values: [String: Self]) -> [String: Self] {
        guard old != new else { return values }
        var values = values
        if let value = values.removeValue(forKey: old) { values[new] = value }
        return values
    }
}

enum RecordActionPlacement: String, Codable, CaseIterable, Identifiable {
    case tiles, header, badges
    var id: String { rawValue }
    var title: String { self == .tiles ? "Плитка" : self == .header ? "Значок вверху" : "Бейдж" }
}
struct RecordActionStyle: Codable, Equatable, Identifiable {
    static let limit = 64
    var id: String
    var color: String = "blue"
    var hidden = false
    var placement: RecordActionPlacement? = nil
    var isDivider: Bool { id.hasPrefix("divider_") && id.count == 40 && id.dropFirst(8).allSatisfy { $0.isHexDigit && $0.isASCII } }
    var effectivePlacement: RecordActionPlacement { isDivider ? .tiles : isBadge ? .badges : placement == .badges ? .tiles : placement ?? RecordAction(rawValue: id)?.defaultPlacement ?? .tiles }
    var isBadge: Bool { id == RecordAction.keePass.id || id == RecordAction.vpn.id }
    static func divider() -> Self { Self(id: "divider_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(), color: "gray") }
    static let colors = ["blue", "green", "orange", "red", "purple", "pink", "gray"]
    var valid: Bool { !id.isEmpty && id.utf8.count <= 40 && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" } && Self.colors.contains(color) }
}

enum RecordAction: String, CaseIterable, Identifiable {
    case inside, browser, connect, sftp, logs, inventory, documentation, attachments, tools, edit, check, notifications, terminal, favorite, duplicate, export, keePass, vpn, delete, licenses, payments
    var id: String { rawValue }
    var defaultPlacement: RecordActionPlacement { switch self { case .keePass, .vpn: return .badges; case .favorite, .duplicate, .export, .delete: return .header; default: return .tiles } }
    var title: String { switch self { case .licenses: return "Лицензии"; case .payments: return "Оплаты"; case .favorite: return "Избранное"; case .duplicate: return "Дублировать"; case .export: return "Экспортировать"; case .keePass: return "KeePass"; case .vpn: return "VPN"; case .delete: return "Удалить"; case .inside: return "Открыть внутри"; case .browser: return "Открыть в браузере"; case .connect: return "Подключиться"; case .sftp: return "SFTP"; case .logs: return "Логи"; case .inventory: return "Инвентаризация"; case .documentation: return "Документация"; case .attachments: return "Вложения"; case .tools: return "Инструменты"; case .edit: return "Редактировать"; case .check: return "Проверить"; case .notifications: return "Уведомления"; case .terminal: return "Внешний терминал" } }
    var icon: String { switch self { case .licenses: return "key.horizontal"; case .payments: return "creditcard"; case .favorite: return "star"; case .duplicate: return "plus.square.on.square"; case .export: return "square.and.arrow.up"; case .keePass: return "key"; case .vpn: return "network.badge.shield.half.filled"; case .delete: return "trash"; case .inside: return "macwindow"; case .browser, .terminal: return "arrow.up.forward.square"; case .connect: return "cable.connector"; case .sftp: return "folder"; case .logs: return "text.alignleft"; case .inventory: return "shippingbox"; case .documentation: return "doc.richtext"; case .attachments: return "paperclip"; case .tools: return "wrench.and.screwdriver"; case .edit: return "pencil"; case .check: return "network"; case .notifications: return "bell.badge" } }
    func available(_ entry: SSHAlias) -> Bool { switch self {
        case .vpn: return entry.canSSH || [.rdp, .vnc, .web, .website, .telnet, .ftp, .ftps, .webdav].contains(entry.recordKind)
        case .inside: return entry.recordKind?.isWeb == true
        case .browser: return entry.recordKind?.isWeb == true && entry.transport?.wireGuardID == nil
        case .connect: return entry.canConnect && entry.recordKind?.isWeb != true
        case .sftp, .check, .notifications, .terminal: return entry.canSSH
        case .logs: return entry.canSSH || entry.recordKind == .localShell
        default: return true
    } }
    func detail(_ entry: SSHAlias) -> String { switch self {
        case .licenses: return "Сроки, файлы и примечания"
        case .payments: return "Даты платежей и примечания"
        case .favorite: return "Быстрый доступ к записи"
        case .duplicate: return "Создать копию записи"
        case .export: return "Сохранить в файл"
        case .keePass: return "Состояние и перенос данных"
        case .vpn: return "Маршрут WireGuard записи"
        case .delete: return "Удалить с подтверждением"
        case .inside: return "Во вкладке SSH Hub"
        case .browser: return entry.transport?.tunnel == nil ? "Браузер по умолчанию" : "Напрямую, без SSH-туннеля"
        case .connect: return entry.canSSH ? "Консоль SSH" : entry.recordKind?.title ?? "Сеанс"
        case .sftp: return "Файлы сервера"
        case .logs: return "Захват, поиск и анализ"
        case .inventory: return "Оборудование и сведения"
        case .documentation: return "Заметки и инструкции"
        case .attachments: return "Файлы записи"
        case .tools: return "Nmap, DNS, порты, TLS и IP"
        case .edit: return "Параметры записи"
        case .check: return "Доступность SSH"
        case .notifications: return "Вход по SSH → Telegram"
        case .terminal: return "Открыть отдельно"
    } }
    static func catalog(_ stored: [RecordActionStyle]?) -> [RecordActionStyle] {
        let explicit = Set((stored ?? []).map(\.id))
        let saved = (stored ?? []).flatMap { style -> [RecordActionStyle] in
            guard style.id == "renewals" else { return [style] }
            return [RecordAction.licenses, .payments].filter { !explicit.contains($0.id) }.map { action in var copy = style; copy.id = action.id; return copy }
        }
        let seen = Set(saved.map(\.id))
        return (saved + allCases.filter { !seen.contains($0.id) }.map { RecordActionStyle(id: $0.id, color: $0.defaultPlacement == .header ? "gray" : "blue", hidden: $0 == .licenses || $0 == .payments) }).filter { RecordAction(rawValue: $0.id) != nil || $0.isDivider }
    }
    static func layout(_ stored: [RecordActionStyle]?, global: [RecordActionStyle]? = nil, entry: SSHAlias) -> [RecordActionStyle] {
        catalog(stored ?? global).filter { $0.isDivider || RecordAction(rawValue: $0.id)?.available(entry) == true }
    }
    static func saving(_ edited: [RecordActionStyle], previous: [RecordActionStyle]?) -> [RecordActionStyle] {
        let seen = Set(edited.map(\.id))
        return edited + (previous ?? []).filter { !seen.contains($0.id) && !$0.isDivider && $0.id != "renewals" }
    }
    struct Section: Identifiable {
        var id: String
        var actions: [RecordActionStyle]
    }
    // Reorder only the displayed placement, preserving the other group's slots and values.
    static func moving(_ styles: [RecordActionStyle], placement: RecordActionPlacement, from offsets: IndexSet, to destination: Int) -> [RecordActionStyle] {
        let slots = styles.indices.filter { styles[$0].effectivePlacement == placement }
        guard !offsets.isEmpty, offsets.allSatisfy({ slots.indices.contains($0) }), (0...slots.count).contains(destination) else { return styles }
        let group = slots.map { styles[$0] }, moved = offsets.map { group[$0] }
        var remaining = group.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        remaining.insert(contentsOf: moved, at: destination - offsets.filter { $0 < destination }.count)
        var result = styles
        for (slot, value) in zip(slots, remaining) { result[slot] = value }
        return result
    }
    static func sections(_ styles: [RecordActionStyle]) -> [Section] {
        var result: [Section] = [], actions: [RecordActionStyle] = [], id = "first"
        for style in styles where !style.hidden && style.effectivePlacement == .tiles {
            if style.isDivider {
                if !actions.isEmpty { result.append(Section(id: id, actions: actions)); actions = [] }
                id = style.id
            } else if RecordAction(rawValue: style.id) != nil { actions.append(style) }
        }
        if !actions.isEmpty { result.append(Section(id: id, actions: actions)) }
        return result
    }

}

// App preference across profiles; per-record metadata remains an optional override.
enum RecordActionDefaults {
    static let key = "globalRecordActionTiles.v1"
    static func valid(_ values: [RecordActionStyle]) -> Bool { values.count <= RecordActionStyle.limit && Set(values.map(\.id)).count == values.count && values.allSatisfy(\.valid) }
    static func decode(_ data: Data?) -> [RecordActionStyle]? {
        guard let data, data.count <= 16384, let values = try? JSONDecoder().decode([RecordActionStyle].self, from: data), valid(values) else { return nil }
        return values
    }
    static func encode(_ values: [RecordActionStyle]?) throws -> Data {
        guard let values else { return Data() }
        guard valid(values) else { throw ConfigError.message("Некорректные общие настройки плиток.") }
        return try JSONEncoder().encode(values)
    }
}

enum RecordPinnedField: String, CaseIterable, Identifiable {
    case address, kind, username, port, alias, group, jump, keyFile
    var id: String { rawValue }
    static let defaults: [Self] = [.address, .port]
    var title: String { switch self {
        case .address: return "Адрес"; case .kind: return "Протокол"; case .username: return "Пользователь"; case .port: return "Порт"
        case .alias: return "Имя записи / SSH-алиас"; case .group: return "Папка"; case .jump: return "SSH-шлюз"; case .keyFile: return "Файл SSH-ключа"
    } }
    func value(_ entry: SSHAlias, group: String) -> String {
        switch self {
        case .address: return entry.website.flatMap { $0.isEmpty ? nil : $0 } ?? entry.host
        case .kind: return (entry.recordKind ?? .ssh).title
        case .username: return entry.user
        case .port: return (entry.canSSH || [.rdp, .vnc, .telnet, .ftp, .ftps, .webdav, .mosh].contains(entry.recordKind)) ? entry.port : ""
        case .alias: return entry.name
        case .group: return group
        case .jump: return entry.value("ProxyJump") ?? ""
        case .keyFile: return entry.value("IdentityFile") ?? ""
        }
    }
}


enum RecordReminderKind: String, Codable, CaseIterable, Identifiable {
    case license, payment
    var id: String { rawValue }
    var title: String { self == .license ? "Лицензия" : "Оплата" }
}
struct RecordLicenseFile: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var size: Int
    var digest: String
    var valid: Bool { !name.isEmpty && name != "." && name != ".." && name.utf8.count <= 255 && !name.contains(where: { $0 == "/" || $0 == "\\" }) && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) && (0...10_485_760).contains(size) && digest.count == 64 && digest.allSatisfy { "0123456789abcdef".contains($0) } }
}
struct RecordReminder: Codable, Equatable, Identifiable {
    var id = UUID()
    var kind: RecordReminderKind = .license
    var title = ""
    // A civil date, independent of the time zone in which the record was edited.
    var deadline = Self.dayString(Date())
    var noticeDays = 30
    var note: String? = nil
    var licenseFile: RecordLicenseFile? = nil
    static func calendar(_ timeZone: TimeZone = .current) -> Calendar { var result = Calendar(identifier: .gregorian); result.timeZone = timeZone; return result }
    static func dayString(_ date: Date, calendar: Calendar = Self.calendar()) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
    func date(calendar: Calendar = Self.calendar()) -> Date? {
        let pieces = deadline.split(separator: "-", omittingEmptySubsequences: false)
        guard deadline.utf8.count == 10, pieces.count == 3, pieces[0].count == 4, pieces[1].count == 2, pieces[2].count == 2,
              let year = Int(pieces[0]), let month = Int(pieces[1]), let day = Int(pieces[2]), (1970...2100).contains(year), (1...12).contains(month), (1...31).contains(day),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)), Self.dayString(date, calendar: calendar) == deadline else { return nil }
        return date
    }
    var valid: Bool { (note?.utf8.count ?? 0) <= 16384 && !(note ?? "").unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" && $0 != "\r" }) && (licenseFile == nil || (kind == .license && licenseFile!.valid)) && title.count <= 80 && !title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) && (0...3650).contains(noticeDays) && date() != nil }
    func daysRemaining(now: Date = Date(), calendar: Calendar = Self.calendar()) -> Int? {
        guard let date = date(calendar: calendar) else { return nil }
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day
    }
    func notice(now: Date = Date(), calendar: Calendar = Self.calendar()) -> RecordReminderNotice? {
        guard let days = daysRemaining(now: now, calendar: calendar), days <= noticeDays else { return nil }
        let state = days < 0 ? "Просрочено на \(-days) дн." : days == 0 ? "Срок сегодня" : "До срока: \(days) дн."
        return RecordReminderNotice(level: days < 0 ? 2 : 1, text: kind.title + (title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : " «" + title + "»") + ": " + state + " · " + deadline)
    }
}
struct RecordReminderNotice: Equatable {
    var level: Int
    var text: String
    static func collect(_ reminders: [RecordReminder]?, now: Date = Date(), calendar: Calendar = RecordReminder.calendar()) -> [Self] { (reminders ?? []).filter(\.valid).compactMap { $0.notice(now: now, calendar: calendar) }.sorted { $0.level > $1.level } }
}
struct RecordReminderAppearance: Codable, Equatable {
    var showIcon = true
    var showCount = true
    var outline = true
    var background = true
    var warningColor = "orange"
    var overdueColor = "red"
    var icon = "calendar.badge.exclamationmark"
    var opacity = 0.10
    var lineWidth = 1.0
    var tintSelection: Bool? = nil
    var selectionOpacity: Double? = nil
    static let icons = ["calendar.badge.exclamationmark", "calendar", "clock.badge.exclamationmark", "bell.badge", "creditcard", "key", "exclamationmark.triangle"]
    var valid: Bool { RecordActionStyle.colors.contains(warningColor) && RecordActionStyle.colors.contains(overdueColor) && Self.icons.contains(icon) && opacity.isFinite && (0.03...0.30).contains(opacity) && lineWidth.isFinite && (1...3).contains(lineWidth) && (selectionOpacity == nil || (selectionOpacity!.isFinite && (0.35...1).contains(selectionOpacity!))) }
    func color(_ level: Int) -> String { level > 1 ? overdueColor : warningColor }
}
enum RecordReminderDefaults {
    static let key = "recordReminderAppearance.v1"
    static func decode(_ data: Data?) -> RecordReminderAppearance {
        guard let data, data.count < 8192, let value = try? JSONDecoder().decode(RecordReminderAppearance.self, from: data), value.valid else { return RecordReminderAppearance() }; return value
    }
}


// Public metadata only. The selected value is committed through the ordinary
// record/SSH editor as HostName or the URL host; no runtime fallback or TLS bypass.
struct RecordAddressPair: Codable, Equatable {
    enum Preference: String, Codable { case domain, ip }
    var domain = ""
    var ip = ""
    var preferred: Preference = .domain
    var selected: String { preferred == .domain ? domain : ip }
    var searchText: String { domain + " " + ip }
    var valid: Bool { !selected.isEmpty && (domain.isEmpty || Self.validDomain(domain)) && (ip.isEmpty || Self.validIP(ip)) }
    static func host(_ value: String) -> String {
        value.hasPrefix("[") && value.hasSuffix("]") ? String(value.dropFirst().dropLast()) : value
    }
    static func validIP(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128, value == value.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        let parts = value.split(separator: "%", omittingEmptySubsequences: false)
        guard parts.count <= 2, parts.count == 1 || (!parts[1].isEmpty && parts[1].utf8.count <= 64 && parts[1].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == ".") }) else { return false }
        var ipv4 = in_addr(), ipv6 = in6_addr()
        return parts[0].withCString { p in (parts.count == 1 && inet_pton(AF_INET, p, &ipv4) == 1) || inet_pton(AF_INET6, p, &ipv6) == 1 }
    }
    static func validDomain(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 253, !validIP(value), value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }) else { return false }
        let name = value.hasSuffix(".") ? String(value.dropLast()) : value
        return name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0.utf8.count <= 63 && $0.first != "-" && $0.last != "-" }
    }
    static func inferred(_ value: String) -> Self {
        let value = host(value)
        return validIP(value) ? Self(ip: value, preferred: .ip) : Self(domain: value)
    }
    func reconciled(with value: String) -> Self {
        guard !value.isEmpty else { return self }
        var copy = self; let value = Self.host(value)
        if Self.validIP(value) { copy.ip = value; copy.preferred = .ip } else { copy.domain = value; copy.preferred = .domain }
        return copy
    }
    static func replacingURLHost(_ input: String, with host: String) -> String? {
        guard var parts = URLComponents(string: input), ["http", "https"].contains(parts.scheme?.lowercased() ?? ""), parts.user == nil, parts.password == nil,
              validIP(host) || validDomain(host) else { return nil }
        parts.host = host.contains(":") ? "[" + host + "]" : host
        return parts.url?.absoluteString
    }
}
