import Foundation
import Testing
@testable import StableBar

/// While setup is open, its choices are unsaved session edits: edit mode would save them at once, and it can't edit
/// the widgets a preset adds. So Edit Bar in Place isn't offered then, and opening setup ends edit mode.
@Test @MainActor func editBarInPlaceIsUnavailableWhileSetupIsOpen() throws {
    let store = BarStore(configurationURL: FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json"))
    defer { store.stop() }
    store.configuration = try JSONDecoder().decode(Configuration.self, from: Data(#"""
        {"widgets":[{"id":"note","type":"text","text":"Hi","position":"right"}]}
        """#.utf8))
    let editing = store.barEditing
    #expect(editing.isAvailable)
    editing.begin()
    #expect(editing.isActive)

    editing.setupIsOpen = true
    #expect(!editing.isActive)
    #expect(!editing.isAvailable)
    editing.toggle()
    #expect(!editing.isActive)

    editing.setupIsOpen = false
    #expect(editing.isAvailable)
    editing.toggle()
    #expect(editing.isActive)
    editing.end()
}
