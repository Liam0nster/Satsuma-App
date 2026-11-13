import Foundation
import AppKit
import SwiftUI
import QuickLookThumbnailing

/// The six file actions: AirDrop, Float, Copy, Move, Copy Path, Terminal.
/// These work on folders, mixed selections, and files with no conversions.
enum FileActions {
    static func airDrop(_ files: [URL]) {
        guard let service = NSSharingService(named: .sendViaAirDrop) else {
            HUD.failed("AirDrop isn’t available on this Mac.")
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: files)
    }

    static func float(_ files: [URL]) {
        for f in files { FloatController.float(f) }
    }

    static func copyOrMove(_ files: [URL], move: Bool) {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        p.prompt = move ? "Move Here" : "Copy Here"
        p.message = (move ? "Move " : "Copy ") + (files.count == 1 ? "“\(files[0].lastPathComponent)”" : "\(files.count) items") + " to…"
        if let last = Settings.shared.lastCopyDirectory { p.directoryURL = URL(fileURLWithPath: last) }
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK, let dir = p.url else { return }
        Settings.shared.lastCopyDirectory = dir.path

        var done: [URL] = []
        var failures = 0
        let fm = FileManager.default
        for f in files {
            var dest = dir.appendingPathComponent(f.lastPathComponent)
            var n = 2
            let base = f.deletingPathExtension().lastPathComponent
            while (try? fm.attributesOfItem(atPath: dest.path)) != nil {
                let ext = f.pathExtension
                dest = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
                n += 1
            }
            do {
                if move { try fm.moveItem(at: f, to: dest) } else { try fm.copyItem(at: f, to: dest) }
                done.append(dest)
            } catch { failures += 1 }
        }
        let verb = move ? "Moved" : "Copied"
        if failures > 0 && done.isEmpty { HUD.failed("Couldn’t \(move ? "move" : "copy") the selection.") }
        else { HUD.done("\(verb) \(done.count) item\(done.count == 1 ? "" : "s")" + (failures > 0 ? " (\(failures) failed)" : ""), outputs: done) }
    }

    /// Characters that make a path dangerous to paste into a shell (command substitution, separators, quotes…).
    static let shellRisky = CharacterSet(charactersIn: "`$;&|<>()\\\"'\n\r\t*?[]{}!#~")

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func copyPath(_ files: [URL]) {
        let style = Settings.shared.copyPathStyle
        let paths = files.map { $0.path }
        let risky = paths.contains { $0.rangeOfCharacter(from: FileActions.shellRisky) != nil }
        let escape = style == .shellEscaped || (style == .automatic && risky)
        let text = escape ? paths.map(shellQuote).joined(separator: " ") : paths.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        var msg = files.count == 1 ? "Path copied" : "\(files.count) paths copied"
        if escape { msg += " (shell-escaped)" }
        HUD.done(msg, outputs: [])
    }

    static func terminal(_ files: [URL]) {
        guard let first = files.first else { return }
        let dir = isDirectory(first) ? first : first.deletingLastPathComponent()
        let id = Settings.shared.terminalBundleID
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            HUD.failed("Terminal app not found.")
            return
        }
        NSWorkspace.shared.open([dir], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}

// MARK: - Float: a small always-on-top shelf for a file you can drag out again

/// Holds a notification token so the observer can remove itself when the window closes.
final class ObserverBox {
    var token: NSObjectProtocol?
}

enum FloatController {
    private static var windows: [NSPanel] = []

    static func float(_ url: URL) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 240),
                            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = url.lastPathComponent
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = FloatView(url: url, frame: NSRect(x: 0, y: 0, width: 220, height: 240))
        panel.center()
        panel.orderFrontRegardless()
        windows.append(panel)
        let box = ObserverBox()
        box.token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { _ in
            windows.removeAll { $0 === panel }
            if let t = box.token { NotificationCenter.default.removeObserver(t) }
        }
    }
}

final class FloatView: NSView, NSDraggingSource {
    let url: URL
    private var dragInProgress = false
    var image: NSImage { didSet { needsDisplay = true } }

    init(url: URL, frame: NSRect) {
        self.url = url
        self.image = NSWorkspace.shared.icon(forFile: url.path)
        super.init(frame: frame)
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 400, height: 400),
                                               scale: NSScreen.main?.backingScaleFactor ?? 2,
                                               representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
            guard let cg = rep?.cgImage else { return }
            DispatchQueue.main.async {
                self?.image = NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let target = bounds.insetBy(dx: 14, dy: 14)
        let s = image.size
        guard s.width > 0, s.height > 0 else { return }
        let scale = min(target.width / s.width, target.height / s.height)
        let w = s.width * scale, h = s.height * scale
        image.draw(in: NSRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h))
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragInProgress else { return }       // one drag session per gesture, not one per mouse move
        dragInProgress = true
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds.insetBy(dx: 30, dy: 30), contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { NSWorkspace.shared.open(url) }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragInProgress = false
    }
}

// MARK: - HUD (progress + result toast)

final class HUDModel: ObservableObject {
    enum State { case working, done, partial, failed }
    @Published var state: State = .working
    @Published var text = ""
    @Published var outputs: [URL] = []
}

