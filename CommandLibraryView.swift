import SwiftUI

@MainActor final class CommandLibrary: ObservableObject {
    static let shared = CommandLibrary()
    let repository = CommandLibraryRepository()
    @Published private(set) var custom: [SavedConsoleCommand] = []
    @Published private(set) var error: String?
    var all: [SavedConsoleCommand] { CommandCatalog.presets + custom }
    init() { do { custom = try repository.load() } catch { self.error = error.localizedDescription } }
    func replace(_ commands: [SavedConsoleCommand]) throws {
        try repository.write(commands); custom = commands; error = nil
    }
    func save(_ command: SavedConsoleCommand) throws {
        if let error { throw ConfigError.message(error) }
        var value = command; value.shortcut = 0
        if CommandCatalog.presets.contains(where: { $0.id == value.id }) { value.id = UUID() }
        try replace(custom.filter { $0.id != value.id } + [value])
    }
    func remove(_ id: UUID) throws {
        if let error { throw ConfigError.message(error) }
        try replace(custom.filter { $0.id != id })
    }
}
struct CommandLibraryView: View {
    var assignmentLimit = 50
    var assign: (([SavedConsoleCommand]) -> Void)? = nil
    @ObservedObject private var library = CommandLibrary.shared
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var group = ""
    @State private var customOnly = false
    @State private var selection = Set<UUID>()
    @State private var editing: SavedConsoleCommand?
    @State private var deleting: SavedConsoleCommand?
    @State private var error: String?
    private var visible: [SavedConsoleCommand] {
        (customOnly ? library.custom : library.all).filter { CommandCatalog.matches($0, query: query, group: group) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Библиотека команд", systemImage: "books.vertical").font(.title2).bold()
                Spacer()
                Button("Новая команда", systemImage: "plus") { editing = SavedConsoleCommand() }
            }
            Text("Встроенных: \(CommandCatalog.presets.count) · своих: \(library.custom.count). Команды не назначаются и не запускаются автоматически. Нужные утилиты и права указаны в описании.").font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Поиск по названию, описанию или тексту", text: $query).textFieldStyle(.roundedBorder)
                Picker("Группа", selection: $group) {
                    Text("Все группы").tag("")
                    ForEach(Array(Set(library.all.map(\.group).filter { !$0.isEmpty })).sorted(), id: \.self) { Text($0).tag($0) }
                }.labelsHidden().frame(width: 175)
                Toggle("Только свои", isOn: $customOnly)
            }
            List(visible) { command in
                HStack(alignment: .top, spacing: 12) {
                    if assign != nil {
                        Toggle(isOn: Binding(get: { selection.contains(command.id) }, set: { enabled in
                            if enabled { selection.insert(command.id) } else { selection.remove(command.id) }
                        })) { EmptyView() }.labelsHidden()
                            .disabled(!selection.contains(command.id) && selection.count >= assignmentLimit)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { Text(command.title).fontWeight(.medium); Text(command.group).font(.caption).foregroundStyle(.secondary) }
                        Text(command.description).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Text(command.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(2)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Menu {
                        if library.custom.contains(where: { $0.id == command.id }) {
                            Button("Изменить") { editing = command }
                            Button("Удалить", role: .destructive) { deleting = command }
                        }
                        Button("Своя копия") { editing = CommandCatalog.copies([command]).first }
                    } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24)
                }.padding(.vertical, 7)
            }.overlay { if visible.isEmpty { Text("Команды не найдены").foregroundStyle(.secondary) } }
            if let error = error ?? library.error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                if assign != nil {
                    Text("В запись добавляются копии. Последующие изменения библиотеки их не меняют.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Добавить выбранные (\(selection.count))") {
                        assign?(CommandCatalog.copies(library.all.filter { selection.contains($0.id) })); dismiss()
                    }.disabled(selection.isEmpty || selection.count > assignmentLimit).buttonStyle(.borderedProminent)
                } else { Spacer() }
                Button("Готово") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(20).frame(width: 840, height: 610).dismissOnOutsideClick()
            .sheet(item: $editing) { LibraryCommandEditor(command: $0) }
            .confirmationDialog("Удалить команду из библиотеки?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("Удалить", role: .destructive) {
                    if let command = deleting { do { try library.remove(command.id); selection.remove(command.id) } catch { self.error = error.localizedDescription } }; deleting = nil
                }
                Button("Отмена", role: .cancel) { deleting = nil }
            } message: { Text("Уже назначенные записям копии сохранятся.") }
    }
}
struct LibraryCommandEditor: View {
    @State var command: SavedConsoleCommand
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Команда библиотеки").font(.title2).bold()
            TextField("Название", text: $command.title)
            TextField("Группа", text: $command.group)
            Text("Описание").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $command.description).frame(height: 95).border(Color.secondary.opacity(0.2)).accessibilityLabel("Описание команды")
            TextField("Команда в одну строку", text: $command.text).font(.system(.body, design: .monospaced))
            Text("Переменные: {{host}}, {{user}}, {{port}}, {{name}}. Назначение записи и отправка Enter настраиваются отдельно.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer(); Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Сохранить") { do { try CommandLibrary.shared.save(command); dismiss() } catch { self.error = error.localizedDescription } }
                    .buttonStyle(.borderedProminent).disabled(SavedCommandSet(commands: [command]).validation != nil)
            }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 600).dismissOnOutsideClick()
    }
}
