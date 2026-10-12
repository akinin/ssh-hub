import SwiftUI
import AppKit
import WebKit
import CryptoKit
import Security

@MainActor enum ConnectionPassword {
    static func read(_ entry: SSHAlias, config: URL) throws -> String {
        if let saved = try SSHPasswordStore.password(for: entry, config: entry.credentialConfig(fallback: config)) { return saved }
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
    init(entry: SSHAlias, config: URL, restored: Bool) {
        self.entry = entry
        web = entry.recordKind == .web ? WebPageModel(entry: entry) : nil
        files = entry.recordKind?.isFiles == true ? RemoteFilesModel(entry: entry, config: config) : nil
        desktop = entry.recordKind?.isDesktop == true ? DesktopSession(entry: entry, config: config) : nil
        if !restored { start() }
    }
    func start() { if web?.started == false { web?.start() }; if files?.connected == false { files?.connect() }; desktop?.start() }
    func stop() { web?.stop(); files?.stop(); desktop?.stop() }
}
struct ConnectionPageView: View {
    @ObservedObject var session: ConnectionPageSession
    var body: some View {
        if let model = session.web { WebPageView(model: model) }
        else if let model = session.files { RemoteFilesView(model: model) }
        else if let model = session.desktop { DesktopPageView(session: model) }
    }
}
@MainActor final class WebPageModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    let entry: SSHAlias
    let view: WKWebView
    @Published var started = false
    @Published var address = ""
    @Published var error: String?
    init(entry: SSHAlias) {
        self.entry = entry
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        view = WKWebView(frame: .zero, configuration: configuration)
        super.init(); view.navigationDelegate = self; view.uiDelegate = self; view.allowsBackForwardNavigationGestures = true
        address = entry.website ?? ""
    }
    func start() {
        guard let url = URL(string: address), LocalConnectionRecord.validWebsite(address) else { error = "Укажи полный HTTP/HTTPS-адрес без учётных данных в URL."; return }
        started = true; error = nil; view.load(URLRequest(url: url))
    }
    func stop() { view.stopLoading() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { address = webView.url?.absoluteString ?? address; objectWillChange.send() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { self.error = error.localizedDescription }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, ["http", "https", "about"].contains(url.scheme?.lowercased() ?? "") else { decisionHandler(.cancel); return }
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request); decisionHandler(.cancel) } else { decisionHandler(.allow) }
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert(); alert.messageText = "Сообщение веб-панели"; alert.informativeText = String(message.prefix(5000)); alert.runModal(); completionHandler()
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert(); alert.messageText = "Веб-панель"; alert.informativeText = String(message.prefix(5000)); alert.addButton(withTitle: "Продолжить"); alert.addButton(withTitle: "Отмена"); completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert(); alert.messageText = "Веб-панель"; alert.informativeText = String(prompt.prefix(5000))
        let field = NSTextField(frame: NSRect(x: 0,y: 0,width: 340,height: 26)); field.stringValue = defaultText ?? ""; alert.accessoryView = field; alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Продолжить"); alert.addButton(withTitle: "Отмена"); completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = parameters.allowsMultipleSelection; panel.canChooseDirectories = parameters.allowsDirectories; completionHandler(panel.runModal() == .OK ? panel.urls : nil)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) { decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download) }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = (suggestedFilename as NSString).lastPathComponent; completionHandler(panel.runModal() == .OK ? panel.url : nil)
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) { self.error = error.localizedDescription }
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            guard let trust = challenge.protectionSpace.serverTrust else { completionHandler(.cancelAuthenticationChallenge,nil); return }
            if SecTrustEvaluateWithError(trust,nil) { completionHandler(.performDefaultHandling,nil); return }
            guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let certificate = chain.first else { completionHandler(.cancelAuthenticationChallenge,nil); return }
            let fingerprint = SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02X",$0) }.joined(separator: ":")
            let host = challenge.protectionSpace.host + ":" + String(challenge.protectionSpace.port)
            let key = "webCertificate.v1." + SHA256.hash(data: Data((entry.favoriteID + host).utf8)).map { String(format: "%02x",$0) }.joined()
            if UserDefaults.standard.string(forKey: key) == fingerprint { completionHandler(.useCredential,URLCredential(trust: trust)); return }
            let alert = NSAlert(); alert.messageText = "Проверка сертификата веб-панели"
            alert.informativeText = (UserDefaults.standard.string(forKey: key) == nil ? "Сертификат не подтверждён системой. Сверь SHA-256 с администратором.\n\n" : "Сертификат изменился. Сверь новый SHA-256 перед входом.\n\n") + host + "\n" + fingerprint
            alert.addButton(withTitle: "Доверять этому сертификату"); alert.addButton(withTitle: "Отмена")
            if alert.runModal() == .alertFirstButtonReturn { UserDefaults.standard.set(fingerprint,forKey: key); completionHandler(.useCredential,URLCredential(trust: trust)) }
            else { completionHandler(.cancelAuthenticationChallenge,nil) }
            return
        }
        guard challenge.previousFailureCount == 0 else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        let alert = NSAlert(); alert.messageText = "Вход на " + challenge.protectionSpace.host
        let stack = NSStackView(); stack.orientation = .vertical
        let user = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 26)); user.placeholderString = "Пользователь"
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 26)); password.placeholderString = "Пароль"
        stack.addArrangedSubview(user); stack.addArrangedSubview(password); alert.accessoryView = stack
        alert.addButton(withTitle: "Войти"); alert.addButton(withTitle: "Отмена")
        if alert.runModal() == .alertFirstButtonReturn { completionHandler(.useCredential, URLCredential(user: user.stringValue, password: password.stringValue, persistence: .forSession)) }
        else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
}
struct WebPageView: View {
    @ObservedObject var model: WebPageModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { model.view.goBack() } label: { Image(systemName: "chevron.left") }.disabled(!model.view.canGoBack).help("Назад")
                Button { model.view.goForward() } label: { Image(systemName: "chevron.right") }.disabled(!model.view.canGoForward).help("Вперёд")
                TextField("Адрес", text: $model.address).textFieldStyle(.roundedBorder).onSubmit { model.start() }
                Button { if model.started { model.view.reload() } else { model.start() } } label: { Image(systemName: "arrow.clockwise") }.help("Обновить")
                Button { if let url = model.view.url ?? URL(string: model.address) { NSWorkspace.shared.open(url) } } label: { Image(systemName: "arrow.up.forward.square") }.help("Открыть в браузере")
            }.padding(8).controlSize(.small)
            Divider()
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).padding(8) }
            if model.started { WebPageContainer(view: model.view) }
            else { VStack(spacing: 12) { Text("Встроенная веб-панель").font(.headline); Text(model.address).foregroundStyle(.secondary); Button("Открыть") { model.start() } }.frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
    }
}
struct WebPageContainer: NSViewRepresentable {
    let view: WKWebView
    func makeNSView(context: Context) -> NSView { let box = NSView(); view.removeFromSuperview(); box.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false; NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: box.leadingAnchor), view.trailingAnchor.constraint(equalTo: box.trailingAnchor), view.topAnchor.constraint(equalTo: box.topAnchor), view.bottomAnchor.constraint(equalTo: box.bottomAnchor)]); return box }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
