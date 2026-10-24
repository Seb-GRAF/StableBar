import AppKit
import SwiftUI

@MainActor
final class PopupPanel: NSPanel {
    /// Closes a pinned popup, which no event monitor watches, on Escape.
    var onEscape: (() -> Void)?
    let size = PopupSize()
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    @objc var hasKeyAppearance: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53, let onEscape { onEscape() } else { super.sendEvent(event) }
    }
}

@MainActor
final class PopupRevealView: NSView {
    var onLiveResize: (() -> Void)?

    init(content: NSView, size: NSSize) {
        super.init(frame: NSRect(origin: .zero, size: size))
        clipsToBounds = true
        wantsLayer = true
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError("PopupRevealView is created programmatically.") }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        onLiveResize?()
    }
}

/// A popup's own shadow without the popup, for a window behind the popup's.
struct PopupShadowView: View {
    let cornerRadius: Double
    let color: Color
    let radius: Double
    let inset: CGFloat

    var body: some View {
        Canvas { context, size in
            let shape = RoundedRectangle(cornerRadius: cornerRadius).path(in: CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset))
            var shadow = context
            shadow.addFilter(.shadow(color: color, radius: radius, y: 1))
            shadow.fill(shape, with: .color(.black))
            // A translucent popup would show the shape through it.
            context.blendMode = .clear
            context.fill(shape, with: .color(.black))
        }
    }
}

/// The height a popup draws at, which animates inside its window; nil fills the window, as a popup resized by hand does.
@MainActor @Observable
final class PopupSize {
    var height: CGFloat?
}

/// A popup, or its shadow, drawn at the top of its window at `size`'s height and its shadow's inset around it, so the
/// window can be taller than the popup while the popup's height animates.
struct PopupCanvas<Content: View>: View {
    let size: PopupSize
    let inset: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(height: size.height.map { $0 + inset * 2 })
            .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// A tooltip's content at the width it needs, up to `maxWidth`, and as tall as its text is once it wraps there.
struct TooltipWidth: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = min(subviews[0].sizeThatFits(.unspecified).width, maxWidth)
        return subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

@MainActor @Observable
final class PopupBackgrounds {
    var hidden = false
}

@MainActor @Observable
final class PopupPins {
    var ids: Set<String> = []
    /// Popups resized by hand, which keep their size instead of fitting their content.
    var resized: Set<String> = []
}

/// A pinned popup's windows, and what returns it under its widget when it's unpinned.
@MainActor
private struct PinnedPopup {
    let panel: PopupPanel
    let shadow: NSPanel?
    weak var anchor: NSView?
    unowned let store: BarStore
    /// The popup's top-left corner under its widget, and the visible part of that screen.
    let home: NSPoint
    let homeScreen: NSRect
    let shown: (inset: CGFloat, cornerRadius: CGFloat)
    let animation: WidgetAnimation
    let transition: PopupTransition
    let source: CGFloat
    let morphPopups: Bool
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
    private weak var parentPopup: PopupPanel?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var moveObserver: Any?
    private var animation: WidgetAnimation?
    private var transition = PopupTransition.fade
    private var source: CGFloat = 0
    private var hoverTask: Task<Void, Never>?
    private weak var hoveredAnchor: NSView?
    private var pointerInPopup = false
    private var editingControls = false
    private var pinned = false
    private var closesAfterClick = false
    private var shown: (inset: CGFloat, cornerRadius: CGFloat)?
    private var morph: (panel: PopupPanel, link: CADisplayLink, from: PopupPanel)?
    private typealias MorphSource = (panel: PopupPanel, shadow: NSPanel?, box: NSRect, cornerRadius: CGFloat)
    private var morphPopups = false
    private var pinnedPopups: [String: PinnedPopup] = [:]
    /// Where each widget's popup was last pinned, whether it was resized there, and whether it closed pinned, so it pins
    /// there again when it next opens.
    private var spots: [String: (frame: NSRect, resized: Bool, pinned: Bool)] = [:]
    let backgrounds = PopupBackgrounds()
    let pins = PopupPins()

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
            // Moving from one widget to the next while something opened on hover shows the next one at once.
            let delay = panel == nil ? store.configuration!.bar.hoverDelay : 0
            hoverTask = Task {
                do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
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
        guard !pinned, panel != nil, hoveredAnchor == nil, !pointerInPopup, !editingControls else { return }
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

    /// The open popup or tooltip, when the next one on the same bar `window` morphs out of it. Its windows are taken
    /// from the popup so `close()` leaves them.
    private func morphSource(on window: NSWindow, bar: BarSettings, animation: WidgetAnimation) -> MorphSource? {
        guard let shown, let panel, bar.morphPopups, anchor?.window === window, animation.duration > 0,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return nil }
        let source = (panel, shadowWindow, panel.frame.insetBy(dx: shown.inset, dy: shown.inset), shown.cornerRadius)
        self.panel = nil
        shadowWindow = nil
        return source
    }

