import AppKit
import SwiftUI
import XCTest
@testable import StableBar

final class BarEditViewTests: XCTestCase {
    @MainActor func testUnorderedWindowsLayOutAllSectionsAndReportWidgetFramesWithoutRevealingTheNormalBar() async throws {
        _ = NSApplication.shared
        let fixture = try ThemeGalleryFixture(#"""
        {"groups":{"pair":{}},"widgets":[{"id":"a","type":"clock","position":"left","group":"pair"},
        {"id":"b","type":"clock","position":"left","group":"pair","enabled":false},
        {"id":"c","type":"text","text":"Hello","position":"right","display":"builtIn"},
        {"id":"d","type":"clock","position":"left"},{"id":"e","type":"clock","position":"left"},
        {"id":"f","type":"clock","position":"left"}]}
        """#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        store.barEditing.begin()
        for display in [BarDisplay(id: 1, isBuiltIn: true, isMain: true, notch: 661...851),
                        BarDisplay(id: 2, isBuiltIn: false, isMain: false, notch: nil)] {
            let height = try XCTUnwrap(store.barEditing.geometry(for: display)).layoutHeight
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1512, height: height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let host = NSHostingView(rootView: BarView(store: store, display: display))
            host.sizingOptions = []
            window.contentView = host
            for _ in 0..<20 {
                host.layoutSubtreeIfNeeded()
                if descendants(host, of: BarEditDropTargetView.self).flatMap({ $0.frames.keys }).count == 6 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let sections = descendants(host, of: BarEditDropTargetView.self)
            XCTAssertEqual(Set(sections.map(\.position)), Set(WidgetPosition.allCases))
            XCTAssertTrue(sections.allSatisfy { $0.frame.width > 0 && $0.frame.height > 0 })
            let sources = descendants(host, of: BarEditDragSourceView.self)
            XCTAssertEqual(Set(sources.map(\.widgetID)), ["a", "b", "c", "d", "e", "f"])
            XCTAssertTrue(sources.allSatisfy { !$0.name.isEmpty })
            let left = try XCTUnwrap(sections.first { $0.position == .left })
            XCTAssertEqual(Set(left.frames.keys), ["a", "b", "d", "e", "f"])
            XCTAssertLessThan(try XCTUnwrap(left.frames["a"]).midX, try XCTUnwrap(left.frames["b"]).midX)
            let scroll = try XCTUnwrap(descendants(left, of: NSScrollView.self).first)
            let original = try XCTUnwrap(left.frames["a"]).minX
            scroll.contentView.scroll(to: CGPoint(x: 120, y: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
            for _ in 0..<20 {
                host.layoutSubtreeIfNeeded()
                if left.frames["a"]?.minX != original { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(try XCTUnwrap(left.frames["a"]).minX, original - 120, accuracy: 1)
            XCTAssertFalse(window.isVisible)
            store.barEditing.end()
            for _ in 0..<20 {
                host.layoutSubtreeIfNeeded()
                if descendants(host, of: BarEditDropTargetView.self).isEmpty { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(descendants(host, of: BarEditDropTargetView.self).isEmpty)
            XCTAssertTrue(descendants(host, of: BarEditDragSourceView.self).isEmpty)
            store.barEditing.begin()
        }
        store.barEditing.end()
        XCTAssertEqual(store.barEditing.widgets(on: BarDisplay(id: 2, isBuiltIn: false, isMain: false, notch: nil)).map(\.id), ["a", "d", "e", "f"])
    }

    @MainActor private func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        view.subviews.flatMap { child in (child as? T).map { [$0] } ?? descendants(child, of: type) }
    }
}
