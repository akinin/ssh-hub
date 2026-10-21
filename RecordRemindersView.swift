import SwiftUI
import AppKit

enum RecordReminderColors {
    static func native(_ value: String) -> NSColor { switch value { case "green": return .systemGreen; case "orange": return .systemOrange; case "red": return .systemRed; case "purple": return .systemPurple; case "pink": return .systemPink; case "gray": return .secondaryLabelColor; default: return .systemBlue } }
}
enum RecordSelectionDefaults {
    static let key = "sidebarSelectionColor.v1"
    static let colors = ["gray", "system", "blue", "green", "orange", "red", "purple", "pink"]
    static func tint(_ value: String?) -> NSColor? { let value = colors.contains(value ?? "") ? value! : "gray"; return value == "system" ? nil : value == "gray" ? .darkGray : RecordReminderColors.native(value) }
}
final class RecordReminderRowView: NSTableRowView {
    var tint: NSColor?
    var selectionTint: NSColor?
    private var selectedTint: NSColor? { if let tint, style.tintSelection != false { return tint }; return selectionTint }
    // Source-list tables reassign this property on every selection change.
    // Keep custom rows out of AppKit's blue vibrancy selection in that setter.
    override var selectionHighlightStyle: NSTableView.SelectionHighlightStyle {
        get { selectedTint != nil ? .none : super.selectionHighlightStyle }
        set { super.selectionHighlightStyle = selectedTint != nil ? .none : newValue }
    }
    override var isSelected: Bool { didSet {
        needsDisplay = true
        for cell in subviews.compactMap({ $0 as? NSTableCellView }) { cell.backgroundStyle = interiorBackgroundStyle }
    } }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { isSelected && selectedTint != nil ? .emphasized : super.interiorBackgroundStyle }
    var style = RecordReminderAppearance()
    private var path: NSBezierPath { NSBezierPath(roundedRect: bounds.insetBy(dx: 12, dy: 1), xRadius: 6, yRadius: 6) }
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if isSelected, selectedTint != nil { drawSelection(in: dirtyRect); return }
        if let tint, !isSelected {
            if style.background { tint.withAlphaComponent(style.opacity).setFill(); path.fill() }
            stroke(tint)
        }
    }
    override func drawSelection(in dirtyRect: NSRect) {
        guard let selectedTint else { super.drawSelection(in: dirtyRect); return }
        selectedTint.withAlphaComponent((style.selectionOpacity ?? 0.80) * (isEmphasized ? 1 : 0.7)).setFill(); path.fill()
        if let tint, style.tintSelection != false { stroke(tint) }
    }
    private func stroke(_ tint: NSColor) { if style.outline { tint.withAlphaComponent(0.85).setStroke(); let border = path; border.lineWidth = style.lineWidth; border.stroke() } }
}

final class RecordReminderCellView: NSTableCellView {
    var reminderBadge: NSStackView? { didSet { updateReminder() } }
    var reminderTint: NSColor? { didSet { updateReminder() } }
    override var backgroundStyle: NSView.BackgroundStyle { didSet { updateReminder() } }
    private func updateReminder() {
        let color: NSColor = backgroundStyle == .emphasized ? .white : reminderTint ?? .secondaryLabelColor
        for view in reminderBadge?.arrangedSubviews ?? [] { (view as? NSTextField)?.textColor = color; (view as? NSImageView)?.contentTintColor = color }
    }
}

