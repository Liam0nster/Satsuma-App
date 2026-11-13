import Foundation
import AppKit
import ImageIO
import PDFKit
import Vision

// MARK: - Entry point

enum Converter {
    static func convert(_ src: URL, to target: String) throws -> URL {
        let from = Formats.ext(of: src)
        guard let cat = Formats.map[from], !isDirectory(src) else {
            throw ConvError.unsupported("“\(src.lastPathComponent)” can’t be converted.")
        }
        guard Formats.targets(for: from).contains(target) else {
            throw ConvError.unsupported("\(from.uppercased()) → \(target.uppercased()) isn’t supported.")
        }
        switch cat {
        case .image: return try Img.convert(src, from: from, to: target)
        case .audio, .video: return try Media.convert(src, from: from, to: target)
        case .pdf: return try PDFConv.convert(src, to: target)
        case .document, .epub: return try DocConv.convert(src, from: from, to: target)
        case .slides, .spreadsheet: return try OfficeConv.convert(src, from: from, to: target)
        case .subtitles: return try Subs.convert(src, from: from, to: target)
        case .archive: return try Archives.convert(src, from: from, to: target)
        case .other: throw ConvError.unsupported("Unsupported file type.")
        }
    }
}

// MARK: - Images

enum Img {
    static func uti(_ ext: String) -> String? {
        ["jpg": "public.jpeg", "png": "public.png", "tiff": "public.tiff", "bmp": "com.microsoft.bmp",
         "heic": "public.heic", "webp": "org.webmproject.webp", "avif": "public.avif"][ext]
    }

    static func canWrite(_ ext: String) -> Bool {
        guard let u = uti(ext), let ids = CGImageDestinationCopyTypeIdentifiers() as? [String] else { return false }
        return ids.contains(u)
    }

    /// Loads with EXIF orientation applied.
    static func load(_ url: URL) throws -> CGImage {
        if Formats.ext(of: url) == "svg" { return try loadSVG(url) }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ConvError.failed("Couldn’t read “\(url.lastPathComponent)”.")
        }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        if w * h > Limits.maxImagePixels {
            throw ConvError.failed("This image is too large to convert safely (\(w)×\(h) pixels).")
        }
        if max(w, h) > 0 {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(w, h)
            ]
            if let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) { return img }
        }
        if let img = CGImageSourceCreateImageAtIndex(src, 0, nil) { return img }
        throw ConvError.failed("Couldn’t decode “\(url.lastPathComponent)”.")
    }

    static func loadSVG(_ url: URL) throws -> CGImage {
        let viaNSImage: CGImage? = onMain {
            guard let img = NSImage(contentsOf: url), img.size.width > 0, img.size.height > 0 else { return nil }
            let scale = max(1, 2048 / max(img.size.width, img.size.height))
            let w = Int(img.size.width * scale), h = Int(img.size.height * scale)
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            img.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
            NSGraphicsContext.restoreGraphicsState()
            return rep.cgImage
        }
        if let cg = viaNSImage { return cg }
        // Fallback: Quick Look renders SVG.
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Shell.run("/usr/bin/qlmanage", ["-t", "-s", "2048", "-o", tmp.path, url.path], offline: true)
        if let png = try FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "png" }) {
            return try load(png)
        }
        throw ConvError.failed("Couldn’t render SVG.")
    }

    static func flatten(_ img: CGImage) -> CGImage {
        guard let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return img }
        let r = CGRect(x: 0, y: 0, width: img.width, height: img.height)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(r)
        ctx.draw(img, in: r)
        return ctx.makeImage() ?? img
    }

    static func write(_ img: CGImage, to url: URL, ext: String, quality: Double? = nil) throws {
        guard let u = uti(ext), canWrite(ext) else {
            throw ConvError.unsupported("This Mac can’t write \(ext.uppercased()) natively.")
        }
        let image = ext == "jpg" ? flatten(img) : img
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, u as CFString, 1, nil) else {
            throw ConvError.failed("Couldn’t create \(ext.uppercased()) file.")
        }
        var props: [CFString: Any] = [:]
        if ["jpg", "heic", "webp", "avif"].contains(ext) {
            props[kCGImageDestinationLossyCompressionQuality] = quality ?? Settings.currentJPEGQuality
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConvError.failed("Image encoding failed.") }
    }

    static func makePDF(_ imgs: [CGImage], _ out: URL) throws {
        let doc = PDFDocument()
        for cg in imgs {
            let ns = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            if let page = PDFPage(image: ns) { doc.insert(page, at: doc.pageCount) }
        }
        guard doc.pageCount > 0, doc.write(to: out) else { throw ConvError.failed("Couldn’t create PDF.") }
    }

    static func convert(_ src: URL, from: String, to: String) throws -> URL {
        let out = Output.destination(for: src, ext: to)
        do {
            let img = try load(src)
            if to == "pdf" { try makePDF([img], out) } else { try write(img, to: out, ext: to) }
        } catch {
            guard to != "pdf", Ext.find("ffmpeg") != nil else { throw error }
            try? FileManager.default.removeItem(at: out)
            try Media.ffmpeg(["-i", src.path, "-frames:v", "1", out.path])
        }
        return out
    }
}

