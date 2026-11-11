import AppKit
import Testing
@testable import StableBar

@Test @MainActor func statusMenuShowsAnIconBesideEveryAction() throws {
    let fixture = try ThemeGalleryFixture()
    defer { fixture.close() }
    let store = BarStore(configurationURL: fixture.url, themesDirectory: fixture.themes)
    defer { store.stop() }
    store.reloadConfiguration()
    let bar = BarPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    defer { bar.close() }
    let menu = NSMenu()
    let delegate = AppDelegate(store: store, panels: [1: bar])
    delegate.menuWillOpen(menu)
    let actions = menu.items.filter { $0.action != nil }
    #expect(actions.map(\.title) == ["Edit Bar in Place", "Try Themes…", "Getting Started…", "Help…", "Send Feedback…",
                                     "Settings…", "Quit StableBar"])
    #expect(actions.allSatisfy { $0.image?.isTemplate == true })

    try fixture.write("{", to: fixture.url)
    store.reloadConfiguration()
    delegate.menuWillOpen(menu)
    let problem = try #require(menu.items.first { $0.action == #selector(AppDelegate.showStatus) })
    #expect(problem.image != nil)
    #expect(problem.image?.isTemplate == false)
}
