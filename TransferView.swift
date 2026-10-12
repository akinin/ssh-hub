import SwiftUI

struct ImportReview: Identifiable {
    let id = UUID()
    let records: [TransferAlias]
    let expectedData: Data
}

struct ImportReviewView: View {
    let review: ImportReview
    @EnvironmentObject var store: AliasStore
    @Environment(\.dismiss) private var dismiss
    @State private var records: [TransferAlias]
    @State private var selection: Set<Int>
    @State private var error: String?
    init(review: ImportReview, existing: [SSHAlias]) {
        self.review = review
        _records = State(initialValue: review.records)
        var names = existing, selected = Set<Int>()
        for (index, value) in review.records.enumerated() where value.validation(existing: names) == nil {
            selected.insert(index); if !value.isStandalone { names.append(SSHAlias(name: value.name, source: URL(fileURLWithPath: "/import"), line: index)) }
        }
        _selection = State(initialValue: selected)
    }
    private var validation: String? {
        if selection.isEmpty { return "Выбери хотя бы одну запись." }
        var names = store.aliases
        for index in selection.sorted() {
            if let message = records[index].validation(existing: names) { return "\(records[index].name): \(message)" }
            if !records[index].isStandalone { names.append(SSHAlias(name: records[index].name, source: store.config.url, line: index)) }
        }
        return nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Импорт подключений", systemImage: "square.and.arrow.down").font(.title2).bold()
            Text("Выбрано: \(selection.count) из \(records.count). Существующие записи не перезаписываются; конфликтующее имя можно изменить.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(records.indices, id: \.self) { index in
                        HStack(alignment: .top, spacing: 12) {
                            Toggle("Импортировать \(records[index].name)", isOn: Binding(get: { selection.contains(index) }, set: {
                                if $0 { selection.insert(index) } else { selection.remove(index) }
                            })).labelsHidden()
                            VStack(alignment: .leading, spacing: 6) {
                                if records[index].isStandalone {
                                    TextField("Название записи", text: Binding(get: { records[index].displayName ?? "" }, set: { records[index].displayName = $0 })).textFieldStyle(.roundedBorder)
                                } else { TextField("Алиас", text: $records[index].name).textFieldStyle(.roundedBorder).accessibilityIdentifier("importName\(index)") }
                                Text("\(records[index].user)@\(records[index].host):\(records[index].port)").font(.caption).foregroundStyle(.secondary)
                                if !records[index].isStandalone, store.rawAliases.contains(where: { $0.name.caseInsensitiveCompare(records[index].name) == .orderedSame }) {
                                    Text("Это имя уже существует").font(.caption).foregroundStyle(.orange)
                                }
                                if !records[index].group.isEmpty { Text("Группа: \(records[index].group)").font(.caption).foregroundStyle(.secondary) }
                            }
                        }.padding(12).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }.frame(height: 300)
            if let text = error ?? validation { Text(text).font(.caption).foregroundStyle(error == nil ? Color.secondary : Color.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Text("Резервная копия и отмена после импорта").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Отмена", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Импортировать") {
                    do { try store.importRecords(selection.sorted().map { records[$0] }, expectedData: review.expectedData); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).disabled(validation != nil)
            }
        }.padding(24).frame(width: 620).dismissOnOutsideClick()
    }
}
