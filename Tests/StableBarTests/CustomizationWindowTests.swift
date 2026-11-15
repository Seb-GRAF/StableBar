import AppKit
import Testing
@testable import StableBar

@Test @MainActor func closingSettingsLetsItsViewsGoAndReopensWhereItWas() async throws {
    let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"clock","type":"clock","position":"right"}]}"#)
    let store = BarStore(configurationURL: fixture.url, themesDirectory: fixture.themes)
    store.reloadConfiguration()
    defer { store.stop(); fixture.close() }
    var shown: [NSWindow] = []
    let settings = CustomizationWindow(present: { shown.append($0) })

    weak var content: NSView?
    autoreleasepool {
        settings.show(store: store, section: .appearance)
        content = shown.last?.contentView
        shown.last?.close()
        shown.removeAll()
    }
    // A closed window's views would keep observing the store and drawing on every change.
    try await awaitCondition { content == nil }

    settings.show(store: store)
    let reopened = try #require(shown.last)
    #expect(reopened.contentView != nil)
    // The old window gave up its autosave name, so the new one still remembers where Settings was.
    #expect(reopened.frameAutosaveName == "StableBarSettings")
    #expect(settings.editor?.section == .appearance)
    reopened.close()
}
