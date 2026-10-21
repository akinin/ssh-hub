import AppKit
import WebKit
import CryptoKit
import Security
import Network

@MainActor final class WebPageModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    let entry: SSHAlias
    let view: WKWebView
    private let setupOnly: Bool
    var onNavigation: (() -> Void)?
    private let config: URL
    private let credentials: (SSHAlias, URL) throws -> (String, String)?
    private var loginTask: Task<Void, Never>?
    private var generation = UUID()
    private var formAttempted = false
    private var usernameAttempted = false
    private var stepUsername: String?
    private var stepDeadline: Date?
    private var httpAttempted = false
    private var manualLogin = false
    @Published var loginStatus: String?
    var canLogin: Bool { guard !setupOnly, started, !entry.isQuickConnection, let origin = WebLoginOrigin(URL(string: entry.website ?? "")) else { return false }; return WebLoginOrigin(view.url) == origin || (view.url == nil && error != nil && WebLoginOrigin(URL(string: address)) == origin) }
    private static func savedCredentials(_ entry: SSHAlias, _ config: URL) throws -> (String, String)? {
        let prepared = try SSHPasswordStore.preparedEntry(for: entry, config: config)
        guard !prepared.isQuickConnection, !prepared.user.isEmpty,
              let password = try SSHPasswordStore.password(for: prepared, config: prepared.credentialConfig(fallback: config)), !password.isEmpty else { return nil }
        return (prepared.user, password)
    }
    var onRequestStart: (() -> Void)?
    func requestStart() { if let onRequestStart { onRequestStart() } else { start() } }
    func configureProxy(_ port: Int) { var proxy = ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!)); proxy.allowFailover = false; view.configuration.websiteDataStore.proxyConfigurations = [proxy] }
    @Published var started = false
    @Published var address = ""
    @Published var error: String?
    convenience init(entry: SSHAlias, config: URL, setupOnly: Bool = false) { self.init(entry: entry, config: config, setupOnly: setupOnly, credentials: Self.savedCredentials) }
    #if WEB_LOGIN_TEST
    convenience init(entry: SSHAlias, config: URL, setupOnly: Bool = false, credentialReader: @escaping (SSHAlias, URL) throws -> (String, String)?) { self.init(entry: entry, config: config, setupOnly: setupOnly, credentials: credentialReader) }
    #endif
    private init(entry: SSHAlias, config: URL, setupOnly: Bool = false, credentials: @escaping (SSHAlias, URL) throws -> (String, String)?) {
        self.entry = entry; self.config = config; self.setupOnly = setupOnly; self.credentials = credentials
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        if setupOnly { configuration.userContentController.addUserScript(WKUserScript(source: WebLoginPickerScript.bootstrap, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient)) }
        view = WKWebView(frame: .zero, configuration: configuration)
        super.init(); view.navigationDelegate = self; view.uiDelegate = self; view.allowsBackForwardNavigationGestures = true
        address = entry.website ?? ""
    }
    func start() {
        guard let url = URL(string: address), LocalConnectionRecord.validWebsite(address) else { error = "Укажи полный HTTP/HTTPS-адрес без учётных данных в URL."; return }
        if entry.transport?.wireGuardID != nil {
            do { let prepared = try SSHPasswordStore.preparedNetworkConnection(for: entry, config: config); guard let port = prepared.networkProxyPort else { throw ConfigError.message("Маршрут WireGuard недоступен.") }; configureProxy(port) }
            catch { self.error = error.localizedDescription; return }
        }
        cancelLogin(); usernameAttempted = false; stepUsername = nil; stepDeadline = nil; formAttempted = false; httpAttempted = false; manualLogin = false; loginStatus = nil
        started = true; error = nil; view.load(URLRequest(url: url))
    }
    func stop() { started = false; stepUsername = nil; stepDeadline = nil; cancelLogin(); loginStatus = nil; manualLogin = false; view.stopLoading(); view.loadHTMLString("", baseURL: nil) }
    private func cancelLogin() { generation = UUID(); loginTask?.cancel(); loginTask = nil }
    func login() {
        guard !setupOnly, canLogin else { return }
        cancelLogin(); usernameAttempted = false; stepUsername = nil; stepDeadline = nil; formAttempted = false; httpAttempted = false; manualLogin = true
        if view.isLoading { return }
        // A rejected HTTP challenge needs a fresh load. Forms can be retried in place.
        if error != nil, let url = URL(string: entry.website ?? "") { error = nil; view.load(URLRequest(url: url)) } else { fillLogin() }
    }
    private func fillLogin() {
        guard !setupOnly, started, !entry.isQuickConnection, entry.transport?.webAutoLogin == true || manualLogin,
              !formAttempted, loginTask == nil, let destination = URL(string: entry.website ?? ""),
              let origin = WebLoginOrigin(destination), origin == WebLoginOrigin(view.url) else { return }
        let token = generation
        loginTask = Task { [weak self] in
            guard let self else { return }
            defer { if generation == token { loginTask = nil } }
            do {
                // Some panels create their form after the main document finishes loading.
                for _ in 0..<60 {
                    guard !Task.isCancelled, generation == token, started, origin == WebLoginOrigin(view.url) else { return }
                    let selectors = entry.transport?.webLoginSelectors
                    let twoStep = selectors?.isTwoStep == true
                    let stage = twoStep ? (usernameAttempted ? "password" : "username") : "combined"
                    if stage == "password", stepUsername == nil { loginStatus = "Начни вход заново или заверши его вручную."; return }
                    if let deadline = stepDeadline, deadline < Date() { loginStatus = "Время ожидания шага пароля истекло. Заверши вход вручную."; return }
                    let status = try await WebLoginForm.run(in: view, origin: destination, probe: true, selectors: selectors, stage: stage)
                    guard !Task.isCancelled, generation == token, started, origin == WebLoginOrigin(view.url) else { return }
                    if status == "waiting" { try await Task.sleep(for: .milliseconds(250)); continue }
                    guard status == "ready" else { loginStatus = "Войди вручную: форма требует подтверждения или не распознана."; return }
                    if stage == "username" { usernameAttempted = true; stepDeadline = Date().addingTimeInterval(15) }
                    else { formAttempted = true } // Never automatically retry either step.
                    guard let (username, secret) = try credentials(entry, config) else { loginStatus = "Сохрани логин и пароль в настройках записи."; return }
                    guard !Task.isCancelled, generation == token, started, origin == WebLoginOrigin(view.url) else { return }
                    if stage == "password", stepUsername != username { loginStatus = "Учётные данные изменились. Начни вход заново."; return }
                    if stage == "username" { stepUsername = username }
                    let result = try await WebLoginForm.run(in: view, origin: destination, username: username, password: stage == "username" ? "" : secret, probe: false, selectors: selectors, stage: stage)
                    guard !Task.isCancelled, generation == token, started else { return }
                    loginStatus = result == "submitted" ? (stage == "username" ? "Ожидание шага пароля…" : nil) : "Проверь форму и заверши вход вручную."
                    if stage == "username", result == "submitted" { try await Task.sleep(for: .milliseconds(250)); continue }
                    stepUsername = nil; stepDeadline = nil
                    if stage == "username" { formAttempted = true }
                    return
                }
                if manualLogin { loginStatus = "Форма входа не найдена на этой странице." }
            } catch is CancellationError {} catch { if generation == token && started { loginStatus = "Не удалось заполнить вход. Проверь пароль в настройках записи или войди вручную." } }
        }
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { cancelLogin(); onNavigation?() }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { if let url = webView.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") { address = url.absoluteString }; objectWillChange.send(); fillLogin() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { self.error = error.localizedDescription }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { self.error = error.localizedDescription }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.targetFrame?.isMainFrame != false, let url = navigationAction.request.url, WebLoginOrigin(url) != WebLoginOrigin(URL(string: entry.website ?? "")) { stepUsername = nil; stepDeadline = nil; if usernameAttempted { formAttempted = true } }
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
        guard started, !setupOnly else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        let space = challenge.protectionSpace
        guard !space.isProxy(), [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest].contains(space.authenticationMethod) else { completionHandler(.performDefaultHandling, nil); return }
        if challenge.previousFailureCount > 0 { error = "Сайт отклонил логин или пароль. Проверь данные записи и нажми «Войти» для повторной попытки."; completionHandler(.cancelAuthenticationChallenge, nil); return }
        if (entry.transport?.webAutoLogin == true || manualLogin), !httpAttempted, !entry.isQuickConnection,
           WebLoginOrigin(URL(string: entry.website ?? ""))?.matches(space) == true {
            httpAttempted = true
            do {
                if let (username, password) = try credentials(entry, config), started {
                    completionHandler(.useCredential, URLCredential(user: username, password: password, persistence: .none)); return
                }
            } catch { self.error = "Не удалось прочитать учётные данные сайта из Связки ключей."; completionHandler(.cancelAuthenticationChallenge, nil); return }
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
