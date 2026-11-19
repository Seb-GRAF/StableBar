import AppKit
import SwiftUI

/// AppKit supplies the drag-end callback on every supported macOS version,
/// including Escape and drops outside the window.
struct WidgetDragRow<Content: View>: NSViewRepresentable {
    let session: WidgetDragSession
    let widgetID: String?
    let name: String
    let insertionKey: String
    let select: () -> Void
    let move: (String) -> Void
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> WidgetDragRowView {
        let view = WidgetDragRowView(rootView: AnyView(content()))
        view.registerForDraggedTypes([WidgetDragRowView.pasteboardType])
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: WidgetDragRowView, context: Context) {
        view.rootView = AnyView(content())
        view.session = session
        view.widgetID = widgetID
        view.name = name
        view.insertionKey = insertionKey
        view.select = select
        view.move = move
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WidgetDragRowView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.fittingSize.width, height: nsView.fittingSize.height)
    }
}

final class WidgetDragRowView: WidgetDragSourceView {
    var session: WidgetDragSession?
    var widgetID: String?
    var insertionKey = ""
    var select: () -> Void = {}
    var move: (String) -> Void = { _ in }
    override var dragSession: WidgetDragSession? { session }
    override var dragWidgetID: String? { widgetID }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        window?.makeFirstResponder(enclosingScrollView?.documentView)
        select()
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard acceptedPayload(sender) != nil else { return [] }
        session?.insertion = insertionKey
        return .move
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        if session?.insertion == insertionKey { session?.insertion = nil }
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { acceptedPayload(sender) != nil }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let payload = acceptedPayload(sender) else { return false }
        return session?.drop(payload, move: move) ?? false
    }

    private func acceptedPayload(_ sender: any NSDraggingInfo) -> WidgetDragSession.Payload? {
        guard let source = sender.draggingSource as? WidgetDragSourceView,
              let data = sender.draggingPasteboard.data(forType: Self.pasteboardType) else { return nil }
        return session?.payload(from: data, source: source.dragSession)
    }
}
