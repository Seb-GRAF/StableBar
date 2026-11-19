import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class WorkspaceWindowDragSession {
    struct Payload: Equatable {
        let token = UUID()
        let source: WorkspaceSource
        let workspace: String
        let windows: [WorkspaceWindow]
    }

    static let typeIdentifier = "com.stablebar.workspace-window-move"
    private(set) var active: Payload?
    var target: String?

    func begin(source: WorkspaceSource, windows: [WorkspaceWindow]) -> Payload? {
        guard source.supportsWindowMoves, let workspace = windows.first?.app.workspace,
              windows.allSatisfy({ $0.app.workspace == workspace }) else { return nil }
        let payload = Payload(source: source, workspace: workspace, windows: windows)
        active = payload
        target = nil
        return payload
    }

    func end(_ payload: Payload) {
        guard active == payload else { return }
        active = nil
        target = nil
    }
}

/// Keep the button's keyboard and accessibility actions, while AppKit distinguishes
/// a click from a drag and reports cancellation, Escape and drops outside the bar.
struct WorkspaceWindowDragSource<Content: View>: NSViewRepresentable {
    let store: WorkspaceStore
    let windows: [WorkspaceWindow]
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> WorkspaceWindowDragSourceView {
        WorkspaceWindowDragSourceView(rootView: AnyView(content()))
    }

    func updateNSView(_ view: WorkspaceWindowDragSourceView, context: Context) {
        view.rootView = AnyView(content().environment(\.self, context.nestedEnvironment))
        view.store = store
        view.windows = windows
        view.action = action
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WorkspaceWindowDragSourceView, context: Context) -> CGSize? {
        nsView.fittingSize
    }
}

class WorkspaceWindowDragSourceView: WidgetHostingView, NSDraggingSource {
    static let pasteboardType = NSPasteboard.PasteboardType(WorkspaceWindowDragSession.typeIdentifier)
    weak var store: WorkspaceStore?
    var windows: [WorkspaceWindow] = []
    var action: () -> Void = {}
    private var mouseDownPoint: NSPoint?
    private var drag: (session: WorkspaceWindowDragSession, payload: WorkspaceWindowDragSession.Payload)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if let event = NSApp?.currentEvent, ![NSEvent.EventType.leftMouseDown, .leftMouseUp, .leftMouseDragged].contains(event.type) {
            return hit
        }
        return self
    }

    override func mouseDown(with event: NSEvent) { mouseDownPoint = event.locationInWindow }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseUp(with event: NSEvent) {
        let clicked = mouseDownPoint != nil && bounds.contains(convert(event.locationInWindow, from: nil))
        mouseDownPoint = nil
        if clicked { action() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, let store,
              hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) >= 4 else { return }
        mouseDownPoint = nil
        guard let payload = store.windowDrag.begin(source: store.source, windows: windows) else { return }
        drag = (store.windowDrag, payload)
        let item = NSPasteboardItem()
        item.setString(payload.token.uuidString, forType: Self.pasteboardType)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        let frame = bounds.insetBy(dx: -bounds.height, dy: 0)
        let image = NSImage(size: frame.size)
        if let bitmap = bitmapImageRepForCachingDisplay(in: frame) {
            cacheDisplay(in: frame, to: bitmap)
            image.addRepresentation(bitmap)
        }
        draggingItem.setDraggingFrame(frame, contents: image)
        beginWindowDrag(with: draggingItem, event: event)
    }

    func beginWindowDrag(with item: NSDraggingItem, event: NSEvent) {
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        endWindowDrag()
    }

    func endWindowDrag() {
        if let drag { drag.session.end(drag.payload) }
        drag = nil
        mouseDownPoint = nil
    }
}

struct WorkspaceWindowDrop: ViewModifier {
    let store: WorkspaceStore
    let workspace: String
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled && store.source.supportsWindowMoves {
            WorkspaceWindowDropTarget(store: store, workspace: workspace) { content }
        } else {
            content
        }
    }

}

/// The source and destination share AppKit's pasteboard and synchronous drop lifecycle.
private struct WorkspaceWindowDropTarget<Content: View>: NSViewRepresentable {
    let store: WorkspaceStore
    let workspace: String
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> WorkspaceWindowDropTargetView {
        WorkspaceWindowDropTargetView(rootView: AnyView(content()))
    }

    func updateNSView(_ view: WorkspaceWindowDropTargetView, context: Context) {
        view.rootView = AnyView(content().environment(\.self, context.nestedEnvironment))
        view.store = store
        view.workspace = workspace
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WorkspaceWindowDropTargetView, context: Context) -> CGSize? {
        nsView.fittingSize
    }
}

/// A workspace cell. It isn't registered for drags itself: the bar window receives them and
/// forwards them to the cell under the pointer.
final class WorkspaceWindowDropTargetView: WidgetHostingView {
    weak var store: WorkspaceStore?
    var workspace = ""

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard acceptedPayload(sender) != nil else {
            clearTarget()
            return []
        }
        store?.windowDrag.target = workspace
        return .move
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { clearTarget() }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { acceptedPayload(sender) != nil }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let payload = acceptedPayload(sender), let store else { return false }
        return store.moveWindows(payload, to: workspace) != nil
    }

    private func acceptedPayload(_ sender: any NSDraggingInfo) -> WorkspaceWindowDragSession.Payload? {
        guard let store, let source = sender.draggingSource as? WorkspaceWindowDragSourceView,
              source.store === store, sender.draggingSourceOperationMask.contains(.move),
              let payload = store.windowDrag.active,
              sender.draggingPasteboard.string(forType: WorkspaceWindowDragSourceView.pasteboardType) == payload.token.uuidString,
              store.canMoveWindows(payload, to: workspace) else { return nil }
        return payload
    }

    private func clearTarget() {
        if store?.windowDrag.target == workspace { store?.windowDrag.target = nil }
    }
}

/// AppKit looks for a drop destination by walking view frames, but SwiftUI can host a cell in a
/// container whose frame doesn't contain it, so a registered cell may never be reached. The bar
/// window takes the drag instead and finds the cell under the pointer by hit-testing, as clicks do.
extension BarPanel: NSDraggingDestination {
    func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let target = dropTarget(at: sender.draggingLocation)
        if target !== workspaceDropTarget { workspaceDropTarget?.draggingExited(sender) }
        workspaceDropTarget = target
        return target?.draggingUpdated(sender) ?? []
    }

    func draggingExited(_ sender: (any NSDraggingInfo)?) {
        workspaceDropTarget?.draggingExited(sender)
        workspaceDropTarget = nil
    }

    func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dropTarget(at: sender.draggingLocation)?.prepareForDragOperation(sender) ?? false
    }

    func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        workspaceDropTarget = nil
        return dropTarget(at: sender.draggingLocation)?.performDragOperation(sender) ?? false
    }

    private func dropTarget(at location: NSPoint) -> WorkspaceWindowDropTargetView? {
        guard let contentView, let frame = contentView.superview,
              let hit = contentView.hitTest(frame.convert(location, from: nil)) else { return nil }
        return sequence(first: hit, next: \.superview).lazy.compactMap { $0 as? WorkspaceWindowDropTargetView }.first
    }
}
