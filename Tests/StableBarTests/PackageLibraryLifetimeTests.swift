import Foundation
import Testing
@testable import StableBar

/// The update check's task, or a view that holds the library, can keep a package library alive after its bar is
/// gone, as when a test ends while the check waits for its client.
@Test @MainActor func packageLibraryThatOutlivesItsStoreSkipsItsUpdateWork() async throws {
    let fixture = try ThemeGalleryFixture()
    defer { fixture.close() }
    var store: BarStore? = BarStore(configurationURL: fixture.url, themesDirectory: fixture.themes)
    weak var released = store
    let library = try #require(store).packageLibrary
    store = nil
    #expect(released == nil)
    await library.loadInstalled()
    #expect(library.error == nil)
}
