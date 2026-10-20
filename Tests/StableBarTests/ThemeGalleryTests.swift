import XCTest
import os
@testable import StableBar

final class ThemeGalleryTests: XCTestCase {
    @MainActor func testThemeSelectionAndBuiltInAreSavedImmediatelyAndUndoableWithoutSavingCommandLineEdits() async throws {
        let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"clock","type":"clock","position":"right"}]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        try store.setSessionEdits([ConfigurationEdit(action: .bar, properties: ["margin": .number(12)])])
        let gallery = ThemeGallery(store: store)
        await gallery.refresh()
        XCTAssertEqual(gallery.selectedKey, "built-in")
        let blueprint = try XCTUnwrap(gallery.choices.first { $0.key == "blueprint" })
        gallery.select(blueprint)
        XCTAssertEqual(gallery.selectedKey, "blueprint")
        XCTAssertEqual(store.configuration?.defaults.fontName, "Menlo")
        XCTAssertEqual(try fixture.document()["theme"], .object(["id": .string("blueprint")]))
        XCTAssertNil(try fixture.document()["bar"])
        XCTAssertEqual(store.configuration?.bar.margin, 12)
        XCTAssertEqual(store.customizationHistory.undoSteps.count, 1)
        XCTAssertFalse(store.customizationHistory.hasPendingChanges)
        gallery.select(try XCTUnwrap(gallery.choices.first { $0.isBuiltIn }))
        XCTAssertEqual(gallery.selectedKey, "built-in")
        XCTAssertNil(try fixture.document()["theme"])
        XCTAssertEqual(store.customizationHistory.undoSteps.count, 2)
        try store.customizationHistory.undo()
        XCTAssertEqual(gallery.selectedKey, "blueprint")
        try store.customizationHistory.undo()
        XCTAssertEqual(gallery.selectedKey, "built-in")
        XCTAssertEqual(store.sessionEdits.count, 1)
    }

    @MainActor func testOlderThemesKeepTheirAppearanceAsCustomAndCanBeReplacedAndUndone() async throws {
        for id in ["graphite", "island", "menu-bar", "minimal", "paper", "slate", "terminal", "terminal/1.0.0"] {
            let fixture = try ThemeGalleryFixture(#"{"includes":["theme.json"],"defaults":{"fontSize":17},"widgets":[]}"#)
            defer { fixture.close() }
            let selection: String
            if id == "terminal/1.0.0" {
                _ = try fixture.packages.install(fixture.themes.appending(path: "terminal"))
                selection = #"{"id":"terminal","version":"1.0.0"}"#
            } else {
                selection = #"{"id":"\#(id)"}"#
            }
            let included = fixture.directory.appending(path: "theme.json")
            try fixture.write(#"{"theme":\#(selection)}"#, to: included)
            let original = try Data(contentsOf: fixture.url)
            let includedOriginal = try Data(contentsOf: included)
            let store = try fixture.store()
            defer { store.stop() }
            XCTAssertNil(store.configurationError)
            let configuration = store.effectiveDocument
            XCTAssertEqual(store.configuration?.defaults.fontSize, 17)
            let gallery = ThemeGallery(store: store)
            await gallery.refresh()
            let custom = try XCTUnwrap(gallery.choices.first { $0.key == id })
            XCTAssertEqual(custom.title, "Custom")
            XCTAssertEqual(gallery.choices.filter(\.isLegacy).map(\.key), [id])
            XCTAssertNotNil(gallery.previews[id])
            let trial = ThemeTrial(store: store)
            XCTAssertEqual(trial.choice?.title, "Custom")
            trial.next()
            trial.cancel()
            XCTAssertEqual(store.effectiveDocument, configuration)
            XCTAssertEqual(try Data(contentsOf: fixture.url), original)
            gallery.select(try XCTUnwrap(gallery.choices.first { $0.key == "blueprint" }))
            await gallery.refresh()
            XCTAssertFalse(gallery.choices.contains(where: \.isLegacy))
            try store.customizationHistory.undo()
            await gallery.refresh()
            XCTAssertEqual(gallery.selectedKey, id)
            XCTAssertEqual(gallery.choices.first { $0.key == id }?.title, "Custom")
            XCTAssertEqual(store.effectiveDocument, configuration)
            XCTAssertEqual(try Data(contentsOf: included), includedOriginal)
        }
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
        await gallery.refresh()
        await gallery.loadStore()
        XCTAssertFalse(gallery.storeUnavailable)
        XCTAssertEqual(gallery.storeThemes.map(\.id), [entry.id])
        XCTAssertEqual(gallery.previews[entry.versionKey]?.light.bar.height, 31)
        XCTAssertEqual(gallery.previews[entry.versionKey]?.light.defaults.fontSize, 19)
        XCTAssertEqual(gallery.previews[entry.versionKey]?.light.widgets.map(\.id), [])
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
        await gallery.refresh()
        XCTAssertTrue(gallery.storeThemes.isEmpty)
    }

    @MainActor func testOfflineStoreLeavesLocalGalleryAndSelectionWorking() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let gallery = ThemeGallery(store: store, client: PackageStoreClient(packages: fixture.packages,
            indexURL: fixture.directory.appending(path: "missing-index.json")))
        await gallery.refresh()
        await gallery.loadStore()
        XCTAssertTrue(gallery.storeUnavailable)
        XCTAssertTrue(gallery.storeThemes.isEmpty)
        XCTAssertEqual(gallery.choices.count, 6)
        XCTAssertEqual(gallery.previews.count, 6)
        gallery.select(try XCTUnwrap(gallery.choices.first { $0.key == "rose-pine" }))
        XCTAssertEqual(gallery.selectedKey, "rose-pine")
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
        await gallery.refresh()
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

    @MainActor func testThemeColorsAppearInNoticeAndResetReturnsToTheTheme() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let gallery = ThemeGallery(store: store)
        await gallery.refresh()
        XCTAssertTrue(gallery.overrides.values.isEmpty)
        try store.customizationHistory.change(ConfigurationEdit(action: .tokens, properties: ["text": .string("#123456")]))
        await gallery.refresh()
        XCTAssertEqual(gallery.overrides.values.map(\.path), [["tokens", "text"]])
        try store.customizationHistory.change(gallery.overrides.resetEdit)
        await gallery.refresh()
        XCTAssertTrue(gallery.overrides.values.isEmpty)
        XCTAssertEqual(store.configuration?.defaults.foreground, HexColor(light: 0x1d1d1fff, dark: 0xf5f5f7ff))
        XCTAssertNil(try fixture.document()["tokens"])
        XCTAssertEqual(store.customizationHistory.undoSteps.count, 2)
    }
    @MainActor func testBuiltInSelectionOverridesAnIncludedThemeWithoutEditingTheInclude() async throws {
        let fixture = try ThemeGalleryFixture(#"{"includes":["included.json"],"widgets":[]}"#)
        defer { fixture.close() }
        let includedURL = fixture.directory.appending(path: "included.json")
        try fixture.write(#"{"theme":{"id":"blueprint"}}"#, to: includedURL)
        let included = try Data(contentsOf: includedURL)
        let store = try fixture.store()
        defer { store.stop() }
        let gallery = ThemeGallery(store: store)
        await gallery.refresh()
        gallery.select(try XCTUnwrap(gallery.choices.first { $0.isBuiltIn }))
        XCTAssertEqual(gallery.selectedKey, "built-in")
        XCTAssertNil(store.configuration?.defaults.fontName)
        XCTAssertEqual(try Data(contentsOf: includedURL), included)
        XCTAssertEqual(store.customizationHistory.undoSteps.count, 1)
        try store.customizationHistory.undo()
        XCTAssertEqual(gallery.selectedKey, "blueprint")
    }

    @MainActor func testInheritedThemeColorsStillCountWhenTheSelectedThemeDoesNotRedefineThem() async throws {
        let fixture = try ThemeGalleryFixture(#"{"theme":{"id":"test-theme","version":"1"},"widgets":[]}"#)
        defer { fixture.close() }
        _ = try fixture.theme(#"{}"#)
        let store = try fixture.store()
        defer { store.stop() }
        let gallery = ThemeGallery(store: store)
        try store.customizationHistory.change(ConfigurationEdit(action: .tokens, properties: ["text": .string("#123456")]))
        await gallery.refresh()
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
        await gallery.refresh()
        let before = try Data(contentsOf: fixture.url)
        await gallery.get(entry)
        XCTAssertNotNil(gallery.errors[entry.versionKey])
        XCTAssertNil(store.customizationHistory.error)
        XCTAssertNil(store.configurationError)
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
        XCTAssertEqual(gallery.selectedKey, "test-theme/1")
        XCTAssertTrue(gallery.choices.contains { $0.key == entry.versionKey })
        let actionError = gallery.errors[entry.versionKey]
        try fixture.write(#"{"theme":{"id":"test-theme","version":"1"},"widgets":[]}"#, to: fixture.url)
        store.reloadConfiguration()
        gallery.configurationChanged()
        await gallery.refreshTask?.value
        XCTAssertNotNil(gallery.previews[entry.versionKey])
        XCTAssertNil(gallery.previewErrors[entry.versionKey])
        XCTAssertEqual(gallery.errors[entry.versionKey], actionError)
    }

    @MainActor func testGalleryBuildsThemeOnlyLooksOffMainThreadAndNeverStartsScriptsOrProviders() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let marker = fixture.directory.appending(path: "must-not-exist")
        try fixture.write("""
        {"defaults":{"fontSize":99},"widgets":[
         {"id":"script","type":"script","command":"touch '\(marker.path)'","position":"left"},
         {"id":"battery","type":"battery","position":"right"}]}
        """, to: fixture.url)
        let store = try fixture.store()
        defer { store.stop() }
        let calls = OSAllocatedUnfairLock(initialState: [(String, Bool)]())
        let gallery = ThemeGallery(store: store, loadPreview: { choice, themes in
            calls.withLock { $0.append((choice.key, Thread.isMainThread)) }
            return try ThemePreview(choice: choice, themesDirectory: themes)
        })
        await gallery.refresh()
        XCTAssertEqual(calls.withLock { $0.map(\.0).sorted() }, gallery.choices.map(\.key).sorted())
        XCTAssertFalse(calls.withLock { $0.contains { $0.1 } })
        XCTAssertEqual(gallery.previews.count, gallery.choices.count)
        for preview in gallery.previews.values {
            XCTAssertNotEqual(preview.light.defaults.fontSize, 99)
            XCTAssertTrue(preview.light.widgets.isEmpty)
            XCTAssertTrue(preview.dark.providers.isEmpty)
        }
        XCTAssertTrue(store.scripts.isEmpty)
        XCTAssertTrue(store.providers.isEmpty)
        XCTAssertFalse(store.workspaceStore.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    @MainActor func testChangesRefreshOverridesImmediatelyWithoutRebuildingCachedLooks() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let calls = OSAllocatedUnfairLock(initialState: [String]())
        let gallery = ThemeGallery(store: store, refreshDelay: .milliseconds(20), loadPreview: { choice, themes in
            calls.withLock { $0.append(choice.key) }
            return try ThemePreview(choice: choice, themesDirectory: themes)
        })
        await gallery.refresh()
        for color in ["#111111", "#222222", "#333333"] {
            try store.customizationHistory.change(ConfigurationEdit(action: .tokens, properties: ["text": .string(color)]))
            gallery.configurationChanged()
            XCTAssertEqual(gallery.overrides.values.map(\.path), [["tokens", "text"]])
        }
        await gallery.refreshTask?.value
        await gallery.refresh()
        XCTAssertEqual(calls.withLock { $0.count }, gallery.choices.count)
        XCTAssertEqual(gallery.previews["built-in"]?.light.defaults.foreground, HexColor(light: 0x1d1d1fff, dark: 0xf5f5f7ff))
        XCTAssertTrue(store.customizationHistory.hasPendingChanges)
        try store.customizationHistory.flush()
        XCTAssertEqual(store.customizationHistory.undoSteps.count, 1)
    }

    @MainActor func testAppearanceFollowsTheBarChoiceThenTheSystemWithoutRebuildingLooks() async throws {
        for appearance in ["light", "dark", "automatic"] {
            let fixture = try ThemeGalleryFixture(appearance == "automatic" ? #"{"widgets":[]}"# : #"{"bar":{"appearance":"\#(appearance)"},"widgets":[]}"#)
            defer { fixture.close() }
            let store = try fixture.store()
            defer { store.stop() }
            let calls = OSAllocatedUnfairLock(initialState: 0)
            let gallery = ThemeGallery(store: store, loadPreview: { choice, themes in
                calls.withLock { $0 += 1 }
                return try ThemePreview(choice: choice, themesDirectory: themes)
            })
            await gallery.refresh()
            for system in ["light", "dark"] {
                store.context.appearance = system
                store.context.app = "another app"
                gallery.contextChanged()
                XCTAssertEqual(gallery.previewAppearance.rawValue, appearance == "automatic" ? system : appearance)
                XCTAssertNil(gallery.refreshTask)
                XCTAssertEqual(calls.withLock { $0 }, gallery.choices.count)
            }
        }
    }

    @MainActor func testStoreDownloadBuildsOnlyItsVersionAndKeepsLocalLooksCached() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let index = LocalPackageIndex(fixture: fixture)
        let entry = try await index.add()
        let store = try fixture.store()
        defer { store.stop() }
        let calls = OSAllocatedUnfairLock(initialState: [String]())
        let gallery = ThemeGallery(store: store,
            client: PackageStoreClient(packages: fixture.packages, indexURL: index.url), loadPreview: { choice, themes in
                calls.withLock { $0.append(choice.key) }
                return try ThemePreview(choice: choice, themesDirectory: themes)
            })
        await gallery.refresh()
        let initialCount = calls.withLock { $0.count }
        await gallery.loadStore()
        XCTAssertEqual(calls.withLock { Array($0.dropFirst(initialCount)) }, [entry.versionKey])
        XCTAssertNotNil(gallery.previews[entry.versionKey])
        await gallery.loadStore()
        await gallery.refresh()
        XCTAssertEqual(calls.withLock { $0.count }, initialCount + 1)
    }

    @MainActor func testInstalledVersionsHaveSeparateCachedSampleLooks() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let first = try fixture.theme(#"{"defaults":{"fontSize":14}}"#)
        let source = fixture.directory.appending(path: "sources/test-theme")
        try fixture.write(#"{"id":"test-theme","name":"Test theme","version":"2","kind":"theme","entry":"config.json"}"#,
                          to: source.appending(path: "package.json"))
        try fixture.write(#"{"defaults":{"fontSize":23}}"#, to: source.appending(path: "config.json"))
        _ = try fixture.packages.install(source)
        let store = try fixture.store()
        defer { store.stop() }
        let calls = OSAllocatedUnfairLock(initialState: [String]())
        let gallery = ThemeGallery(store: store, loadPreview: { choice, themes in
            calls.withLock { $0.append(choice.key) }
            return try ThemePreview(choice: choice, themesDirectory: themes)
        })
        await gallery.refresh()
        await gallery.refresh()
        XCTAssertEqual(gallery.previews[first.key]?.light.defaults.fontSize, 14)
        XCTAssertEqual(gallery.previews["test-theme/2"]?.light.defaults.fontSize, 23)
        XCTAssertEqual(calls.withLock { $0.filter { $0 == first.key }.count }, 1)
        XCTAssertEqual(calls.withLock { $0.filter { $0 == "test-theme/2" }.count }, 1)
    }

    @MainActor func testAnOlderBackgroundRefreshCannotReplaceNewerLooks() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let started = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let pause = OSAllocatedUnfairLock(initialState: true)
        let gallery = ThemeGallery(store: store, refreshDelay: .zero, loadPreview: { choice, themes in
            let shouldPause = pause.withLock { value in let previous = value; value = false; return previous }
            let preview = try ThemePreview(choice: choice, themesDirectory: themes)
            if shouldPause { started.continuation.yield(()); release.wait(); throw CommandFailure(message: "Old failure") }
            return preview
        })
        let firstRefresh = Task { await gallery.refresh() }
        for await _ in started.stream { break }
        await gallery.refresh()
        release.signal()
        await firstRefresh.value
        XCTAssertEqual(gallery.previews.count, gallery.choices.count)
        XCTAssertTrue(gallery.previewErrors.isEmpty)
    }

    @MainActor func testBrokenUserConfigurationDoesNotPreventThemeSamples() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        try fixture.write("{", to: fixture.url)
        store.reloadConfiguration()
        XCTAssertNotNil(store.configurationError)
        let gallery = ThemeGallery(store: store)
        await gallery.refresh()
        XCTAssertEqual(gallery.previews.count, gallery.choices.count)
        XCTAssertFalse(gallery.previews.isEmpty)
        XCTAssertNotNil(gallery.error(for: gallery.selectedKey))
        try fixture.write(#"{"widgets":[]}"#, to: fixture.url)
        store.reloadConfiguration()
        gallery.contextChanged()
        XCTAssertNil(gallery.error(for: gallery.selectedKey))
        XCTAssertTrue(gallery.previewErrors.isEmpty)
    }

    @MainActor func testSuccessfulPreviewClearsOnlyItsPreviewErrorAndKeepsGetErrors() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let fails = OSAllocatedUnfairLock(initialState: true)
        let gallery = ThemeGallery(store: store, loadPreview: { choice, themes in
            if fails.withLock({ $0 }) { throw CommandFailure(message: "Brief preview failure") }
            return try ThemePreview(choice: choice, themesDirectory: themes)
        })
        await gallery.refresh()
        XCTAssertEqual(gallery.previewErrors.count, gallery.choices.count)
        fails.withLock { $0 = false }
        await gallery.refresh()
        XCTAssertTrue(gallery.previewErrors.isEmpty)
        XCTAssertEqual(gallery.previews.count, gallery.choices.count)
        let index = LocalPackageIndex(fixture: fixture)
        let entry = try await index.add(checksum: String(repeating: "0", count: 64))
        let actions = ThemeGallery(store: store, client: PackageStoreClient(packages: fixture.packages, indexURL: index.url))
        await actions.get(entry)
        let error = try XCTUnwrap(actions.errors[entry.versionKey])
        await actions.refreshTask?.value
        await actions.refresh()
        XCTAssertEqual(actions.errors[entry.versionKey], error)
    }
}
