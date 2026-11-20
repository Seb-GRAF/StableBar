import AppKit
import SwiftUI

@MainActor
final class PopupPanel: NSPanel {
    /// Closes a pinned popup, which no event monitor watches, on Escape and ⌘W.
    var onEscape: (() -> Void)?
    let size = PopupSize()
    let navigation = PopupNavigation()
    /// Opens above its anchor, from a bar at the bottom of the display: it grows and resizes from its top.
    var opensUpward = false
    /// What resizes a pinnable popup from its edges.
    var resizeEdges: PopupResizeEdges?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    @objc var hasKeyAppearance: Bool { true }

    /// Under a bar at the top of the display, the margin left for the popup's shadow reaches into the menu bar, and AppKit
    /// would move the window, popup and all, down out of it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53, let onEscape {
            if navigation.view == nil { onEscape() } else { navigation.view = nil }
        } else {
            super.sendEvent(event)
        }
    }

    /// AppKit turns Close off for a window without a title-bar close button.
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(performClose(_:)) ? onEscape != nil : super.validateMenuItem(menuItem)
    }

    override func performClose(_ sender: Any?) {
        if let onEscape { onEscape() } else { super.performClose(sender) }
    }
}

/// The window behind a popup's that draws its shadow, kept where it's placed like the popup's.
final class PopupShadowPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
final class PopupRevealView: NSView {
    init(content: NSView, size: NSSize) {
        super.init(frame: NSRect(origin: .zero, size: size))
        clipsToBounds = true
        wantsLayer = true
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError("PopupRevealView is created programmatically.") }
}

/// Lies over a popup's content and resizes the popup when its visible edges or corners are dragged.
@MainActor
final class PopupResizeEdges: NSView {
    /// All edges once the popup is pinned; at its widget, the edge facing the widget stays put.
    var resizable: Edge.Set = [.leading, .trailing, .bottom] {
        didSet { window?.invalidateCursorRects(for: self) }
    }
    let inset: CGFloat
    private let onResize: (PopupPanel, NSRect) -> Void
    private let band: CGFloat = 4
    private let corner: CGFloat = 24
    private var drag: (start: NSPoint, frame: NSRect, edges: Edge.Set)?

    init(frame: NSRect, inset: CGFloat, onResize: @escaping (PopupPanel, NSRect) -> Void) {
        self.inset = inset
        self.onResize = onResize
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError("PopupResizeEdges is created programmatically.") }

    private var popup: NSRect { bounds.insetBy(dx: inset, dy: inset) }

    /// How far each corner reaches along its edges; a short popup's corners meet halfway.
    private var reach: NSSize { NSSize(width: min(corner, popup.width / 2), height: min(corner, popup.height / 2)) }

    /// The edges a drag from `point` moves. The grab area lies just inside the popup's drawn edge: clicks on the
    /// transparent shadow inset around it go to the window below.
    private func edges(at point: NSPoint) -> Edge.Set {
        guard popup.contains(point), !popup.insetBy(dx: band, dy: band).contains(point) else { return [] }
        var edges: Edge.Set = []
        if point.x < popup.minX + reach.width { edges.insert(.leading) }
        if point.x > popup.maxX - reach.width { edges.insert(.trailing) }
        if point.y < popup.minY + reach.height { edges.insert(.bottom) }
        if point.y > popup.maxY - reach.height { edges.insert(.top) }
        return resizable.isSuperset(of: edges) ? edges : []
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        edges(at: convert(point, from: superview)).isEmpty ? nil : self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var mouseDownCanMoveWindow: Bool { false }

    // Cursor rects mustn't overlap, so each cell of the grid where the grabbed edges change gets its own.
    override func resetCursorRects() {
        let xs = [popup.minX, popup.minX + band, popup.minX + reach.width, popup.maxX - reach.width, popup.maxX - band, popup.maxX]
        let ys = [popup.minY, popup.minY + band, popup.minY + reach.height, popup.maxY - reach.height, popup.maxY - band, popup.maxY]
        for (left, right) in zip(xs, xs.dropFirst()) {
            for (bottom, top) in zip(ys, ys.dropFirst()) {
                let cell = NSRect(x: left, y: bottom, width: right - left, height: top - bottom)
                let edges = edges(at: NSPoint(x: cell.midX, y: cell.midY))
                if !edges.isEmpty { addCursorRect(cell, cursor: cursor(for: edges)) }
            }
        }
    }

    private func cursor(for edges: Edge.Set) -> NSCursor {
        guard #available(macOS 15, *) else {
            return edges.isDisjoint(with: [.leading, .trailing]) ? .resizeUpDown : .resizeLeftRight
        }
        let position: NSCursor.FrameResizePosition = switch edges {
        case .top: .top
        case .bottom: .bottom
        case .leading: .left
        case .trailing: .right
        case [.top, .leading]: .topLeft
        case [.top, .trailing]: .topRight
        case [.bottom, .leading]: .bottomLeft
        default: .bottomRight
        }
        return .frameResize(position: position, directions: .all)
    }

