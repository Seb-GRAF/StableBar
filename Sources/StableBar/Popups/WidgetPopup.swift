import AppKit
import SwiftUI

/// A tooltip's content at the width it needs, up to `maxWidth`, and as tall as its text is once it wraps there.
struct TooltipWidth: Layout {
    /// How wide a widget's tooltip grows, its shadow included, before its text wraps.
    static let widgetMaxWidth: CGFloat = 320

    let maxWidth: CGFloat

    // The content can draw nothing, such as the volume slider once its output has no volume.
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let width = min(content.sizeThatFits(.unspecified).width, maxWidth)
        return content.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
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
    weak var store: BarStore?
    /// The popup's left corner at its widget, on the edge facing it, and the visible part of that screen.
    let home: NSPoint
    let homeScreen: NSRect
    let shown: (inset: CGFloat, cornerRadius: CGFloat)
    let animation: WidgetAnimation
    let transition: PopupTransition
    let source: CGFloat
    let morphPopups: Bool
    let onClose: (command: String, widget: WidgetConfiguration)?
}

extension PopupTransition {
    @MainActor func animate(_ content: NSView, source: CGFloat, upward: Bool, closing: Bool, with animation: WidgetAnimation) {
        let bounds = content.bounds
        let layer = content.layer!
        let edge = upward ? bounds.minY : bounds.maxY
        let change: CABasicAnimation
        switch self {
        case .unfold:
            let mask = CALayer()
            mask.backgroundColor = .black
            mask.anchorPoint = CGPoint(x: 0, y: upward ? 0 : 1)
            mask.frame = bounds
            layer.mask = mask
            change = animation.layerAnimation(keyPath: "bounds.size.height")
            change.fromValue = closing ? bounds.height : 0
            change.toValue = closing ? 0 : bounds.height
        case .fade, .slide, .zoom:
            let hidden = switch self {
            case .slide: CATransform3DMakeTranslation(0, upward ? -12 : 12, 0)
            case .zoom: scaled(0.5, around: CGPoint(x: source, y: edge))
            default: scaled(0.97, around: CGPoint(x: bounds.midX, y: edge))
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
    private let mouseLocation: () -> NSPoint
    /// What the hover delays wait on; tests pass a clock they advance themselves.
    private let clock: any Clock<Duration>
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
    private var hoverOrigin: NSPoint?
    private var pointerInPopup = false
    private var editingControls = false
    private(set) var pinned = false
    private var closesAfterClick = false
    private var shown: (inset: CGFloat, cornerRadius: CGFloat)?
    private var morph: (panel: PopupPanel, link: CADisplayLink, from: PopupPanel)?
    private typealias MorphSource = (panel: PopupPanel, shadow: NSPanel?, box: NSRect, cornerRadius: CGFloat)
    private var morphPopups = false
    private var pinnedPopups: [String: PinnedPopup] = [:]
    /// Where each widget's popup was last pinned, and whether it closed pinned, so it pins there again when it next opens.
    private var spots: [String: (frame: NSRect, pinned: Bool)] = [:]
    /// The size each widget's popup was last resized to by hand, which it opens at again.
    private var sizes: [String: NSSize] = [:]
    /// What the open popup runs when it closes.
    private var onClose: (command: String, widget: WidgetConfiguration)?
    let backgrounds = PopupBackgrounds()
    let pins = PopupPins()

    init(present: @escaping (PopupPanel, Bool) -> Void = { panel, onHover in
        if onHover { panel.orderFront(nil) } else { panel.makeKeyAndOrderFront(nil) }
        panel.makeFirstResponder(nil)
    }, mouseLocation: @escaping () -> NSPoint = { NSEvent.mouseLocation }, clock: any Clock<Duration> = ContinuousClock()) {
        self.present = present
        self.mouseLocation = mouseLocation
        self.clock = clock
    }

    var isOpen: Bool { panel != nil }

    func toggle(_ popup: PopupConfiguration, widget: WidgetConfiguration, defaults: WidgetStyle,
                store: BarStore, anchor: NSView) {
        guard store.barEditing.allowsWidgetActions, !toggleIfOpen(widget.id, anchor: anchor) else { return }
        open(popup, widget: widget, defaults: defaults, store: store, anchor: anchor, onHover: false)
    }

    /// Handles a click on the widget whose popup is open under `anchor`: one opened on hover stays open, one opened by a
    /// click closes. False when that popup isn't open.
    func toggleIfOpen(_ id: String, anchor: NSView) -> Bool {
        guard self.anchor === anchor && widgetID == id else { return false }
        if pinned { close() } else { keepOpen() }
        return true
    }

    /// Shows what hovering `anchor` opens after the hover delay. A `show` that waits, such as to read its popup's content,
    /// should check `Task.isCancelled` before opening: leaving the widget or closing the popup cancels it.
    func hover(_ inside: Bool, store: BarStore, anchor: NSView, show: @escaping @MainActor () async -> Void) {
        guard !pinned else { return }
        if inside {
            hoverTask?.cancel()
            hoveredAnchor = anchor
            guard self.anchor !== anchor else {
                hoverOrigin = nil
                return
            }
            let delay = panel == nil ? store.configuration!.bar.hoverDelay : 0
            hoverTask = Task {
                do {
                    try await clock.sleep(for: .milliseconds(delay))
                    try await waitForHoverPath()
                    // A wait that ran out while the main thread was busy resumes after a later cancel.
                    try Task.checkCancellation()
                } catch { return }
                guard store.barEditing.allowsWidgetActions, anchor.window != nil else { return }
                await show()
            }
        } else if hoveredAnchor === anchor {
            if self.anchor === anchor, !panel!.ignoresMouseEvents {
                let frame = anchor.window!.convertToScreen(anchor.convert(anchor.bounds, to: nil))
                hoverOrigin = NSPoint(x: mouseLocation().x, y: panel!.opensUpward ? frame.minY : frame.maxY)
            }
            hoveredAnchor = nil
            hoverTask?.cancel()
            closeAfterHover()
        }
    }

    func hoverPopup(_ inside: Bool) {
        pointerInPopup = inside
        if inside {
            hoverOrigin = nil
            hoverTask?.cancel()
        } else { closeAfterHover() }
    }

    private func waitForHoverPath() async throws {
        guard let hoverOrigin else { return }
        let frame = panel!.frame.insetBy(dx: shown!.inset, dy: shown!.inset)
        var point = mouseLocation()
        while popupHoverTriangleContains(point, from: hoverOrigin, to: frame) {
            try await clock.sleep(for: .milliseconds(200))
            try Task.checkCancellation()
            let next = mouseLocation()
            guard panel!.opensUpward ? next.y > point.y : next.y < point.y else { return }
            point = next
        }
    }

    private func closeAfterHover() {
        guard !pinned, panel != nil, hoveredAnchor == nil, !pointerInPopup, !editingControls else { return }
        hoverTask?.cancel()
        hoverTask = Task { [weak self] in
            do {
                try await self?.waitForHoverPath()
                try await self?.clock.sleep(for: .milliseconds(200))
                try Task.checkCancellation()
            } catch { return }
            self?.close()
        }
    }

    /// Closes the open popup after `duration`, unless the pointer moves into it or it's pinned first.
    func close(after duration: Duration) {
        hoverTask = Task { [weak self] in
            do {
                try await self?.clock.sleep(for: duration)
                try Task.checkCancellation()
            } catch { return }
            self?.close()
        }
    }

    private func keepOpen() {
        pinned = true
        hoverTask?.cancel()
        if let panel, !panel.isKeyWindow {
            panel.makeKey()
            panel.makeFirstResponder(nil)
        }
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
        openTooltip(id: widget.id, style: widget.tooltipStyle, defaults: defaults, store: store, anchor: anchor, ignoresMouseEvents: true) { _ in Text(text) }
    }

    /// Shows a widget's hover controls in a tooltip under it, drawn in the tooltip's style. The pointer can move into
    /// it, and it stays open while a control in it is dragged.
    func showControls(widget: WidgetConfiguration, defaults: WidgetStyle, store: BarStore, anchor: NSView,
                      @ViewBuilder controls: (WidgetStyle) -> some View) {
        openTooltip(id: widget.id, style: widget.tooltipStyle, defaults: defaults, store: store, anchor: anchor, ignoresMouseEvents: false) { style in
            controls(style)
                .onPreferenceChange(ControlEditingPreference.self) { [weak self] editing in self?.editControls(editing) }
        }
    }

    /// Shows the widget's `row` in a tray under it. `sidePadding` is the widget's own, so the row lines up with it.
    func showRow(widget: WidgetConfiguration, defaults: WidgetStyle, store: BarStore, anchor: NSView, sidePadding: Double,
                 @ViewBuilder row: () -> some View) {
        openTooltip(id: widget.id, style: WidgetStyle(background: widget.popupBackground).inheriting(widget.style), defaults: defaults, store: store, anchor: anchor,
                    maxWidth: anchor.window!.screen!.visibleFrame.width - 16, alignment: .leading, sidePadding: sidePadding,
                    ignoresMouseEvents: false) { _ in row() }
        self.store = store
        watchEvents(anchor: anchor, pinnable: false)
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
                             maxWidth: CGFloat = TooltipWidth.widgetMaxWidth, alignment: PopupAlignment = .center, sidePadding: Double = 10, ignoresMouseEvents: Bool,
                             @ViewBuilder content: (WidgetStyle) -> some View) {
        let window = anchor.window!
        let screen = window.screen!
        let kind = ScreenKind(BarDisplay(screen: screen))
        let bar = store.configuration!.bar(on: kind)
        let animation = bar.motion.popupAnimation
        let from = morphSource(on: window, bar: bar, animation: animation)
        close()
        parentPopup = window as? PopupPanel
        let frame = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let edge = popupAttachmentEdge(anchor: frame, window: window.frame, geometry: (window as? BarPanel)?.barGeometry, position: bar.position)
        let style = tooltipStyle(defaults: defaults, widget: widgetStyle, states: StyleStates(mode: store.barPresentation.modePresentation(on: kind)),
                                 sidePadding: sidePadding)
        let appearance = WidgetAppearance(style, defaults: WidgetStyle())
        let shadowInset = CGFloat(appearance.shadowRadius * 2 + 2)
        let panel = PopupPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: TooltipWidth(maxWidth: maxWidth - shadowInset * 2) {
                content(style)
                    .font(appearance.font)
                    .foregroundStyle(appearance.foreground)
                    .padding(.horizontal, appearance.paddingHorizontal)
                    .padding(.vertical, appearance.paddingVertical)
                    // Its blocks read this screen's look, such as its slider role, not the laptop's.
                    .environment(\.screenKind, kind)
            }
            .modifier(PopupBackground(style: style, glass: bar.glass, backgrounds: backgrounds))
            .padding(shadowInset)
            .onHover { [weak self, weak panel] inside in
                if panel === self?.panel { self?.hoverPopup(inside) }
            })
        let size = host.fittingSize
        let alignedX = alignment == .leading ? frame.minX - shadowInset : frame.midX - size.width / 2
        let x = min(max(alignedX, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - size.width - 8)
        let gap = CGFloat(bar.popupGap(inPopup: parentPopup != nil))
        let y = bar.position == .bottom ? edge + gap - shadowInset : edge - size.height - gap + shadowInset
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: false)
        panel.opensUpward = bar.position == .bottom
        panel.title = "\(id) tooltip"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Left unset, the window passes clicks through where it's transparent, such as the margin kept for the shadow, which
        // reaches over the widget. Set to false, it takes every click in its frame.
        if ignoresMouseEvents { panel.ignoresMouseEvents = true }
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
        // A menu bar item's cell can still take a click after its anchor has left the window (#827).
        guard let window = anchor.window else { return }
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
        let edge = popupAttachmentEdge(anchor: frame, window: window.frame, geometry: (window as? BarPanel)?.barGeometry, position: bar.position)
        let upward = bar.position == .bottom
        let style = popup.baseStyle(widget: widget, defaults: defaults)
        let appearance = WidgetAppearance(style, defaults: WidgetStyle())
        let shadowInset = CGFloat(appearance.shadowRadius * 2 + 2)
        let width = min(sizes[widget.id]?.width ?? CGFloat(popup.style.width ?? 360), screen.visibleFrame.width - shadowInset * 2 - 16)
        let gap = CGFloat(popup.gap(below: bar, inPopup: parentPopup != nil))
        let maximumHeight = (upward ? screen.visibleFrame.maxY - edge : edge - screen.visibleFrame.minY) - shadowInset * 2 - 8 - gap
        let alignedX: CGFloat = switch popup.alignment {
        case .leading: frame.minX
        case .center: frame.midX - width / 2
        case .trailing: frame.maxX - width
        }
        let x = min(max(alignedX, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - width - 8)
        let panel = PopupPanel(contentRect: NSRect(x: x - shadowInset, y: upward ? edge + gap - shadowInset : edge - gap + shadowInset,
                                                  width: width + shadowInset * 2, height: 0),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.opensUpward = upward
        let host = NSHostingView(rootView: PopupCanvas(size: panel.size, inset: shadowInset, upward: upward) {
            PopupView(popup: popup, style: style, store: store, widget: widget, backgrounds: backgrounds, navigation: panel.navigation,
                      size: panel.size)
                .environment(\.screenKind, ScreenKind(BarDisplay(screen: screen)))
                .frame(idealWidth: width, maxWidth: .infinity)
                .onPreferenceChange(PopupHeightPreference.self) { [weak self, weak panel] contentHeight in
                    guard popup.height == nil, let panel, let self, !self.pins.resized.contains(widget.id) else { return }
                    let follows = contentHeight <= maximumHeight
                    if panel.size.followsContent != follows { panel.size.followsContent = follows }
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
                    // A popup with views resizes with the motion its views slide with, so switching doesn't snap.
                    self.resize(panel, shadow: shadow, to: height, inset: shadowInset,
                                animation: popup.views.isEmpty ? popup.animation : popup.animation ?? WidgetAnimation())
                }
                .padding(shadowInset)
        }
        .onHover { [weak self, weak panel] inside in
            if panel === self?.panel { self?.hoverPopup(inside) }
        })
        let height = min(sizes[widget.id]?.height ?? popup.height.map { CGFloat($0) } ?? host.fittingSize.height - shadowInset * 2, maximumHeight)
        panel.size.height = height
        panel.setFrame(NSRect(x: x - shadowInset, y: upward ? edge + gap - shadowInset : edge - height - gap - shadowInset,
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
        if popup.pinnable {
            panel.minSize = NSSize(width: 240 + shadowInset * 2, height: 140 + shadowInset * 2)
            let edges = PopupResizeEdges(frame: panel.contentView!.bounds, inset: shadowInset) { [weak self] panel, frame in
                guard let self else { return }
                self.keepSize(widget.id, of: panel)
                self.sizes[widget.id] = frame.insetBy(dx: shadowInset, dy: shadowInset).size
                for window in [panel, shadow].compactMap({ $0 }) { window.setFrame(frame, display: true) }
                panel.invalidateShadow()
            }
            if upward { edges.resizable = [.leading, .trailing, .top] }
            panel.contentView!.addSubview(edges)
            panel.resizeEdges = edges
        }
        if sizes[widget.id] != nil { keepSize(widget.id, of: panel) }
        widgetID = widget.id
        self.store = store
        onClose = popup.onClose.map { ($0, widget) }
        if let command = popup.onOpen { store.widgetScripts.runAction(command, widget: widget, event: ScriptEvent(sender: "popup.opened")) }
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
        let (fromHalf, toHalf) = (min(from.box.width, from.box.height) / 2, min(toBox.width, toBox.height) / 2)
        let (fromRadius, toRadius) = (min(from.cornerRadius, fromHalf), min(appearance.cornerRadius, toHalf))
        // SwiftUI draws a corner of half the shorter side or more as a capsule, while Core Animation's continuous corner
        // comes to a point there, so such a card takes circular corners.
        let capsule = from.cornerRadius >= fromHalf || appearance.cornerRadius >= toHalf
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
        panel.effectiveAppearance.performAsCurrentDrawingAppearance {
            outline.borderColor = NSColor(appearance.border(increasedContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)).cgColor
        }
        let cards = [morph, from.panel, panel].map { window in (CALayer(), window) } + [(outline, morph)]
        for (card, window) in cards {
            card.anchorPoint = .zero
            card.frame = from.box.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
            card.cornerCurve = capsule ? .circular : .continuous
            card.cornerRadius = fromRadius
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
                                                 ("cornerRadius", card.cornerRadius, toRadius)]
            card.frame = target
            card.cornerRadius = toRadius
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
            for window in windows {
                transition.animate(window.contentView!, source: source, upward: panel.opensUpward, closing: false, with: animation)
            }
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
                        let navigation = self.panel!.navigation
                        if navigation.view == nil { self.close() } else { navigation.view = nil }
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
            // Answering a permission prompt the popup asked for, such as System Audio Recording, leaves it open.
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier != AppWatcher.permissionPrompts else { return }
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
        hoverOrigin = nil
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

    /// Keeps the open popup on screen through clicks elsewhere, app switches and other popups, and lets it be resized from
    /// its top too. Unless it's being dragged, it moves to where the widget's popup was last pinned.
    func pin(dragging: Bool = false) {
        let id = widgetID!
        let panel = panel!
        finishMorph()
        stopWatching()
        store!.setPopupVisibleWidget(nil)
        pinnedPopups[id] = PinnedPopup(panel: panel, shadow: shadowWindow, anchor: anchor, store: store!,
                                       home: NSPoint(x: panel.frame.minX, y: panel.opensUpward ? panel.frame.minY : panel.frame.maxY),
                                       homeScreen: panel.screen!.visibleFrame,
                                       shown: shown!, animation: animation!, transition: transition, source: source, morphPopups: morphPopups,
                                       onClose: onClose)
        onClose = nil
        pins.ids.insert(id)
        panel.resizeEdges?.resizable = .all
        panel.onEscape = { [weak self] in self?.closePinned(id) }
        if let shadowWindow { panel.addChildWindow(shadowWindow, ordered: .below) }
        if !dragging, let spot = spots[id] {
            let size = panel.frame.size
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
        popup.panel.onEscape = nil
        pins.ids.remove(id)
        spots[id] = (popup.panel.frame, false)
        close()
        // The widget can leave the bar, with a configuration change or its display, while its popup is pinned.
        guard let anchor = popup.anchor, let store = popup.store else {
            if let onClose = popup.onClose { popup.store?.widgetScripts.runAction(onClose.command, widget: onClose.widget, event: ScriptEvent(sender: "popup.closed")) }
            dismiss([popup.panel, popup.shadow].compactMap { $0 }, transition: popup.transition, source: popup.source,
                    upward: popup.panel.opensUpward, animation: popup.animation)
            return
        }
        popup.panel.resizeEdges?.resizable = [.leading, .trailing, popup.panel.opensUpward ? .top : .bottom]
        panel = popup.panel
        shadowWindow = popup.shadow
        shown = popup.shown
        widgetID = id
        self.anchor = anchor
        self.store = store
        animation = popup.animation
        transition = popup.transition
        source = popup.source
        morphPopups = popup.morphPopups
        onClose = popup.onClose
        pinned = true
        store.setPopupVisibleWidget(id, anchor: anchor)
        watchEvents(anchor: anchor, pinnable: true)
        // A popup keeps the size it was given, so a wider one may need to move left to stay on its screen.
        let size = popup.panel.frame.size
        let x = min(popup.home.x, popup.homeScreen.maxX - size.width)
        let y = popup.panel.opensUpward ? popup.home.y : popup.home.y - size.height
        move(popup.panel, to: NSRect(x: x, y: y, width: size.width, height: size.height), with: popup.animation)
    }

    func closePinned(_ id: String) {
        let popup = pinnedPopups.removeValue(forKey: id)!
        popup.panel.onEscape = nil
        pins.ids.remove(id)
        spots[id] = (popup.panel.frame, true)
        pins.resized.remove(id)
        if let onClose = popup.onClose { popup.store?.widgetScripts.runAction(onClose.command, widget: onClose.widget, event: ScriptEvent(sender: "popup.closed")) }
        dismiss([popup.panel, popup.shadow].compactMap { $0 }, transition: popup.transition, source: popup.source,
                upward: popup.panel.opensUpward, animation: popup.animation)
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
            let y = panel.opensUpward ? panel.frame.minY : panel.frame.maxY - height - inset * 2
            let frame = NSRect(x: panel.frame.minX, y: y, width: panel.frame.width, height: height + inset * 2)
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
        let window = PopupShadowPanel(contentRect: panel.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
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
        let host = NSHostingView(rootView: PopupCanvas(size: panel.size, inset: inset, upward: panel.opensUpward) {
            PopupShadowView(cornerRadius: appearance.cornerRadius, color: appearance.shadowColor, radius: appearance.shadowRadius, inset: inset)
        })
        window.contentView = PopupRevealView(content: host, size: panel.frame.size)
        return window
    }

    func close() {
        if let onClose { store?.widgetScripts.runAction(onClose.command, widget: onClose.widget, event: ScriptEvent(sender: "popup.closed")) }
        onClose = nil
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
        dismiss([panel, shadowWindow].compactMap { $0 }, transition: transition, source: source, upward: panel?.opensUpward == true, animation: animation)
        panel = nil
        shadowWindow = nil
        shown = nil
        widgetID = nil
        anchor = nil
        animation = nil
    }

    private func dismiss(_ windows: [NSWindow], transition: PopupTransition, source: CGFloat, upward: Bool, animation: WidgetAnimation?) {
        if let animation {
            if animation.duration > 0, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                for window in windows { transition.animate(window.contentView!, source: source, upward: upward, closing: true, with: animation) }
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

/// Whether `point` lies in the triangle from `origin` to the popup's near edge, below or above it.
func popupHoverTriangleContains(_ point: NSPoint, from origin: NSPoint, to popup: NSRect) -> Bool {
    guard origin.y > popup.maxY || origin.y < popup.minY else { return false }
    let edge = origin.y > popup.maxY ? popup.maxY : popup.minY
    let progress = (origin.y - point.y) / (origin.y - edge)
    guard (0...1).contains(progress) else { return false }
    let left = origin.x + (popup.minX - origin.x) * progress
    let right = origin.x + (popup.maxX - origin.x) * progress
    return point.x >= left && point.x <= right
}

/// A tooltip's style: the popup style `defaults` and the widget's tooltip style, with a compact padding whatever they or
/// their states set. Its spacing is the widget's own, as on the bar, or 6. Hover controls apply the widget's data state
/// again when they draw.
func tooltipStyle(defaults: WidgetStyle, widget: WidgetStyle, states: StyleStates = StyleStates(), sidePadding: Double = 10) -> WidgetStyle {
    WidgetStyle(paddingHorizontal: sidePadding, paddingVertical: 6)
        .inheriting(resolveStyle([WidgetStyle(spacing: 6), defaults.withoutSpacing, widget.withoutPadding], states: states))
}
