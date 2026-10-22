import AppKit
import XCTest
@testable import StableBar

final class ThemeTrialPanelTests: XCTestCase {
    func testPointerSelectsTheDisplayIncludingNegativeAndStackedCoordinates() {
        let frames = [CGRect(x: 0, y: 0, width: 1440, height: 900),
                      CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                      CGRect(x: 0, y: 900, width: 2560, height: 1440)]
        XCTAssertEqual(ThemeTrialPlacement.screenIndex(at: CGPoint(x: 200, y: 850), frames: frames, mainIndex: 0, barIndices: [0, 1, 2]), 0)
        XCTAssertEqual(ThemeTrialPlacement.screenIndex(at: CGPoint(x: -1000, y: 1000), frames: frames, mainIndex: 0, barIndices: [0, 1, 2]), 1)
        XCTAssertEqual(ThemeTrialPlacement.screenIndex(at: CGPoint(x: 2000, y: 2000), frames: frames, mainIndex: 0, barIndices: [0, 1, 2]), 2)
        let edges = [(CGPoint(x: -1000, y: 1080), 1), (CGPoint(x: 2560, y: 2340), 2),
                     (CGPoint(x: 0, y: 900), 0), (CGPoint(x: -1920, y: 0), 1)]
        for (point, index) in edges {
            XCTAssertEqual(ThemeTrialPlacement.screenIndex(at: point, frames: frames, mainIndex: 0, barIndices: [0, 1, 2]),
                           index)
        }
    }

    func testScreenChoiceFallsBackToMainThenFirstBarAndRequiresABar() {
        let frames = [CGRect(x: 0, y: 0, width: 1440, height: 900),
                      CGRect(x: -1920, y: 0, width: 1920, height: 1080)]
        let outside = CGPoint(x: -3000, y: 2000)
        XCTAssertEqual(ThemeTrialPlacement.screenIndex(at: outside, frames: frames, mainIndex: 1, barIndices: [0, 1]), 1)
        XCTAssertEqual(ThemeTrialPlacement.screenIndex(at: outside, frames: frames, mainIndex: nil, barIndices: [0, 1]), 0)
        XCTAssertEqual(ThemeTrialPlacement.screenIndex(at: outside, frames: frames, mainIndex: 1, barIndices: [0]), 0)
        XCTAssertEqual(ThemeTrialPlacement.screenIndex(at: CGPoint(x: -1000, y: 500), frames: frames, mainIndex: 0, barIndices: [0]), 0)
        XCTAssertNil(ThemeTrialPlacement.screenIndex(at: outside, frames: frames, mainIndex: 0, barIndices: []))
        XCTAssertNil(ThemeTrialPlacement.screenIndex(at: outside, frames: [], mainIndex: nil, barIndices: []))
    }

    func testPanelCentersBelowTheChosenBarAndTracksThemeDimensionsAndOutsideUnderlines() {
        let screen = CGRect(x: -1920, y: 0, width: 1920, height: 1056)
        let size = CGSize(width: 340, height: 110)
        let first = ThemeTrialPlacement.frame(size: size, bar: CGRect(x: -1920, y: 1010, width: 1920, height: 40),
                                               geometry: BarGeometry(layoutHeight: 40, margin: 4, outsideExtent: 0), visibleFrame: screen)
        XCTAssertEqual(first.midX, screen.midX)
        XCTAssertEqual(first.maxY, 1006)
        let second = ThemeTrialPlacement.frame(size: size, bar: CGRect(x: -1920, y: 990, width: 1920, height: 60),
                                                geometry: BarGeometry(layoutHeight: 60, margin: 0, outsideExtent: 6, outsideHeight: 2),
                                                visibleFrame: screen)
        XCTAssertEqual(second.midX, first.midX)
        XCTAssertEqual(second.maxY, 976)
        XCTAssertEqual(second.size, size)
    }

