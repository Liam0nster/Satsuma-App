import Foundation
import AppKit
import ApplicationServices
import SwiftUI

// MARK: - Model

struct WheelItem: Identifiable {
    let id = UUID()
    let title: String
    let symbol: String?
    let run: ([URL]) -> Void
}

final class WheelModel: ObservableObject {
    @Published var kind: WheelKind = .convert
    @Published var items: [WheelItem] = []
    @Published var highlighted: Int?
    @Published var files: [URL] = []
    @Published var message: String?

    var summary: String {
        if files.count == 1 { return files[0].lastPathComponent }
        return "\(files.count) items"
    }
}

enum WheelGeometry {
    static let size: CGFloat = 420
    static let ringRadius: CGFloat = 150
    static let innerRadius: CGFloat = 62
    static let outerRadius: CGFloat = 210

    /// Offset from the wheel centre in screen (y-down) coordinates; item 0 sits at the top, going clockwise.
    static func offset(_ i: Int, of n: Int) -> CGPoint {
        let a = Double(i) * 2 * Double.pi / Double(max(n, 1))
        return CGPoint(x: ringRadius * CGFloat(sin(a)), y: -ringRadius * CGFloat(cos(a)))
    }

    /// `p` is relative to the centre in AppKit (y-up) coordinates.
    static func index(for p: CGPoint, count n: Int) -> Int? {
        guard n > 0 else { return nil }
        let dist = hypot(p.x, p.y)
        guard dist >= innerRadius, dist <= outerRadius + 40 else { return nil }
        var theta = atan2(Double(p.x), Double(p.y))   // 0 at top, clockwise positive
        if theta < 0 { theta += 2 * Double.pi }
        let step = 2 * Double.pi / Double(n)
        return Int((theta / step).rounded()) % n
    }
}

// MARK: - Which items does each wheel show?

enum WheelBuilder {
    static func build(kind: WheelKind, files: [URL]) -> (items: [WheelItem], message: String?) {
        switch kind {
        case .convert:
            guard let _ = Formats.category(of: files) else {
                return ([], "No conversions for this selection.\nTap \(Settings.shared.actionsKey.symbol) for file actions.")
            }
            let targets = Formats.commonTargets(for: files)
            if targets.isEmpty { return ([], "No conversions for this file type.\nTap \(Settings.shared.actionsKey.symbol) for file actions.") }
            let items = targets.map { t in
                WheelItem(title: Formats.label(t), symbol: nil) { files in Runner.convert(files, to: t) }
            }
            return (items, nil)

        case .tools:
            let tools = Tools.applicable(to: files)
            if tools.isEmpty { return ([], "No file tools for this selection.") }
            let items = tools.map { t in
                WheelItem(title: t.title, symbol: t.symbol) { files in Runner.tool(t, files: files) }
            }
            return (items, nil)

        case .actions:
            let items = [
                WheelItem(title: "AirDrop", symbol: "dot.radiowaves.left.and.right") { FileActions.airDrop($0) },
                WheelItem(title: "Float", symbol: "pin.fill") { FileActions.float($0) },
                WheelItem(title: "Copy", symbol: "doc.on.doc") { FileActions.copyOrMove($0, move: false) },
                WheelItem(title: "Move", symbol: "folder") { FileActions.copyOrMove($0, move: true) },
                WheelItem(title: "Copy Path", symbol: "text.cursor") { FileActions.copyPath($0) },
                WheelItem(title: "Terminal", symbol: "terminal") { FileActions.terminal($0) }
            ]
            return (items, nil)
        }
    }
}

// MARK: - SwiftUI wheel

struct WheelView: View {
    @ObservedObject var m: WheelModel

    var body: some View {
        let S = WheelGeometry.size
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: S - 20, height: S - 20)
                .overlay(Circle().stroke(Color.orange.opacity(0.55), lineWidth: 2))
                .shadow(color: .black.opacity(0.35), radius: 18)
            Circle()
                .fill(Color.black.opacity(0.18))
                .frame(width: WheelGeometry.innerRadius * 2, height: WheelGeometry.innerRadius * 2)

