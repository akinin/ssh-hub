import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImageIO

struct RecordRowBadgesEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var items = RecordRowBadgeSettings.defaults
    @State private var expected = Data()
    @State private var error: String?
    var body: some View {
        VStack(spacing: 0) {
            HubSheetHeader(title: "Значки после названия записи", subtitle: "Общий набор и порядок для списка записей", icon: "tag").padding(20)
            Divider()
            Text("Перетаскивай строки за название или ручку. Флажок включает значок.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 12)
            MenuCustomizationRows(draft: Binding(get: { items.map { CustomMenuItem(id: $0.id, visible: $0.visible) } }, set: { items = $0.map { RecordRowBadgeItem(id: $0.id, visible: $0.visible) } }), definitions: RecordRowBadge.allCases.map { CustomMenuDefinition($0.id, $0.title, $0.icon) }).frame(maxHeight: .infinity).padding(.horizontal, 12)
            Text("Значки появляются только при наличии соответствующих данных. Скрытие значка не отключает проверки доступности, сертификатов или напоминания.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 12)
            if let error { Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 20) }
            Divider()
            HStack {
                Button("По умолчанию") { items = RecordRowBadgeSettings.decode(ApplicationDefaults.values[RecordRowBadgeSettings.key] as? Data) }
                Spacer()
                Button("Отмена", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Сохранить") {
                    guard (UserDefaults.standard.data(forKey: RecordRowBadgeSettings.key) ?? Data()) == expected else { error = "Настройки изменились. Открой окно заново."; return }
                    if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: RecordRowBadgeSettings.key); dismiss() }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }.padding(16)
        }.frame(width: 570, height: 640).onAppear { expected = UserDefaults.standard.data(forKey: RecordRowBadgeSettings.key) ?? Data(); items = RecordRowBadgeSettings.decode(expected) }
    }
}


struct ConnectionAppearanceFields: View {
    @Binding var appearance: ConnectionAppearance
    let fallback: String
    var website = ""
    @State private var choosingWebsite = false
    @State private var error: String?
    var body: some View {
        HStack(spacing: 16) {
            VStack(spacing: 6) {
                Button { chooseLogo() } label: {
                    ConnectionIcon(appearance: appearance, size: 54).padding(8)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(alignment: .bottomTrailing) { Image(systemName: "pencil.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .blue) }
                }.buttonStyle(.plain).help("Выбрать логотип").accessibilityLabel("Выбрать логотип")
                if appearance.logo != nil {
                    Button("Убрать логотип") { appearance.logo = nil }.buttonStyle(.link).font(.caption)
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("Название записи").font(.caption).foregroundStyle(.secondary)
                TextField("Название", text: $appearance.name, prompt: Text(fallback.isEmpty ? "Например, Домашний сервер" : fallback))
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("connectionDisplayName")
                Text("Название отображается в дереве. Нажми на логотип, чтобы заменить его.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Иконка с сайта…", systemImage: "globe") { choosingWebsite = true }.controlSize(.small)
                if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            }
        }.sheet(isPresented: $choosingWebsite) {
            WebsiteIconView(address: website) { data in appearance.logo = data; error = nil }
        }
    }
    private func chooseLogo() {
        let panel = NSOpenPanel(); panel.title = "Логотип подключения"
        panel.allowedContentTypes = [.png, .jpeg, .webP]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { appearance.logo = try ConnectionLogo.load(url); error = nil }
        catch { self.error = error.localizedDescription }
    }
}

struct ConnectionAppearanceView: View {
    @EnvironmentObject var store: AliasStore
    @Environment(\.dismiss) private var dismiss
    let entry: SSHAlias
    @State private var appearance = ConnectionAppearance()
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Оформление карточки").font(.title2).bold()
            Text(entry.secondaryTitle).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            ConnectionAppearanceFields(appearance: $appearance, fallback: entry.name, website: entry.website ?? "")
            RecordPinnedFieldsEditor(appearance: $appearance)
            if let validation = appearance.validation { Text(validation).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Отмена", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Сохранить") { store.setAppearance(appearance, for: entry); dismiss() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(appearance.validation != nil)
            }
        }.padding(24).frame(width: 490).dismissOnOutsideClick().onAppear { appearance = store.appearance(entry) }
    }
}


struct WebsiteIconView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var address: String
    @State private var task: Task<Void, Never>?
    @State private var error: String?
    @State private var certificateFailure: WebsiteIconCertificateFailure?
    @State private var acceptedOrigins: Set<WebsiteIconOrigin> = []
    let apply: (Data) -> Void
    init(address: String, apply: @escaping (Data) -> Void) { _address = State(initialValue: address); self.apply = apply }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Иконка с сайта", systemImage: "globe").font(.title3).bold()
            TextField("http:// или https://", text: $address).textFieldStyle(.roundedBorder).accessibilityIdentifier("websiteIconURL").disabled(task != nil)
            Text("Загрузится иконка страницы или favicon. Пароли и cookies браузера не используются. Изменение логотипа применяется после сохранения.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            if certificateFailure != nil {
                Button("Всё равно получить") { load(acceptCertificate: true) }.disabled(task != nil)
                    .accessibilityIdentifier("websiteIconAcceptCertificate")
            }
            HStack {
                if task != nil { ProgressView().controlSize(.small); Text("Загрузка…").font(.caption) }
                Spacer()
                Button("Отмена", role: .cancel) { task?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Получить иконку") { load() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(task != nil || (try? WebsiteIcon.address(address)) == nil)
            }
        }.padding(20).frame(width: 440).onDisappear { task?.cancel() }
            .onChange(of: address) { _, _ in error = nil; certificateFailure = nil; acceptedOrigins = [] }
    }
    private func load(acceptCertificate: Bool = false) {
        guard task == nil else { return }
        if acceptCertificate, let certificateFailure { acceptedOrigins.insert(certificateFailure.origin) }
        else { acceptedOrigins = [] }
        let target = address, accepted = acceptedOrigins
        error = nil; certificateFailure = nil
        task = Task { @MainActor in
            do { let data = try await WebsiteIcon.load(target, acceptingCertificatesFor: accepted); try Task.checkCancellation(); apply(data); task = nil; dismiss() }
            catch { if !Task.isCancelled { self.error = error.localizedDescription; certificateFailure = error as? WebsiteIconCertificateFailure }; task = nil }
        }
    }
}

struct RecordPinnedFieldsEditor: View {
    @Binding var appearance: ConnectionAppearance
    private var selected: [String] { appearance.pinnedFields ?? RecordPinnedField.defaults.map(\.rawValue) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text("Поля рядом с названием").font(.headline); Spacer(); Button("По умолчанию") { appearance.pinnedFields = nil }.controlSize(.small) }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                ForEach(RecordPinnedField.allCases) { field in
                    Toggle(field.title, isOn: Binding(get: { selected.contains(field.rawValue) }, set: { enabled in
                        var fields = selected; fields.removeAll { $0 == field.rawValue }; if enabled { fields.append(field.rawValue) }; appearance.pinnedFields = fields
                    })).toggleStyle(.checkbox)
                }
            }
            Text("Настройка только этой записи. Пустые значения не показываются; пароли и содержимое ключей здесь не выводятся.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
