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
        wantsLayer = true
        content.frame = bounds
        // Keep the scroll viewport full-sized and pinned to the top while the panel folds.
        content.autoresizingMask = [.minYMargin]
        addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError("PopupRevealView is created programmatically.") }
}

/// A popup's own shadow without the popup, for a window behind the popup's.
struct PopupShadowView: View {
    let cornerRadius: Double
    let color: Color
    let radius: Double
    let inset: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        shape.fill(.black)
            .padding(inset)
            .shadow(color: color, radius: radius, y: 1)
            // A translucent popup would show the shape through it.
            .mask {
                Rectangle().overlay { shape.padding(inset).blendMode(.destinationOut) }.compositingGroup()
            }
    }
}

struct PopupMorphView: View {
    let from: PopupView
    let to: PopupView
    let fromBox: CGRect
    let toBox: CGRect
    let glass: GlassSettings
    let animation: WidgetAnimation
    let finished: () -> Void
    @State private var moved = false

    var body: some View {
        let box = moved ? toBox : fromBox
        ZStack(alignment: .top) {
            from.frame(width: fromBox.width, height: fromBox.height).opacity(moved ? 0 : 1)
            to.frame(width: toBox.width, height: toBox.height).opacity(moved ? 1 : 0)
        }
        .frame(width: box.width, height: box.height, alignment: .top)
        .modifier(PopupBackground(style: moved ? to.style : from.style, glass: glass))
        .offset(x: box.minX, y: box.minY)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            withAnimation(animation.value, completionCriteria: .removed) { moved = true } completion: { finished() }
        }
    }
}

extension PopupTransition {
    @MainActor func animate(_ content: NSView, source: CGFloat, closing: Bool, with animation: WidgetAnimation) {
        let bounds = content.bounds
        let layer = content.layer!
        let change: CABasicAnimation
        switch self {
        case .unfold:
            let mask = CALayer()
            mask.backgroundColor = .black
            mask.anchorPoint = CGPoint(x: 0, y: 1)
            mask.frame = bounds
            layer.mask = mask
            change = animation.layerAnimation(keyPath: "bounds.size.height")
            change.fromValue = closing ? bounds.height : 0
            change.toValue = closing ? 0 : bounds.height
        case .fade, .slide, .zoom:
            let hidden = switch self {
            case .slide: CATransform3DMakeTranslation(0, 12, 0)
            case .zoom: scaled(0.5, around: CGPoint(x: source, y: bounds.maxY))
            default: scaled(0.97, around: CGPoint(x: bounds.midX, y: bounds.maxY))
            }
            change = animation.layerAnimation(keyPath: "transform")
            change.fromValue = closing ? CATransform3DIdentity : hidden
            change.toValue = closing ? hidden : CATransform3DIdentity
        }
        if closing {
            change.fillMode = .forwards
            change.isRemovedOnCompletion = false
        }
        (layer.mask ?? layer).add(change, forKey: "reveal")
    }

    private func scaled(_ scale: CGFloat, around point: CGPoint) -> CATransform3D {
        CATransform3DTranslate(CATransform3DScale(CATransform3DMakeTranslation(point.x, point.y, 0), scale, scale, 1), -point.x, -point.y, 0)
    }
}

@MainActor
final class WidgetPopup {
    private let present: (PopupPanel, Bool) -> Void
    private var panel: PopupPanel?
    private(set) var shadowWindow: NSPanel?
    private var widgetID: String?
    private weak var store: BarStore?
    private weak var anchor: NSView?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var animation: WidgetAnimation?
    private var transition = PopupTransition.fade
    private var source: CGFloat = 0
    private var hoverTask: Task<Void, Never>?
    private weak var hoveredAnchor: NSView?
    private var pointerInPopup = false
    private var pinned = false
    private var closesAfterClick = false
    private var shown: (view: PopupView, inset: CGFloat)?
    private var morph: (panel: PopupPanel, link: CADisplayLink)?

    init(present: @escaping (PopupPanel, Bool) -> Void = { panel, onHover in
        if onHover { panel.orderFront(nil) } else { panel.makeKeyAndOrderFront(nil) }
    }) {
        self.present = present
    }

    var isOpen: Bool { panel != nil }

    func toggle(_ popup: PopupConfiguration, widget: WidgetConfiguration, defaults: WidgetStyle,
                store: BarStore, anchor: NSView) {
        guard store.barEditing.allowsWidgetActions else { return }
        if self.anchor === anchor && widgetID == widget.id {
            if pinned { close() } else { keepOpen() }
            return
        }
        open(popup, widget: widget, defaults: defaults, store: store, anchor: anchor, onHover: false)
    }

