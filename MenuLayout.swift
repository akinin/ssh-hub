import AppKit

// Stable command IDs only. Preferences never contain executable commands.
enum CustomMenuSurface: String, CaseIterable, Identifiable {
    case toolbar, tools, record
    var id: String { rawValue }
    var key: String { "customMenu." + rawValue + ".v1" }
    var title: String { switch self { case .toolbar: return "Верхняя панель"; case .tools: return "Меню «Инструменты»"; case .record: return "Меню записи по ПКМ" } }
    var icon: String { self == .toolbar ? "rectangle.topthird.inset.filled" : self == .tools ? "wrench.and.screwdriver" : "cursorarrow.click.2" }
    var defaults: [CustomMenuItem] {
        let ids: [String]
        switch self {
        case .toolbar: ids = ["reload", "palette", "tools", "maps", "settings", "assistant", "lock", "record"]
        case .tools: ids = ["commands", "trash", "divider:network", "network", "maps", "integrations", "monitoring", "maintenance", "divider:ssh", "generateKey", "keys", "history", "tunnels"]
        case .record: ids = ["website", "browser", "connect", "sftp", "external", "loginNotify", "dashboard", "divider:copy", "copyUsername", "copyPassword", "divider:materials", "documentation", "attachments", "edit", "appearance", "group", "favorite", "template", "duplicate", "copy", "export", "keePass", "divider:delete", "delete", "divider:create", "record", "folder"]
        }
        let optional = definitions.map(\.id).filter { !ids.contains($0) }
        return ids.map { CustomMenuItem(id: $0) } + optional.map { CustomMenuItem(id: $0, visible: false) }
    }
    var definitions: [CustomMenuDefinition] {
        if self == .record {
            return [
                .init("website", "Открыть внутри", "macwindow"), .init("browser", "Открыть в браузере", "arrow.up.forward.square"),
                .init("connect", "Подключиться", "play.circle"), .init("sftp", "Открыть SFTP", "folder"), .init("external", "Во внешнем терминале", "arrow.up.forward.square"),
                .init("loginNotify", "Уведомления о входе", "bell.badge"), .init("dashboard", "Панель управления", "rectangle.grid.2x2"),
                .init("copyUsername", "Копировать логин", "person.crop.rectangle"), .init("copyPassword", "Копировать пароль", "key"),
                .init("documentation", "Документация", "doc.richtext"), .init("attachments", "Вложения", "paperclip"),
                .init("licenses", "Лицензии", "key.horizontal"), .init("payments", "Оплаты", "creditcard"), .init("edit", "Редактировать", "pencil"), .init("appearance", "Оформление карточки", "photo"), .init("group", "Переместить в папку", "folder.badge.gearshape"),
                .init("favorite", "В избранное / убрать из избранного", "star"), .init("template", "Сохранить как шаблон", "square.stack"), .init("duplicate", "Дублировать", "plus.square.on.square"),
                .init("copy", "Копировать команду", "doc.on.doc"), .init("export", "Экспорт", "square.and.arrow.up"), .init("keePass", "Передать в KeePass", "key"),
                .init("delete", "Удалить", "trash"), .init("record", "Новая запись", "plus"), .init("folder", "Новая папка", "folder.badge.plus")
            ]
        }
        let global: [CustomMenuDefinition] = [
            .init("reload", "Обновить", "arrow.clockwise"), .init("palette", "Палитра действий", "command"), .init("tools", "Инструменты", "wrench.and.screwdriver"),
            .init("maps", "Сетевые карты", "point.3.connected.trianglepath.dotted"), .init("settings", "Настройки", "gearshape"), .init("assistant", "ИИ-помощник", "sparkles"),
            .init("lock", "Заблокировать", "lock"), .init("record", "Новая запись", "plus"), .init("folder", "Новая папка", "folder.badge.plus"),
            .init("commands", "Библиотека команд", "books.vertical"), .init("trash", "Корзина записей", "trash"), .init("network", "Сетевые инструменты", "wrench.and.screwdriver"),
            .init("integrations", "Интеграции", "square.stack.3d.up"), .init("monitoring", "Мониторинг сервера", "chart.xyaxis.line"), .init("maintenance", "Сценарии обслуживания", "list.bullet.clipboard"),
            .init("generateKey", "Создать SSH-ключ", "key.fill"), .init("keys", "SSH-ключи", "key.horizontal"), .init("history", "История подключений", "clock.arrow.circlepath"), .init("tunnels", "SSH-туннели", "arrow.left.arrow.right"),
            .init("credentials", "Общие учётные данные", "person.badge.key.fill"), .init("profiles", "Профили", "person.crop.rectangle.stack"), .init("templates", "Шаблоны записей", "square.stack"),
            .init("availability", "Статус доступности", "waveform.path.ecg"), .init("backup", "Резервное копирование", "externaldrive"), .init("import", "Импорт записей", "square.and.arrow.down"), .init("export", "Экспорт записей", "square.and.arrow.up")
        ]
        return self == .toolbar ? global : global.filter { !["tools", "settings", "assistant"].contains($0.id) }
    }
}
struct CustomMenuDefinition: Identifiable {
    var id: String; var title: String; var icon: String
    init(_ id: String, _ title: String, _ icon: String) { self.id = id; self.title = title; self.icon = icon }
}
struct CustomMenuItem: Codable, Equatable, Identifiable {
    var id: String
    var visible = true
    var isDivider: Bool { id.hasPrefix("divider:") }
}
enum CustomMenuLayout {
    static func items(_ data: Data, for surface: CustomMenuSurface) -> [CustomMenuItem] {
        guard !data.isEmpty, data.count <= 32_768, let decoded = try? JSONDecoder().decode([CustomMenuItem].self, from: data), decoded.count <= 64,
              Set(decoded.map(\.id)).count == decoded.count else { return surface.defaults }
        let allowed = Set(surface.definitions.map(\.id))
        var result = decoded.filter { allowed.contains($0.id) || surface != .toolbar && $0.isDivider && $0.id.utf8.count <= 80 }
        let present = Set(result.map(\.id))
        result += surface.defaults.filter { !$0.isDivider && !present.contains($0.id) }
        return result
    }
    static func visible(_ data: Data, for surface: CustomMenuSurface) -> [CustomMenuItem] { items(data, for: surface).filter(\.visible) }
    static func move(_ items: [CustomMenuItem], from: Int, to: Int) -> [CustomMenuItem] {
        guard items.indices.contains(from), (0...items.count).contains(to) else { return items }
        var copy = items; let value = copy.remove(at: from); copy.insert(value, at: to > from ? to - 1 : to); return copy
    }
    // Preserve dynamic titles, applicability and handlers built by the original
    // record menu. Configuration cannot enable an unsupported record action.
    static func apply(to menu: NSMenu, data: Data) {
        let available = Dictionary(menu.items.compactMap { item in (item.representedObject as? String).map { ($0, item) } }, uniquingKeysWith: { first, _ in first })
        menu.removeAllItems(); var separator = false
        for value in visible(data, for: .record) {
            if value.isDivider { separator = !menu.items.isEmpty; continue }
            guard let item = available[value.id] else { continue }
            if separator { menu.addItem(.separator()); separator = false }
            menu.addItem(item)
        }
    }
}
