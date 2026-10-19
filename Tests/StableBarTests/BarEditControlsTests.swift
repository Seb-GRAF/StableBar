import AppKit
import SwiftUI
import XCTest
@testable import StableBar

final class BarEditControlsTests: XCTestCase {
    @MainActor func testControlsCreatedWhilePopoverIsOpenUseTheBarInsteadOfTheScreenIndex() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let originalBars = makeBars()
        let first = try XCTUnwrap(originalBars[1])
        let second = try XCTUnwrap(originalBars[2])
        let bars: [CGDirectDisplayID: BarPanel] = [100: first, 1: second]
        defer { bars.values.forEach { $0.close() } }
        let popover = BarEditAddPopover(present: { _, _ in })
        store.barEditing = BarEditing(store: store, addPopover: popover)
        defer { popover.close(focusBar: false) }
        let anchor = NSView(frame: CGRect(x: 100, y: 10, width: 22, height: 22))
        first.contentView = anchor
        store.barEditing.begin()
        popover.show(store: store, displayID: 1, position: .right, anchor: anchor,
                     visibleFrame: try XCTUnwrap(visibleFrames[1]))
        var presented: [UnorderedEditControlsPanel] = []
        let controls = BarEditControls(makePanel: {
            let panel = UnorderedEditControlsPanel()
            presented.append(panel)
            return panel
        })
        defer { controls.close() }
        controls.update(store: store, bars: bars, visibleFrames: [100: try XCTUnwrap(visibleFrames[1]), 1: try XCTUnwrap(visibleFrames[2])])
        XCTAssertFalse(try XCTUnwrap(presented.first { abs($0.frame.midX - first.frame.midX) < 1 }).simulatedVisible)
        XCTAssertTrue(try XCTUnwrap(presented.first { abs($0.frame.midX - second.frame.midX) < 1 }).simulatedVisible)
        popover.close(focusBar: false)
        XCTAssertTrue(presented.allSatisfy(\.simulatedVisible))
    }

    @MainActor func testEachEditingDisplayGetsPassiveControlsThatFollowItsBar() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let bars = makeBars()
        defer { bars.values.forEach { $0.close() } }
        var presented: [UnorderedEditControlsPanel] = []
        let controls = BarEditControls(makePanel: {
            let panel = UnorderedEditControlsPanel()
            presented.append(panel)
            return panel
        })
        defer { controls.close() }
        controls.update(store: store, bars: bars, visibleFrames: visibleFrames)
        XCTAssertTrue(presented.isEmpty)
        store.barEditing.begin()
        controls.update(store: store, bars: bars, visibleFrames: visibleFrames)
        XCTAssertEqual(presented.count, 2)
        for panel in presented {
            let bar = try XCTUnwrap(bars.values.first { abs($0.frame.midX - panel.frame.midX) < 1 })
            XCTAssertTrue(panel.simulatedVisible)
            XCTAssertFalse(panel.canBecomeKey)
            XCTAssertFalse(panel.canBecomeMain)
            XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
            XCTAssertFalse(panel.styleMask.contains(.titled))
            XCTAssertTrue(panel.hasShadow)
            XCTAssertFalse(panel.hidesOnDeactivate)
            XCTAssertEqual(panel.animationBehavior, .none)
            XCTAssertEqual(panel.level, bar.level)
            XCTAssertEqual(panel.collectionBehavior, bar.collectionBehavior)
            XCTAssertGreaterThan(panel.frame.width, 200)
            XCTAssertGreaterThan(panel.frame.height, 24)
            XCTAssertEqual(panel.frame.maxY, bar.frame.minY - 8, accuracy: 0.01)
        }
        let bar = try XCTUnwrap(bars[1])
        let panel = try XCTUnwrap(presented.first { abs($0.frame.midX - bar.frame.midX) < 1 })
        bar.barGeometry = BarGeometry(layoutHeight: 90, margin: 4, outsideExtent: 0)
        bar.setFrame(CGRect(x: 0, y: 780, width: 1200, height: 90), display: false)
        controls.update(store: store, bars: bars, visibleFrames: visibleFrames)
        XCTAssertEqual(presented.count, 2, "Moving a bar must reuse its controls")
        XCTAssertEqual(panel.frame.midX, bar.frame.midX)
        XCTAssertEqual(panel.frame.maxY, bar.frame.minY - 8)
    }

    @MainActor func testDoneKeepsItsAccentFillWhenTheControlsAreInactive() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let view = BarEditControlsView(actions: BarEditControlsActions(editing: store.barEditing, focusBar: {}))
        for scheme in [ColorScheme.dark, .light] {
            for state in [ControlActiveState.active, .inactive] {
                let renderer = ImageRenderer(content: HStack(spacing: 0) {
                    view
                    Color.accentColor.frame(width: 8, height: 8)
                }
                    .environment(\.colorScheme, scheme)
                    .environment(\.controlActiveState, state))
                renderer.scale = 1
                let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
                let fill = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide - 24, y: bitmap.pixelsHigh / 2)?
                    .usingColorSpace(.sRGB))
                let accent = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide - 4, y: bitmap.pixelsHigh / 2)?
                    .usingColorSpace(.sRGB))
                XCTAssertEqual(fill.redComponent, accent.redComponent, accuracy: 0.02, "\(scheme), \(state)")
                XCTAssertEqual(fill.greenComponent, accent.greenComponent, accuracy: 0.02, "\(scheme), \(state)")
                XCTAssertEqual(fill.blueComponent, accent.blueComponent, accuracy: 0.02, "\(scheme), \(state)")
                XCTAssertEqual(fill.alphaComponent, 1, accuracy: 0.02, "\(scheme), \(state)")
            }
        }
    }

    @MainActor func testUndoRestoresHistoryThenFocusesItsOwnBarAndDoneEndsEditing() throws {
        let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"clock","type":"clock","position":"left"}]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let bars = makeBars()
        defer { bars.values.forEach { $0.close() } }
        var presented: [UnorderedEditControlsPanel] = []
        let controls = BarEditControls(makePanel: {
            let panel = UnorderedEditControlsPanel()
            presented.append(panel)
            return panel
        })
        defer { controls.close() }
        store.onConfigurationChange = { controls.update(store: store, bars: bars, visibleFrames: self.visibleFrames) }
        defer { store.onConfigurationChange = nil }
        store.barEditing.begin()
        controls.update(store: store, bars: bars, visibleFrames: visibleFrames)
        let firstBar = try XCTUnwrap(bars[1])
        let secondBar = try XCTUnwrap(bars[2])
        let firstPanel = try XCTUnwrap(presented.first { abs($0.frame.midX - firstBar.frame.midX) < 1 })
        let secondPanel = try XCTUnwrap(presented.first { $0 !== firstPanel })
        let firstActions = try XCTUnwrap(firstPanel.contentView as? NSHostingView<BarEditControlsView>).rootView.actions
        let secondActions = try XCTUnwrap(secondPanel.contentView as? NSHostingView<BarEditControlsView>).rootView.actions
        XCTAssertFalse(firstActions.canUndo)
        XCTAssertFalse(secondActions.canUndo)
        for bar in bars.values {
            bar.onMakeKey = { XCTAssertEqual(store.configuration?.widgets.map(\.id), ["clock"], "Undo must precede focus") }
        }
        store.barEditing.remove("clock")
        XCTAssertTrue(firstActions.canUndo)
        XCTAssertTrue(secondActions.canUndo)
        firstActions.undo()
        XCTAssertEqual(store.configuration?.widgets.map(\.id), ["clock"])
        XCTAssertEqual(firstBar.makeKeyCalls, 1)
        XCTAssertEqual(secondBar.makeKeyCalls, 0)
        XCTAssertFalse(firstActions.canUndo)
        store.barEditing.redo()
        secondActions.undo()
        XCTAssertEqual(store.configuration?.widgets.map(\.id), ["clock"])
        XCTAssertEqual(firstBar.makeKeyCalls, 1)
        XCTAssertEqual(secondBar.makeKeyCalls, 1)
        XCTAssertFalse(firstPanel.canBecomeKey)
        XCTAssertFalse(secondPanel.canBecomeKey)
        secondActions.done()
        XCTAssertFalse(store.barEditing.isActive)
        XCTAssertFalse(secondActions.canUndo)
        XCTAssertTrue(presented.allSatisfy(\.closed))
        XCTAssertEqual(firstBar.makeKeyCalls, 1)
        XCTAssertEqual(secondBar.makeKeyCalls, 1)
    }

    @MainActor func testControlsFollowConfiguredAppearanceAndReturnToSystemAppearance() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let bars = makeBars()
        defer { bars.values.forEach { $0.close() } }
        var presented: [UnorderedEditControlsPanel] = []
        let controls = BarEditControls(makePanel: {
            let panel = UnorderedEditControlsPanel()
            presented.append(panel)
            return panel
        })
        defer { controls.close() }
        store.barEditing.begin()
        controls.update(store: store, bars: bars, visibleFrames: visibleFrames)
        XCTAssertEqual(presented.count, 2)
        XCTAssertTrue(presented.allSatisfy { $0.appearance == nil })
        for (appearance, name) in [(BarAppearance.dark, NSAppearance.Name.darkAqua), (.light, .aqua)] {
            try store.applyEdits([.init(action: .bar, properties: ["appearance": .string(appearance.rawValue)])], persist: false)
            controls.update(store: store, bars: bars, visibleFrames: visibleFrames)
            XCTAssertEqual(presented.count, 2, "Appearance changes must reuse the controls")
            for panel in presented {
                XCTAssertEqual(panel.appearance?.name, name)
                XCTAssertEqual(panel.contentView?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]), name)
            }
        }
        try store.applyEdits([.init(action: .bar, properties: ["appearance": .null])], persist: false)
        controls.update(store: store, bars: bars, visibleFrames: visibleFrames)
        for panel in presented {
            XCTAssertNil(panel.appearance)
            XCTAssertEqual(panel.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]),
                           NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]))
        }
    }

    @MainActor func testControlsStayInsideANarrowVisibleFrame() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let bars = makeBars()
        defer { bars.values.forEach { $0.close() } }
        var presented: UnorderedEditControlsPanel?
        let controls = BarEditControls(makePanel: {
            let panel = UnorderedEditControlsPanel()
            presented = panel
            return panel
        })
        defer { controls.close() }
        let visibleFrame = CGRect(x: 100, y: 0, width: 320, height: 876)
        store.barEditing.begin()
        controls.update(store: store, bars: [1: try XCTUnwrap(bars[1])], visibleFrames: [1: visibleFrame])
        let panel = try XCTUnwrap(presented)
        XCTAssertTrue(visibleFrame.contains(panel.frame))
        XCTAssertEqual(panel.frame.width, visibleFrame.width - 16, accuracy: 0.01)
        XCTAssertEqual(panel.frame.maxX, visibleFrame.maxX - 8, accuracy: 0.01)
        controls.update(store: store, bars: [1: try XCTUnwrap(bars[1])], visibleFrames: visibleFrames)
        XCTAssertGreaterThan(panel.frame.width, visibleFrame.width - 16)
        XCTAssertEqual(panel.frame.midX, try XCTUnwrap(bars[1]).frame.midX)
    }

    @MainActor func testControlsCloseForEveryEditingExitAndReopeningStartsFresh() throws {
        for exit in ["done", "escape", "menu", "reload", "runtime reload", "invalid reload", "themes", "stop"] {
            let fixture = try ThemeGalleryFixture()
            defer { fixture.close() }
            let store = try fixture.store()
            defer { store.stop() }
            let bars = makeBars()
            defer { bars.values.forEach { $0.close() } }
            var presented: [UnorderedEditControlsPanel] = []
            let controls = BarEditControls(makePanel: {
                let panel = UnorderedEditControlsPanel()
                presented.append(panel)
                return panel
            })
            defer { controls.close() }
            store.onConfigurationChange = { controls.update(store: store, bars: bars, visibleFrames: self.visibleFrames) }
            defer { store.onConfigurationChange = nil }
            store.barEditing.begin()
            XCTAssertEqual(presented.count, 2, exit)
            switch exit {
            case "done": store.barEditing.end()
            case "escape": XCTAssertTrue(store.barEditing.handleKey(53))
            case "menu": store.barEditing.toggle()
            case "reload": store.reloadConfiguration()
            case "runtime reload": _ = try store.handle(RuntimeRequest(action: .reload))
            case "invalid reload": try fixture.write("{", to: fixture.url); store.reloadConfiguration()
            case "themes": ThemeTrial(store: store).cancel()
            default: store.stop()
            }
            XCTAssertFalse(store.barEditing.isActive, exit)
            XCTAssertTrue(presented.allSatisfy { $0.closed && !$0.simulatedVisible }, exit)
            store.barEditing.begin()
            XCTAssertEqual(presented.count, 4, exit)
            controls.close()
            XCTAssertTrue(presented.allSatisfy(\.closed), exit)
        }
    }

    @MainActor func testOnlyTheDisplayWithASheetHidesAndItStaysHiddenAcrossUpdates() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let bars = makeBars()
        defer { bars.values.forEach { $0.close() } }
        var presented: [UnorderedEditControlsPanel] = []
        let controls = BarEditControls(makePanel: {
            let panel = UnorderedEditControlsPanel()
            presented.append(panel)
            return panel
        })
        defer { controls.close() }
        store.barEditing.begin()
        controls.update(store: store, bars: bars, visibleFrames: visibleFrames)
        let bar = try XCTUnwrap(bars[1])
        let panel = try XCTUnwrap(presented.first { abs($0.frame.midX - bar.frame.midX) < 1 })
        let other = try XCTUnwrap(presented.first { $0 !== panel })
        NotificationCenter.default.post(name: NSWindow.willBeginSheetNotification, object: bar)
        XCTAssertFalse(panel.simulatedVisible)
        XCTAssertTrue(other.simulatedVisible)
        controls.update(store: store, bars: bars, visibleFrames: visibleFrames)
        XCTAssertFalse(panel.simulatedVisible)
        XCTAssertFalse(panel.closed)
        NotificationCenter.default.post(name: NSWindow.didEndSheetNotification, object: bar)
        XCTAssertTrue(panel.simulatedVisible)
        XCTAssertEqual(presented.count, 2)
        controls.close()
        NotificationCenter.default.post(name: NSWindow.didEndSheetNotification, object: bar)
        XCTAssertFalse(panel.simulatedVisible, "A late sheet notification must not reopen closed controls")
    }

    @MainActor func testOnlyPopoverDisplayHidesControlsUntilItClosesIncludingSheetTransitions() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let bars = makeBars()
        defer { bars.values.forEach { $0.close() } }
        var presented: [UnorderedEditControlsPanel] = []
        let controls = BarEditControls(makePanel: {
            let panel = UnorderedEditControlsPanel()
            presented.append(panel)
            return panel
        })
        defer { controls.close() }
        store.barEditing.begin()
        controls.update(store: store, bars: bars, visibleFrames: visibleFrames)
        let bar = try XCTUnwrap(bars[1])
        let panel = try XCTUnwrap(presented.first { abs($0.frame.midX - bar.frame.midX) < 1 })
        let other = try XCTUnwrap(presented.first { $0 !== panel })
        NotificationCenter.default.post(name: BarEditAddPopover.changedNotification, object: bar, userInfo: ["open": true])
        XCTAssertFalse(panel.simulatedVisible)
        XCTAssertTrue(other.simulatedVisible)
        controls.update(store: store, bars: bars, visibleFrames: visibleFrames)
        XCTAssertFalse(panel.simulatedVisible)
        NotificationCenter.default.post(name: NSWindow.willBeginSheetNotification, object: bar)
        NotificationCenter.default.post(name: NSWindow.didEndSheetNotification, object: bar)
        XCTAssertFalse(panel.simulatedVisible, "Ending a sheet must not cover an open popover")
        NotificationCenter.default.post(name: BarEditAddPopover.changedNotification, object: bar, userInfo: ["open": false])
        XCTAssertTrue(panel.simulatedVisible)
        controls.update(store: store, bars: bars, visibleFrames: visibleFrames)
        XCTAssertTrue(panel.simulatedVisible)
        XCTAssertTrue(other.simulatedVisible)
    }

    @MainActor func testAnAlreadyAttachedSheetHidesControlsAndRemovedDisplaysCloseTheirs() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let bars = makeBars()
        defer { bars.values.forEach { $0.close() } }
        let bar = try XCTUnwrap(bars[1])
        let sheet = NSPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        defer { sheet.close() }
        bar.simulatedSheet = sheet
        var presented: [UnorderedEditControlsPanel] = []
        let controls = BarEditControls(makePanel: {
            let panel = UnorderedEditControlsPanel()
            presented.append(panel)
            return panel
        })
        defer { controls.close() }
        store.barEditing.begin()
        controls.update(store: store, bars: bars, visibleFrames: visibleFrames)
        let hidden = try XCTUnwrap(presented.first { !$0.simulatedVisible })
        NotificationCenter.default.post(name: NSWindow.didEndSheetNotification, object: bar)
        XCTAssertTrue(hidden.simulatedVisible, "The end notification precedes detaching the sheet")
        controls.update(store: store, bars: bars, visibleFrames: visibleFrames)
        XCTAssertTrue(hidden.simulatedVisible, "An update must trust the end notification while the sheet detaches")
        bar.simulatedSheet = nil
        NotificationCenter.default.post(name: NSWindow.willBeginSheetNotification, object: bar)
        XCTAssertFalse(hidden.simulatedVisible, "The next sheet's begin notification hides the controls again")
        controls.update(store: store, bars: bars, visibleFrames: visibleFrames)
        XCTAssertFalse(hidden.simulatedVisible)
        NotificationCenter.default.post(name: NSWindow.didEndSheetNotification, object: bar)
        XCTAssertTrue(hidden.simulatedVisible)
        controls.update(store: store, bars: [2: try XCTUnwrap(bars[2])], visibleFrames: visibleFrames)
        XCTAssertTrue(hidden.closed)
        XCTAssertTrue(presented.first { $0 !== hidden }?.simulatedVisible == true)
        NotificationCenter.default.post(name: NSWindow.didEndSheetNotification, object: bar)
        XCTAssertFalse(hidden.simulatedVisible)
    }

    private var visibleFrames: [CGDirectDisplayID: CGRect] {
        [1: CGRect(x: 0, y: 0, width: 1512, height: 876),
         2: CGRect(x: -1920, y: 0, width: 1920, height: 1056)]
    }

    @MainActor private func makeBars() -> [CGDirectDisplayID: SheetEditingBarPanel] {
        _ = NSApplication.shared
        return [1: CGRect(x: 0, y: 800, width: 1512, height: 64),
                2: CGRect(x: -1920, y: 980, width: 1920, height: 64)].mapValues { frame in
            let bar = SheetEditingBarPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                          backing: .buffered, defer: false)
            bar.isReleasedWhenClosed = false
            bar.isEditingBar = true
            bar.level = .floating
            bar.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
            return bar
        }
    }
}

@MainActor private final class SheetEditingBarPanel: BarPanel {
    var simulatedSheet: NSWindow?
    var makeKeyCalls = 0
    var onMakeKey: (() -> Void)?
    override var attachedSheet: NSWindow? { simulatedSheet }
    override func makeKey() { makeKeyCalls += 1; onMakeKey?() }
}

/// Records presentation without ordering any test window onto the screen.
@MainActor private final class UnorderedEditControlsPanel: BarEditControlsPanel {
    var simulatedVisible = false
    var closed = false
    override func orderFrontRegardless() { simulatedVisible = true }
    override func orderOut(_ sender: Any?) { simulatedVisible = false }
    override func close() { simulatedVisible = false; closed = true; super.close() }
}
