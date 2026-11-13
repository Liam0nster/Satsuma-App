import Foundation
import AppKit
import PDFKit

// MARK: - Documents (DOCX / Pages / MD / TXT / RTF / HTML / EPUB)

enum DocConv {
    static func convert(_ src: URL, from: String, to: String) throws -> URL {
        let out = Output.destination(for: src, ext: to)
        // Markdown → HTML / EPUB directly, for clean output.
        if from == "md" && (to == "html" || to == "epub") {
            let md = try String(contentsOf: src, encoding: .utf8)
            let html = Markdown.toHTML(md)
            if to == "html" {
                // The file name is escaped (it is attacker-controlled), and the CSP blocks scripts even if markup slips through.
                let page = "<!DOCTYPE html><html><head><meta charset=\"utf-8\">"
                    + "<meta http-equiv=\"Content-Security-Policy\" content=\"script-src 'none'; object-src 'none'; base-uri 'none'\">"
                    + "<title>\(Markdown.esc(Output.baseName(src)))</title></head><body>\(html)</body></html>"
                try page.write(to: out, atomically: true, encoding: .utf8)
            } else {
                try EpubBuilder.build(title: Output.baseName(src), bodyHTML: html, to: out)
            }
            return out
        }
        if from == "pages" && to == "docx" {
            try Pages.export(src, out, as: "Microsoft Word")
            return out
        }
        let attr = try DocIO.load(src, from: from)
        try DocIO.save(attr, to: out, ext: to, title: Output.baseName(src))
        return out
    }
}

enum DocIO {
    static func load(_ url: URL, from: String) throws -> NSAttributedString {
        switch from {
        case "md":
            let md = try String(contentsOf: url, encoding: .utf8)
            return try HTMLToAttributed.build(Markdown.toHTML(md))
        case "html":
            let raw = try Data(contentsOf: url)
            let s = String(data: raw, encoding: .utf8) ?? String(data: raw, encoding: .isoLatin1) ?? ""
            return try HTMLToAttributed.build(s)
        case "txt":
            let s: String
            if let utf8 = try? String(contentsOf: url, encoding: .utf8) { s = utf8 }
            else { s = try String(contentsOf: url, encoding: .isoLatin1) }
            return NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: 12)])
        case "textclipping":
            guard let s = TextClipping.read(url) else { throw ConvError.failed("Couldn’t read this text clipping.") }
            return NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: 12)])
        case "epub":
            return try HTMLToAttributed.build(try EpubReader.html(from: url))
        case "pages":
            let tmp = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: tmp) }
            let docx = tmp.appendingPathComponent("in.docx")
            try Pages.export(url, docx, as: "Microsoft Word")
            return try loadFile(docx)
        default:
            return try loadFile(url)
        }
    }

    static func loadFile(_ url: URL) throws -> NSAttributedString {
        try onMain { try NSAttributedString(url: url, options: [:], documentAttributes: nil) }
    }

    // Note: there is deliberately no NSAttributedString(html:) import here. Apple's HTML importer is WebKit-based and
    // can fetch remote images/stylesheets. All HTML goes through HTMLToAttributed (see HTMLText.swift) instead.

    static func save(_ a: NSAttributedString, to out: URL, ext: String, title: String) throws {
        let r = NSRange(location: 0, length: a.length)
        switch ext {
        case "docx":
            let d = try onMain { try a.data(from: r, documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]) }
            try d.write(to: out)
        case "html":
            let d = try onMain { try a.data(from: r, documentAttributes: [.documentType: NSAttributedString.DocumentType.html]) }
            try d.write(to: out)
        case "txt":
            try a.string.write(to: out, atomically: true, encoding: .utf8)
        case "md":
            try Markdown.from(a).write(to: out, atomically: true, encoding: .utf8)
        case "pdf":
            try pdf(a, to: out)
        case "epub":
            let d = try onMain { try a.data(from: r, documentAttributes: [.documentType: NSAttributedString.DocumentType.html]) }
            let html = String(decoding: d, as: UTF8.self)
            try EpubBuilder.build(title: title, bodyHTML: bodyInner(html), to: out)
        case "pages":
            let tmp = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: tmp) }
            let docx = tmp.appendingPathComponent("in.docx")
            try save(a, to: docx, ext: "docx", title: title)
            try Pages.fromDocx(docx, out)
        default:
            throw ConvError.unsupported("Can’t write .\(ext).")
        }
    }

    static func bodyInner(_ html: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "<body[^>]*>(.*)</body>", options: [.dotMatchesLineSeparators, .caseInsensitive]),
              let m = re.firstMatch(in: html, range: NSRange(location: 0, length: (html as NSString).length)),
              m.numberOfRanges > 1 else { return html }
        return (html as NSString).substring(with: m.range(at: 1))
    }

    /// Paginated PDF using the system print machinery.
    static func pdf(_ a: NSAttributedString, to url: URL) throws {
        try onMain {
            let info = NSPrintInfo()
            info.paperSize = NSSize(width: 612, height: 792)
            info.topMargin = 54; info.bottomMargin = 54; info.leftMargin = 54; info.rightMargin = 54
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
            let width = info.paperSize.width - info.leftMargin - info.rightMargin
            let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
            tv.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
            tv.textContainer?.widthTracksTextView = true
            tv.isVerticallyResizable = true
            tv.textStorage?.setAttributedString(a)
            if let lm = tv.layoutManager, let tc = tv.textContainer {
                lm.ensureLayout(for: tc)
                tv.setFrameSize(NSSize(width: width, height: max(100, lm.usedRect(for: tc).height + 20)))
            }
            let op = NSPrintOperation(view: tv, printInfo: info)
            op.showsPrintPanel = false
            op.showsProgressPanel = false
            if !op.run() { throw ConvError.failed("Couldn’t create PDF.") }
        }
    }
}

