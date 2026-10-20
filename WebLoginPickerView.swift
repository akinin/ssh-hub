import SwiftUI

struct WebLoginPickerView: View {
    @StateObject private var session: ConnectionPageSession
    @StateObject private var picker: WebLoginPickerModel
    @Environment(\.dismiss) private var dismiss
    let apply: (WebLoginSelectors) -> Void
    init(entry: SSHAlias, config: URL, gateway: SSHAlias?, apply: @escaping (WebLoginSelectors) -> Void) {
        let session = ConnectionPageSession(entry: entry, config: config, restored: true, loginSetup: true)
        session.gateway = gateway
        _session = StateObject(wrappedValue: session)
        _picker = StateObject(wrappedValue: WebLoginPickerModel(web: session.web!, origin: URL(string: entry.website!)!))
        self.apply = apply
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Выбрать поля на странице", systemImage: "cursorarrow.click").font(.title2.bold())
            Text(picker.origin.absoluteString).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
            HStack(spacing: 10) {
                roleButton("Логин", role: "username", selected: !picker.selectors.username.isEmpty, color: .blue)
                roleButton("Пароль", role: "password", selected: !picker.selectors.password.isEmpty, color: .purple)
                roleButton("Кнопка входа", role: "submit", selected: !picker.selectors.submit.isEmpty, color: .green)
                Spacer()
                Button("Загрузить заново", systemImage: "arrow.clockwise") { session.stop(); session.start() }.disabled(picker.checking)
            }
            HStack { Toggle("Выбирать элементы", isOn: $picker.selecting).toggleStyle(.switch); Text("Выключи выбор, чтобы перейти к форме входа или открыть её на странице.").font(.caption).foregroundStyle(.secondary) }
            Text("Выбери элемент в строке выше, затем нажми на него на странице. В режиме выбора нажатия не отправляют форму. CAPTCHA, SSO и одноразовые коды проходят вручную.").font(.caption).foregroundStyle(.secondary)
            Divider()
            if session.entry.transport?.tunnel != nil { ConnectionTunnelStatus(tunnel: session.tunnel, cancel: session.stop) }
            if let error = picker.web.error { Text(error).foregroundStyle(.red).font(.caption) }
            WebPageContainer(view: picker.web.view).frame(maxWidth: .infinity, maxHeight: .infinity).overlay { if !picker.web.started { ProgressView("Загрузка страницы…") } }
            Divider()
            Label(picker.status, systemImage: picker.verified ? "checkmark.circle.fill" : "info.circle").font(.caption).foregroundStyle(picker.verified ? Color.green : .secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("webLoginPickerStatus")
            HStack {
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Проверить настройку") { Task { _ = await picker.check() } }.disabled(picker.selectors.validation != nil || picker.checking)
                Button("Использовать настройку") {
                    Task { if let choice = await picker.check() { apply(choice); dismiss() } }
                }.buttonStyle(.borderedProminent).disabled(!picker.verified || picker.checking).accessibilityIdentifier("webLoginPickerApply")
            }
        }.padding(20).frame(width: 920, height: 690)
            .task { picker.start(); session.start() }
            .onDisappear { picker.close(); session.stop() }
    }
    private func roleButton(_ title: String, role: String, selected: Bool, color: Color) -> some View {
        Button { picker.selectRole(role) } label: {
            Label(title, systemImage: selected ? "checkmark.circle.fill" : "circle").padding(.vertical, 3)
        }.tint(color).buttonStyle(.bordered).background(picker.role == role ? color.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .accessibilityIdentifier("webLoginPick-" + role)
    }
}
