import AppKit
import WebKit

// A private, headless WKWebView exercises the same editing engine as the application.
// It uses only generated documents; no user files or network destinations are opened.
@main @MainActor final class DocumentationVisualTests: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var view: WKWebView!
    var window: NSWindow!
    var finished = false
    var failure: String?
    var changes: [String] = []
    static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        let test = DocumentationVisualTests(); test.start()
        let deadline = Date().addingTimeInterval(30)
        while !test.finished && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        if let failure = test.failure { fputs("Visual documentation tests failed: \(failure)\n", stderr); exit(1) }
        guard test.finished else { fputs("Visual documentation tests timed out\n", stderr); exit(1) }
        print("Visual documentation tests passed: Markdown roundtrip, formatting, lists, tables, code, selection, search/replace, undo and safe paste")
    }
    func start() {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        config.userContentController.add(self, name: "documentation")
        config.userContentController.addUserScript(WKUserScript(source: DocumentationVisual.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        view = WKWebView(frame: NSRect(x: 0, y: 0, width: 700, height: 500), configuration: config); view.navigationDelegate = self
        window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false); window.contentView = view
        view.loadHTMLString(DocumentationVisual.page("# Сервер\n**Важное** и *курсив*\n- первый\n- [x] готово\n| Порт | Значение |\n| --- | --- |\n| SSH | 22 |\n```sh\nprintf '<script>'\n```\n[сайт](https://example.test)\n<script>window.evil=true</script>"), baseURL: nil)
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: String], body["type"] == "change", let value = body["value"] { changes.append(value) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.callAsyncJavaScript(#"""
        return await (async () => {
          const assert = (condition, message) => { if (!condition) throw Error(message); };
          const root = document.getElementById('editor'), editor = window.hubEditor;
          assert(editor, 'editor script is available under CSP');
          const roundtrip = editor.serialize();
          assert(roundtrip.includes('# Сервер') && roundtrip.includes('**Важное**') && roundtrip.includes('*курсив*'), 'headings and inline formatting');
          assert(roundtrip.includes('- первый') && roundtrip.includes('- [x] готово'), 'lists and checked tasks');
          assert(roundtrip.includes('| SSH | 22 |') && roundtrip.includes("printf '<script>'"), 'table and code remain');
          assert(!window.evil && !root.querySelector('script') && !root.querySelector('img'), 'raw HTML does not execute');
          root.innerHTML = '<b>жирный</b> текст <i>курсив</i>';
          assert(editor.serialize() === '**жирный** текст *курсив*', 'formatting in a newly typed root preserves inline text');
          root.innerHTML = '<p>слово второй слово</p>';
          assert(editor.find('слово', false, null), 'first match');
          assert(window.getSelection().toString() === 'слово', 'selection is a found word');
          editor.command('bold');
          assert(editor.serialize().includes('**слово**'), 'toolbar formats selected text');
          assert(editor.find('второй', false, null), 'second word found');
          await new Promise(resolve => setTimeout(resolve, 20));
          editor.find('второй', false, 'замена');
          assert(editor.serialize().includes('замена') && !editor.serialize().includes('второй'), 'replace selected match');
          await new Promise(resolve => setTimeout(resolve, 20));
          document.execCommand('undo');
          assert(editor.serialize().includes('второй'), 'undo restores replaced text: ' + editor.serialize() + ' / undo=' + document.queryCommandEnabled('undo'));
          assert(!editor.find('отсутствует', false, null), 'missing query is reported');
          root.innerHTML = '<p><strong>жирный <em>курсив</em></strong></p><table><tr><th>A</th><th>B</th></tr><tr><td>x|y</td><td>значение</td></tr></table>';
          assert(editor.serialize().includes('**жирный *курсив***'), 'nested formatting');
          assert(editor.serialize().includes('x\\|y'), 'table separator escapes');
          root.innerHTML = '<p>До</p>';
          const range = document.createRange(); range.selectNodeContents(root.firstChild); range.collapse(false);
          window.getSelection().removeAllRanges(); window.getSelection().addRange(range);
          document.dispatchEvent(new Event('selectionchange'));
          const paste = new Event('paste', {bubbles:true,cancelable:true});
          Object.defineProperty(paste,'clipboardData',{value:{getData: () => '<img src=https://example.test onerror=evil()> После'}});
          root.dispatchEvent(paste);
          assert(!root.querySelector('img') && root.textContent.includes('<img'), 'paste inserts literal plain text');
          return 'ok';
        })()
        """#, arguments: [:], in: nil, in: .page) { result in
            switch result {
            case .failure(let error): self.failure = String(describing: (error as NSError).userInfo)
            case .success(let value): if value as? String != "ok" { self.failure = "unexpected result" }
            }
            self.view.configuration.userContentController.removeScriptMessageHandler(forName: "documentation")
            self.finished = true
        }
    }
}