            VStack(spacing: 3) {
                Image(systemName: m.kind.symbol).font(.system(size: 18, weight: .semibold)).foregroundColor(.orange)
                Text(m.kind.title).font(.system(size: 12, weight: .bold))
                Text(m.summary).font(.system(size: 9)).foregroundColor(.secondary)
                    .lineLimit(1).truncationMode(.middle).frame(width: 100)
            }

            if let msg = m.message {
                Text(msg)
                    .font(.system(size: 12)).multilineTextAlignment(.center).foregroundColor(.secondary)
                    .frame(width: 220).offset(y: 110)
            }

            ForEach(Array(m.items.enumerated()), id: \.element.id) { i, item in
                let o = WheelGeometry.offset(i, of: m.items.count)
                Chip(item: item, highlighted: m.highlighted == i)
                    .position(x: S / 2 + o.x, y: S / 2 + o.y)
            }
        }
        .frame(width: S, height: S)
    }
}

struct Chip: View {
    let item: WheelItem
    let highlighted: Bool
    var body: some View {
        VStack(spacing: 2) {
            if let s = item.symbol { Image(systemName: s).font(.system(size: 15, weight: .semibold)) }
            Text(item.title).font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .foregroundColor(.white)
        .frame(width: 68, height: item.symbol == nil ? 36 : 48)
        .background(RoundedRectangle(cornerRadius: 14).fill(highlighted ? Color.orange : Color.black.opacity(0.4)))
        .scaleEffect(highlighted ? 1.15 : 1.0)
        .animation(.easeOut(duration: 0.12), value: highlighted)
    }
}

// MARK: - AppKit plumbing

final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The drop target. Computes which wheel segment the pointer is over and applies it on drop.
final class WheelDropView: NSView {
    weak var controller: WheelController?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func update(windowPoint: NSPoint) {
        guard let c = controller else { return }
        let p = convert(windowPoint, from: nil)
        let rel = CGPoint(x: p.x - bounds.midX, y: p.y - bounds.midY)
        let idx = WheelGeometry.index(for: rel, count: c.model.items.count)
        if c.model.highlighted != idx { c.model.highlighted = idx }
    }

    // Drag destination
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        update(windowPoint: sender.draggingLocation)
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        update(windowPoint: sender.draggingLocation)
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { controller?.model.highlighted = nil }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        update(windowPoint: sender.draggingLocation)
        if let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                           options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            controller?.model.files = urls
        }
        return controller?.activateHighlighted() ?? false
    }

    // Hover + click (used when the wheel is opened without a drag)
    override func mouseMoved(with event: NSEvent) { update(windowPoint: event.locationInWindow) }
    override func mouseDown(with event: NSEvent) {
        update(windowPoint: event.locationInWindow)
        if controller?.model.highlighted == nil { controller?.close() } else { _ = controller?.activateHighlighted() }
    }
    override func rightMouseDown(with event: NSEvent) { controller?.close() }
}

final class WheelPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Invisible, screen-sized drop target shown while a drag is still in flight after a keyboard selection.
/// It swallows the drop so releasing the mouse can't move or copy the original file into whatever is underneath.
final class CatcherView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .URL, .string])
    }
    required init?(coder: NSCoder) { fatalError("not supported") }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { true }   // accepted, nothing done
}

// MARK: - Controller

final class WheelController {
    enum Source { case drag, explicit }

    static let shared = WheelController()
    let model = WheelModel()
    private(set) var isOpen = false
    private var source: Source = .explicit
    private var panel: WheelPanel?
    private var pollTimer: Timer?
    private var releasedAt: TimeInterval?
    private var catcher: WheelPanel?
    private var catcherTimer: Timer?

    var cameFromDrag: Bool { source == .drag }

    func show(kind: WheelKind, files: [URL], at point: NSPoint, source: Source) {
        self.source = source
        releasedAt = nil
        model.files = files
        apply(kind)

        let size = WheelGeometry.size
        var origin = NSPoint(x: point.x - size / 2, y: point.y - size / 2)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main {
            let f = screen.frame
            origin.x = min(max(origin.x, f.minX), f.maxX - size)
            origin.y = min(max(origin.y, f.minY), f.maxY - size)
        }
        let p = panel ?? makePanel()
        p.setFrame(NSRect(origin: origin, size: NSSize(width: size, height: size)), display: true)
        p.orderFrontRegardless()
        isOpen = true
        KeyCapture.shared.start(observeOnlyOK: source == .drag)
        startPolling()
    }

