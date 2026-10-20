import AppKit
import XCTest
@testable import StableBar

final class ThemeTrialTests: XCTestCase {
    @MainActor func testListMatchesGalleryAndStartsAtCurrentBundledOrInstalledTheme() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let installed = try fixture.theme(#"{"defaults":{"fontSize":19}}"#)
        for selection in [#"{"id":"rose-pine"}"#, #"{"id":"test-theme","version":"1"}"#, #"{"id":"rose-pine","enabled":false}"#, ""] {
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
        XCTAssertEqual(store.configuration?.defaults.cornerRadius, 13)
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

    @MainActor func testGalleryAndTrialSaveIdenticalThemeEditsIncludingMainFileSettingsAndInheritedThemes() async throws {
        let cases: [(main: String, included: String, key: String, properties: [String: ConfigurationValue]?)] = [
            (#"{"widgets":[]}"#, "{}", "built-in", nil),
            (#"{"theme":{"id":"rose-pine"},"widgets":[]}"#, "{}", "built-in", nil),
            (#"{"widgets":[]}"#, "{}", "rose-pine", ["id": .string("rose-pine")]),
            (#"{"theme":{"id":"test-theme","version":"1","settings":{"size":48}},"widgets":[]}"#,
             "{}", "test-theme/1", ["id": .string("test-theme"), "version": .string("1"), "settings": .object(["size": .number(48)])]),
            (#"{"includes":["included.json"],"widgets":[]}"#, #"{"theme":{"id":"rose-pine"}}"#,
             "built-in", ["id": .string("built-in")]),
            (#"{"includes":["included.json"],"widgets":[]}"#,
             #"{"theme":{"id":"test-theme","version":"1","settings":{"size":48}}}"#,
             "test-theme/1", ["id": .string("test-theme"), "version": .string("1"), "settings": .null])
        ]
        for scenario in cases {
            let fixture = try ThemeGalleryFixture(scenario.main)
            defer { fixture.close() }
            _ = try installSizedTheme(in: fixture)
            let includedURL = fixture.directory.appending(path: "included.json")
            try fixture.write(scenario.included, to: includedURL)
            let included = try Data(contentsOf: includedURL)
            let original = try Data(contentsOf: fixture.url)
            let store = try loadedStore(fixture)
            defer { store.stop() }
            let gallery = ThemeGallery(store: store)
            await gallery.refresh()
            let choice = try XCTUnwrap(gallery.choices.first { $0.key == scenario.key })
            let edit = try store.themeEdit(for: choice)
            XCTAssertEqual(edit.action, .theme)
            XCTAssertEqual(edit.properties, scenario.properties)
            var ids: [String] = []
            let expected = try edit.applying(to: fixture.document(), widgetIDs: &ids)
            gallery.select(choice)
            XCTAssertNil(gallery.errors[choice.key])
            let galleryDocument = try fixture.document()
            XCTAssertEqual(galleryDocument, expected)
            if store.customizationHistory.canUndo { try store.customizationHistory.undo() }
            XCTAssertEqual(try Data(contentsOf: fixture.url), original)
            let trial = ThemeTrial(store: store)
            for _ in trial.choices.indices {
                if trial.choice?.key == choice.key { break }
                trial.next()
                XCTAssertNil(trial.error)
            }
            XCTAssertEqual(trial.choice?.key, choice.key)
            XCTAssertEqual(try store.themeEdit(for: choice).properties, edit.properties)
            trial.keep()
            XCTAssertNil(trial.error)
            XCTAssertFalse(trial.isActive)
            XCTAssertEqual(try fixture.document(), galleryDocument)
            XCTAssertEqual(try Data(contentsOf: includedURL), included)
        }
    }


    @MainActor func testVersionedIncludedThemeSettingsDoNotLeakIntoGalleryOrTrialSelections() async throws {
        let fixture = try ThemeGalleryFixture(#"{"includes":["included.json"],"widgets":[]}"#)
        defer { fixture.close() }
        _ = try installSizedTheme(in: fixture)
        let other = try fixture.theme(#"{"bar":{"height":61}}"#, id: "other")
        let includedURL = fixture.directory.appending(path: "included.json")
        try fixture.write(#"{"theme":{"id":"test-theme","version":"1","settings":{"size":48}}}"#, to: includedURL)
        let included = try Data(contentsOf: includedURL)
        let original = try Data(contentsOf: fixture.url)
        let store = try loadedStore(fixture)
        defer { store.stop() }
        let gallery = ThemeGallery(store: store)
        await gallery.refresh()
        for key in ["built-in", "rose-pine", other.key] {
            let choice = try XCTUnwrap(gallery.choices.first { $0.key == key })
            for trialSelection in [false, true] {
                if trialSelection {
                    let trial = ThemeTrial(store: store)
                    for _ in trial.choices.indices {
                        if trial.choice?.key == key { break }
                        trial.next()
                        XCTAssertNil(trial.error)
                    }
                    trial.keep()
                    XCTAssertNil(trial.error)
                    XCTAssertFalse(trial.isActive)
                } else {
                    gallery.select(choice)
                    XCTAssertNil(gallery.errors[key])
                }
                XCTAssertEqual(store.selectedThemeKey, key)
                let selection = try XCTUnwrap(fixture.document()["theme"]?.decoded([String: ConfigurationValue].self))
                XCTAssertEqual(selection["settings"], .null)
                XCTAssertEqual(selection["version"], choice.isBundled ? .null : .string("1"))
                XCTAssertEqual(try Data(contentsOf: includedURL), included)
                try store.customizationHistory.undo()
                XCTAssertEqual(try Data(contentsOf: fixture.url), original)
                XCTAssertEqual(store.configuration?.bar.height, 48)
            }
        }
    }

    @MainActor func testClearanceUsesSavedCompositionDuringTrialAndChangesOnlyWhenKept() throws {
        let fixture = try ThemeGalleryFixture(#"{"bar":{"keepWindowsClear":true},"widgets":[]}"#)
        defer { fixture.close() }
        let theme = try fixture.theme(#"{"bar":{"height":95,"offset":30,"keepWindowsClear":false}}"#)
        let store = try loadedStore(fixture)
        defer { store.stop() }
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let display = BarDisplay(id: 1, isBuiltIn: true, isMain: true, notch: nil)
        let app = AppDelegate(store: store)
        let clearance = { app.clearanceDisplay(frame: frame, visibleFrame: frame, display: display, desktopTop: frame.maxY) }
        let before = try XCTUnwrap(clearance())
        let trial = ThemeTrial(store: store)
        for _ in trial.choices.indices {
            if trial.choice?.key == theme.key { break }
            trial.next()
        }
        XCTAssertNil(trial.error)
        XCTAssertEqual(store.configuration?.bar.height, 95)
        XCTAssertEqual(clearance(), before)
        XCTAssertEqual(store.clearanceConfiguration?.bar.keepWindowsClear, true)
        trial.cancel()
        XCTAssertEqual(clearance(), before)
        let keeping = ThemeTrial(store: store)
        for _ in keeping.choices.indices {
            if keeping.choice?.key == theme.key { break }
            keeping.next()
        }
        keeping.keep()
        XCTAssertNil(keeping.error)
        let kept = try XCTUnwrap(clearance())
        XCTAssertNotEqual(kept, before)
        XCTAssertEqual(kept.barFrame.height, 95)
        XCTAssertEqual(kept.barFrame.minY, 30)
    }

    @MainActor func testKeepingCurrentThemeNeverSavesPendingCommandLineSettings() async throws {
        for savedSettings in ["", #", "settings":{"size":48}"#] {
            let fixture = try ThemeGalleryFixture(#"{"theme":{"id":"test-theme","version":"1"\#(savedSettings)},"widgets":[]}"#)
            defer { fixture.close() }
            let installed = try installSizedTheme(in: fixture)
            let original = try Data(contentsOf: fixture.url)
            let store = try loadedStore(fixture)
            defer { store.stop() }
            let edit = ConfigurationEdit(action: .theme, properties: [
                "id": .string("test-theme"), "version": .string("1"), "settings": .object(["size": .number(63)])
            ])
            try store.setSessionEdits([edit])
            let gallery = ThemeGallery(store: store)
            await gallery.refresh()
            XCTAssertEqual(gallery.previews[installed.key]?.light.bar.height, 40)
            gallery.select(installed)
            XCTAssertNil(gallery.errors[installed.key])
            XCTAssertEqual(try Data(contentsOf: fixture.url), original)
            let trial = ThemeTrial(store: store)
            XCTAssertEqual(trial.choice?.key, installed.key)
            trial.next()
            trial.previous()
            XCTAssertNil(trial.error)
            XCTAssertEqual(store.configuration?.bar.height, 63)
            try store.applyEdits([ConfigurationEdit(action: .theme, properties: [
                "id": .string("test-theme"), "version": .string("1"), "settings": .object(["size": .number(71)])
            ])], persist: false)
            let pending = try encodedEdits(store)
            XCTAssertEqual(store.configuration?.bar.height, 71)
            trial.keep()
            XCTAssertNil(trial.error)
            XCTAssertFalse(trial.isActive)
            XCTAssertEqual(try Data(contentsOf: fixture.url), original)
            XCTAssertEqual(store.configuration?.bar.height, 71)
            XCTAssertEqual(try encodedEdits(store), pending)
            XCTAssertTrue(store.customizationHistory.undoSteps.isEmpty)
        }
    }

    @MainActor func testCancelRestoresEveryComposedLayerAndLeavesAllFilesAndHistoryUntouched() throws {
        let fixture = try ThemeGalleryFixture(#"{"includes":["included.json"],"theme":{"id":"rose-pine"},"templates":{"label":{"type":"text","position":"left","style":{"paddingHorizontal":7}}},"widgets":[{"id":"label","template":"label","text":"Label"}],"widgetOverrides":{"label":{"style":{"fontSize":17}}},"profiles":[{"name":"work","configuration":{"bar":{"inset":19}}}]}"#)
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
        XCTAssertEqual(try fixture.document()["theme"], .object(["id": .string("rose-pine")]))
        XCTAssertNil(try fixture.document()["bar"])
        XCTAssertEqual(store.configuration?.widgets.first?.content, .text("Temporary"))
        XCTAssertEqual(store.configuration?.bar.margin, 9)
        XCTAssertEqual(store.configuration?.defaults.cornerRadius, 13)
        XCTAssertEqual(try encodedEdits(store), edits)
        XCTAssertFalse(store.customizationHistory.hasPendingChanges)
        XCTAssertEqual(store.customizationHistory.undoSteps.count, 1)
        try store.customizationHistory.undo()
        XCTAssertEqual(try Data(contentsOf: fixture.url), original)
        XCTAssertEqual(store.configuration?.widgets.first?.content, .text("Temporary"))
        XCTAssertEqual(try encodedEdits(store), edits)
        try store.customizationHistory.redo()
        XCTAssertEqual(store.configuration?.defaults.cornerRadius, 13)
        XCTAssertEqual(try encodedEdits(store), edits)
    }

    @MainActor func testKeepBuiltInOverridesAnIncludedThemeAndUndoRestoresIt() throws {
        let fixture = try ThemeGalleryFixture(#"{"includes":["included.json"],"widgets":[]}"#)
        defer { fixture.close() }
        let includedURL = fixture.directory.appending(path: "included.json")
        try fixture.write(#"{"theme":{"id":"rose-pine"}}"#, to: includedURL)
        let included = try Data(contentsOf: includedURL)
        let store = try loadedStore(fixture)
        defer { store.stop() }
        let trial = ThemeTrial(store: store)
        XCTAssertEqual(trial.choice?.key, "rose-pine")
        trial.next()
        XCTAssertTrue(trial.choice?.isBuiltIn == true)
        XCTAssertNotEqual(store.configuration?.defaults.cornerRadius, 13)
        trial.keep()
        XCTAssertNil(trial.error)
        XCTAssertEqual(try fixture.document()["theme"], .object(["id": .string("built-in")]))
        XCTAssertEqual(try Data(contentsOf: includedURL), included)
        XCTAssertEqual(store.customizationHistory.undoSteps.count, 1)
        try store.customizationHistory.undo()
        XCTAssertEqual(store.configuration?.defaults.cornerRadius, 13)
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
        try store.customizationHistory.change(ConfigurationEdit(action: .theme, properties: ["id": .string("rose-pine")]))
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
            let themeEdit = ConfigurationEdit(action: .theme, properties: ["id": .string("rose-pine")])
            try store.setSessionEdits([themeEdit] + pendingEdits)
            let trial = ThemeTrial(store: store)
            XCTAssertEqual(trial.choice?.key, "rose-pine")
            trial.next()
            XCTAssertNotEqual(store.configuration?.defaults.cornerRadius, 13)
            try store.applyEdits([ConfigurationEdit(action: .bar, properties: ["inset": .number(23)])], persist: false)
            store.reloadConfiguration()
            XCTAssertNotEqual(store.configuration?.defaults.cornerRadius, 13)
            XCTAssertEqual(store.configuration?.bar.inset, 23)
            let edits = try encodedEdits(store)
            if keep { trial.keep() } else { trial.cancel() }
            XCTAssertNil(trial.error)
            XCTAssertEqual(store.configuration?.defaults.cornerRadius, 13)
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
        XCTAssertEqual(cancelled.choice?.key, "rose-pine")
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
        let fixture = try ThemeGalleryFixture(#"{"theme":{"id":"rose-pine"},"widgets":[]}"#)
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        let original = try Data(contentsOf: fixture.url)
        let trial = ThemeTrial(store: store)
        trial.next()
        XCTAssertNotEqual(store.configuration?.defaults.cornerRadius, 13)
        XCTAssertEqual(AppDelegate(store: store).applicationShouldTerminate(NSApplication.shared), .terminateNow)
        store.stop()
        XCTAssertEqual(try Data(contentsOf: fixture.url), original)
        let restarted = try loadedStore(fixture)
        defer { restarted.stop() }
        XCTAssertEqual(restarted.configuration?.defaults.cornerRadius, 13)
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
        XCTAssertEqual(trial.choice?.key, invalid.key)
        XCTAssertFalse(trial.canKeep)
        trial.keep()
        XCTAssertTrue(trial.isActive)
        XCTAssertEqual(store.effectiveDocument, document)
        XCTAssertEqual(try Data(contentsOf: fixture.url), original)
        trial.next()
        XCTAssertNil(trial.error)
        XCTAssertTrue(trial.canKeep)
        try FileManager.default.removeItem(at: fixture.url)
        trial.keep()
        XCTAssertNotNil(trial.error)
        XCTAssertTrue(trial.isActive)
        XCTAssertTrue(store.customizationHistory.undoSteps.isEmpty)
        try original.write(to: fixture.url)
        trial.cancel()
        XCTAssertEqual(store.effectiveDocument, document)
    }

    @MainActor func testNavigationPassesTwoBrokenThemesAndKeepsTheLastGoodLookUntilAnotherWorks() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let broken = try ["broken-a", "broken-b"].map { id in
            let choice = try fixture.theme(#"{"bar":{"height":55}}"#, id: id)
            try fixture.write(#"{"environment":{"INVALID":"theme"}}"#, to: choice.directory.appending(path: "config.json"))
            return choice
        }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        let original = try Data(contentsOf: fixture.url)
        let baseline = store.effectiveDocument
        let trial = ThemeTrial(store: store)
        trial.previous()
        XCTAssertEqual(trial.choice?.key, broken[1].key)
        XCTAssertEqual(trial.choice?.title, broken[1].title)
        XCTAssertFalse(trial.canKeep)
        XCTAssertNotNil(trial.error)
        XCTAssertEqual(store.effectiveDocument, baseline)
        trial.previous()
        XCTAssertEqual(trial.choice?.key, broken[0].key)
        XCTAssertEqual(trial.position, "7 of 8")
        XCTAssertFalse(trial.canKeep)
        XCTAssertNotNil(trial.error)
        XCTAssertTrue(trial.handleKey(36))
        XCTAssertTrue(trial.isActive)
        XCTAssertEqual(try Data(contentsOf: fixture.url), original)
        XCTAssertTrue(store.customizationHistory.undoSteps.isEmpty)
        trial.previous()
        XCTAssertEqual(trial.choice?.key, "rose-pine")
        XCTAssertTrue(trial.canKeep)
        XCTAssertNil(trial.error)
        XCTAssertEqual(store.configuration?.defaults.cornerRadius, 13)
        let lastGood = store.effectiveDocument
        for choice in broken {
            trial.next()
            XCTAssertEqual(trial.choice?.key, choice.key)
            XCTAssertFalse(trial.canKeep)
            XCTAssertNotNil(trial.error)
            XCTAssertEqual(store.effectiveDocument, lastGood)
        }
        trial.next()
        XCTAssertTrue(trial.choice?.isBuiltIn == true)
        XCTAssertTrue(trial.canKeep)
        XCTAssertNil(trial.error)
        XCTAssertNotEqual(store.configuration?.defaults.cornerRadius, 13)
        trial.cancel()
        XCTAssertEqual(store.effectiveDocument, baseline)
        XCTAssertEqual(try Data(contentsOf: fixture.url), original)
        XCTAssertTrue(store.customizationHistory.undoSteps.isEmpty)
    }

    @MainActor func testMenuBarMenuHidesTryThemesWhenNoBarExists() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        let menu = NSMenu()
        let delegate = AppDelegate(store: store)
        delegate.menuWillOpen(menu)
        XCTAssertFalse(menu.items.contains { $0.title == "Try Themes…" })
        try fixture.write("{", to: fixture.url)
        let failed = BarStore(configurationURL: fixture.url, themesDirectory: fixture.themes)
        defer { failed.stop() }
        failed.reloadConfiguration()
        XCTAssertNotNil(failed.configurationError)
        AppDelegate(store: failed).menuWillOpen(menu)
        XCTAssertFalse(menu.items.contains { $0.title == "Try Themes…" })
    }

    @MainActor func testMenuBarMenuOffersTryThemesWhenABarExists() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        let bar = BarPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        defer { bar.close() }
        let menu = NSMenu()
        let delegate = AppDelegate(store: store, panels: [1: bar])
        delegate.menuWillOpen(menu)
        let item = try XCTUnwrap(menu.items.first { $0.title == "Try Themes…" })
        XCTAssertNotNil(item.action)
        XCTAssertFalse(bar.isVisible)
    }

    private var pendingEdits: [ConfigurationEdit] {
        [ConfigurationEdit(action: .bar, properties: ["margin": .number(9)]),
         ConfigurationEdit(action: .set, id: "label", properties: ["text": .string("Temporary")])]
    }

    private func installSizedTheme(in fixture: ThemeGalleryFixture) throws -> ThemeChoice {
        let source = try fixture.theme(#"{"bar":{"height":"@setting.size"}}"#, install: false)
        try fixture.write(#"{"id":"test-theme","name":"Test theme","version":"1","kind":"theme","entry":"config.json","settings":{"size":{"type":"number","default":40}}}"#,
                          to: source.directory.appending(path: "package.json"))
        let installed = try fixture.packages.install(source.directory)
        return ThemeChoice(manifest: installed.manifest, directory: installed.directory, isBundled: false)
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
