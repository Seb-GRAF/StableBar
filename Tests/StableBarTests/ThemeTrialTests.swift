import AppKit
import XCTest
@testable import StableBar

final class ThemeTrialTests: XCTestCase {
    @MainActor func testListMatchesGalleryAndStartsAtCurrentBundledOrInstalledTheme() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let installed = try fixture.theme(#"{"defaults":{"fontSize":19}}"#)
        for selection in [#"{"id":"terminal"}"#, #"{"id":"test-theme","version":"1"}"#, #"{"id":"terminal","enabled":false}"#, ""] {
            let configuration = selection.isEmpty ? #"{"widgets":[]}"# : #"{"theme":\#(selection),"widgets":[]}"#
            try fixture.write(configuration, to: fixture.url)
            let store = try loadedStore(fixture)
            defer { store.stop() }
            let trial = ThemeTrial(store: store)
            let gallery = ThemeGallery(store: store)
            await gallery.refresh()
            XCTAssertEqual(trial.choices.map(\.key), gallery.choices.map(\.key))
            XCTAssertTrue(trial.choices.first?.isBuiltIn == true)
            XCTAssertEqual(trial.choices.last?.key, installed.key)
            XCTAssertEqual(trial.choice?.key, gallery.selectedKey)
            XCTAssertEqual(trial.position, "\(trial.selectedIndex + 1) of \(trial.choices.count)")
        }
    }