struct HUDView: View {
    @ObservedObject var m: HUDModel
    var body: some View {
        HStack(spacing: 10) {
            switch m.state {
            case .working: ProgressView().controlSize(.small)
            case .done: Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
            case .partial: Image(systemName: "exclamationmark.circle.fill").foregroundColor(.orange)
            case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
            }
            Text(m.text).font(.system(size: 13, weight: .medium)).lineLimit(4)
            Spacer(minLength: 4)
            if (m.state == .done || m.state == .partial), !m.outputs.isEmpty {
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting(m.outputs) }
                    .buttonStyle(.link)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(width: 420, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.orange.opacity(0.5), lineWidth: 1))
    }
}

enum HUD {
    private static let model = HUDModel()
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func working(_ text: String) { present(.working, text, []) }
    static func done(_ text: String, outputs: [URL]) { present(.done, text, outputs); hide(after: 6) }
    static func partial(_ text: String, outputs: [URL]) { present(.partial, text, outputs); hide(after: 14) }
    static func failed(_ text: String) { present(.failed, text, []); hide(after: 10) }

    private static func present(_ state: HUDModel.State, _ text: String, _ outputs: [URL]) {
        onMain {
            hideWork?.cancel()
            model.state = state
            model.text = text
            model.outputs = outputs
            if panel == nil {
                let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 60),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                p.isOpaque = false
                p.backgroundColor = .clear
                p.hasShadow = true
                p.level = .statusBar
                p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                p.hidesOnDeactivate = false
                p.isReleasedWhenClosed = false
                let host = NSHostingView(rootView: HUDView(m: model))
                p.contentView = host
                panel = p
            }
            guard let p = panel else { return }
            if let host = p.contentView as? NSHostingView<HUDView> {
                let size = host.fittingSize
                p.setContentSize(size)
            }
            if let screen = NSScreen.main {
                let f = screen.visibleFrame
                p.setFrameOrigin(NSPoint(x: f.midX - p.frame.width / 2, y: f.maxY - p.frame.height - 16))
            }
            p.orderFrontRegardless()
        }
    }

    private static func hide(after seconds: Double) {
        onMain {
            let w = DispatchWorkItem { panel?.orderOut(nil) }
            hideWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
        }
    }
}

// MARK: - Jobs

/// One unit of work that succeeded: which sources it consumed and which files it produced.
struct JobItem {
    let sources: [URL]
    let outputs: [URL]
}

struct JobResult {
    var items: [JobItem] = []
    var failures: [String] = []
    var outputs: [URL] { items.flatMap { $0.outputs } }
}

enum Runner {
    /// Jobs run one at a time so they can't race each other for output names or share a LibreOffice profile.
    private static let queue = DispatchQueue(label: "satsuma.jobs", qos: .userInitiated)

    static func convert(_ files: [URL], to target: String) {
        let label = files.count == 1
            ? "Converting “\(files[0].lastPathComponent)” to \(Formats.label(target))…"
            : "Converting \(files.count) files to \(Formats.label(target))…"
        let trash = Settings.shared.trashOriginals
        run(label: label, trashSources: trash) {
            var r = JobResult()
            for f in files {
                Output.beginItem()
                do {
                    let out = try Converter.convert(f, to: target)
                    Output.commitItem()
                    r.items.append(JobItem(sources: [f], outputs: [out]))
                } catch {
                    Output.discardItem()       // remove any half-written output
                    r.failures.append("\(f.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if r.items.isEmpty, let first = r.failures.first { throw ConvError.failed(first) }
            return r
        }
    }

    static func tool(_ t: ToolDef, files: [URL]) {
        var params: [String] = []
        if let spec = t.prompt {
            guard let answers = Prompt.ask(spec) else { return }
            params = answers
        }
        run(label: "\(t.title)…", trashSources: false) {
            try Tools.execute(t, files: files, params: params)
        }
    }

    /// An output only counts as good if it exists and is not empty.
    private static func looksValid(_ u: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { return false }
        if isDir.boolValue { return true }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: u.path),
              let size = attrs[.size] as? NSNumber else { return false }
        return size.intValue > 0
    }

    static func run(label: String, trashSources: Bool, _ work: @escaping () throws -> JobResult) {
        HUD.working(label)
        queue.async {
            do {
                let r = try work()
                let outs = r.outputs
                // Outputs inherit the "downloaded from the internet" flag of their sources.
                for item in r.items { Quarantine.propagate(from: item.sources, to: item.outputs) }
                // Only sources whose conversion succeeded AND produced a real file may be trashed.
                let trashable = r.items
                    .filter { $0.outputs.allSatisfy { Runner.looksValid($0) } }
                    .flatMap { $0.sources }
                DispatchQueue.main.async {
                    let base = outs.count == 1 ? "Saved “\(outs[0].lastPathComponent)”" : "Saved \(outs.count) files"
                    if r.failures.isEmpty {
                        HUD.done(base, outputs: outs)
                    } else {
                        HUD.partial("\(base). \(r.failures.count) failed — " + r.failures.prefix(2).joined(separator: "; "), outputs: outs)
                    }
                    if Settings.shared.revealAfter { NSWorkspace.shared.activateFileViewerSelecting(outs) }
                    if trashSources, !trashable.isEmpty { NSWorkspace.shared.recycle(trashable, completionHandler: nil) }
                }
            } catch {
                DispatchQueue.main.async { HUD.failed(error.localizedDescription) }
            }
        }
    }
}