    func showTooltip(_ text: String, widget: WidgetConfiguration, defaults: WidgetStyle,
                     store: BarStore, anchor: NSView) {
        openTooltip(id: widget.id, style: widget.style, defaults: defaults, store: store, anchor: anchor, ignoresMouseEvents: true) { _ in Text(text) }
    }

    /// Shows a widget's hover controls in a tooltip under it, drawn in the tooltip's style. The pointer can move into
    /// it, and it stays open while a control in it is dragged.
    func showControls(widget: WidgetConfiguration, defaults: WidgetStyle, store: BarStore, anchor: NSView,
                      @ViewBuilder controls: (WidgetStyle) -> some View) {
        openTooltip(id: widget.id, style: widget.style, defaults: defaults, store: store, anchor: anchor, ignoresMouseEvents: false) { style in
            controls(style)
                .onPreferenceChange(ControlEditingPreference.self) { [weak self] editing in self?.editControls(editing) }
        }
    }

    func showWidgets(defaults: WidgetStyle, store: BarStore, anchor: NSView, @ViewBuilder widgets: () -> some View) {
        guard store.barEditing.allowsWidgetActions else { return }
        if self.anchor === anchor {
            close()
            return
        }
        openTooltip(id: BarView.moreWidgetsID, style: WidgetStyle(), defaults: defaults, store: store, anchor: anchor,
                    maxWidth: anchor.window!.screen!.visibleFrame.width - 16, ignoresMouseEvents: false) { _ in widgets() }
        pinned = true
        hoveredAnchor = nil
        watchEvents(anchor: anchor, pinnable: false)
    }

    /// Keeps hover controls open while they're dragged, even with the pointer outside them, and closes them after.
    private func editControls(_ editing: Bool) {
        editingControls = editing
        if editing { hoverTask?.cancel() } else { closeAfterHover() }
    }

    /// Shows `content` in a tooltip under `anchor`, drawn in the widget's popup style, which opens and closes with the
    /// bar's popup motion.
    private func openTooltip(id: String, style widgetStyle: WidgetStyle, defaults: WidgetStyle, store: BarStore, anchor: NSView,
                             maxWidth: CGFloat = 320, ignoresMouseEvents: Bool, @ViewBuilder content: (WidgetStyle) -> some View) {
        let window = anchor.window!
        let screen = window.screen!
        let kind = ScreenKind(BarDisplay(screen: screen))
        let bar = store.configuration!.bar(on: kind)
        let animation = bar.motion.popupAnimation
        let from = morphSource(on: window, bar: bar, animation: animation)
        close()
        parentPopup = window as? PopupPanel
        let frame = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let top = popupAttachmentTop(anchor: frame, window: window.frame, geometry: (window as? BarPanel)?.barGeometry)
        let style = resolveStyle([defaults, widgetStyle], states: StyleStates(mode: store.modePresentation(on: kind)))
        let appearance = WidgetAppearance(style, defaults: WidgetStyle())
        let shadowInset = CGFloat(appearance.shadowRadius * 2 + 2)
        let panel = PopupPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: TooltipWidth(maxWidth: maxWidth - shadowInset * 2) {
                content(style)
                    .font(appearance.font)
                    .foregroundStyle(appearance.foreground)
                    .padding(.horizontal, appearance.paddingHorizontal)
                    .padding(.vertical, appearance.paddingVertical)
            }
            .modifier(PopupBackground(style: style, glass: bar.glass, backgrounds: backgrounds))
            .padding(shadowInset)
            .onHover { [weak self, weak panel] inside in
                if panel === self?.panel { self?.hoverPopup(inside) }
            })
        let size = host.fittingSize
        let x = min(max(frame.midX - size.width / 2, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - size.width - 8)
        panel.setFrame(NSRect(x: x, y: top - size.height - 6 + shadowInset, width: size.width, height: size.height), display: false)
        panel.title = "\(id) tooltip"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = ignoresMouseEvents
        panel.animationBehavior = .none
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        panel.appearance = window.appearance
        panel.contentView = PopupRevealView(content: host, size: size)
        let shadow = makeShadowWindow(behind: panel, style: style, inset: shadowInset)
        self.panel = panel
        shadowWindow = shadow
        shown = (shadowInset, CGFloat(appearance.cornerRadius))
        self.anchor = anchor
        hoveredAnchor = anchor
        self.animation = animation
        transition = bar.popupTransition ?? bar.motion.popupTransition
        source = frame.midX - x
        if let from {
            morph(from, into: panel, inset: shadowInset, shadow: shadow, style: style, glass: bar.glass, animation: animation, onHover: true)
        } else {
            reveal(panel, shadow: shadow, onHover: true, with: animation)
        }
        attachToParentPopup()
    }