// MARK: - Audio / Video (ffmpeg, with afconvert fallback for common audio)

enum Media {
    static func ffmpeg(_ args: [String]) throws {
        let exe = try Ext.require("ffmpeg")
        // -n: never overwrite (fail instead of writing through a file or symlink that appeared meanwhile).
        // -protocol_whitelist before every input: a disguised playlist can't make ffmpeg open network URLs.
        var full = ["-hide_banner", "-loglevel", "error", "-nostdin", "-n"]
        for a in args {
            if a == "-i" { full += ["-protocol_whitelist", "file,pipe"] }
            full.append(a)
        }
        try Shell.run(exe, full, offline: true)
    }

    static func probeDuration(_ url: URL) -> Double? {
        guard let p = Ext.find("ffprobe"),
              let s = try? Shell.run(p, ["-v", "error", "-protocol_whitelist", "file,pipe", "-show_entries", "format=duration",
                                          "-of", "default=nw=1:nk=1", "-i", url.path], offline: true)
        else { return nil }
        return Double(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func probeSize(_ url: URL) -> (Int, Int)? {
        guard let p = Ext.find("ffprobe"),
              let s = try? Shell.run(p, ["-v", "error", "-protocol_whitelist", "file,pipe", "-select_streams", "v:0",
                                          "-show_entries", "stream=width,height", "-of", "csv=s=x:p=0", "-i", url.path],
                                     offline: true)
        else { return nil }
        let parts = s.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "x").compactMap { Int($0) }
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }

    static let audioArgs: [String: [String]] = [
        "mp3": ["-c:a", "libmp3lame", "-q:a", "2"],
        "m4a": ["-c:a", "aac", "-b:a", "192k"],
        "wav": ["-c:a", "pcm_s16le"],
        "flac": ["-c:a", "flac"],
        "ogg": ["-c:a", "libvorbis", "-q:a", "5"],
        "opus": ["-c:a", "libopus", "-b:a", "128k"],
        "aiff": ["-c:a", "pcm_s16be"],
        "wma": ["-c:a", "wmav2", "-b:a", "192k"]
    ]

    static let evenScale = "scale=trunc(iw/2)*2:trunc(ih/2)*2"

    static func videoAttempts(_ to: String) -> [[String]] {
        switch to {
        case "mp4", "mov":
            let fast = to == "mp4" ? ["-movflags", "+faststart"] : []
            return [
                ["-vf", evenScale, "-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k"] + fast,
                ["-vf", evenScale, "-c:v", "h264_videotoolbox", "-b:v", "6M", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k"] + fast
            ]
        case "mkv":
            return [["-c", "copy"],
                    ["-vf", evenScale, "-c:v", "libx264", "-crf", "20", "-pix_fmt", "yuv420p", "-c:a", "aac"]]
        case "webm":
            return [["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-pix_fmt", "yuv420p", "-c:a", "libopus"]]
        case "avi":
            return [["-c:v", "mpeg4", "-q:v", "3", "-c:a", "libmp3lame", "-q:a", "3"]]
        case "wmv":
            return [["-vf", evenScale, "-c:v", "wmv2", "-b:v", "4M", "-c:a", "wmav2", "-b:a", "192k"]]
        case "gif":
            return [["-vf", "fps=15,scale='min(640,iw)':-1:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse",
                     "-loop", "0", "-an"]]
        default:
            return []
        }
    }

    static func convert(_ src: URL, from: String, to: String) throws -> URL {
        let out = Output.destination(for: src, ext: to)

        if let a = audioArgs[to] {
            if Ext.find("ffmpeg") == nil, let native = afconvertArgs[to], Formats.map[from] == .audio {
                try Shell.run("/usr/bin/afconvert", native + [src.path, out.path])
                return out
            }
            try ffmpeg(["-i", src.path, "-vn", "-map_metadata", "0"] + a + [out.path])
            return out
        }

        var lastError: Error = ConvError.unsupported("Unsupported video format.")
        for args in videoAttempts(to) {
            do {
                try ffmpeg(["-i", src.path] + args + [out.path])
                return out
            } catch {
                lastError = error
                try? FileManager.default.removeItem(at: out)
            }
        }
        throw lastError
    }

    static let afconvertArgs: [String: [String]] = [
        "m4a": ["-f", "m4af", "-d", "aac"],
        "wav": ["-f", "WAVE", "-d", "LEI16"],
        "aiff": ["-f", "AIFF", "-d", "BEI16"]
    ]
}

// MARK: - PDF

enum PDFConv {
    static func convert(_ src: URL, to target: String) throws -> URL {
        guard let doc = PDFDocument(url: src) else { throw ConvError.failed("Couldn’t open the PDF.") }
        switch target {
        case "jpg", "png":
            return try images(doc, src, target)
        case "txt":
            let out = Output.destination(for: src, ext: "txt")
            try pages(doc).joined(separator: "\n\n").write(to: out, atomically: true, encoding: .utf8)
            return out
        case "md":
            let out = Output.destination(for: src, ext: "md")
            let body = pages(doc).enumerated().map { "<!-- Page \($0.offset + 1) -->\n\n" + $0.element }.joined(separator: "\n\n---\n\n")
            try body.write(to: out, atomically: true, encoding: .utf8)
            return out
        case "docx":
            let out = Output.destination(for: src, ext: "docx")
            try toDocx(src, doc, out)
            return out
        case "pages":
            let tmp = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: tmp) }
            let docx = tmp.appendingPathComponent("in.docx")
            try toDocx(src, doc, docx)
            let out = Output.destination(for: src, ext: "pages")
            try Pages.fromDocx(docx, out)
            return out
        case "pptx":
            let produced = try Office.convert(src, format: "pptx:Impress MS PowerPoint 2007 XML", infilter: "impress_pdf_import")
            let out = Output.destination(for: src, ext: "pptx")
            try FileManager.default.moveItem(at: produced, to: out)
            return out
        case "xlsx":
            return try toXlsx(src, doc)
        case "epub":
            let out = Output.destination(for: src, ext: "epub")
            let html = pages(doc).map { p in
                p.components(separatedBy: "\n\n").map { "<p>" + htmlEscape($0).replacingOccurrences(of: "\n", with: " ") + "</p>" }.joined()
            }.joined(separator: "<hr/>")
            try EpubBuilder.build(title: Output.baseName(src), bodyHTML: html, to: out)
            return out
        default:
            throw ConvError.unsupported("PDF → \(target.uppercased()) isn’t supported.")
        }
    }