    func testPanelStaysInsideVisibleScreenEdges() {
        let screen = CGRect(x: 100, y: -1000, width: 500, height: 900)
        let result = ThemeTrialPlacement.frame(size: CGSize(width: 340, height: 110),
                                               bar: CGRect(x: 0, y: -950, width: 200, height: 40), geometry: nil, visibleFrame: screen)
        XCTAssertEqual(result.minX, 108)
        XCTAssertEqual(result.minY, -992)
        XCTAssertTrue(screen.contains(result))
    }

    @MainActor func testOutsideClickCancelsThePreviewWithoutSavingAndReopeningStartsFresh() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let store = BarStore(configurationURL: fixture.url, themesDirectory: fixture.themes)
        store.reloadConfiguration()
        defer { store.stop() }
        let document = store.effectiveDocument
        let original = try Data(contentsOf: fixture.url)
        let bar = BarPanel(contentRect: CGRect(x: screen.frame.minX, y: screen.frame.maxY - 60, width: screen.frame.width, height: 40),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        defer { bar.close() }
        var presented: PopupPanel?
        let controller = ThemeTrialPanel(present: { presented = $0 })
        defer { controller.cancel() }
        controller.show(store: store, bar: bar, screen: screen)
        let panel = try XCTUnwrap(presented)
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertEqual(panel.animationBehavior, .none)
        XCTAssertEqual(panel.frame.midX, bar.frame.midX, accuracy: 1)
        XCTAssertFalse(panel.isVisible)
        XCTAssertTrue(controller.handle(try key(123, panel: panel)))
        XCTAssertEqual(store.configuration?.defaults.cornerRadius, 6)
        let outside = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        XCTAssertFalse(controller.handle(outside))
        XCTAssertEqual(store.effectiveDocument, document)
        XCTAssertEqual(try Data(contentsOf: fixture.url), original)
        XCTAssertTrue(store.customizationHistory.undoSteps.isEmpty)
        controller.show(store: store, bar: bar, screen: screen)
        XCTAssertTrue(controller.handle(try key(124, panel: XCTUnwrap(presented))))
        XCTAssertNotEqual(store.effectiveDocument, document)
        controller.cancel()
        XCTAssertEqual(store.effectiveDocument, document)
    }

    @MainActor func testPanelKeyboardKeepsCancelsAndLeavesModifiedShortcutsAlone() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let store = BarStore(configurationURL: fixture.url, themesDirectory: fixture.themes)
        store.reloadConfiguration()
        defer { store.stop() }
        let bar = BarPanel(contentRect: CGRect(x: screen.frame.minX, y: screen.frame.maxY - 60, width: screen.frame.width, height: 40),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        defer { bar.close() }
        var presented: PopupPanel?
        let controller = ThemeTrialPanel(present: { presented = $0 })
        defer { controller.cancel() }
        controller.show(store: store, bar: bar, screen: screen)
        let panel = try XCTUnwrap(presented)
        XCTAssertFalse(controller.handle(try key(123, panel: panel, modifiers: .command)))
        XCTAssertTrue(controller.handle(try key(123, panel: panel)))
        XCTAssertTrue(controller.handle(try key(36, panel: panel)))
        XCTAssertEqual(try fixture.document()["theme"], .object(["id": .string("synthwave")]))
        XCTAssertEqual(store.customizationHistory.undoSteps.count, 1)
        controller.show(store: store, bar: bar, screen: screen)
        let next = try XCTUnwrap(presented)
        XCTAssertTrue(controller.handle(try key(124, panel: next)))
        XCTAssertNotEqual(store.configuration?.defaults.cornerRadius, 6)
        XCTAssertTrue(controller.handle(try key(53, panel: next)))
        XCTAssertEqual(store.configuration?.defaults.cornerRadius, 6)
        XCTAssertEqual(store.customizationHistory.undoSteps.count, 1)
    }

    @MainActor private func key(_ code: UInt16, panel: PopupPanel, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                     windowNumber: panel.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                                     isARepeat: false, keyCode: code))
    }
}
