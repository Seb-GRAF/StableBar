import AppKit
import SwiftUI

@MainActor
final class PopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    @objc var hasKeyAppearance: Bool { true }
}

@MainActor
final class PopupRevealView: NSView {
    init(content: NSView, size: NSSize) {
        super.init(frame: NSRect(origin: .zero, size: size))
        clipsToBounds = true
        content.frame = bounds
        // Keep the scroll viewport full-sized and pinned to the top while the panel folds.
        content.autoresizingMask = [.minYMargin]
        addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError("PopupRevealView is created programmatically.") }
}

@MainActor
final class WidgetPopup {
    private let present: (PopupPanel) -> Void
    private var panel: PopupPanel?
    private var widgetID: String?
    private weak var store: BarStore?
    private weak var anchor: NSView?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var animation: WidgetAnimation?

    init(present: @escaping (PopupPanel) -> Void = { $0.makeKeyAndOrderFront(nil) }) {
        self.present = present
    }

    var isOpen: Bool { panel != nil }

    func toggle(_ popup: PopupConfiguration, widget: WidgetConfiguration, defaults: WidgetStyle,
                store: BarStore, anchor: NSView) {
        guard store.barEditing.allowsWidgetActions else { return }
        if self.anchor === anchor && widgetID == widget.id {
            close()
            return
        }
        close()
        let window = anchor.window!
        let screen = window.screen!
        let frame = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let popupTop = popupAttachmentTop(anchor: frame, window: window.frame, geometry: (window as? BarPanel)?.barGeometry)
        let style = popup.baseStyle(widget: widget, defaults: defaults)
        let appearance = WidgetAppearance(style, defaults: WidgetStyle())
        let shadowInset = CGFloat(appearance.shadowRadius * 2 + 2)
        let width = min(CGFloat(popup.style.width ?? 360), screen.visibleFrame.width - shadowInset * 2 - 16)
        let host = NSHostingView(rootView: PopupView(popup: popup, style: style, store: store, widget: widget)
            .frame(width: width)
            .shadow(color: appearance.shadowColor, radius: appearance.shadowRadius, y: 1)
            .padding(shadowInset))
        let height = min(popup.height.map { CGFloat($0) } ?? host.fittingSize.height - shadowInset * 2,
                         popupTop - screen.visibleFrame.minY - shadowInset * 2 - 8 - popup.offset)
        let alignedX: CGFloat = switch popup.alignment {
        case .leading: frame.minX
        case .center: frame.midX - width / 2
        case .trailing: frame.maxX - width
        }
        let x = min(max(alignedX, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - width - 8)
        let panel = PopupPanel(contentRect: NSRect(x: x - shadowInset, y: popupTop - height - popup.offset - shadowInset,
                                                  width: width + shadowInset * 2, height: height + shadowInset * 2),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "\(widget.id) popup"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.autorecalculatesKeyViewLoop = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        panel.appearance = store.configuration?.bar.appearance.flatMap { NSAppearance(named: $0 == .dark ? .darkAqua : .aqua) }
        panel.contentView = PopupRevealView(content: host, size: panel.frame.size)
        self.panel = panel
        widgetID = widget.id
        self.store = store
        store.setPopupVisibleWidget(widget.id, anchor: anchor)
        self.anchor = anchor
        animation = popup.animation
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self else { return false }
                if event.type == .keyDown {
                    if event.keyCode == 53 {
                        self.close()
                        return true
                    }
                } else if event.window !== self.panel {
                    let onAnchor = event.window === anchor.window && anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil))
                    if !onAnchor { self.close() }
                }
                return false
            }
            return handled ? nil : event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        let fullFrame = panel.frame
        if popup.animation != nil {
            panel.alphaValue = 0
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                panel.setFrame(NSRect(x: fullFrame.minX, y: fullFrame.maxY - 1, width: fullFrame.width, height: 1), display: false)
            }
        }
        present(panel)
        if let animation = popup.animation {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = animation.duration
                context.timingFunction = animation.timingFunction
                panel.animator().alphaValue = 1
                panel.animator().setFrame(fullFrame, display: true)
            }
        }
    }

    func close() {
        store?.setPopupVisibleWidget(nil)
        store = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        if let panel, let animation {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = animation.duration
                context.timingFunction = animation.timingFunction
                panel.animator().alphaValue = 0
                if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    let frame = panel.frame
                    panel.animator().setFrame(NSRect(x: frame.minX, y: frame.maxY - 1, width: frame.width, height: 1), display: true)
                }
            } completionHandler: {
                Task { @MainActor in panel.close() }
            }
        } else {
            panel?.close()
        }
        panel = nil
        widgetID = nil
        anchor = nil
        animation = nil
    }

    func removeAnchor(_ view: NSView) {
        if anchor === view { close() }
    }
}

struct PopupAnchor: NSViewRepresentable {
    let view: NSView
    let popup: WidgetPopup
    var id: String?

    func makeNSView(context: Context) -> NSView {
        view.identifier = id.map { NSUserInterfaceItemIdentifier($0) }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    func makeCoordinator() -> WidgetPopup { popup }

    static func dismantleNSView(_ nsView: NSView, coordinator: WidgetPopup) {
        coordinator.removeAnchor(nsView)
    }
}