    func open(_ popup: PopupConfiguration, widget: WidgetConfiguration, defaults: WidgetStyle,
              store: BarStore, anchor: NSView, onHover: Bool) {
        if pinnedPopups[widget.id] != nil {
            if !onHover { closePinned(widget.id) }
            return
        }
        let window = anchor.window!
        let screen = window.screen!
        let bar = store.configuration!.bar(on: ScreenKind(BarDisplay(screen: screen)))
        let animation = popup.animation ?? bar.motion.popupAnimation
        let pinsAgain = !onHover && spots[widget.id]?.pinned == true
        let from = pinsAgain ? nil : morphSource(on: window, bar: bar, animation: animation)
        close()
        parentPopup = window as? PopupPanel
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
        let host = NSHostingView(rootView: PopupCanvas(size: panel.size, inset: shadowInset) {
            PopupView(popup: popup, style: style, store: store, widget: widget, backgrounds: backgrounds)
                .environment(\.screenKind, ScreenKind(BarDisplay(screen: screen)))
                .frame(idealWidth: width, maxWidth: .infinity)
                .onPreferenceChange(PopupHeightPreference.self) { [weak self, weak panel] contentHeight in
                    guard popup.height == nil, let panel, let self, !self.pins.resized.contains(widget.id) else { return }
                    let shadow: NSWindow?
                    if panel === self.panel {
                        shadow = self.shadowWindow
                    } else if let pinned = self.pinnedPopups.values.first(where: { $0.panel === panel }) {
                        shadow = pinned.shadow
                    } else {
                        return
                    }
                    let height = min(contentHeight, maximumHeight).rounded(.up)
                    guard let shown = panel.size.height, abs(shown - height) > 0.5 else { return }
                    self.resize(panel, shadow: shadow, to: height, inset: shadowInset, animation: popup.animation)
                }
                .padding(shadowInset)
        }
        .onHover { [weak self, weak panel] inside in
            if panel === self?.panel { self?.hoverPopup(inside) }
        })
        let height = min(popup.height.map { CGFloat($0) } ?? host.fittingSize.height - shadowInset * 2, maximumHeight)
        panel.size.height = height
        panel.setFrame(NSRect(x: x - shadowInset, y: popupTop - height - popup.offset - shadowInset,
                              width: width + shadowInset * 2, height: height + shadowInset * 2), display: false)
        panel.title = "\(widget.id) popup"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.autorecalculatesKeyViewLoop = true
        panel.isMovableByWindowBackground = popup.pinnable
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        panel.appearance = store.configuration?.bar(on: ScreenKind(BarDisplay(screen: screen))).appearance
            .flatMap { NSAppearance(named: $0 == .dark ? .darkAqua : .aqua) }
        panel.contentView = PopupRevealView(content: host, size: panel.frame.size)
        self.panel = panel
        shown = (shadowInset, CGFloat(appearance.cornerRadius))
        let shadow = makeShadowWindow(behind: panel, style: style, inset: shadowInset)
        shadowWindow = shadow
        widgetID = widget.id
        self.store = store
        if parentPopup == nil {
            store.setPopupVisibleWidget(widget.id, anchor: anchor)
        } else {
            store.setInnerPopupAnchor(anchor, of: widget.id)
        }
        self.anchor = anchor
        self.animation = animation
        transition = bar.popupTransition ?? bar.motion.popupTransition
        source = frame.midX - panel.frame.minX
        morphPopups = bar.morphPopups
        watchEvents(anchor: anchor, pinnable: popup.pinnable)
        if let from {
            morph(from, into: panel, inset: shadowInset, shadow: shadow, style: style, glass: bar.glass, animation: animation, onHover: onHover)
        } else {
            reveal(panel, shadow: shadow, onHover: onHover, with: animation)
        }
        attachToParentPopup()
        if pinsAgain { pin() }
    }

