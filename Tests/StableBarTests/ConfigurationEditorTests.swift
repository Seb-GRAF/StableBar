import XCTest
@testable import StableBar

final class ConfigurationEditorTests: XCTestCase {
    @MainActor func testPendingNumberBindingsCommitToTheirOriginalWidgetAfterSelectionChanges() throws {
        for key in ["fontSize", "paddingHorizontal", "paddingVertical", "cornerRadius", "borderWidth"] {
            let fixture = try ThemeGalleryFixture(#"{"defaults":{"\#(key)":12},"widgets":[{"id":"a","type":"clock","position":"right"},{"id":"b","type":"clock","position":"right","style":{"\#(key)":20}}]}"#)
            defer { fixture.close() }
            let store = try fixture.store()
            defer { store.stop() }
            let before = try Data(contentsOf: fixture.url)
            let editor = ConfigurationEditor(store: store)
            let id = try XCTUnwrap(editor.selectedID)
            let other = editor.properties(for: "b")
            let fields = StyleFields(store: store, path: "widgets.\(id).style", widgetID: id,
                                     values: editor.style(for: id),
                                     set: { editor.set(["style": .object($0)], for: id) }, unset: { _ in })
            let binding = fields.numberBinding(key, default: 0)
            XCTAssertEqual(binding.wrappedValue, 12)
            editor.selectedID = "b"
            binding.wrappedValue = 20
            XCTAssertNil(editor.error)
            XCTAssertEqual(editor.selectedID, "b")
            XCTAssertEqual(editor.style(for: "a")[key], .number(20), key)
            XCTAssertEqual(editor.properties(for: "b"), other, key)
            try editor.history.flush()
            XCTAssertEqual(editor.undoSteps.count, 1)
            editor.undo()
            XCTAssertEqual(try Data(contentsOf: fixture.url), before)
            XCTAssertEqual(editor.selectedID, "b")
        }
    }

    @MainActor func testTargetedUnchangedStyleUsesTheOriginalWidgetsInheritedValue() throws {
        let fixture = try ThemeGalleryFixture(#"{"defaults":{"fontSize":12},"widgets":[{"id":"a","type":"clock","position":"right"},{"id":"b","type":"clock","position":"right","style":{"fontSize":20}}]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let before = try Data(contentsOf: fixture.url)
        let editor = ConfigurationEditor(store: store)
        editor.selectedID = "b"
        editor.set(["style": .object(["fontSize": .number(12)])], for: "a")
        XCTAssertNil(editor.error)
        XCTAssertTrue(store.customizationEdits.isEmpty)
        XCTAssertTrue(editor.undoSteps.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
    }
}
