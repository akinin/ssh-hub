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
            Text(entry == nil ? "Общие настройки действий для записей без индивидуального оформления. Выбери плитку или значок вверху; добавь разделители между группами." : "Настройки только этой записи. Можно вернуться к общему варианту. Перетаскивай строки или используй стрелки.").font(.caption).foregroundStyle(.secondary)
            RecordActionRows(draft: $draft)
            HStack {
                Button(entry == nil ? "По умолчанию" : "Использовать общие") {
                    draft = entry.map { RecordAction.layout(nil, global: inherited, entry: $0) } ?? RecordAction.catalog(nil)
                    resetSnapshot = draft
                }
                RecordActionAddMenu(draft: $draft)
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Сохранить") { onSave(resetSnapshot == draft ? nil : RecordAction.saving(draft, previous: stored ?? inherited)); dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 820)
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

private struct RecordActionRows: View {
    @Binding var draft: [RecordActionStyle]
    private func move(_ id: String, by delta: Int) { guard let index = draft.firstIndex(where: { $0.id == id }), draft.indices.contains(index + delta) else { return }; draft.swapAt(index, index + delta) }
    var body: some View {
        List {
            ForEach($draft) { $style in
                HStack(spacing: 8) {
                    Image(systemName: style.isDivider ? "minus" : RecordAction(rawValue: style.id)?.icon ?? "questionmark").foregroundStyle(style.tint).frame(width: 22)
                    Text(style.isDivider ? "Горизонтальный разделитель" : RecordAction(rawValue: style.id)?.title ?? style.id).frame(maxWidth: .infinity, alignment: .leading)
                    if !style.isDivider {
                        Picker("Размещение: " + (RecordAction(rawValue: style.id)?.title ?? ""), selection: Binding(get: { style.effectivePlacement }, set: { style.placement = $0 })) { ForEach(RecordActionPlacement.allCases) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 150)
                        Picker("Цвет", selection: $style.color) { ForEach(RecordActionStyle.colors, id: \.self) { Text(RecordActionStyle.colorTitle($0)).tag($0) } }.labelsHidden().frame(width: 100)
                    } else { Rectangle().fill(.quaternary).frame(maxWidth: 240).frame(height: 1) }
                    Button { move(style.id, by: -1) } label: { Image(systemName: "arrow.up") }.disabled(draft.first?.id == style.id).help("Выше")
                    Button { move(style.id, by: 1) } label: { Image(systemName: "arrow.down") }.disabled(draft.last?.id == style.id).help("Ниже")
                    if style.isDivider {
                        Button { let id = style.id; draft.removeAll { $0.id == id } } label: { Image(systemName: "trash") }.help("Убрать разделитель")
                    } else {
                        Toggle("Показать " + (RecordAction(rawValue: style.id)?.title ?? "действие"), isOn: Binding(get: { !style.hidden }, set: { style.hidden = !$0 })).labelsHidden().toggleStyle(.checkbox)
                    }
                }.padding(.vertical, 4).accessibilityElement(children: .contain)
                    .contextMenu {
                        if !style.isDivider {
                            Button("Разделитель после этого действия", systemImage: "minus") {
                                if let index = draft.firstIndex(where: { $0.id == style.id }), draft.count < 32 { draft.insert(.divider(), at: index + 1) }
                            }.disabled(draft.count >= 32)
                        }
                    }
            }.onMove { source, destination in draft.move(fromOffsets: source, toOffset: destination) }
        }.frame(minHeight: 330)
    }
}
private struct RecordActionAddMenu: View {
    @Binding var draft: [RecordActionStyle]
    var body: some View {
        Menu("Добавить") {
            Button("Горизонтальный разделитель", systemImage: "minus") { draft.append(.divider()) }.disabled(draft.count >= 32)
            if draft.contains(where: \.hidden) { Divider() }
            ForEach(draft.filter { $0.hidden && !$0.isDivider }) { style in
                Button(RecordAction(rawValue: style.id)?.title ?? style.id) { if let index = draft.firstIndex(where: { $0.id == style.id }) { draft[index].hidden = false } }
            }
        }
    }
}

private enum RecordTileScope: String, CaseIterable, Identifiable {
    case record, global
    var id: String { rawValue }
    var title: String { self == .record ? "Для этой записи" : "Для всех записей" }
}

struct RecordTileCustomizationView: View {
    let entry: SSHAlias
    let stored: [RecordActionStyle]?
    let inherited: [RecordActionStyle]?
    let onSave: ([RecordActionStyle]?) -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage(RecordActionDefaults.key) private var globalData = Data()
    @State private var initialGlobalData: Data
    @State private var scope = RecordTileScope.record
    @State private var recordDraft: [RecordActionStyle]
    @State private var globalDraft: [RecordActionStyle]
    @State private var recordReset: [RecordActionStyle]?
    @State private var globalReset: [RecordActionStyle]?
    @State private var recordTouched = false
    @State private var globalTouched = false
    @State private var error: String?
    init(entry: SSHAlias, stored: [RecordActionStyle]?, inherited: [RecordActionStyle]?, onSave: @escaping ([RecordActionStyle]?) -> Void) {
        self.entry = entry; self.stored = stored; self.inherited = inherited; self.onSave = onSave
        _initialGlobalData = State(initialValue: UserDefaults.standard.data(forKey: RecordActionDefaults.key) ?? Data())
        let record = RecordAction.layout(stored, global: inherited, entry: entry), global = RecordAction.catalog(inherited)
        _recordDraft = State(initialValue: record); _globalDraft = State(initialValue: global)
        _recordReset = State(initialValue: stored == nil ? record : nil); _globalReset = State(initialValue: inherited == nil ? global : nil)
    }
    private var draft: Binding<[RecordActionStyle]> {
        Binding(get: { scope == .record ? recordDraft : globalDraft }, set: { value in
            if scope == .record { recordDraft = value; recordTouched = true } else { globalDraft = value; globalTouched = true }
            error = nil
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Настройка действий", systemImage: "square.grid.2x2").font(.title2.bold())
            Picker("Область настройки", selection: $scope) {
                ForEach(RecordTileScope.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("recordTileScope")
            Text(scope == .record ? "Выбери размещение: плитка или значок вверху. Перетаскивай строки или используй стрелки; разделители делят плитки на группы." : "Общие настройки действий для записей без индивидуального оформления. Выбери плитку или значок вверху; добавь разделители между группами.").font(.caption).foregroundStyle(.secondary)
            RecordActionRows(draft: draft)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button(scope == .record ? "Использовать общие" : "По умолчанию") {
                    if scope == .record { recordDraft = RecordAction.layout(nil, global: globalDraft, entry: entry); recordReset = recordDraft; recordTouched = true }
                    else { globalDraft = RecordAction.catalog(nil); globalReset = globalDraft; globalTouched = true }
                }
                RecordActionAddMenu(draft: draft)
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Сохранить") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 820)
            .onChange(of: scope) { _, value in
                guard value == .record else { return }
                if (!recordTouched && stored == nil) || recordReset == recordDraft {
                    recordDraft = RecordAction.layout(nil, global: globalDraft, entry: entry); recordReset = recordDraft
                }
            }
    }
    private func save() {
        do {
            var encoded: Data?
            if globalTouched {
                guard globalData == initialGlobalData else { throw ConfigError.message("Общие настройки изменились. Открой настройку плиток заново.") }
                encoded = try RecordActionDefaults.encode(globalReset == globalDraft ? nil : RecordAction.saving(globalDraft, previous: inherited))
            }
            if let encoded { globalData = encoded }
            if recordTouched { onSave(recordReset == recordDraft ? nil : RecordAction.saving(recordDraft, previous: stored ?? inherited)) }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
