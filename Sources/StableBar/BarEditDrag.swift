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
    weak var editing: BarEditing?
    var widgetID = ""
    var select: () -> Void = {}
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

    override func mouseUp(with event: NSEvent) {
        if mouseDownPoint != nil, bounds.contains(convert(event.locationInWindow, from: nil)) { select() }
        super.mouseUp(with: event)
    }

    override func dragImage() -> NSImage {
        let name = name
        return NSImage(size: NSSize(width: 150, height: 28), flipped: false) { rect in
            NSColor.controlBackgroundColor.setFill()
            rect.fill()
            (name as NSString).draw(in: rect.insetBy(dx: 8, dy: 5), withAttributes: [.font: NSFont.systemFont(ofSize: 12),
                                                                                  .foregroundColor: NSColor.labelColor])
            return true
        }
    }

    override func didEndWidgetDrag() { editing?.insertion = nil }
}

struct BarEditDropTarget<Content: View>: NSViewRepresentable {
    let editing: BarEditing
    let displayID: Int
    let position: WidgetPosition
    let frames: [String: CGRect]
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> BarEditDropTargetView {
        let view = BarEditDropTargetView(rootView: AnyView(content()))
        view.registerForDraggedTypes([BarEditDragSourceView.pasteboardType])
        return view
    }

    func updateNSView(_ view: BarEditDropTargetView, context: Context) {
        view.rootView = AnyView(content())
        view.editing = editing
        view.displayID = displayID
        view.position = position
        view.frames = frames
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BarEditDropTargetView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.fittingSize.width, height: proposal.height ?? nsView.fittingSize.height)
    }
}

final class BarEditDropTargetView: WidgetHostingView {
    override var isFlipped: Bool { true }
    weak var editing: BarEditing?
    var displayID = 0
    var position = WidgetPosition.left
    var frames: [String: CGRect] = [:]

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let payload = acceptedPayload(sender), let target = target(sender, payload: payload) else { return [] }
        editing?.insertion = target
        return .move
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        if editing?.insertion?.displayID == displayID, editing?.insertion?.position == position { editing?.insertion = nil }
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { acceptedPayload(sender) != nil }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let payload = acceptedPayload(sender), let target = target(sender, payload: payload) else { return false }
        return editing?.drop(payload, at: target) ?? false
    }

    private func target(_ sender: any NSDraggingInfo, payload: WidgetDragSession.Payload) -> BarEditInsertion? {
        editing?.dropTarget(payload.widgetID, on: displayID, position: position,
                            x: convert(sender.draggingLocation, from: nil).x, frames: frames)
    }

    private func acceptedPayload(_ sender: any NSDraggingInfo) -> WidgetDragSession.Payload? {
        guard editing?.isActive == true, let source = sender.draggingSource as? BarEditDragSourceView,
              let data = sender.draggingPasteboard.data(forType: BarEditDragSourceView.pasteboardType) else { return nil }
        return editing?.dragSession.payload(from: data, source: source.editing?.dragSession)
    }
}
