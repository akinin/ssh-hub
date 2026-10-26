import SwiftUI
import AppKit
import WebKit
import CryptoKit
import Security
import Network

@MainActor enum ConnectionPassword {
    static func read(_ entry: SSHAlias, config: URL) throws -> String {
        if !entry.isQuickConnection, let saved = try SSHPasswordStore.password(for: entry, config: entry.credentialConfig(fallback: config)) { return saved }
        let alert = NSAlert(); alert.messageText = "Вход · " + (entry.recordKind?.title ?? "") + " · " + entry.name
        alert.informativeText = entry.user + " · " + (entry.recordKind == .webdav ? entry.website ?? "" : entry.host + ":" + entry.port) + ". Пароль используется только для этого сеанса."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 26)); alert.accessoryView = field; alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Подключиться"); alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { throw CancellationError() }
        return field.stringValue
    }
}
@MainActor final class ConnectionPageSession: ObservableObject {
    let entry: SSHAlias
    let web: WebPageModel?
    let files: RemoteFilesModel?
    let desktop: DesktopSession?
    let tunnel = ConnectionTunnel()
    private let config: URL
    private var connecting: Task<Void, Never>?
    private var generation = UUID()
    var gateway: SSHAlias?
    func matches(_ value: SSHAlias) -> Bool {
        entry.recordKind == value.recordKind && entry.website == value.website && entry.transport == value.transport && entry.options.map { $0.key + "=" + $0.value } == value.options.map { $0.key + "=" + $0.value }
    }
    init(entry: SSHAlias, config: URL, restored: Bool, loginSetup: Bool = false) {
        self.entry = entry; self.config = config
        web = entry.recordKind?.isWeb == true ? WebPageModel(entry: entry, config: config, setupOnly: loginSetup) : nil
        files = entry.recordKind?.isFiles == true ? RemoteFilesModel(entry: entry, config: config) : nil
        desktop = entry.recordKind?.isDesktop == true ? DesktopSession(entry: entry, config: config) : nil
        desktop?.onRequestStart = { [weak self] in self?.start() }
        desktop?.onRequestStop = { [weak self] in self?.stop() }
        web?.onRequestStart = { [weak self] in self?.start() }
        tunnel.onFailure = { [weak self] error in self?.desktop?.stop(); self?.web?.stop(); self?.web?.started = false; self?.web?.error = error; self?.desktop?.status = error }
        if !restored && entry.transport?.tunnel == nil { start() }
    }
    func start() {
        guard connecting == nil, desktop?.connected != true, desktop?.starting != true, web?.started != true else { return }
        guard entry.transport?.tunnel != nil else { launch(); return }
        guard let gateway else { web?.error = "SSH-запись туннеля не найдена. Выбери её в настройках записи."; desktop?.status = "SSH-запись туннеля не найдена. Выбери её в настройках записи."; return }
        let token = UUID(); generation = token
        connecting = Task { [weak self] in
            guard let self else { return }; defer { if self.generation == token { self.connecting = nil } }
            do {
                let port = try await self.tunnel.start(entry: self.entry, gateway: gateway, config: self.config)
                guard !Task.isCancelled, self.generation == token else { return }
                self.desktop?.tunnelPort = port; self.web?.configureProxy(port); self.launch()
            } catch is CancellationError {} catch { self.web?.error = error.localizedDescription; self.desktop?.status = error.localizedDescription }
        }
    }
    private func launch() { if web?.started == false { web?.start() }; if files?.connected == false { files?.connect() }; desktop?.start() }
    func stop() { generation = UUID(); connecting?.cancel(); connecting = nil; web?.stop(); files?.stop(); desktop?.stop(); tunnel.stop() }
}
struct ConnectionPageView: View {
    @ObservedObject var session: ConnectionPageSession
    var body: some View {
        VStack(spacing: 0) {
        if session.entry.transport?.tunnel != nil { ConnectionTunnelStatus(tunnel: session.tunnel, cancel: session.stop) }
        if let model = session.web { WebPageView(model: model) }
        else if let model = session.files { RemoteFilesView(model: model) }
        else if let model = session.desktop { DesktopPageView(session: model) }
        }
    }
}
struct ConnectionTunnelStatus: View {
    @ObservedObject var tunnel: ConnectionTunnel
    let cancel: () -> Void
    var body: some View { HStack { Label(tunnel.status.isEmpty ? "Через SSH-туннель" : tunnel.status, systemImage: "lock.shield").font(.caption).lineLimit(2); Spacer(); if !tunnel.status.isEmpty { Button("Остановить туннель", action: cancel).controlSize(.small) } }.padding(6) }
}
struct WebPageView: View {
    @ObservedObject var model: WebPageModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { model.view.goBack() } label: { Image(systemName: "chevron.left") }.disabled(!model.view.canGoBack).help("Назад")
                Button { model.view.goForward() } label: { Image(systemName: "chevron.right") }.disabled(!model.view.canGoForward).help("Вперёд")
                TextField("Адрес", text: $model.address).textFieldStyle(.roundedBorder).onSubmit { if model.started { model.start() } else { model.requestStart() } }
                Button { if model.started { model.view.reload() } else { model.requestStart() } } label: { Image(systemName: "arrow.clockwise") }.help("Обновить")
                Button { model.login() } label: { Image(systemName: "person.badge.key") }.disabled(!model.canLogin).help("Войти с сохранённым логином и паролем").accessibilityLabel("Войти с сохранённым паролем").accessibilityIdentifier("webLogin")
                Button { if let url = model.view.url ?? URL(string: model.address) { NSWorkspace.shared.open(url) } } label: { Image(systemName: "arrow.up.forward.square") }.disabled(model.entry.transport?.wireGuardID != nil).help(model.entry.transport?.wireGuardID == nil ? "Открыть в браузере" : "WireGuard записи работает во встроенной веб-панели")
            }.padding(8).controlSize(.small)
            Divider()
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).padding(8) }
            if let status = model.loginStatus { Text(status).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 4) }
            if model.started { WebPageContainer(view: model.view).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { VStack(spacing: 12) { Text("Встроенная веб-панель").font(.headline); Text(model.address).foregroundStyle(.secondary); Button("Открыть") { model.requestStart() } }.frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
    }
}
struct WebPageContainer: NSViewRepresentable {
    let view: WKWebView
    func makeNSView(context: Context) -> NSView { let box = NSView(); view.removeFromSuperview(); box.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false; NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: box.leadingAnchor), view.trailingAnchor.constraint(equalTo: box.trailingAnchor), view.topAnchor.constraint(equalTo: box.topAnchor), view.bottomAnchor.constraint(equalTo: box.bottomAnchor)]); return box }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
