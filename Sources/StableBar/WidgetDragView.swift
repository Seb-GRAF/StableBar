import AppKit
import SwiftUI

class WidgetHostingView: NSView {
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
}

/// Both widget editors use the same native drag lifecycle and single-use payload.
class WidgetDragSourceView: WidgetHostingView, NSDraggingSource {
    static let pasteboardType = NSPasteboard.PasteboardType(WidgetDragSession.typeIdentifier)
    var dragSession: WidgetDragSession? { nil }
    var dragWidgetID: String? { nil }
    var name = ""
    private(set) var mouseDownPoint: NSPoint?
    private var drag: (session: WidgetDragSession, payload: WidgetDragSession.Payload)?

    override func mouseDown(with event: NSEvent) { mouseDownPoint = event.locationInWindow }
    override func mouseUp(with event: NSEvent) { mouseDownPoint = nil }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, let widgetID = dragWidgetID, let session = dragSession,
              hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) >= 4 else { return }
        mouseDownPoint = nil
        let payload = session.begin(widgetID)
        guard let data = try? JSONEncoder().encode(payload) else { session.end(payload); return }
        drag = (session, payload)
        let item = NSPasteboardItem()
        item.setData(data, forType: Self.pasteboardType)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        let image = dragImage()
        draggingItem.setDraggingFrame(NSRect(origin: convert(event.locationInWindow, from: nil), size: image.size), contents: image)
        beginWidgetDrag(with: draggingItem, event: event)
    }

    func beginWidgetDrag(with item: NSDraggingItem, event: NSEvent) {
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func dragImage() -> NSImage {
        let name = name
        return NSImage(size: NSSize(width: max(bounds.width, 120), height: 28), flipped: false) { rect in
            (name as NSString).draw(in: rect.insetBy(dx: 8, dy: 4), withAttributes: [.font: NSFont.systemFont(ofSize: 13)])
            return true
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        endWidgetDrag()
    }

    func endWidgetDrag() {
        if let drag, drag.session.accepts(drag.payload) {
            drag.session.end(drag.payload)
            didEndWidgetDrag()
        }
        drag = nil
        mouseDownPoint = nil
    }

    func didEndWidgetDrag() {}
}
