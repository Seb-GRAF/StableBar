import AppKit
import SwiftUI
import Testing
@testable import StableBar

@Test @MainActor func closingSettingsLetsItsViewsGoAndReopensWhereItWas() async throws {
    let fixture = try ThemeGalleryFixture(#"""
    {"widgets":[{"id":"clock","type":"clock","position":"right"},{"id":"note","type":"text","text":"Hi","position":"left"}]}
    """#)
    let store = BarStore(configurationURL: fixture.url, themesDirectory: fixture.themes)
    store.reloadConfiguration()
    defer { store.stop(); fixture.close() }
    var shown: [NSWindow] = []
    let settings = CustomizationWindow(present: { shown.append($0) })

    weak var content: NSView?
    try autoreleasepool {
        settings.show(store: store, section: .appearance)
        settings.editor?.selectedID = "note"
        let window = try #require(shown.first)
        content = try #require(window.contentView)
        window.close()
        shown.removeAll()
    }
    // A closed window's views would keep observing the store and drawing on every change.
    try await awaitCondition { content == nil }

    store.configuration = try JSONDecoder().decode(Configuration.self, from: Data(#"""
    {"widgets":[{"id":"clock","type":"clock","position":"right"}]}
    """#.utf8))
    settings.show(store: store)
    let reopened = try #require(shown.first)
    #expect(reopened.contentView != nil)
    // Settings remembers its frame only through this autosave name.
    #expect(reopened.frameAutosaveName == "StableBarSettings")
    #expect(settings.editor?.section == .appearance)
    #expect(settings.editor?.selectedID == "clock")
    reopened.close()
}

@Test @MainActor func settingsFollowsAWindowManagerTileNarrowerThanItsFullHeader() async throws {
    let fixture = try ThemeGalleryFixture()
    defer { fixture.close() }
    let store = try fixture.store()
    defer { store.stop() }
    let editor = ConfigurationEditor(store: store)
    editor.section = .profiles
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentView = NSHostingView(rootView: SettingsView(store: store, editor: editor))
    // AppKit widens the window back to SwiftUI's minimum width on its next layout pass.
    window.setFrame(NSRect(x: 0, y: 0, width: 300, height: 760), display: false)
    try await awaitCondition { window.frame.width > 300 }
    // One of three tiles side by side on a 1512-point screen.
    #expect(window.frame.width <= 490)
}
