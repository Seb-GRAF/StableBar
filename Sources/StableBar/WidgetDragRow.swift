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

final class WidgetDragRowView: NSView, NSDraggingSource {
    static let pasteboardType = NSPasteboard.PasteboardType(WidgetDragSession.typeIdentifier)
    var session: WidgetDragSession?
    var widgetID: String?
    var name = ""
    var insertionKey = ""
    var select: () -> Void = {}
    var move: (String) -> Void = { _ in }
    private var mouseDownPoint: NSPoint?
    private var payload: WidgetDragSession.Payload?
    private let hostingView: NSHostingView<AnyView>

    var rootView: AnyView {
        get { hostingView.rootView }
        set { hostingView.rootView = newValue; invalidateIntrinsicContentSize() }
    }

    init(rootView: AnyView) {
        hostingView = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { hostingView.intrinsicContentSize }
    override var fittingSize: NSSize { hostingView.fittingSize }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        select()
        window?.makeFirstResponder(enclosingScrollView?.documentView)
    }

    override func mouseUp(with event: NSEvent) { mouseDownPoint = nil }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, let widgetID, let session,
              hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) >= 4 else { return }
        mouseDownPoint = nil
        let payload = session.begin(widgetID)
        self.payload = payload
        guard let data = try? JSONEncoder().encode(payload) else {
            session.end(payload)
            self.payload = nil
            return
        }
        let item = NSPasteboardItem()
        item.setData(data, forType: Self.pasteboardType)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        let name = name
        let image = NSImage(size: NSSize(width: max(bounds.width, 120), height: 28), flipped: false) { rect in
            (name as NSString).draw(in: rect.insetBy(dx: 8, dy: 4), withAttributes: [.font: NSFont.systemFont(ofSize: 13)])
            return true
        }
        draggingItem.setDraggingFrame(NSRect(origin: convert(event.locationInWindow, from: nil), size: image.size), contents: image)
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if let payload { self.session?.end(payload) }
        payload = nil
        mouseDownPoint = nil
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
        guard let source = sender.draggingSource as? WidgetDragRowView,
              let data = sender.draggingPasteboard.data(forType: Self.pasteboardType) else { return nil }
        return session?.payload(from: data, source: source.session)
    }
}
