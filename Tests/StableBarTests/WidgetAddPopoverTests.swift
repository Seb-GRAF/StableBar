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
        var choiceFrames: [String: CGRect] = [:]
        let host = NSHostingView(rootView: WidgetAddPopoverView(model: model, store: store, measuredChoices: { choiceFrames = $0 }))
        host.sizingOptions = []
        window.contentView = host
        for _ in 0..<40 {
            host.layoutSubtreeIfNeeded()
            if setup.storeUnavailable, choiceFrames.count >= 3 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let labels = accessibleText(host)
        XCTAssertEqual(host.rootView.title, "ADD HERE")
        XCTAssertTrue(labels.contains("Search widgets"), "Missing search: \(labels)")
        XCTAssertTrue(host.rootView.model.choices.contains { $0.name == "Clock & date" })
        let frames = try model.choices.prefix(3).map { try XCTUnwrap(choiceFrames[$0.id]) }
        XCTAssertTrue(frames.allSatisfy { $0.width > 0 && $0.height > 0 })
        XCTAssertEqual(frames[0].midY, frames[1].midY, accuracy: 1)
        XCTAssertLessThan(frames[0].midX, frames[1].midX)
        XCTAssertGreaterThan(frames[2].midY, frames[0].midY)
        XCTAssertEqual(frames[0].minX, frames[2].minX, accuracy: 1)
        XCTAssertEqual(model.rowCount, 7)
        XCTAssertLessThanOrEqual(host.fittingSize.width, 340)
        XCTAssertLessThan(host.fittingSize.height, 560)
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

    @MainActor func testGridKeysKeepTheColumnAndHoverRequiresPointerMovement() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let model = WidgetAddPopoverModel(setup: WidgetSetup(store: store), position: .left, before: nil, added: { _ in })
        let ids = model.choices.map(\.id)
        model.move(by: 1)
        XCTAssertEqual(model.selected, ids[2])
        model.move(by: -1)
        XCTAssertEqual(model.selected, ids[0])
        XCTAssertTrue(model.moveColumn(by: 1))
        XCTAssertEqual(model.selected, ids[1])
        model.move(by: 1)
        XCTAssertEqual(model.selected, ids[3])
        model.selected = ids[11]
        model.move(by: 1)
        XCTAssertEqual(model.selected, ids[11], "The last row has no row below")
        model.moveColumn(by: 1)
        XCTAssertEqual(model.selected, ids[11], "Right must not wrap to the next row")
        model.moveColumn(by: -1)
        XCTAssertEqual(model.selected, ids[10])
        model.hover(ids[1], at: CGPoint(x: -100, y: -100))
        XCTAssertEqual(model.selected, ids[1])
        model.move(by: 1)
        let pointer = NSEvent.mouseLocation
        model.hover(ids[0], at: pointer)
        XCTAssertEqual(model.selected, ids[3], "Scrolling under a stationary pointer must keep keyboard selection")
        model.hover(ids[0], at: CGPoint(x: pointer.x + 1, y: pointer.y))
        XCTAssertEqual(model.selected, ids[0])
        model.search = "text"
        XCTAssertFalse(model.moveColumn(by: -1), "A nonempty field keeps its caret keys")
        XCTAssertEqual(model.selected, "text")
    }

    @MainActor func testRightPopoverIgnoresTheLeadingTemporaryWidgetAndReportsAnchorReadErrors() async throws {
        let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"first","type":"clock","position":"right"}]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        try store.setSessionEdits([
            .init(action: .add, properties: ["id": .string("temporary"), "type": .string("text"), "text": .string("Temporary"), "position": .string("right")]),
            .init(action: .reorder, ids: ["temporary"])
        ])
        var presented: BarEditAddPanel?
        let popover = BarEditAddPopover(present: { _, panel in presented = panel })
        store.barEditing = BarEditing(store: store, addPopover: popover)
        let bar = PopoverEditingBarPanel(contentRect: CGRect(x: 0, y: 850, width: 1200, height: 50),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        bar.isEditingBar = true
        bar.isReleasedWhenClosed = false
        let anchor = NSView(frame: CGRect(x: 200, y: 10, width: 22, height: 22))
        bar.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 1200, height: 50))
        bar.contentView?.addSubview(anchor)
        defer { popover.close(focusBar: false); bar.close() }
        let setup = WidgetSetup(store: store, client: PackageStoreClient(packages: fixture.packages,
            indexURL: fixture.directory.appending(path: "missing-index.json")))
        store.barEditing.begin()
        popover.show(store: store, displayID: 2, position: .right, anchor: anchor,
            visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 900), setup: setup)
        let panel = try XCTUnwrap(presented)
        for _ in 0..<40 {
            panel.contentView?.layoutSubtreeIfNeeded()
            if setup.storeUnavailable { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(popover.handle(try key(36, window: panel), keyWindow: panel))
        for _ in 0..<40 {
            if popover.displayID == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let ids = try XCTUnwrap(store.configuration?.widgets.map(\.id))
        XCTAssertEqual(ids.first, "temporary")
        XCTAssertEqual(ids.last, "first")
        XCTAssertEqual(ids.count, 3)
        XCTAssertFalse(String(decoding: try Data(contentsOf: fixture.url), as: UTF8.self).contains("temporary"))
        try fixture.write("{", to: fixture.url)
        popover.show(store: store, displayID: 2, position: .right, anchor: anchor,
            visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 900), setup: setup)
        XCTAssertNil(popover.displayID)
        XCTAssertNotNil(store.barEditing.error)
        XCTAssertEqual(store.barEditing.errorDisplayID, 2)
    }

    @MainActor func testDisplayChangesSheetsAnchorToggleAndFocusOrder() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        var calls: [String] = []
        var presented: BarEditAddPanel?
        let popover = BarEditAddPopover(present: { _, panel in presented = panel }, dismiss: { panel in
            calls.append("dismiss")
            panel.close()
        })
        store.barEditing = BarEditing(store: store, addPopover: popover)
        let bar = PopoverEditingBarPanel(contentRect: CGRect(x: 0, y: 850, width: 1200, height: 50),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        bar.onMakeKey = { calls.append("focus") }
        bar.isEditingBar = true
        bar.isReleasedWhenClosed = false
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 1200, height: 50))
        bar.contentView = content
        let anchor = NSView(frame: CGRect(x: 200, y: 10, width: 22, height: 22))
        let other = NSView(frame: CGRect(x: 400, y: 10, width: 22, height: 22))
        content.addSubview(anchor)
        content.addSubview(other)
        let secondBar = PopoverEditingBarPanel(contentRect: CGRect(x: -1200, y: 850, width: 1200, height: 50),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        secondBar.isEditingBar = true
        secondBar.isReleasedWhenClosed = false
        let secondAnchor = NSView(frame: CGRect(x: 200, y: 10, width: 22, height: 22))
        secondBar.contentView = NSView(frame: content.frame)
        secondBar.contentView?.addSubview(secondAnchor)
        defer { popover.close(focusBar: false); secondBar.close(); bar.close() }
        let setup = WidgetSetup(store: store, client: PackageStoreClient(packages: fixture.packages,
            indexURL: fixture.directory.appending(path: "missing-index.json")))
        func show(_ slot: NSView = anchor, displayID: Int = 1) {
            popover.show(store: store, displayID: displayID, position: .right, anchor: slot,
                visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 900), setup: setup)
        }
        store.barEditing.begin()
        show()
        let sheet = PopoverSheetPanel()
        sheet.isReleasedWhenClosed = false
        sheet.simulatedParent = try XCTUnwrap(presented)
        let nested = PopoverSheetPanel()
        nested.isReleasedWhenClosed = false
        nested.simulatedParent = sheet
        defer { nested.close(); sheet.close() }
        for window in [sheet, nested] {
            XCTAssertFalse(popover.handle(try click(window: window, at: .zero), eventWindow: window))
            XCTAssertEqual(popover.displayID, 1)
        }
        calls = []
        popover.close()
        XCTAssertEqual(calls, ["focus", "dismiss"])
        show()
        calls = []
        store.barEditing.screensChanged()
        XCTAssertNil(popover.displayID)
        XCTAssertEqual(calls, ["dismiss"])
        XCTAssertTrue(store.barEditing.isActive)
        show()
        XCTAssertFalse(popover.handle(try click(window: bar, at: CGPoint(x: 210, y: 20)), eventWindow: bar))
        show()
        XCTAssertNil(popover.displayID, "The open + must close on its button action after mouse-down")
        show()
        XCTAssertFalse(popover.handle(try click(window: bar, at: CGPoint(x: 410, y: 20)), eventWindow: bar))
        XCTAssertNil(popover.displayID)
        show(other)
        XCTAssertEqual(popover.displayID, 1, "A different + can reopen on the same display")
        XCTAssertFalse(popover.handle(try click(window: secondBar, at: CGPoint(x: 210, y: 20)), eventWindow: secondBar))
        show(secondAnchor, displayID: 2)
        XCTAssertEqual(popover.displayID, 2, "A different + can reopen on another display")
        show()
        XCTAssertEqual(popover.displayID, 1)
        XCTAssertFalse(bar.isVisible)
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
        for expected in ["echo reviewed", "Uses Automation access", "Connects to example.com", "Hello"] {
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
        bar.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 1200, height: 50))
        bar.contentView?.addSubview(anchor)
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
        bar.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 1200, height: 50))
        bar.contentView?.addSubview(anchor)
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
        XCTAssertTrue(popover.handle(try key(124, window: panel), keyWindow: panel))
        XCTAssertTrue(popover.handle(try key(123, window: panel), keyWindow: panel))
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

    @MainActor private func click(window: NSWindow, at point: CGPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
}

@MainActor private final class PopoverEditingBarPanel: BarPanel {
    var onMakeKey: (() -> Void)?
    override func makeKey() { onMakeKey?() }
}

@MainActor private final class PopoverSheetPanel: NSPanel {
    var simulatedParent: NSWindow?
    override var sheetParent: NSWindow? { simulatedParent }
}