    static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Text per page; falls back to on-device OCR (Vision) for scanned pages.
    static func pages(_ doc: PDFDocument) -> [String] {
        var result: [String] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            var t = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty, let img = try? render(page, dpi: 200) { t = ocr(img) }
            result.append(t)
        }
        return result
    }

    static func ocr(_ img: CGImage) -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: img, options: [:]).perform([req])
        let lines = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }

    static func render(_ page: PDFPage, dpi: CGFloat) throws -> CGImage {
        // Core Graphics only (thread-safe, unlike AppKit drawing), and oversized pages are rendered at a lower DPI
        // so a hostile page size can't ask for gigabytes of memory.
        guard let cg = page.pageRef else { throw ConvError.failed("Couldn’t read a PDF page.") }
        var box = cg.getBoxRect(.cropBox)
        if cg.rotationAngle % 180 != 0 { box = CGRect(x: 0, y: 0, width: box.height, height: box.width) }
        guard box.width > 0, box.height > 0 else { throw ConvError.failed("This PDF page has no size.") }
        var scale = dpi / 72
        let pixels = Double(box.width * scale) * Double(box.height * scale)
        if pixels > Limits.maxPDFRenderPixels {
            scale *= CGFloat((Limits.maxPDFRenderPixels / pixels).squareRoot())
        }
        let w = max(1, Int((box.width * scale).rounded()))
        let h = max(1, Int((box.height * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ConvError.failed("Couldn’t allocate memory to render a PDF page.")
        }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.concatenate(cg.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: w, height: h),
                                               rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(cg)
        guard let img = ctx.makeImage() else { throw ConvError.failed("Couldn’t render a PDF page.") }
        return img
    }

    static func images(_ doc: PDFDocument, _ src: URL, _ ext: String) throws -> URL {
        if doc.pageCount == 1, let page = doc.page(at: 0) {
            let out = Output.destination(for: src, ext: ext)
            try Img.write(try render(page, dpi: 300), to: out, ext: ext)
            return out
        }
        let base = Output.baseName(src)
        let dir = try Output.folder(for: src, name: base)
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let name = base + "-" + String(format: "%03d", i + 1) + "." + ext
            try Img.write(try render(page, dpi: 300), to: dir.appendingPathComponent(name), ext: ext)
        }
        return dir
    }

    static func toDocx(_ src: URL, _ doc: PDFDocument, _ out: URL) throws {
        if Ext.find("soffice") != nil,
           let produced = try? Office.convert(src, format: "docx:MS Word 2007 XML", infilter: "writer_pdf_import") {
            try FileManager.default.moveItem(at: produced, to: out)
            return
        }
        // Text-only fallback.
        let text = pages(doc).joined(separator: "\n\n")
        let attr = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)])
        try DocIO.save(attr, to: out, ext: "docx", title: Output.baseName(src))
    }

    static func toXlsx(_ src: URL, _ doc: PDFDocument) throws -> URL {
        // Heuristic: split each text line into cells on tabs or runs of 2+ spaces.
        let splitter = try NSRegularExpression(pattern: "\\t+|\\s{2,}")
        func csvCell(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var rows: [String] = []
        for p in pages(doc) {
            for line in p.components(separatedBy: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                let ns = line as NSString
                let marked = splitter.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: ns.length), withTemplate: "\u{1}")
                rows.append(marked.components(separatedBy: "\u{1}").map(csvCell).joined(separator: ","))
            }
        }
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let csv = tmp.appendingPathComponent(Output.baseName(src) + ".csv")
        try rows.joined(separator: "\n").write(to: csv, atomically: true, encoding: .utf8)
        let produced = try Office.convert(csv, format: "xlsx:Calc MS Excel 2007 XML", infilter: "CSV:44,34,76,1")
        let out = Output.destination(for: src, ext: "xlsx")
        try FileManager.default.moveItem(at: produced, to: out)
        return out
    }
}