    private func attachToParentPopup() {
        for window in [shadowWindow, panel].compactMap({ $0 }) { parentPopup?.addChildWindow(window, ordered: .above) }
    }

    /// Moves and reshapes the open popup or tooltip `from` into `panel`, the next one on the same bar: a card with the
    /// next one's background travels between their places while their contents cross-fade.
    private func morph(_ from: MorphSource, into panel: PopupPanel, inset: CGFloat, shadow: NSPanel?, style: WidgetStyle,
                       glass: GlassSettings, animation: WidgetAnimation, onHover: Bool) {
        let appearance = WidgetAppearance(style, defaults: WidgetStyle())
        let toBox = panel.frame.insetBy(dx: inset, dy: inset)
        let union = from.box.union(toBox)
        let morph = PopupPanel(contentRect: union, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        morph.title = "\(panel.title) morph"
        morph.isOpaque = false
        morph.backgroundColor = .clear
        morph.hasShadow = true
        morph.ignoresMouseEvents = true
        morph.hidesOnDeactivate = false
        morph.isReleasedWhenClosed = false
        morph.animationBehavior = .none
        morph.level = panel.level
        morph.collectionBehavior = panel.collectionBehavior
        morph.appearance = panel.appearance
        morph.contentView = PopupRevealView(content: NSHostingView(rootView: Color.clear.modifier(
            GlassBackground(fill: style.background, glass: glass, surface: \.popups, shape: Rectangle()))), size: union.size)
        let outline = CALayer()
        outline.borderWidth = appearance.borderWidth
        panel.effectiveAppearance.performAsCurrentDrawingAppearance { outline.borderColor = NSColor(appearance.borderColor).cgColor }
        let cards = [morph, from.panel, panel].map { window in (CALayer(), window) } + [(outline, morph)]
        for (card, window) in cards {
            card.anchorPoint = .zero
            card.frame = from.box.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
            card.cornerCurve = .continuous
            card.cornerRadius = from.cornerRadius
            if card === outline {
                window.contentView!.layer!.addSublayer(card)
            } else {
                card.backgroundColor = .black
                window.contentView!.layer!.mask = card
            }
        }
        let link = morph.displayLink(target: morph, selector: #selector(NSWindow.invalidateShadow))
        link.add(to: .main, forMode: .common)
        self.morph = (morph, link, from.panel)
        backgrounds.hidden = true
        from.shadow?.close()
        from.panel.hasShadow = false
        from.panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.contentView!.alphaValue = 0
        present(panel, onHover)
        if panel.isVisible {
            shadow?.order(.below, relativeTo: panel.windowNumber)
            morph.order(.below, relativeTo: from.panel.windowNumber)
        }
        for window in [morph, from.panel, panel] { window.displayIfNeeded() }
        let start = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self, weak morph] in
            if let morph, morph === self?.morph?.panel { self?.finishMorph() }
        }
        for (card, window) in cards {
            let target = toBox.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
            let changes: [(String, Any, Any)] = [("position", NSValue(point: card.position), NSValue(point: target.origin)),
                                                 ("bounds.size", NSValue(size: card.bounds.size), NSValue(size: target.size)),
                                                 ("cornerRadius", card.cornerRadius, appearance.cornerRadius)]
            card.frame = target
            card.cornerRadius = appearance.cornerRadius
            for (keyPath, fromValue, toValue) in changes {
                let change = animation.layerAnimation(keyPath: keyPath)
                change.fromValue = fromValue
                change.toValue = toValue
                change.beginTime = start
                change.fillMode = .backwards
                card.add(change, forKey: keyPath)
            }
        }
        for (view, opacity, delay, duration) in [(from.panel.contentView!, 0.0, 0.0, 0.4), (panel.contentView!, 1, 0.2, 0.6)] {
            let change = CABasicAnimation(keyPath: "opacity")
            change.fromValue = 1 - opacity
            change.toValue = opacity
            change.beginTime = start + animation.duration * delay
            change.duration = animation.duration * duration
            change.timingFunction = animation.timingFunction
            change.fillMode = .backwards
            view.alphaValue = opacity
            view.layer!.add(change, forKey: "opacity")
        }
        CATransaction.commit()
        CATransaction.flush()
    }

