import AppKit

/// Minimal HTML → attributed-text converter used for Markdown, EPUB and .html inputs.
///
/// It replaces Apple's WebKit-based HTML importer on purpose: that importer can fetch remote images and
/// stylesheets, which would break the "everything stays on your Mac" promise. This walker only reads the parsed
/// tree (libxml2, no entity or network loading) and never touches a URL, image, script or stylesheet.
enum HTMLToAttributed {
    static func build(_ html: String) throws -> NSAttributedString {
        let inner = DocIO.bodyInner(html)
        let wrapped = "<html><head><meta charset=\"utf-8\"/></head><body>\(inner)</body></html>"
        guard let doc = try? XMLDocument(data: Data(wrapped.utf8),
                                         options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]) else {
            throw ConvError.failed("Couldn’t parse the HTML.")
        }
        let b = Builder()
        if let body = (try? doc.nodes(forXPath: "//body"))?.first { b.walk(body, depth: 0) }
        return b.finish()
    }

    private final class Builder {
        struct Style {
            var size: CGFloat = 12
            var bold = false
            var italic = false
            var mono = false
            var link: String?
        }

        let out = NSMutableAttributedString()
        var style = Style()
        var pre = false
        var quote = 0
        var lists: [(ordered: Bool, index: Int)] = []
        var nl = 2                 // trailing newlines already in `out` (start of document counts as a break)
        var lastIsSpace = false

        static let skip: Set<String> = ["script", "style", "head", "title", "meta", "link", "iframe", "object", "embed",
                                        "noscript", "svg", "canvas", "audio", "video", "template", "math", "applet"]
        static let headingSizes: [String: CGFloat] = ["h1": 24, "h2": 20, "h3": 17, "h4": 15, "h5": 13, "h6": 13]
        static let blocks: Set<String> = ["p", "div", "section", "article", "header", "footer", "main", "nav", "aside",
                                          "figure", "figcaption", "address", "details", "summary", "dl", "dt", "dd",
                                          "fieldset", "form"]

        func walk(_ node: XMLNode, depth: Int) {
            if depth > 200 {                       // pathological nesting: keep the text, stop recursing
                append(node.stringValue ?? "")
                return
            }
            switch node.kind {
            case .text:
                appendText(node.stringValue ?? "")
            case .element:
                if let el = node as? XMLElement { element(el, depth: depth) }
            default:
                break
            }
        }

        private func element(_ el: XMLElement, depth: Int) {
            let name = (el.name ?? "").lowercased()
            if Builder.skip.contains(name) { return }
            let savedStyle = style
            let savedPre = pre
            let savedQuote = quote
            defer { style = savedStyle; pre = savedPre; quote = savedQuote }

            func children() {
                for c in el.children ?? [] { walk(c, depth: depth + 1) }
            }

            switch name {
            case "br":
                append("\n")
            case "hr":
                ensureBreak(1)
                append("────────────\n")
            case "img":
                // Never load the image; keep its alt text so the information isn't silently lost.
                if let alt = el.attribute(forName: "alt")?.stringValue,
                   !alt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    appendText("[\(alt)]")
                }
            case "h1", "h2", "h3", "h4", "h5", "h6":
                ensureBreak(2)
                style.size = Builder.headingSizes[name] ?? 13
                style.bold = true
                children()
                ensureBreak(2)
            case "b", "strong":
                style.bold = true
                children()
            case "i", "em", "cite", "dfn", "var":
                style.italic = true
                children()
            case "code", "kbd", "samp", "tt":
                style.mono = true
                children()
            case "pre":
                ensureBreak(2)
                style.mono = true
                pre = true
                children()
                ensureBreak(2)
            case "a":
                if let href = el.attribute(forName: "href")?.stringValue, Markdown.isSafeLink(href) { style.link = href }
                children()
            case "blockquote":
                ensureBreak(2)
                quote += 1
                style.italic = true
                children()
                ensureBreak(2)
            case "ul", "ol":
                ensureBreak(lists.isEmpty ? 2 : 1)
                lists.append((ordered: name == "ol", index: 0))
                children()
                lists.removeLast()
                ensureBreak(lists.isEmpty ? 2 : 1)
            case "li":
                ensureBreak(1)
                var marker = "• "
                if !lists.isEmpty {
                    lists[lists.count - 1].index += 1
                    if lists[lists.count - 1].ordered { marker = "\(lists[lists.count - 1].index). " }
                }
                append(String(repeating: "    ", count: max(0, lists.count - 1)) + marker)
                children()
                ensureBreak(1)
            case "table":
                ensureBreak(2)
                children()
                ensureBreak(2)
            case "tr":
                ensureBreak(1)
                children()
                ensureBreak(1)
            case "th":
                style.bold = true
                children()
                append("\t")
            case "td":
                children()
                append("\t")
            default:
                if Builder.blocks.contains(name) {
                    ensureBreak(2)
                    children()
                    ensureBreak(2)
                } else {
                    children()
                }
            }
        }

        // MARK: Output helpers

        private func font() -> NSFont {
            let weight: NSFont.Weight = style.bold ? .bold : .regular
            var f: NSFont = style.mono
                ? NSFont.monospacedSystemFont(ofSize: max(9, style.size - 1), weight: weight)
                : NSFont.systemFont(ofSize: style.size, weight: weight)
            if style.italic {
                let d = f.fontDescriptor.withSymbolicTraits(f.fontDescriptor.symbolicTraits.union(.italic))
                f = NSFont(descriptor: d, size: f.pointSize) ?? f
            }
            return f
        }

        private func attrs() -> [NSAttributedString.Key: Any] {
            var a: [NSAttributedString.Key: Any] = [.font: font()]
            if quote > 0 {
                let ps = NSMutableParagraphStyle()
                ps.firstLineHeadIndent = CGFloat(quote) * 18
                ps.headIndent = CGFloat(quote) * 18
                a[.paragraphStyle] = ps
            }
            if let l = style.link, let u = URL(string: l) { a[.link] = u }
            return a
        }

        private func track(_ s: String) {
            var c = 0
            for ch in s.reversed() {
                if ch == "\n" { c += 1 } else { break }
            }
            if c == s.count { nl += c } else { nl = c }
            lastIsSpace = (s.last == " ")
        }

        private func append(_ s: String) {
            guard !s.isEmpty else { return }
            out.append(NSAttributedString(string: s, attributes: attrs()))
            track(s)
        }

        private func appendText(_ raw: String) {
            var s = raw
            if !pre {
                s = s.replacingOccurrences(of: "[ \\t\\r\\n]+", with: " ", options: .regularExpression)
                if nl > 0 || lastIsSpace { s = String(s.drop(while: { $0 == " " })) }
            }
            append(s)
        }

        private func ensureBreak(_ n: Int) {
            guard out.length > 0 else { return }
            while nl < n { append("\n") }
        }

        func finish() -> NSAttributedString {
            while out.length > 0 && out.string.hasSuffix("\n") {
                out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
            }
            return out
        }
    }
}
