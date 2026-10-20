import AppKit
import SwiftUI
import XCTest
@testable import StableBar

final class PackagesViewTests: XCTestCase {
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
            XCTAssertTrue(text.contains(expected), "Review is missing \(expected): \(text)")
        }
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(try fixture.packages.list().isEmpty)
        XCTAssertTrue(store.customizationHistory.undoSteps.isEmpty)
    }

    @MainActor func testAddWidgetSheetLoadsTheCommandReviewAfterChoosingAPackage() async throws {
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
        let host = NSHostingView(rootView: WidgetAddView(setup: setup, store: store, position: .left, added: { _ in
            XCTFail("Commands must be reviewed before adding")
        }))
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
