import XCTest
@testable import StableBar

final class WidgetDragSessionTests: XCTestCase {
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
}
