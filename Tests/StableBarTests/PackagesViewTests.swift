import AppKit
import SwiftUI
import XCTest
@testable import StableBar

final class PackagesViewTests: XCTestCase {
    @MainActor func testOneClickUpdatesPreserveSettingsPlacementHiddenWidgetsAndUndo() async throws {
        for enabled in [true, false] {
            let fixture = try ThemeGalleryFixture()
            defer { fixture.close() }
            let index = LocalPackageIndex(fixture: fixture)
            let settings = #"{"label":{"type":"string","default":"Default"},"units":{"type":"string","choices":["metric","imperial"],"default":"metric"}}"#
            _ = try await index.add(id: "note", kind: "widgets", configuration: #"{"widgets":[{"id":"note","type":"text","position":"left","text":"@setting.label"},{"id":"other","type":"text","position":"left","text":"Other"}]}"#, settings: settings)
            let old = try fixture.packages.install(fixture.directory.appending(path: "sources/note"))
            try fixture.write(#"{"packages":[{"id":"note","version":"1","enabled":\#(enabled),"settings":{"label":"Saved","units":"imperial"}}],"widgetOverrides":{"note":{"enabled":false,"display":"external"}},"profiles":[{"name":"Night","when":{"appearance":"dark"},"configuration":{"widgetOverrides":{"note":{"style":{"fontSize":18}}}}}],"widgets":[]}"#, to: fixture.url)
            if !enabled {
                var document = try fixture.document()
                document["widgetOverrides"] = nil
                document["profiles"] = nil
                try configurationData(document).write(to: fixture.url)
            }
            _ = try await index.add(id: "note", kind: "widgets", configuration: #"{"widgets":[{"id":"other","type":"text","position":"right","text":"New"},{"id":"note","type":"text","position":"right","text":"@setting.label"}]}"#, settings: settings.replacingOccurrences(of: #"["metric","imperial"]"#, with: #"["metric"]"#), version: "2")
            let store = try fixture.store()
            defer { store.stop() }
            let before = try fixture.document()
            let library = PackageLibrary(store: store, client: PackageStoreClient(packages: fixture.packages, indexURL: index.url))
            await library.loadInstalled()
            await library.loadStore()
            XCTAssertEqual(library.updates.map(\.id), ["note"])
            await library.update(old.manifest)
            XCTAssertNil(library.error)
            XCTAssertNil(library.pendingUpdate)
            XCTAssertTrue(library.updating.isEmpty)
            XCTAssertTrue(library.updates.isEmpty)
            let after = try fixture.document()
            let selection = try XCTUnwrap(after["packages"]?.decoded([WidgetPackageSelection].self).first)
            XCTAssertEqual(selection.version, "2")
            XCTAssertEqual(selection.enabled, enabled)
            XCTAssertEqual(selection.settings, ["label": .string("Saved"), "units": .string("metric")])
            XCTAssertEqual(after["profiles"], before["profiles"])
            if enabled {
                XCTAssertEqual(store.configuration?.widgets.map(\.id), ["note", "other"])
                let note = try XCTUnwrap(store.configuration?.widgets.first)
                XCTAssertFalse(note.enabled)
                XCTAssertEqual(note.position, .left)
                XCTAssertEqual(note.display, .external)
                XCTAssertEqual(note.content, .text("Saved"))
            } else {
                XCTAssertTrue(store.configuration!.widgets.isEmpty)
                XCTAssertEqual(after["widgetOverrides"], before["widgetOverrides"])
            }
            XCTAssertEqual(try fixture.packages.list().count, 2)
            try store.customizationHistory.undo()
            XCTAssertEqual(try fixture.document(), before)
        }
    }

    @MainActor func testUpdateReviewsAddedAccessAndKeepsInactivePackagesOffTheBar() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let index = LocalPackageIndex(fixture: fixture)
        _ = try await index.add(id: "note", kind: "widgets", configuration: #"{"widgets":[{"id":"note","type":"text","position":"left","text":"Old"}]}"#)
        let old = try fixture.packages.install(fixture.directory.appending(path: "sources/note"))
        _ = try await index.add(id: "note", kind: "widgets", configuration: #"{"widgets":[{"id":"note","type":"text","position":"left","text":"New"}]}"#, version: "2", hosts: #"["example.com"]"#)
        let store = try fixture.store()
        defer { store.stop() }
        let before = try fixture.document()
        let library = PackageLibrary(store: store, client: PackageStoreClient(packages: fixture.packages, indexURL: index.url))
        await library.loadInstalled()
        await library.loadStore()
        await library.update(old.manifest)
        XCTAssertEqual(library.updateAdditions, ["Host: example.com"])
        XCTAssertNotNil(library.pendingUpdate)
        XCTAssertEqual(try fixture.packages.list().count, 1)
        XCTAssertEqual(try fixture.document(), before)
        library.pendingUpdate = nil
        await library.update(old.manifest)
        await library.confirmUpdate(try XCTUnwrap(library.pendingUpdate))
        XCTAssertNil(library.error)
        XCTAssertTrue(library.updates.isEmpty)
        XCTAssertEqual(try fixture.packages.list().count, 2)
        XCTAssertEqual(try fixture.document(), before)
        XCTAssertTrue(store.customizationHistory.undoSteps.isEmpty)
    }

    @MainActor func testFailedUpdateLeavesTheSelectedThemeAndItsSettingsIntact() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let old = try fixture.theme(#"{"bar":{"height":30}}"#)
        try fixture.write(#"{"theme":{"id":"test-theme","version":"1"},"widgets":[]}"#, to: fixture.url)
        let index = LocalPackageIndex(fixture: fixture)
        _ = try await index.add(id: "test-theme", checksum: String(repeating: "0", count: 64), version: "2")
        let store = try fixture.store()
        defer { store.stop() }
        let before = try fixture.document()
        let client = PackageStoreClient(packages: fixture.packages, indexURL: index.url)
        let library = PackageLibrary(store: store, client: client)
        await library.loadInstalled()
        await library.loadStore()
        await library.update(old.manifest)
        XCTAssertNotNil(library.error)
        XCTAssertEqual(try fixture.document(), before)
        XCTAssertEqual(try fixture.packages.list().count, 1)
        _ = try await index.add(id: "test-theme", configuration: #"{"bar":{"height":35}}"#, version: "2")
        await library.loadStore(reload: true)
        await library.update(old.manifest)
        XCTAssertNil(library.error)
        XCTAssertEqual(store.configuration?.bar.height, 35)
        XCTAssertEqual(try fixture.document()["theme"]?.decoded(WidgetPackageSelection.self).version, "2")
    }

    @MainActor func testStorePreviewsDoNotInstallPackagesOrRunTheirCommands() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let index = LocalPackageIndex(fixture: fixture)
        let marker = fixture.directory.appending(path: "command-ran")
        let widget = try await index.add(id: "command-preview", kind: nil, configuration:
            #"{"widgets":[{"id":"script","type":"script","position":"right","command":"touch '\#(marker.path)'"}]}"#)
        let theme = try await index.add(configuration: #"{"bar":{"height":31}}"#)
        let store = try fixture.store()
        defer { store.stop() }
        let before = try Data(contentsOf: fixture.url)
        let library = PackageLibrary(store: store, client: PackageStoreClient(packages: fixture.packages, indexURL: index.url))
        await library.selectStore(widget)
        XCTAssertNil(library.draft?.themePreview)
        await library.selectStore(theme)
        XCTAssertEqual(library.draft?.themePreview?.light.bar.height, 31)
        XCTAssertEqual(library.draft?.themePreview?.dark.bar.height, 31)
        XCTAssertTrue(try fixture.packages.list().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
        XCTAssertTrue(store.customizationHistory.undoSteps.isEmpty)
    }

    @MainActor func testPackageSettingsSaveAcrossNavigationAsOneUndoStepAndCredentialsStayADraft() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let source = fixture.directory.appending(path: "weather")
        try fixture.write(#"""
        {"id":"weather","name":"Weather","version":"1","entry":"config.json",
         "settings":{"location":{"type":"string","default":"Paris"},"units":{"type":"string","choices":["metric","imperial"],"default":"metric"}}}
        """#, to: source.appending(path: "package.json"))
        try fixture.write(#"{"widgets":[{"id":"weather","type":"text","position":"right","text":"@setting.location"}]}"#,
                          to: source.appending(path: "config.json"))
        let installed = try fixture.packages.install(source)
        let other = try fixture.theme(#"{}"#)
        let store = try fixture.store()
        defer { store.stop() }
        _ = try WidgetSetup(store: store).enable(installed, settings: [:], position: .right)
        let before = try Data(contentsOf: fixture.url)
        let steps = store.customizationHistory.undoSteps.count
        let library = store.packageLibrary
        await library.loadInstalled()
        await library.selectInstalled(installed.manifest)
        let draft = try XCTUnwrap(library.draft)
        library.setSetting("location", value: .string("Z"), in: draft)
        library.setSetting("location", value: .string("Zurich"), in: draft)
        XCTAssertTrue(store.customizationHistory.hasPendingChanges)
        draft.secrets["token"] = "unsaved credential"
        await library.selectInstalled(other.manifest)
        await library.selectInstalled(installed.manifest)
        XCTAssertTrue(library.draft === draft)
        XCTAssertEqual(library.draft?.settings["location"], .string("Zurich"))
        XCTAssertEqual(library.draft?.secrets["token"], "unsaved credential")
        try store.customizationHistory.flush()
        XCTAssertEqual(store.customizationHistory.undoSteps.count, steps + 1)
        let saved = try XCTUnwrap(fixture.document()["packages"]?.decoded([WidgetPackageSelection].self).first)
        XCTAssertEqual(saved.settings["location"], .string("Zurich"))
        XCTAssertFalse(String(decoding: try Data(contentsOf: fixture.url), as: UTF8.self).contains("unsaved credential"))
        try store.customizationHistory.undo()
        library.configurationChanged()
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
        XCTAssertEqual(draft.settings["location"], .string("Paris"))
        XCTAssertEqual(draft.secrets["token"], "unsaved credential")
        try store.setSessionEdits([.init(action: .package, properties: [
            "id": .string("weather"), "version": .string("1"),
            "settings": .object(["location": .string("Temporary")])
        ])])
        library.configurationChanged()
        XCTAssertEqual(draft.settings["location"], .string("Paris"))
        XCTAssertEqual(store.configuration?.widgets.first?.content, .text("Temporary"))
        library.setSetting("units", value: .string("imperial"), in: draft)
        library.configurationChanged()
        XCTAssertEqual(draft.settings, ["location": .string("Paris"), "units": .string("imperial")])
        try store.customizationHistory.flush()
        let savedWithSession = try XCTUnwrap(fixture.document()["packages"]?.decoded([WidgetPackageSelection].self).first)
        XCTAssertEqual(savedWithSession.settings, ["location": .string("Paris"), "units": .string("imperial")])
        XCTAssertEqual(store.configuration?.widgets.first?.content, .text("Temporary"))
        XCTAssertEqual(store.sessionEdits.count, 1)
        draft.inspectionTask?.cancel()
    }

    @MainActor func testRemovingAnAddedPackageFromTheBarDropsItsWidgetOverrides() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let source = fixture.directory.appending(path: "note")
        try fixture.write(#"{"id":"note","name":"Note","version":"1","entry":"config.json"}"#, to: source.appending(path: "package.json"))
        try fixture.write(#"{"widgets":[{"id":"note","type":"text","position":"right","text":"Note"}]}"#,
                          to: source.appending(path: "config.json"))
        let installed = try fixture.packages.install(source)
        let store = try fixture.store()
        defer { store.stop() }
        _ = try WidgetSetup(store: store).enable(installed, settings: [:], position: .left)
        XCTAssertNotNil(try fixture.document()["widgetOverrides"])
        let library = store.packageLibrary
        await library.loadInstalled()
        await library.selectInstalled(installed.manifest)
        let draft = try XCTUnwrap(library.draft)
        library.deactivate(draft)
        XCTAssertNil(draft.error)
        XCTAssertNil(try fixture.document()["widgetOverrides"])
        XCTAssertEqual(store.configuration?.widgets.map(\.id), [])
    }

    @MainActor func testReviewingANewVersionCarriesCompatibleSettingsAndKeepsItsDraft() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let source = fixture.directory.appending(path: "weather")
        let manifest = #"{"id":"weather","name":"Weather","version":"VERSION","entry":"config.json","settings":{"location":{"type":"string","default":"Default"},"units":{"type":"string","choices":CHOICES,"default":"metric"}}}"#
        try fixture.write(manifest.replacingOccurrences(of: "VERSION", with: "1").replacingOccurrences(of: "CHOICES", with: #"["metric","imperial"]"#),
                          to: source.appending(path: "package.json"))
        try fixture.write(#"{"widgets":[{"id":"weather","type":"text","position":"right","text":"@setting.location"}]}"#,
                          to: source.appending(path: "config.json"))
        let old = try fixture.packages.install(source)
        let store = try fixture.store()
        defer { store.stop() }
        _ = try WidgetSetup(store: store).enable(old, settings: ["location": .string("Zurich"), "units": .string("imperial")], position: .left)
        try fixture.write(manifest.replacingOccurrences(of: "VERSION", with: "2").replacingOccurrences(of: "CHOICES", with: #"["metric"]"#),
                          to: source.appending(path: "package.json"))
        let updated = try fixture.packages.install(source)
        let library = store.packageLibrary
        await library.loadInstalled()
        await library.selectInstalled(updated.manifest)
        let draft = try XCTUnwrap(library.draft)
        XCTAssertEqual(draft.settings, ["location": .string("Zurich"), "units": .string("metric")])
        library.setSetting("location", value: .string("Bern"), in: draft)
        XCTAssertFalse(store.customizationHistory.hasPendingChanges)
        await library.selectInstalled(old.manifest)
        await library.selectInstalled(updated.manifest)
        XCTAssertEqual(library.draft?.settings["location"], .string("Bern"))
        await library.add(draft)
        XCTAssertNil(draft.error)
        let selected = try XCTUnwrap(fixture.document()["packages"]?.decoded([WidgetPackageSelection].self).first)
        XCTAssertEqual(selected.version, "2")
        XCTAssertEqual(selected.settings, ["location": .string("Bern"), "units": .string("metric")])
        XCTAssertEqual(store.configuration?.widgets.first?.position, .left)
        XCTAssertEqual(store.configuration?.widgets.first?.content, .text("Bern"))
    }

    @MainActor func testStoreListingDoesNotClaimInstalledPackageOrigin() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let index = LocalPackageIndex(fixture: fixture)
        let entry = try await index.add(id: "listed", kind: "widgets", configuration: #"{"widgets":[]}"#, version: "2")
        func folder(_ id: String, _ version: String) throws -> URL {
            let source = fixture.directory.appending(path: "folders/\(id)-\(version)")
            try fixture.write(#"{"id":"\#(id)","name":"\#(id)","version":"\#(version)","kind":"widgets","entry":"config.json"}"#,
                              to: source.appending(path: "package.json"))
            try fixture.write(#"{"widgets":[]}"#, to: source.appending(path: "config.json"))
            return source
        }
        let older = try fixture.packages.install(folder("listed", "1")).manifest
        let newer = try fixture.packages.install(folder("listed", "3")).manifest
        let unlisted = try fixture.packages.install(folder("unlisted", "1")).manifest
        let store = try fixture.store()
        defer { store.stop() }
        let library = PackageLibrary(store: store, client: PackageStoreClient(packages: fixture.packages, indexURL: index.url))
        await library.loadInstalled()
        XCTAssertEqual(library.source(of: older), .installed)
        await library.loadStore()
        XCTAssertEqual(library.source(of: older), .listed)
        XCTAssertEqual(library.source(of: newer), .listed)
        XCTAssertEqual(library.source(of: unlisted), .installed)
        await library.selectStore(entry)
        XCTAssertEqual(library.draft.map { library.source($0) }, .store)
        await library.select(try folder("listed", "1"))
        XCTAssertEqual(library.draft.map { library.source($0) }, .local)
        let installed = try fixture.packages.install(folder("listed", "2"))
        let review = PackageLibrary(store: store, client: PackageStoreClient(packages: fixture.packages, indexURL: index.url), reviewing: true)
        let installedDraft = PackageDraft(inspection: installed, settings: [:])
        XCTAssertEqual(review.source(installedDraft), .installed)
        await review.loadStore()
        XCTAssertEqual(review.source(installedDraft), .listed)
        await review.selectStore(entry)
        XCTAssertEqual(review.draft.map { review.source($0) }, .listed)
        let downloaded = try await PackageStoreClient(packages: fixture.packages, indexURL: index.url).package(entry)
        XCTAssertEqual(review.source(PackageDraft(inspection: downloaded, settings: [:])), .store)
        try fixture.write(#"{"packages":[]}"#, to: index.url)
        await library.loadStore(reload: true)
        XCTAssertEqual(library.source(of: installed.manifest), .installed)
    }

    @MainActor func testPackagesBrowserOpensInstalledPackageSettingsFromSelection() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let theme = try fixture.theme(#"{}"#, install: false)
        try fixture.write(#"""
        {"id":"test-theme","name":"Test theme","version":"1","kind":"theme","entry":"config.json",
         "settings":{"caption":{"type":"string","default":"Ready to customize"}}}
        """#, to: theme.directory.appending(path: "package.json"))
        _ = try fixture.packages.install(theme.directory)
        let index = fixture.directory.appending(path: "index.json")
        try fixture.write(#"{"packages":[]}"#, to: index)
        let store = try fixture.store()
        defer { store.stop() }
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 620),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: PackagesView(store: store, indexURL: index, selectedPackageID: "test-theme"))
        host.sizingOptions = []
        window.contentView = host
        for _ in 0..<30 {
            host.layoutSubtreeIfNeeded()
            if textFields(host).contains("Ready to customize") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let table = try XCTUnwrap(tables(in: host).first)
        XCTAssertEqual(table.numberOfRows, 4)
        XCTAssertEqual(table.selectedRow, 1)
        XCTAssertTrue(textFields(host).contains("Ready to customize"))
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(store.customizationHistory.undoSteps.isEmpty)
    }

    @MainActor func testCommandPackageReviewLoadsInAnUnorderedWindow() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let source = fixture.directory.appending(path: "review")
        try fixture.write(#"""
        {"id":"review","name":"Review package","version":"1","entry":"config.json",
         "permissions":["automation"],"hosts":["example.com"],
         "settings":{"message":{"type":"string","title":"Message","default":"Hello"}}}
        """#, to: source.appending(path: "package.json"))
        try fixture.write(#"{"widgets":[{"id":"note","type":"text","text":"@setting.message","position":"left","onClick":"echo reviewed"}]}"#,
                          to: source.appending(path: "config.json"))
        let inspection = try fixture.packages.inspect(source)
        let store = try fixture.store()
        defer { store.stop() }
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 680, height: 620),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: PackagesView(store: store, reviewing: inspection, onEnable: { _, _ in }))
        host.sizingOptions = []
        window.contentView = host
        for _ in 0..<30 {
            host.layoutSubtreeIfNeeded()
            if textFields(host).contains("echo reviewed") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let text = textFields(host)
        for expected in ["echo reviewed", "Automation", "example.com", "Hello"] {
            XCTAssertTrue(text.contains { $0.contains(expected) }, "Review is missing \(expected): \(text)")
        }
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(try fixture.packages.list().isEmpty)
        XCTAssertTrue(store.customizationHistory.undoSteps.isEmpty)
    }

    @MainActor func testAddWidgetPopoverLoadsTheCommandReviewAfterChoosingAPackage() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let index = LocalPackageIndex(fixture: fixture)
        _ = try await index.add(id: "commands", kind: nil,
            configuration: #"{"widgets":[{"id":"note","type":"text","position":"right","text":"Hello","onClick":"echo from add"}]}"#)
        let store = try fixture.store()
        defer { store.stop() }
        let setup = WidgetSetup(store: store, client: PackageStoreClient(packages: fixture.packages, indexURL: index.url))
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 680, height: 620),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let model = WidgetAddPopoverModel(setup: setup, position: .left, before: nil, added: { _ in
            XCTFail("Commands must be reviewed before adding")
        })
        let host = NSHostingView(rootView: WidgetAddPopoverView(model: model, store: store))
        host.sizingOptions = []
        window.contentView = host
        for _ in 0..<50 {
            host.layoutSubtreeIfNeeded()
            if setup.choices.contains(where: { $0.package?.id == "commands" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let choice = try XCTUnwrap(setup.choices.first { $0.package?.id == "commands" })
        let added = await setup.add(choice, to: .left)
        XCTAssertNil(added)
        for _ in 0..<30 {
            host.layoutSubtreeIfNeeded()
            if textFields(host).contains("echo from add") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(textFields(host).contains("echo from add"))
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(try fixture.packages.list().isEmpty)
        XCTAssertTrue(store.customizationHistory.undoSteps.isEmpty)
    }

    @MainActor private func textFields(_ view: NSView) -> [String] {
        (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(textFields)
    }

    @MainActor private func tables(in view: NSView) -> [NSTableView] {
        (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables)
    }
}
