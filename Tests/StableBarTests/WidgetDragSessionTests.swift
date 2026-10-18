import AppKit
import SwiftUI
import XCTest
@testable import StableBar

final class WidgetDragSessionTests: XCTestCase {
    @MainActor func testSharedDragSourceAuthenticatesOneNativeGestureAndCreatesOneUndoStep() throws {
        let fixture = try ThemeGalleryFixture(#"{"groups":{"pair":{}},"widgets":[{"id":"a","type":"clock","position":"left","group":"pair"},{"id":"b","type":"clock","position":"left","group":"pair"},{"id":"c","type":"clock","position":"left"}]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let before = try Data(contentsOf: fixture.url)
        let session = WidgetDragSession()
        let view = CapturingWidgetDragSource(rootView: AnyView(Text("Clock")))
        view.session = session
        view.widgetID = "b"
        view.mouseDown(with: try mouse(.leftMouseDown, x: 0))
        view.mouseDragged(with: try mouse(.leftMouseDragged, x: 3))
        XCTAssertNil(session.active)
        XCTAssertTrue(view.items.isEmpty)
        view.mouseDragged(with: try mouse(.leftMouseDragged, x: 4))
        view.mouseDragged(with: try mouse(.leftMouseDragged, x: 10))
        XCTAssertEqual(view.items.count, 1)
        let item = try XCTUnwrap(view.items.first?.item as? NSPasteboardItem)
        let data = try XCTUnwrap(item.data(forType: WidgetDragSourceView.pasteboardType))
        let payload = try XCTUnwrap(session.payload(from: data, source: view.dragSession))
        XCTAssertEqual(payload.widgetID, "b")
        XCTAssertNil(session.payload(from: data, source: WidgetDragSession()))
        var moves = 0
        let setup = WidgetSetup(store: store)
        let move: (String) -> Void = { id in
            moves += 1
            do { try setup.move(id, to: .right) }
            catch { XCTFail("Drop failed: \(error)") }
        }
        XCTAssertTrue(session.drop(payload, move: move))
        XCTAssertFalse(session.drop(payload, move: move))
        XCTAssertEqual(moves, 1)
        XCTAssertEqual(store.configuration?.widgets.filter { $0.group == "pair" }.map(\.position), [.right, .right])
        XCTAssertEqual(store.customizationHistory.undoSteps.count, 1)
        // A late completion from this drag must leave a newer drag alone.
        let newer = session.begin("c")
        view.endWidgetDrag()
        XCTAssertEqual(session.active, newer)
        try store.customizationHistory.undo()
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
    }

    @MainActor func testSharedNativeDragCancellationClearsInsertionAndRejectsItsPayload() throws {
        let session = WidgetDragSession()
        let view = CapturingWidgetDragSource(rootView: AnyView(Text("Clock")))
        view.session = session
        view.widgetID = "a"
        view.mouseDown(with: try mouse(.leftMouseDown, x: 0))
        view.mouseDragged(with: try mouse(.leftMouseDragged, x: 5))
        let payload = try XCTUnwrap(session.active)
        session.insertion = "right/"
        view.endWidgetDrag()
        XCTAssertNil(session.active)
        XCTAssertNil(session.insertion)
        XCTAssertNil(view.mouseDownPoint)
        XCTAssertEqual(view.completions, 1)
        XCTAssertFalse(session.drop(payload) { _ in XCTFail("A cancelled drag cannot move a widget") })
        view.endWidgetDrag()
        XCTAssertEqual(view.completions, 1)
    }

    @MainActor func testBothEditorsShareHostingAndKeepTheirCoordinateAndSelectionBehavior() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        store.barEditing.begin()
        let session = WidgetDragSession()
        let row = WidgetDragRowView(rootView: AnyView(Color.clear.frame(width: 80, height: 24)))
        row.session = session
        row.widgetID = "a"
        let bar = BarEditDragSourceView(rootView: AnyView(Color.clear.frame(width: 80, height: 24)))
        bar.editing = store.barEditing
        bar.widgetID = "a"
        let target = BarEditDropTargetView(rootView: AnyView(Color.clear.frame(width: 80, height: 24)))
        XCTAssertFalse(row.isFlipped)
        XCTAssertTrue(bar.isFlipped)
        XCTAssertTrue(target.isFlipped)
        XCTAssertTrue(row.dragSession === session)
        XCTAssertTrue(bar.dragSession === store.barEditing.dragSession)
        for view: WidgetHostingView in [row, bar, target] {
            XCTAssertEqual(view.fittingSize, NSSize(width: 80, height: 24))
            view.rootView = AnyView(Color.clear.frame(width: 140, height: 42))
            XCTAssertEqual(view.fittingSize, NSSize(width: 140, height: 42))
            view.frame = CGRect(x: 0, y: 0, width: 140, height: 42)
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(view.subviews.first?.frame, view.bounds)
        }
        var rowSelections = 0
        var barSelections = 0
        row.select = { rowSelections += 1 }
        bar.select = { barSelections += 1 }
        let down = try mouse(.leftMouseDown, x: 10)
        let up = try mouse(.leftMouseUp, x: 10)
        row.mouseDown(with: down)
        bar.mouseDown(with: down)
        XCTAssertEqual(rowSelections, 1)
        XCTAssertEqual(barSelections, 0)
        row.mouseUp(with: up)
        bar.mouseUp(with: up)
        XCTAssertEqual(rowSelections, 1)
        XCTAssertEqual(barSelections, 1)
        store.barEditing.end()
        XCTAssertNil(bar.dragSession)
    }