// MARK: - Text clippings (best effort)

enum TextClipping {
    static func read(_ url: URL) -> String? {
        if let d = try? Data(contentsOf: url),
           let plist = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any],
           let uti = plist["UTI-Data"] as? [String: Any] {
            if let t = uti["public.utf8-plain-text"] as? Data, let s = String(data: t, encoding: .utf8) { return s }
            if let t = uti["public.utf16-plain-text"] as? Data, let s = String(data: t, encoding: .utf16BigEndian) { return s }
        }
        // Classic resource fork: first resource is length-prefixed text.
        let rsrc = URL(fileURLWithPath: url.path + "/..namedfork/rsrc")
        guard let d = try? Data(contentsOf: rsrc), d.count > 16 else { return nil }
        let bytes = [UInt8](d)
        func be32(_ at: Int) -> Int { bytes[at..<(at + 4)].reduce(0) { ($0 << 8) | Int($1) } }
        let dataOffset = be32(0)
        guard dataOffset + 4 < bytes.count else { return nil }
        let len = be32(dataOffset)
        guard len > 0, dataOffset + 4 + len <= bytes.count else { return nil }
        let payload = Data(bytes[(dataOffset + 4)..<(dataOffset + 4 + len)])
        if let s = String(data: payload, encoding: .utf16BigEndian), !s.contains("\u{FFFD}"), !s.isEmpty { return s }
        return String(data: payload, encoding: .macOSRoman)
    }
}

// MARK: - Markdown

