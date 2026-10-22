import SwiftUI

struct RecordBatchView: View {
    let target: RecordBatchTarget
    @EnvironmentObject private var store: AliasStore
    @Environment(\.dismiss) private var dismiss
    @State private var changeFolder = false
    @State private var folder = ""
    @State private var tagOperation: BatchTagOperation = .unchanged
    @State private var tags = ""
    @State private var changeCredentials = false
    @State private var choice: RecordCredentialChoice = .record
    @State private var review: RecordBatchPlan?
    @State private var error: String?
    private var eligible: Int { target.entries.filter(RecordCredentialChoice.supports).count }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Массовое редактирование · \(target.entries.count)", systemImage: "square.and.pencil").font(.title2.bold())
            if let review {
                Text("Изменится записей: \(review.changedCount). Проверь изменения перед сохранением.").foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(review.records) { record in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.title).font(.headline)
                                if review.groupsBefore[record.key] != review.groupsAfter[record.key] { Text("Папка: " + (review.groupsBefore[record.key] ?? "Без папки") + " → " + (review.groupsAfter[record.key] ?? "Без папки")) }
                                if review.searchBefore.tags[record.key] != review.searchAfter.tags[record.key] { Text("Теги: " + tagsText(review.searchBefore.tags[record.key]) + " → " + tagsText(review.searchAfter.tags[record.key])) }
                                if review.credentialsBefore.choice(for: record.key) != review.credentialsAfter.choice(for: record.key) { Text("Учётные данные: " + credentialTitle(review.credentialsBefore.choice(for: record.key), document: review.credentialsBefore) + " → " + credentialTitle(review.credentialsAfter.choice(for: record.key), document: review.credentialsAfter)) }
                                if changeCredentials && !record.supportsCredentials { Text("Этот тип записи не использует учётные данные подключения; привязка не меняется.").foregroundStyle(.secondary) }
                                if !review.changed(record.key) { Text("Без изменений").foregroundStyle(.secondary) }
                            }.font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            } else {
                Text("Поля без галочки сохранятся. Выбраны записи текущего профиля.").font(.callout).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HubDisclosureGroup("Выбранные записи") { ForEach(target.entries, id: \.id) { Text(store.title($0)).font(.caption).frame(maxWidth: .infinity, alignment: .leading) } }
                        Toggle("Переместить в папку", isOn: $changeFolder).toggleStyle(.checkbox)
                        if changeFolder { HStack { TextField("Без папки", text: $folder).textFieldStyle(.roundedBorder); Menu("Выбрать") { Button("Без папки") { folder = "" }; ForEach(store.groupNames, id: \.self) { path in Button(path) { folder = path } } } } }
                        Divider()
                        Picker("Теги", selection: $tagOperation) { ForEach(BatchTagOperation.allCases) { Text($0.title).tag($0) } }
                        if tagOperation != .unchanged {
                            TextField("Теги через запятую", text: $tags).textFieldStyle(.roundedBorder)
                            Text("Меняются только пользовательские теги. Автоматические метки материалов сохраняются.").font(.caption).foregroundStyle(.secondary)
                        }
                        Divider()
                        Toggle("Изменить источник учётных данных", isOn: $changeCredentials).toggleStyle(.checkbox).disabled(eligible == 0)
                        if changeCredentials {
                            Text("Применяется к \(eligible) из \(target.entries.count) записей. Пароли и файлы баз не изменяются.").font(.caption).foregroundStyle(.secondary)
                            RecordCredentialFields(vault: store.credentialVault(), workspace: store.kdbx!, choice: $choice, username: .constant(""))
                        }
                    }.padding(.vertical, 4)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                if review != nil { Button("Изменить поля") { review = nil; error = nil } }
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                if let review { Button("Сохранить изменения") { do { try store.applyBatch(review, target: target); dismiss() } catch { self.error = error.localizedDescription } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
                else { Button("Просмотреть изменения") { prepare() }.buttonStyle(.borderedProminent).disabled(!changeFolder && tagOperation == .unchanged && !changeCredentials) }
            }
        }.padding(22).frame(width: 720, height: 590)
    }
    private func prepare() {
        do {
            let parsed = tagOperation == .unchanged ? [] : try SearchMetadata.parseTags(tags)
            if [.add, .remove].contains(tagOperation), parsed.isEmpty { throw ConfigError.message("Укажи теги для добавления или удаления.") }
            review = try store.prepareBatch(target, patch: RecordBatchPatch(folder: changeFolder ? folder : nil, tagOperation: tagOperation, tags: parsed, credentials: changeCredentials ? choice : nil)); error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func tagsText(_ values: [String]?) -> String { values?.isEmpty == false ? values!.joined(separator: ", ") : "Нет" }
    private func credentialTitle(_ choice: RecordCredentialChoice, document: SharedCredentialDocument) -> String {
        switch choice {
        case .record: return "Из записи"
        case .preset(let id): return document.presets.first { $0.id == id }?.title ?? "Удалённый набор"
        case .keePass(let reference):
            guard let reference else { return "KeePass · запись не выбрана" }
            let database = document.kdbxDatabases?.first { $0.id == reference.databaseID }?.title ?? "База недоступна"
            let entry = store.kdbx?.runtime.catalog(reference.databaseID)?.first { $0.id == reference.entryID }?.title ?? reference.entryID.uuidString
            return "KeePass · " + database + " · " + entry
        }
    }
}
