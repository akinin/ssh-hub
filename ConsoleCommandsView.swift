import SwiftUI
import AppKit

@MainActor final class SavedCommandsWorkspace: ObservableObject {
    let repository = SavedCommandsRepository()
    @Published private(set) var records: [String: SavedCommandSet] = [:]
    @Published var error: String?
    func load(_ key: String) {
        guard records[key] == nil else { return }
        do { records[key] = try repository.load(key) } catch { self.error = error.localizedDescription }
    }
    func save(_ value: SavedCommandSet, key: String) throws { try repository.write(value, key: key); records[key] = value }
    func copy(from: String, to: String) {
        guard from != to else { return }
        load(from)
        guard let value = records[from] else { return }
        do { try save(value, key: to) } catch { self.error = error.localizedDescription }
    }
}
struct ConsoleCommandBar: View {
    let entry: SSHAlias
    @ObservedObject var session: ConsoleSession
    @ObservedObject var workspace: SavedCommandsWorkspace
    @EnvironmentObject var store: AliasStore
    @State private var editing = false
    @State private var group = ""
    private var value: SavedCommandSet { workspace.records[entry.favoriteID] ?? SavedCommandSet() }
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal").foregroundStyle(.secondary).help("Команды записи")
            if !value.commands.allSatisfy({ $0.group.isEmpty }) {
                Menu(group.isEmpty ? "Все группы" : group) {
                    Button("Все группы") { group = "" }
                    ForEach(Array(Set(value.commands.map(\.group).filter { !$0.isEmpty })).sorted(), id: \.self) { name in Button(name) { group = name } }
                }.fixedSize()
            }
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    if value.commands.isEmpty { Text("Свои команды").foregroundStyle(.secondary) }
                    ForEach(value.commands.filter { group.isEmpty || $0.group == group }) { command in
                        Button(command.title) {
                            session.execute(command)
                        }.disabled(session.finished || session.awaitingConnection).help(command.text + (value.sendEnter ? " · с Enter" : " · без Enter"))
                            .contextMenu { Button("Копировать команду") { store.copy(command.text) }; Button("Настроить команды…") { editing = true } }
                    }
                }.font(.system(size: 11)).padding(.vertical, 3)
            }.scrollIndicators(.hidden)
            Button { editing = true } label: { Image(systemName: "slider.horizontal.3") }.help("Настроить команды записи").accessibilityLabel("Настроить команды записи")
        }.controlSize(.small).padding(.horizontal, 12).frame(height: 34).background(.bar)
            .onAppear { workspace.load(entry.favoriteID) }
            .sheet(isPresented: $editing) { ConsoleCommandsEditor(key: entry.favoriteID, title: store.title(entry), workspace: workspace) }
    }
}
struct ConsoleCommandsSettingsLink: View {
    let entry: SSHAlias
    @EnvironmentObject var store: AliasStore
    @State private var editing = false
    var body: some View {
        Button("Команды консоли…", systemImage: "terminal") { editing = true }
            .sheet(isPresented: $editing) { ConsoleCommandsEditor(key: entry.favoriteID, title: store.title(entry), workspace: store.savedCommands) }
    }
}
struct ConsoleCommandsEditor: View {
    let key: String
    let title: String
    @ObservedObject var workspace: SavedCommandsWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var draft = SavedCommandSet()
    @State private var ready = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Команды · " + title).font(.title3).bold().lineLimit(1)
            Toggle("Сразу отправлять Enter", isOn: $draft.sendEnter).toggleStyle(.switch)
            Text(draft.sendEnter ? "Кнопка команды отправляет текст и Enter в активный сеанс этой записи." : "Кнопка вставляет команду в консоль. Для выполнения нажми Enter.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Переменные: {{host}}, {{user}}, {{port}}, {{name}}. Значения экранируются для shell; используй их без своих кавычек. Клавиши действуют в выбранной консоли.").font(.caption).foregroundStyle(.secondary)
            Divider()
            ScrollView {
                VStack(spacing: 10) {
                    ForEach($draft.commands) { $command in
                        HStack(spacing: 8) {
                            VStack(spacing: 10) {
                                TextField("Название кнопки", text: $command.title).accessibilityIdentifier("commandTitle")
                                HStack {
                                    TextField("Группа", text: $command.group)
                                    Picker("Клавиша", selection: $command.shortcut) {
                                        Text("Нет").tag(0)
                                        ForEach(1...9, id: \.self) { Text("⌘⌥\($0)").tag($0) }
                                    }.frame(width: 160)
                                }
                                TextField("Команда", text: $command.text).font(.system(.body, design: .monospaced)).accessibilityIdentifier("commandText")
                            }.textFieldStyle(.roundedBorder)
                            VStack {
                                Button { move(command.id, by: -1) } label: { Image(systemName: "arrow.up") }.help("Выше")
                                Button { move(command.id, by: 1) } label: { Image(systemName: "arrow.down") }.help("Ниже")
                            }.buttonStyle(.plain)
                            Button { draft.commands.removeAll { $0.id == command.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).help("Удалить команду")
                        }
                    }
                }.padding(6)
            }.frame(maxHeight: .infinity)
            Button("Добавить команду", systemImage: "plus") { draft.commands.append(SavedConsoleCommand()) }.disabled(draft.commands.count >= 50 || !ready)
            if let error = error ?? draft.validation { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack { Spacer(); Button("Отмена", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Сохранить") {
                    do { try workspace.save(draft, key: key); dismiss() } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!ready || draft.validation != nil)
            }
        }.padding(20).frame(width: 640, height: 540)
            .onAppear { workspace.load(key); if let value = workspace.records[key] { draft = value; ready = true } else { error = workspace.error } }
    }
    private func move(_ id: UUID, by offset: Int) {
        guard let index = draft.commands.firstIndex(where: { $0.id == id }), draft.commands.indices.contains(index + offset) else { return }
        draft.commands.swapAt(index, index + offset)
    }

}
