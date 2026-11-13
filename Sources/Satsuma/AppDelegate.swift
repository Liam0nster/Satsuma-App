import AppKit
import SwiftUI
import ApplicationServices
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildMenu()

        // Input Monitoring: needed to see modifier-key taps while another app is active.
        // Accessibility is NOT requested here. It is optional (exclusive keyboard control of the wheel, cancelling a
        // drag with Return); the user can grant it from Settings.
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }

        DragMonitor.shared.start()

        // ⌃⌥↩ with Finder in front opens the wheel for Finder's selection. A registered hotkey needs no keystroke monitoring.
        HotKey.shared.onPress = { DragMonitor.shared.openFinderSelection(fromHotkey: true) }
        HotKey.shared.register(keyCode: kVK_Return, modifiers: controlKey | optionKey)
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "circle.hexagongrid.fill", accessibilityDescription: "Satsuma")
        }
        let menu = NSMenu()
        let s = Settings.shared
        let hint = NSMenuItem(title: "Drag a file, then tap \(s.convertKey.symbol) convert · \(s.toolsKey.symbol) tools · \(s.actionsKey.symbol) actions",
                              action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())
        menu.addItem(item("Choose Files…", #selector(chooseFiles)))
        menu.addItem(item("Use Finder Selection  (⌃⌥↩ in Finder)", #selector(finderSelection)))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Satsuma", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func chooseFiles() {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = true
        p.allowsMultipleSelection = true
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK, !p.urls.isEmpty else { return }
        let c = NSScreen.main?.frame ?? .zero
        WheelController.shared.show(kind: .convert, files: p.urls, at: NSPoint(x: c.midX, y: c.midY), source: .explicit)
    }

    @objc private func finderSelection() {
        // Menu clicks aren't "from the hotkey": ask Finder directly and centre the wheel.
        DragMonitor.shared.openFinderSelection(fromHotkey: false)
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 760),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Satsuma Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView())
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
