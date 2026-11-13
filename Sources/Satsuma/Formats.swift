import Foundation

enum Category: String, CaseIterable {
    case image, video, audio, pdf, document, slides, spreadsheet, epub, subtitles, archive, other

    var title: String {
        switch self {
        case .image: return "Images"
        case .video: return "Video"
        case .audio: return "Audio"
        case .pdf: return "PDF"
        case .document: return "Documents"
        case .slides: return "Slides"
        case .spreadsheet: return "Spreadsheets"
        case .epub: return "EPUB"
        case .subtitles: return "Subtitles"
        case .archive: return "Archives"
        case .other: return "Files"
        }
    }
}

enum Formats {
    /// Extension aliases → canonical extension.
    static let aliases: [String: String] = [
        "jpeg": "jpg", "tif": "tiff", "heif": "heic", "aif": "aiff", "markdown": "md", "mkd": "md",
        "htm": "html", "tgz": "gzip", "gz": "gzip", "oga": "ogg", "m4v": "mp4", "text": "txt"
    ]

    static let map: [String: Category] = {
        var m: [String: Category] = [:]
        for e in ["jpg", "png", "webp", "heic", "tiff", "avif", "bmp", "svg"] { m[e] = .image }
        for e in ["mp4", "mov", "mkv", "webm", "avi", "wmv", "gif"] { m[e] = .video }
        for e in ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma"] { m[e] = .audio }
        m["pdf"] = .pdf
        for e in ["docx", "doc", "pages", "md", "txt", "rtf", "rtfd", "textclipping", "html", "odt"] { m[e] = .document }
        for e in ["ppt", "pptx"] { m[e] = .slides }
        for e in ["xlsx", "xls", "ods", "csv", "tsv"] { m[e] = .spreadsheet }
        m["epub"] = .epub
        for e in ["srt", "vtt"] { m[e] = .subtitles }
        for e in ["zip", "tar", "gzip", "rar"] { m[e] = .archive }
        return m
    }()

    static func ext(of url: URL) -> String {
        let e = url.pathExtension.lowercased()
        return aliases[e] ?? e
    }

    static func category(of url: URL) -> Category {
        if isDirectory(url) { return .other }
        return map[ext(of: url)] ?? .other
    }

    /// The shared category of a selection, or nil if mixed or if it contains a folder.
    static func category(of urls: [URL]) -> Category? {
        guard !urls.isEmpty, !urls.contains(where: { isDirectory($0) }) else { return nil }
        let cats = Set(urls.map { category(of: $0) })
        return cats.count == 1 ? cats.first : nil
    }

    static func targets(for e: String) -> [String] {
        guard let cat = map[e] else { return [] }
        let list: [String]
        switch cat {
        case .image: list = ["jpg", "png", "webp", "heic", "tiff", "avif", "bmp", "pdf"]
        case .video: list = ["mp4", "mov", "mkv", "webm", "avi", "wmv", "gif", "mp3"]
        case .audio: list = ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma"]
        case .pdf: list = ["docx", "pages", "pptx", "xlsx", "jpg", "png", "epub", "txt", "md"]
        case .document: list = ["docx", "pages", "md", "txt", "epub", "html", "pdf"]
        case .slides: list = ["pdf", "jpg", "png"]
        case .spreadsheet: list = ["xlsx", "ods", "csv", "tsv", "pdf"]
        case .epub: list = ["docx", "md", "txt", "pdf"]
        case .subtitles: list = ["srt", "vtt", "txt"]
        case .archive: list = ["zip", "tar", "gzip"]
        case .other: list = []
        }
        return list.filter { $0 != e }
    }

    /// Targets valid for every file in the selection.
    static func commonTargets(for urls: [URL]) -> [String] {
        var common: [String]?
        for u in urls {
            let t = targets(for: ext(of: u))
            common = common == nil ? t : common!.filter { t.contains($0) }
        }
        return common ?? []
    }

    static func label(_ e: String) -> String {
        switch e {
        case "md": return "Markdown"
        case "gzip": return "GZIP"
        default: return e.uppercased()
        }
    }

    /// Real file extension to write for a target format.
    static func outputExtension(_ target: String) -> String {
        target == "gzip" ? "tar.gz" : target
    }

    /// Total number of (input → output) conversion pairs this app offers.
    static var conversionCount: Int {
        map.keys.filter { aliases[$0] == nil }.reduce(0) { $0 + targets(for: $1).count }
    }
}