    func switchTo(_ kind: WheelKind) {
        guard isOpen, kind != model.kind else { return }
        apply(kind)
    }

    private func apply(_ kind: WheelKind) {
        model.kind = kind
        let built = WheelBuilder.build(kind: kind, files: model.files)
        model.items = built.items
        model.message = built.message
        model.highlighted = nil
    }

    private func makePanel() -> WheelPanel {
        let size = WheelGeometry.size
        let p = WheelPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.acceptsMouseMovedEvents = true

        let drop = WheelDropView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        drop.controller = self
        let host = PassthroughHostingView(rootView: WheelView(m: model))
        host.frame = drop.bounds
        host.autoresizingMask = [.width, .height]
        drop.addSubview(host)
        p.contentView = drop
        panel = p
        return p
    }

    // Keyboard (called by KeyCapture)
    func move(_ delta: Int) {
        let n = model.items.count
        guard n > 0 else { return }
        let cur = model.highlighted ?? (delta > 0 ? -1 : 0)
        model.highlighted = ((cur + delta) % n + n) % n
    }

    /// Return key: apply the highlighted item. With nothing highlighted, Return does nothing (it doesn't close the
    /// wheel and strand the drag).
    func activateFromKeyboard() {
        guard model.highlighted != nil else { return }
        let wasDrag = source == .drag
        guard activateHighlighted() else { return }
        if wasDrag { holdDrop() }
    }

    @discardableResult
    func activateHighlighted() -> Bool {
        guard let i = model.highlighted, model.items.indices.contains(i) else { close(); return false }
        let item = model.items[i]
        let files = model.files
        close()
        DispatchQueue.main.async { item.run(files) }
        return true
    }

    func close() {
        pollTimer?.invalidate()
        pollTimer = nil
        panel?.orderOut(nil)
        isOpen = false
        model.highlighted = nil
        KeyCapture.shared.stop()
    }

    /// While a drag opened the wheel, close it shortly after the mouse button is released.
    private func startPolling() {
        pollTimer?.invalidate()
        guard source == .drag else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, self.isOpen else { return }
            if NSEvent.pressedMouseButtons & 1 == 0 {
                let now = ProcessInfo.processInfo.systemUptime
                if self.releasedAt == nil { self.releasedAt = now }
                if now - (self.releasedAt ?? now) > 0.4 { self.close() }   // dropped somewhere else
            } else {
                self.releasedAt = nil
            }
        }
    }

    // MARK: After a keyboard selection the drag is still in flight

    private func holdDrop() {
        // Cancel the drag if we are allowed to (posting Escape needs Accessibility access)…
        cancelDrag()
        // …and either way put an invisible net under the pointer until the button is released.
        showCatcher()
    }

    private func cancelDrag() {
        guard AXIsProcessTrusted() else { return }
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
    }

    private func showCatcher() {
        hideCatcher()
        let frame = NSScreen.screens.reduce(NSRect.null) { $0.union($1.frame) }
        guard !frame.isNull else { return }
        let p = WheelPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = NSColor(white: 0, alpha: 0.004)   // nearly invisible, but not fully transparent
        p.hasShadow = false
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.contentView = CatcherView(frame: NSRect(origin: .zero, size: frame.size))
        p.setFrame(frame, display: true)
        p.orderFrontRegardless()
        catcher = p

        let started = ProcessInfo.processInfo.systemUptime
        var released: TimeInterval?
        catcherTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] t in
            let now = ProcessInfo.processInfo.systemUptime
            if NSEvent.pressedMouseButtons & 1 == 0 {
                if released == nil { released = now }
                if now - (released ?? now) > 0.5 { self?.hideCatcher(); t.invalidate() }
            } else {
                released = nil
            }
            if now - started > 60 { self?.hideCatcher(); t.invalidate() }   // never leave a screen-sized panel up
        }
    }

    private func hideCatcher() {
        catcherTimer?.invalidate()
        catcherTimer = nil
        catcher?.orderOut(nil)
        catcher = nil
    }
}
