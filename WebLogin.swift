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
    const visible = e => !e.disabled && !e.readOnly && e.getClientRects().length && getComputedStyle(e).visibility !== 'hidden' && getComputedStyle(e).display !== 'none';
    const passwords = [...document.querySelectorAll('input[type="password"]')].filter(visible);
    if (passwords.length !== 1) return passwords.length ? 'ambiguous' : 'waiting';
    const password = passwords[0], form = password.form;
    const scope = form || document;
    const inputs = [...scope.querySelectorAll('input')].filter(visible);
    if (password.autocomplete.split(/\s+/).includes('new-password') || inputs.some(e => /one-time-code/i.test(e.autocomplete) || /(^|[-_])(otp|totp|captcha|verification|mfa|code|authcode)([-_]|$)/i.test(e.name + '-' + e.id))) return 'manual';
    const users = inputs.filter(e => ['text', 'email', 'tel'].includes(e.type) && e !== password && !/search/i.test(e.name + ' ' + e.id));
    const preferred = users.filter(e => e.autocomplete === 'username' || e.type === 'email' || /user|login|email|account/i.test(e.name + ' ' + e.id));
    const user = preferred.length === 1 ? preferred[0] : users.length === 1 ? users[0] : null;
    if (!user) return 'ambiguous';
    if ([...document.querySelectorAll('iframe')].some(e => /captcha|turnstile/i.test(e.src)) || document.querySelector('[data-sitekey]')) return 'manual';
    if (form && new URL(form.action || location.href, location.href).origin !== origin) return 'origin';
    const loginLabel = e => /^(log[ -]?in|sign[ -]?in|войти|вход|подключиться|авторизоваться)$/i.test((e.innerText || e.value || e.getAttribute('aria-label') || '').trim());
    const submits = [...scope.querySelectorAll('button, input[type="submit"]')].filter(e => visible(e) && (e.type === 'submit' || loginLabel(e)));
    if (submits.length !== 1) return 'ambiguous';
    const button = submits[0];
    if (!loginLabel(button)) return 'manual';
    if (button.formAction && new URL(button.formAction, location.href).origin !== origin) return 'origin';
    const method = button.hasAttribute('formmethod') ? button.formMethod : form?.method;
    // Ordinary GET forms can expose a password in a URL. JS-only buttons are supported.
    const post = form && method?.toLowerCase() === 'post';
    if (!post && button.type !== 'button') return 'manual';
    if (user.value && user.value !== username && operation !== 'probe') return 'manual';
    if (password.value) return 'manual';
    if (operation === 'probe') return 'ready';
    const set = (element, value) => {
      Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(element, value);
      element.dispatchEvent(new Event('input', {bubbles:true}));
      element.dispatchEvent(new Event('change', {bubbles:true}));
    };
    set(user, username); set(password, secret);
    // Input handlers may re-render or switch the form. Do not submit a changed destination.
    if (location.origin !== origin || !user.isConnected || !password.isConnected || !button.isConnected ||
        (form && new URL(form.action || location.href, location.href).origin !== origin) ||
        (button.formAction && new URL(button.formAction, location.href).origin !== origin) ||
        user.form !== form || password.form !== form ||
        (post && (button.hasAttribute('formmethod') ? button.formMethod : form?.method)?.toLowerCase() !== 'post') ||
        (!post && button.type !== 'button')) return 'filled';
    if (post && button.type === 'submit') form.requestSubmit(button);
    else button.click();
    return 'submitted';
    """#
    @MainActor static func run(in view: WKWebView, origin: URL, username: String = "", password: String = "", probe: Bool) async throws -> String {
        let result = try await view.callAsyncJavaScript(script, arguments: ["origin": originString(origin), "operation": probe ? "probe" : "fill", "username": username, "secret": password], in: nil, contentWorld: .defaultClient)
        return result as? String ?? "manual"
    }
    static func originString(_ url: URL) -> String {
        guard let origin = WebLoginOrigin(url) else { return "" }
        let host = origin.host.contains(":") && !origin.host.hasPrefix("[") ? "[" + origin.host + "]" : origin.host
        return origin.scheme + "://" + host + ((origin.scheme == "https" && origin.port == 443) || (origin.scheme == "http" && origin.port == 80) ? "" : ":" + String(origin.port))
    }
}