enum Markdown {
    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    static func inline(_ s: String) -> String {
        var t = linkify(esc(s))
        let rules: [(String, String)] = [
            ("`([^`]+)`", "<code>$1</code>"),
            ("\\*\\*([^*]+)\\*\\*", "<strong>$1</strong>"),
            ("__([^_]+)__", "<strong>$1</strong>"),
            ("\\*([^*]+)\\*", "<em>$1</em>"),
            ("(?<![A-Za-z0-9])_([^_]+)_(?![A-Za-z0-9])", "<em>$1</em>")
        ]
        for (pat, rep) in rules {
            if let re = try? NSRegularExpression(pattern: pat) {
                t = re.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length), withTemplate: rep)
            }
        }
        return t
    }

    // MARK: Safe links and images

    /// Only http(s)/mailto links, fragments and relative paths survive. javascript:, data:, file: and protocol-relative
    /// URLs are dropped, so Markdown can't smuggle scripts or local-file references into the output.
    /// Input is already HTML-escaped (quotes included), so it can't break out of an attribute.
    static func safeURL(_ raw: String, image: Bool) -> String? {
        let u = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
        guard !u.isEmpty else { return nil }
        let lower = u.lowercased()
        if lower.hasPrefix("//") { return nil }
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return u }
        if !image && lower.hasPrefix("mailto:") { return u }
        if image && (lower.hasPrefix("data:image/png;") || lower.hasPrefix("data:image/jpeg;")
                     || lower.hasPrefix("data:image/gif;") || lower.hasPrefix("data:image/webp;")) { return u }
        if lower.hasPrefix("#") || lower.hasPrefix("/") || lower.hasPrefix("./") || lower.hasPrefix("../") { return u }
        if !lower.contains(":") { return u }     // plain relative path
        return nil
    }

    /// Link targets allowed on rich-text links (http, https, mailto only).
    static func isSafeLink(_ raw: String) -> Bool {
        let l = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return l.hasPrefix("http://") || l.hasPrefix("https://") || l.hasPrefix("mailto:")
    }

    private static func replaceMatches(_ pattern: String, in s: String, _ f: ([String]) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        var result = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            result += f((0..<m.numberOfRanges).map { ns.substring(with: m.range(at: $0)) })
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    static func linkify(_ escaped: String) -> String {
        var t = replaceMatches("!\\[([^\\]]*)\\]\\(([^)]+)\\)", in: escaped) { m in
            guard let u = safeURL(m[2], image: true) else { return m[1] }
            return "<img alt=\"\(m[1])\" src=\"\(u)\"/>"
        }
        t = replaceMatches("\\[([^\\]]+)\\]\\(([^)]+)\\)", in: t) { m in
            guard let u = safeURL(m[2], image: false) else { return m[1] }
            return "<a href=\"\(u)\">\(m[1])</a>"
        }
        return t
    }

    static func toHTML(_ md: String) -> String {
        let lines = md.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var out = ""
        var para: [String] = []
        var listKind: String?
        var inCode = false
        var code: [String] = []

        func flushPara() {
            if !para.isEmpty { out += "<p>" + inline(para.joined(separator: " ")) + "</p>\n"; para = [] }
        }
        func closeList() {
            if let k = listKind { out += "</\(k)>\n"; listKind = nil }
        }
        func match(_ pat: String, _ s: String) -> [String]? {
            guard let re = try? NSRegularExpression(pattern: pat),
                  let m = re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) else { return nil }
            return (0..<m.numberOfRanges).map { (s as NSString).substring(with: m.range(at: $0)) }
        }

        for line in lines {
            if line.hasPrefix("```") {
                if inCode { out += "<pre><code>" + esc(code.joined(separator: "\n")) + "</code></pre>\n"; code = []; inCode = false }
                else { flushPara(); closeList(); inCode = true }
                continue
            }
            if inCode { code.append(line); continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { flushPara(); closeList(); continue }
            if let m = match("^(#{1,6})\\s+(.*)$", trimmed) {
                flushPara(); closeList()
                out += "<h\(m[1].count)>\(inline(m[2]))</h\(m[1].count)>\n"
            } else if match("^(-{3,}|\\*{3,}|_{3,})$", trimmed) != nil {
                flushPara(); closeList(); out += "<hr/>\n"
            } else if let m = match("^[-*+]\\s+(.*)$", trimmed) {
                flushPara()
                if listKind != "ul" { closeList(); out += "<ul>\n"; listKind = "ul" }
                out += "<li>\(inline(m[1]))</li>\n"
            } else if let m = match("^\\d+[.)]\\s+(.*)$", trimmed) {
                flushPara()
                if listKind != "ol" { closeList(); out += "<ol>\n"; listKind = "ol" }
                out += "<li>\(inline(m[1]))</li>\n"
            } else if let m = match("^>\\s?(.*)$", trimmed) {
                flushPara(); closeList()
                out += "<blockquote>\(inline(m[1]))</blockquote>\n"
            } else {
                closeList()
                para.append(trimmed)
            }
        }
        if inCode { out += "<pre><code>" + esc(code.joined(separator: "\n")) + "</code></pre>\n" }
        flushPara(); closeList()
        return out
    }

    /// Converts styled text to Markdown using font size / bold / italic / links.
    static func from(_ a: NSAttributedString) -> String {
        let ns = a.string as NSString
        guard ns.length > 0 else { return "" }

        // Body font size = size covering the most characters.
        var sizeWeights: [Int: Int] = [:]
        a.enumerateAttribute(.font, in: NSRange(location: 0, length: ns.length)) { v, r, _ in
            if let f = v as? NSFont { sizeWeights[Int(f.pointSize.rounded()), default: 0] += r.length }
        }
        let body = Double(sizeWeights.max(by: { $0.value < $1.value })?.key ?? 12)

        let bulletRE = try? NSRegularExpression(pattern: "^\\s*[•◦▪‣·]\\s*")
        let numberRE = try? NSRegularExpression(pattern: "^\\s*(\\d+)[.)]\\s+")
        var lines: [String] = []
        var loc = 0
        while loc < ns.length {
            let pr = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            loc = NSMaxRange(pr)
            let sub = a.attributedSubstring(from: pr)
            let plain = sub.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if plain.isEmpty { lines.append(""); continue }

            var maxSize = 0.0
            var line = ""
            sub.enumerateAttributes(in: NSRange(location: 0, length: sub.length)) { attrs, range, _ in
                var text = (sub.string as NSString).substring(with: range).replacingOccurrences(of: "\n", with: "")
                if text.isEmpty { return }
                let font = attrs[.font] as? NSFont
                if let f = font, !text.trimmingCharacters(in: .whitespaces).isEmpty { maxSize = max(maxSize, Double(f.pointSize)) }
                let traits = font?.fontDescriptor.symbolicTraits ?? []
                let lead = String(text.prefix(while: { $0 == " " || $0 == "\t" }))
                let trail = String(text.reversed().prefix(while: { $0 == " " || $0 == "\t" }))
                var core = text.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
                if core.isEmpty { line += text; return }
                if traits.contains(.bold) && traits.contains(.italic) { core = "***\(core)***" }
                else if traits.contains(.bold) { core = "**\(core)**" }
                else if traits.contains(.italic) { core = "*\(core)*" }
                if let link = attrs[.link] { core = "[\(core)](\(link))" }
                text = lead + core + trail
                line += text
            }
            var l = line.trimmingCharacters(in: .whitespaces)
            let ratio = body > 0 ? maxSize / body : 1
            if ratio >= 1.25 {
                let level = ratio >= 2 ? 1 : (ratio >= 1.6 ? 2 : (ratio >= 1.4 ? 3 : 4))
                l = l.replacingOccurrences(of: "**", with: "")
                lines.append(String(repeating: "#", count: level) + " " + l)
            } else if let re = bulletRE, re.firstMatch(in: l, range: NSRange(location: 0, length: (l as NSString).length)) != nil {
                lines.append("- " + re.stringByReplacingMatches(in: l, range: NSRange(location: 0, length: (l as NSString).length), withTemplate: ""))
            } else if let re = numberRE, let m = re.firstMatch(in: l, range: NSRange(location: 0, length: (l as NSString).length)) {
                let n = (l as NSString).substring(with: m.range(at: 1))
                lines.append("\(n). " + re.stringByReplacingMatches(in: l, range: NSRange(location: 0, length: (l as NSString).length), withTemplate: ""))
            } else {
                lines.append(l)
            }
        }
        // Blank line between paragraphs (but keep list items tight).
        var out: [String] = []
        for (i, l) in lines.enumerated() {
            out.append(l)
            let isList = l.hasPrefix("- ") || l.range(of: "^\\d+\\. ", options: .regularExpression) != nil
            let nextIsList = i + 1 < lines.count && (lines[i + 1].hasPrefix("- ") || lines[i + 1].range(of: "^\\d+\\. ", options: .regularExpression) != nil)
            if !l.isEmpty, i + 1 < lines.count, !lines[i + 1].isEmpty, !(isList && nextIsList) { out.append("") }
        }
        return out.joined(separator: "\n").replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression) + "\n"
    }
}

