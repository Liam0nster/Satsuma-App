import SwiftUI
import ServiceManagement

enum ModKey: String, CaseIterable, Identifiable {
    case shift, command, control, option
    var id: String { rawValue }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .shift: return .shift
        case .command: return .command
        case .control: return .control
        case .option: return .option
        }
    }
    var symbol: String {
        switch self {
        case .shift: return "⇧"
        case .command: return "⌘"
        case .control: return "⌃"
        case .option: return "⌥"
        }
    }
    var label: String { "\(rawValue.capitalized) (\(symbol))" }
}

enum WheelKind: String {
    case convert, tools, actions
    var title: String {
        switch self {
        case .convert: return "Convert"
        case .tools: return "File Tools"
        case .actions: return "File Actions"
        }
    }
    var symbol: String {
        switch self {
        case .convert: return "arrow.triangle.2.circlepath"
        case .tools: return "wand.and.stars"
        case .actions: return "bolt.fill"
        }
    }
}

enum OutputMode: String, CaseIterable, Identifiable {
    case besideOriginal, customFolder
    var id: String { rawValue }
    var label: String { self == .besideOriginal ? "Next to the original file" : "A specific folder" }
}

enum CopyPathStyle: String, CaseIterable, Identifiable {
    case automatic, plain, shellEscaped
    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: return "Plain (shell-escaped only if the name has unusual characters)"
        case .plain: return "Always plain"
        case .shellEscaped: return "Always shell-escaped"
        }
    }
}

final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    @Published var convertKey: ModKey { didSet { d.set(convertKey.rawValue, forKey: "convertKey") } }
    @Published var toolsKey: ModKey { didSet { d.set(toolsKey.rawValue, forKey: "toolsKey") } }
    @Published var actionsKey: ModKey { didSet { d.set(actionsKey.rawValue, forKey: "actionsKey") } }
    @Published var outputMode: OutputMode { didSet { d.set(outputMode.rawValue, forKey: "outputMode") } }
    @Published var customOutputPath: String { didSet { d.set(customOutputPath, forKey: "customOutputPath") } }
    @Published var revealAfter: Bool { didSet { d.set(revealAfter, forKey: "revealAfter") } }
    @Published var trashOriginals: Bool { didSet { d.set(trashOriginals, forKey: "trashOriginals") } }
    @Published var jpegQuality: Double { didSet { d.set(jpegQuality, forKey: "jpegQuality") } }
    @Published var terminalBundleID: String { didSet { d.set(terminalBundleID, forKey: "terminalBundleID") } }
    @Published var copyPathStyle: CopyPathStyle { didSet { d.set(copyPathStyle.rawValue, forKey: "copyPathStyle") } }
    @Published var jobTimeoutMinutes: Int { didSet { d.set(jobTimeoutMinutes, forKey: "jobTimeoutMinutes") } }
    @Published var maxExtractGB: Int { didSet { d.set(maxExtractGB, forKey: "maxExtractGB") } }
    @Published var launchAtLogin: Bool {
        didSet {
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Launch at login failed: \(error)")
            }
        }
    }

    /// Max seconds a modifier key may be held and still count as a "tap".
    let tapWindow: TimeInterval = 0.4
    var lastCopyDirectory: String? {
        get { d.string(forKey: "lastCopyDir") }
        set { d.set(newValue, forKey: "lastCopyDir") }
    }

    init() {
        convertKey = ModKey(rawValue: d.string(forKey: "convertKey") ?? "") ?? .shift
        toolsKey = ModKey(rawValue: d.string(forKey: "toolsKey") ?? "") ?? .command
        actionsKey = ModKey(rawValue: d.string(forKey: "actionsKey") ?? "") ?? .control
        outputMode = OutputMode(rawValue: d.string(forKey: "outputMode") ?? "") ?? .besideOriginal
        customOutputPath = d.string(forKey: "customOutputPath") ?? ""
        revealAfter = d.object(forKey: "revealAfter") as? Bool ?? false
        trashOriginals = d.object(forKey: "trashOriginals") as? Bool ?? false
        jpegQuality = d.object(forKey: "jpegQuality") as? Double ?? 0.9
        terminalBundleID = d.string(forKey: "terminalBundleID") ?? "com.apple.Terminal"
        copyPathStyle = CopyPathStyle(rawValue: d.string(forKey: "copyPathStyle") ?? "") ?? .automatic
        jobTimeoutMinutes = d.object(forKey: "jobTimeoutMinutes") as? Int ?? 60
        maxExtractGB = d.object(forKey: "maxExtractGB") as? Int ?? 20
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func kind(for key: ModKey) -> WheelKind? {
        if key == convertKey { return .convert }
        if key == toolsKey { return .tools }
        if key == actionsKey { return .actions }
        return nil
    }

    // MARK: Thread-safe readers for background jobs
    // The @Published properties above are for the UI (main thread). Converters run on a background queue, so they
    // read the same values back from UserDefaults, which is thread-safe.

    static var jobTimeout: TimeInterval {
        let m = UserDefaults.standard.object(forKey: "jobTimeoutMinutes") as? Int ?? 60
        return TimeInterval(max(1, m) * 60)
    }

    static var maxExtractBytes: Int64 {
        let g = UserDefaults.standard.object(forKey: "maxExtractGB") as? Int ?? 20
        return Int64(max(1, g)) * 1_073_741_824
    }

    static var currentJPEGQuality: Double {
        UserDefaults.standard.object(forKey: "jpegQuality") as? Double ?? 0.9
    }

    static func resolvedOutputDirectory(for src: URL) -> URL {
        let d = UserDefaults.standard
        let mode = OutputMode(rawValue: d.string(forKey: "outputMode") ?? "") ?? .besideOriginal
        let path = d.string(forKey: "customOutputPath") ?? ""
        if mode == .customFolder, !path.isEmpty, isDirectory(URL(fileURLWithPath: path)) {
            return URL(fileURLWithPath: path)
        }
        return src.deletingLastPathComponent()
    }
}