    /// Presents `panel` and its shadow's window, fading them in with the popup's transition.
    private func reveal(_ panel: PopupPanel, shadow: NSPanel?, onHover: Bool, with animation: WidgetAnimation) {
        let windows = [panel, shadow].compactMap { $0 }
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

    private func watchEvents(anchor: NSView, pinnable: Bool) {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .keyDown]) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                // A window of the popup's own, such as a chooser's panel, handles its events like the popup.
                guard let self, event.window?.parent == nil || event.window?.parent !== self.panel else { return false }
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
                        if self.morphPopups && event.type == .leftMouseDown && event.window === anchor.window {
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
        if pinnable {
            // Dragging a pinnable popup away pins it where it's dropped.
            moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.willMoveNotification, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pin(dragging: true) }
            }
        }
    }

    private func stopWatching() {
        hoverTask?.cancel()
        hoverTask = nil
        hoveredAnchor = nil
        pointerInPopup = false
        editingControls = false
        pinned = false
        closesAfterClick = false
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        localMonitor = nil
        globalMonitor = nil
        moveObserver = nil
    }

    /// Keeps the open popup on screen through clicks elsewhere, app switches and other popups, and lets it be resized. Unless
    /// it's being dragged, it moves to where the widget's popup was last pinned.
    func pin(dragging: Bool = false) {
        let id = widgetID!
        let panel = panel!
        finishMorph()
        stopWatching()
        store!.setPopupVisibleWidget(nil)
        pinnedPopups[id] = PinnedPopup(panel: panel, shadow: shadowWindow, anchor: anchor, store: store!,
                                       home: NSPoint(x: panel.frame.minX, y: panel.frame.maxY), homeScreen: panel.screen!.visibleFrame,
                                       shown: shown!, animation: animation!, transition: transition, source: source, morphPopups: morphPopups)
        pins.ids.insert(id)
        panel.styleMask.insert(.resizable)
        panel.minSize = NSSize(width: 240 + shown!.inset * 2, height: 140 + shown!.inset * 2)
        panel.onEscape = { [weak self] in self?.closePinned(id) }
        (panel.contentView as! PopupRevealView).onLiveResize = { [weak self] in self?.keepSize(id, of: panel) }
        if let shadowWindow { panel.addChildWindow(shadowWindow, ordered: .below) }
        if !dragging, let spot = spots[id] {
            if spot.resized { keepSize(id, of: panel) }
            let size = spot.resized ? spot.frame.size : panel.frame.size
            move(panel, to: NSRect(x: spot.frame.minX, y: spot.frame.maxY - size.height, width: size.width, height: size.height), with: animation!)
        }
        self.panel = nil
        shadowWindow = nil
        shown = nil
        widgetID = nil
        anchor = nil
        animation = nil
        store = nil
    }

    /// Moves a pinned popup back under its widget, where it closes like any open popup.
    func unpin(_ id: String) {
        let popup = pinnedPopups.removeValue(forKey: id)!
        pins.ids.remove(id)
        spots[id] = (popup.panel.frame, pins.resized.contains(id), false)
        close()
        // The widget can leave the bar, with a configuration change or its display, while its popup is pinned.
        guard let anchor = popup.anchor else {
            dismiss([popup.panel, popup.shadow].compactMap { $0 }, transition: popup.transition, source: popup.source, animation: popup.animation)
            return
        }
        popup.panel.styleMask.remove(.resizable)
        popup.panel.onEscape = nil
        panel = popup.panel
        shadowWindow = popup.shadow
        shown = popup.shown
        widgetID = id
        self.anchor = anchor
        store = popup.store
        animation = popup.animation
        transition = popup.transition
        source = popup.source
        morphPopups = popup.morphPopups
        pinned = true
        popup.store.setPopupVisibleWidget(id, anchor: anchor)
        watchEvents(anchor: anchor, pinnable: true)
        // A popup keeps the size it was given, so a wider one may need to move left to stay on its screen.
        let size = popup.panel.frame.size
        let x = min(popup.home.x, popup.homeScreen.maxX - size.width)
        move(popup.panel, to: NSRect(x: x, y: popup.home.y - size.height, width: size.width, height: size.height), with: popup.animation)
    }

    func closePinned(_ id: String) {
        let popup = pinnedPopups.removeValue(forKey: id)!
        pins.ids.remove(id)
        spots[id] = (popup.panel.frame, pins.resized.contains(id), true)
        pins.resized.remove(id)
        dismiss([popup.panel, popup.shadow].compactMap { $0 }, transition: popup.transition, source: popup.source, animation: popup.animation)
    }

    /// Closes the open popup and every pinned one.
    func closeAll() {
        close()
        for id in pinnedPopups.keys { closePinned(id) }
    }

    /// Stops fitting a popup to its content once it's resized by hand; its content then follows the window's size.
    private func keepSize(_ id: String, of panel: PopupPanel) {
        pins.resized.insert(id)
        panel.size.height = nil
    }

    /// Moves a popup with its motion; its shadow window follows as a child window.
    private func move(_ panel: PopupPanel, to frame: NSRect, with animation: WidgetAnimation) {
        if animation.duration > 0, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = animation.duration
                context.timingFunction = animation.timingFunction
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    /// Animates a popup's height inside its window with its own animation, if it has one: the window grows first and
    /// shrinks last, so the popup's edge, shadow and content move together.
    private func resize(_ panel: PopupPanel, shadow: NSWindow?, to height: CGFloat, inset: CGFloat, animation: WidgetAnimation?) {
        let fit = {
            let frame = NSRect(x: panel.frame.minX, y: panel.frame.maxY - height - inset * 2, width: panel.frame.width, height: height + inset * 2)
            for window in [panel, shadow].compactMap({ $0 }) { window.setFrame(frame, display: true) }
            panel.invalidateShadow()
        }
        guard let animation, animation.duration > 0, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.size.height = height
            fit()
            return
        }
        if height > panel.size.height! { fit() }
        withAnimation(animation.value) { panel.size.height = height }
        let link = panel.displayLink(target: panel, selector: #selector(NSWindow.invalidateShadow))
        link.add(to: .main, forMode: .common)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(animation.duration))
            link.invalidate()
            if panel.size.height == height { fit() }
        }
    }

    private func finishMorph() {
        guard let morph else { return }
        backgrounds.hidden = false
        if let panel {
            panel.contentView!.layer!.mask = nil
            panel.displayIfNeeded()
        }
        morph.panel.contentView!.isHidden = true
        shadowWindow?.alphaValue = 1
        CATransaction.flush()
        morph.panel.hasShadow = false
        panel?.hasShadow = true
        panel?.invalidateShadow()
        morph.link.invalidate()
        self.morph = nil
        Task { @MainActor in
            morph.panel.close()
            morph.from.close()
        }
    }

    /// A window behind `panel` for its style's shadow, if it has one. macOS outlines a window and shapes its shadow from
    /// what the window draws. In the popup's window, the popup's own shadow would get that outline near its outer edge,
    /// so it gets a window of its own behind the popup.
    private func makeShadowWindow(behind panel: PopupPanel, style: WidgetStyle, inset: CGFloat) -> NSPanel? {
        guard style.shadowColor.map({ $0.light & 0xff > 0 || $0.dark & 0xff > 0 }) == true else { return nil }
        let appearance = WidgetAppearance(style, defaults: WidgetStyle())
        let window = NSPanel(contentRect: panel.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = "\(panel.title) shadow"
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.level = panel.level
        window.collectionBehavior = panel.collectionBehavior
        window.appearance = panel.appearance
        window.alphaValue = 0
        let host = NSHostingView(rootView: PopupCanvas(size: panel.size, inset: inset) {
            PopupShadowView(cornerRadius: appearance.cornerRadius, color: appearance.shadowColor, radius: appearance.shadowRadius, inset: inset)
        })
        window.contentView = PopupRevealView(content: host, size: panel.frame.size)
        return window
    }

    func close() {
        stopWatching()
        if let widgetID { pins.resized.remove(widgetID) }
        if parentPopup == nil {
            store?.setPopupVisibleWidget(nil)
        } else if let widgetID {
            store?.setInnerPopupAnchor(nil, of: widgetID)
        }
        parentPopup = nil
        store = nil
        finishMorph()
        dismiss([panel, shadowWindow].compactMap { $0 }, transition: transition, source: source, animation: animation)
        panel = nil
        shadowWindow = nil
        shown = nil
        widgetID = nil
        anchor = nil
        animation = nil
    }

    private func dismiss(_ windows: [NSWindow], transition: PopupTransition, source: CGFloat, animation: WidgetAnimation?) {
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
