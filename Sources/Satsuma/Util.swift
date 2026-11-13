import Foundation
import AppKit

/// Runs `body` on the main thread. Safe to call from background threads (blocks until done).
func onMain<T>(_ body: () throws -> T) rethrows -> T {
    if Thread.isMainThread { return try body() }
    return try DispatchQueue.main.sync(execute: body)
}

enum ConvError: LocalizedError {
    case unsupported(String)
    case missingTool(String, String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let s): return s
        case .missingTool(let name, let hint): return "\(name) is required for this. \(hint)"
        case .failed(let s): return s
        }
    }
}

enum Shell {
    private final class Reason {
        private let lock = NSLock()
        private var text: String?
        func set(_ s: String) { lock.lock(); if text == nil { text = s }; lock.unlock() }
        var value: String? { lock.lock(); defer { lock.unlock() }; return text }
    }

    /// Runs an executable with arguments (no shell involved), returns combined stdout+stderr.
    ///
    /// - offline: run under `sandbox-exec` with outbound networking denied (when available).
    /// - timeout: kill the process after this long (default: the Settings value).
    /// - abortIf: polled twice a second; return a message to kill the process (used for archive-bomb limits).
    @discardableResult
    static func run(_ exe: String, _ args: [String], cwd: URL? = nil, offline: Bool = false,
                    timeout: TimeInterval? = nil, abortIf: (() -> String?)? = nil) throws -> String {
        var launch = exe
        var argv = args
        if offline && Sandbox.available {
            launch = "/usr/bin/sandbox-exec"
            argv = ["-p", Sandbox.profile, exe] + args
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = argv
        if let cwd = cwd { p.currentDirectoryURL = cwd }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        try p.run()

        let reason = Reason()
        let limit = timeout ?? Settings.jobTimeout
        let started = Date()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler {
            guard p.isRunning else { return }
            var why: String?
            if Date().timeIntervalSince(started) > limit {
                why = "Stopped: it ran longer than \(Int(limit / 60)) minutes (you can change this in Settings)."
            } else if let w = abortIf?() {
                why = w
            }
            guard let stopWhy = why else { return }
            reason.set(stopWhy)
            p.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
        }
        timer.resume()
        defer { timer.cancel() }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if let why = reason.value { throw ConvError.failed(why) }
        let out = String(decoding: data, as: UTF8.self)
        if p.terminationStatus != 0 {
            let name = (exe as NSString).lastPathComponent
            throw ConvError.failed("\(name) failed (exit \(p.terminationStatus)): \(String(out.suffix(500)))")
        }
        return out
    }
}

enum AppleScriptRunner {
    /// `script` must be a constant: user data is only ever passed through `args` (argv), never interpolated.
    static func run(_ script: String, _ args: [String] = []) throws -> String {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("satsuma-\(UUID().uuidString).applescript")
        try script.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        return try Shell.run("/usr/bin/osascript", [tmp.path] + args)
    }
}

/// Locates external engines. Order: bundled copy, Homebrew (Apple silicon / Intel), system.
/// A candidate is only used if it is owned by root or you and is not group/world-writable.
enum Ext {
    static let hints: [String: String] = [
        "ffmpeg": "Install it with `brew install ffmpeg`, or copy a build into Satsuma.app/Contents/Resources/bin.",
        "ffprobe": "It ships with ffmpeg (`brew install ffmpeg`).",
        "soffice": "Install LibreOffice (`brew install --cask libreoffice`) for Office-format conversions."
    ]

    static func find(_ name: String) -> String? {
        var dirs: [String] = []
        if let r = Bundle.main.resourcePath { dirs.append(r + "/bin") }
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]
        if name == "soffice" { dirs.insert("/Applications/LibreOffice.app/Contents/MacOS", at: 0) }
        for d in dirs {
            let p = d + "/" + name
            if FileManager.default.isExecutableFile(atPath: p), trusted(p) { return p }
        }
        return nil
    }

    private static func trusted(_ path: String) -> Bool {
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let a = try? FileManager.default.attributesOfItem(atPath: real),
              let perm = a[.posixPermissions] as? Int,
              let owner = a[.ownerAccountID] as? Int else { return false }
        return (owner == 0 || owner == Int(getuid())) && (perm & 0o022) == 0
    }

    static func require(_ name: String) throws -> String {
        if let p = find(name) { return p }
        throw ConvError.missingTool(name, hints[name] ?? "")
    }
}

