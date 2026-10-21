import AppKit
import WebKit

@main @MainActor enum WebLoginTests {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws { if !value() { throw ConfigError.message(message) } }
    static let user = "fixture@example.test", password = "fixture-'\"\\</script>"
    static let config = URL(fileURLWithPath: "/fixture/config")
    static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        var done = false, failure: String?
        Task { do { try await run(); print("Web login tests passed: isolated WebKit, exact origins, form guards, no restore login, Keychain failure, stop and no retries") } catch { failure = error.localizedDescription }; done = true }
        let deadline = Date().addingTimeInterval(90)
        while !done && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        if let failure { fputs("Web login test failed: \(failure)\n", stderr); exit(1) }
        if !done { fputs("Web login test timed out\n", stderr); exit(1) }
    }
    static func wait(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 { if condition() { return }; try await Task.sleep(for: .milliseconds(25)) }
        throw ConfigError.message("Timed out waiting for WebKit")
    }
    static func entry(_ url: String, automatic: Bool = true) -> SSHAlias {
        var record = LocalConnectionRecord(); record.kind = .web; record.title = "Fixture"; record.user = user; record.website = url; record.transport = ConnectionSettings(); record.transport?.webAutoLogin = automatic
        return record.entry(config: config, privateConfig: URL(fileURLWithPath: "/fixture/private"))
    }
    static func run() async throws {
        let base = CommandLine.arguments[1], other = CommandLine.arguments[2]
        let origin = WebLoginOrigin(URL(string: base))!
        try check(origin == WebLoginOrigin(URL(string: base + "/path?q=1")), "origin ignores path")
        try check(origin != WebLoginOrigin(URL(string: other)), "port scoped")
        try check(WebLoginOrigin(URL(string: "https://example.test")) == WebLoginOrigin(URL(string: "https://EXAMPLE.test:443/path")), "canonical default port")
        try check(WebLoginOrigin(URL(string: "https://u:p@example.test")) == nil && WebLoginOrigin(URL(string: "file:///tmp/test")) == nil, "invalid credential origins")
        try check(WebLoginForm.originString(URL(string: "http://[::1]:8080/x")!) == "http://[::1]:8080", "IPv6 origin")
        let space = URLProtectionSpace(host: origin.host, port: origin.port, protocol: origin.scheme, realm: "fixture", authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        try check(origin.matches(space), "Basic origin")
        try check(!origin.matches(URLProtectionSpace(host: origin.host, port: origin.port, protocol: "https", realm: nil, authenticationMethod: NSURLAuthenticationMethodHTTPBasic)), "scheme scoped")
        try check(!origin.matches(URLProtectionSpace(proxyHost: origin.host, port: origin.port, type: NSURLProtectionSpaceHTTPProxy, realm: nil, authenticationMethod: NSURLAuthenticationMethodHTTPBasic)), "proxy excluded")
        let old = try JSONDecoder().decode(ConnectionSettings.self, from: JSONEncoder().encode(ConnectionSettings()))
        try check(old.webAutoLogin == nil, "old settings never opt in")
        var record = LocalConnectionRecord(); record.kind = .web; record.title = "Fixture"; record.website = base; record.user = user; record.transport = old; record.transport?.webAutoLogin = true
        let encoded = try JSONEncoder().encode(record), decoded = try JSONDecoder().decode(LocalConnectionRecord.self, from: encoded)
        try check(decoded == record && !String(decoding: encoded, as: UTF8.self).contains(password), "public settings roundtrip without secret")
        let original = entry(base + "/form")
        let account = SSHPasswordStore.account(for: original, config: config)
        var changed = original; changed.website = other + "/form"
        try check(SSHPasswordStore.account(for: changed, config: config) != account, "changed site cannot reuse credential account")
        changed = original; changed.options.insert(SSHOption(key: "User", value: "other"), at: 0)
        try check(SSHPasswordStore.account(for: changed, config: config) != account && SSHPasswordStore.account(for: original, config: URL(fileURLWithPath: "/other/config")) != account, "username and config scope")
        let custom = WebLoginSelectors(username: "#account", password: "#credential", submit: "#enter")
        record.transport?.webLoginSelectors = custom
        try check(record.transport?.validation == nil && (try? JSONDecoder().decode(LocalConnectionRecord.self, from: JSONEncoder().encode(record)))?.transport?.webLoginSelectors == custom, "manual selectors public roundtrip")
        try check(WebLoginSelectors(username: "#a", password: "#a", submit: "#b").validation != nil && WebLoginSelectors().validation != nil, "incomplete/overlapping selectors rejected")
        record.user = "bad\nuser"; try check(record.validation != nil, "bounded one-line username")

        var setupReads = 0
        let setup = WebPageModel(entry: entry(base + "/manual"), config: config, setupOnly: true, credentialReader: { _,_ in setupReads += 1; return (user, password) })
        let setupWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        setupWindow.isReleasedWhenClosed = false; setupWindow.contentView = setup.view
        let picker = WebLoginPickerModel(web: setup, origin: URL(string: base + "/manual")!)
        setup.start(); picker.start()
        try await wait { setup.view.url?.path == "/manual" && !setup.view.isLoading }
        // The picker captures clicks before page handlers and never reads values.
        for (role, selector) in [("username", "#account"), ("password", "#credential"), ("submit", "#enter")] {
            picker.role = role
            _ = try await WebLoginPickerScript.run(in: setup.view, origin: URL(string: base)!, role: role)
            _ = try await setup.view.callAsyncJavaScript("document.querySelector(selector).click();", arguments: ["selector": selector], in: nil, contentWorld: .defaultClient)
        }
        let verified = await picker.check()
        try check(setupReads == 0 && verified == custom && picker.verified && setup.view.url?.path == "/manual", "visual selection checked without submitting")
        let contents = try await setup.view.callAsyncJavaScript("return [...document.querySelectorAll('input')].every(e=>e.value==='');", arguments: [:], in: nil, contentWorld: .defaultClient)
        try check(contents as? Bool == true, "visual setup does not fill/read credentials")
        _ = try await setup.view.callAsyncJavaScript("document.querySelector('#credential').replaceWith(document.querySelector('#credential').cloneNode());", arguments: [:], in: nil, contentWorld: .page)
        let invalidNode = await picker.check()
        try check(invalidNode == nil && !picker.verified, "replacement of selected DOM node invalidates check even with same selector")
        setup.address = other + "/form"; setup.start()
        try await wait { setup.view.url?.absoluteString == other + "/form" && !setup.view.isLoading }
        let invalidOrigin = await picker.check()
        try check(invalidOrigin == nil && !picker.verified && picker.selectors.username.isEmpty, "navigation and different origin clear selection")
        picker.close(); setupWindow.close()
        var stepSetupReads = 0
        let stepSetup = WebPageModel(entry: entry(base + "/two"), config: config, setupOnly: true, credentialReader: { _,_ in stepSetupReads += 1; return (user, password) })
        setupWindow.contentView = stepSetup.view
        let stepPicker = WebLoginPickerModel(web: stepSetup, origin: URL(string: base)!)
        stepPicker.setTwoStep(true); stepSetup.start(); stepPicker.start()
        try await wait { stepSetup.view.url?.path == "/two" && !stepSetup.view.isLoading }
        for (role, selector) in [("username", "#step-user"), ("next", "#next")] {
            stepPicker.role = role
            _ = try await WebLoginPickerScript.run(in: stepSetup.view, origin: URL(string: base)!, role: role, twoStep: true)
            _ = try await stepSetup.view.callAsyncJavaScript("document.querySelector(selector).click();", arguments: ["selector": selector], in: nil, contentWorld: .defaultClient)
        }
        let firstStep = await stepPicker.check()
        try check(firstStep?.next == "#next" && stepPicker.verified && !stepPicker.canApply, "first step separately verified without submission")
        stepPicker.advance()
        _ = try await WebLoginPickerScript.run(in: stepSetup.view, origin: URL(string: base)!, operation: "pause", role: "password", twoStep: true)
        _ = try await stepSetup.view.callAsyncJavaScript("document.querySelector('#step-user').value='fixture-setup';document.querySelector('#next').click();", arguments: [:], in: nil, contentWorld: .defaultClient)
        try await wait { stepSetup.view.url?.path == "/step-next" && !stepSetup.view.isLoading }
        for (role, selector) in [("password", "#step-password"), ("submit", "#finish")] {
            stepPicker.role = role
            _ = try await WebLoginPickerScript.run(in: stepSetup.view, origin: URL(string: base)!, operation: "resume", role: role, twoStep: true)
            _ = try await stepSetup.view.callAsyncJavaScript("document.querySelector(selector).click();", arguments: ["selector": selector], in: nil, contentWorld: .defaultClient)
        }
        let secondStep = await stepPicker.check()
        try check(secondStep?.validation == nil && secondStep?.username == "#step-user" && stepPicker.canApply && stepSetupReads == 0, "visual two-step setup retains first selectors, verifies second without credentials")
        stepPicker.close()
        var roleSetupReads = 0
        let roleSetup = WebPageModel(entry: entry(base + "/role-two"), config: config, setupOnly: true, credentialReader: { _,_ in roleSetupReads += 1; return (user, password) })
        setupWindow.contentView = roleSetup.view
        let rolePicker = WebLoginPickerModel(web: roleSetup, origin: URL(string: base)!)
        rolePicker.setTwoStep(true); roleSetup.start(); rolePicker.start()
        try await wait { roleSetup.view.url?.path == "/role-two" && !roleSetup.view.isLoading }
        for (role, selector) in [("username", "input[syno-id=username]"), ("next", "[syno-id=account-panel-next-btn] .arrow")] {
            rolePicker.role = role
            _ = try await WebLoginPickerScript.run(in: roleSetup.view, origin: URL(string: base)!, role: role, twoStep: true)
            _ = try await roleSetup.view.callAsyncJavaScript("document.querySelector(selector).click();", arguments: ["selector": selector], in: nil, contentWorld: .defaultClient)
        }
        let roleFirst = await rolePicker.check()
        try check(roleFirst?.next == "div[syno-id=account-panel-next-btn]" && rolePicker.verified, "nested arrow selects external role button with stable locator")
        rolePicker.advance()
        _ = try await WebLoginPickerScript.run(in: roleSetup.view, origin: URL(string: base)!, operation: "pause", role: "password", twoStep: true)
        _ = try await roleSetup.view.callAsyncJavaScript("document.querySelector('[syno-id=username]').value='fixture-setup';document.querySelector('[syno-id=username]').dispatchEvent(new Event('input',{bubbles:true}));", arguments: [:], in: nil, contentWorld: .defaultClient)
        try await Task.sleep(for: .milliseconds(50))
        _ = try await roleSetup.view.callAsyncJavaScript("document.querySelector('[syno-id=account-panel-next-btn]').click();", arguments: [:], in: nil, contentWorld: .defaultClient)
        for (role, selector) in [("password", "input[syno-id=password]"), ("submit", "[syno-id=password-next] .arrow")] {
            rolePicker.role = role
            _ = try await WebLoginPickerScript.run(in: roleSetup.view, origin: URL(string: base)!, operation: "resume", role: role, twoStep: true)
            _ = try await roleSetup.view.callAsyncJavaScript("document.querySelector(selector).click();", arguments: ["selector": selector], in: nil, contentWorld: .defaultClient)
        }
        let roleChoice = await rolePicker.check()
        try check(roleChoice?.validation == nil && roleChoice?.password == "input[syno-id=password]" && rolePicker.canApply && roleSetupReads == 0, "external password role button visual setup never reads credentials")
        rolePicker.close()
        var reads = 0
        let model = WebPageModel(entry: entry(base + "/form", automatic: false), config: config, credentialReader: { _,_ in reads += 1; return (user, password) })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false); window.isReleasedWhenClosed = false; window.contentView = model.view
        try await Task.sleep(for: .milliseconds(100)); try check(reads == 0 && !model.started, "construction/restoration does not start or read a password")
        model.start(); try await wait { model.view.url?.path == "/form" && !model.view.isLoading }
        try await Task.sleep(for: .milliseconds(300)); try check(reads == 0, "automatic login disabled")
        model.login(); try await wait { model.view.url?.path == "/submit" && !model.view.isLoading }
        try check(reads == 1 && !model.view.configuration.websiteDataStore.isPersistent, "manual action uses isolated session")
        model.stop(); try check(!model.started && !model.canLogin && model.loginStatus == nil, "stop clears login state")
        for path in ["/basic", "/delayed", "/spa", "/repeat"] {
            var count = 0
            let auto = WebPageModel(entry: entry(base + path), config: config, credentialReader: { _,_ in count += 1; return (user, password) })
            window.contentView = auto.view; auto.start()
            try await wait { count > 0 && !auto.view.isLoading }
            try await Task.sleep(for: .milliseconds(600))
            try check(count == 1, "one credential read per explicit session " + path)
            if path == "/spa" { try await wait { auto.view.title == "SPA success" } }
            if path == "/repeat" { try check(auto.view.url?.path == "/repeat-submit", "failed form stays manual") }
            auto.stop()
        }
        let steps = WebLoginSelectors(username: "#step-user", password: "#step-password", submit: "#finish", next: "#next")
        try check(steps.validation == nil && (try? JSONDecoder().decode(WebLoginSelectors.self, from: JSONEncoder().encode(custom)))?.next == nil, "two-step backward compatibility")
        for path in ["/two", "/two-spa", "/two-redirect"] {
            var stepEntry = entry(base + path); stepEntry.transport?.webLoginSelectors = steps
            var stepReads = 0
            let step = WebPageModel(entry: stepEntry, config: config, credentialReader: { _,_ in stepReads += 1; return (user, password) })
            window.contentView = step.view; step.start()
            if path == "/two" { try await wait { step.view.url?.path == "/step-finish" && !step.view.isLoading } }
            else if path == "/two-spa" { try await wait { step.view.title == "Two success" } }
            else { try await wait { step.view.url?.absoluteString == other + "/form" && !step.view.isLoading } }
            try await Task.sleep(for: .milliseconds(350))
            try check(stepReads == (path == "/two-redirect" ? 1 : 2), "bounded two-step credential reads " + path)
            step.stop()
        }
        var roleEntry = entry(base + "/role-two"); roleEntry.transport?.webLoginSelectors = roleChoice
        var roleReads = 0
        let roleLogin = WebPageModel(entry: roleEntry, config: config, credentialReader: { _,_ in roleReads += 1; return (user, password) })
        window.contentView = roleLogin.view; roleLogin.start()
        try await wait { roleLogin.view.title == "Role success" }
        try await Task.sleep(for: .milliseconds(250))
        try check(roleReads == 2, "external role buttons wait for reactive DOM, fill both steps once"); roleLogin.stop()
        var manualEntry = entry(base + "/manual"); manualEntry.transport?.webLoginSelectors = custom
        var customReads = 0
        let configured = WebPageModel(entry: manualEntry, config: config, credentialReader: { _,_ in customReads += 1; return (user, password) })
        window.contentView = configured.view; configured.start()
        try await wait { configured.view.url?.path == "/submit" && !configured.view.isLoading }
        try check(customReads == 1, "explicit selectors submit unusual form exactly once"); configured.stop()
        var rejectedReads = 0
        let rejected = WebPageModel(entry: entry(base + "/basic"), config: config, credentialReader: { _,_ in rejectedReads += 1; return (user, "incorrect-fixture") })
        window.contentView = rejected.view; rejected.start(); try await wait { rejected.error != nil }; try await Task.sleep(for: .milliseconds(300))
        try check(rejectedReads == 1, "HTTP refusal does not retry stored credentials"); rejected.stop()
        var redirectReads = 0
        let redirected = WebPageModel(entry: entry(base + "/redirect"), config: config, credentialReader: { _,_ in redirectReads += 1; return (user, password) })
        window.contentView = redirected.view; redirected.start(); try await wait { redirected.view.url?.absoluteString == other + "/form" && !redirected.view.isLoading }
        try await Task.sleep(for: .milliseconds(300)); try check(redirectReads == 0 && !redirected.canLogin, "redirected origin gets no credentials"); redirected.stop()
        let blocked = WebPageModel(entry: entry(base + "/form"), config: config, credentialReader: { _,_ in throw ConfigError.message("synthetic locked preset") })
        window.contentView = blocked.view; blocked.start(); try await wait { blocked.loginStatus != nil }; try check(blocked.view.url?.path == "/form", "locked credentials never submit or fall back"); blocked.stop()
        var stoppedReads = 0
        let stopped = WebPageModel(entry: entry(base + "/delayed"), config: config, credentialReader: { _,_ in stoppedReads += 1; return (user, password) })
        window.contentView = stopped.view; stopped.start(); stopped.stop(); try await Task.sleep(for: .milliseconds(500)); try check(stoppedReads == 0, "stop before delayed form prevents read")

        // Exercise the real script in the same isolated content world against synthetic DOM.
        let view = model.view; window.contentView = view
        view.load(URLRequest(url: URL(string: base + "/blank")!)); try await wait { view.url?.path == "/blank" && !view.isLoading }
        let secondHTML = #"<form method="post" action="/submit"><input id="step-password" type="password"><button id="finish" type="submit">Войти</button></form>"#
        for (html, expected) in [(secondHTML, "ready"), (secondHTML.replacingOccurrences(of: "post", with: "get"), "manual"), (secondHTML.replacingOccurrences(of: "</form>", with: "<input autocomplete='one-time-code'></form>"), "manual"), (secondHTML.replacingOccurrences(of: "/submit", with: other + "/submit"), "origin"), (secondHTML.replacingOccurrences(of: "type=\"password\"", with: "type=\"password\" autocomplete=\"new-password\""), "manual")] {
            _ = try await view.callAsyncJavaScript("document.body.innerHTML=html;", arguments: ["html": html], in: nil, contentWorld: .defaultClient)
            let status = try await WebLoginForm.run(in: view, origin: URL(string: base)!, probe: true, selectors: steps, stage: "password")
            try check(status == expected, "second step preserves form guards " + expected)
        }
        let externalRole = #"<form id="credentials"><input id="account"><input id="credential" type="password"></form><div role="button" id="enter"><span>Войти</span></div>"#
        for (html, expected) in [(externalRole, "ready"), (externalRole.replacingOccurrences(of: "<div role=", with: "<a href='/submit' role=").replacingOccurrences(of: "</div>", with: "</a>"), "manual"), (externalRole.replacingOccurrences(of: "<div role=", with: "<form id='other'><div role=") + "</form>", "manual"), (externalRole.replacingOccurrences(of: "id=\"credentials\"", with: "id=\"credentials\" action=\"" + other + "/submit\""), "origin"), (externalRole.replacingOccurrences(of: "</form>", with: "<input autocomplete='one-time-code'></form>"), "manual")] {
            _ = try await view.callAsyncJavaScript("document.body.innerHTML=html;", arguments: ["html": html], in: nil, contentWorld: .defaultClient)
            let result = try await WebLoginForm.run(in: view, origin: URL(string: base)!, probe: true, selectors: custom)
            try check(result == expected, "external role guard " + expected)
        }
        _ = try await view.callAsyncJavaScript("document.body.innerHTML=html;document.querySelector('#credential').addEventListener('input',()=>setTimeout(()=>document.querySelector('#enter').setAttribute('role','link'),0));", arguments: ["html": externalRole], in: nil, contentWorld: .defaultClient)
        let changedRole = try await WebLoginForm.run(in: view, origin: URL(string: base)!, username: user, password: password, probe: false, selectors: custom)
        try check(changedRole == "filled", "reactive role mutation cannot trigger changed control")
        let normal = #"<form method="post" action="/submit"><input name="username"><input type="password" name="password"><button type="submit">Войти</button></form>"#
        let cases: [(String, String)] = [
            (normal, "ready"),
            (normal.replacingOccurrences(of: "post", with: "get"), "manual"),
            (normal.replacingOccurrences(of: "Войти", with: "Delete account"), "manual"),
            (normal.replacingOccurrences(of: "</form>", with: "<input name=\"code\"></form>"), "manual"),
            (normal.replacingOccurrences(of: "/submit", with: other + "/submit"), "origin"),
            (normal.replacingOccurrences(of: "type=\"password\"", with: "type=\"password\" autocomplete=\"new-password\""), "manual"),
            (normal.replacingOccurrences(of: "</form>", with: "<input autocomplete=\"one-time-code\"></form>"), "manual"),
            (normal.replacingOccurrences(of: "</form>", with: "<input type=\"password\"></form>"), "ambiguous"),
            (normal.replacingOccurrences(of: "</form>", with: "<input data-sitekey=\"fixture\"></form>"), "manual"),
            (normal.replacingOccurrences(of: "type=\"submit\"", with: "type=\"submit\" formaction=\"" + other + "/submit\""), "origin")
        ]
        for (html, expected) in cases {
            _ = try await view.callAsyncJavaScript("document.body.innerHTML=html;", arguments: ["html": html], in: nil, contentWorld: .defaultClient)
            let result = try await WebLoginForm.run(in: view, origin: URL(string: base)!, probe: true)
            try check(result == expected, "form guard " + expected + " got " + result)
        }
        _ = try await view.callAsyncJavaScript("document.body.innerHTML=html; document.querySelector('[type=password]').addEventListener('input', ()=>document.querySelector('form').method='get');", arguments: ["html": normal], in: nil, contentWorld: .defaultClient)
        let changedMethod = try await WebLoginForm.run(in: view, origin: URL(string: base)!, username: user, password: password, probe: false)
        try check(changedMethod == "filled", "changed form method cannot submit password through GET")
        let unusual = #"<form method="post" action="/submit"><input id="account"><input id="credential" type="password"><button id="enter" type="submit">Continue to dashboard</button></form><form><input type="password"></form>"#
        let customCases: [(String, WebLoginSelectors, String)] = [
            (unusual, custom, "ready"),
            (unusual, .init(username: "[", password: "#credential", submit: "#enter"), "selectors"),
            (unusual, .init(username: "input", password: "#credential", submit: "#enter"), "waiting"),
            (unusual.replacingOccurrences(of: "method=\"post\"", with: "method=\"get\""), custom, "manual"),
            (unusual.replacingOccurrences(of: "/submit", with: other + "/submit"), custom, "origin"),
            (unusual.replacingOccurrences(of: "id=\"credential\"", with: "id=\"credential\" autocomplete=\"new-password\""), custom, "manual"),
            (unusual.replacingOccurrences(of: "<button id", with: "<input name=\"otp\"><button id"), custom, "manual"),
            (unusual.replacingOccurrences(of: "<button id", with: "<div data-sitekey=\"fixture\"></div><button id"), custom, "manual"),
            (unusual.replacingOccurrences(of: "<input id=\"account\">", with: "<input id=\"account\" form=\"other\">"), custom, "manual")
        ]
        for (html, selectors, expected) in customCases {
            _ = try await view.callAsyncJavaScript("document.body.innerHTML=html;", arguments: ["html": html], in: nil, contentWorld: .defaultClient)
            let result = try await WebLoginForm.run(in: view, origin: URL(string: base)!, probe: true, selectors: selectors)
            try check(result == expected, "manual selector guard " + expected + " got " + result)
        }
        _ = try await view.callAsyncJavaScript("document.body.innerHTML=html; document.querySelector('#account').addEventListener('input', ()=>document.querySelector('#enter').id='replaced');", arguments: ["html": unusual], in: nil, contentWorld: .defaultClient)
        let replaced = try await WebLoginForm.run(in: view, origin: URL(string: base)!, username: user, password: password, probe: false, selectors: custom)
        try check(replaced == "filled", "manual selector mutation cannot submit stale element")
        _ = try await view.callAsyncJavaScript("document.body.innerHTML=html; document.querySelector('[name=username]').addEventListener('input', ()=>document.querySelector('button').setAttribute('form','other'));", arguments: ["html": normal + "<form id='other' method='get'></form>"], in: nil, contentWorld: .defaultClient)
        let reassociated = try await WebLoginForm.run(in: view, origin: URL(string: base)!, username: user, password: password, probe: false)
        try check(reassociated == "filled", "button reassociated with another form cannot submit")
        // The final validation must not overwrite a username already entered by the user.
        _ = try await view.callAsyncJavaScript("document.body.innerHTML=html; document.querySelector('[name=username]').value='another-user';", arguments: ["html": normal], in: nil, contentWorld: .defaultClient)
        let existingUser = try await WebLoginForm.run(in: view, origin: URL(string: base)!, username: user, password: password, probe: false)
        try check(existingUser == "manual", "existing different username preserved")
        window.contentView = nil; window.close()
    }
}
