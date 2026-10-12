import SwiftUI

@MainActor final class TemplateLibrary: ObservableObject {
    static let shared = TemplateLibrary()
    @Published private(set) var custom: [RecordTemplate] = []
    private var file: URL { DocumentationRepository().root.deletingLastPathComponent().appendingPathComponent("Templates.json") }
    var all: [RecordTemplate] { RecordTemplate.builtins + custom }
    init() {
        if let data = try? Data(contentsOf: file), data.count <= 8_000_000,
           let values = try? JSONDecoder().decode([RecordTemplate].self, from: data), values.count <= 100,
           Set(values.map(\.id)).count == values.count, values.allSatisfy({ $0.validation == nil }) { custom = values }
    }
    func save(_ value: RecordTemplate) throws {
        if let error = value.validation { throw ConfigError.message(error) }
        var values = custom.filter { $0.id != value.id }; values.append(value)
        try replace(values)
    }
    func remove(_ id: UUID) throws { try replace(custom.filter { $0.id != id }) }
    func replace(_ values: [RecordTemplate]) throws {
        guard values.count <= 100, Set(values.map(\.id)).count == values.count, values.allSatisfy({ $0.validation == nil }), !values.contains(where: { value in RecordTemplate.builtins.contains { $0.id == value.id } }) else { throw ConfigError.message("До 100 корректных собственных шаблонов.") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(values)
        guard data.count <= 8_000_000 else { throw ConfigError.message("Шаблоны занимают больше 8 МБ.") }
        try data.write(to: file, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        custom = values
    }
}
extension AliasStore {
    func create(from template: RecordTemplate) { recordEditor = RecordEditorTarget(blueprint: template) }
    func saveTemplate(from entry: SSHAlias) {
        do {
            let value = RecordTemplate(name: title(entry), user: entry.user, port: entry.port, identity: entry.value("IdentityFile") ?? "", jump: entry.value("ProxyJump") ?? "", group: group(entry), commands: try savedCommands.repository.load(entry.favoriteID), documentation: try DocumentationRepository().load(entry.favoriteID).text)
            try TemplateLibrary.shared.save(value); notice = "Шаблон «" + value.name + "» сохранён. Адрес и пароль не копируются."
        } catch { self.error = error.localizedDescription }
    }
}
struct TemplatesView: View {
    @EnvironmentObject var store: AliasStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var library = TemplateLibrary.shared
    @State private var editing: RecordTemplate?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Label("Шаблоны записей", systemImage: "square.stack").font(.title2).bold(); Spacer(); Button("Новый шаблон") { editing = RecordTemplate(name: "Новый шаблон") } }
            Text("Заготовки SSH с параметрами, командами и документацией. Пароли и приватные ключи в шаблонах не хранятся.").font(.callout).foregroundStyle(.secondary)
            List(library.all) { value in
                HStack {
                    VStack(alignment: .leading) { Text(value.name); Text(value.user + " · порт " + value.port + " · команд: \(value.commands.commands.count)").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Создать запись") { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { store.create(from: value) } }
                    Button(library.custom.contains(where: { $0.id == value.id }) ? "Изменить" : "Своя копия") {
                        var copy = value
                        if !library.custom.contains(where: { $0.id == value.id }) { copy.id = UUID(); copy.name += " · свой" }
                        editing = copy
                    }
                    if library.custom.contains(where: { $0.id == value.id }) { Button { do { try library.remove(value.id) } catch { self.error = error.localizedDescription } } label: { Image(systemName: "trash") }.help("Удалить шаблон") }
                }.padding(.vertical, 6)
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack { Spacer(); Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 720, height: 480).dismissOnOutsideClick().sheet(item: $editing) { TemplateEditor(value: $0) }
    }
}
struct TemplateEditor: View {
    @State var value: RecordTemplate
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Свой шаблон").font(.title2).bold()
            Form {
                TextField("Название", text: $value.name)
                TextField("Адрес по умолчанию", text: $value.host)
                TextField("Пользователь", text: $value.user)
                TextField("Порт", text: $value.port)
                TextField("Путь к ключу", text: $value.identity)
                TextField("ProxyJump", text: $value.jump)
                TextField("Папка", text: $value.group)
            }.textFieldStyle(.roundedBorder)
            Text("Документация (Markdown)").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $value.documentation).font(.system(.body, design: .monospaced)).frame(height: 90).border(Color.secondary.opacity(0.2))
            Toggle("Отправлять Enter для команд", isOn: $value.commands.sendEnter)
            ScrollView { ForEach($value.commands.commands) { $command in
                HStack { TextField("Кнопка", text: $command.title).frame(width: 120); TextField("Команда", text: $command.text); Button { value.commands.commands.removeAll { $0.id == command.id } } label: { Image(systemName: "minus.circle") } }
            } }.frame(height: 100)
            Button("Добавить команду") { value.commands.commands.append(SavedConsoleCommand()) }.disabled(value.commands.commands.count >= 50)
            if let error = error ?? value.validation { Text(error).font(.caption).foregroundStyle(.red) }
            HStack { Spacer(); Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction); Button("Сохранить") { do { try TemplateLibrary.shared.save(value); dismiss() } catch { self.error = error.localizedDescription } }.keyboardShortcut(.defaultAction).disabled(value.validation != nil) }
        }.padding(24).frame(width: 610, height: 670).dismissOnOutsideClick()
    }
}