/// Looks for the external engines off the main thread (it touches the disk and may launch a probe process).
final class EngineStatus: ObservableObject {
    @Published var ffmpeg: Bool?
    @Published var soffice: Bool?
    @Published var pages: Bool?
    @Published var gs: Bool?
    @Published var sandbox: Bool?

    func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let f = Ext.find("ffmpeg") != nil
            let o = Ext.find("soffice") != nil
            let p = Pages.installed
            let g = Ext.find("gs") != nil
            let s = Sandbox.available
            DispatchQueue.main.async {
                self.ffmpeg = f
                self.soffice = o
                self.pages = p
                self.gs = g
                self.sandbox = s
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var s = Settings.shared
    @StateObject private var engines = EngineStatus()

    private var duplicateKeys: Bool {
        Set([s.convertKey, s.toolsKey, s.actionsKey]).count < 3
    }

    var body: some View {
        Form {
            Section("Wheels — tap a key while dragging a file") {
                Picker("Convert wheel", selection: $s.convertKey) { ForEach(ModKey.allCases) { Text($0.label).tag($0) } }
                Picker("File tools wheel", selection: $s.toolsKey) { ForEach(ModKey.allCases) { Text($0.label).tag($0) } }
                Picker("File actions wheel", selection: $s.actionsKey) { ForEach(ModKey.allCases) { Text($0.label).tag($0) } }
                if duplicateKeys {
                    Text("Each wheel needs its own key.").foregroundColor(.red).font(.caption)
                }
                Text("Drag a file, tap the key (don't hold), then keep dragging. The wheel stays open until you drop or press Esc. Arrow keys move the selection, Return applies it, and tapping another wheel key switches wheels. Keyboard control is exclusive (keys don't leak into other apps) once Accessibility access is granted.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("Output") {
                Picker("Save results", selection: $s.outputMode) { ForEach(OutputMode.allCases) { Text($0.label).tag($0) } }
                if s.outputMode == .customFolder {
                    HStack {
                        Text(s.customOutputPath.isEmpty ? "No folder chosen" : s.customOutputPath)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Choose…") { chooseFolder() }
                    }
                }
                Toggle("Reveal results in Finder", isOn: $s.revealAfter)
                Toggle("Move originals to Trash after a successful conversion", isOn: $s.trashOriginals)
                HStack {
                    Text("Image quality (JPEG/HEIC/WebP)")
                    Slider(value: $s.jpegQuality, in: 0.3...1.0)
                    Text(String(format: "%.0f%%", s.jpegQuality * 100)).monospacedDigit()
                }
                Picker("Copy Path format", selection: $s.copyPathStyle) { ForEach(CopyPathStyle.allCases) { Text($0.label).tag($0) } }
            }
            Section("Safety limits") {
                Stepper("Stop a conversion after \(s.jobTimeoutMinutes) minutes", value: $s.jobTimeoutMinutes, in: 5...480, step: 5)
                Stepper("Archive extraction limit: \(s.maxExtractGB) GB", value: $s.maxExtractGB, in: 1...500)
            }
            Section("General") {
                Toggle("Launch at login", isOn: $s.launchAtLogin)
                TextField("Terminal app bundle ID", text: $s.terminalBundleID)
                Text("Input Monitoring lets Satsuma see modifier-key taps during a drag. Accessibility (optional) lets the wheel capture its own keys and cancel a drag when you press Return.")
                    .font(.caption).foregroundColor(.secondary)
                Button("Open Input Monitoring settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
                }
                Button("Open Accessibility settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            }
            Section("Conversion engines") {
                engineRow("ffmpeg (audio/video, WebP/AVIF fallback)", engines.ffmpeg)
                engineRow("LibreOffice (slides, spreadsheets, PDF → Office)", engines.soffice)
                engineRow("Pages (.pages conversions)", engines.pages)
                engineRow("Ghostscript (better PDF compression, optional)", engines.gs)
                engineRow("Network isolation for converters (sandbox-exec)", engines.sandbox)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 760)
        .onAppear { engines.refresh() }
    }

    /// `nil` means "still checking" (the checks run on a background thread, never while the view is being drawn).
    private func engineRow(_ name: String, _ ok: Bool?) -> some View {
        HStack {
            if let ok = ok {
                Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundColor(ok ? .green : .secondary)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(name)
        }
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        if p.runModal() == .OK, let u = p.url { s.customOutputPath = u.path }
    }
}