// MARK: - EPUB

enum EpubBuilder {
    static func xhtml(_ html: String) -> String {
        let wrapped = "<html><head><meta charset=\"utf-8\"/></head><body>\(html)</body></html>"
        guard let doc = try? XMLDocument(data: Data(wrapped.utf8), options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]),
              let bodies = try? doc.nodes(forXPath: "//body"), let body = bodies.first as? XMLElement else {
            return "<p>" + Markdown.esc(html) + "</p>"
        }
        return (body.children ?? []).map { $0.xmlString(options: [.nodeCompactEmptyElement]) }.joined()
    }

    static func build(title: String, bodyHTML: String, to out: URL) throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let fm = FileManager.default
        try fm.createDirectory(at: tmp.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try fm.createDirectory(at: tmp.appendingPathComponent("OEBPS"), withIntermediateDirectories: true)
        let t = Markdown.esc(title)

        try "application/epub+zip".write(to: tmp.appendingPathComponent("mimetype"), atomically: true, encoding: .ascii)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """.write(to: tmp.appendingPathComponent("META-INF/container.xml"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="id">urn:uuid:\(UUID().uuidString)</dc:identifier>
            <dc:title>\(t)</dc:title>
            <dc:language>en</dc:language>
            <meta property="dcterms:modified">\(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: "\\.\\d+", with: "", options: .regularExpression))</meta>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="c1" href="chapter.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine><itemref idref="c1"/></spine>
        </package>
        """.write(to: tmp.appendingPathComponent("OEBPS/content.opf"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>\(t)</title></head>
        <body><nav epub:type="toc"><ol><li><a href="chapter.xhtml">\(t)</a></li></ol></nav></body></html>
        """.write(to: tmp.appendingPathComponent("OEBPS/nav.xhtml"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>\(t)</title></head>
        <body>\(xhtml(bodyHTML))</body></html>
        """.write(to: tmp.appendingPathComponent("OEBPS/chapter.xhtml"), atomically: true, encoding: .utf8)

        // The mimetype entry must be first and uncompressed.
        try Shell.run("/usr/bin/zip", ["-X", "-0", out.path, "mimetype"], cwd: tmp)
        try Shell.run("/usr/bin/zip", ["-X", "-r", "-9", out.path, "META-INF", "OEBPS"], cwd: tmp)
    }
}

enum EpubReader {
    /// Concatenates the spine's XHTML bodies into one HTML string (text-focused).
    static func html(from epub: URL) throws -> String {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Shell.run("/usr/bin/unzip", ["-q", "-o", epub.path, "-d", tmp.path], abortIf: Archives.bombGuard(tmp))
        // A hostile EPUB can contain symlinks (to ~/.ssh/id_rsa, say) or "../" paths in its manifest. Delete every
        // link, and below only ever read files whose resolved path is inside the extraction folder.
        Sanitize.prune(tmp, removeSymlinks: true)
        guard let containerURL = Sanitize.inside(tmp, tmp.appendingPathComponent("META-INF/container.xml")) else {
            throw ConvError.failed("Invalid EPUB.")
        }
        let container = try String(contentsOf: containerURL, encoding: .utf8)
        guard let opfPath = firstMatch("full-path=\"([^\"]+)\"", in: container) else { throw ConvError.failed("Invalid EPUB.") }
        guard let opfURL = Sanitize.inside(tmp, tmp.appendingPathComponent(opfPath.removingPercentEncoding ?? opfPath)) else {
            throw ConvError.failed("Invalid EPUB.")
        }
        let opf = try String(contentsOf: opfURL, encoding: .utf8)

        var hrefs: [String: String] = [:]
        for tag in allMatches("<item\\b[^>]*>", in: opf) {
            if let id = firstMatch("\\bid=\"([^\"]+)\"", in: tag), let href = firstMatch("\\bhref=\"([^\"]+)\"", in: tag) { hrefs[id] = href }
        }
        let order = allMatches("<itemref\\b[^>]*>", in: opf).compactMap { firstMatch("idref=\"([^\"]+)\"", in: $0) }
        var body = ""
        for id in order {
            guard let h = hrefs[id] else { continue }
            let decoded = h.removingPercentEncoding ?? h
            let candidate = opfURL.deletingLastPathComponent().appendingPathComponent(decoded)
            guard let file = Sanitize.inside(tmp, candidate),
                  let s = try? String(contentsOf: file, encoding: .utf8) else { continue }
            body += DocIO.bodyInner(s) + "\n"
            if body.utf8.count > 50_000_000 { break }      // cap the amount of text we will build
        }
        guard !body.isEmpty else { throw ConvError.failed("This EPUB has no readable text.") }
        return "<html><head><meta charset=\"utf-8\"></head><body>\(body)</body></html>"
    }

    static func firstMatch(_ pat: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pat),
              let m = re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)), m.numberOfRanges > 1 else { return nil }
        return (s as NSString).substring(with: m.range(at: 1))
    }

    static func allMatches(_ pat: String, in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pat) else { return [] }
        return re.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length)).map { (s as NSString).substring(with: $0.range) }
    }
}