func makeTempDir() throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("satsuma-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

func isDirectory(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
}

enum Output {
    private static let lock = NSLock()
    private static var issued: [(url: URL, at: Date)] = []

    /// Call before each unit of work; every path handed out by `destination`/`folder` is remembered so a failed
    /// unit can have its partial output removed.
    static func beginItem() { lock.lock(); issued.removeAll(); lock.unlock() }
    static func commitItem() { lock.lock(); issued.removeAll(); lock.unlock() }
    static func discardItem() {
        lock.lock()
        let list = issued
        issued.removeAll()
        lock.unlock()
        for (u, at) in list {
            // Only remove things created since we reserved the name.
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: u.path),
                  let created = attrs[.creationDate] as? Date,
                  created >= at.addingTimeInterval(-1) else { continue }
            try? FileManager.default.removeItem(at: u)
        }
    }

    /// File name without extension; treats `x.tar.gz` as `x`.
    static func baseName(_ src: URL) -> String {
        var name = src.deletingPathExtension().lastPathComponent
        let e = src.pathExtension.lowercased()
        if (e == "gz" || e == "tgz"), name.lowercased().hasSuffix(".tar") { name = String(name.dropLast(4)) }
        return name
    }

    static func directory(for src: URL) -> URL { Settings.resolvedOutputDirectory(for: src) }

    /// `lstat`-style existence check: a dangling symlink counts as existing, so we never write through one.
    private static func exists(_ u: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: u.path)) != nil
    }

    /// A non-existing destination URL, adding " 2", " 3"... when needed.
    static func destination(for src: URL, ext: String, suffix: String = "", base: String? = nil) -> URL {
        let dir = directory(for: src)
        let name = (base ?? baseName(src)) + suffix
        func make(_ n: String) -> URL {
            dir.appendingPathComponent(ext.isEmpty ? n : n + "." + ext)
        }
        var url = make(name)
        var i = 2
        while exists(url) {
            url = make("\(name) \(i)")
            i += 1
        }
        lock.lock()
        issued.append((url: url, at: Date()))
        lock.unlock()
        return url
    }

    /// Creates and returns a new unique folder next to the output location.
    static func folder(for src: URL, name: String) throws -> URL {
        let dest = destination(for: src, ext: "", base: name)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        return dest
    }
}

func parseTime(_ s: String) -> Double? {
    let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ":").map { Double($0) }
    guard !parts.isEmpty, !parts.contains(where: { $0 == nil }) else { return nil }
    return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
}

func parseAspect(_ s: String) -> (Double, Double)? {
    let t = s.lowercased().replacingOccurrences(of: "x", with: ":")
    let p = t.split(separator: ":").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard p.count == 2, p[0] > 0, p[1] > 0, p[0].isFinite, p[1].isFinite else { return nil }
    return (p[0], p[1])
}

/// Parses "1-3,5,8-" style page ranges (1-based). Returns 0-based indexes, always within the document.
func parsePageRange(_ s: String, pageCount: Int) -> [Int] {
    var result: [Int] = []
    for part in s.split(separator: ",") {
        let bits = part.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if bits.count == 1, let n = Int(bits[0]) {
            if n >= 1 && n <= pageCount { result.append(n - 1) }
        } else if bits.count == 2 {
            // Clamp before building the range so "1-2000000000" can't allocate gigabytes.
            let a = max(1, Int(bits[0]) ?? 1)
            let b = min(pageCount, Int(bits[1]) ?? pageCount)
            if a <= b { result += Array((a - 1)...(b - 1)) }
        }
    }
    return result
}

enum Prompt {
    /// Modal prompt with labelled text fields. Returns nil if cancelled.
    static func ask(_ spec: PromptSpec) -> [String]? {
        onMain {
            let alert = NSAlert()
            alert.messageText = spec.title
            alert.informativeText = spec.message
            var fieldsOut: [NSTextField] = []
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 6
            for (label, def) in spec.fields {
                let l = NSTextField(labelWithString: label)
                let f = NSTextField(string: def)
                f.frame.size.width = 260
                f.widthAnchor.constraint(equalToConstant: 260).isActive = true
                stack.addArrangedSubview(l)
                stack.addArrangedSubview(f)
                fieldsOut.append(f)
            }
            stack.setFrameSize(stack.fittingSize)
            alert.accessoryView = stack
            alert.addButton(withTitle: "Run")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            return fieldsOut.map { $0.stringValue }
        }
    }
}
