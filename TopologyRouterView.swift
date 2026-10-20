import SwiftUI

struct TopologyRouterView: View {
    @ObservedObject var model: TopologyModel
    @State var settings: TopologyRouterSettings
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var error: String?
    @State private var saved = false
    private var hasPassword: Bool { TopologyRouterKeyStore.hasPassword(profileID:model.credentialProfileID,settings:settings) }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text(settings.provider.title + " · источник карты").font(.title2).bold()
            TextField("Название: например MikroTik · WAN2",text:$settings.name)
            TextField("Адрес: https://router.example",text:$settings.baseURL)
            TextField("Пользователь API",text:$settings.username)
            PasswordEntryView(prompt: hasPassword ? "Новый пароль (сохранённый скрыт)" : "Пароль API", text: $password)
            Picker("Добавить данные к записи",selection:Binding(get:{settings.recordKey ?? ""},set:{settings.recordKey = $0.isEmpty ? nil : $0})) {
                Text("Отдельное устройство на карте").tag("")
                ForEach(model.entries) { entry in Text(entry.name).tag(entry.favoriteID) }
            }
            Text("UniFi, MikroTik и Keenetic можно использовать вместе. Привязка дополняет существующее устройство. WAN1/WAN2 и связи с другими шлюзами настраиваются в карте.").font(.caption).foregroundStyle(.secondary)
            Text(settings.provider == .mikrotik ? "RouterOS REST API через HTTPS (www-ssl). Сбор читает интерфейсы, адреса, маршруты, DNS и соседей; конфигурацию устройства не меняет." : "Локальный Keenetic RCI через HTTPS с поддерживаемой авторизацией. Сбор читает сетевые сведения; конфигурацию устройства не меняет.").font(.caption).foregroundStyle(.secondary)
            Text("Нужен доверенный сертификат сервера. Пароль хранится только в Связке ключей и привязан к адресу, пользователю и профилю; в архив не включается.").font(.caption).foregroundStyle(.secondary)
            if hasPassword { Label("Пароль сохранён",systemImage:"key.fill").font(.caption).foregroundStyle(.secondary) }
            if let error = error ?? model.error { Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled) }
            if saved { Text("Настройки сохранены").font(.caption).foregroundStyle(.green) }
            Spacer(minLength:0)
            HStack {
                Button("Готово") { password = ""; dismiss() }.keyboardShortcut(.cancelAction)
                if model.document.routers.contains(where:{$0.id == settings.id}) { Button("Убрать источник") { model.removeRouter(settings); dismiss() } }
                Spacer(); Button("Сохранить") { save() }.disabled(model.busy)
                Button("Получить карту") { if save() { model.collectRouter(settings); if model.busy { dismiss() } } }.disabled(model.busy || (password.isEmpty && !hasPassword)).buttonStyle(.borderedProminent)
            }
        }.padding(22).frame(width:630,height:480).textFieldStyle(.roundedBorder).dismissOnOutsideClick(enabled:!model.busy)
    }
    @discardableResult private func save()->Bool {
        do { try model.configureRouter(settings,password:password); password = ""; saved = true; error = nil; return true }
        catch { self.error = error.localizedDescription; return false }
    }
}
