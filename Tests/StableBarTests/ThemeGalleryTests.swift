import XCTest
import os
import Observation
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
        await gallery.refresh()
        await gallery.loadStore()
        XCTAssertFalse(gallery.storeUnavailable)
        XCTAssertEqual(gallery.storeThemes.map(\.id), [entry.id])
        XCTAssertEqual(gallery.previews[entry.versionKey]?.store.configuration?.bar.height, 31)
        XCTAssertEqual(gallery.previews[entry.versionKey]?.store.configuration?.defaults.fontSize, 19)
        XCTAssertEqual(gallery.previews[entry.versionKey]?.store.configuration?.widgets.map(\.id), ["clock"])
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
        try fixture.write(#"{"theme":{"id":"terminal"}}"#, to: includedURL)
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
        XCTAssertEqual(gallery.selectedKey, "terminal")
    }

    @MainActor func testInheritedThemeColorsStillCountWhenTheSelectedThemeDoesNotRedefineThem() async throws {
        let fixture = try ThemeGalleryFixture(#"{"theme":{"id":"menu-bar"},"widgets":[]}"#)
        defer { fixture.close() }
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

    @MainActor func testRefreshBuildsOneStaticSnapshotPerThemeOffTheMainThread() async throws {
        let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"script","type":"script","command":"must-not-run","position":"left"}]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        store.scripts["script"] = ScriptWidget()
        store.scripts["script"]?.output = ScriptOutput(text: "First")
        store.preparePresentations()
        let calls = OSAllocatedUnfairLock(initialState: [(String, Bool)]())
        let gallery = ThemeGallery(store: store, compose: { request in
            calls.withLock { $0.append((request.choice.key, Thread.isMainThread)) }
            return try request.compose()
        })
        await gallery.refresh()
        XCTAssertEqual(calls.withLock { $0.map(\.0).sorted() }, gallery.choices.map(\.key).sorted())
        XCTAssertFalse(calls.withLock { $0.contains { $0.1 } })
        let first = try XCTUnwrap(gallery.previews["built-in"])
        let invalidated = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = gallery.previews["built-in"]?.store.scripts["script"]?.output
        } onChange: { invalidated.withLock { $0 = true } }
        store.scripts["script"]?.output.text = "Second"
        store.workspaceStore.workspaces = [Workspace(name: "New", isFocused: true, isVisible: true, monitor: 1)]
        XCTAssertFalse(invalidated.withLock { $0 })
        XCTAssertTrue(gallery.previews["built-in"]?.store === first.store)
        XCTAssertEqual(first.store.scripts["script"]?.output.text, "First")
        XCTAssertEqual(calls.withLock { $0.count }, gallery.choices.count)
        await gallery.refresh()
        XCTAssertEqual(calls.withLock { $0.count }, gallery.choices.count * 2)
        XCTAssertFalse(gallery.previews["built-in"]?.store === first.store)
        XCTAssertEqual(gallery.previews["built-in"]?.store.scripts["script"]?.output.text, "Second")
        XCTAssertEqual(gallery.previews["built-in"]?.store.workspaceStore.workspaces.first?.name, "New")
    }

    @MainActor func testChangesRefreshOverridesImmediatelyAndComposeOnceAfterABurst() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let calls = OSAllocatedUnfairLock(initialState: [String]())
        let gallery = ThemeGallery(store: store, refreshDelay: .milliseconds(20), compose: { request in
            calls.withLock { $0.append(request.choice.key) }
            return try request.compose()
        })
        await gallery.refresh()
        let first = try XCTUnwrap(gallery.previews["built-in"])
        for color in ["#111111", "#222222", "#333333"] {
            try store.customizationHistory.change(ConfigurationEdit(action: .tokens, properties: ["text": .string(color)]))
            gallery.configurationChanged()
            XCTAssertEqual(gallery.overrides.values.map(\.path), [["tokens", "text"]])
            XCTAssertTrue(gallery.previews["built-in"]?.store === first.store)
        }
        XCTAssertEqual(calls.withLock { $0.count }, gallery.choices.count)
        await gallery.refreshTask?.value
        XCTAssertEqual(calls.withLock { $0.count }, gallery.choices.count * 2)
        XCTAssertEqual(gallery.previews["built-in"]?.store.configuration?.defaults.foreground, HexColor(0x333333ff))
        XCTAssertTrue(store.customizationHistory.hasPendingChanges)
        try store.customizationHistory.flush()
        XCTAssertEqual(store.customizationHistory.undoSteps.count, 1)
    }

    @MainActor func testOnlyContextChangesThatAffectAppearanceRefreshPreviews() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let conditional = try fixture.theme(#"{"profiles":[{"name":"editor","when":{"app":"editor"},"configuration":{"bar":{"height":77}}}]}"#)
        let store = try fixture.store()
        defer { store.stop() }
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let gallery = ThemeGallery(store: store, refreshDelay: .zero, compose: { request in
            calls.withLock { $0 += 1 }
            return try request.compose()
        })
        await gallery.refresh()
        var previous = store.context
        store.context.app = "other app"
        store.context.onBattery.toggle()
        store.context.displayCount += 1
        store.context.externalDisplay.toggle()
        gallery.contextChanged(from: previous)
        XCTAssertNil(gallery.refreshTask)
        XCTAssertEqual(calls.withLock { $0 }, gallery.choices.count)
        previous = store.context
        store.context.app = "editor"
        gallery.contextChanged(from: previous)
        await gallery.refreshTask?.value
        XCTAssertEqual(calls.withLock { $0 }, gallery.choices.count * 2)
        XCTAssertEqual(gallery.previews[conditional.key]?.store.configuration?.bar.height, 77)
        previous = store.context
        store.context.appearance = "dark"
        gallery.contextChanged(from: previous)
        await gallery.refreshTask?.value
        XCTAssertEqual(calls.withLock { $0 }, gallery.choices.count * 3)
        XCTAssertEqual(gallery.previews["built-in"]?.store.context.appearance, "dark")
    }

    @MainActor func testFixedAppearanceIgnoresSystemAppearanceChanges() async throws {
        let fixture = try ThemeGalleryFixture(#"{"bar":{"appearance":"light"},"widgets":[]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let gallery = ThemeGallery(store: store)
        await gallery.refresh()
        let previous = store.context
        store.context.appearance = "dark"
        gallery.contextChanged(from: previous)
        XCTAssertNil(gallery.refreshTask)
        XCTAssertEqual(gallery.previews["built-in"]?.store.context.appearance, "light")
    }

    @MainActor func testOneStoreDownloadBuildsOnlyItsOwnPreviewAndKeepsLocalSnapshots() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let index = LocalPackageIndex(fixture: fixture)
        let entry = try await index.add()
        let store = try fixture.store()
        defer { store.stop() }
        let calls = OSAllocatedUnfairLock(initialState: [String]())
        let gallery = ThemeGallery(store: store,
            client: PackageStoreClient(packages: fixture.packages, indexURL: index.url), compose: { request in
                calls.withLock { $0.append(request.choice.key) }
                return try request.compose()
            })
        await gallery.refresh()
        let local = gallery.previews.mapValues { $0.store }
        let initialCount = calls.withLock { $0.count }
        await gallery.loadStore()
        XCTAssertEqual(calls.withLock { Array($0.dropFirst(initialCount)) }, [entry.versionKey])
        for (key, store) in local { XCTAssertTrue(gallery.previews[key]?.store === store) }
        XCTAssertNotNil(gallery.previews[entry.versionKey])
        await gallery.loadStore()
        XCTAssertEqual(calls.withLock { $0.count }, initialCount + 1)
    }

    @MainActor func testAnOlderBackgroundRefreshCannotReplaceNewerSnapshots() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let started = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let pause = OSAllocatedUnfairLock(initialState: true)
        let gallery = ThemeGallery(store: store, refreshDelay: .zero, compose: { request in
            let shouldPause = pause.withLock { value in let previous = value; value = false; return previous }
            if shouldPause { started.continuation.yield(()); release.wait() }
            return try request.compose()
        })
        let firstRefresh = Task { await gallery.refresh() }
        for await _ in started.stream { break }
        try store.customizationHistory.change(ConfigurationEdit(action: .tokens, properties: ["text": .string("#123456")]))
        gallery.configurationChanged()
        await gallery.refreshTask?.value
        let latest = try XCTUnwrap(gallery.previews["built-in"])
        XCTAssertEqual(latest.store.configuration?.defaults.foreground, HexColor(0x123456ff))
        release.signal()
        await firstRefresh.value
        XCTAssertTrue(gallery.previews["built-in"]?.store === latest.store)
    }

    @MainActor func testAContextChangeDuringBackgroundCompositionRefreshesTheResult() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let started = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let pause = OSAllocatedUnfairLock(initialState: true)
        let gallery = ThemeGallery(store: store, refreshDelay: .zero, compose: { request in
            let shouldPause = pause.withLock { value in let previous = value; value = false; return previous }
            if shouldPause { started.continuation.yield(()); release.wait() }
            return try request.compose()
        })
        let firstRefresh = Task { await gallery.refresh() }
        for await _ in started.stream { break }
        store.context.appearance = "dark"
        release.signal()
        await firstRefresh.value
        await gallery.refreshTask?.value
        XCTAssertEqual(gallery.previews.count, gallery.choices.count)
        XCTAssertEqual(gallery.previews["built-in"]?.store.context.appearance, "dark")
    }

    @MainActor func testBrokenInitialConfigurationKeepsCardsAndWaitsForConfigurationRecovery() async throws {
        for broken in ["{", #"{"widgets":[{"id":"a","type":"missing","position":"left"}]}"#] {
            let fixture = try ThemeGalleryFixture()
            defer { fixture.close() }
            let store = try fixture.store()
            defer { store.stop() }
            try fixture.write(broken, to: fixture.url)
            store.reloadConfiguration()
            XCTAssertNotNil(store.configurationError)
            let calls = OSAllocatedUnfairLock(initialState: 0)
            let gallery = ThemeGallery(store: store, refreshDelay: .zero, compose: { request in
                calls.withLock { $0 += 1 }
                return try request.compose()
            })
            await gallery.refresh()
            XCTAssertFalse(gallery.choices.isEmpty)
            XCTAssertEqual(gallery.previewErrors.count, gallery.choices.count)
            XCTAssertTrue(gallery.previewErrors.values.allSatisfy { $0.contains("Previews are unavailable") })
            XCTAssertTrue(gallery.previews.isEmpty)
            let previous = store.context
            store.context.appearance = "dark"
            gallery.contextChanged(from: previous)
            XCTAssertNil(gallery.refreshTask)
            XCTAssertEqual(calls.withLock { $0 }, 0)
            try fixture.write(#"{"widgets":[]}"#, to: fixture.url)
            store.reloadConfiguration()
            XCTAssertNil(store.configurationError)
            gallery.configurationErrorChanged()
            await gallery.refreshTask?.value
            XCTAssertEqual(gallery.previews.count, gallery.choices.count)
            XCTAssertTrue(gallery.previewErrors.isEmpty)
        }
    }

    @MainActor func testSuccessfulPreviewClearsOnlyItsPreviewErrorAndKeepsGetErrors() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let fails = OSAllocatedUnfairLock(initialState: true)
        let gallery = ThemeGallery(store: store, compose: { request in
            if fails.withLock({ $0 }) { throw CommandFailure(message: "Brief preview failure") }
            return try request.compose()
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
