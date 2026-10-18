import XCTest
@testable import StableBar

final class ThemeGalleryTests: XCTestCase {
    @MainActor func testThemeSelectionAndBuiltInAreSavedImmediatelyAndUndoableWithoutSavingCommandLineEdits() throws {
        let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"clock","type":"clock","position":"right"}]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        try store.setSessionEdits([ConfigurationEdit(action: .bar, properties: ["margin": .number(12)])])
        let gallery = ThemeGallery(store: store)
        gallery.refresh()
        XCTAssertEqual(gallery.selectedKey, "built-in")
        let terminal = try XCTUnwrap(gallery.choices.first { $0.key == "terminal" })
        gallery.select(terminal)
        XCTAssertEqual(gallery.selectedKey, "terminal")
        XCTAssertEqual(store.configuration?.defaults.fontName, "Menlo")
        XCTAssertEqual(try fixture.document()["theme"], .object(["id": .string("terminal")]))
        XCTAssertNil(try fixture.document()["bar"])
        XCTAssertEqual(store.configuration?.bar.margin, 12)
        XCTAssertEqual(store.customizationHistory.undoSteps.count, 1)
        XCTAssertFalse(store.customizationHistory.hasPendingChanges)
        gallery.select(try XCTUnwrap(gallery.choices.first { $0.isBuiltIn }))
        XCTAssertEqual(gallery.selectedKey, "built-in")
        XCTAssertNil(try fixture.document()["theme"])
        XCTAssertEqual(store.customizationHistory.undoSteps.count, 2)
        try store.customizationHistory.undo()
        XCTAssertEqual(gallery.selectedKey, "terminal")
        try store.customizationHistory.undo()
        XCTAssertEqual(gallery.selectedKey, "built-in")
        XCTAssertEqual(store.sessionEdits.count, 1)
    }

    @MainActor func testStorePreviewsUseDownloadedThemesAndGetInstallsSelectsAndSavesOneChange() async throws {
        let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"clock","type":"clock","position":"right"}]}"#)
        defer { fixture.close() }
        let index = LocalPackageIndex(fixture: fixture)
        let entry = try await index.add(configuration: #"{"bar":{"height":31},"defaults":{"fontSize":19}}"#)
        let store = try fixture.store()
        defer { store.stop() }
        let before = try Data(contentsOf: fixture.url)
        let gallery = ThemeGallery(store: store, client: PackageStoreClient(packages: fixture.packages, indexURL: index.url))
        gallery.refresh()
        await gallery.loadStore()
        XCTAssertFalse(gallery.storeUnavailable)
        XCTAssertEqual(gallery.storeThemes.map(\.id), [entry.id])
        XCTAssertEqual(gallery.previews[entry.versionKey]?.bar.height, 31)
        XCTAssertEqual(gallery.previews[entry.versionKey]?.defaults.fontSize, 19)
        XCTAssertEqual(gallery.previews[entry.versionKey]?.widgets.map(\.id), ["clock"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.packages.directory.path))
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
        // A ready preview is cached: Get works even if its archive is no longer available.
        try FileManager.default.removeItem(at: index.url.deletingLastPathComponent())
        await gallery.get(entry)
        XCTAssertNil(gallery.errors[entry.versionKey])
        XCTAssertNil(gallery.progress[entry.versionKey])
        XCTAssertTrue(gallery.storeThemes.isEmpty)
        XCTAssertEqual(gallery.selectedKey, entry.versionKey)
        XCTAssertEqual(store.configuration?.bar.height, 31)
        XCTAssertEqual(store.customizationHistory.undoSteps.count, 1)
        XCTAssertEqual(try fixture.document()["theme"], .object(["id": .string(entry.id), "version": .string("1")]))
        try store.customizationHistory.undo()
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.packages.directory.appending(path: "store-theme/1").path))
        gallery.refresh()
        XCTAssertTrue(gallery.storeThemes.isEmpty)
    }

    @MainActor func testOfflineStoreLeavesLocalGalleryAndSelectionWorking() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let gallery = ThemeGallery(store: store, client: PackageStoreClient(packages: fixture.packages,
            indexURL: fixture.directory.appending(path: "missing-index.json")))
        gallery.refresh()
        await gallery.loadStore()
        XCTAssertTrue(gallery.storeUnavailable)
        XCTAssertTrue(gallery.storeThemes.isEmpty)
        XCTAssertEqual(gallery.choices.count, 8)
        XCTAssertEqual(gallery.previews.count, 8)
        gallery.select(try XCTUnwrap(gallery.choices.first { $0.key == "slate" }))
        XCTAssertEqual(gallery.selectedKey, "slate")
        XCTAssertNil(store.customizationHistory.error)
    }

    @MainActor func testDownloadAndGetErrorsStayOnTheirCardAndLeaveTheCurrentThemeAlone() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let index = LocalPackageIndex(fixture: fixture)
        let entry = try await index.add(checksum: String(repeating: "0", count: 64))
        let store = try fixture.store()
        defer { store.stop() }
        let before = try Data(contentsOf: fixture.url)
        let gallery = ThemeGallery(store: store, client: PackageStoreClient(packages: fixture.packages, indexURL: index.url))
        gallery.refresh()
        await gallery.loadStore()
        XCTAssertEqual(gallery.storeThemes.count, 1)
        XCTAssertNotNil(gallery.errors[entry.versionKey])
        XCTAssertNil(gallery.previews[entry.versionKey])
        await gallery.get(entry)
        XCTAssertTrue(gallery.errors[entry.versionKey]?.contains("checksum") == true)
        XCTAssertNil(gallery.progress[entry.versionKey])
        XCTAssertNil(store.customizationHistory.error)
        XCTAssertNil(store.configurationError)
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
        XCTAssertTrue(store.customizationHistory.undoSteps.isEmpty)
    }

    @MainActor func testThemeColorsAppearInNoticeAndResetReturnsToTheTheme() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let gallery = ThemeGallery(store: store)
        gallery.refresh()
        XCTAssertTrue(gallery.overrides.values.isEmpty)
        try store.customizationHistory.change(ConfigurationEdit(action: .tokens, properties: ["text": .string("#123456")]))
        gallery.refresh()
        XCTAssertEqual(gallery.overrides.values.map(\.path), [["tokens", "text"]])
        try store.customizationHistory.change(gallery.overrides.resetEdit)
        gallery.refresh()
        XCTAssertTrue(gallery.overrides.values.isEmpty)
        XCTAssertEqual(store.configuration?.defaults.foreground, HexColor(light: 0x1d1d1fff, dark: 0xf5f5f7ff))
        XCTAssertNil(try fixture.document()["tokens"])
        XCTAssertEqual(store.customizationHistory.undoSteps.count, 2)
    }
    @MainActor func testBuiltInSelectionOverridesAnIncludedThemeWithoutEditingTheInclude() throws {
        let fixture = try ThemeGalleryFixture(#"{"includes":["included.json"],"widgets":[]}"#)
        defer { fixture.close() }
        let includedURL = fixture.directory.appending(path: "included.json")
        try fixture.write(#"{"theme":{"id":"terminal"}}"#, to: includedURL)
        let included = try Data(contentsOf: includedURL)
        let store = try fixture.store()
        defer { store.stop() }
        let gallery = ThemeGallery(store: store)
        gallery.refresh()
        gallery.select(try XCTUnwrap(gallery.choices.first { $0.isBuiltIn }))
        XCTAssertEqual(gallery.selectedKey, "built-in")
        XCTAssertNil(store.configuration?.defaults.fontName)
        XCTAssertEqual(try Data(contentsOf: includedURL), included)
        XCTAssertEqual(store.customizationHistory.undoSteps.count, 1)
        try store.customizationHistory.undo()
        XCTAssertEqual(gallery.selectedKey, "terminal")
    }

    @MainActor func testInheritedThemeColorsStillCountWhenTheSelectedThemeDoesNotRedefineThem() throws {
        let fixture = try ThemeGalleryFixture(#"{"theme":{"id":"menu-bar"},"widgets":[]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let gallery = ThemeGallery(store: store)
        try store.customizationHistory.change(ConfigurationEdit(action: .tokens, properties: ["text": .string("#123456")]))
        gallery.refresh()
        XCTAssertEqual(gallery.overrides.values.map(\.path), [["tokens", "text"]])
        try store.customizationHistory.change(gallery.overrides.resetEdit)
        XCTAssertEqual(store.configuration?.defaults.foreground, HexColor(light: 0x1d1d1fff, dark: 0xf5f5f7ff))
    }

    @MainActor func testGetSelectionFailureStaysOnTheInstalledCardWithoutABannerError() async throws {
        let fixture = try ThemeGalleryFixture(#"{"profile":"special","widgets":[]}"#)
        defer { fixture.close() }
        _ = try fixture.theme(#"{"profiles":[{"name":"special","configuration":{}}]}"#)
        try fixture.write(#"{"theme":{"id":"test-theme","version":"1"},"profile":"special","widgets":[]}"#, to: fixture.url)
        let store = try fixture.store()
        defer { store.stop() }
        let index = LocalPackageIndex(fixture: fixture)
        let entry = try await index.add()
        let gallery = ThemeGallery(store: store, client: PackageStoreClient(packages: fixture.packages, indexURL: index.url))
        gallery.refresh()
        let before = try Data(contentsOf: fixture.url)
        await gallery.get(entry)
        XCTAssertNotNil(gallery.errors[entry.versionKey])
        XCTAssertNil(store.customizationHistory.error)
        XCTAssertNil(store.configurationError)
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
        XCTAssertEqual(gallery.selectedKey, "test-theme/1")
        XCTAssertTrue(gallery.choices.contains { $0.key == entry.versionKey })
    }

}