// MARK: - Subtitles

enum Subs {
    struct Cue { var start: String; var end: String; var text: String }

    static func norm(_ t: String) -> String {
        var s = t.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        if s.filter({ $0 == ":" }).count == 1 { s = "00:" + s }
        return s
    }

    static func parse(_ raw: String) -> [Cue] {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\u{FEFF}", with: "")
        var cues: [Cue] = []
        for block in text.components(separatedBy: "\n\n") {
            let lines = block.components(separatedBy: "\n")
            guard let ti = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[ti].components(separatedBy: "-->")
            guard parts.count == 2 else { continue }
            let endToken = parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
            let body = lines[(ti + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            cues.append(Cue(start: norm(parts[0]), end: norm(endToken), text: body))
        }
        return cues
    }

    static func convert(_ src: URL, from: String, to: String) throws -> URL {
        let raw = try String(contentsOf: src, encoding: .utf8)
        let cues = parse(raw)
        guard !cues.isEmpty else { throw ConvError.failed("No subtitle cues found.") }
        let out = Output.destination(for: src, ext: to)
        var result = ""
        switch to {
        case "srt":
            result = cues.enumerated().map { i, c in
                "\(i + 1)\n\(c.start.replacingOccurrences(of: ".", with: ",")) --> \(c.end.replacingOccurrences(of: ".", with: ","))\n\(c.text)"
            }.joined(separator: "\n\n") + "\n"
        case "vtt":
            result = "WEBVTT\n\n" + cues.map { "\($0.start) --> \($0.end)\n\($0.text)" }.joined(separator: "\n\n") + "\n"
        case "txt":
            let tags = try NSRegularExpression(pattern: "<[^>]+>")
            result = cues.map { c in
                tags.stringByReplacingMatches(in: c.text, range: NSRange(location: 0, length: (c.text as NSString).length), withTemplate: "")
            }.joined(separator: "\n") + "\n"
        default:
            throw ConvError.unsupported("Unsupported subtitle target.")
        }
        try result.write(to: out, atomically: true, encoding: .utf8)
        return out
    }
}

// MARK: - Archives

enum Archives {
    /// Extracts, enforcing the size limit, then removes special files. Symlinks are kept (and never followed):
    /// the archive writers below store them as links.
    static func extract(_ src: URL, to dir: URL) throws {
        try extractRaw(src, to: dir, bomb: bombGuard(dir))
        Sanitize.prune(dir, removeSymlinks: false)
    }

    /// Polled while an extractor runs; aborts it if the output grows past the configured limit (archive bombs).
    static func bombGuard(_ dir: URL) -> () -> String? {
        let cap = Settings.maxExtractBytes
        var lastCheck = Date.distantPast
        return {
            guard Date().timeIntervalSince(lastCheck) > 2 else { return nil }
            lastCheck = Date()
            guard Archives.directorySize(dir) > cap else { return nil }
            return "Stopped: the archive expands past the \(cap / 1_073_741_824) GB limit (possible archive bomb). Raise the limit in Settings if this is expected."
        }
    }

    static func directorySize(_ dir: URL) -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys, options: []) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in en {
            if let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true {
                total += Int64(v.fileSize ?? 0)
            }
        }
        return total
    }

