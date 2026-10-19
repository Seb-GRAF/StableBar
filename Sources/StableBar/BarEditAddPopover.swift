import AppKit
import SwiftUI
import Observation

@MainActor
final class BarEditAddPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "Add here"
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = false
        autorecalculatesKeyViewLoop = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

struct BarEditAddPlacement {
    let frame: CGRect
    let arrowX: CGFloat

    init(size: CGSize, anchor: CGRect, bar: CGRect, visibleFrame: CGRect) {
        let width = min(size.width, max(0, visibleFrame.width - 16))
        let top = min(anchor.minY, bar.minY)
        let height = min(size.height, max(0, top - visibleFrame.minY - 8))
        let x = min(max(anchor.midX - width / 2, visibleFrame.minX + 8), visibleFrame.maxX - width - 8)
        frame = CGRect(x: x, y: top - height, width: width, height: height)
        arrowX = min(max(anchor.midX - x, 16), width - 16)
    }
}

/// A key-capable nonactivating child panel gives search the same keyboard grab as
/// the edit bar, without relying on NSPopover focus from a nonactivating parent.
@MainActor @Observable
final class BarEditAddPopover: NSObject {
    private(set) var displayID: Int?
    private(set) var position: WidgetPosition?
    private(set) var arrowX: CGFloat = 170
    @ObservationIgnored private var panel: BarEditAddPanel?
    @ObservationIgnored private var model: WidgetAddPopoverModel?
    @ObservationIgnored private weak var bar: BarPanel?
    @ObservationIgnored private weak var anchor: NSView?
    @ObservationIgnored private var visibleFrame: CGRect = .zero
    @ObservationIgnored private var localMonitor: Any?
    @ObservationIgnored private var globalMonitor: Any?
    @ObservationIgnored private let present: (BarPanel, BarEditAddPanel) -> Void
    @ObservationIgnored private let dismiss: (BarEditAddPanel) -> Void

    init(present: @escaping (BarPanel, BarEditAddPanel) -> Void = {
        $0.addChildWindow($1, ordered: .above)
        $1.makeKeyAndOrderFront(nil)
    }, dismiss: @escaping (BarEditAddPanel) -> Void = { $0.close() }) {
        self.present = present
        self.dismiss = dismiss
    }

    func isOpen(on bar: BarPanel) -> Bool { panel != nil && self.bar === bar }

    func show(store: BarStore, displayID: Int, position: WidgetPosition, anchor: NSView,
              visibleFrame: CGRect? = nil, setup: WidgetSetup? = nil) {
        guard store.barEditing.isActive, let bar = anchor.window as? BarPanel,
              let visibleFrame = visibleFrame ?? bar.screen?.visibleFrame else { return }
        if self.anchor === anchor, panel != nil { close(); return }
        close(focusBar: false)
        let setup = setup ?? WidgetSetup(store: store)
        let before: String?
        do { before = try setup.addAnchor(at: position) }
        catch {
            store.barEditing.report(error, on: displayID)
            return
        }
        let panel = BarEditAddPanel()
        panel.level = bar.level
        panel.collectionBehavior = bar.collectionBehavior
        panel.appearance = store.configuration?.bar.appearance.flatMap { NSAppearance(named: $0 == .dark ? .darkAqua : .aqua) }
        let model = WidgetAddPopoverModel(setup: setup, position: position, before: before) { [weak self, weak store] id in
            self?.close()
            if store?.customizationHistory.notice != nil { store?.barEditing.select(id) }
        }
        self.panel = panel
        self.model = model
        self.bar = bar
        self.anchor = anchor
        self.visibleFrame = visibleFrame
        self.displayID = displayID
        self.position = position
        panel.contentView = NSHostingView(rootView: AnyView(WidgetAddPopoverView(model: model, store: store,
            availableSize: CGSize(width: max(0, visibleFrame.width - 16), height: max(0, bar.frame.minY - visibleFrame.minY - 16)),
            changed: { [weak self] in self?.contentChanged() })
            .padding(.top, 9)
            .background(BarEditPopoverSurface(popover: self))))
        NotificationCenter.default.addObserver(self, selector: #selector(reposition), name: NSWindow.didMoveNotification, object: bar)
        NotificationCenter.default.addObserver(self, selector: #selector(reposition), name: NSWindow.didResizeNotification, object: bar)
        NotificationCenter.default.addObserver(self, selector: #selector(parentClosed), name: NSWindow.willCloseNotification, object: bar)
        reposition()
        NotificationCenter.default.post(name: Self.changedNotification, object: bar, userInfo: ["open": true])
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return handled ? nil : event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close(focusBar: false) }
        }
        present(bar, panel)
    }

    static let changedNotification = Notification.Name("BarEditAddPopoverChanged")

    @objc func reposition() {
        guard let panel, let bar, let anchor, let host = panel.contentView else { return }
        let rect = bar.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let placement = BarEditAddPlacement(size: host.fittingSize, anchor: rect, bar: bar.frame, visibleFrame: visibleFrame)
        arrowX = placement.arrowX
        panel.setFrame(placement.frame, display: true)
        panel.invalidateShadow()
    }

    private func contentChanged() {
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.reposition()
        }
    }

