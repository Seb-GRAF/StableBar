import AppKit
import SwiftUI
import XCTest
@testable import StableBar

final class PackagesViewTests: XCTestCase {
    @MainActor func testStoreEssentialsBecomeBuiltInAndKeepEditingAndUndo() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let index = LocalPackageIndex(fixture: fixture)
        let configuration = #"{"widgets":[{"id":"date","type":"clock","position":"right","format":"@setting.format","open":"com.apple.iCal"}]}"#
        let settings = #"{"format":{"type":"string","default":"EEE d MMM"}}"#
        _ = try await index.add(id: "date", kind: "widgets", configuration: configuration, settings: settings)
        let installed = try fixture.packages.install(fixture.directory.appending(path: "sources/date"),
            record: PackageInstallRecord(source: PackageSource.storeID, name: PackageSource.store.name, url: PackageSource.store.url))
        try fixture.write(#"{"packages":[{"id":"date","version":"1","settings":{"format":"yyyy-MM-dd"}}],"profiles":[{"name":"work","configuration":{}}]}"#, to: fixture.url)
        let store = try fixture.store()
        defer { store.stop() }
        try store.applyEdits([], persist: false)
        let library = PackageLibrary(store: store, client: PackageStoreClient(packages: fixture.packages, indexURL: index.url))
        defer { library.stopUpdateChecks() }
        _ = try await index.add(id: "date", kind: "widgets", configuration: configuration, settings: settings, version: "2")
        await library.loadInstalled()
        await library.loadStore()
        XCTAssertEqual(store.builtInWidgetIDs, ["date"])
        XCTAssertEqual(library.origin(of: installed.manifest), .builtIn)
        XCTAssertTrue(library.installedPackages.isEmpty)
        XCTAssertTrue(library.storeEntries(showingThemes: false, sourceID: nil).isEmpty)
        XCTAssertTrue(library.updates.isEmpty)
        let editor = ConfigurationEditor(store: store)
        editor.editBar(for: "work")
        let before = try fixture.document()
        editor.set(["format": .string("HH:mm")], for: "date")
        try editor.history.flush()
        XCTAssertNil(editor.error)
        XCTAssertEqual(store.configuration?.widgets.first?.content, .clock(format: "HH:mm"))
        XCTAssertEqual(try fixture.document()["packages"], before["packages"])
        editor.undo()
        XCTAssertEqual(try fixture.document(), before)
        XCTAssertEqual(store.configuration?.widgets.first?.content, .clock(format: "yyyy-MM-dd"))
        editor.endProfileEditing()
        try WidgetSetup(store: store).remove("date")
        XCTAssertTrue(store.configuration!.widgets.isEmpty)
        try store.customizationHistory.undo()
        XCTAssertEqual(store.configuration?.widgets.map(\.id), ["date"])
        XCTAssertEqual(try fixture.packages.list().count, 1)
    }