    @MainActor func testDropWithinAndBetweenPositionsMovesOnceAndCreatesOneUndoStep() throws {
        for position in [WidgetPosition.left, .right, .notchLeft] {
            let fixture = try ThemeGalleryFixture(#"{"groups":{"pair":{}},"widgets":[{"id":"a","type":"clock","position":"left","group":"pair"},{"id":"b","type":"clock","position":"left","group":"pair"},{"id":"c","type":"clock","position":"left"}]}"#)
            defer { fixture.close() }
            let store = try fixture.store()
            defer { store.stop() }
            let before = try Data(contentsOf: fixture.url)
            let setup = WidgetSetup(store: store)
            let session = WidgetDragSession()
            let payload = session.begin("b")
            session.insertion = position.rawValue + "/"
            var moves = 0
            let move: (String) -> Void = { id in
                moves += 1
                do { try setup.move(id, to: position) }
                catch { XCTFail("Drop failed: \(error)") }
            }
            XCTAssertTrue(session.drop(payload, move: move))
            XCTAssertFalse(session.drop(payload, move: move))
            session.end(payload)
            XCTAssertEqual(moves, 1)
            XCTAssertNil(session.active)
            XCTAssertNil(session.insertion)
            XCTAssertEqual(store.configuration?.widgets.map(\.id), ["c", "a", "b"])
            XCTAssertEqual(store.configuration?.widgets.filter { $0.group == "pair" }.map(\.position), [position, position])
            XCTAssertEqual(store.customizationHistory.undoSteps.count, 1)
            try store.customizationHistory.undo()
            XCTAssertEqual(try Data(contentsOf: fixture.url), before)
        }
    }

    @MainActor func testOnlyPayloadFromTheLiveDragInThisListIsAccepted() throws {
        let session = WidgetDragSession()
        let other = WidgetDragSession()
        let payload = session.begin("a")
        let data = try JSONEncoder().encode(payload)
        XCTAssertEqual(session.payload(from: data, source: session), payload)
        XCTAssertNil(session.payload(from: data, source: nil))
        XCTAssertNil(session.payload(from: data, source: other))
        XCTAssertNil(session.payload(from: Data("a".utf8), source: session))
        let forged = WidgetDragSession.Payload(widgetID: "b", token: payload.token)
        XCTAssertNil(session.payload(from: try JSONEncoder().encode(forged), source: session))
        let unrelated = other.begin("a")
        XCTAssertFalse(session.accepts(unrelated))
        XCTAssertFalse(session.drop(unrelated) { _ in XCTFail("An unrelated drag must not move a widget") })
        XCTAssertEqual(session.active, payload)
    }

    @MainActor func testCancellationAndCompletionOutsideTheListClearStateAndRejectLaterDrops() throws {
        let session = WidgetDragSession()
        let cancelled = session.begin("a")
        session.insertion = "right/"
        session.end(cancelled)
        XCTAssertNil(session.active)
        XCTAssertNil(session.insertion)
        XCTAssertNil(session.payload(from: try JSONEncoder().encode(cancelled), source: session))
        XCTAssertFalse(session.drop(cancelled) { _ in XCTFail("A cancelled drag must not move a widget") })

        let current = session.begin("a")
        session.insertion = "left/"
        session.end(cancelled)
        XCTAssertEqual(session.active, current)
        XCTAssertEqual(session.insertion, "left/")
        XCTAssertFalse(session.drop(cancelled) { _ in XCTFail("An old drag must not consume a new drag") })
        session.end(current)
        XCTAssertNil(session.active)
        XCTAssertNil(session.insertion)
    }

    @MainActor private func mouse(_ type: NSEvent.EventType, x: CGFloat) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: 10), modifierFlags: [], timestamp: 0,
                                        windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
}

@MainActor private final class CapturingWidgetDragSource: WidgetDragSourceView {
    var session: WidgetDragSession?
    var widgetID: String?
    var items: [NSDraggingItem] = []
    var completions = 0
    override var dragSession: WidgetDragSession? { session }
    override var dragWidgetID: String? { widgetID }
    override func beginWidgetDrag(with item: NSDraggingItem, event: NSEvent) { items.append(item) }
    override func didEndWidgetDrag() { completions += 1 }
}
