import Foundation

struct RecordTemplate: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var host = ""
    var user = "root"
    var port = "22"
    var identity = ""
    var jump = ""
    var group = ""
    var commands = SavedCommandSet()
    var documentation = ""
    var validation: String? {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ConnectionAppearance(name: name).validation == nil,
              AliasTransfer.validGroup(group), documentation.utf8.count <= DocumentationRepository.maximumBytes else { return "Проверь название, папку и размер документации." }
        var draft = AliasDraft(); draft.name = "template"; draft.host = host.isEmpty ? "example.com" : host
        draft.user = user; draft.port = port; draft.identity = identity; draft.jump = jump
        return draft.validation(existing: []) ?? commands.validation
    }
    static let builtins: [Self] = [
        Self(id: UUID(uuidString: "A25A1CD1-0911-4200-B01B-000000000001")!, name: "Proxmox", commands: SavedCommandSet(commands: [SavedConsoleCommand(title: "Версия", text: "pveversion", group: "Сведения"), SavedConsoleCommand(title: "Виртуальные машины", text: "qm list", group: "Сведения"), SavedConsoleCommand(title: "Контейнеры", text: "pct list", group: "Сведения")]), documentation: "## Proxmox\n\nАдрес панели: https://АДРЕС:8006\n\nУкажи адрес и проверь параметры SSH перед подключением."),
        Self(id: UUID(uuidString: "A25A1CD1-0911-4200-B01B-000000000002")!, name: "UniFi", commands: SavedCommandSet(commands: [SavedConsoleCommand(title: "Система", text: "uname -a", group: "Сведения"), SavedConsoleCommand(title: "Адреса", text: "ip addr", group: "Сеть")]), documentation: "## UniFi\n\nУкажи учётные данные SSH, настроенные для своего устройства. Команды зависят от модели и версии прошивки."),
        Self(id: UUID(uuidString: "A25A1CD1-0911-4200-B01B-000000000003")!, name: "Wiren Board", commands: SavedCommandSet(commands: [SavedConsoleCommand(title: "Версия", text: "cat /etc/wb-release", group: "Сведения"), SavedConsoleCommand(title: "Службы", text: "systemctl --failed", group: "Диагностика")]), documentation: "## Wiren Board\n\nУкажи адрес контроллера и свои параметры SSH. Запиши здесь подключённые устройства и особенности объекта.")
    ]
}