    func hover(_ inside: Bool, store: BarStore, anchor: NSView, show: @escaping () -> Void) {
        guard !pinned else { return }
        if inside {
            hoverTask?.cancel()
            hoveredAnchor = anchor
            guard self.anchor !== anchor else { return }
            hoverTask = Task {
                do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
                guard store.barEditing.allowsWidgetActions else { return }
                show()
            }
        } else if hoveredAnchor === anchor {
            hoveredAnchor = nil
            hoverTask?.cancel()
            closeAfterHover()
        }
    }

    func hoverPopup(_ inside: Bool) {
        pointerInPopup = inside
        if inside { hoverTask?.cancel() } else { closeAfterHover() }
    }

    private func closeAfterHover() {
        guard !pinned, panel != nil, hoveredAnchor == nil, !pointerInPopup else { return }
        hoverTask?.cancel()
        hoverTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            self?.close()
        }
    }

    private func keepOpen() {
        pinned = true
        hoverTask?.cancel()
        panel?.makeKey()
    }

    func showTooltip(_ text: String, widget: WidgetConfiguration, defaults: WidgetStyle,
                     store: BarStore, anchor: NSView) {
        close()
        let window = anchor.window!
        let screen = window.screen!
        let frame = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let top = popupAttachmentTop(anchor: frame, window: window.frame, geometry: (window as? BarPanel)?.barGeometry)
        let kind = ScreenKind(BarDisplay(screen: screen))
        let style = resolveStyle([defaults, widget.style], states: StyleStates(mode: store.modePresentation(on: kind)))
        let appearance = WidgetAppearance(style, defaults: WidgetStyle())
        let shadowInset = CGFloat(appearance.shadowRadius * 2 + 2)
        let host = NSHostingView(rootView: Text(text)
            .font(appearance.font)
            .foregroundStyle(appearance.foreground)
            .padding(.horizontal, appearance.paddingHorizontal)
            .padding(.vertical, appearance.paddingVertical)
            .frame(maxWidth: 320 - shadowInset * 2, alignment: .leading)
            .fixedSize()
            .modifier(GlassBackground(fill: style.background, glass: store.configuration?.bar(on: kind).glass ?? GlassSettings(), surface: \.popups,
                                      shape: RoundedRectangle(cornerRadius: appearance.cornerRadius)))
            .overlay {
                RoundedRectangle(cornerRadius: appearance.cornerRadius)
                    .strokeBorder(appearance.borderColor, lineWidth: appearance.borderWidth)
            }
            .shadow(color: appearance.shadowColor, radius: appearance.shadowRadius, y: 1)
            .padding(shadowInset))
        let size = host.fittingSize
        let x = min(max(frame.midX - size.width / 2, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - size.width - 8)
        let panel = PopupPanel(contentRect: NSRect(x: x, y: top - size.height - 6 + shadowInset, width: size.width, height: size.height),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Widget tooltip"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        panel.appearance = window.appearance
        panel.contentView = host
        self.panel = panel
        self.anchor = anchor
        hoveredAnchor = anchor
        present(panel, true)
    }

    func open(_ popup: PopupConfiguration, widget: WidgetConfiguration, defaults: WidgetStyle,
              store: BarStore, anchor: NSView, onHover: Bool) {
        let window = anchor.window!
        let screen = window.screen!
        let bar = store.configuration!.bar(on: ScreenKind(BarDisplay(screen: screen)))
        let animation = popup.animation ?? bar.motion.popupAnimation
        var from: (view: PopupView, box: NSRect, windows: [NSPanel])?
        if let shown, let panel, bar.morphPopups, self.anchor?.window === window, animation.duration > 0,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            from = (shown.view, panel.frame.insetBy(dx: shown.inset, dy: shown.inset), [panel, shadowWindow].compactMap { $0 })
            self.panel = nil
            shadowWindow = nil
        }
        close()
        pinned = !onHover
        hoveredAnchor = onHover ? anchor : nil
        let frame = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let popupTop = popupAttachmentTop(anchor: frame, window: window.frame, geometry: (window as? BarPanel)?.barGeometry)
        let style = popup.baseStyle(widget: widget, defaults: defaults)
        let appearance = WidgetAppearance(style, defaults: WidgetStyle())
        let shadowInset = CGFloat(appearance.shadowRadius * 2 + 2)
        let width = min(CGFloat(popup.style.width ?? 360), screen.visibleFrame.width - shadowInset * 2 - 16)
        let maximumHeight = popupTop - screen.visibleFrame.minY - shadowInset * 2 - 8 - popup.offset
        let alignedX: CGFloat = switch popup.alignment {
        case .leading: frame.minX
        case .center: frame.midX - width / 2
        case .trailing: frame.maxX - width
        }
        let x = min(max(alignedX, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - width - 8)
        let panel = PopupPanel(contentRect: NSRect(x: x - shadowInset, y: popupTop - popup.offset + shadowInset,
                                                  width: width + shadowInset * 2, height: 0),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let view = PopupView(popup: popup, style: style, store: store, widget: widget)
        let host = NSHostingView(rootView: view
            .environment(\.screenKind, ScreenKind(BarDisplay(screen: screen)))
            .frame(width: width)
            .onPreferenceChange(PopupHeightPreference.self) { [weak self, weak panel] contentHeight in
                guard popup.height == nil, let panel, panel === self?.panel else { return }
                let height = (min(contentHeight, maximumHeight) + shadowInset * 2).rounded(.up)
                guard abs(panel.frame.height - height) > 0.5 else { return }
                let frame = NSRect(x: panel.frame.minX, y: panel.frame.maxY - height, width: panel.frame.width, height: height)
                let windows = [panel, self?.shadowWindow].compactMap { $0 }
                for window in windows {
                    let reveal = window.contentView!
                    reveal.subviews[0].frame = NSRect(x: 0, y: reveal.bounds.height - height, width: frame.width, height: height)
                }
                if let animation = popup.animation, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = animation.duration
                        context.timingFunction = animation.timingFunction
                        for window in windows { window.animator().setFrame(frame, display: true) }
                    } completionHandler: {
                        Task { @MainActor in panel.invalidateShadow() }
                    }
                } else {
                    for window in windows { window.setFrame(frame, display: true) }
                    panel.invalidateShadow()
                }
            }
            .padding(shadowInset)
            .onHover { [weak self, weak panel] inside in
                if panel === self?.panel { self?.hoverPopup(inside) }
            })
        let height = min(popup.height.map { CGFloat($0) } ?? host.fittingSize.height - shadowInset * 2, maximumHeight)
        panel.setFrame(NSRect(x: x - shadowInset, y: popupTop - height - popup.offset - shadowInset,
                              width: width + shadowInset * 2, height: height + shadowInset * 2), display: false)
        panel.title = "\(widget.id) popup"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.autorecalculatesKeyViewLoop = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        panel.appearance = store.configuration?.bar(on: ScreenKind(BarDisplay(screen: screen))).appearance
            .flatMap { NSAppearance(named: $0 == .dark ? .darkAqua : .aqua) }
        panel.contentView = PopupRevealView(content: host, size: panel.frame.size)
        self.panel = panel
        shown = (view, shadowInset)
        // macOS outlines a window and shapes its shadow from what the window draws. In the popup's window, the popup's
        // own shadow would get that outline near its outer edge, so it gets a window of its own behind the popup.
        let drawsShadow = style.shadowColor.map { $0.light & 0xff > 0 || $0.dark & 0xff > 0 } ?? false
        let shadow = drawsShadow ? makeShadowWindow(behind: panel, appearance: appearance, inset: shadowInset) : nil
        shadowWindow = shadow
        widgetID = widget.id
        self.store = store
        store.setPopupVisibleWidget(widget.id, anchor: anchor)
        self.anchor = anchor
        self.animation = animation
        transition = bar.popupTransition ?? bar.motion.popupTransition
        source = frame.midX - panel.frame.minX
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .keyDown]) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self else { return false }
                if event.type == .keyDown {
                    if event.keyCode == 53 {
                        self.close()
                        return true
                    }
                } else if event.type == .leftMouseUp {
                    if self.closesAfterClick { Task { @MainActor in if self.closesAfterClick { self.close() } } }
                } else if event.window === self.panel {
                    self.keepOpen()
                } else {
                    let onAnchor = event.window === anchor.window && anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil))
                    if !onAnchor {
                        if bar.morphPopups && event.type == .leftMouseDown && event.window === anchor.window {
                            self.closesAfterClick = true
                        } else {
                            self.close()
                        }
                    }
                }
                return false
            }
            return handled ? nil : event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        let windows = [panel, shadow].compactMap { $0 }
        if let from {
            let toBox = panel.frame.insetBy(dx: shadowInset, dy: shadowInset)
            let union = from.box.union(toBox)
            func local(_ box: NSRect) -> CGRect {
                CGRect(x: box.minX - union.minX, y: union.maxY - box.maxY, width: box.width, height: box.height)
            }
            let morph = PopupPanel(contentRect: union, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            morph.title = "\(widget.id) popup morph"
            morph.isOpaque = false
            morph.backgroundColor = .clear
            morph.hasShadow = true
            morph.ignoresMouseEvents = true
            morph.hidesOnDeactivate = false
            morph.isReleasedWhenClosed = false
            morph.level = panel.level
            morph.collectionBehavior = panel.collectionBehavior
            morph.appearance = panel.appearance
            var fromView = from.view
            var toView = view
            fromView.drawsBackground = false
            toView.drawsBackground = false
            morph.contentView = NSHostingView(rootView: PopupMorphView(from: fromView, to: toView, fromBox: local(from.box), toBox: local(toBox),
                                                                       glass: bar.glass, animation: animation) { [weak self, weak morph] in
                if let morph, morph === self?.morph?.panel { self?.finishMorph() }
            }
            .environment(\.screenKind, ScreenKind(BarDisplay(screen: screen))))
            let link = morph.displayLink(target: morph, selector: #selector(NSWindow.invalidateShadow))
            link.add(to: .main, forMode: .common)
            self.morph = (morph, link)
            present(morph, true)
            Task { @MainActor in from.windows.forEach { $0.close() } }
            for window in windows { window.alphaValue = 0 }
            present(panel, onHover)
            if panel.isVisible { shadow?.order(.below, relativeTo: panel.windowNumber) }
            return
        }
        panel.alphaValue = 0
        present(panel, onHover)
        if panel.isVisible { shadow?.order(.below, relativeTo: panel.windowNumber) }
        if animation.duration > 0, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                Task { @MainActor in
                    guard panel === self?.panel else { return }
                    for window in windows { window.contentView!.layer!.mask = nil }
                    panel.invalidateShadow()
                }
            }
            for window in windows { transition.animate(window.contentView!, source: source, closing: false, with: animation) }
            CATransaction.commit()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animation.duration
            context.timingFunction = animation.timingFunction
            for window in windows { window.animator().alphaValue = 1 }
        } completionHandler: {
            Task { @MainActor in panel.invalidateShadow() }
        }
    }

    private func finishMorph() {
        guard let morph else { return }
        for window in [panel, shadowWindow].compactMap({ $0 }) { window.alphaValue = 1 }
        panel?.invalidateShadow()
        morph.link.invalidate()
        morph.panel.close()
        self.morph = nil
    }

    private func makeShadowWindow(behind panel: PopupPanel, appearance: WidgetAppearance, inset: CGFloat) -> NSPanel {
        let window = NSPanel(contentRect: panel.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = "\(panel.title) shadow"
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.level = panel.level
        window.collectionBehavior = panel.collectionBehavior
        window.appearance = panel.appearance
        window.alphaValue = 0
        let host = NSHostingView(rootView: PopupShadowView(cornerRadius: appearance.cornerRadius, color: appearance.shadowColor,
                                                           radius: appearance.shadowRadius, inset: inset))
        window.contentView = PopupRevealView(content: host, size: panel.frame.size)
        return window
    }

    func close() {
        hoverTask?.cancel()
        hoverTask = nil
        hoveredAnchor = nil
        pointerInPopup = false
        pinned = false
        closesAfterClick = false
        store?.setPopupVisibleWidget(nil)
        store = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        finishMorph()
        let windows = [panel, shadowWindow].compactMap { $0 }
        if let animation {
            if animation.duration > 0, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                for window in windows { transition.animate(window.contentView!, source: source, closing: true, with: animation) }
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = animation.duration
                context.timingFunction = animation.timingFunction
                for window in windows { window.animator().alphaValue = 0 }
            } completionHandler: {
                Task { @MainActor in windows.forEach { $0.close() } }
            }
        } else {
            windows.forEach { $0.close() }
        }
        panel = nil
        shadowWindow = nil
        shown = nil
        widgetID = nil
        anchor = nil
        animation = nil
    }

    func removeAnchor(_ view: NSView) {
        if anchor === view || hoveredAnchor === view { close() }
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