    override func mouseDown(with event: NSEvent) {
        drag = (window!.convertPoint(toScreen: event.locationInWindow), window!.frame, edges(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseDragged(with event: NSEvent) {
        let (start, frame, edges) = drag!
        let window = window as! PopupPanel
        let location = window.convertPoint(toScreen: event.locationInWindow)
        onResize(window, resizedPopupFrame(frame, moving: edges, by: NSPoint(x: location.x - start.x, y: location.y - start.y),
                                           minSize: window.minSize, within: window.screen!.visibleFrame.insetBy(dx: -inset, dy: -inset)))
    }
}

/// A popup's own shadow without the popup, for a window behind the popup's.
struct PopupShadowView: View {
    let cornerRadius: Double
    let color: Color
    let radius: Double
    let x: Double
    let y: Double
    let inset: CGFloat

    var body: some View {
        Canvas { context, size in
            let shape = RoundedRectangle(cornerRadius: cornerRadius).path(in: CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset))
            var shadow = context
            shadow.addFilter(.shadow(color: color, radius: radius, x: x, y: y))
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
    /// The popup is as tall as its content, which then has nothing to scroll.
    var followsContent = false
}

/// The view a popup shows in place of its layout, opened from a block's `view`; nil shows the layout.
@MainActor @Observable
final class PopupNavigation {
    var view: String?
}

/// A popup, or its shadow, drawn at the top of its window, or at the bottom when it opens upward, at `size`'s height and
/// its shadow's inset around it, so the window can be taller than the popup while the popup's height animates.
struct PopupCanvas<Content: View>: View {
    let size: PopupSize
    let inset: CGFloat
    let upward: Bool
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(height: size.height.map { $0 + inset * 2 })
            .frame(maxHeight: .infinity, alignment: upward ? .bottom : .top)
    }
}

/// `frame` with its `edges` moved by `offset`, as a drag moves them, and its other edges where they are. It stays at least
/// `minSize`, and the edges it moves stay inside `bounds`.
func resizedPopupFrame(_ frame: NSRect, moving edges: Edge.Set, by offset: NSPoint, minSize: NSSize, within bounds: NSRect) -> NSRect {
    var (minX, maxX, minY, maxY) = (frame.minX, frame.maxX, frame.minY, frame.maxY)
    if edges.contains(.leading) { minX = min(max(minX + offset.x, bounds.minX), maxX - minSize.width) }
    if edges.contains(.trailing) { maxX = max(min(maxX + offset.x, bounds.maxX), minX + minSize.width) }
    if edges.contains(.bottom) { minY = min(max(minY + offset.y, bounds.minY), maxY - minSize.height) }
    if edges.contains(.top) { maxY = max(min(maxY + offset.y, bounds.maxY), minY + minSize.height) }
    return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
}