struct ReminderAppearanceFields: View {
    @Binding var value: RecordReminderAppearance
    private let iconTitles = ["Календарь с предупреждением", "Календарь", "Часы", "Колокольчик", "Банковская карта", "Ключ", "Предупреждение"]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 20) { Toggle("Значок", isOn: $value.showIcon); Toggle("Счётчик", isOn: $value.showCount); Toggle("Рамка", isOn: $value.outline); Toggle("Фон", isOn: $value.background) }.toggleStyle(.checkbox)
            Picker("Значок", selection: $value.icon) { ForEach(Array(RecordReminderAppearance.icons.enumerated()), id: \.element) { index, icon in Label(iconTitles[index], systemImage: icon).tag(icon) } }.disabled(!value.showIcon)
            HStack {
                Picker("Скоро", selection: $value.warningColor) { ForEach(RecordActionStyle.colors, id: \.self) { Text(RecordActionStyle.colorTitle($0)).tag($0) } }
                Picker("Просрочено", selection: $value.overdueColor) { ForEach(RecordActionStyle.colors, id: \.self) { Text(RecordActionStyle.colorTitle($0)).tag($0) } }
            }
            HStack { Text("Подсветка").frame(width: 100, alignment: .leading); Slider(value: $value.opacity, in: 0.03...0.30, step: 0.01); Text(value.opacity, format: .percent.precision(.fractionLength(0))).monospacedDigit().frame(width: 45) }.disabled(!value.background)
            HStack { Text("Толщина рамки"); Spacer(); Picker("Толщина рамки", selection: $value.lineWidth) { Text("1 пт").tag(1.0); Text("2 пт").tag(2.0); Text("3 пт").tag(3.0) }.labelsHidden().frame(width: 100) }.disabled(!value.outline)
            Toggle("Выделять выбранную запись цветом срока", isOn: Binding(get: { value.tintSelection != false }, set: { value.tintSelection = $0 }))
            HStack { Text("Яркость выделения"); Slider(value: Binding(get: { value.selectionOpacity ?? 0.80 }, set: { value.selectionOpacity = $0 }), in: 0.35...1.0, step: 0.05) }.disabled(value.tintSelection == false)
            HStack { preview("Срок близко", color: value.warningColor); preview("Просрочено", color: value.overdueColor) }
            Text("Предупреждения видны в боковой панели, пока срок не изменён или не удалён. Точка доступности настраивается отдельно.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func preview(_ title: String, color: String) -> some View {
        let tint = Color(nsColor: RecordReminderColors.native(color))
        return HStack(spacing: 6) { Text(title); Spacer(minLength: 4); if value.showIcon { Image(systemName: value.icon) }; if value.showCount { Text("1").monospacedDigit() } }
            .font(.callout).foregroundStyle(tint).padding(9)
            .background(value.background ? tint.opacity(value.opacity) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(value.outline ? tint : .clear, lineWidth: value.lineWidth) }
    }
}
struct GlobalReminderAppearanceSettings: View {
    @AppStorage(RecordReminderDefaults.key) private var data = Data()
    private var value: Binding<RecordReminderAppearance> { Binding(get: { RecordReminderDefaults.decode(data) }, set: { if $0.valid, let encoded = try? JSONEncoder().encode($0) { data = encoded } }) }
    var body: some View {
        Section("Индикаторы лицензий и оплат") {
            ReminderAppearanceFields(value: value)
            Button("По умолчанию") { data = Data() }
            Text("Применяется сразу ко всем записям без индивидуального оформления. Даты и сроки предупреждений задаются в «Лицензии и оплаты» у записи.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct RecordReminderFields: View {
    @Binding var reminders: [RecordReminder]
    @Binding var useGlobal: Bool
    @Binding var style: RecordReminderAppearance
    var body: some View {
                VStack(alignment: .leading, spacing: 14) {
                    if reminders.isEmpty { Text("Добавь лицензию или оплату, укажи дату и за сколько дней показать предупреждение рядом с записью.").foregroundStyle(.secondary) }
                    ForEach($reminders) { $reminder in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack { Picker("Тип", selection: $reminder.kind) { ForEach(RecordReminderKind.allCases) { Text($0.title).tag($0) } }.frame(width: 200); Spacer(); Button { reminders.removeAll { $0.id == reminder.id } } label: { Image(systemName: "trash") }.help("Убрать этот срок из черновика") }
                                TextField("Название (необязательно)", text: $reminder.title).textFieldStyle(.roundedBorder)
                                DatePicker(reminder.kind == .license ? "Окончание" : "Следующая оплата", selection: Binding(get: { reminder.date() ?? Date() }, set: { reminder.deadline = RecordReminder.dayString($0) }), in: Self.dateRange, displayedComponents: .date)
                                HStack { Text("Предупреждать за"); TextField("Дни", value: $reminder.noticeDays, format: .number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width: 65); Text("дней (0–3650)").foregroundStyle(.secondary); Spacer() }
                                if let notice = reminder.notice() { Text(notice.text).font(.caption).foregroundStyle(notice.level > 1 ? .red : .orange) }
                            }.padding(8)
                        }
                    }
                    HStack { Button("Добавить лицензию", systemImage: "key") { reminders.append(RecordReminder()) }; Button("Добавить оплату", systemImage: "creditcard") { var value = RecordReminder(); value.kind = .payment; reminders.append(value) } }.disabled(reminders.count >= 20)
                    DisclosureGroup("Оформление индикатора") {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle("Использовать общие настройки", isOn: $useGlobal)
                            if useGlobal { Text("Настройки → Внешний вид → Индикаторы лицензий и оплат. Здесь можно включить индивидуальный вариант.").font(.caption).foregroundStyle(.secondary) }
                            else { ReminderAppearanceFields(value: $style) }
                        }.padding(.top, 10)
                    }.disclosureGroupStyle(FullRowDisclosureStyle())
                }
    }
    private static var dateRange: ClosedRange<Date> { let calendar = RecordReminder.calendar(); return calendar.date(from: DateComponents(year: 1970, month: 1, day: 1))!...calendar.date(from: DateComponents(year: 2100, month: 12, day: 31))! }
}
struct RecordReminderDraftFields: View {
    @Binding var appearance: ConnectionAppearance
    @AppStorage(RecordReminderDefaults.key) private var globalData = Data()
    var body: some View {
        RecordReminderFields(reminders: Binding(get: { appearance.reminders ?? [] }, set: { appearance.reminders = $0.isEmpty ? nil : $0 }),
            useGlobal: Binding(get: { appearance.reminderAppearance == nil }, set: { appearance.reminderAppearance = $0 ? nil : RecordReminderDefaults.decode(globalData) }),
            style: Binding(get: { appearance.reminderAppearance ?? RecordReminderDefaults.decode(globalData) }, set: { appearance.reminderAppearance = $0 }))
    }
}

