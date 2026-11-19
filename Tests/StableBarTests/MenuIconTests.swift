import AppKit
import Testing
@testable import StableBar

@Test @MainActor func statusMenuShowsAnIconBesideEveryAction() throws {
    let fixture = try ThemeGalleryFixture()
    defer { fixture.close() }
    let store = BarStore(configurationURL: fixture.url, themesDirectory: fixture.themes)
    defer { store.stop() }
    store.configurationStore.reloadConfiguration()
    let bar = BarPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    defer { bar.close() }
    let menu = NSMenu()
    let delegate = AppDelegate(store: store, panels: [1: bar])
    delegate.menuWillOpen(menu)
    let actions = menu.items.filter { $0.action != nil }
    #expect(actions.map(\.title) == ["Edit Bar in Place", "Try Themes…", "Get Widgets…", "Hide Bar", "Getting Started…",
                                     "Help…", "Share My Bar…", "Send Feedback…", "Settings…", "Quit StableBar"])
    #expect(actions.allSatisfy { $0.image?.isTemplate == true })

    let hide = try #require(actions.first { $0.title == "Hide Bar" })
    #expect(NSApplication.shared.sendAction(try #require(hide.action), to: hide.target, from: hide))
    delegate.menuWillOpen(menu)
    #expect(menu.items.filter { $0.action != nil }.map(\.title) == ["Show Bar", "Getting Started…", "Help…", "Send Feedback…",
                                                                    "Settings…", "Quit StableBar"])

    try fixture.write("{", to: fixture.url)
    store.configurationStore.reloadConfiguration()
    delegate.menuWillOpen(menu)
    let problem = try #require(menu.items.first { $0.action == #selector(AppDelegate.showStatus) })
    #expect(problem.image != nil)
    #expect(problem.image?.isTemplate == false)
}
