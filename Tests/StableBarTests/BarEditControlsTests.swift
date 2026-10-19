import AppKit
import XCTest
@testable import StableBar

final class BarEditControlsTests: XCTestCase {
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
            XCTAssertFalse(panel.hasShadow)
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
        XCTAssertEqual(panel.frame.maxY, 776)
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
        bar.simulatedSheet = nil
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
    override var attachedSheet: NSWindow? { simulatedSheet }
}

/// Records presentation without ordering any test window onto the screen.
@MainActor private final class UnorderedEditControlsPanel: BarEditControlsPanel {
    var simulatedVisible = false
    var closed = false
    override func orderFrontRegardless() { simulatedVisible = true }
    override func orderOut(_ sender: Any?) { simulatedVisible = false }
    override func close() { simulatedVisible = false; closed = true; super.close() }
}
