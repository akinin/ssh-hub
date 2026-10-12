import Foundation

// A small offline Markdown renderer. Raw HTML is text, and links only allow explicit
// web/mail schemes. Images, scripts and network resources are never loaded implicitly.
enum DocumentationMarkdown {
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }
    static func safeLink(_ text: String) -> Bool {
        guard !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), ["https", "http", "mailto"].contains(scheme) else { return false }
        return scheme == "mailto" || url.host?.isEmpty == false
    }
    static func inline(_ text: String) -> String {
        var result = "", index = text.startIndex
        let markers = [("**", "strong"), ("__", "strong"), ("~~", "del"), ("*", "em"), ("_", "em")]
        while index < text.endIndex {
            let remaining = text[index...]
            if remaining.first == "\\" {
                let next = text.index(after: index)
                if next < text.endIndex { result += escape(String(text[next])); index = text.index(after: next); continue }
            }
            if remaining.first == "`", let end = text[text.index(after: index)...].firstIndex(of: "`") {
                result += "<code>" + escape(String(text[text.index(after: index)..<end])) + "</code>"
                index = text.index(after: end); continue
            }
            if remaining.first == "[", let labelEnd = remaining.firstIndex(of: "]"), text.index(after: labelEnd) < text.endIndex,
               text[text.index(after: labelEnd)] == "(", let end = text[text.index(labelEnd, offsetBy: 2)...].firstIndex(of: ")") {
                let label = String(text[text.index(after: index)..<labelEnd]), link = String(text[text.index(labelEnd, offsetBy: 2)..<end])
                if safeLink(link) { result += "<a href=\"" + escape(link) + "\">" + escape(label) + "</a>" }
                else { result += escape(String(text[index...end])) }
                index = text.index(after: end); continue
            }
            var matched = false
            for (marker, tag) in markers where remaining.hasPrefix(marker) {
                let start = text.index(index, offsetBy: marker.count)
                if let range = text.range(of: marker, range: start..<text.endIndex), range.lowerBound > start {
                    // Escape inner content rather than recursively parse arbitrary nested input.
                    result += "<\(tag)>" + escape(String(text[start..<range.lowerBound])) + "</\(tag)>"
                    index = range.upperBound; matched = true; break
                }
            }
            if matched { continue }
            result += escape(String(text[index])); index = text.index(after: index)
        }
        return result
    }
    static func body(_ markdown: String) -> String {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var html = "", index = 0
        func cells(_ line: String) -> [String] {
            var value = line.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("|") { value.removeFirst() }; if value.hasSuffix("|") { value.removeLast() }
            return value.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        while index < lines.count {
            let line = lines[index], trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { index += 1; continue }
            if trimmed.hasPrefix("```") {
                index += 1; var code: [String] = []
                while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") { code.append(lines[index]); index += 1 }
                if index < lines.count { index += 1 }
                html += "<pre><code>" + escape(code.joined(separator: "\n")) + "</code></pre>"; continue
            }
            if index + 1 < lines.count, line.contains("|") {
                let separator = cells(lines[index + 1])
                if !separator.isEmpty && separator.allSatisfy({ $0.filter { $0 == "-" }.count >= 3 && $0.allSatisfy { $0 == "-" || $0 == ":" || $0 == " " } }) {
                    html += "<div class=\"table\"><table><thead><tr>" + cells(line).map { "<th>" + inline($0) + "</th>" }.joined() + "</tr></thead><tbody>"
                    index += 2
                    while index < lines.count && lines[index].contains("|") && !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                        html += "<tr>" + cells(lines[index]).map { "<td>" + inline($0) + "</td>" }.joined() + "</tr>"; index += 1
                    }
                    html += "</tbody></table></div>"; continue
                }
            }
            let level = trimmed.prefix { $0 == "#" }.count
            if (1...6).contains(level), trimmed.dropFirst(level).hasPrefix(" ") {
                html += "<h\(level)>" + inline(String(trimmed.dropFirst(level + 1))) + "</h\(level)>"
            } else if ["---", "***", "___"].contains(trimmed) { html += "<hr>" }
            else if trimmed.hasPrefix("> ") { html += "<blockquote>" + inline(String(trimmed.dropFirst(2))) + "</blockquote>" }
            else if trimmed.hasPrefix("- [ ] ") || trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") {
                html += "<div class=\"list\">" + (trimmed.hasPrefix("- [ ]") ? "☐ " : "☑ ") + inline(String(trimmed.dropFirst(6))) + "</div>"
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                html += "<div class=\"list\">• " + inline(String(trimmed.dropFirst(2))) + "</div>"
            } else if let range = trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) {
                html += "<div class=\"list\">" + escape(String(trimmed[..<range.upperBound])) + inline(String(trimmed[range.upperBound...])) + "</div>"
            } else { html += "<p>" + inline(line) + "</p>" }
            index += 1
        }
        return html
    }
    static func page(_ markdown: String) -> String {
        """
        <!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="color-scheme" content="light dark">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src 'none'; base-uri 'none'; form-action 'none'">
        <style>:root{color-scheme:light dark}body{font:14px -apple-system,BlinkMacSystemFont,sans-serif;line-height:1.6;margin:24px;overflow-wrap:anywhere;color:CanvasText;background:Canvas}h1{font-size:26px}h2{font-size:21px}h3{font-size:17px}h1,h2{border-bottom:1px solid #8885;padding-bottom:6px}p{margin:8px 0}a{color:#368bfa}code{font:12px ui-monospace,monospace;background:#8882;border-radius:4px;padding:2px 4px}pre{overflow:auto;background:#8882;padding:12px;border-radius:8px}pre code{background:none;padding:0}blockquote{border-left:3px solid #8886;padding-left:14px;margin:10px 0;color:GrayText}hr{border:0;border-top:1px solid #8885;margin:16px 0}.list{padding-left:12px;margin:4px 0}.table{overflow:auto}table{border-collapse:collapse;min-width:50%}td,th{border:1px solid #8885;text-align:left;padding:6px 10px}th{background:#8882}</style></head><body>\(body(markdown))</body></html>
        """
    }
}
