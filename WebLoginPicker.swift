import Foundation
import WebKit

// Only DOM locators cross this bridge. Never read field values, cookies or credentials.
enum WebLoginPickerScript {
    static let bootstrap = #"""
    (() => {
      if (window !== window.top || window.__sshHubPickerGuard) return;
      window.__sshHubPickerGuard = true; window.__sshHubPickerEnabled = true;
      const block = e => {
        if (!window.__sshHubPickerEnabled) return;
        if (e.type === 'keydown' && e.key !== 'Enter' && e.key !== ' ') return;
        e.preventDefault(); e.stopImmediatePropagation();
        if (e.type === 'click') window.__sshHubLoginPicker?.choose?.(e);
      };
      for (const type of ['pointerdown','mousedown','click','submit','keydown']) window.addEventListener(type,block,true);
    })();
    """#
    static let script = bootstrap + #"""

    if (window !== window.top || location.origin !== origin) return {error:'origin'};
    const key = '__sshHubLoginPicker';
    if (operation === 'stop') { window[key]?.stop(); delete window[key]; window.__sshHubPickerEnabled=false; return {}; }
    if (!window[key]) {
      window.__sshHubPickerEnabled=true; const nodes = {}, selectors = {};
      const host = document.createElement('div'); host.style.cssText = 'position:fixed;inset:0;pointer-events:none;z-index:2147483647';
      const shadow = host.attachShadow({mode:'closed'}); document.documentElement.append(host);
      const state = {nodes, selectors, role:'username', revision:0, error:'', stop:()=>{host.remove();}};
      window[key] = state;
      const unique = (selector, node) => { try { const all = document.querySelectorAll(selector); return all.length === 1 && all[0] === node; } catch (_) { return false; } };
      const locator = node => {
        if (node.id) { const s = '#' + CSS.escape(node.id); if (s.length <= 512 && unique(s,node)) return s; }
        for (const attribute of ['syno-id', 'data-testid']) {
          const value = node.getAttribute(attribute);
          if (value) { const s = node.localName + '[' + attribute + '=' + CSS.escape(value) + ']'; if (s.length <= 512 && unique(s,node)) return s; }
        }
        if (node.name) { const s = node.localName + '[name=' + CSS.escape(node.name) + ']'; if (s.length <= 512 && unique(s,node)) return s; }
        const path = []; let element = node;
        while (element && element.nodeType === 1) {
          const tag = element.localName;
          const siblings = element.parentElement ? [...element.parentElement.children].filter(e=>e.localName===tag) : [element];
          path.unshift(tag + (siblings.length > 1 ? ':nth-of-type(' + (siblings.indexOf(element)+1) + ')' : ''));
          const s = path.join(' > '); if (s.length > 512) return null;
          if (unique(s,node)) return s; element = element.parentElement;
        }
        return null;
      };
      const visible = e => e?.isConnected && !e.disabled && !e.readOnly && e.getClientRects().length && getComputedStyle(e).visibility !== 'hidden' && getComputedStyle(e).display !== 'none';
      state.valid = () => (state.twoStep ? (state.role==='username' || state.role==='next' ? ['username','next'] : ['password','submit']) : ['username','password','submit']).every(role=>visible(nodes[role]) && unique(selectors[role],nodes[role]));
      state.draw = () => {
        shadow.replaceChildren();
        for (const [role,node] of Object.entries(nodes)) {
          if (!node.isConnected) continue;
          const r=node.getBoundingClientRect(), box=document.createElement('div');
          box.style.cssText='position:fixed;box-sizing:border-box;border:3px solid '+({username:'#1688ff',password:'#b76dff',submit:'#26ad67',next:'#26ad67'}[role])+';border-radius:4px;';
          Object.assign(box.style,{left:r.left+'px',top:r.top+'px',width:r.width+'px',height:r.height+'px'}); shadow.append(box);
        }
      };
      const block = e => { e.preventDefault();e.stopImmediatePropagation(); };
      const choose = e => {
        block(e); const node = e.target instanceof Element ? e.target.closest('input,button,[role=button]') : null;
        const role=state.role;
        const valid = visible(node) && (role==='password' ? node instanceof HTMLInputElement && node.type==='password' : role==='username' ? node instanceof HTMLInputElement && ['text','email','tel'].includes(node.type) : ((node instanceof HTMLButtonElement || node instanceof HTMLInputElement) && ['submit','button'].includes(node.type) || node instanceof HTMLElement && !node.matches('input,button,a,[href]') && !node.closest('button,a[href]') && node.getAttribute('role') === 'button'));
        if (!valid) { state.error='type'; return; }
        const selector=locator(node); if (!selector) { state.error='selector'; return; }
        if (Object.entries(nodes).some(([r,n])=>r!==role && n===node)) { state.error='duplicate'; return; }
        nodes[role]=node;selectors[role]=selector;state.revision++;state.error='';state.draw();
      };
      state.choose=choose;
    }
    const state = window[key]; state.role = role; state.twoStep = twoStep;
    const group = twoStep ? (role === 'username' || role === 'next' ? 'first' : 'second') : 'combined';
    if (state.group && state.group !== group) { for (const key of Object.keys(state.nodes)) delete state.nodes[key]; for (const key of Object.keys(state.selectors)) delete state.selectors[key]; state.revision++; }
    state.group = group;
    if (operation === 'pause') window.__sshHubPickerEnabled=false;
    if (operation === 'resume') window.__sshHubPickerEnabled=true;
    state.draw();
    return {selectors:state.selectors, revision:state.revision, valid:state.valid(), error:state.error};
    """#
    @MainActor static func run(in view: WKWebView, origin: URL, operation: String = "poll", role: String = "username", twoStep: Bool = false) async throws -> [String: Any] {
        try await view.callAsyncJavaScript(script, arguments: ["origin": WebLoginForm.originString(origin), "operation": operation, "role": role, "twoStep": twoStep], in: nil, contentWorld: .defaultClient) as? [String: Any] ?? [:]
    }
}

@MainActor final class WebLoginPickerModel: ObservableObject {
    let web: WebPageModel
    let origin: URL
    @Published var role = "username"
    @Published var selecting = true
    @Published var twoStep = false
    @Published private(set) var passwordStep = false
    private var firstVerified = false
    @Published private(set) var selectors = WebLoginSelectors()
    @Published private(set) var verified = false
    @Published private(set) var checking = false
    @Published var status = "Выбери «Логин» и нажми на поле на странице."
    private var revision = -1
    private var generation = UUID()
    private var polling: Task<Void, Never>?
    private var closed = false
    init(web: WebPageModel, origin: URL) {
        self.web = web; self.origin = origin
        web.onNavigation = { [weak self] in self?.invalidate() }
    }
    private func invalidate() {
        generation = UUID(); revision = -1; verified = false
        if twoStep && passwordStep && firstVerified && WebLoginOrigin(web.view.url) == WebLoginOrigin(origin) {
            selectors.password = ""; selectors.submit = ""; status = "Выбери поле пароля и кнопку входа на втором шаге."
        } else if twoStep && passwordStep && firstVerified && web.view.url == nil { status = "Ожидание второго шага…" }
        else if !twoStep || !passwordStep { selectors = WebLoginSelectors(next: twoStep ? "" : nil); firstVerified = false; status = "Страница изменилась. Выбери поля заново." }
        else { firstVerified = false; status = "Переход на другой сайт: начни настройку заново." }
    }
    func setTwoStep(_ value: Bool) { generation = UUID(); twoStep = value; passwordStep = false; firstVerified = false; role = "username"; selecting = true; selectors = WebLoginSelectors(next: value ? "" : nil); revision = -1; verified = false }
    func advance() {
        guard twoStep, firstVerified, verified, !checking else { return }
        generation = UUID(); passwordStep = true; role = "password"; selecting = false; revision = -1; verified = false
        status = "Введи логин на странице и нажми «Далее», затем включи режим выбора и укажи пароль и кнопку входа."
    }
    var currentComplete: Bool { twoStep ? (passwordStep ? !selectors.password.isEmpty && !selectors.submit.isEmpty && firstVerified : !selectors.username.isEmpty && !(selectors.next ?? "").isEmpty) : selectors.validation == nil }
    var canApply: Bool { verified && (!twoStep || passwordStep) }
    func start() {
        guard polling == nil, !closed else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.closed else { return }
                await self.poll()
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            }
        }
    }
    private func update(_ state: [String: Any]) {
        guard let selected = state["selectors"] as? [String: String], let number = state["revision"] as? Int else { verified = false; return }
        if revision != number {
            revision = number; verified = false
            if twoStep {
                if passwordStep { selectors.password = selected["password"] ?? ""; selectors.submit = selected["submit"] ?? "" }
                else { selectors.username = selected["username"] ?? ""; selectors.next = selected["next"] ?? ""; firstVerified = false }
            } else { selectors = WebLoginSelectors(username: selected["username"] ?? "", password: selected["password"] ?? "", submit: selected["submit"] ?? "") }
            status = twoStep && passwordStep && !selecting ? "Введи логин на странице и нажми «Далее», затем включи выбор пароля и кнопки входа." : currentComplete ? "Все элементы выбраны. Нажми «Проверить настройку»." : "Выбери оставшиеся элементы."
        }
        if state["valid"] as? Bool != true { verified = false }
        if let error = state["error"] as? String, !error.isEmpty { status = error == "origin" ? "Открой форму на исходном адресе записи." : "Выбери подходящее поле или кнопку входа." }
    }
    private func poll() async {
        guard !checking, !web.view.isLoading else { verified = false; return }
        guard WebLoginOrigin(web.view.url) == WebLoginOrigin(origin) else { verified = false; firstVerified = false; status = "Дождись загрузки формы на исходном сайте. После перехода на другой сайт нажми «Загрузить заново»."; return }
        let token = generation
        if let state = try? await WebLoginPickerScript.run(in: web.view, origin: origin, operation: selecting ? "resume" : "pause", role: role, twoStep: twoStep), token == generation, !closed { update(state) }
    }
    func selectRole(_ value: String) {
        role = value; selecting = true
        Task { await poll() }
    }
    func check() async -> WebLoginSelectors? {
        guard !checking, !closed, !web.view.isLoading, WebLoginOrigin(web.view.url) == WebLoginOrigin(origin) else { verified = false; return nil }
        checking = true; verified = false
        defer { checking = false }
        let token = generation
        do {
            let state = try await WebLoginPickerScript.run(in: web.view, origin: origin, role: role, twoStep: twoStep)
            guard token == generation, !closed else { return nil }; update(state)
            let choice = selectors, number = revision
            guard currentComplete, state["valid"] as? Bool == true else { status = "Выбери все видимые элементы этого шага заново."; return nil }
            let result = try await WebLoginForm.run(in: web.view, origin: origin, probe: true, selectors: choice, stage: twoStep ? (passwordStep ? "password" : "username") : "combined")
            let after = try await WebLoginPickerScript.run(in: web.view, origin: origin, role: role, twoStep: twoStep)
            guard !closed, token == generation, !web.view.isLoading, WebLoginOrigin(web.view.url) == WebLoginOrigin(origin), after["revision"] as? Int == number, after["valid"] as? Bool == true, result == "ready" else {
                status = "Проверка не пройдена: форма изменилась или требует ручного входа. Проверь поля, метод отправки и адрес формы."; return nil
            }
            if twoStep && !passwordStep { firstVerified = true }
            verified = true; status = "Шаг проверен. Поля и кнопка доступны на этом сайте. Пароль не вводился, вход не выполнялся."
            return choice
        } catch { status = "Не удалось проверить страницу. Дождись загрузки и выбери поля заново."; return nil }
    }
    func close() {
        closed = true; generation = UUID(); polling?.cancel(); polling = nil; web.onNavigation = nil
        web.stop() // Clearing the document also destroys the isolated picker listeners and highlights.
    }
}
