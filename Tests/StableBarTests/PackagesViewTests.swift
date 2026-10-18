import AppKit
import SwiftUI
import XCTest
@testable import StableBar

final class PackagesViewTests: XCTestCase {
    @MainActor func testPackagesBrowserStillLoadsInstalledPackagesAndTheirDetails() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        _ = try fixture.theme(#"{}"#)
        let index = fixture.directory.appending(path: "index.json")
        try fixture.write(#"{"packages":[]}"#, to: index)
        let store = try fixture.store()
        defer { store.stop() }
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 620),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: PackagesView(store: store, indexURL: index))
        host.sizingOptions = []
        window.contentView = host
        for _ in 0..<30 {
            host.layoutSubtreeIfNeeded()
            if tables(in: host).first?.numberOfRows == 3 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let table = try XCTUnwrap(tables(in: host).first)
        XCTAssertEqual(table.numberOfRows, 3)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        let directory = fixture.packages.directory.appending(path: "test-theme/1").path
        for _ in 0..<30 {
            host.layoutSubtreeIfNeeded()
            if textFields(host).contains(directory) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(textFields(host).contains(directory))
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