// MARK: - Apple Pages (via AppleScript)

enum Pages {
    static var installed: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iWork.Pages") != nil
    }

    private static func requirePages() throws {
        guard installed else { throw ConvError.missingTool("Pages", "Install Apple Pages from the App Store.") }
    }

    /// `format` is a Pages export format name, e.g. "Microsoft Word" or "PDF".
    static func export(_ src: URL, _ out: URL, as format: String) throws {
        try requirePages()
        _ = try AppleScriptRunner.run("""
        on run argv
            set inPath to item 1 of argv
            set outPath to item 2 of argv
            tell application "Pages"
                set d to open (POSIX file inPath)
                export d to (POSIX file outPath) as \(format)
                close d saving no
            end tell
        end run
        """, [src.path, out.path])
    }

    static func fromDocx(_ src: URL, _ out: URL) throws {
        try requirePages()
        _ = try AppleScriptRunner.run("""
        on run argv
            set inPath to item 1 of argv
            set outPath to item 2 of argv
            tell application "Pages"
                set d to open (POSIX file inPath)
                save d in (POSIX file outPath)
                close d saving no
            end tell
        end run
        """, [src.path, out.path])
    }
}

// MARK: - Office formats via LibreOffice

enum Office {
    /// Settings written into every throw-away LibreOffice profile: macros off, linked content never updated.
    static let lockdownXCU = """
    <?xml version="1.0" encoding="UTF-8"?>
    <oor:items xmlns:oor="http://openoffice.org/2001/registry" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
    <item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="MacroSecurityLevel" oor:op="fuse"><value>3</value></prop></item>
    <item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="DisableMacrosExecution" oor:op="fuse"><value>true</value></prop></item>
    <item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="BlockUntrustedRefererLinks" oor:op="fuse"><value>true</value></prop></item>
    <item oor:path="/org.openoffice.Office.Calc/Content/Update"><prop oor:name="Link" oor:op="fuse"><value>2</value></prop></item>
    <item oor:path="/org.openoffice.Office.Writer/Content/Update"><prop oor:name="Link" oor:op="fuse"><value>2</value></prop></item>
    </oor:items>
    """