    func handle(_ event: NSEvent, keyWindow: NSWindow? = NSApp?.keyWindow, eventWindow: NSWindow? = nil) -> Bool {
        guard let panel else { return false }
        if event.type != .keyDown {
            let eventWindow = eventWindow ?? event.window
            var window = eventWindow
            while let inside = window {
                if inside === panel { return false }
                window = inside.sheetParent
            }
            // Let the open + finish its click, so its action can toggle closed.
            if event.type == .leftMouseDown, eventWindow === bar, let anchor,
               anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil)) { return false }
            close(focusBar: false)
            return false
        }
        guard event.window === panel || (event.window == nil && keyWindow === panel),
              event.modifierFlags.intersection([.shift, .command, .control, .option]).isEmpty else { return false }
        if event.keyCode == 53 { close(); return true }
        guard model?.setup.review == nil else { return false }
        switch event.keyCode {
        case 125: model?.move(by: 1)
        case 126: model?.move(by: -1)
        case 123: return model?.moveColumn(by: -1) ?? false
        case 124: return model?.moveColumn(by: 1) ?? false
        case 36, 76: model?.addSelected()
        default: return false
        }
        return true
    }

    @objc private func parentClosed() { close(focusBar: false) }

    func close(focusBar: Bool = true) {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        model?.cancel()
        let parent = bar
        if let parent { NotificationCenter.default.removeObserver(self, name: nil, object: parent) }
        if let panel {
            if focusBar, let parent, parent.isEditingBar { parent.makeKey() }
            panel.parent?.removeChildWindow(panel)
            dismiss(panel)
        }
        panel = nil
        model = nil
        anchor = nil
        bar = nil
        displayID = nil
        position = nil
        if let parent {
            NotificationCenter.default.post(name: Self.changedNotification, object: parent, userInfo: ["open": false])
        }
    }
}

struct BarEditAddAnchor: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct BarEditPopoverSurface: View {
    let popover: BarEditAddPopover
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = BarEditPopoverShape(arrowX: popover.arrowX)
        shape.fill(.regularMaterial)
            .overlay { shape.stroke(colorScheme == .dark ? Color.white.opacity(0.18) : .black.opacity(0.12), lineWidth: 0.5) }
    }
}

private struct BarEditPopoverShape: Shape {
    let arrowX: CGFloat
    func path(in rect: CGRect) -> Path {
        let bottom = max(19, rect.height)
        var path = Path()
        path.move(to: CGPoint(x: 10, y: 9))
        path.addLine(to: CGPoint(x: arrowX - 9, y: 9))
        path.addLine(to: CGPoint(x: arrowX, y: 0))
        path.addLine(to: CGPoint(x: arrowX + 9, y: 9))
        path.addLine(to: CGPoint(x: rect.width - 10, y: 9))
        path.addQuadCurve(to: CGPoint(x: rect.width, y: 19), control: CGPoint(x: rect.width, y: 9))
        path.addLine(to: CGPoint(x: rect.width, y: bottom - 10))
        path.addQuadCurve(to: CGPoint(x: rect.width - 10, y: bottom), control: CGPoint(x: rect.width, y: bottom))
        path.addLine(to: CGPoint(x: 10, y: bottom))
        path.addQuadCurve(to: CGPoint(x: 0, y: bottom - 10), control: CGPoint(x: 0, y: bottom))
        path.addLine(to: CGPoint(x: 0, y: 19))
        path.addQuadCurve(to: CGPoint(x: 10, y: 9), control: CGPoint(x: 0, y: 9))
        path.closeSubpath()
        return path
    }
}
