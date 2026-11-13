import AppKit
import SwiftUI
import Testing
import XCTest
@testable import StableBar

final class BarEditViewTests: XCTestCase {
    @MainActor func testContentTileKeepsTheWidgetsRenderedWidth() throws {
        let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"small","type":"text","text":"Hi","position":"right","style":{"width":40,"height":20}}]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        store.barEditing.begin()
        let display = BarDisplay(id: 1, isBuiltIn: true, isMain: true, notch: 661...851)
        let entry = try XCTUnwrap(store.barEditing.entries(on: display).first)
        XCTAssertFalse(entry.usesPlaceholder)
        let tile = NSHostingView(rootView: BarEditTile(store: store, display: display.id, kind: ScreenKind(display), entry: entry,
                                                     config: try XCTUnwrap(store.configuration)))
        XCTAssertGreaterThanOrEqual(tile.fittingSize.width, 40)
        XCTAssertLessThanOrEqual(tile.fittingSize.width, 44, "The outline and overlapping remove badge must not turn a widget into a wider card")
    }

    @MainActor func testContentWiderThanTheOldCardIsNotClippedAndItsNameAddsNoCaption() throws {
        let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"a-long-widget-name-that-belongs-only-in-the-tooltip","type":"text","text":"Hi","position":"right","style":{"width":220,"height":20}}]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        store.barEditing.begin()
        let display = BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil)
        let tile = NSHostingView(rootView: BarEditTile(store: store, display: display.id, kind: ScreenKind(display),
            entry: try XCTUnwrap(store.barEditing.entries(on: display).first), config: try XCTUnwrap(store.configuration)))
        XCTAssertEqual(tile.fittingSize.width, 220, accuracy: 0.01)
        XCTAssertEqual(tile.fittingSize.height, 20, accuracy: 0.01)
    }

    @MainActor func testHiddenAndEmptyPlaceholdersKeepTheirNamesInCompactTiles() throws {
        let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"widget-00000001","type":"text","text":"","position":"right"},{"id":"elsewhere","type":"text","text":"Off","display":"builtIn","position":"right"}]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        store.barEditing.begin()
        let display = BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil)
        let entries = store.barEditing.entries(on: display)
        XCTAssertEqual(entries.map(\.name), ["Text", "elsewhere"])
        XCTAssertEqual(entries.map { $0.visibility.isHidden }, [false, true])
        for entry in entries {
            XCTAssertTrue(entry.usesPlaceholder)
            let tile = NSHostingView(rootView: BarEditTile(store: store, display: display.id, kind: ScreenKind(display), entry: entry,
                                                         config: try XCTUnwrap(store.configuration)))
            XCTAssertGreaterThan(tile.fittingSize.width, 40)
            XCTAssertLessThanOrEqual(tile.fittingSize.width, 140)
            XCTAssertEqual(tile.fittingSize.height, 22, accuracy: 0.01)
        }
    }

    @MainActor func testEveryPositionIsAZoneWithItsAddSlotAndWidgetsKeepTheirSize() async throws {
        let widgets = (0..<15).map {
            #"{"id":"widget-\#($0)","type":"text","text":"•","position":"right","style":{"width":18,"height":20}}"#
        }.joined(separator: ",")
        let fixture = try ThemeGalleryFixture("{\"widgets\":[\(widgets)]}")
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let display = BarDisplay(id: 1, isBuiltIn: true, isMain: true, notch: 661...851)
        store.barEditing.begin()
        let (window, bar) = try await editBar(store, on: display)
        defer { window.close() }
        XCTAssertEqual(descendants(bar, of: BarEditDragSourceView.self).count, 15, "The measuring copy must not add drag or accessibility targets")
        XCTAssertEqual(bar.frames.count, 15)
        XCTAssertTrue(bar.frames.values.allSatisfy { abs($0.width - 18) < 0.01 && $0.minX >= 0 && $0.maxX <= bar.bounds.width })
        XCTAssertEqual(Set(bar.spans.keys), Set(WidgetPosition.allCases), "Empty positions keep a zone to drop on")
        let right = try XCTUnwrap(bar.spans[.right])
        XCTAssertLessThan(right.lowerBound, try XCTUnwrap(bar.frames.values.map(\.minX).min()) - 20, "+ leads the right zone")
        XCTAssertTrue(bar.scrolling.isEmpty)
    }

    @MainActor func testACrowdedSideScrollsAtFullSizeAndShowsItsEndUntilScrolled() async throws {
        let widgets = (0..<12).map { #"{"id":"left-\#($0)","type":"text","text":"L","position":"left","style":{"width":60,"height":20}}"# }
            + (0..<18).map { #"{"id":"right-\#($0)","type":"text","text":"R","position":"right","style":{"width":60,"height":20}}"# }
        // A theme's notch spacing can reach into the notch.
        let fixture = try ThemeGalleryFixture("{\"bar\":{\"notchSpacing\":-20},\"widgets\":[\(widgets.joined(separator: ","))]}")
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        store.barEditing.begin()
        let display = BarDisplay(id: 1, isBuiltIn: true, isMain: true, notch: 661...851)
        let (window, bar) = try await editBar(store, on: display)
        defer { window.close() }
        XCTAssertEqual(bar.frames.count, 30, "Every widget is on the bar, none in More widgets")
        XCTAssertTrue(bar.frames.values.allSatisfy { abs($0.width - 60) < 0.01 }, "No widget shrinks")
        let notch = try XCTUnwrap(try XCTUnwrap(store.configuration).bar.layoutNotch(on: display))
        let right = (0..<18).compactMap { bar.frames["right-\($0)"] }
        XCTAssertEqual(right, right.sorted { $0.minX < $1.minX }, "The crowded side keeps its order")
        XCTAssertLessThanOrEqual(try XCTUnwrap(right.last).maxX, bar.bounds.width, "At rest the side shows its end")
        XCTAssertLessThan(try XCTUnwrap(right.first).minX, notch.upperBound, "and scrolls to its start")
        XCTAssertEqual(bar.scrolling.map(\.id), [.left, .notchRight])
        bar.scroll(bar.scrolling[1], -100)
        var scrolled = try await settled(window, store: store, display: display)
        XCTAssertEqual(try XCTUnwrap(scrolled.frames["right-0"]).minX, try XCTUnwrap(right.first).minX + 100, accuracy: 0.01)
        XCTAssertEqual(scrolled.frames["left-0"], bar.frames["left-0"], "The other side stays")
        XCTAssertEqual(scrolled.scrolling[0].visible.upperBound, notch.lowerBound, "Arrows and fades stay clear of the notch")
        scrolled.scroll(scrolled.scrolling[0], 10_000)
        scrolled = try await settled(window, store: store, display: display)
        XCTAssertEqual(try XCTUnwrap(scrolled.spans[.notchLeft]).upperBound, notch.lowerBound + 20, accuracy: 0.01,
                       "Scrolled to its end, a side ends where the bar puts it")
    }

    @MainActor func testADraggedWidgetOpensItsGapInThePositionItWouldLandIn() async throws {
        _ = NSApplication.shared
        let fixture = try ThemeGalleryFixture(#"""
        {"widgets":[{"id":"a","type":"text","text":"A","position":"right","style":{"width":40,"height":20}},
        {"id":"b","type":"text","text":"B","position":"right","style":{"width":60,"height":20}}]}
        """#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let editing = store.barEditing
        editing.begin()
        let display = BarDisplay(id: 2, isBuiltIn: false, isMain: true, notch: nil)
        let payload = editing.dragSession.begin("a")
        defer { editing.dragSession.end(payload) }
        editing.insertion = BarEditInsertion(displayID: 2, position: .center, before: nil, index: 0, x: 0)
        let (window, bar) = try await editBar(store, on: display, width: 1000)
        defer { window.close() }
        let gap = try XCTUnwrap(bar.frames["a"])
        XCTAssertTrue(try XCTUnwrap(bar.spans[.center]).contains(gap.midX), "\(gap) in \(bar.spans)")
        XCTAssertEqual(gap.width, 40, accuracy: 0.01)
        XCTAssertFalse(try XCTUnwrap(bar.spans[.right]).contains(gap.midX))
    }

    @MainActor func testTilesStayWhereTheDropLeftThemWhileTheBarCatchesUpWithTheSavedOrder() async throws {
        _ = NSApplication.shared
        let fixture = try ThemeGalleryFixture(#"""
        {"widgets":[{"id":"a","type":"text","text":"A","position":"right","style":{"width":40,"height":20}},
        {"id":"b","type":"text","text":"B","position":"right","style":{"width":60,"height":20}},
        {"id":"c","type":"text","text":"C","position":"right","style":{"width":80,"height":20}}]}
        """#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let editing = store.barEditing
        editing.begin()
        let display = BarDisplay(id: 2, isBuiltIn: false, isMain: true, notch: nil)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: BarView(store: store, display: display))
        host.sizingOptions = []
        window.contentView = host
        func positions() -> [String: CGFloat] {
            host.layoutSubtreeIfNeeded()
            return Dictionary(uniqueKeysWithValues: descendants(host, of: BarEditDragSourceView.self).map {
                ($0.widgetID, $0.convert($0.bounds, to: host).minX)
            })
        }
        let payload = editing.dragSession.begin("a")
        let target = BarEditInsertion(displayID: 2, position: .right, before: nil, index: 2, x: 0)
        editing.insertion = target
        var landed: [String: CGFloat] = [:]
        for _ in 0..<100 {
            let current = positions()
            if current == landed { break }
            landed = current
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThan(try XCTUnwrap(landed["a"]), try XCTUnwrap(landed["c"]))
        XCTAssertTrue(editing.drop(payload, at: target))
        editing.finishDrop()
        for _ in 0..<100 {
            if editing.insertion == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.configuration?.widgets.map(\.id), ["b", "c", "a"])
        XCTAssertEqual(positions(), landed)
    }

    @MainActor func testUnorderedWindowsLayOutEveryPositionAndLeaveNoDragTargetsAfterEditing() async throws {
        _ = NSApplication.shared
        let fixture = try ThemeGalleryFixture(#"""
        {"groups":{"pair":{}},"widgets":[{"id":"a","type":"clock","position":"left","group":"pair","style":{"width":1500}},
        {"id":"b","type":"clock","position":"left","group":"pair","display":"builtIn"},
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
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1512, height: 40),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let host = NSHostingView(rootView: BarView(store: store, display: display))
            host.sizingOptions = []
            window.contentView = host
            for _ in 0..<20 {
                host.layoutSubtreeIfNeeded()
                if descendants(host, of: BarEditDropTargetView.self).first?.frames.count == 6 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let bar = try XCTUnwrap(descendants(host, of: BarEditDropTargetView.self).first)
            XCTAssertEqual(Set(bar.spans.keys), Set(WidgetPosition.allCases))
            let sources = descendants(host, of: BarEditDragSourceView.self)
            XCTAssertEqual(Set(sources.map(\.widgetID)), ["a", "b", "c", "d", "e", "f"])
            XCTAssertTrue(sources.allSatisfy { !$0.name.isEmpty })
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(bar.frames["a"]).width, 1500, "A group wider than the bar keeps its size")
            XCTAssertFalse(window.isVisible)
            store.barEditing.end()
            for _ in 0..<500 {
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

    /// Lays the edit bar out in a window that is never ordered onto the screen. Close the window when done.
    @MainActor private func editBar(_ store: BarStore, on display: BarDisplay, width: CGFloat = 1512) async throws
        -> (window: NSWindow, bar: BarEditDropTargetView) {
        let height = try XCTUnwrap(store.configuration).onScreen(ScreenKind(display)).barGeometry(for: display).layoutHeight
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: BarView(store: store, display: display))
        host.sizingOptions = []
        window.contentView = host
        return (window, try await settled(window, store: store, display: display))
    }

    /// The edit bar once every widget has a frame and the frames hold for a few passes.
    @MainActor private func settled(_ window: NSWindow, store: BarStore, display: BarDisplay) async throws -> BarEditDropTargetView {
        let host = try XCTUnwrap(window.contentView)
        let expected = Set(store.barEditing.entries(on: display).map(\.id))
        var frames: [String: CGRect] = [:]
        var settled = 0
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            let current = descendants(host, of: BarEditDropTargetView.self).first?.frames ?? [:]
            if Set(current.keys) == expected, current == frames { settled += 1 } else { settled = 0 }
            frames = current
            if settled == 3 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try XCTUnwrap(descendants(host, of: BarEditDropTargetView.self).first)
    }

    @MainActor private func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        view.subviews.flatMap { child in (child as? T).map { [$0] } ?? descendants(child, of: type) }
    }
}

@Test @MainActor func aGroupWiderThanItsSideScrollsSoEveryMemberCanBeReached() async throws {
    let fixture = try ThemeGalleryFixture(#"""
    {"groups":{"pair":{}},"widgets":[{"id":"a","type":"text","text":"A","position":"right","group":"pair","style":{"width":1500,"height":20}},
    {"id":"b","type":"text","text":"B","position":"right","group":"pair","style":{"width":40,"height":20}},
    {"id":"c","type":"text","text":"C","position":"right","style":{"width":40,"height":20}}]}
    """#)
    defer { fixture.close() }
    let store = try fixture.store()
    defer { store.stop() }
    store.barEditing.begin()
    let display = BarDisplay(id: 1, isBuiltIn: true, isMain: true, notch: 661...851)
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1512, height: 100), styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    // SwiftUI hit-tests only a window that's on screen; a transparent one stays out of sight.
    window.alphaValue = 0
    defer { window.close() }
    let host = NSHostingView(rootView: BarView(store: store, display: display))
    host.sizingOptions = []
    window.contentView = host
    window.orderFrontRegardless()
    func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        view.subviews.flatMap { child in (child as? T).map { [$0] } ?? descendants(child, of: type) }
    }
    var last: CGRect?
    var settled = 0
    for _ in 0..<100 {
        host.layoutSubtreeIfNeeded()
        let current = descendants(host, of: BarEditDragSourceView.self).first { $0.widgetID == "b" }.map { $0.convert($0.bounds, to: host) }
        if let current, current == last { settled += 1 } else { settled = 0 }
        last = current
        if settled == 3 { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    let member = try #require(last)
    #expect(member.minX >= 851 && member.maxX <= 1512, "At rest the side shows the group's last member: \(member)")
    #expect(abs(member.width - 40) < 0.01, "The crowded side scrolls instead of shrinking the group")
    var selected: String?
    store.onCustomizeWidget = { selected = $0 }
    func click(_ point: CGPoint, until condition: () -> Bool) async throws -> Bool {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: host.convert(point, to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
    let selectedLast = try await click(CGPoint(x: member.midX, y: member.midY)) { selected == "b" }
    #expect(selectedLast, "A click on the member selects it")
    // The − badge overlaps the tile's top-left corner.
    let removedLast = try await click(CGPoint(x: member.minX + 1, y: member.minY + 1)) {
        store.configuration?.widgets.map(\.id) == ["a", "c"]
    }
    #expect(removedLast, "A click on the member's − badge removes it")
}

@Test @MainActor func aTileOnAScreenWithItsOwnLayoutIsNotRedrawnWhenTheRestOfTheEditBarIs() async throws {
    let fixture = try ThemeGalleryFixture(#"""
    {"widgets":[{"id":"hi","type":"text","text":"Hi","position":"right"}],"screens":{"monitor":{"layout":{"left":["hi"]}}}}
    """#)
    defer { fixture.close() }
    let store = try fixture.store()
    defer { store.stop() }
    store.barEditing.begin()
    let display = BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil)
    let host = NSHostingView(rootView: BarView(store: store, display: display))
    host.sizingOptions = []
    host.frame = CGRect(x: 0, y: 0, width: 1512, height: 100)
    func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        view.subviews.flatMap { child in (child as? T).map { [$0] } ?? descendants(child, of: type) }
    }
    var tile: BarEditDragSourceView?
    var settled = 0
    for _ in 0..<100 {
        host.layoutSubtreeIfNeeded()
        if let current = descendants(host, of: BarEditDragSourceView.self).first {
            if current === tile, current.name == "Not redrawn" { settled += 1 } else { settled = 0 }
            tile = current
            current.name = "Not redrawn"
            if settled == 3 { break }
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(settled == 3)
    let source = try #require(tile)
    // A tile redraw runs the drag source's `updateNSView`, which sets this name back to the widget's.
    source.name = "Not redrawn"
    // The edit bar redraws when anything it reads changes, such as which workspace has focus.
    for focused in [true, false, true] {
        store.workspaceStore.workspaces = [Workspace(name: "1", isFocused: focused, isVisible: true, monitor: display.id)]
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    // A drag source SwiftUI replaced would keep the name without having been left alone.
    #expect(descendants(host, of: BarEditDragSourceView.self).first === source)
    #expect(source.name == "Not redrawn")
}
