import Foundation
import AppKit
import PDFKit
import ImageIO

struct PromptSpec {
    let title: String
    let message: String
    let fields: [(String, String)]
}

struct ToolDef: Identifiable {
    enum Mode { case each, group(min: Int) }
    let id: String
    let title: String
    let symbol: String
    let categories: Set<Category>
    var mode: Mode = .each
    var prompt: PromptSpec? = nil
    let run: ([URL], [String]) throws -> [URL]
}

enum Tools {
    static func applicable(to files: [URL]) -> [ToolDef] {
        let cat = Formats.category(of: files)
        return all.filter { t in
            if t.id == "zip" { return true }
            guard let cat = cat, t.categories.contains(cat) else { return false }
            switch t.mode {
            case .each: return true
            case .group(let m): return files.count >= m
            }
        }
    }

    /// Runs a tool over the selection (per-file or grouped), collecting failures.
    static func execute(_ t: ToolDef, files: [URL], params: [String]) throws -> JobResult {
        var result = JobResult()
        if case .group = t.mode {
            Output.beginItem()
            do {
                let outs = try t.run(files, params)
                Output.commitItem()
                result.items.append(JobItem(sources: files, outputs: outs))
            } catch {
                Output.discardItem()
                throw error
            }
            return result
        }
        for f in files {
            Output.beginItem()
            do {
                let outs = try t.run([f], params)
                Output.commitItem()
                result.items.append(JobItem(sources: [f], outputs: outs))
            } catch {
                Output.discardItem()       // remove any half-written output
                result.failures.append("\(f.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if result.items.isEmpty, let first = result.failures.first { throw ConvError.failed(first) }
        return result
    }

    // 26 tools: 7 image, 6 video, 4 audio, 5 PDF, 3 merge, 1 zip.
    static let all: [ToolDef] = [
        // Images
        ToolDef(id: "img.compress", title: "Compress", symbol: "arrow.down.right.and.arrow.up.left", categories: [.image]) { f, _ in
            [try ImgTools.compress(f[0])]
        },
        ToolDef(id: "img.resize", title: "Resize", symbol: "arrow.up.left.and.arrow.down.right", categories: [.image],
                prompt: PromptSpec(title: "Resize", message: "Fill one field to keep the aspect ratio, or both for an exact size.",
                                   fields: [("Width (px)", "1280"), ("Height (px)", "")])) { f, p in
            [try ImgTools.resize(f[0], width: Int(p[0]), height: Int(p[1]))]
        },
        ToolDef(id: "img.crop", title: "Crop", symbol: "crop", categories: [.image],
                prompt: PromptSpec(title: "Crop", message: "Centered crop to an aspect ratio (e.g. 1:1, 4:3, 16:9).",
                                   fields: [("Aspect ratio", "1:1")])) { f, p in
            [try ImgTools.crop(f[0], aspect: p[0])]
        },
        ToolDef(id: "img.rotate", title: "Rotate", symbol: "rotate.right", categories: [.image]) { f, _ in
            [try ImgTools.transform(f[0], suffix: " rotated") { try ImgTools.rotate90($0) }]
        },
        ToolDef(id: "img.flip", title: "Flip", symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", categories: [.image]) { f, _ in
            [try ImgTools.transform(f[0], suffix: " flipped") { try ImgTools.flipH($0) }]
        },
        ToolDef(id: "img.strip", title: "Strip Metadata", symbol: "eye.slash", categories: [.image]) { f, _ in
            [try ImgTools.transform(f[0], suffix: " clean", quality: 0.95) { $0 }]
        },
        ToolDef(id: "img.gray", title: "Grayscale", symbol: "circle.lefthalf.filled", categories: [.image]) { f, _ in
            [try ImgTools.transform(f[0], suffix: " gray") { try ImgTools.gray($0) }]
        },

        // Video
        ToolDef(id: "vid.compress", title: "Compress", symbol: "arrow.down.right.and.arrow.up.left", categories: [.video]) { f, _ in
            [try VidTools.compress(f[0])]
        },
        ToolDef(id: "vid.trim", title: "Trim", symbol: "scissors", categories: [.video],
                prompt: PromptSpec(title: "Trim video", message: "Times as seconds or mm:ss.",
                                   fields: [("Start", "0:00"), ("End", "0:10")])) { f, p in
            [try VidTools.trim(f[0], start: p[0], end: p[1])]
        },
        ToolDef(id: "vid.crop", title: "Crop", symbol: "crop", categories: [.video],
                prompt: PromptSpec(title: "Crop video", message: "Centered crop to an aspect ratio.",
                                   fields: [("Aspect ratio", "1:1")])) { f, p in
            [try VidTools.crop(f[0], aspect: p[0])]
        },
        ToolDef(id: "vid.mute", title: "Mute", symbol: "speaker.slash", categories: [.video]) { f, _ in
            [try VidTools.mute(f[0])]
        },
        ToolDef(id: "vid.faster", title: "Speed 2×", symbol: "hare", categories: [.video]) { f, _ in
            [try VidTools.speed(f[0], factor: 2)]
        },
        ToolDef(id: "vid.slower", title: "Speed ½×", symbol: "tortoise", categories: [.video]) { f, _ in
            [try VidTools.speed(f[0], factor: 0.5)]
        },

        // Audio
        ToolDef(id: "aud.trim", title: "Trim", symbol: "scissors", categories: [.audio],
                prompt: PromptSpec(title: "Trim audio", message: "Times as seconds or mm:ss.",
                                   fields: [("Start", "0:00"), ("End", "0:30")])) { f, p in
            [try AudTools.trim(f[0], start: p[0], end: p[1])]
        },
        ToolDef(id: "aud.normalize", title: "Normalize", symbol: "waveform.path", categories: [.audio]) { f, _ in
            [try AudTools.normalize(f[0])]
        },
        ToolDef(id: "aud.compress", title: "Compress", symbol: "arrow.down.right.and.arrow.up.left", categories: [.audio]) { f, _ in
            [try AudTools.compress(f[0])]
        },
        ToolDef(id: "aud.fade", title: "Fade In/Out", symbol: "waveform", categories: [.audio],
                prompt: PromptSpec(title: "Fade", message: "Fade length in seconds.", fields: [("Seconds", "2")])) { f, p in
            [try AudTools.fade(f[0], seconds: Double(p[0]) ?? 2)]
        },

        // PDF
        ToolDef(id: "pdf.compress", title: "Compress", symbol: "arrow.down.right.and.arrow.up.left", categories: [.pdf]) { f, _ in
            [try PDFTools.compress(f[0])]
        },
        ToolDef(id: "pdf.split", title: "Split Pages", symbol: "square.split.2x1", categories: [.pdf]) { f, _ in
            [try PDFTools.split(f[0])]
        },
        ToolDef(id: "pdf.extract", title: "Extract Pages", symbol: "doc.on.doc", categories: [.pdf],
                prompt: PromptSpec(title: "Extract pages", message: "Pages such as 1-3,5,8-",
                                   fields: [("Pages", "1")])) { f, p in
            [try PDFTools.extract(f[0], range: p[0])]
        },
        ToolDef(id: "pdf.rotate", title: "Rotate", symbol: "rotate.right", categories: [.pdf]) { f, _ in
            [try PDFTools.rotate(f[0])]
        },
        ToolDef(id: "pdf.merge", title: "Merge", symbol: "arrow.triangle.merge", categories: [.pdf], mode: .group(min: 2)) { f, _ in
            [try PDFTools.merge(f)]
        },

        // Merge (other media)
        ToolDef(id: "img.merge", title: "Merge → PDF", symbol: "arrow.triangle.merge", categories: [.image], mode: .group(min: 2)) { f, _ in
            [try ImgTools.mergeToPDF(f)]
        },
        ToolDef(id: "aud.merge", title: "Merge", symbol: "arrow.triangle.merge", categories: [.audio], mode: .group(min: 2)) { f, _ in
            [try AudTools.merge(f)]
        },
        ToolDef(id: "vid.merge", title: "Merge", symbol: "arrow.triangle.merge", categories: [.video], mode: .group(min: 2)) { f, _ in
            [try VidTools.merge(f)]
        },

        // Any file or folder
        ToolDef(id: "zip", title: "Zip", symbol: "archivebox", categories: Set(Category.allCategories), mode: .group(min: 1)) { f, _ in
            [try Archives.zip(f)]
        }
    ]
}

extension Category {
    static var allCategories: [Category] { Category.allCases }
}

// MARK: - Image tools

enum ImgTools {
    static func transform(_ src: URL, suffix: String, quality: Double? = nil, _ f: (CGImage) throws -> CGImage) throws -> URL {
        var ext = Formats.ext(of: src)
        if ext == "svg" || !Img.canWrite(ext) { ext = "png" }
        let out = Output.destination(for: src, ext: ext, suffix: suffix)
        let img = try Img.load(src)
        try Img.write(try f(img), to: out, ext: ext, quality: quality)
        return out
    }

    static func context(_ w: Int, _ h: Int, gray: Bool = false) throws -> CGContext {
        guard w > 0, h > 0, w * h <= Limits.maxImagePixels else {
            throw ConvError.failed("That size is too large (limit \(Limits.maxImagePixels / 1_000_000) megapixels).")
        }
        let ctx: CGContext?
        if gray {
            ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        } else {
            ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard let c = ctx else { throw ConvError.failed("Image processing failed.") }
        c.interpolationQuality = .high
        return c
    }

    static func finish(_ ctx: CGContext) throws -> CGImage {
        guard let i = ctx.makeImage() else { throw ConvError.failed("Image processing failed.") }
        return i
    }

    static func compress(_ src: URL) throws -> URL {
        try transform(src, suffix: " compressed", quality: 0.6) { $0 }
    }

    static func resize(_ src: URL, width: Int?, height: Int?) throws -> URL {
        try transform(src, suffix: " resized") { img in
            let ar = Double(img.width) / Double(img.height)
            var w = width ?? 0, h = height ?? 0
            if w > 0 && h == 0 { h = Int((Double(w) / ar).rounded()) }
            else if h > 0 && w == 0 { w = Int((Double(h) * ar).rounded()) }
            guard w > 0, h > 0 else { throw ConvError.failed("Enter a width and/or height.") }
            let ctx = try context(w, h)
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return try finish(ctx)
        }
    }

    static func crop(_ src: URL, aspect: String) throws -> URL {
        guard let (aw, ah) = parseAspect(aspect) else { throw ConvError.failed("Use an aspect ratio like 16:9.") }
        return try transform(src, suffix: " cropped") { img in
            let W = Double(img.width), H = Double(img.height)
            var w = W, h = W * ah / aw
            if h > H { h = H; w = H * aw / ah }
            let rect = CGRect(x: ((W - w) / 2).rounded(), y: ((H - h) / 2).rounded(), width: w.rounded(), height: h.rounded())
            guard let c = img.cropping(to: rect) else { throw ConvError.failed("Crop failed.") }
            return c
        }
    }

    static func rotate90(_ img: CGImage) throws -> CGImage {
        let w = img.width, h = img.height
        let ctx = try context(h, w)
        ctx.translateBy(x: CGFloat(h) / 2, y: CGFloat(w) / 2)
        ctx.rotate(by: -.pi / 2)
        ctx.translateBy(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return try finish(ctx)
    }

    static func flipH(_ img: CGImage) throws -> CGImage {
        let ctx = try context(img.width, img.height)
        ctx.translateBy(x: CGFloat(img.width), y: 0)
        ctx.scaleBy(x: -1, y: 1)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return try finish(ctx)
    }

    static func gray(_ img: CGImage) throws -> CGImage {
        let ctx = try context(img.width, img.height, gray: true)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return try finish(ctx)
    }

    static func mergeToPDF(_ files: [URL]) throws -> URL {
        let imgs = try files.map { try Img.load($0) }
        let out = Output.destination(for: files[0], ext: "pdf", suffix: " merged")
        try Img.makePDF(imgs, out)
        return out
    }
}

// MARK: - Video tools

enum VidTools {
    static func outExt(_ src: URL) -> String { Formats.ext(of: src) == "mov" ? "mov" : "mp4" }

    static func encode(_ src: URL, suffix: String, pre: [String] = [], filters: [String] = [], extra: [String]? = nil) throws -> URL {
        let ext = outExt(src)
        let out = Output.destination(for: src, ext: ext, suffix: suffix)
        var args = pre + ["-i", src.path]
        args += ["-vf", (filters + [Media.evenScale]).joined(separator: ",")]
        args += extra ?? ["-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k"]
        if ext == "mp4" { args += ["-movflags", "+faststart"] }
        try Media.ffmpeg(args + [out.path])
        return out
    }

    static func compress(_ src: URL) throws -> URL {
        try encode(src, suffix: " compressed", filters: [],
                   extra: ["-c:v", "libx264", "-preset", "medium", "-crf", "28", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "128k"])
    }

    static func trim(_ src: URL, start: String, end: String) throws -> URL {
        guard let s = parseTime(start), let e = parseTime(end), e > s else { throw ConvError.failed("Enter a valid start and end time.") }
        return try encode(src, suffix: " trimmed", pre: ["-ss", String(s), "-to", String(e)])
    }

    static func crop(_ src: URL, aspect: String) throws -> URL {
        guard let (aw, ah) = parseAspect(aspect) else { throw ConvError.failed("Use an aspect ratio like 16:9.") }
        let a = aw / ah
        let w = "'trunc(if(gt(iw/ih,\(a)),ih*\(a),iw)/2)*2'"
        let h = "'trunc(if(gt(iw/ih,\(a)),ih,iw/\(a))/2)*2'"
        return try encode(src, suffix: " cropped", filters: ["crop=w=\(w):h=\(h)"])
    }

    static func mute(_ src: URL) throws -> URL {
        let ext = Formats.ext(of: src)
        let out = Output.destination(for: src, ext: ext, suffix: " muted")
        try Media.ffmpeg(["-i", src.path, "-an", "-c:v", "copy", out.path])
        return out
    }

    static func speed(_ src: URL, factor: Double) throws -> URL {
        let out = Output.destination(for: src, ext: outExt(src), suffix: factor > 1 ? " fast" : " slow")
        let v = "setpts=PTS/\(factor)"
        let withAudio = ["-filter_complex", "[0:v]\(v)[v];[0:a]atempo=\(factor)[a]", "-map", "[v]", "-map", "[a]",
                         "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac"]
        do {
            try Media.ffmpeg(["-i", src.path] + withAudio + [out.path])
        } catch {
            try? FileManager.default.removeItem(at: out)
            try Media.ffmpeg(["-i", src.path, "-vf", v, "-an", "-c:v", "libx264", "-pix_fmt", "yuv420p", out.path])
        }
        return out
    }

    static func merge(_ files: [URL]) throws -> URL {
        guard let (w, h) = Media.probeSize(files[0]) else { throw ConvError.missingTool("ffprobe", Ext.hints["ffprobe"] ?? "") }
        let W = (w / 2) * 2, H = (h / 2) * 2
        var inputs: [String] = []
        var graph = ""
        var concatIn = ""
        for (i, f) in files.enumerated() {
            inputs += ["-i", f.path]
            graph += "[\(i):v]scale=\(W):\(H):force_original_aspect_ratio=decrease,pad=\(W):\(H):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30[v\(i)];"
            concatIn += "[v\(i)][\(i):a]"
        }
        graph += "\(concatIn)concat=n=\(files.count):v=1:a=1[v][a]"
        let out = Output.destination(for: files[0], ext: "mp4", suffix: " merged")
        try Media.ffmpeg(inputs + ["-filter_complex", graph, "-map", "[v]", "-map", "[a]",
                                   "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", out.path])
        return out
    }
}

// MARK: - Audio tools

enum AudTools {
    static func ext(_ src: URL) -> String {
        let e = Formats.ext(of: src)
        return Media.audioArgs[e] != nil ? e : "mp3"
    }

    static func trim(_ src: URL, start: String, end: String) throws -> URL {
        guard let s = parseTime(start), let e = parseTime(end), e > s else { throw ConvError.failed("Enter a valid start and end time.") }
        let x = ext(src)
        let out = Output.destination(for: src, ext: x, suffix: " trimmed")
        try Media.ffmpeg(["-ss", String(s), "-to", String(e), "-i", src.path, "-vn"] + (Media.audioArgs[x] ?? []) + [out.path])
        return out
    }

    static func normalize(_ src: URL) throws -> URL {
        let x = ext(src)
        let out = Output.destination(for: src, ext: x, suffix: " normalized")
        try Media.ffmpeg(["-i", src.path, "-vn", "-af", "loudnorm=I=-16:TP=-1.5:LRA=11", "-ar", "44100"] + (Media.audioArgs[x] ?? []) + [out.path])
        return out
    }

    static func compress(_ src: URL) throws -> URL {
        let out = Output.destination(for: src, ext: "mp3", suffix: " compressed")
        try Media.ffmpeg(["-i", src.path, "-vn", "-c:a", "libmp3lame", "-b:a", "96k", out.path])
        return out
    }

    static func fade(_ src: URL, seconds: Double) throws -> URL {
        guard let dur = Media.probeDuration(src) else { throw ConvError.missingTool("ffprobe", Ext.hints["ffprobe"] ?? "") }
        let d = min(seconds, dur / 2)
        let x = ext(src)
        let out = Output.destination(for: src, ext: x, suffix: " faded")
        try Media.ffmpeg(["-i", src.path, "-vn", "-af", "afade=t=in:d=\(d),afade=t=out:st=\(max(0, dur - d)):d=\(d)"]
                         + (Media.audioArgs[x] ?? []) + [out.path])
        return out
    }

    static func merge(_ files: [URL]) throws -> URL {
        var inputs: [String] = []
        var labels = ""
        for (i, f) in files.enumerated() { inputs += ["-i", f.path]; labels += "[\(i):a]" }
        let x = ext(files[0])
        let out = Output.destination(for: files[0], ext: x, suffix: " merged")
        try Media.ffmpeg(inputs + ["-filter_complex", "\(labels)concat=n=\(files.count):v=0:a=1[a]", "-map", "[a]"]
                         + (Media.audioArgs[x] ?? []) + [out.path])
        return out
    }
}

// MARK: - PDF tools

enum PDFTools {
    static func open(_ url: URL) throws -> PDFDocument {
        guard let d = PDFDocument(url: url) else { throw ConvError.failed("Couldn’t open the PDF.") }
        return d
    }

    static func compress(_ src: URL) throws -> URL {
        let out = Output.destination(for: src, ext: "pdf", suffix: " compressed")
        if let gs = Ext.find("gs") {
            try Shell.run(gs, ["-sDEVICE=pdfwrite", "-dCompatibilityLevel=1.4", "-dPDFSETTINGS=/ebook", "-dSAFER", "-dNOPAUSE",
                               "-dQUIET", "-dBATCH", "-sOutputFile=\(out.path)", src.path], offline: true)
        } else {
            if #available(macOS 13.4, *) {
                let doc = try open(src)
                let opts: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]
                guard doc.write(to: out, withOptions: opts) else { throw ConvError.failed("Couldn’t write the compressed PDF.") }
            } else {
                throw ConvError.missingTool("Ghostscript", "PDF compression needs macOS 13.4+ or Ghostscript (`brew install ghostscript`).")
            }
        }
        // Don't leave a bigger file behind.
        let a = (try? FileManager.default.attributesOfItem(atPath: src.path)[.size] as? Int) ?? 0
        let b = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
        if a > 0, b >= a {
            try? FileManager.default.removeItem(at: out)
            throw ConvError.failed("This PDF is already well compressed.")
        }
        return out
    }

    static func split(_ src: URL) throws -> URL {
        let doc = try open(src)
        let base = Output.baseName(src)
        let dir = try Output.folder(for: src, name: base + " pages")
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
            let d = PDFDocument()
            d.insert(page, at: 0)
            d.write(to: dir.appendingPathComponent(base + "-" + String(format: "%03d", i + 1) + ".pdf"))
        }
        return dir
    }

    static func extract(_ src: URL, range: String) throws -> URL {
        let doc = try open(src)
        let idx = parsePageRange(range, pageCount: doc.pageCount)
        guard !idx.isEmpty else { throw ConvError.failed("No valid pages in “\(range)”.") }
        let out = Output.destination(for: src, ext: "pdf", suffix: " extract")
        let d = PDFDocument()
        for i in idx {
            if let p = doc.page(at: i)?.copy() as? PDFPage { d.insert(p, at: d.pageCount) }
        }
        guard d.write(to: out) else { throw ConvError.failed("Couldn’t write PDF.") }
        return out
    }

    static func rotate(_ src: URL) throws -> URL {
        let doc = try open(src)
        for i in 0..<doc.pageCount { if let p = doc.page(at: i) { p.rotation = (p.rotation + 90) % 360 } }
        let out = Output.destination(for: src, ext: "pdf", suffix: " rotated")
        guard doc.write(to: out) else { throw ConvError.failed("Couldn’t write PDF.") }
        return out
    }

    static func merge(_ files: [URL]) throws -> URL {
        let merged = PDFDocument()
        for f in files {
            let d = try open(f)
            for i in 0..<d.pageCount {
                if let p = d.page(at: i)?.copy() as? PDFPage { merged.insert(p, at: merged.pageCount) }
            }
        }
        let out = Output.destination(for: files[0], ext: "pdf", suffix: " merged")
        guard merged.write(to: out) else { throw ConvError.failed("Couldn’t write PDF.") }
        return out
    }
}
