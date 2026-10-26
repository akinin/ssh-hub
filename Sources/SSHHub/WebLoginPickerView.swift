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
            HubSheetHeader(title: "Настройка автовхода", subtitle: picker.origin.absoluteString, icon: "cursorarrow.click")
            HStack(spacing: 10) {
                if !picker.twoStep || !picker.passwordStep { roleButton("Логин", role: "username", selected: !picker.selectors.username.isEmpty, color: .blue) }
                if picker.twoStep && !picker.passwordStep { roleButton("Далее", role: "next", selected: !(picker.selectors.next ?? "").isEmpty, color: .green) }
                if !picker.twoStep || picker.passwordStep { roleButton("Пароль", role: "password", selected: !picker.selectors.password.isEmpty, color: .purple)
                roleButton("Кнопка входа", role: "submit", selected: !picker.selectors.submit.isEmpty, color: .green) }
                Spacer()
                Button { picker.setTwoStep(picker.twoStep); session.stop(); session.start() } label: { Image(systemName: "arrow.clockwise").frame(width: 24, height: 24) }.help("Загрузить исходную страницу заново").accessibilityLabel("Загрузить заново").disabled(picker.checking)
            }
            HStack {
                Toggle("Логин и пароль на разных шагах", isOn: Binding(get: { picker.twoStep }, set: { picker.setTwoStep($0) })).toggleStyle(.switch).disabled(picker.checking)
                Spacer()
                if picker.selecting { Button("Перейти по странице") { picker.selecting = false }.disabled(picker.checking) }
            }
            Text(picker.selecting ? "Нажми «Логин», «Пароль» или кнопку входа сверху, затем укажи элемент на странице." : (picker.twoStep && picker.passwordStep ? "Введи логин и нажми «Далее» на странице. Затем нажми «Пароль» сверху и укажи поле." : "Перейди к форме входа. Затем нажми тип поля сверху, чтобы выбрать его на странице."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            if session.entry.transport?.tunnel != nil { ConnectionTunnelStatus(tunnel: session.tunnel, cancel: session.stop) }
            if let error = picker.web.error { Text(error).foregroundStyle(.red).font(.caption) }
            WebPageContainer(view: picker.web.view).frame(maxWidth: .infinity, maxHeight: .infinity).overlay { if !picker.web.started { ProgressView("Загрузка страницы…") } }
            Divider()
            HubNotice(text: picker.status, icon: picker.verified ? "checkmark.circle.fill" : "info.circle", tint: picker.verified ? .green : .secondary).accessibilityElement(children: .combine).accessibilityIdentifier("webLoginPickerStatus")
            HStack {
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Проверить настройку") { Task { _ = await picker.check() } }.disabled(!picker.currentComplete || picker.checking)
                if picker.twoStep && !picker.passwordStep { Button("Перейти к шагу пароля") { picker.advance() }.disabled(!picker.verified || picker.checking) }
                if !picker.twoStep || picker.passwordStep { Button("Использовать настройку") {
                    Task { if let choice = await picker.check() { apply(choice); dismiss() } }
                }.buttonStyle(.borderedProminent).disabled(!picker.canApply || picker.checking).accessibilityIdentifier("webLoginPickerApply") }
            }
        }.padding(20).frame(minWidth: 680, idealWidth: 900, maxWidth: 1100, minHeight: 620, idealHeight: 680, maxHeight: 900)
            .task { picker.start(); session.start() }
            .onDisappear { picker.close(); session.stop() }
    }
    private func roleButton(_ title: String, role: String, selected: Bool, color: Color) -> some View {
        Button { picker.selectRole(role) } label: {
            Label(title, systemImage: selected ? "checkmark.circle.fill" : "circle").padding(.vertical, 3)
        }.tint(color).buttonStyle(.bordered).background(picker.role == role ? color.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(picker.role == role ? color.opacity(0.55) : .clear, lineWidth: 1) }
            .disabled(picker.checking).accessibilityValue(picker.role == role ? "Выбирается" : selected ? "Выбрано" : "Не выбрано").accessibilityAddTraits(picker.role == role ? .isSelected : [])
            .accessibilityIdentifier("webLoginPick-" + role)
    }
}
