import Foundation
import AppKit

/// Watches for file drags system-wide and for "taps" of modifier keys during a drag.
///
/// It deliberately does NOT monitor ordinary key presses: only mouse events and modifier-key changes. Keyboard
/// control of the wheel is handled by `KeyCapture` (only while the wheel is open) and the Finder shortcut uses a
/// registered hotkey (`HotKey`), which never sees any other keystroke.
final class DragMonitor {
    static let shared = DragMonitor()

    private(set) var dragging = false
    private(set) var dragFiles: [URL] = []
    private var downChangeCount = 0
    private var pressed: [ModKey: TimeInterval] = [:]
    private var chord = false
    private var endTimer: Timer?

    func start() {
        observe(.leftMouseDown) { [weak self] _ in self?.mouseDown() }
        observe(.leftMouseDragged) { [weak self] _ in self?.mouseDragged() }
        observe(.flagsChanged) { [weak self] e in self?.flagsChanged(e) }
    }

    /// Registers both a global monitor (other apps are active) and a local one (we are active).
    private func observe(_ mask: NSEvent.EventTypeMask, _ handler: @escaping (NSEvent) -> Void) {
        NSEvent.addGlobalMonitorForEvents(matching: mask) { handler($0) }
        NSEvent.addLocalMonitorForEvents(matching: mask) { handler($0); return $0 }
    }

    // MARK: Drag detection

    private func mouseDown() {
        downChangeCount = NSPasteboard(name: .drag).changeCount
        dragging = false
        dragFiles = []
    }

    private func mouseDragged() {
        guard !dragging else { return }
        let pb = NSPasteboard(name: .drag)
        guard pb.changeCount != downChangeCount,
              let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return }
        dragging = true
        dragFiles = urls
        endTimer?.invalidate()
        endTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] t in
            if NSEvent.pressedMouseButtons & 1 == 0 {
                self?.dragging = false
                self?.dragFiles = []
                t.invalidate()
            }
        }
    }

    // MARK: Modifier taps

    private func flagsChanged(_ e: NSEvent) {
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let now = ProcessInfo.processInfo.systemUptime
        let downNow = Set(ModKey.allCases.filter { flags.contains($0.flag) })
        let before = Set(pressed.keys)

        for k in downNow.subtracting(before) {
            if !before.isEmpty { chord = true }          // another modifier already held
            pressed[k] = now
        }
        for k in before.subtracting(downNow) {
            let t0 = pressed[k] ?? 0
            pressed[k] = nil
            if !chord && now - t0 <= Settings.shared.tapWindow { tapped(k) }
        }
        if pressed.isEmpty { chord = false }
    }

    private func tapped(_ key: ModKey) {
        guard let kind = Settings.shared.kind(for: key) else { return }
        let wheel = WheelController.shared
        if wheel.isOpen {
            wheel.switchTo(kind)
        } else if dragging, !dragFiles.isEmpty {
            wheel.show(kind: kind, files: dragFiles, at: NSEvent.mouseLocation, source: .drag)
        }
    }

    // MARK: Finder selection

    /// Opens the Convert wheel for whatever is selected in Finder.
    /// `fromHotkey`: the wheel appears at the pointer and Finder must be frontmost; from the menu it is centred.
    func openFinderSelection(fromHotkey: Bool = true) {
        if fromHotkey, NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.apple.finder" {
            HUD.failed("Select files in Finder first, then press ⌃⌥↩ with Finder in front.")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<[URL], Error>
            do { result = .success(try DragMonitor.finderSelection()) } catch { result = .failure(error) }
            DispatchQueue.main.async {
                switch result {
                case .failure:
                    HUD.failed("Couldn’t read Finder’s selection. Allow Satsuma to control Finder in System Settings → Privacy & Security → Automation.")
                case .success(let urls):
                    guard !urls.isEmpty else { HUD.failed("Nothing is selected in Finder."); return }
                    var point = NSEvent.mouseLocation
                    if !fromHotkey, let c = NSScreen.main?.frame { point = NSPoint(x: c.midX, y: c.midY) }
                    WheelController.shared.show(kind: .convert, files: urls, at: point, source: .explicit)
                }
            }
        }
    }

    /// Asks Finder for its selection as JSON (JavaScript for Automation). JSON escapes newlines and quotes inside
    /// names and each path arrives as a percent-encoded URL, so a hostile file name can never split into extra paths.
    static func finderSelection() throws -> [URL] {
        let js = "JSON.stringify(Application('Finder').selection().map(function(i){return i.url();}))"
        let out = try Shell.run("/usr/bin/osascript", ["-l", "JavaScript", "-e", js])
        guard let line = out.split(separator: "\n").last(where: { $0.hasPrefix("[") }),
              let data = String(line).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let list = obj as? [String] else { return [] }
        return list.compactMap { URL(string: $0) }.filter { $0.isFileURL }.map { $0.standardizedFileURL }
    }
}
