import SwiftUI
import WebKit

struct VisualDocumentationEditor: NSViewRepresentable {
    @Binding var text: String
    let controller: DocumentationEditorController
    let save: () -> Void
    let find: () -> Void
    let error: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(context.coordinator, name: "documentation")
        config.userContentController.addUserScript(WKUserScript(source: DocumentationVisual.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        controller.webView = view
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        controller.webView = view
        guard context.coordinator.last != text else { return }
        context.coordinator.last = text
        view.loadHTMLString(DocumentationVisual.page(text), baseURL: nil)
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "documentation")
        if coordinator.parent.controller.webView === view { coordinator.parent.controller.webView = nil }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WKWebView, context: Context) -> CGSize? {
        CGSize(width: proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 0, height: proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? 0)
    }
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: VisualDocumentationEditor
        var last: String?
        init(_ parent: VisualDocumentationEditor) { self.parent = parent }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: String] else { return }
            switch body["type"] {
            case "change":
                guard let text = body["value"], text.utf8.count <= DocumentationRepository.maximumBytes else { return }
                last = text; parent.text = text
            case "save": parent.save()
            case "find": parent.find()
            case "error": parent.error(body["value"] ?? "Не удалось изменить документ.")
            default: break
            }
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.request.url?.absoluteString == "about:blank" && action.navigationType != .linkActivated ? .allow : .cancel)
        }
    }
}
