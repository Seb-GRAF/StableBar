import AppKit
import SwiftUI
import XCTest
@testable import StableBar

final class WidgetAddPopoverTests: XCTestCase {
    @MainActor func testHostingShowsTitleSearchTwoColumnsAndFiltersChoices() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let setup = WidgetSetup(store: store, client: PackageStoreClient(packages: fixture.packages,
            indexURL: fixture.directory.appending(path: "missing-index.json")))
        let model = WidgetAddPopoverModel(setup: setup, position: .left, before: nil, added: { _ in })
        let window = makeWindow()
        defer { window.close() }
        let host = NSHostingView(rootView: WidgetAddPopoverView(model: model, store: store))
        host.sizingOptions = []
        window.contentView = host
        for _ in 0..<40 {
            host.layoutSubtreeIfNeeded()
            if setup.storeUnavailable { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let labels = accessibleText(host)
        XCTAssertEqual(host.rootView.title, "ADD HERE")
        XCTAssertTrue(labels.contains("Search widgets"), "Missing search: \(labels)")
        XCTAssertTrue(host.rootView.model.choices.contains { $0.name == "Clock" })
        XCTAssertEqual(model.columns, 2)
        XCTAssertEqual(model.rowCount, 6)
        XCTAssertLessThanOrEqual(host.fittingSize.width, 340)
        XCTAssertLessThan(host.fittingSize.height, 420)
        model.search = "CPU"
        for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.choices.map(\.id), ["system"])
        XCTAssertEqual(model.selected, "system")
        XCTAssertTrue(accessibleText(host).contains("CPU"))
        XCTAssertFalse(accessibleText(host).contains("Clock"))
        model.search = "Script"
        XCTAssertEqual(model.choices.map(\.id), ["script"])
        model.search = "does not exist"
        XCTAssertNil(model.selected)
        model.move(by: 1)
        XCTAssertNil(model.selected)
        XCTAssertFalse(window.isVisible)
    }