    private static func extractRaw(_ src: URL, to dir: URL, bomb: @escaping () -> String?) throws {
        let from = Formats.ext(of: src)
        let lower = src.lastPathComponent.lowercased()
        if from == "zip" {
            try Shell.run("/usr/bin/ditto", ["-x", "-k", src.path, dir.path], abortIf: bomb)
        } else if from == "gzip" && !(lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz")) {
            // Plain single-file gzip.
            let name = src.deletingPathExtension().lastPathComponent
            try Shell.run("/bin/sh", ["-c", "/usr/bin/gzip -dc \"$1\" > \"$2\"", "sh", src.path, dir.appendingPathComponent(name).path],
                          abortIf: bomb)
        } else {
            // tar, tar.gz, rar (bsdtar reads RAR).
            try Shell.run("/usr/bin/tar", ["-xf", src.path, "-C", dir.path], offline: true, abortIf: bomb)
        }
    }

    static func create(from dir: URL, to out: URL, kind: String) throws {
        switch kind {
        // -y stores symlinks as links instead of following them (which would copy the target's contents in).
        case "zip": try Shell.run("/usr/bin/zip", ["-q", "-r", "-y", "-X", out.path, "."], cwd: dir)
        case "tar": try Shell.run("/usr/bin/tar", ["-cf", out.path, "-C", dir.path, "."])
        default: try Shell.run("/usr/bin/tar", ["-czf", out.path, "-C", dir.path, "."])
        }
    }

    static func convert(_ src: URL, from: String, to: String) throws -> URL {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let ex = tmp.appendingPathComponent("x")
        try FileManager.default.createDirectory(at: ex, withIntermediateDirectories: true)
        try extract(src, to: ex)
        let out = Output.destination(for: src, ext: Formats.outputExtension(to))
        try create(from: ex, to: out, kind: to)
        return out
    }

    /// Zips arbitrary files/folders (used by the Zip file tool).
    static func zip(_ files: [URL]) throws -> URL {
        guard let first = files.first else { throw ConvError.failed("Nothing to zip.") }
        // Common case: everything lives in one folder, so zip it in place (no temporary copy of your data).
        let parents = Set(files.map { $0.deletingLastPathComponent().standardizedFileURL.path })
        guard parents.count == 1, let parent = parents.first else { return try zipCopying(files) }
        let base = files.count == 1 ? Output.baseName(first) : "Archive"
        let out = Output.destination(for: first, ext: "zip", base: base)
        // "./" keeps a name that starts with "-" from being read as an option; -y stores symlinks as links.
        let names = files.map { "./" + $0.lastPathComponent }
        try Shell.run("/usr/bin/zip", ["-q", "-r", "-y", "-X", out.path] + names, cwd: URL(fileURLWithPath: parent))
        return out
    }

    /// Mixed locations: gather copies (links stay links) in a temp folder first.
    private static func zipCopying(_ files: [URL]) throws -> URL {
        guard let first = files.first else { throw ConvError.failed("Nothing to zip.") }
        let base = files.count == 1 ? Output.baseName(first) : "Archive"
        let out = Output.destination(for: first, ext: "zip", base: base)
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        for f in files {
            try FileManager.default.copyItem(at: f, to: tmp.appendingPathComponent(f.lastPathComponent))
        }
        try Shell.run("/usr/bin/zip", ["-q", "-r", "-y", "-X", out.path, "."], cwd: tmp)
        return out
    }
}
