import SwiftUI
import XCTest
@testable import StableBar

final class ThemeCardTests: XCTestCase {
    @MainActor func testPreviewAndItsBackgroundUseTheForcedBarAppearance() async throws {
        for appearance in ["light", "dark"] {
            let fixture = try ThemeGalleryFixture(#"{"bar":{"appearance":"\#(appearance)"},"widgets":[]}"#)
            defer { fixture.close() }
            let store = try fixture.store()
            defer { store.stop() }
            store.context.appearance = appearance == "light" ? "dark" : "light"
            let gallery = ThemeGallery(store: store)
            await gallery.refresh()
            let snapshot = try XCTUnwrap(gallery.previews["minimal"])
            let card = ThemeCard(title: "Minimal", snapshot: snapshot, select: {})
            XCTAssertEqual(card.previewColorScheme, appearance == "dark" ? .dark : .light)
        }
    }
}