struct RecordRemindersView: View {
    let entry: SSHAlias
    @EnvironmentObject var store: AliasStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage(RecordReminderDefaults.key) private var globalData = Data()
    @State private var reminders: [RecordReminder] = []
    @State private var initialReminders: [RecordReminder] = []
    @State private var style = RecordReminderAppearance()
    @State private var initialStyle: RecordReminderAppearance?
    @State private var useGlobal = true
    @State private var error: String?
    private var valid: Bool { reminders.count <= 20 && reminders.allSatisfy(\.valid) && (useGlobal || style.valid) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HubSheetHeader(title: "Лицензии и оплаты", subtitle: store.title(entry), icon: "calendar.badge.clock")
            ScrollView {
                RecordReminderFields(reminders: $reminders, useGlobal: $useGlobal, style: $style).padding(.trailing, 8)
            }
            if !valid { Text("Проверь даты и дни предупреждения (0–3650). Название — до 80 символов без переводов строк.").font(.caption).foregroundStyle(.red) }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack { Text("Изменения применятся после сохранения.").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction); Button("Сохранить") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!valid) }
        }.padding(22).frame(width: 660, height: 640).onAppear {
            let value = store.appearance(entry); reminders = value.reminders ?? []; initialReminders = reminders; initialStyle = value.reminderAppearance; useGlobal = initialStyle == nil; style = initialStyle ?? RecordReminderDefaults.decode(globalData)
        }
    }
    private func save() {
        guard !AppAccess.shared.locked, !store.endingWorkspace, valid, let current = store.aliases.first(where: { $0.favoriteID == entry.favoriteID }) else { error = "Запись недоступна. Закрой форму и обнови список."; return }
        var appearance = store.appearance(current)
        guard (appearance.reminders ?? []) == initialReminders, appearance.reminderAppearance == initialStyle else { error = "Сроки уже изменены. Открой форму заново."; return }
        appearance.reminders = reminders.isEmpty ? nil : reminders.map { var item = $0; item.title = item.title.trimmingCharacters(in: .whitespacesAndNewlines); return item }
        appearance.reminderAppearance = useGlobal ? nil : style
        guard appearance.validation == nil else { error = appearance.validation; return }
        store.setAppearance(appearance, for: current); dismiss()
    }
}
