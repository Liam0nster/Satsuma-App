import Foundation
import AppKit
import ApplicationServices
import Carbon.HIToolbox

// MARK: - Limits

enum Limits {
    /// Largest decoded image we will allocate (pixels).
    static let maxImagePixels = 150_000_000
    /// Largest rendered PDF page we will allocate (pixels); bigger pages are rendered at a lower DPI.
    static let maxPDFRenderPixels = 100_000_000.0
}

// MARK: - Network-isolated child processes

/// Converters (ffmpeg, LibreOffice, Ghostscript, Quick Look) parse untrusted files. We run them under
/// `sandbox-exec` with outbound IP networking denied and credential folders unreadable.
/// `sandbox-exec` is deprecated but still ships with macOS; if it is missing or the profile is rejected we
/// fall back to running without it (Settings shows which case you are in).
enum Sandbox {
    static var profile: String {
        let home = NSHomeDirectory()
        func quoted(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let secrets = [".ssh", ".aws", ".gnupg", "Library/Keychains"]
            .map { "(deny file-read* (subpath \(quoted(home + "/" + $0))))" }
            .joined()
        return "(version 1)(allow default)(deny network-outbound (remote ip))" + secrets
    }

    static let available: Bool = {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else { return false }
        return (try? Shell.run("/usr/bin/sandbox-exec", ["-p", profile, "/usr/bin/true"], offline: false)) != nil
    }()
}

// MARK: - Quarantine ("downloaded from the internet") propagation

/// Outputs inherit the source's quarantine flag so Gatekeeper still checks anything that came from the internet.
enum Quarantine {
    static let key = "com.apple.quarantine"

    static func value(of url: URL) -> Data? {
        let n = getxattr(url.path, key, nil, 0, 0, XATTR_NOFOLLOW)
        guard n > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: n)
        let r = getxattr(url.path, key, &buf, n, 0, XATTR_NOFOLLOW)
        guard r > 0 else { return nil }
        return Data(buf.prefix(r))
    }

    static func apply(_ data: Data, to url: URL) {
        data.withUnsafeBytes { p in
            _ = setxattr(url.path, key, p.baseAddress, data.count, 0, XATTR_NOFOLLOW)
        }
    }

    /// If any source is quarantined, mark every output (and everything inside output folders) the same way.
    static func propagate(from sources: [URL], to outputs: [URL]) {
        guard let v = sources.lazy.compactMap({ value(of: $0) }).first else { return }
        for o in outputs {
            apply(v, to: o)
            if isDirectory(o), let en = FileManager.default.enumerator(at: o, includingPropertiesForKeys: nil) {
                for case let u as URL in en { apply(v, to: u) }
            }
        }
    }
}

// MARK: - Extracted-tree hygiene

enum Sanitize {
    /// Deletes FIFOs, sockets and devices from an extracted tree and, optionally, every symlink.
    /// Links are never followed while scanning.
    static func prune(_ root: URL, removeSymlinks: Bool) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return }
        var doomed: [URL] = []
        for case let u as URL in en {
            let v = try? u.resourceValues(forKeys: Set(keys))
            if v?.isSymbolicLink == true {
                if removeSymlinks { doomed.append(u) }
                continue
            }
            if v?.isRegularFile != true && v?.isDirectory != true { doomed.append(u) }
        }
        for u in doomed { try? fm.removeItem(at: u) }
    }

    /// Returns the fully resolved URL if `file` really lives inside `root`, otherwise nil.
    /// Use the returned URL for reading so the check and the read agree.
    static func inside(_ root: URL, _ file: URL) -> URL? {
        let r = root.standardizedFileURL.resolvingSymlinksInPath().path
        let f = file.standardizedFileURL.resolvingSymlinksInPath()
        return (f.path == r || f.path.hasPrefix(r + "/")) ? f : nil
    }
}

// MARK: - Keyboard capture while the wheel is open

/// Installed only while the wheel is on screen.
/// With Accessibility access it is an active event tap that *consumes* the wheel's keys, so they never reach the
/// app underneath (no accidental rename in Finder). Without it, a listen-only monitor is used for drag-started
/// wheels only (those keys still reach the other app); click-opened wheels then use the mouse only.
final class KeyCapture {
    static let shared = KeyCapture()

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fallbackMonitor: Any?
    private var wanted = false
    fileprivate var swallowedDown = Set<Int>()

    func start(observeOnlyOK: Bool) {
        wanted = true
        guard tap == nil, fallbackMonitor == nil else { return }
        swallowedDown.removeAll()

        let mask = ((1 as CGEventMask) << CGEventMask(CGEventType.keyDown.rawValue))
                 | ((1 as CGEventMask) << CGEventMask(CGEventType.keyUp.rawValue))
        let callback: CGEventTapCallBack = { _, type, event, _ in
            let cap = KeyCapture.shared
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = cap.tap { CGEvent.tapEnable(tap: t, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            if type == .keyUp {
                if cap.swallowedDown.remove(code) != nil { return nil }
                return Unmanaged.passUnretained(event)
            }
            if cap.handle(code) {
                cap.swallowedDown.insert(code)
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        if let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                     eventsOfInterest: mask, callback: callback, userInfo: nil) {
            tap = t
            let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
            runLoopSource = src
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
            CGEvent.tapEnable(tap: t, enable: true)
        } else if observeOnlyOK {
            fallbackMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
                _ = self?.handle(Int(e.keyCode))
            }
        }
    }

    func stop() {
        wanted = false
        // Tear down a little later: we may be inside the tap callback, and the key-up of the key that closed the
        // wheel should still be swallowed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            guard !wanted else { return }
            if let t = tap {
                CGEvent.tapEnable(tap: t, enable: false)
                CFMachPortInvalidate(t)
            }
            if let s = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
            tap = nil
            runLoopSource = nil
            if let m = fallbackMonitor { NSEvent.removeMonitor(m) }
            fallbackMonitor = nil
            swallowedDown.removeAll()
        }
    }

    /// Returns true if the wheel used the key (and it should not reach the app underneath).
    @discardableResult
    fileprivate func handle(_ keyCode: Int) -> Bool {
        let wheel = WheelController.shared
        guard wheel.isOpen else { return false }
        switch keyCode {
        case 123, 126: wheel.move(-1); return true               // ← ↑
        case 124, 125: wheel.move(1); return true                // → ↓
        case 36, 76: wheel.activateFromKeyboard(); return true   // Return / Enter
        case 53:                                                  // Esc
            let fromDrag = wheel.cameFromDrag
            wheel.close()
            return !fromDrag    // let Esc through to the OS so it cancels an in-flight drag
        default: return false
        }
    }
}

// MARK: - Global hotkey (no keystroke monitoring needed)

/// Registers a system hotkey with Carbon. Unlike a key monitor this needs no Input Monitoring permission and
/// only ever sees the one combination.
final class HotKey {
    static let shared = HotKey()
    var onPress: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var handlerInstalled = false

    func register(keyCode: Int, modifiers: Int) {
        if !handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            _ = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                HotKey.shared.onPress?()
                return noErr
            }, 1, &spec, nil, nil)
            handlerInstalled = true
        }
        let id = EventHotKeyID(signature: OSType(0x53415453), id: 1)   // 'SATS'
        _ = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref)
    }
}
