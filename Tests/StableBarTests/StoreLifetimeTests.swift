import Foundation
import Testing
@testable import StableBar

/// A view or a queued task can keep edit mode and the Undo history alive after their bar is gone. They then have
/// nothing left to change, and reading the bar must not crash.
@Test @MainActor func editModeAndUndoHistoryThatOutliveTheirStoreDoNothing() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json")
    var store: BarStore? = BarStore(configurationURL: url)
    weak var released = store
    let editing = try #require(store).barEditing
    let history = try #require(store).customizationHistory
    store = nil
    #expect(released == nil)

    editing.begin()
    #expect(!editing.isActive)
    #expect(!editing.isAvailable)
    #expect(!editing.canUndo)
    #expect(editing.widgets(on: BarDisplay(id: 1, isBuiltIn: true, isMain: true, notch: nil)).isEmpty)

    #expect(!history.hasPendingChanges)
    #expect(try history.pendingEdits().isEmpty)
    #expect(!history.checkForExternalChanges())
    try history.change(ConfigurationEdit(action: .set, id: "clock", properties: ["text": .string("Hi")]))
    try history.flush()
    try history.undo()
    try history.redo()
    #expect(history.error == nil)
}
