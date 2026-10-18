import SwiftUI
import XCTest
@testable import StableBar

final class ThemeCardTests: XCTestCase {
    func testNarrowPreviewFillsTheCardWhileWidePreviewsStillScale() {
        let narrow = ThemePreviewSizing(naturalSize: CGSize(width: 200, height: 40), availableWidth: 580)
        XCTAssertEqual(narrow.width, 580)
        XCTAssertEqual(narrow.width * narrow.scale, 580)
        XCTAssertEqual(narrow.scale, 1)
        let wide = ThemePreviewSizing(naturalSize: CGSize(width: 800, height: 40), availableWidth: 580)
        XCTAssertEqual(wide.width, 800)
        XCTAssertEqual(wide.width * wide.scale, 580, accuracy: 0.001)
        XCTAssertEqual(wide.scale, 0.725, accuracy: 0.001)
    }

    func testPreviewSizingKeepsBarsThatFitAtTheirNaturalScale() {
        let sizing = ThemePreviewSizing(naturalSize: CGSize(width: 200, height: 40), availableWidth: 580)
        XCTAssertEqual(sizing.scale, 1)
        XCTAssertFalse(sizing.clipsMiddle)
        XCTAssertEqual(ThemePreviewSizing(naturalSize: .zero, availableWidth: 580).scale, 1)
    }

    func testNarrowPreviewKeepsLeftCenterAndRightGroupsInPosition() throws {
        let layout = ThemeBarPreviewLayout(positions: [.left, .center, .right], spacing: 8)
        let plan = layout.plan(width: 560, widths: [40, 60, 50])
        XCTAssertEqual(try XCTUnwrap(plan.placements["0"]).x, 0)
        XCTAssertEqual(try XCTUnwrap(plan.placements["1"]).x, 250)
        XCTAssertEqual(try XCTUnwrap(plan.placements["2"]).x, 510)
        XCTAssertTrue(plan.overflow.isEmpty)
    }

    func testPreviewSizingUniformlyScalesTheWholeBarToFit() {
        let sizing = ThemePreviewSizing(naturalSize: CGSize(width: 800, height: 40), availableWidth: 580)
        XCTAssertEqual(sizing.scale, 0.725, accuracy: 0.001)
        XCTAssertFalse(sizing.clipsMiddle)
        let boundary = ThemePreviewSizing(naturalSize: CGSize(width: 1160, height: 40), availableWidth: 580)
        XCTAssertEqual(boundary.scale, ThemePreviewSizing.minimumScale)
        XCTAssertFalse(boundary.clipsMiddle)
    }

    func testPreviewSizingKeepsBothEndsAtHalfScaleWhenTheBarIsTooWide() {
        let sizing = ThemePreviewSizing(naturalSize: CGSize(width: 2400, height: 40), availableWidth: 580)
        XCTAssertEqual(sizing.scale, 0.5)
        XCTAssertTrue(sizing.clipsMiddle)
    }

    func testUnmeasuredPreviewsStayHiddenUntilTheirSizeArrives() {
        for width: CGFloat in [280, 580] {
            XCTAssertFalse(ThemePreviewSizing(naturalSize: .zero, availableWidth: width).isMeasured)
            for naturalWidth: CGFloat in [0, 200, 800, 2400] {
                XCTAssertTrue(ThemePreviewSizing(naturalSize: CGSize(width: naturalWidth, height: 40), availableWidth: width).isMeasured)
            }
            XCTAssertFalse(ThemePreviewSizing(naturalSize: CGSize(width: 2400, height: 0), availableWidth: width).isMeasured)
        }
    }

    @MainActor func testWidePreviewCardFitsItsProposedWidth() throws {
        _ = NSApplication.shared
        let fixture = try ThemeGalleryFixture(#"""
        {"widgets":[{"id":"busy","type":"text","position":"left",
         "text":"A very busy bar with many workspaces, applications, scripts and status widgets repeated across the display"},
         {"id":"clock","type":"clock","position":"right"}]}
        """#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let preview = ThemePreview.snapshot(try XCTUnwrap(store.configuration), from: store)
        let snapshot = ThemePreview.Snapshot(store: preview)
        for isStore in [false, true] {
            for width: CGFloat in [280, 580] {
                let host = NSHostingView(rootView: ThemeCard(title: "Busy theme", snapshot: snapshot,
                    isSelected: !isStore, isStore: isStore, select: {}))
                host.frame = CGRect(x: 0, y: 0, width: width, height: 110)
                host.layoutSubtreeIfNeeded()
                XCTAssertLessThanOrEqual(host.fittingSize.width, width + 0.5)
                XCTAssertGreaterThan(host.fittingSize.height, 76)
            }
        }
    }

    @MainActor func testPreviewAndItsBackgroundUseTheForcedBarAppearance() async throws {
        for appearance in ["light", "dark"] {
            let fixture = try ThemeGalleryFixture(#"{"bar":{"appearance":"\#(appearance)"},"widgets":[]}"#)
            defer { fixture.close() }
            let store = try fixture.store()
            defer { store.stop() }
            store.context.appearance = appearance == "light" ? "dark" : "light"
            let gallery = ThemeGallery(store: store)
            await gallery.refresh()
            let snapshot = try XCTUnwrap(gallery.previews["minimal"])
            let card = ThemeCard(title: "Minimal", snapshot: snapshot, select: {})
            XCTAssertEqual(card.previewColorScheme, appearance == "dark" ? .dark : .light)
        }
    }
}
