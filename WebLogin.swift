import Foundation
import WebKit

// Credentials belong to one exact scheme/host/port, never a redirected origin or proxy.
struct WebLoginOrigin: Equatable {
    let scheme: String
    let host: String
    let port: Int
    init?(_ url: URL?) {
        guard let url, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let rawHost = url.host?.lowercased(), !rawHost.isEmpty, url.user == nil, url.password == nil,
              (1...65535).contains(url.port ?? (scheme == "https" ? 443 : 80)) else { return nil }
        self.scheme = scheme; self.host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]")); port = url.port ?? (scheme == "https" ? 443 : 80)
    }
    func matches(_ space: URLProtectionSpace) -> Bool {
        !space.isProxy() && space.protocol?.lowercased() == scheme && space.host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")) == host && space.port == port
            && [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest].contains(space.authenticationMethod)
    }
}

enum WebLoginForm {
    // Run in WebKit's isolated client world. Values are named arguments, never script source.
    // Probe before reading Keychain. Recheck everything in fill to cover navigation/DOM changes.
    static let script = #"""
    if (window !== window.top || location.origin !== origin) return 'origin';
    const visible = e => e && (!e.disabled || selectors !== null && validButton(e)) && !e.readOnly && e.getClientRects().length && getComputedStyle(e).visibility !== 'hidden' && getComputedStyle(e).display !== 'none';
    const roleButton = e => {
      if (!(e instanceof HTMLElement) || e.matches('input,button') || e.getAttribute('role') !== 'button') return false;
      if (e instanceof HTMLAnchorElement) {
        const href = (e.getAttribute('href') || '').toLowerCase().replace(/\s+/g,'');
        return ['', '#', 'javascript:;', 'javascript:void(0)', 'javascript:void(0);'].includes(href) && !e.parentElement?.closest('button,a[href]');
      }
      return !e.matches('[href]') && !e.closest('button,a[href]');
    };
    const validButton = e => roleButton(e) || (e instanceof HTMLButtonElement || e instanceof HTMLInputElement) && ['submit','button'].includes(e.type);
    const jsButton = e => roleButton(e) || e.type === 'button';
    const owner = e => roleButton(e) ? e.closest('form') : e.form;
    const manual = selectors !== null;
    const associated = (e, f) => owner(e) === f || (manual && jsButton(e) && owner(e) === null);
    const first = stage === 'username', second = stage === 'password';
    const unique = selector => { const matches = document.querySelectorAll(selector); return matches.length === 1 && visible(matches[0]) ? matches[0] : null; };
    let user, password, button, form;
    if (manual) {
      try { user = second ? null : unique(selectors.username); password = first ? null : unique(selectors.password); button = unique(first ? selectors.next : selectors.submit); }
      catch (_) { return 'selectors'; }
      if ((!second && !user) || (!first && !password) || !button) return 'waiting';
      if ((!second && (!(user instanceof HTMLInputElement) || !['text','email','tel'].includes(user.type))) ||
          (!first && (!(password instanceof HTMLInputElement) || password.type !== 'password')) ||
          !validButton(button)) return 'manual';
      form = (first ? user : password).form;
      if ((!second && user.form !== form) || !associated(button, form)) return 'manual';
    } else {
      const passwords = [...document.querySelectorAll('input[type="password"]')].filter(visible);
      if (passwords.length !== 1) return passwords.length ? 'ambiguous' : 'waiting';
      password = passwords[0]; form = password.form;
    }
    const scope = form || document;
    const inputs = [...scope.querySelectorAll('input')].filter(visible);
    if ((!first && password.autocomplete.split(/\s+/).includes('new-password')) ||
        inputs.filter(e => e.type === 'password').length !== (first ? 0 : 1) ||
        inputs.some(e => /one-time-code/i.test(e.autocomplete) || /(^|[-_])(otp|totp|captcha|verification|mfa|code|authcode)([-_]|$)/i.test(e.name + '-' + e.id))) return 'manual';
    if (!manual) {
      const users = inputs.filter(e => ['text', 'email', 'tel'].includes(e.type) && e !== password && !/search/i.test(e.name + ' ' + e.id));
      const preferred = users.filter(e => e.autocomplete === 'username' || e.type === 'email' || /user|login|email|account/i.test(e.name + ' ' + e.id));
      user = preferred.length === 1 ? preferred[0] : users.length === 1 ? users[0] : null;
      if (!user) return 'ambiguous';
    }
    if ([...document.querySelectorAll('iframe')].some(e => /captcha|turnstile/i.test(e.src)) || document.querySelector('[data-sitekey]')) return 'manual';
    if (form && new URL(form.action || location.href, location.href).origin !== origin) return 'origin';
    if (!manual) {
      const loginLabel = e => /^(log[ -]?in|sign[ -]?in|войти|вход|подключиться|авторизоваться)$/i.test((e.innerText || e.value || e.getAttribute('aria-label') || '').trim());
      const submits = [...scope.querySelectorAll('button, input[type="submit"]')].filter(e => visible(e) && (e.type === 'submit' || loginLabel(e)));
      if (submits.length !== 1) return 'ambiguous';
      button = submits[0];
      if (!loginLabel(button)) return 'manual';
    }
    if (!associated(button, form)) return 'manual';
    if (button.formAction && new URL(button.formAction, location.href).origin !== origin) return 'origin';
    const method = button.hasAttribute('formmethod') ? button.formMethod : form?.method;
    // Explicit JS form selection may use the default GET method. Dispatch only a
    // cancelable submit event to its handler; never invoke native GET submission.
    const post = form && method?.toLowerCase() === 'post';
    const scripted = manual && form && owner(button) === form && button.type === 'submit' && method?.toLowerCase() === 'get';
    if (!post && !scripted && !jsButton(button)) return 'manual';
    if (user?.value && user.value !== username && operation !== 'probe') return 'manual';
    if (password?.value) return 'manual';
    if (operation === 'probe') return 'ready';
    const set = (element, value) => {
      Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(element, value);
      element.dispatchEvent(new Event('input', {bubbles:true}));
      element.dispatchEvent(new Event('change', {bubbles:true}));
    };
    if (!second) set(user, username); if (!first) set(password, secret);
    // Vue and similar forms enable their external role=button in the next DOM update.
    await new Promise(resolve => setTimeout(resolve, 0));
    // Input handlers may re-render or switch the form. Do not submit a changed destination.
    let sameSelection = true;
    if (manual) { try { sameSelection = (second || unique(selectors.username) === user) && (first || unique(selectors.password) === password) && unique(first ? selectors.next : selectors.submit) === button; } catch (_) { sameSelection = false; } }
    if (!sameSelection || location.origin !== origin || (!second && !user.isConnected) || (!first && !password.isConnected) || !button.isConnected || !validButton(button) || !visible(button) || button.disabled || button.getAttribute('aria-disabled') === 'true' ||
        (form && new URL(form.action || location.href, location.href).origin !== origin) ||
        (button.formAction && new URL(button.formAction, location.href).origin !== origin) ||
        (!second && user.form !== form) || (!first && password.form !== form) || !associated(button, form) ||
        (post && (button.hasAttribute('formmethod') ? button.formMethod : form?.method)?.toLowerCase() !== 'post') ||
        (scripted && (button.type !== 'submit' || owner(button) !== form || (button.hasAttribute('formmethod') ? button.formMethod : form.method)?.toLowerCase() !== 'get')) ||
        (!post && !scripted && !jsButton(button))) return 'filled';
    if (scripted) {
      if (!form.checkValidity()) return 'filled';
      const event = new SubmitEvent('submit', {bubbles:true, cancelable:true, submitter:button});
      return form.dispatchEvent(event) ? 'filled' : 'submitted';
    }
    if (post && button.type === 'submit') form.requestSubmit(button);
    else button.click();
    return 'submitted';
    """#
    @MainActor static func run(in view: WKWebView, origin: URL, username: String = "", password: String = "", probe: Bool, selectors: WebLoginSelectors? = nil, stage: String = "combined") async throws -> String {
        if let selectors {
            let values = stage == "username" ? [selectors.username, selectors.next ?? ""] : stage == "password" ? [selectors.password, selectors.submit] : [selectors.username, selectors.password, selectors.submit]
            guard values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }), Set(values).count == values.count else { return "selectors" }
        } else if stage != "combined" { return "selectors" }
        let selection: Any = selectors.map { ["username": $0.username, "password": $0.password, "submit": $0.submit, "next": $0.next ?? ""] } ?? (NSNull() as Any)
        let result = try await view.callAsyncJavaScript(script, arguments: ["origin": originString(origin), "operation": probe ? "probe" : "fill", "username": username, "secret": password, "selectors": selection, "stage": stage], in: nil, contentWorld: .defaultClient)
        return result as? String ?? "manual"
    }
    static func originString(_ url: URL) -> String {
        guard let origin = WebLoginOrigin(url) else { return "" }
        let host = origin.host.contains(":") && !origin.host.hasPrefix("[") ? "[" + origin.host + "]" : origin.host
        return origin.scheme + "://" + host + ((origin.scheme == "https" && origin.port == 443) || (origin.scheme == "http" && origin.port == 80) ? "" : ":" + String(origin.port))
    }
}