    @MainActor func testKeyboardSelectionAndRapidRequestsAddOnlyOnceAtTheAnchor() async throws {
        let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"first","type":"clock","position":"right"}]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let setup = WidgetSetup(store: store)
        var added: [String] = []
        let model = WidgetAddPopoverModel(setup: setup, position: .right, before: "first", added: { added.append($0) })
        model.search = "text"
        model.move(by: -20)
        XCTAssertEqual(model.selected, "text")
        model.addSelected()
        model.addSelected()
        for _ in 0..<40 {
            if !added.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(added.count, 1)
        XCTAssertEqual(store.configuration?.widgets.map(\.id), [try XCTUnwrap(added.first), "first"])
        XCTAssertEqual(store.customizationHistory.undoSteps.count, 1)
        XCTAssertTrue(setup.requestStarted)
        model.addSelected()
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(added.count, 1)
    }

    @MainActor func testCommandReviewLoadsInsidePopoverIncludingRequirementsAndSettings() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let source = fixture.directory.appending(path: "review")
        try fixture.write(#"{"id":"review","name":"Review package","version":"1","entry":"config.json","permissions":["automation"],"hosts":["example.com"],"settings":{"message":{"type":"string","title":"Message","default":"Hello"}}}"#,
                          to: source.appending(path: "package.json"))
        try fixture.write(#"{"widgets":[{"id":"note","type":"text","text":"@setting.message","position":"left","onClick":"echo reviewed"}]}"#,
                          to: source.appending(path: "config.json"))
        let store = try fixture.store()
        defer { store.stop() }
        let setup = WidgetSetup(store: store, client: PackageStoreClient(packages: fixture.packages,
            indexURL: fixture.directory.appending(path: "missing-index.json")))
        let model = WidgetAddPopoverModel(setup: setup, position: .notchLeft, before: "first", added: { _ in XCTFail("Review must precede adding") })
        let window = makeWindow()
        defer { window.close() }
        let host = NSHostingView(rootView: WidgetAddPopoverView(model: model, store: store))
        host.sizingOptions = []
        window.contentView = host
        for _ in 0..<30 {
            host.layoutSubtreeIfNeeded()
            if setup.storeUnavailable { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        setup.review = WidgetSetup.Review(inspection: try fixture.packages.inspect(source), position: .notchLeft, before: "first")
        for _ in 0..<40 {
            host.layoutSubtreeIfNeeded()
            if accessibleText(host).contains("echo reviewed") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let text = accessibleText(host)
        for expected in ["echo reviewed", "Automation", "example.com", "Hello"] {
            XCTAssertTrue(text.contains(expected), "Review is missing \(expected): \(text)")
        }
        XCTAssertEqual(setup.review?.inspection.manifest.name, "Review package")
        XCTAssertEqual(setup.review?.before, "first")
        XCTAssertTrue(store.customizationHistory.undoSteps.isEmpty)
        XCTAssertTrue(try fixture.packages.list().isEmpty)
        setup.cancelReview()
        XCTAssertNil(setup.review)
        XCTAssertFalse(window.isVisible)
    }

    func testPopoverStaysUnderItsSlotAndClampsToDisplayEdges() {
        let screen = CGRect(x: -800, y: 0, width: 800, height: 900)
        let bar = CGRect(x: -800, y: 850, width: 800, height: 50)
        for x in [-780.0, -400, -38] {
            let anchor = CGRect(x: x, y: 863, width: 22, height: 22)
            let placement = BarEditAddPlacement(size: CGSize(width: 340, height: 400), anchor: anchor, bar: bar, visibleFrame: screen)
            XCTAssertEqual(placement.frame.maxY, bar.minY)
            XCTAssertTrue(screen.contains(placement.frame))
            XCTAssertEqual(placement.frame.minX + placement.arrowX, anchor.midX, accuracy: 8)
        }
    }

    @MainActor func testEscapeClosesPopoverBeforeEditingAndOutsideClicksAndReloadCloseIt() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        var presented: BarEditAddPanel?
        let popover = BarEditAddPopover(present: { _, panel in presented = panel })
        store.barEditing = BarEditing(store: store, addPopover: popover)
        let bar = BarPanel(contentRect: CGRect(x: 0, y: 850, width: 1200, height: 50),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        bar.isReleasedWhenClosed = false
        bar.isEditingBar = true
        let anchor = NSView(frame: CGRect(x: 200, y: 10, width: 22, height: 22))
        bar.contentView = anchor
        defer { popover.close(focusBar: false); bar.close() }
        let setup = WidgetSetup(store: store, client: PackageStoreClient(packages: fixture.packages,
            indexURL: fixture.directory.appending(path: "missing-index.json")))
        func show() {
            popover.show(store: store, displayID: 1, position: .left, anchor: anchor,
                         visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 900), setup: setup)
        }
        store.barEditing.begin()
        show()
        let panel = try XCTUnwrap(presented)
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(panel.isVisible)
        let escape = try key(53, window: panel)
        XCTAssertFalse(BarEditingKeyboard.handle(escape, store: store, keyWindow: panel))
        XCTAssertTrue(popover.handle(escape, keyWindow: panel))
        XCTAssertNil(popover.displayID)
        XCTAssertTrue(store.barEditing.isActive)
        XCTAssertTrue(BarEditingKeyboard.handle(try key(53, window: bar), store: store, keyWindow: bar))
        XCTAssertFalse(store.barEditing.isActive)
        store.barEditing.begin()
        show()
        let outside = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: bar.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        XCTAssertFalse(popover.handle(outside))
        XCTAssertNil(popover.displayID)
        XCTAssertTrue(store.barEditing.isActive)
        show()
        store.reloadConfiguration()
        XCTAssertNil(popover.displayID)
        XCTAssertFalse(store.barEditing.isActive)
        XCTAssertFalse(bar.isVisible)
    }

    @MainActor func testPopoverKeyboardNavigatesAndReturnAddsAtItsSlotWithoutTakingTyping() async throws {
        let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"first","type":"clock","position":"right"}]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        var presented: BarEditAddPanel?
        let popover = BarEditAddPopover(present: { _, panel in presented = panel })
        store.barEditing = BarEditing(store: store, addPopover: popover)
        let bar = BarPanel(contentRect: CGRect(x: 0, y: 850, width: 1200, height: 50),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        bar.isReleasedWhenClosed = false
        bar.isEditingBar = true
        let anchor = NSView(frame: CGRect(x: 200, y: 10, width: 22, height: 22))
        bar.contentView = anchor
        defer { popover.close(focusBar: false); bar.close() }
        let setup = WidgetSetup(store: store, client: PackageStoreClient(packages: fixture.packages,
            indexURL: fixture.directory.appending(path: "missing-index.json")))
        store.barEditing.begin()
        popover.show(store: store, displayID: 1, position: .right, anchor: anchor,
                     visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 900), setup: setup)
        let panel = try XCTUnwrap(presented)
        for _ in 0..<40 {
            panel.contentView?.layoutSubtreeIfNeeded()
            if setup.storeUnavailable { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(popover.handle(try key(0, window: panel), keyWindow: panel))
        XCTAssertTrue(popover.handle(try key(125, window: panel), keyWindow: panel))
        XCTAssertTrue(popover.handle(try key(126, window: panel), keyWindow: panel))
        XCTAssertTrue(popover.handle(try key(36, window: panel), keyWindow: panel))
        for _ in 0..<40 {
            if popover.displayID == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(popover.displayID)
        XCTAssertEqual(store.configuration?.widgets.count, 2)
        XCTAssertNotEqual(store.configuration?.widgets.first?.id, "first")
        XCTAssertEqual(store.configuration?.widgets.first?.content, .clock(format: "EEE d MMM  HH:mm"))
        XCTAssertEqual(store.customizationHistory.undoSteps.count, 1)
        XCTAssertTrue(store.barEditing.isActive)
        XCTAssertFalse(panel.isVisible)
    }

    @MainActor private func makeWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 540, height: 620), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    @MainActor private func key(_ code: UInt16, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
    }

    @MainActor private func accessibleText(_ value: NSView) -> [String] {
        var text = (value as? NSTextField).map { [$0.stringValue, $0.placeholderString ?? ""] } ?? []
        text += value.subviews.flatMap(accessibleText)
        return text
    }
}