    @MainActor func testPreviousAndNextWrapAndPreviewWithoutWritingOrAddingHistory() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        let original = try Data(contentsOf: fixture.url)
        let trial = ThemeTrial(store: store)
        trial.previous()
        XCTAssertEqual(trial.selectedIndex, trial.choices.count - 1)
        XCTAssertEqual(store.configuration?.defaults.fontName, "Menlo")
        trial.next()
        XCTAssertEqual(trial.selectedIndex, 0)
        for index in 1...trial.choices.count {
            trial.next()
            XCTAssertNil(trial.error)
            XCTAssertEqual(trial.selectedIndex, index % trial.choices.count)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.url), original)
        XCTAssertTrue(store.customizationHistory.undoSteps.isEmpty)
        XCTAssertTrue(store.customizationEdits.isEmpty)
        trial.cancel()
    }

    @MainActor func testCancelRestoresEveryComposedLayerAndLeavesAllFilesAndHistoryUntouched() throws {
        let fixture = try ThemeGalleryFixture(#"{"includes":["included.json"],"theme":{"id":"terminal"},"templates":{"label":{"type":"text","position":"left","style":{"paddingHorizontal":7}}},"widgets":[{"id":"label","template":"label","text":"Label"}],"widgetOverrides":{"label":{"style":{"fontSize":17}}},"profiles":[{"name":"work","configuration":{"bar":{"inset":19}}}]}"#)
        defer { fixture.close() }
        try fixture.write(#"{"defaults":{"cornerRadius":4}}"#, to: fixture.directory.appending(path: "included.json"))
        let installed = try fixture.theme(#"{"bar":{"height":57},"defaults":{"fontSize":22}}"#)
        let store = try loadedStore(fixture)
        defer { store.stop() }
        try store.setSessionEdits(pendingEdits)
        let original = try Data(contentsOf: fixture.url)
        let included = try Data(contentsOf: fixture.directory.appending(path: "included.json"))
        let theme = try Data(contentsOf: installed.directory.appending(path: "config.json"))
        let document = store.effectiveDocument
        let origins = store.origins
        let profiles = store.activeProfiles
        let edits = try encodedEdits(store)
        let trial = ThemeTrial(store: store)
        trial.next()
        XCTAssertEqual(trial.choice?.key, installed.key)
        XCTAssertEqual(store.configuration?.bar.height, 57)
        XCTAssertEqual(store.configuration?.bar.margin, 9)
        XCTAssertEqual(store.configuration?.bar.inset, 19)
        XCTAssertEqual(store.configuration?.widgets.first?.style.fontSize, 17)
        trial.cancel()
        trial.cancel()
        trial.next()
        XCTAssertFalse(trial.isActive)
        XCTAssertEqual(store.effectiveDocument, document)
        XCTAssertEqual(store.origins, origins)
        XCTAssertEqual(store.activeProfiles, profiles)
        XCTAssertEqual(try encodedEdits(store), edits)
        XCTAssertEqual(try Data(contentsOf: fixture.url), original)
        XCTAssertEqual(try Data(contentsOf: fixture.directory.appending(path: "included.json")), included)
        XCTAssertEqual(try Data(contentsOf: installed.directory.appending(path: "config.json")), theme)
        XCTAssertTrue(store.customizationHistory.undoSteps.isEmpty)
    }

    @MainActor func testKeepSavesOnlyTheThemeAsOneImmediateUndoableChange() throws {
        let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"label","type":"text","text":"Saved","position":"left"}]}"#)
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        try store.setSessionEdits(pendingEdits)
        let original = try Data(contentsOf: fixture.url)
        let edits = try encodedEdits(store)
        let trial = ThemeTrial(store: store)
        trial.previous()
        trial.keep()
        trial.keep()
        trial.cancel()
        XCTAssertNil(trial.error)
        XCTAssertFalse(trial.isActive)
        XCTAssertEqual(try fixture.document()["theme"], .object(["id": .string("terminal")]))
        XCTAssertNil(try fixture.document()["bar"])
        XCTAssertEqual(store.configuration?.widgets.first?.content, .text("Temporary"))
        XCTAssertEqual(store.configuration?.bar.margin, 9)
        XCTAssertEqual(store.configuration?.defaults.fontName, "Menlo")
        XCTAssertEqual(try encodedEdits(store), edits)
        XCTAssertFalse(store.customizationHistory.hasPendingChanges)
        XCTAssertEqual(store.customizationHistory.undoSteps.count, 1)
        try store.customizationHistory.undo()
        XCTAssertEqual(try Data(contentsOf: fixture.url), original)
        XCTAssertEqual(store.configuration?.widgets.first?.content, .text("Temporary"))
        XCTAssertEqual(try encodedEdits(store), edits)
        try store.customizationHistory.redo()
        XCTAssertEqual(store.configuration?.defaults.fontName, "Menlo")
        XCTAssertEqual(try encodedEdits(store), edits)
    }

    @MainActor func testKeepBuiltInOverridesAnIncludedThemeAndUndoRestoresIt() throws {
        let fixture = try ThemeGalleryFixture(#"{"includes":["included.json"],"widgets":[]}"#)
        defer { fixture.close() }
        let includedURL = fixture.directory.appending(path: "included.json")
        try fixture.write(#"{"theme":{"id":"terminal"}}"#, to: includedURL)
        let included = try Data(contentsOf: includedURL)
        let store = try loadedStore(fixture)
        defer { store.stop() }
        let trial = ThemeTrial(store: store)
        XCTAssertEqual(trial.choice?.key, "terminal")
        trial.next()
        XCTAssertTrue(trial.choice?.isBuiltIn == true)
        XCTAssertNil(store.configuration?.defaults.fontName)
        trial.keep()
        XCTAssertNil(trial.error)
        XCTAssertEqual(try fixture.document()["theme"], .object(["id": .string("built-in")]))
        XCTAssertEqual(try Data(contentsOf: includedURL), included)
        XCTAssertEqual(store.customizationHistory.undoSteps.count, 1)
        try store.customizationHistory.undo()
        XCTAssertEqual(store.configuration?.defaults.fontName, "Menlo")
    }

    @MainActor func testInstalledThemeSettingsSurvivePreviewAndKeepAndOtherPackageFilesStayUntouched() throws {
        let fixture = try ThemeGalleryFixture(#"{"theme":{"id":"test-theme","version":"1","settings":{"size":48}},"packages":[{"id":"labels","version":"1"}],"widgets":[]}"#)
        defer { fixture.close() }
        let source = try fixture.theme(#"{"bar":{"height":"@setting.size"}}"#, install: false)
        try fixture.write(#"{"id":"test-theme","name":"Test theme","version":"1","kind":"theme","entry":"config.json","settings":{"size":{"type":"number","default":40}}}"#,
                          to: source.directory.appending(path: "package.json"))
        let installed = try fixture.packages.install(source.directory)
        let package = fixture.packages.directory.appending(path: "labels/1")
        let packageURL = package.appending(path: "config.json")
        try fixture.write(#"{"id":"labels","name":"Labels","version":"1","kind":"widgets","entry":"config.json"}"#, to: package.appending(path: "package.json"))
        try fixture.write(#"{"widgets":[{"id":"package-label","type":"text","text":"Package","position":"left"}]}"#, to: packageURL)
        let packageData = try Data(contentsOf: packageURL)
        let themeData = try Data(contentsOf: installed.directory.appending(path: "config.json"))
        let store = try loadedStore(fixture)
        defer { store.stop() }
        let original = try Data(contentsOf: fixture.url)
        let trial = ThemeTrial(store: store)
        XCTAssertEqual(trial.choice?.key, "test-theme/1")
        XCTAssertEqual(store.configuration?.bar.height, 48)
        trial.next()
        XCTAssertTrue(trial.choice?.isBuiltIn == true)
        trial.previous()
        XCTAssertEqual(store.configuration?.bar.height, 48)
        XCTAssertTrue(store.configuration?.widgets.contains { $0.content == .text("Package") } == true)
        trial.keep()
        XCTAssertNil(trial.error)
        XCTAssertEqual(try Data(contentsOf: fixture.url), original)
        XCTAssertEqual(try Data(contentsOf: packageURL), packageData)
        XCTAssertEqual(try Data(contentsOf: installed.directory.appending(path: "config.json")), themeData)
        XCTAssertTrue(store.customizationHistory.undoSteps.isEmpty)
        let another = ThemeTrial(store: store)
        another.next()
        another.next()
        another.previous()
        another.previous()
        another.keep()
        XCTAssertEqual(store.configuration?.bar.height, 48)
        XCTAssertEqual(try fixture.document()["theme"]?.decoded(WidgetPackageSelection.self).settings, ["size": .number(48)])
    }

    @MainActor func testPreviewAndCancelUpdateTheCompositionUsedByEveryDisplay() throws {
        let fixture = try ThemeGalleryFixture(#"{"bar":{"displayScale":{"external":1.25}},"widgets":[]}"#)
        defer { fixture.close() }
        _ = try fixture.theme(#"{"bar":{"height":57},"profiles":[{"name":"two screens","when":{"displayCount":2},"configuration":{"bar":{"height":64}}}]}"#)
        let store = try loadedStore(fixture)
        defer { store.stop() }
        store.context.displayCount = 2
        let displays = [BarDisplay(id: 1, isBuiltIn: true, isMain: true, notch: nil),
                        BarDisplay(id: 2, isBuiltIn: false, isMain: false, notch: nil)]
        var heights: [[CGFloat]] = []
        store.onConfigurationChange = { [weak store] in
            guard let configuration = store?.configuration else { return }
            heights.append(displays.map { configuration.barGeometry(for: $0).layoutHeight })
        }
        let trial = ThemeTrial(store: store)
        trial.previous()
        XCTAssertNil(trial.error)
        XCTAssertEqual(heights.last, [64, 80])
        XCTAssertEqual(store.activeProfiles, ["two screens"])
        trial.cancel()
        XCTAssertEqual(heights.last, [40, 50])
        XCTAssertTrue(store.activeProfiles.isEmpty)
        let kept = ThemeTrial(store: store)
        kept.previous()
        kept.keep()
        XCTAssertNil(kept.error)
        XCTAssertEqual(heights.last, [64, 80])
        XCTAssertEqual(try fixture.document()["theme"], .object(["id": .string("test-theme"), "version": .string("1")]))
        XCTAssertEqual(store.customizationHistory.undoSteps.count, 1)
        try store.customizationHistory.undo()
        XCTAssertEqual(heights.last, [40, 50])
    }

    @MainActor func testCancelAfterFailedReloadRestoresThePriorCompositionAndLeavesRedoAvailable() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        try store.customizationHistory.change(ConfigurationEdit(action: .theme, properties: ["id": .string("terminal")]))
        try store.customizationHistory.undo()
        let document = store.effectiveDocument
        let origins = store.origins
        let original = try Data(contentsOf: fixture.url)
        let trial = ThemeTrial(store: store)
        trial.previous()
        XCTAssertTrue(store.customizationHistory.canRedo)
        trial.cancel()
        XCTAssertEqual(store.effectiveDocument, document)
        XCTAssertTrue(store.customizationHistory.canRedo)
        let failing = ThemeTrial(store: store)
        failing.previous()
        let invalid = Data(#"{"bar":{"height":"invalid"},"widgets":[]}"#.utf8)
        try invalid.write(to: fixture.url)
        store.reloadConfiguration()
        XCTAssertNotNil(store.configurationError)
        failing.cancel()
        XCTAssertEqual(store.effectiveDocument, document)
        XCTAssertEqual(store.origins, origins)
        XCTAssertEqual(try Data(contentsOf: fixture.url), invalid)
        try original.write(to: fixture.url)
    }

    @MainActor func testPendingThemeAndLaterCommandLineEditsStayAppliedThroughKeepAndCancel() throws {
        for keep in [false, true] {
            let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"label","type":"text","text":"Saved","position":"left"}]}"#)
            defer { fixture.close() }
            let store = try loadedStore(fixture)
            defer { store.stop() }
            let themeEdit = ConfigurationEdit(action: .theme, properties: ["id": .string("terminal")])
            try store.setSessionEdits([themeEdit] + pendingEdits)
            let trial = ThemeTrial(store: store)
            XCTAssertEqual(trial.choice?.key, "terminal")
            trial.next()
            XCTAssertNil(store.configuration?.defaults.fontName)
            try store.applyEdits([ConfigurationEdit(action: .bar, properties: ["inset": .number(23)])], persist: false)
            store.reloadConfiguration()
            XCTAssertNil(store.configuration?.defaults.fontName)
            XCTAssertEqual(store.configuration?.bar.inset, 23)
            let edits = try encodedEdits(store)
            if keep { trial.keep() } else { trial.cancel() }
            XCTAssertNil(trial.error)
            XCTAssertEqual(store.configuration?.defaults.fontName, "Menlo")
            XCTAssertEqual(store.configuration?.bar.margin, 9)
            XCTAssertEqual(store.configuration?.bar.inset, 23)
            XCTAssertEqual(store.configuration?.widgets.first?.content, .text("Temporary"))
            XCTAssertEqual(try encodedEdits(store), edits)
            XCTAssertNil(try fixture.document()["bar"])
            XCTAssertNil(try fixture.document()["theme"])
        }
    }

    @MainActor func testKeyboardArrowsReturnEscapeAndUnrelatedKeys() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        let original = try Data(contentsOf: fixture.url)
        let cancelled = ThemeTrial(store: store)
        XCTAssertFalse(cancelled.handleKey(48)) // Tab remains available to focus controls.
        XCTAssertTrue(cancelled.handleKey(123))
        XCTAssertEqual(cancelled.choice?.key, "terminal")
        XCTAssertTrue(cancelled.handleKey(124))
        XCTAssertTrue(cancelled.choice?.isBuiltIn == true)
        XCTAssertTrue(cancelled.handleKey(123))
        XCTAssertTrue(cancelled.handleKey(53))
        XCTAssertFalse(cancelled.handleKey(36))
        XCTAssertEqual(try Data(contentsOf: fixture.url), original)
        for key: UInt16 in [36, 76] {
            let kept = ThemeTrial(store: store)
            kept.previous()
            XCTAssertTrue(kept.handleKey(key))
            XCTAssertFalse(kept.isActive)
            XCTAssertNil(kept.error)
        }
        XCTAssertEqual(store.customizationHistory.undoSteps.count, 2)
    }

    @MainActor func testQuittingDuringTrialLeavesTheSavedThemeForTheNextLaunch() throws {
        let fixture = try ThemeGalleryFixture(#"{"theme":{"id":"terminal"},"widgets":[]}"#)
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        let original = try Data(contentsOf: fixture.url)
        let trial = ThemeTrial(store: store)
        trial.next()
        XCTAssertNil(store.configuration?.defaults.fontName)
        XCTAssertEqual(AppDelegate(store: store).applicationShouldTerminate(NSApplication.shared), .terminateNow)
        store.stop()
        XCTAssertEqual(try Data(contentsOf: fixture.url), original)
        let restarted = try loadedStore(fixture)
        defer { restarted.stop() }
        XCTAssertEqual(restarted.configuration?.defaults.fontName, "Menlo")
        XCTAssertTrue(restarted.customizationHistory.undoSteps.isEmpty)
    }

    @MainActor func testInvalidPreviewAndFailedKeepDoNotWriteOrEndTheTrial() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let invalid = try fixture.theme(#"{"defaults":{"fontSize":19}}"#)
        try fixture.write(#"{"environment":{"INVALID":"theme"}}"#, to: invalid.directory.appending(path: "config.json"))
        let store = try loadedStore(fixture)
        defer { store.stop() }
        let document = store.effectiveDocument
        let original = try Data(contentsOf: fixture.url)
        let trial = ThemeTrial(store: store)
        trial.previous()
        XCTAssertNotNil(trial.error)
        XCTAssertTrue(trial.choice?.isBuiltIn == true)
        XCTAssertEqual(store.effectiveDocument, document)
        XCTAssertEqual(try Data(contentsOf: fixture.url), original)
        trial.next()
        XCTAssertNil(trial.error)
        try FileManager.default.removeItem(at: fixture.url)
        trial.keep()
        XCTAssertNotNil(trial.error)
        XCTAssertTrue(trial.isActive)
        XCTAssertTrue(store.customizationHistory.undoSteps.isEmpty)
        try original.write(to: fixture.url)
        trial.cancel()
        XCTAssertEqual(store.effectiveDocument, document)
    }

    @MainActor func testPreviewSnapshotStoresStillNeverApplyOrRunThemeTrials() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = BarStore(configurationURL: fixture.url, themesDirectory: fixture.themes, isPreview: true)
        defer { store.stop() }
        store.reloadConfiguration()
        let choice = try XCTUnwrap(ThemeCatalog(packages: fixture.packages.directory, themesDirectory: fixture.themes).choices.last)
        XCTAssertThrowsError(try store.tryTheme(choice))
        XCTAssertNil(store.configuration)
        XCTAssertTrue(store.scripts.isEmpty)
        XCTAssertTrue(store.providers.isEmpty)
    }

    @MainActor func testMenuBarMenuOffersTryThemes() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        let menu = NSMenu()
        AppDelegate(store: store).menuWillOpen(menu)
        let item = try XCTUnwrap(menu.items.first { $0.title == "Try Themes…" })
        XCTAssertNotNil(item.action)
    }

    private var pendingEdits: [ConfigurationEdit] {
        [ConfigurationEdit(action: .bar, properties: ["margin": .number(9)]),
         ConfigurationEdit(action: .set, id: "label", properties: ["text": .string("Temporary")])]
    }

    @MainActor private func loadedStore(_ fixture: ThemeGalleryFixture) throws -> BarStore {
        let store = BarStore(configurationURL: fixture.url, themesDirectory: fixture.themes)
        store.reloadConfiguration()
        XCTAssertNil(store.configurationError)
        _ = try XCTUnwrap(store.configuration)
        return store
    }

    @MainActor private func encodedEdits(_ store: BarStore) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(store.sessionEdits)
    }
}
