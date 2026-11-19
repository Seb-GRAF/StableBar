import AppKit
import SwiftUI

/// Native drag completion clears the insertion marker on cancellation and drops outside
/// the bar. All displays share the model's authenticated, single-use drag session.
struct BarEditDragSource<Content: View>: NSViewRepresentable {
    let editing: BarEditing
    let widgetID: String
    let name: String
    let select: () -> Void
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> BarEditDragSourceView {
        BarEditDragSourceView(rootView: AnyView(content()))
    }

    func updateNSView(_ view: BarEditDragSourceView, context: Context) {
        view.rootView = AnyView(content())
        view.editing = editing
        view.widgetID = widgetID
        view.name = name
        view.select = select
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BarEditDragSourceView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.fittingSize.width, height: proposal.height ?? nsView.fittingSize.height)
    }
}

final class BarEditDragSourceView: WidgetDragSourceView {
    static let lift: CGFloat = 1.05
    weak var editing: BarEditing?
    var widgetID = ""
    var select: () -> Void = {}
    private(set) var liftedImage: NSImage?
    override var isFlipped: Bool { true }
    override var dragSession: WidgetDragSession? { editing?.isActive == true ? editing?.dragSession : nil }
    override var dragWidgetID: String? { widgetID }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if let event = NSApp?.currentEvent, ![NSEvent.EventType.leftMouseDown, .leftMouseUp, .leftMouseDragged].contains(event.type) {
            return hit
        }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        NSCursor.closedHand.set()
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        NSCursor.openHand.set()
        if mouseDownPoint != nil, bounds.contains(convert(event.locationInWindow, from: nil)) { select() }
        super.mouseUp(with: event)
    }

    override func dragImage() -> NSImage {
        let snapshot = bitmapImageRepForCachingDisplay(in: bounds)!
        cacheDisplay(in: bounds, to: snapshot)
        let tile = NSImage(cgImage: snapshot.cgImage!, size: bounds.size)
        let image = NSImage(size: NSSize(width: bounds.width * Self.lift + 16, height: bounds.height * Self.lift + 16), flipped: false) { rect in
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 6
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            shadow.shadowColor = .black.withAlphaComponent(0.3)
            shadow.set()
            tile.draw(in: rect.insetBy(dx: 8, dy: 8))
            return true
        }
        liftedImage = image
        return image
    }

    override func beginWidgetDrag(with item: NSDraggingItem, event: NSEvent) {
        let size = item.draggingFrame.size
        item.draggingFrame = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
        super.beginWidgetDrag(with: item, event: event)
    }

    override func didEndWidgetDrag() { editing?.insertion = nil }

    override func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        NSCursor.arrow.set()
        super.draggingSession(session, endedAt: screenPoint, operation: operation)
        editing?.finishDrop()
    }
}

struct BarEditDropTarget<Content: View>: NSViewRepresentable {
    let editing: BarEditing
    let displayID: Int
    /// Where drags aim at each position, empty ones included, within the position's side.
    let spans: [WidgetPosition: ClosedRange<CGFloat>]
    let frames: [String: CGRect]
    /// The sides too crowded for their widgets, which scroll by `scroll`.
    let scrolling: [BarEditSide]
    let scroll: (BarEditSide, CGFloat) -> Void
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> BarEditDropTargetView {
        let view = BarEditDropTargetView(rootView: AnyView(content()), sizingOptions: [])
        view.registerForDraggedTypes([BarEditDragSourceView.pasteboardType])
        return view
    }

    func updateNSView(_ view: BarEditDropTargetView, context: Context) {
        view.rootView = AnyView(content())
        view.editing = editing
        view.displayID = displayID
        view.spans = spans
        view.frames = frames
        view.scrolling = scrolling
        view.scroll = scroll
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BarEditDropTargetView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.fittingSize.width, height: proposal.height ?? nsView.fittingSize.height)
    }
}

/// The edit bar takes the size of the bar. A crowded side's widgets at full size are wider, so neither the
/// bar nor its content reports their size to Auto Layout, which would otherwise stretch it past the screen's edge.
final class BarEditDropTargetView: WidgetHostingView {
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    weak var editing: BarEditing?
    var displayID = 0
    var spans: [WidgetPosition: ClosedRange<CGFloat>] = [:]
    var frames: [String: CGRect] = [:]
    var scrolling: [BarEditSide] = []
    var scroll: (BarEditSide, CGFloat) -> Void = { _, _ in }

    override func scrollWheel(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        guard let side = scrolling.first(where: { $0.visible.contains(x) }) else { return super.scrollWheel(with: event) }
        // A mouse wheel turns the side too, a line at a time.
        let delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        scroll(side, -delta * (event.hasPreciseScrollingDeltas ? 1 : 10))
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let payload = acceptedPayload(sender) else { return [] }
        // Holding a widget near a crowded side's edge scrolls that side; AppKit repeats this while the pointer rests.
        let x = convert(sender.draggingLocation, from: nil).x
        if let side = scrolling.first(where: { $0.visible.contains(x) }) {
            if x < side.visible.lowerBound + 32 { scroll(side, -6) } else if x > side.visible.upperBound - 32 { scroll(side, 6) }
        }
        guard let target = target(sender, payload: payload) else { return [] }
        if editing?.insertion != target { editing?.insertion = target }
        // AppKit shows the arrow during a drag; over the bar, the hand keeps holding the widget.
        NSCursor.closedHand.set()
        return .move
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        if editing?.insertion?.displayID == displayID { editing?.insertion = nil }
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        sender.animatesToDestination = true
        return acceptedPayload(sender) != nil
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let payload = acceptedPayload(sender), let target = target(sender, payload: payload) else { return false }
        let gap = frames.filter { editing?.isMoving($0.key) == true }.values.reduce(CGRect.null) { $0.union($1) }
        if !gap.isNull {
            let image = (sender.draggingSource as! BarEditDragSourceView).liftedImage
            sender.enumerateDraggingItems(for: self, classes: [NSPasteboardItem.self]) { item, _, _ in
                let size = NSSize(width: item.draggingFrame.width / BarEditDragSourceView.lift,
                                  height: item.draggingFrame.height / BarEditDragSourceView.lift)
                item.setDraggingFrame(NSRect(x: gap.midX - size.width / 2, y: gap.midY - size.height / 2, width: size.width, height: size.height),
                                      contents: image)
            }
        }
        return editing?.drop(payload, at: target) ?? false
    }

    private func target(_ sender: any NSDraggingInfo, payload: WidgetDragSession.Payload) -> BarEditInsertion? {
        let x = convert(sender.draggingLocation, from: nil).x
        guard let position = WidgetPlacement.position(at: x, in: spans) else { return nil }
        return editing?.dropTarget(payload.widgetID, on: displayID, position: position, x: x, frames: frames)
    }

    private func acceptedPayload(_ sender: any NSDraggingInfo) -> WidgetDragSession.Payload? {
        guard editing?.isActive == true, let source = sender.draggingSource as? BarEditDragSourceView,
              let data = sender.draggingPasteboard.data(forType: BarEditDragSourceView.pasteboardType) else { return nil }
        return editing?.dragSession.payload(from: data, source: source.editing?.dragSession)
    }
}
