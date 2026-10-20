import SwiftUI

extension RecordActionStyle {
    var tint: Color { switch color { case "green": return .green; case "orange": return .orange; case "red": return .red; case "purple": return .purple; case "pink": return .pink; case "gray": return .gray; default: return .blue } }
    static func colorTitle(_ value: String) -> String { ["blue": "Синий", "green": "Зелёный", "orange": "Оранжевый", "red": "Красный", "purple": "Фиолетовый", "pink": "Розовый", "gray": "Серый"][value] ?? value }
}

struct RecordActionsEditor: View {
    let entry: SSHAlias?
    let inherited: [RecordActionStyle]?
    let stored: [RecordActionStyle]?
    let onSave: ([RecordActionStyle]?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: [RecordActionStyle]
    @State private var resetSnapshot: [RecordActionStyle]?
    init(entry: SSHAlias?, stored: [RecordActionStyle]?, inherited: [RecordActionStyle]? = nil, onSave: @escaping ([RecordActionStyle]?) -> Void) {
        self.entry = entry; self.stored = stored; self.inherited = inherited; self.onSave = onSave
        let initial = entry.map { RecordAction.layout(stored, global: inherited, entry: $0) } ?? RecordAction.catalog(stored)
        _draft = State(initialValue: initial)
        _resetSnapshot = State(initialValue: stored == nil ? initial : nil)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(entry == nil ? "Плитки всех записей" : "Плитки записи", systemImage: "square.grid.2x2").font(.title2.bold())
            Text(entry == nil ? "Общий порядок, цвета и набор плиток для записей без индивидуальных настроек. Для каждого типа показываются только подходящие действия." : "Настройки только этой записи. Можно вернуться к общему варианту. Перетаскивай строки или используй стрелки.").font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(draft.indices, id: \.self) { index in
                    if let action = RecordAction(rawValue: draft[index].id) {
                        HStack(spacing: 10) {
                            Image(systemName: action.icon).foregroundStyle(draft[index].tint).frame(width: 22)
                            Text(action.title).frame(maxWidth: .infinity, alignment: .leading)
                            Picker("Цвет: " + action.title, selection: $draft[index].color) { ForEach(RecordActionStyle.colors, id: \.self) { Text(RecordActionStyle.colorTitle($0)).tag($0) } }.labelsHidden().frame(width: 110)
                            Button { draft.swapAt(index, index - 1) } label: { Image(systemName: "arrow.up") }.disabled(index == 0).help("Выше")
                            Button { draft.swapAt(index, index + 1) } label: { Image(systemName: "arrow.down") }.disabled(index == draft.count - 1).help("Ниже")
                            Toggle("Показать " + action.title, isOn: Binding(get: { !draft[index].hidden }, set: { draft[index].hidden = !$0 })).labelsHidden().toggleStyle(.checkbox)
                        }.padding(.vertical, 4).accessibilityElement(children: .contain)
                    }
                }.onMove { source, destination in draft.move(fromOffsets: source, toOffset: destination) }
            }.frame(minHeight: 330)
            HStack {
                Button(entry == nil ? "По умолчанию" : "Использовать общие") {
                    draft = entry.map { RecordAction.layout(nil, global: inherited, entry: $0) } ?? RecordAction.catalog(nil)
                    resetSnapshot = draft
                }
                Menu("Добавить") {
                    ForEach(draft.indices.filter { draft[$0].hidden }, id: \.self) { index in Button(RecordAction(rawValue: draft[index].id)?.title ?? draft[index].id) { draft[index].hidden = false } }
                }.disabled(!draft.contains(where: \.hidden))
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Сохранить") { onSave(resetSnapshot == draft ? nil : RecordAction.saving(draft, previous: stored ?? inherited)); dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 660)
    }
}

struct GlobalRecordActionsEditor: View {
    @AppStorage(RecordActionDefaults.key) private var data = Data()
    var body: some View {
        RecordActionsEditor(entry: nil, stored: RecordActionDefaults.decode(data)) { styles in
            if let encoded = try? RecordActionDefaults.encode(styles) { data = encoded }
        }
    }
}