    @MainActor func testEssentialsHideStoreDuplicatesButKeepLocalCopyUpdates() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let index = LocalPackageIndex(fixture: fixture)
        _ = try await index.add(id: "date", kind: "widgets", configuration: #"{"widgets":[]}"#)
        let store = try fixture.store()
        defer { store.stop() }
        let library = PackageLibrary(store: store, client: PackageStoreClient(packages: fixture.packages, indexURL: index.url))
        defer { library.stopUpdateChecks() }
        await library.loadInstalled()
        await library.loadStore()
        XCTAssertTrue(library.storeEntries(showingThemes: false, sourceID: nil).isEmpty)
        let old = try fixture.packages.install(fixture.directory.appending(path: "sources/date"))
        _ = try await index.add(id: "date", kind: "widgets", configuration: #"{"widgets":[]}"#, version: "2")
        await library.loadInstalled()
        await library.loadStore(reload: true)
        XCTAssertEqual(library.storeEntries(showingThemes: false, sourceID: nil).map(\.id), ["date"])
        XCTAssertEqual(library.updates.map(\.id), ["date"])
        await library.update(old.manifest)
        XCTAssertNil(library.error)
        XCTAssertEqual(try fixture.packages.list().map(\.versionKey), ["date/1", "date/2"])
    }

    @MainActor func testPackageUpdateNoticesPersistDismissalAndReturnOnlyForNewVersions() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let suite = "StableBarPackageNotices-\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let index = LocalPackageIndex(fixture: fixture)
        _ = try await index.add(id: "note", kind: "widgets", configuration: #"{"widgets":[]}"#)
        let old = try fixture.packages.install(fixture.directory.appending(path: "sources/note"))
        _ = try await index.add(id: "note", kind: "widgets", configuration: #"{"widgets":[]}"#, version: "2")
        let store = try fixture.store()
        defer { store.stop() }
        let client = PackageStoreClient(packages: fixture.packages, indexURL: index.url)
        let library = PackageLibrary(store: store, client: client, preferences: preferences)
        defer { library.stopUpdateChecks() }
        await library.loadInstalled()
        await library.loadStore()
        XCTAssertNotNil(library.updateWidget)
        library.dismissUpdates()
        XCTAssertNil(library.updateWidget)
        XCTAssertEqual(library.updates.map(\.id), ["note"])
        let reopened = PackageLibrary(store: store, client: client, preferences: preferences)
        defer { reopened.stopUpdateChecks() }
        await reopened.loadInstalled()
        await reopened.loadStore()
        XCTAssertNil(reopened.updateWidget)
        _ = try await index.add(id: "note", kind: "widgets", configuration: #"{"widgets":[]}"#, version: "3")
        await reopened.loadStore(reload: true)
        XCTAssertNotNil(reopened.updateWidget)
        reopened.notifiesAboutUpdates = false
        XCTAssertNil(reopened.updateWidget)
        XCTAssertFalse(PackageLibrary(store: store, client: client, preferences: preferences).notifiesAboutUpdates)
        reopened.notifiesAboutUpdates = true
        XCTAssertNotNil(reopened.updateWidget)
        var opened = false
        store.onCustomizePackages = { opened = true }
        reopened.showingStore = true
        reopened.search = "unrelated"
        reopened.openUpdates()
        XCTAssertTrue(opened)
        XCTAssertFalse(reopened.showingStore)
        XCTAssertEqual(reopened.search, "")
        await reopened.update(old.manifest)
        XCTAssertNil(reopened.error)
        XCTAssertNil(reopened.updateWidget)
        XCTAssertTrue(reopened.updates.isEmpty)
    }

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

    /// The update reviews the source's download, so a folder copy of the new version is used only when it has those files.
    @MainActor func testUpdateOverAFolderCopyOfTheNewVersionNeedsTheSourcesFiles() async throws {
        for identical in [false, true] {
            let fixture = try ThemeGalleryFixture()
            defer { fixture.close() }
            let index = LocalPackageIndex(fixture: fixture)
            _ = try await index.add(id: "note", kind: "widgets", configuration: #"{"widgets":[{"id":"note","type":"text","position":"left","text":"Old"}]}"#, name: "Note")
            let old = try fixture.packages.install(fixture.directory.appending(path: "sources/note"))
            try fixture.write(#"{"packages":[{"id":"note","version":"1","enabled":true}],"widgets":[]}"#, to: fixture.url)
            _ = try await index.add(id: "note", kind: "widgets", configuration: #"{"widgets":[{"id":"note","type":"text","position":"left","text":"New"}]}"#,
                                    version: "2", name: "Note")
            // Version 2 opened from a folder: the Store's files, or the same version with a host added.
            let folder = fixture.directory.appending(path: "folder-note")
            try FileManager.default.copyItem(at: fixture.directory.appending(path: "sources/note"), to: folder)
            if !identical {
                let manifest = folder.appending(path: "package.json")
                try fixture.write(String(decoding: try Data(contentsOf: manifest), as: UTF8.self)
                    .replacingOccurrences(of: #""hosts":[]"#, with: #""hosts":["example.com"]"#), to: manifest)
                XCTAssertEqual(try fixture.packages.inspect(folder).manifest.hosts, ["example.com"])
            }
            _ = try fixture.packages.install(folder)
            XCTAssertEqual(try fixture.packages.record(id: "note"), .local)
            let store = try fixture.store()
            defer { store.stop() }
            let library = PackageLibrary(store: store, client: PackageStoreClient(packages: fixture.packages, indexURL: index.url))
            defer { library.stopUpdateChecks() }
            await library.loadInstalled()
            await library.loadStore()
            await library.update(old.manifest)
            XCTAssertNil(library.pendingUpdate)
            let selected = try XCTUnwrap(fixture.document()["packages"]?.decoded([WidgetPackageSelection].self).first)
            if identical {
                XCTAssertNil(library.error)
                XCTAssertEqual(selected.version, "2")
                XCTAssertEqual(try fixture.packages.record(id: "note")?.source, PackageSource.storeID)
            } else {
                XCTAssertEqual(library.error, "Note 2 is already installed from a folder with different files. Uninstall it before getting it from StableBar Store.")
                XCTAssertEqual(selected.version, "1")
                XCTAssertEqual(try fixture.packages.record(id: "note"), .local)
            }
        }
    }

    @MainActor func testAddingFromAPrivateSourceRecordsThatSource() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let index = LocalPackageIndex(fixture: fixture), acme = LocalPackageIndex(fixture: fixture, folder: "acme")
        _ = try await index.add(id: "clock", kind: "widgets", configuration: #"{"widgets":[]}"#, name: "Clock")
        _ = try await acme.add(id: "clock", kind: "widgets", configuration: #"{"widgets":[{"id":"clock","type":"text","position":"right","text":"Acme"}]}"#, name: "Clock")
        let store = try fixture.store()
        defer { store.stop() }
        let client = PackageStoreClient(packages: fixture.packages, indexURL: index.url)
        let source = PackageSource(id: "acme", name: "Acme", url: acme.url)
        await client.setPrivateSources([source])
        let library = PackageLibrary(store: store, client: client)
        defer { library.stopUpdateChecks() }
        await library.loadInstalled()
        await library.loadStore()
        let entry = try XCTUnwrap(library.entries.first { $0.sourceID == "acme" })
        await library.selectStore(entry)
        let draft = try XCTUnwrap(library.draft)
        await library.add(draft)
        XCTAssertNil(draft.error)
        XCTAssertNil(library.error)
        XCTAssertEqual(try fixture.packages.list().map(\.versionKey), ["clock/1"])
        XCTAssertEqual(try fixture.packages.record(id: "clock"), PackageInstallRecord(source))
    }

    @MainActor func testUpdatesRecordTheSourceThatListsThem() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let index = LocalPackageIndex(fixture: fixture), acme = LocalPackageIndex(fixture: fixture, folder: "acme")
        let empty = #"{"widgets":[]}"#
        _ = try await index.add(id: "note", kind: "widgets", configuration: empty, name: "Note")
        // Recorded by the Store under an old name, which the update refreshes.
        let stale = PackageInstallRecord(source: PackageSource.storeID, name: "Old Store", url: nil)
        let note = try fixture.packages.install(fixture.directory.appending(path: "sources/note"), record: stale, requestedName: "Old Store")
        _ = try await acme.add(id: "clock", kind: "widgets", configuration: empty, name: "Clock")
        let source = PackageSource(id: "acme", name: "Acme", url: acme.url)
        // Installed from Acme under an old name, which the update refreshes. Only Acme can update it.
        let clock = try fixture.packages.install(fixture.directory.appending(path: "sources/clock"),
                                                 record: PackageInstallRecord(source: "acme", name: "Old Acme", url: nil), requestedName: "Old Acme")
        _ = try await index.add(id: "note", kind: "widgets", configuration: empty, version: "2", name: "Note")
        _ = try await acme.add(id: "clock", kind: "widgets", configuration: empty, version: "2", name: "Clock")
        let store = try fixture.store()
        defer { store.stop() }
        let client = PackageStoreClient(packages: fixture.packages, indexURL: index.url)
        await client.setPrivateSources([source])
        let library = PackageLibrary(store: store, client: client)
        defer { library.stopUpdateChecks() }
        await library.loadInstalled()
        await library.loadStore()
        XCTAssertEqual(Set(library.updates.map(\.id)), ["note", "clock"])
        await library.update(note.manifest)
        XCTAssertNil(library.error)
        let configuredStore = await client.source(id: PackageSource.storeID)
        let storeSource = try XCTUnwrap(configuredStore)
        XCTAssertEqual(try fixture.packages.record(id: "note"), PackageInstallRecord(storeSource))
        await library.update(clock.manifest)
        XCTAssertNil(library.error)
        XCTAssertEqual(try fixture.packages.record(id: "clock"), PackageInstallRecord(source))
        XCTAssertEqual(try fixture.packages.list().map(\.versionKey), ["clock/1", "clock/2", "note/1", "note/2"])
    }

    @MainActor func testUpdatesComeOnlyFromTheInstalledSource() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let index = LocalPackageIndex(fixture: fixture), acme = LocalPackageIndex(fixture: fixture, folder: "acme")
        let empty = #"{"widgets":[]}"#
        // The Store lists note 2 and Acme lists note 3; note 1 is installed.
        _ = try await index.add(id: "note", kind: "widgets", configuration: empty, name: "Note")
        let installed = try fixture.packages.install(fixture.directory.appending(path: "sources/note"))
        _ = try await index.add(id: "note", kind: "widgets", configuration: empty, version: "2", name: "Note")
        _ = try await acme.add(id: "note", kind: "widgets", configuration: empty, version: "3", name: "Note")
        let store = try fixture.store()
        defer { store.stop() }
        let client = PackageStoreClient(packages: fixture.packages, indexURL: index.url)
        let acmeSource = PackageSource(id: "acme", name: "Acme", url: acme.url)
        await client.setPrivateSources([acmeSource])
        let library = PackageLibrary(store: store, client: client)
        defer { library.stopUpdateChecks() }
        let recordURL = fixture.directory.appending(path: "packages/note/\(PackageInstallRecord.fileName)")
        let cases: [(PackageInstallRecord?, String?, String?)] = [
            (nil, "2", PackageSource.storeID), (.local, "2", PackageSource.storeID),
            (PackageInstallRecord(source: PackageSource.storeID, name: nil, url: nil), "2", PackageSource.storeID),
            (PackageInstallRecord(acmeSource), "3", "acme"),
            (PackageInstallRecord(source: "gone", name: "Gone", url: nil), nil, nil)
        ]
        for (record, expected, sourceID) in cases {
            if let record {
                try JSONEncoder().encode(record).write(to: recordURL)
            } else {
                try FileManager.default.removeItem(at: recordURL)
            }
            await library.loadInstalled()
            await library.loadStore()
            let label = record?.source ?? "no record"
            XCTAssertEqual(library.updateSourceID(for: installed.manifest), sourceID, label)
            XCTAssertEqual(library.update(for: installed.manifest)?.version, expected, label)
            XCTAssertEqual(library.update(for: installed.manifest)?.sourceID, sourceID, label)
            XCTAssertEqual(library.updates.map(\.id), expected == nil ? [] : ["note"], label)
        }
    }

    @MainActor func testStoreCardsAndDraftsKeepSourcesApart() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let index = LocalPackageIndex(fixture: fixture), acme = LocalPackageIndex(fixture: fixture, folder: "acme")
        // Clock 1 is in both indexes and installed with a Acme record.
        _ = try await index.add(id: "clock", kind: "widgets",
                                configuration: #"{"widgets":[{"id":"clock","type":"text","position":"right","text":"Store"}]}"#, name: "Clock")
        _ = try await acme.add(id: "clock", kind: "widgets",
                               configuration: #"{"widgets":[{"id":"clock","type":"text","position":"right","text":"Acme"}]}"#, name: "Clock")
        let acmeSource = PackageSource(id: "acme", name: "Acme", url: acme.url)
        let installed = try fixture.packages.install(fixture.directory.appending(path: "sources/clock"),
                                                     record: PackageInstallRecord(acmeSource), requestedName: "Acme")
        let store = try fixture.store()
        defer { store.stop() }
        let client = PackageStoreClient(packages: fixture.packages, indexURL: index.url)
        await client.setPrivateSources([acmeSource])
        let library = PackageLibrary(store: store, client: client)
        defer { library.stopUpdateChecks() }
        await library.loadInstalled()
        await library.loadStore()
        let storeClock = try XCTUnwrap(library.entries.first { $0.sourceID == PackageSource.storeID })
        let acmeClock = try XCTUnwrap(library.entries.first { $0.sourceID == "acme" })
        XCTAssertEqual(library.installedElsewhere(storeClock), "Acme")
        XCTAssertNil(library.installedElsewhere(acmeClock))
        let refusal = "Clock is installed from Acme. Uninstall it before getting it from StableBar Store."
        await library.get(storeClock)
        XCTAssertEqual(library.error, refusal)
        XCTAssertTrue(library.getting.isEmpty)
        XCTAssertEqual(try fixture.packages.record(id: "clock"), PackageInstallRecord(acmeSource))
        // A Store draft reviews the Store's files and can't enable the version Acme installed.
        await library.selectStore(storeClock)
        let refused = try XCTUnwrap(library.draft)
        XCTAssertEqual(refused.sourceID, PackageSource.storeID)
        XCTAssertNotEqual(refused.inspection.directory, installed.directory)
        XCTAssertEqual(refused.inspection.widgets.first?.content, .text("Store"))
        let before = try Data(contentsOf: fixture.url)
        await library.add(refused)
        XCTAssertEqual(refused.error, refusal)
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
        XCTAssertEqual(try fixture.packages.record(id: "clock"), PackageInstallRecord(acmeSource))
        // Uninstall, then select both Store entries: each draft keeps its own sourceID and directory.
        await library.uninstall(installed.manifest)
        XCTAssertNil(try fixture.packages.record(id: "clock"))
        await library.selectStore(acmeClock)
        let first = try XCTUnwrap(library.draft)
        await library.selectStore(storeClock)
        let second = try XCTUnwrap(library.draft)
        XCTAssertEqual([first.sourceID, second.sourceID], ["acme", "stablebar"])
        XCTAssertNotEqual(first.inspection.directory, second.inspection.directory)
        XCTAssertEqual(first.inspection.widgets.first?.content, .text("Acme"))
        XCTAssertEqual(library.origin(first), .privateSource("Acme"))
        XCTAssertEqual(library.origin(second), .store)
        // A folder install of Acme's files under the same version: the Store draft's files differ, so adding it is refused
        // rather than enabling unreviewed files under the Store's name.
        _ = try fixture.packages.install(fixture.directory.appending(path: "sources/clock"))
        await library.loadInstalled()
        let unchanged = try Data(contentsOf: fixture.url)
        await library.add(second)
        XCTAssertEqual(second.error, "Clock 1 is already installed from a folder with different files. Uninstall it before getting it from StableBar Store.")
        XCTAssertEqual(try fixture.packages.record(id: "clock"), .local)
        XCTAssertEqual(try Data(contentsOf: fixture.url), unchanged)
        // Selecting the Store's entry over the unclaimed copy reviews the Store's download, not the installed files.
        await library.selectStore(storeClock)
        let reviewed = try XCTUnwrap(library.draft)
        XCTAssertEqual(reviewed.inspection.widgets.first?.content, .text("Store"))
        await library.add(reviewed)
        XCTAssertNotNil(reviewed.error)
        XCTAssertEqual(try fixture.packages.record(id: "clock"), .local)
        // Acme's draft has the installed files, so adding it claims the copy for Acme, as Get does.
        await library.add(first)
        XCTAssertNil(first.error)
        XCTAssertEqual(try fixture.packages.record(id: "clock")?.source, "acme")
    }

    /// A folder version under an ID Acme owns stays the folder's: labelled Local folder, never reused for Acme's entry
    /// of that version, and claimed for Acme only when it has Acme's files.
    @MainActor func testFolderVersionsOfAnIDASourceOwnsKeepTheirOwnOrigin() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let acme = LocalPackageIndex(fixture: fixture, folder: "acme")
        let configuration = #"{"widgets":[{"id":"clock","type":"text","position":"right","text":"Acme"}]}"#
        _ = try await acme.add(id: "clock", kind: "widgets", configuration: configuration, name: "Clock")
        let acmeSource = PackageSource(id: "acme", name: "Acme", url: acme.url)
        let published = fixture.directory.appending(path: "sources/clock")
        let first = try fixture.packages.install(published, record: PackageInstallRecord(acmeSource), requestedName: "Acme")
        _ = try await acme.add(id: "clock", kind: "widgets", configuration: configuration, version: "2", name: "Clock")
        // An author's folder build of version 2, with a file Acme's doesn't have.
        let folder = fixture.directory.appending(path: "folder")
        try FileManager.default.copyItem(at: published, to: folder)
        try fixture.write("draft", to: folder.appending(path: "notes.txt"))
        let second = try fixture.packages.install(folder)
        var owned = PackageInstallRecord(acmeSource)
        owned.localVersions = ["2"]
        XCTAssertEqual(try fixture.packages.record(id: "clock"), owned)
        let store = try fixture.store()
        defer { store.stop() }
        let client = PackageStoreClient(packages: fixture.packages, indexURL: fixture.directory.appending(path: "none/index.json"))
        await client.setPrivateSources([acmeSource])
        let library = PackageLibrary(store: store, client: client)
        defer { library.stopUpdateChecks() }
        await library.loadInstalled()
        await library.loadStore()
        let entry = try XCTUnwrap(library.entries.first { $0.sourceID == "acme" && $0.version == "2" })
        XCTAssertEqual(library.origin(of: second.manifest), .local)
        XCTAssertEqual(library.origin(of: first.manifest), .privateSource("Acme"))
        XCTAssertEqual(library.updateSourceID(for: second.manifest), "acme")
        // Acme's entry for version 2 reviews Acme's download, not the folder's files.
        let reviewed = try await client.packageForAdding(entry)
        XCTAssertNotEqual(reviewed.directory, second.directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reviewed.directory.appending(path: "notes.txt").path))
        // Updating to, or adding, Acme's version 2 doesn't put the folder's files under Acme's name.
        let refusal = "Clock 2 is already installed from a folder with different files. Uninstall it before getting it from Acme."
        await library.update(first.manifest)
        XCTAssertEqual(library.error, refusal)
        let draft = PackageDraft(inspection: reviewed, settings: [:])
        draft.sourceID = "acme"
        await library.add(draft)
        XCTAssertEqual(draft.error, refusal)
        XCTAssertEqual(try fixture.packages.record(id: "clock"), owned)
        // With Acme's own files, adding claims the folder's version for Acme.
        try FileManager.default.removeItem(at: second.directory.appending(path: "notes.txt"))
        await library.add(draft)
        XCTAssertNil(draft.error)
        XCTAssertEqual(try fixture.packages.record(id: "clock"), PackageInstallRecord(acmeSource))
        XCTAssertEqual(library.origin(of: second.manifest), .privateSource("Acme"))
    }

    /// The other order: a folder installs version 1, then Acme claims the ID with version 2. Version 1 stays the folder's
    /// until Acme's own files for it are added.
    @MainActor func testASourceClaimingAFolderIDLeavesItsOtherVersionsLocal() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let acme = LocalPackageIndex(fixture: fixture, folder: "acme")
        let configuration = #"{"widgets":[{"id":"clock","type":"text","position":"right","text":"Acme"}]}"#
        _ = try await acme.add(id: "clock", kind: "widgets", configuration: configuration, name: "Clock")
        let acmeSource = PackageSource(id: "acme", name: "Acme", url: acme.url)
        // An author's folder build of version 1, with a file Acme's doesn't have.
        let folder = fixture.directory.appending(path: "folder")
        try FileManager.default.copyItem(at: fixture.directory.appending(path: "sources/clock"), to: folder)
        try fixture.write("draft", to: folder.appending(path: "notes.txt"))
        let first = try fixture.packages.install(folder)
        XCTAssertEqual(try fixture.packages.record(id: "clock"), .local)
        _ = try await acme.add(id: "clock", kind: "widgets", configuration: configuration, version: "2", name: "Clock")
        let client = PackageStoreClient(packages: fixture.packages, indexURL: fixture.directory.appending(path: "none/index.json"))
        await client.setPrivateSources([acmeSource])
        let catalog = await client.catalog()
        let version2 = try XCTUnwrap(catalog.entries.first { $0.sourceID == "acme" && $0.version == "2" })
        let second = try await client.installWithoutReview(version2)
        var owned = PackageInstallRecord(acmeSource)
        owned.localVersions = ["1"]
        XCTAssertEqual(try fixture.packages.record(id: "clock"), owned)
        XCTAssertEqual(String(decoding: try packageListing(fixture.packages), as: UTF8.self).components(separatedBy: #""source" : "local""#).count, 2)

        // Acme now lists version 1 too.
        _ = try await acme.add(id: "clock", kind: "widgets", configuration: configuration, name: "Clock")
        let store = try fixture.store()
        defer { store.stop() }
        let library = PackageLibrary(store: store, client: client)
        defer { library.stopUpdateChecks() }
        _ = await client.catalog(reload: true)
        await library.loadInstalled()
        await library.loadStore()
        XCTAssertEqual(library.origin(of: first.manifest), .local)
        XCTAssertEqual(library.origin(of: second.manifest), .privateSource("Acme"))
        let version1 = try XCTUnwrap(library.entries.first { $0.sourceID == "acme" && $0.version == "1" })
        // Acme's entry for version 1 reviews Acme's download, not the folder's files.
        let reviewed = try await client.packageForAdding(version1)
        XCTAssertNotEqual(reviewed.directory, first.directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reviewed.directory.appending(path: "notes.txt").path))
        let refusal = "Clock 1 is already installed from a folder with different files. Uninstall it before getting it from Acme."
        await library.get(version1)
        XCTAssertEqual(library.error, refusal)
        let draft = PackageDraft(inspection: reviewed, settings: [:])
        draft.sourceID = "acme"
        await library.add(draft)
        XCTAssertEqual(draft.error, refusal)
        XCTAssertEqual(try fixture.packages.record(id: "clock"), owned)
        // With Acme's own files, adding claims version 1 for Acme.
        try FileManager.default.removeItem(at: first.directory.appending(path: "notes.txt"))
        await library.add(draft)
        XCTAssertNil(draft.error)
        XCTAssertEqual(try fixture.packages.record(id: "clock"), PackageInstallRecord(acmeSource))
        XCTAssertEqual(library.origin(of: first.manifest), .privateSource("Acme"))
    }

    @MainActor func testStoreGridRendersSameIDsFromTwoSourcesWithLabels() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let index = LocalPackageIndex(fixture: fixture), acme = LocalPackageIndex(fixture: fixture, folder: "acme")
        let empty = #"{"widgets":[]}"#
        _ = try await index.add(id: "clock", kind: "widgets", configuration: empty, name: "Clock")
        _ = try await acme.add(id: "clock", kind: "widgets", configuration: empty, name: "Clock")
        let acmeSource = PackageSource(id: "acme", name: "Acme", url: acme.url)
        _ = try fixture.packages.install(fixture.directory.appending(path: "sources/clock"),
                                         record: PackageInstallRecord(acmeSource), requestedName: "Acme")
        let store = try fixture.store()
        defer { store.stop() }
        let client = PackageStoreClient(packages: fixture.packages, indexURL: index.url)
        await client.setPrivateSources([acmeSource])
        let library = PackageLibrary(store: store, client: client)
        defer { library.stopUpdateChecks() }
        store.packageLibrary = library
        await library.loadInstalled()
        await library.loadStore()
        // Both sources list the same ID: the keys stay unique, so the grid has no duplicate identities.
        let keys = library.storeEntries(showingThemes: nil, sourceID: nil).map(\.key)
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(Set(keys).count, 2)
        XCTAssertEqual(PackageOrigin.privateSource("Acme").title, "Acme")
        XCTAssertEqual(PackageOrigin.privateSource("Acme").symbol, "lock.fill")
        // The Store's card is the one that must say where Clock is installed from; Acme's owns the install.
        let storeClock = try XCTUnwrap(library.entries.first { $0.sourceID == PackageSource.storeID })
        let acmeClock = try XCTUnwrap(library.entries.first { $0.sourceID == "acme" })
        XCTAssertEqual(library.installedElsewhere(storeClock), "Acme")
        XCTAssertNil(library.installedElsewhere(acmeClock))
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 620),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        library.showingStore = true
        let host = NSHostingView(rootView: PackagesView(store: store))
        host.sizingOptions = []
        window.contentView = host
        // The grid lays out with both Clock cards, which would trip SwiftUI's duplicate-ID check if they shared an identity.
        for _ in 0..<30 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(host.subviews.first { String(describing: type(of: $0)).contains("PlatformContainer") })
        // The Store card says where Clock is installed from; Acme's card, which owns the install, says Installed.
        XCTAssertEqual(library.cardStatus(storeClock), .installedElsewhere("Acme"))
        XCTAssertEqual(library.cardStatus(acmeClock), .installed)
        await library.uninstall(try XCTUnwrap(library.installed.first))
        XCTAssertEqual(library.cardStatus(storeClock), .get)
        XCTAssertEqual(library.cardStatus(acmeClock), .get)
        XCTAssertFalse(window.isVisible)
    }

    @MainActor func testSearchFiltersAndOriginsCoverEverySource() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let index = LocalPackageIndex(fixture: fixture), acme = LocalPackageIndex(fixture: fixture, folder: "acme")
        let empty = #"{"widgets":[]}"#
        let acmeSource = PackageSource(id: "acme", name: "Acme", url: acme.url)
        _ = try await index.add(id: "note", kind: "widgets", configuration: empty, name: "Note")
        let installedFromAcme = try fixture.packages.install(fixture.directory.appending(path: "sources/note"),
                                                             record: PackageInstallRecord(acmeSource), requestedName: "Acme")
        _ = try await index.add(id: "clock", kind: "widgets", configuration: empty, name: "Clock")
        _ = try await acme.add(id: "clock", kind: "widgets", configuration: empty, name: "Clock")
        let store = try fixture.store()
        defer { store.stop() }
        let client = PackageStoreClient(packages: fixture.packages, indexURL: index.url)
        await client.setPrivateSources([acmeSource])
        let library = PackageLibrary(store: store, client: client)
        defer { library.stopUpdateChecks() }
        await library.loadInstalled()
        await library.loadStore()
        XCTAssertTrue(library.hasPrivateSources)
        XCTAssertEqual(library.sources.map(\.id), ["stablebar", "acme"])
        XCTAssertEqual(library.sourceName("acme"), "Acme")
        XCTAssertTrue(library.sourceErrors.isEmpty)
        XCTAssertEqual(library.storeEntries(showingThemes: nil, sourceID: "acme").map(\.sourceID), ["acme"])
        XCTAssertEqual(library.storeEntries(showingThemes: nil, sourceID: nil).map(\.key), ["stablebar:clock/1", "acme:clock/1"])
        XCTAssertTrue(library.storeEntries(showingThemes: true, sourceID: nil).isEmpty)
        library.search = "acme"
        XCTAssertEqual(Set(library.storeEntries(showingThemes: nil, sourceID: nil).map(\.sourceID)), ["acme"])
        XCTAssertTrue(library.matchesSearch(installedFromAcme.manifest))
        library.search = "stablebar store"
        XCTAssertEqual(library.storeEntries(showingThemes: nil, sourceID: nil).map(\.sourceID), ["stablebar"])
        XCTAssertFalse(library.matchesSearch(installedFromAcme.manifest))
        library.search = ""
        XCTAssertEqual(library.origin(of: installedFromAcme.manifest), .privateSource("Acme"))
        XCTAssertEqual(library.origin(of: library.entries[0]), .store)
        XCTAssertEqual(library.origin(of: library.entries[1]), .privateSource("Acme"))
        // The installed copy's page says its updates are checked at its source; a source's other drafts don't.
        let review = "StableBar’s maintainers didn’t review this package."
        XCTAssertEqual(library.privateSourceHint(PackageDraft(inspection: installedFromAcme, settings: [:])), "Updates are checked there. " + review)
        let download = PackageDraft(inspection: try await client.package(library.entries[1]), settings: [:])
        download.sourceID = "acme"
        XCTAssertEqual(library.privateSourceHint(download), review)
        XCTAssertEqual(PackageOrigin.installed(record: PackageInstallRecord(source: "gone", name: "Gone", url: nil), version: "1", listedInStore: false, sources: [.store]),
                       .privateSource("Gone (removed)"))
        XCTAssertEqual(PackageOrigin.installed(record: nil, version: "1", listedInStore: true, sources: [.store]), .listed)
        XCTAssertEqual(PackageOrigin.installed(record: nil, version: "1", listedInStore: false, sources: [.store]), .installed)
        XCTAssertEqual(PackageOrigin.installed(record: .local, version: "1", listedInStore: true, sources: [.store]), .local)
        XCTAssertEqual(PackageOrigin.installed(record: PackageInstallRecord(.store), version: "1", listedInStore: false, sources: [.store]), .store)
        XCTAssertEqual(PackageOrigin.installed(record: PackageInstallRecord(acmeSource), version: "1", listedInStore: false,
                                               sources: [.store, acmeSource]),
                       .privateSource("Acme"))
        var withFolderVersion = PackageInstallRecord(acmeSource)
        withFolderVersion.localVersions = ["2"]
        XCTAssertEqual(PackageOrigin.installed(record: withFolderVersion, version: "2", listedInStore: false, sources: [.store, acmeSource]),
                       .local)
        XCTAssertEqual(PackageOrigin.installed(record: withFolderVersion, version: "1", listedInStore: false, sources: [.store, acmeSource]),
                       .privateSource("Acme"))
        // A Store failure is reported even when a private source loads.
        let offline = PackageStoreClient(packages: fixture.packages, indexURL: fixture.directory.appending(path: "missing/index.json"))
        await offline.setPrivateSources([acmeSource])
        let partial = PackageLibrary(store: store, client: offline)
        defer { partial.stopUpdateChecks() }
        await partial.loadStore()
        XCTAssertNotNil(partial.storeError)
        XCTAssertEqual(Array(partial.sourceErrors.keys), [PackageSource.storeID])
        XCTAssertEqual(partial.entries.map(\.key), ["acme:clock/1"])
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
        let widgetPreview = try await library.preview(widget)
        XCTAssertEqual(widgetPreview.widgets.map(\.id), ["script"])
        XCTAssertNil(widgetPreview.theme)
        await library.selectStore(widget)
        XCTAssertNil(library.draft?.themePreview)
        let themePreview = try await library.preview(theme)
        XCTAssertEqual(themePreview.theme?.light.bar.height, 31)
        await library.selectStore(theme)
        XCTAssertEqual(library.draft?.themePreview?.light.bar.height, 31)
        XCTAssertEqual(library.draft?.themePreview?.dark.bar.height, 31)
        XCTAssertTrue(try fixture.packages.list().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
        XCTAssertTrue(store.customizationHistory.undoSteps.isEmpty)
    }

    @MainActor func testListScreenshotLoadsWithoutDownloadingOrInstallingThePackage() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let imageURL = fixture.directory.appending(path: "preview.png")
        let image = ImageRenderer(content: Color.blue.frame(width: 20, height: 20))
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: XCTUnwrap(image.cgImage)).representation(using: .png, properties: [:]))
        try data.write(to: imageURL)
        let entry = try ConfigurationValue.object([
            "id": .string("image"), "name": .string("Image"), "version": .string("1"),
            "archive": .string("missing.tar.gz"), "sha256": .string("unused"),
            "source": .string("https://example.com/source"), "screenshot": .string(imageURL.absoluteString)
        ]).decoded(PackageIndex.Entry.self)
        let store = try fixture.store()
        defer { store.stop() }
        let library = store.packageLibrary
        let preview = try await library.preview(entry)
        XCTAssertEqual(preview.screenshot, data)
        XCTAssertTrue(try fixture.packages.list().isEmpty)
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
        // Installed before install records existed.
        func dropRecord(_ id: String) throws {
            try FileManager.default.removeItem(at: fixture.directory.appending(path: "packages/\(id)/\(PackageInstallRecord.fileName)"))
        }
        try dropRecord("listed")
        try dropRecord("unlisted")
        let store = try fixture.store()
        defer { store.stop() }
        let library = PackageLibrary(store: store, client: PackageStoreClient(packages: fixture.packages, indexURL: index.url))
        await library.loadInstalled()
        XCTAssertEqual(library.origin(of: older), .installed)
        await library.loadStore()
        XCTAssertEqual(library.origin(of: older), .listed)
        XCTAssertEqual(library.origin(of: newer), .listed)
        XCTAssertEqual(library.origin(of: unlisted), .installed)
        await library.selectStore(entry)
        XCTAssertEqual(library.draft.map { library.origin($0) }, .store)
        await library.select(try folder("listed", "1"))
        XCTAssertEqual(library.draft.map { library.origin($0) }, .local)
        let installed = try fixture.packages.install(folder("listed", "2"))
        try dropRecord("listed")
        let review = PackageLibrary(store: store, client: PackageStoreClient(packages: fixture.packages, indexURL: index.url), reviewing: true)
        let installedDraft = PackageDraft(inspection: installed, settings: [:])
        XCTAssertEqual(review.origin(installedDraft), .installed)
        await review.loadStore()
        XCTAssertEqual(review.origin(installedDraft), .listed)
        // The installed copy has no record, so the review shows the Store's download, not the unclaimed files.
        await review.selectStore(entry)
        XCTAssertEqual(review.draft.map { review.origin($0) }, .store)
        XCTAssertNotEqual(review.draft?.inspection.directory, installed.directory)
        let downloaded = try await PackageStoreClient(packages: fixture.packages, indexURL: index.url).package(entry)
        XCTAssertEqual(review.origin(PackageDraft(inspection: downloaded, settings: [:])), .store)
        try fixture.write(#"{"packages":[]}"#, to: index.url)
        await library.loadStore(reload: true)
        XCTAssertEqual(library.origin(of: installed.manifest), .installed)
    }

    @MainActor func testStoreListsUpdatesThenInstalledThenOtherPackagesByName() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let acme = PackageSource(id: "acme", name: "Acme", url: LocalPackageIndex(fixture: fixture, folder: "acme").url)
        for (id, name) in [("weather", "weather"), ("clock", "Clock"), ("notes", "Notes"), ("battery", "Battery"), ("agenda", "agenda")] {
            let source = fixture.directory.appending(path: "folders/\(id)")
            try fixture.write(#"{"id":"\#(id)","name":"\#(name)","version":"1","kind":"widgets","entry":"config.json"}"#,
                              to: source.appending(path: "package.json"))
            try fixture.write(#"{"widgets":[]}"#, to: source.appending(path: "config.json"))
            _ = try id == "agenda" ? fixture.packages.install(source, record: PackageInstallRecord(acme), requestedName: "Acme")
                : fixture.packages.install(source)
        }
        func index(_ url: URL, _ listed: [(String, String, String)]) throws {
            let entries = listed.map { id, name, version in
                #"{"id":"\#(id)","name":"\#(name)","version":"\#(version)","kind":"widgets","archive":"\#(id).tar.gz","sha256":"0","source":"https://example.com/\#(id)"}"#
            }
            try fixture.write(#"{"packages":[\#(entries.joined(separator: ","))]}"#, to: url)
        }
        let store = LocalPackageIndex(fixture: fixture).url
        try index(store, [("zoom", "Zoom", "1"), ("notes", "Notes", "1"), ("weather", "weather", "2"),
                          ("agenda", "agenda", "1"), ("battery", "Battery", "1"), ("clock", "Clock", "3")])
        try index(acme.url, [("zoom", "Zoom", "1"), ("agenda", "agenda", "1")])
        let bar = try fixture.store()
        defer { bar.stop() }
        let client = PackageStoreClient(packages: fixture.packages, indexURL: store)
        await client.setPrivateSources([acme])
        let library = PackageLibrary(store: bar, client: client)
        defer { library.stopUpdateChecks() }
        await library.loadInstalled()
        await library.loadStore()
        // The Store's agenda card says Installed from Acme, so it sorts with the installed packages; same names follow the sources.
        XCTAssertEqual(library.storeEntries(showingThemes: nil, sourceID: nil).map(\.key), [
            "stablebar:clock/3", "stablebar:weather/2", "stablebar:agenda/1", "acme:agenda/1",
            "stablebar:battery/1", "stablebar:notes/1", "stablebar:zoom/1", "acme:zoom/1"
        ])
        XCTAssertEqual(library.storeEntries(showingThemes: nil, sourceID: "acme").map(\.key), ["acme:agenda/1", "acme:zoom/1"])
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
        XCTAssertEqual(table.numberOfRows, 3)
        XCTAssertEqual(table.selectedRow, 2)
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

    /// Review Focus 3: a pasted token is trimmed before it's saved, and Undo removes the source but keeps its token.
    @MainActor func testAddingASourceSavesConfigAndATrimmedTokenAndUndoKeepsTheToken() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let index = LocalPackageIndex(fixture: fixture), local = LocalPackageIndex(fixture: fixture, folder: "acme")
        _ = try await index.add(id: "note", kind: "widgets", configuration: #"{"widgets":[]}"#, name: "Note")
        _ = try await local.add(id: "clock", kind: "widgets", configuration: #"{"widgets":[]}"#, name: "Clock")
        // The configuration accepts only https sources, so the Acme index is served from a stubbed https host.
        let acme = (url: URL(string: "https://add-source.sources-sheet.example/acme/index.json")!, name: "Acme")
        StubURLProtocol.serve(try Data(contentsOf: local.url), at: acme.url)
        let store = try fixture.store()
        defer { store.stop() }
        let tokens = PackageSourceTokens.memory()
        let client = PackageStoreClient(packages: fixture.packages, indexURL: index.url, tokens: tokens, session: StubURLProtocol.session())
        let library = PackageLibrary(store: store, client: client)
        defer { library.stopUpdateChecks() }
        await library.loadInstalled()
        await library.loadStore()

        try await library.addSource(PackageSource(id: "acme", name: "Acme", url: acme.url), token: "  t\n")
        try store.customizationHistory.flush()
        XCTAssertEqual(try fixture.document()["packageSources"]?.decoded([PackageSource].self).map(\.id), ["acme"])
        XCTAssertEqual(tokens.read("source:acme").flatMap(SavedSourceToken.init(stored:)), SavedSourceToken(token: "t", for: acme.url))
        XCTAssertFalse(String(decoding: try Data(contentsOf: fixture.url), as: UTF8.self).contains("\"t\""))
        XCTAssertTrue(library.entries.contains { $0.sourceID == "acme" })
        XCTAssertEqual(store.customizationHistory.undoSteps.count, 1)
        let draft = PackageSourceDraft(existing: library.sources)
        draft.urlText = acme.url.absoluteString
        await draft.check(using: library)
        XCTAssertEqual(draft.state, .duplicate("Acme"))

        try store.customizationHistory.undo()
        // After configurationChanged(): the source is gone, the token stays.
        library.configurationChanged()
        await library.sourceSync?.value
        XCTAssertNil(try fixture.document()["packageSources"])
        XCTAssertFalse(library.sources.contains { $0.id == "acme" })
        XCTAssertFalse(library.entries.contains { $0.sourceID == "acme" })
        // Redo brings the source back, and its kept token goes along again.
        try store.customizationHistory.redo()
        library.configurationChanged()
        await library.sourceSync?.value
        XCTAssertTrue(library.entries.contains { $0.sourceID == "acme" })
        let saved = await library.savedTokens()
        XCTAssertEqual(saved, ["acme"])
        XCTAssertEqual(StubURLProtocol.requests.last { $0.url == acme.url }?.value(forHTTPHeaderField: "Authorization"), "Bearer t")
        XCTAssertEqual(tokens.read("source:acme").flatMap(SavedSourceToken.init(stored:)), SavedSourceToken(token: "t", for: acme.url))
    }

    /// A failed check can run again with the same URL and token, as Check again does once the index is published.
    @MainActor func testAFailedSourceCheckCanRunAgainWithoutChangingTheForm() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let local = LocalPackageIndex(fixture: fixture, folder: "team")
        _ = try await local.add(id: "clock", kind: "widgets", configuration: #"{"widgets":[]}"#, name: "Clock")
        let url = URL(string: "https://retry.sources-sheet.example/team/index.json")!
        let store = try fixture.store()
        defer { store.stop() }
        let client = PackageStoreClient(packages: fixture.packages, indexURL: fixture.directory.appending(path: "store/index.json"),
                                        session: StubURLProtocol.session())
        let library = PackageLibrary(store: store, client: client)
        defer { library.stopUpdateChecks() }
        let draft = PackageSourceDraft(existing: library.sources)
        draft.name = "Team"
        draft.urlText = url.absoluteString
        await draft.check(using: library)
        guard case .failed = draft.state else { return XCTFail("Expected a failed check, got \(draft.state)") }
        XCTAssertFalse(draft.canSave)
        StubURLProtocol.serve(try Data(contentsOf: local.url), at: url)
        await draft.check(using: library)
        XCTAssertEqual(draft.state, .found(widgets: 1, themes: 0))
        XCTAssertTrue(draft.canSave)
    }

    @MainActor func testSourcesFromIncludesAreReadOnly() async throws {
        // main includes team.json (source "team") and defines "acme" itself:
        let fixture = try ThemeGalleryFixture(#"{"includes":["team.json"],"widgets":[],"packageSources":[{"id":"acme","name":"Acme","url":"https://acme.sources-sheet.example/index.json"}]}"#)
        defer { fixture.close() }
        try fixture.write(#"{"packageSources":[{"id":"team","name":"Team","url":"https://team.sources-sheet.example/index.json"}]}"#,
                          to: fixture.directory.appending(path: "team.json"))
        let store = try fixture.store()
        defer { store.stop() }
        let tokens = PackageSourceTokens.memory()
        let client = PackageStoreClient(packages: fixture.packages, indexURL: fixture.directory.appending(path: "store/index.json"),
                                        tokens: tokens, session: StubURLProtocol.session())
        let library = PackageLibrary(store: store, client: client)
        defer { library.stopUpdateChecks() }
        await library.loadInstalled()
        let configured = try PackageSource.configured(in: store.effectiveDocument)
        let team = try XCTUnwrap(configured.first { $0.id == "team" }), acme = try XCTUnwrap(configured.first { $0.id == "acme" })
        XCTAssertFalse(library.isEditable(team)); XCTAssertTrue(library.isEditable(acme))
        XCTAssertFalse(library.isEditable(.store))
        XCTAssertEqual(library.definingFile(team), "team.json")
        XCTAssertEqual(library.definingFile(acme), "config.json")

        // A read-only source still takes a token, and saving it leaves the configuration alone.
        let before = try fixture.document()
        try await library.updateSource(team, token: " k ")
        XCTAssertEqual(try fixture.document(), before)
        XCTAssertEqual(tokens.read("source:team").flatMap(SavedSourceToken.init(stored:)), SavedSourceToken(token: "k", for: team.url))
        let saved = await library.savedTokens()
        XCTAssertEqual(saved, ["team"])
        try await library.removeToken("team")
        XCTAssertNil(tokens.read("source:team"))
        let remaining = await library.savedTokens()
        XCTAssertEqual(remaining, [])
    }

    @MainActor private func textFields(_ view: NSView) -> [String] {
        (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(textFields)
    }

    @MainActor private func tables(in view: NSView) -> [NSTableView] {
        (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables)
    }
}
