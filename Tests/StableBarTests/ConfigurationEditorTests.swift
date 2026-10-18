import XCTest
@testable import StableBar

final class ConfigurationEditorTests: XCTestCase {
    @MainActor func testProgrammaticSelectionCommitsPendingTextBeforeChangingItsWidget() async throws {
        let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"a","type":"clock","position":"right"},{"id":"b","type":"clock","position":"right"}]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        var editor: ConfigurationEditor!
        var pending: Double?
        var committedIDs: [String] = []
        editor = ConfigurationEditor(store: store, endEditing: {
            guard let value = pending, let id = editor.selectedID else { return }
            pending = nil
            committedIDs.append(id)
            editor.set(["style": .object(["fontSize": .number(value)])])
        })
        pending = 17
        editor.selectedID = "b"
        XCTAssertEqual(committedIDs, ["a"])
        XCTAssertEqual(editor.style(for: "a")["fontSize"], .number(17))
        XCTAssertNil(editor.properties(for: "b")["style"])
        pending = 19
        let added = await WidgetSetup(store: store).add(try XCTUnwrap(WidgetAddCatalog.builtIns.first { $0.id == "text" }), to: .left)
        editor.selectedID = try XCTUnwrap(added)
        XCTAssertEqual(committedIDs, ["a", "b"])
        XCTAssertEqual(editor.style(for: "b")["fontSize"], .number(19))
        XCTAssertNil(editor.selected["style"])
        pending = 21
        editor.showWidget("a")
        XCTAssertEqual(committedIDs, ["a", "b", added!])
        XCTAssertEqual(editor.section, .widgets)
        XCTAssertEqual(editor.selectedID, "a")
        XCTAssertEqual(editor.style(for: added!)["fontSize"], .number(21))
        XCTAssertEqual(editor.style(for: "a")["fontSize"], .number(17))
        editor.showWidget("missing")
        XCTAssertEqual(editor.selectedID, "a")
        XCTAssertNil(editor.error)
        try editor.history.flush()
    }

    @MainActor func testRemoveCommitsPendingTextBeforeRemovingTheWidgetAndKeepsUndoStepsInOrder() throws {
        let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"a","type":"clock","position":"right"},{"id":"b","type":"clock","position":"right"}]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        var editor: ConfigurationEditor!
        var pending = true
        var committedID: String?
        editor = ConfigurationEditor(store: store, endEditing: {
            guard pending else { return }
            pending = false
            committedID = editor.selectedID
            editor.set(["style": .object(["fontSize": .number(18)])])
        })
        editor.change(ConfigurationEdit(action: .remove, id: "a"))
        XCTAssertEqual(committedID, "a")
        XCTAssertEqual(editor.selectedID, "b")
        XCTAssertNil(editor.error)
        XCTAssertNil(editor.properties(for: "b")["style"])
        XCTAssertEqual(editor.history.undoSteps.count, 2)
        editor.undo()
        XCTAssertEqual(editor.style(for: "a")["fontSize"], .number(18))
        editor.undo()
        XCTAssertNil(editor.properties(for: "a")["style"])
    }

    @MainActor func testUndoRedoAndSelectionRepairEndEditingWhileTheOldWidgetIsStillSelected() async throws {
        let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"a","type":"clock","position":"right"}]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        var editor: ConfigurationEditor!
        var endedOn: [String?] = []
        editor = ConfigurationEditor(store: store, endEditing: { endedOn.append(editor.selectedID) })
        let added = await WidgetSetup(store: store).add(try XCTUnwrap(WidgetAddCatalog.builtIns.first { $0.id == "text" }), to: .left)
        editor.selectedID = try XCTUnwrap(added)
        endedOn = []
        editor.undo()
        XCTAssertEqual(endedOn.first!, added)
        XCTAssertEqual(editor.selectedID, "a")
        endedOn = []
        editor.redo()
        XCTAssertEqual(endedOn.first!, "a")
        editor.selectedID = added
        try WidgetSetup(store: store).remove(try XCTUnwrap(added))
        endedOn = []
        editor.keepSelection()
        XCTAssertEqual(endedOn, [added])
        XCTAssertEqual(editor.selectedID, "a")
    }

    @MainActor func testBarRemovalUsesTheSamePendingEditingBoundaryBeforeChangingTheConfiguration() throws {
        let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"a","type":"clock","position":"right"},{"id":"b","type":"clock","position":"right"}]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        var editor: ConfigurationEditor!
        var pending = false
        editor = ConfigurationEditor(store: store, endEditing: {
            guard pending else { return }
            pending = false
            editor.set(["style": .object(["fontSize": .number(22)])])
        })
        store.onEndCustomizationEditing = { editor.finishEditing() }
        store.barEditing.begin()
        pending = true
        store.barEditing.remove("a")
        editor.keepSelection()
        XCTAssertEqual(editor.selectedID, "b")
        XCTAssertNil(editor.error)
        XCTAssertNil(store.barEditing.error)
        XCTAssertNil(editor.properties(for: "b")["style"])
        editor.undo()
        XCTAssertEqual(editor.style(for: "a")["fontSize"], .number(22))
    }

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