    /// Converts with LibreOffice and returns the produced file in a temp folder (caller moves it).
    static func convert(_ src: URL, format: String, infilter: String? = nil) throws -> URL {
        let exe = try Ext.require("soffice")
        let tmp = try makeTempDir()
        // One private profile per job: no shared state between runs, and our lockdown settings are always in place.
        let profile = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: profile) }
        let userDir = profile.appendingPathComponent("user")
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        try lockdownXCU.write(to: userDir.appendingPathComponent("registrymodifications.xcu"), atomically: true, encoding: .utf8)
        var args = ["-env:UserInstallation=" + profile.absoluteString, "--headless", "--norestore"]
        if let f = infilter { args.append("--infilter=\(f)") }
        args += ["--convert-to", format, "--outdir", tmp.path, src.path]
        do {
            try Shell.run(exe, args, offline: true)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? []
        guard let first = files.first else {
            try? FileManager.default.removeItem(at: tmp)
            throw ConvError.failed("LibreOffice produced no output.")
        }
        return first
    }
}

enum OfficeConv {
    static let csvOut = "csv:Text - txt - csv (StarCalc):44,34,76,1"
    static let tsvOut = "csv:Text - txt - csv (StarCalc):9,34,76,1"

    static func convert(_ src: URL, from: String, to: String) throws -> URL {
        let cat = Formats.map[from]
        if cat == .slides {
            let pdf = try Office.convert(src, format: "pdf")
            defer { try? FileManager.default.removeItem(at: pdf.deletingLastPathComponent()) }
            if to == "pdf" {
                let out = Output.destination(for: src, ext: "pdf")
                try FileManager.default.moveItem(at: pdf, to: out)
                return out
            }
            guard let doc = PDFDocument(url: pdf) else { throw ConvError.failed("Couldn’t read converted slides.") }
            return try PDFConv.images(doc, src, to)
        }

        // Spreadsheets
        if (from == "csv" && to == "tsv") || (from == "tsv" && to == "csv") {
            return try swapDelimiter(src, from: from, to: to)
        }
        let format: String
        switch to {
        case "xlsx": format = "xlsx:Calc MS Excel 2007 XML"
        case "ods": format = "ods"
        case "csv": format = csvOut
        case "tsv": format = tsvOut
        case "pdf": format = "pdf:calc_pdf_Export"
        default: throw ConvError.unsupported("Unsupported spreadsheet target.")
        }
        var infilter: String?
        if from == "csv" { infilter = "CSV:44,34,76,1" }
        if from == "tsv" { infilter = "CSV:9,34,76,1" }
        let produced = try Office.convert(src, format: format, infilter: infilter)
        defer { try? FileManager.default.removeItem(at: produced.deletingLastPathComponent()) }
        let out = Output.destination(for: src, ext: to)
        try FileManager.default.moveItem(at: produced, to: out)
        return out
    }

