import AppKit
import SwiftUI
import XCTest
@testable import StableBar

final class WidgetAddViewTests: XCTestCase {
    @MainActor func testListPrimaryActionAddsTheCurrentRowOnce() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let setup = WidgetSetup(store: store, client: PackageStoreClient(packages: fixture.packages,
            indexURL: fixture.directory.appending(path: "missing-index.json")))
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 680, height: 620),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var additions: [String] = []
        let host = NSHostingView(rootView: WidgetAddView(setup: setup, store: store, position: .left, added: { additions.append($0) }))
        host.sizingOptions = []
        window.contentView = host
        for _ in 0..<30 {
            host.layoutSubtreeIfNeeded()
            if setup.storeUnavailable { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let table = try XCTUnwrap(tables(in: host).first)
        let textRow = 1 + (try XCTUnwrap(setup.choices.filter { !$0.isScript }.firstIndex { $0.id == "text" }))
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        try doubleClick(row: 0, in: table)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(store.configuration?.widgets.isEmpty == true)
        XCTAssertFalse(setup.requestStarted)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        try doubleClick(row: textRow, in: table)
        try doubleClick(row: textRow, in: table)
        for _ in 0..<30 {
            host.layoutSubtreeIfNeeded()
            if !additions.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(additions.count, 1)
        XCTAssertEqual(store.configuration?.widgets.count, 1)
        XCTAssertEqual(store.configuration?.widgets.first?.content, .text("New widget"))
        XCTAssertEqual(store.configuration?.widgets.first?.position, .left)
        XCTAssertEqual(store.customizationHistory.undoSteps.count, 1)
        XCTAssertFalse(window.isVisible)
    }

    @MainActor private func tables(in view: NSView) -> [NSTableView] {
        (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables)
    }

    @MainActor private func doubleClick(row: Int, in table: NSTableView) throws {
        table.scrollRowToVisible(row)
        let rect = table.rect(ofRow: row)
        let point = table.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil)
        let window = try XCTUnwrap(table.window)
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 1,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 2, pressure: 0))
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1))
        NSApp.postEvent(up, atStart: true)
        table.mouseDown(with: down)
    }
}
