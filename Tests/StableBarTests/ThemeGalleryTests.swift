import XCTest
import os
@testable import StableBar

final class ThemeGalleryTests: XCTestCase {
    @MainActor func testThemeSelectionIsSavedImmediatelyAndUndoableWithoutSavingCommandLineEdits() async throws {
        let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"clock","type":"clock","position":"right"}]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        try store.configurationStore.setSessionEdits([ConfigurationEdit(action: .bar, properties: ["margin": .number(12)])])
        let gallery = ThemeGallery(store: store)
        await gallery.refresh()
        XCTAssertEqual(gallery.selectedKey, "built-in")
        let slim = try XCTUnwrap(gallery.choices.first { $0.key == "slim" })
        gallery.select(slim)
        XCTAssertEqual(gallery.selectedKey, "slim")
        XCTAssertEqual(store.configuration?.defaults.fontName, "Menlo")
        XCTAssertEqual(try fixture.document()["theme"], .object(["id": .string("slim")]))
        XCTAssertNil(try fixture.document()["bar"])
        XCTAssertEqual(store.configuration?.bar.margin, 12)
        XCTAssertEqual(store.customizationHistory.undoSteps.count, 1)
        XCTAssertFalse(store.customizationHistory.hasPendingChanges)
        gallery.select(try XCTUnwrap(gallery.choices.first { $0.key == "glass" }))
        XCTAssertEqual(gallery.selectedKey, "glass")
        XCTAssertEqual(try fixture.document()["theme"], .object(["id": .string("glass")]))
        XCTAssertEqual(store.customizationHistory.undoSteps.count, 2)
        try store.customizationHistory.undo()
        XCTAssertEqual(gallery.selectedKey, "slim")
        try store.customizationHistory.undo()
        XCTAssertEqual(gallery.selectedKey, "built-in")
        XCTAssertEqual(store.configurationStore.sessionEdits.count, 1)
    }

    @MainActor func testRetiredThemesKeepTheirAppearanceAsCustomAndCanBeReplacedAndUndone() async throws {
        for id in ["graphite", "island", "menu-bar", "minimal", "paper", "slate", "terminal", "blueprint", "broadsheet",
                   "brutalist", "everforest", "handheld", "kanagawa", "platinum", "rose-pine", "synthwave",
                   "built-in", "leman", "notch", "catppuccin", "nord", "gruvbox", "phosphor"] {
            let fixture = try ThemeGalleryFixture(#"{"includes":["theme.json"],"defaults":{"fontSize":17},"widgets":[]}"#)
            defer { fixture.close() }
            let included = fixture.directory.appending(path: "theme.json")
            try fixture.write(#"{"theme":{"id":"\#(id)"}}"#, to: included)
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
            gallery.select(try XCTUnwrap(gallery.choices.first { $0.key == "slim" }))
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

    @MainActor func testInstalledThemesShowCatalogMembershipWithoutClaimingOrigin() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let listed = try fixture.theme(#"{}"#, id: "listed")
        let unlisted = try fixture.theme(#"{}"#)
        // Installed before install records existed.
        for id in ["listed", "test-theme"] {
            try FileManager.default.removeItem(at: fixture.directory.appending(path: "packages/\(id)/\(PackageInstallRecord.fileName)"))
        }
        let index = LocalPackageIndex(fixture: fixture)
        _ = try await index.add(id: "listed", version: "1")
        let store = try fixture.store()
        defer { store.stop() }
        let gallery = ThemeGallery(store: store, client: PackageStoreClient(packages: fixture.packages, indexURL: index.url))
        await gallery.refresh()
        XCTAssertEqual(gallery.source(of: listed), .installed)
        XCTAssertEqual(gallery.source(of: unlisted), .installed)
        let included = try XCTUnwrap(gallery.choices.first { $0.isBundled })
        XCTAssertEqual(gallery.source(of: included), .included)
        await gallery.loadStore()
        XCTAssertEqual(gallery.source(of: listed), .listed)
        XCTAssertEqual(gallery.source(of: unlisted), .installed)
        XCTAssertEqual(gallery.source(of: included), .included)
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
        XCTAssertEqual(gallery.previews[entry.key]?.light.bar.height, 31)
        XCTAssertEqual(gallery.previews[entry.key]?.light.defaults.fontSize, 19)
        XCTAssertEqual(gallery.previews[entry.key]?.light.widgets.map(\.id), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.packages.directory.path))
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
        // A ready preview is cached: Get works even if its archive is no longer available.
        try FileManager.default.removeItem(at: index.url.deletingLastPathComponent())
        await gallery.get(entry)
        XCTAssertNil(gallery.errors[entry.key])
        XCTAssertNil(gallery.progress[entry.key])
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

    @MainActor func testSaveAsThemeMovesTheThemesEditsIntoANewThemeWithOneUndoStep() async throws {
        let fixture = try ThemeGalleryFixture(#"""
        {"theme":{"id":"phosphor"},"tokens":{"brand":"#00ff00"},"bar":{"offset":30},
         "widgets":[{"id":"clock","type":"clock","position":"right","style":{"foreground":"@token.brand"}}],
         "profiles":[{"name":"Phosphor edits","when":{"theme":"phosphor"},"configuration":{
           "tokens":{"accent":"#ff0000"},"defaults":{"fontSize":17},
           "bar":{"height":34,"popupOffset":12,"glass":{"enabled":true,"transparency":0.5}},
           "widgetOverrides":{"clock":{"background":"#000000"}}}}]}
        """#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        store.configurationStore.reloadConfiguration()
        let before = try Data(contentsOf: fixture.url)
        var look = store.effectiveDocument
        let gallery = ThemeGallery(store: store)
        await gallery.refresh()
        await gallery.save(try XCTUnwrap(gallery.choices.first { $0.key == "phosphor" }), as: "My Phosphor")
        XCTAssertNil(gallery.error(for: "phosphor"))
        XCTAssertEqual(gallery.selectedKey, "my-phosphor/1.0.0")
        let document = try fixture.document()
        XCTAssertEqual(document["theme"], .object(["id": .string("my-phosphor"), "version": .string("1.0.0")]))
        XCTAssertEqual(document["tokens"], .object(["brand": .string("#00ff00")]))
        XCTAssertEqual(document["bar"], .object(["offset": .number(30)]))
        XCTAssertEqual(try document["profiles"]?.decoded([[String: ConfigurationValue]].self), [[
            "name": .string("My Phosphor edits"), "when": .object(["theme": .string("my-phosphor")]),
            "configuration": .object(["widgetOverrides": .object(["clock": .object(["background": .string("#000000")])])])
        ]])
        var saved = store.effectiveDocument
        look["theme"] = nil
        saved["theme"] = nil
        XCTAssertEqual(saved, look)
        XCTAssertEqual(gallery.edits.changes.map(\.path), [["widgetOverrides", "clock", "background"]])
        XCTAssertTrue(gallery.edits.everyTheme.isEmpty)
        XCTAssertEqual(store.customizationHistory.undoSteps.count, 1)
        try store.customizationHistory.undo()
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.packages.directory.appending(path: "my-phosphor/1.0.0").path))
        await gallery.refresh()
        await gallery.save(try XCTUnwrap(gallery.choices.first { $0.key == "phosphor" }), as: "My Phosphor", selecting: false)
        XCTAssertEqual(gallery.selectedKey, "phosphor")
        XCTAssertNil(try fixture.document()["profiles"]?.decoded([ConfigurationProfile].self).first { $0.name == "Phosphor edits" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.packages.directory.appending(path: "my-phosphor/1.0.1").path))
    }

    /// A name without ASCII letters or digits gives no theme id, so saving fails rather than inventing one. An id that
    /// belongs to a theme that comes with StableBar, such as Classic's, fails too.
    @MainActor func testSavingAThemeNamedWithoutLettersOrDigitsOrWithAReservedIDFails() async throws {
        for name in ["日本", "Classic", "Clear", "Nord"] {
            let fixture = try ThemeGalleryFixture(#"{"theme":{"id":"slim"},"widgets":[]}"#)
            defer { fixture.close() }
            let store = try fixture.store()
            defer { store.stop() }
            let before = try Data(contentsOf: fixture.url)
            let gallery = ThemeGallery(store: store)
            await gallery.refresh()
            await gallery.save(try XCTUnwrap(gallery.choices.first { $0.key == "slim" }), as: name)
            XCTAssertNotNil(gallery.error(for: "slim"), name)
            XCTAssertEqual(try Data(contentsOf: fixture.url), before)
            XCTAssertTrue(try fixture.packages.list().isEmpty)
            XCTAssertTrue(store.customizationHistory.undoSteps.isEmpty)
        }
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
        XCTAssertEqual(gallery.choices.map(\.key), ["clear", "glass", "tonal", "slim", "dot", "gloss", "sticker", "built-in"])
        XCTAssertEqual(gallery.previews.count, 8)
        gallery.select(try XCTUnwrap(gallery.choices.first { $0.key == "glass" }))
        XCTAssertEqual(gallery.selectedKey, "glass")
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
        XCTAssertNotNil(gallery.errors[entry.key])
        XCTAssertNil(gallery.previews[entry.key])
        await gallery.get(entry)
        XCTAssertTrue(gallery.errors[entry.key]?.contains("checksum") == true)
        XCTAssertNil(gallery.progress[entry.key])
        XCTAssertNil(store.customizationHistory.error)
        XCTAssertNil(store.configurationError)
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
        XCTAssertTrue(store.customizationHistory.undoSteps.isEmpty)
    }

    @MainActor func testAThemeColorEditIsTheThemesAndRevertReturnsToTheThemeEvenWhenItDoesNotRedefineIt() async throws {
        for themed in [false, true] {
            let fixture = try ThemeGalleryFixture(themed ? #"{"theme":{"id":"test-theme","version":"1"},"widgets":[]}"# : #"{"widgets":[]}"#)
            defer { fixture.close() }
            if themed { _ = try fixture.theme(#"{}"#) }
            let store = try fixture.store()
            defer { store.stop() }
            store.configurationStore.reloadConfiguration()
            let editor = ConfigurationEditor(store: store)
            let gallery = editor.gallery
            await gallery.refresh()
            XCTAssertTrue(gallery.edits.changes.isEmpty)
            editor.changeLook(ConfigurationEdit(action: .tokens, properties: ["text": .string("#123456")]))
            try editor.history.flush()
            gallery.configurationChanged()
            XCTAssertEqual(gallery.edits.changes.map(\.path), [["tokens", "text"]])
            editor.change(try XCTUnwrap(gallery.edits.revertEdit))
            gallery.configurationChanged()
            XCTAssertTrue(gallery.edits.changes.isEmpty)
            XCTAssertEqual(store.configuration?.defaults.foreground, HexColor(light: 0x1d1d1fff, dark: 0xf5f5f7ff))
            XCTAssertNil(try fixture.document()["profiles"])
            XCTAssertEqual(store.customizationHistory.undoSteps.count, 2)
        }
    }
    @MainActor func testSelectionOverridesAnIncludedThemeWithoutEditingTheInclude() async throws {
        let fixture = try ThemeGalleryFixture(#"{"includes":["included.json"],"widgets":[]}"#)
        defer { fixture.close() }
        let includedURL = fixture.directory.appending(path: "included.json")
        try fixture.write(#"{"theme":{"id":"phosphor"}}"#, to: includedURL)
        let included = try Data(contentsOf: includedURL)
        let store = try fixture.store()
        defer { store.stop() }
        let gallery = ThemeGallery(store: store)
        await gallery.refresh()
        gallery.select(try XCTUnwrap(gallery.choices.first { $0.key == "slim" }))
        XCTAssertEqual(gallery.selectedKey, "slim")
        XCTAssertEqual(store.configuration?.defaults.fontName, "Menlo")
        XCTAssertEqual(try Data(contentsOf: includedURL), included)
        XCTAssertEqual(store.customizationHistory.undoSteps.count, 1)
        try store.customizationHistory.undo()
        XCTAssertEqual(gallery.selectedKey, "phosphor")
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
        store.configurationStore.reloadConfiguration()
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
        XCTAssertTrue(store.widgetScripts.scripts.isEmpty)
        XCTAssertTrue(store.widgetScripts.providers.isEmpty)
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
            XCTAssertEqual(gallery.edits.everyTheme.map(\.path), [["tokens", "text"]])
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
                store.configurationStore.context.appearance = system
                store.configurationStore.context.app = "another app"
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
        XCTAssertNotNil(gallery.previews[entry.key])
        await gallery.loadStore()
        await gallery.refresh()
        XCTAssertEqual(calls.withLock { $0.count }, initialCount + 1)
    }

    @MainActor func testThemesAndAddWidgetChoicesIncludePrivateSources() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let index = LocalPackageIndex(fixture: fixture), acme = LocalPackageIndex(fixture: fixture, folder: "acme")
        _ = try await index.add()
        _ = try await acme.add(id: "acme-theme", configuration: #"{"bar":{"height":27}}"#, name: "Acme theme")
        let acmeSource = PackageSource(id: "acme", name: "Acme", url: acme.url)
        let store = try fixture.store()
        defer { store.stop() }
        let client = PackageStoreClient(packages: fixture.packages, indexURL: index.url)
        await client.setPrivateSources([acmeSource])
        let gallery = ThemeGallery(store: store, client: client)
        await gallery.refresh()
        await gallery.loadStore()
        XCTAssertFalse(gallery.storeUnavailable)
        XCTAssertEqual(gallery.storeThemes.map(\.key), ["stablebar:store-theme/1", "acme:acme-theme/1"])
        let acmeTheme = try XCTUnwrap(gallery.storeThemes.first { $0.sourceID == "acme" })
        XCTAssertEqual(gallery.previews[acmeTheme.key]?.light.bar.height, 27)
        XCTAssertEqual(gallery.sourceName("acme"), "Acme")
        await gallery.get(acmeTheme)
        XCTAssertNil(gallery.errors[acmeTheme.key])
        XCTAssertEqual(try fixture.packages.record(id: "acme-theme"), PackageInstallRecord(acmeSource))
        let installed = try XCTUnwrap(gallery.choices.first { $0.manifest.id == "acme-theme" })
        XCTAssertEqual(gallery.source(of: installed), .privateSource("Acme"))
        XCTAssertEqual(gallery.storeThemes.map(\.key), ["stablebar:store-theme/1"])
        // An author's folder build of version 2 is labelled as the folder's, not Acme's.
        let folder = fixture.directory.appending(path: "acme-theme-2")
        try fixture.write(#"{"id":"acme-theme","name":"Acme theme","version":"2","entry":"config.json","kind":"theme"}"#,
                          to: folder.appending(path: "package.json"))
        try fixture.write(#"{"bar":{"height":28}}"#, to: folder.appending(path: "config.json"))
        _ = try fixture.packages.install(folder)
        await gallery.refresh()
        let folderBuild = try XCTUnwrap(gallery.choices.first { $0.manifest.versionKey == "acme-theme/2" })
        XCTAssertEqual(gallery.source(of: folderBuild), .local)
        XCTAssertEqual(gallery.source(of: try XCTUnwrap(gallery.choices.first { $0.manifest.versionKey == "acme-theme/1" })),
                       .privateSource("Acme"))

        // The Add popover lists widgets from every source.
        let widgets = LocalPackageIndex(fixture: fixture, folder: "widgets"), acmeWidgets = LocalPackageIndex(fixture: fixture, folder: "acme-widgets")
        _ = try await widgets.add(id: "clock", kind: "widgets", configuration: #"{"widgets":[]}"#, name: "Clock")
        _ = try await acmeWidgets.add(id: "clock", kind: "widgets", configuration: #"{"widgets":[]}"#, name: "Clock")
        let widgetClient = PackageStoreClient(packages: fixture.packages, indexURL: widgets.url)
        await widgetClient.setPrivateSources([PackageSource(id: "acme", name: "Acme", url: acmeWidgets.url)])
        let choices = WidgetAddCatalog.compose(try await widgetClient.widgetChoices(), sourceNames: ["acme": "Acme"])
        XCTAssertEqual(choices.filter { $0.package != nil }.map(\.id), ["store/clock", "store/acme/clock"])
        let acmeClock = try XCTUnwrap(choices.first { $0.id == "store/acme/clock" })
        XCTAssertEqual(acmeClock.package?.sourceID, "acme")
        XCTAssertEqual(acmeClock.sourceName, "Acme")
        XCTAssertTrue(acmeClock.matches("Acme"))
        XCTAssertTrue(try XCTUnwrap(choices.first { $0.id == "store/clock" }).matches("Store"))
        XCTAssertFalse(try XCTUnwrap(choices.first { $0.id == "store/clock" }).matches("Acme"))
        let setup = WidgetSetup(store: store, client: widgetClient)
        await setup.load()
        XCTAssertFalse(setup.storeUnavailable)
        XCTAssertEqual(setup.choices.first { $0.id == "store/acme/clock" }?.sourceName, "Acme")
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
        store.configurationStore.reloadConfiguration()
        XCTAssertNotNil(store.configurationError)
        let gallery = ThemeGallery(store: store)
        await gallery.refresh()
        XCTAssertEqual(gallery.previews.count, gallery.choices.count)
        XCTAssertFalse(gallery.previews.isEmpty)
        XCTAssertNotNil(gallery.error(for: gallery.selectedKey))
        try fixture.write(#"{"widgets":[]}"#, to: fixture.url)
        store.configurationStore.reloadConfiguration()
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
        let error = try XCTUnwrap(actions.errors[entry.key])
        await actions.refreshTask?.value
        await actions.refresh()
        XCTAssertEqual(actions.errors[entry.key], error)
    }
}