    /// Native CSV ↔ TSV with quote handling.
    static func swapDelimiter(_ src: URL, from: String, to: String) throws -> URL {
        let text = try String(contentsOf: src, encoding: .utf8)
        let inDelim: Character = from == "csv" ? "," : "\t"
        let outDelim = to == "csv" ? "," : "\t"
        var rows: [[String]] = [[]]
        var cell = ""
        var quoted = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { cell.append("\""); i += 1 } else { quoted = false }
                } else { cell.append(c) }
            } else if c == "\"" { quoted = true }
            else if c == inDelim { rows[rows.count - 1].append(cell); cell = "" }
            else if c == "\n" || c == "\r\n" { rows[rows.count - 1].append(cell); cell = ""; rows.append([]) }
            else if c == "\r" { /* skip */ }
            else { cell.append(c) }
            i += 1
        }
        if !cell.isEmpty || !rows[rows.count - 1].isEmpty { rows[rows.count - 1].append(cell) }
        if rows.last?.isEmpty == true { rows.removeLast() }

        func fmt(_ s: String) -> String {
            if to == "tsv" { return s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
            return (s.contains(",") || s.contains("\"") || s.contains("\n")) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        let out = Output.destination(for: src, ext: to)
        try rows.map { $0.map(fmt).joined(separator: outDelim) }.joined(separator: "\n").appending("\n").write(to: out, atomically: true, encoding: .utf8)
        return out
    }
}
