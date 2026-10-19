import AppKit
import SwiftUI
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
        let tile = NSHostingView(rootView: BarEditTile(store: store, display: display.id, entry: entry,
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
        let tile = NSHostingView(rootView: BarEditTile(store: store, display: display.id,
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
            let tile = NSHostingView(rootView: BarEditTile(store: store, display: display.id, entry: entry,
                                                         config: try XCTUnwrap(store.configuration)))
            XCTAssertGreaterThan(tile.fittingSize.width, 20)
            XCTAssertLessThan(tile.fittingSize.width, 100)
            XCTAssertLessThanOrEqual(tile.fittingSize.height, 24)
        }
    }

    @MainActor func testFifteenRealSizeRightWidgetsFitTheNotchedBarWithoutScrolling() async throws {
        let widgets = (0..<15).map {
            #"{"id":"widget-\#($0)","type":"text","text":"•","position":"right","style":{"width":18,"height":20}}"#
        }.joined(separator: ",")
        let fixture = try ThemeGalleryFixture("{\"widgets\":[\(widgets)]}")
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        store.barEditing.begin()
        let display = BarDisplay(id: 1, isBuiltIn: true, isMain: true, notch: 661...851)
        let host = NSHostingView(rootView: BarView(store: store, display: display))
        host.sizingOptions = []
        host.frame = CGRect(x: 0, y: 0, width: 1512, height: 100)
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if let right = descendants(host, of: BarEditDropTargetView.self).first(where: { $0.position == .right }),
               right.frames.count == 15, right.frames.values.allSatisfy({ $0.minX >= 0 && $0.maxX <= right.bounds.width }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let sections = descendants(host, of: BarEditDropTargetView.self)
        XCTAssertEqual(sections.count, 5)
        XCTAssertEqual(descendants(host, of: BarEditDragSourceView.self).count, 15, "The measuring copy must not add drag or accessibility targets")
        let right = try XCTUnwrap(sections.first { $0.position == .right })
        XCTAssertEqual(right.frames.count, 15)
        XCTAssertTrue(right.frames.values.allSatisfy { abs($0.width - 18) < 0.01 })
        XCTAssertTrue(right.frames.values.allSatisfy { $0.minX >= 0 && $0.maxX <= right.bounds.width },
                      "Section: \(right.frame), bounds: \(right.bounds), tiles: \(right.frames)")
        for section in sections {
            let scroll = try XCTUnwrap(descendants(section, of: NSScrollView.self).first)
            XCTAssertFalse(scroll.hasHorizontalScroller)
        }
        XCTAssertNil(host.window)
        XCTAssertLessThan(try XCTUnwrap(store.barEditing.geometry(for: display)).layoutHeight, 84)
    }

    @MainActor func testVerticalMouseWheelScrollsTheNativeViewportWithoutAKeyWindow() throws {
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 40))
        let document = NSView(frame: CGRect(x: 0, y: 0, width: 500, height: 40))
        let wheel = BarEditScrollWheelView(frame: document.bounds)
        document.addSubview(wheel)
        scroll.documentView = document
        let cgEvent = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -3, wheel2: 0, wheel3: 0))
        wheel.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: cgEvent)))
        XCTAssertGreaterThan(scroll.contentView.bounds.minX, 0)
        XCTAssertNil(scroll.window)
        XCTAssertNil(wheel.hitTest(.zero), "The wheel overlay must leave clicks and drags alone")
    }

    @MainActor func testUnorderedWindowsLayOutAllSectionsAndReportWidgetFramesWithoutRevealingTheNormalBar() async throws {
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
            let wheel = try XCTUnwrap(descendants(left, of: BarEditScrollWheelView.self).first)
            XCTAssertTrue(wheel.enclosingScrollView === scroll)
            let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -12, wheel2: 0, wheel3: 0))
            wheel.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: event)))
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

    @MainActor func testTraysOnASeeThroughBarBringABackingThatTheirTextReadsOn() async throws {
        _ = NSApplication.shared
        let display = BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil)
        // Without tiles, widget text sits on the tray itself.
        let tileless = #","background":null,"borderColor":null,"shadowColor":null"#
        let cases: [(name: String, appearance: BarAppearance, bar: String, defaults: String, darkTray: Bool)] = [
            ("Built-in", .light, "", "", false),
            ("Built-in", .dark, "", "", true),
            // A translucent strip with text that keeps its color in both appearances, as SketchyBar setups often have.
            ("fixed light text", .light, ##""style":{"background":"#1e1e2e80"},"##, ##""foreground":"#ffffff""## + tileless, true),
            ("fixed dark text", .dark, "", ##""foreground":"#1d1d1f""## + tileless, false),
            // Widgets don't draw the bar style's text color.
            ("bar style text", .light, ##""style":{"foreground":"#ffffff"},"##, String(tileless.dropFirst()), false)
        ]
        for item in cases {
            let fixture = try ThemeGalleryFixture(#"""
            {"bar":{\#(item.bar)"appearance":"\#(item.appearance.rawValue)"},"defaults":{\#(item.defaults)},
             "widgets":[{"id":"label","type":"text","text":"WWWW","position":"right"},
                        {"id":"elsewhere","type":"text","text":"Hidden","display":"builtIn","position":"right"}]}
            """#)
            defer { fixture.close() }
            let store = try fixture.store()
            defer { store.stop() }
            store.barEditing.begin()
            let render = try await editBarImage(store, on: display)
            let tray = try XCTUnwrap(render.trays[.right])
            let label = "\(item.name), \(item.appearance)"
            // Inside the tray's padding, before its + slot.
            let fill = try XCTUnwrap(render.image.colorAt(x: Int(tray.minX + 3 * render.scale), y: Int(tray.midY))?
                .usingColorSpace(.sRGB))
            XCTAssertGreaterThan(fill.alphaComponent, 0.9, "\(label): the tray needs a backing of its own over the wallpaper")
            XCTAssertEqual(brightness(fill) < 0.5, item.darkTray, label)
            let slot = CGRect(x: tray.minX + 12 * render.scale, y: tray.midY - 6 * render.scale,
                              width: 12 * render.scale, height: 12 * render.scale)
            XCTAssertGreaterThan(try contrast(in: slot, of: render.image, with: fill), 0.4, "\(label): +")
            for id in ["label", "elsewhere"] {
                // The right half of the widget, clear of its − badge.
                let frame = try XCTUnwrap(render.frames[id], id)
                let text = CGRect(x: frame.midX, y: tray.midY - 3 * render.scale,
                                  width: frame.width / 2 - render.scale, height: 6 * render.scale)
                XCTAssertGreaterThan(try contrast(in: text, of: render.image, with: fill), 0.3, "\(label): \(id)")
            }
        }
    }

    @MainActor func testTraysOnAPaintedStripKeepItsCalmTintAndReadOnIt() async throws {
        _ = NSApplication.shared
        let display = BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil)
        let tileless = #","background":null,"borderColor":null,"shadowColor":null"#
        let cases: [(name: String, appearance: BarAppearance, strip: [Int], defaults: String)] = [
            ("light strip", .light, [0xc8, 0xd8, 0xf0], ""),
            ("dark strip", .dark, [0x00, 0x40, 0x6a], ""),
            // Colors that ignore the appearance: SketchyBar-style text on its strip, and Built-in tiles on a black strip.
            ("fixed light text", .light, [0x1e, 0x1e, 0x2e], ##""foreground":"#cdd6f4""## + tileless),
            ("tiles on a black strip", .light, [0x00, 0x00, 0x00], "")
        ]
        for item in cases {
            let fixture = try ThemeGalleryFixture(#"""
            {"bar":{"style":{"background":"#\#(item.strip.map { String(format: "%02x", $0) }.joined())"},
                    "appearance":"\#(item.appearance.rawValue)"},"defaults":{\#(item.defaults)},
             "widgets":[{"id":"label","type":"text","text":"WWWW","position":"right"},
                        {"id":"elsewhere","type":"text","text":"Hidden","display":"builtIn","position":"right"}]}
            """#)
            defer { fixture.close() }
            let store = try fixture.store()
            defer { store.stop() }
            store.barEditing.begin()
            let render = try await editBarImage(store, on: display)
            let tray = try XCTUnwrap(render.trays[.right])
            let label = "\(item.name), \(item.appearance)"
            let fill = try XCTUnwrap(render.image.colorAt(x: Int(tray.minX + 3 * render.scale), y: Int(tray.midY))?
                .usingColorSpace(.sRGB))
            // The strip as drawn beside the tray, in the same color space as the tray.
            let strip = try XCTUnwrap(render.image.colorAt(x: Int(tray.minX - 3 * render.scale), y: Int(tray.midY))?
                .usingColorSpace(.sRGB))
            XCTAssertEqual(fill.redComponent, strip.redComponent, accuracy: 0.12, label)
            XCTAssertEqual(fill.greenComponent, strip.greenComponent, accuracy: 0.12, label)
            XCTAssertEqual(fill.blueComponent, strip.blueComponent, accuracy: 0.12, label)
            let slot = CGRect(x: tray.minX + 12 * render.scale, y: tray.midY - 6 * render.scale,
                              width: 12 * render.scale, height: 12 * render.scale)
            XCTAssertGreaterThan(try contrast(in: slot, of: render.image, with: fill), 0.4, "\(label): +")
            let frame = try XCTUnwrap(render.frames["elsewhere"])
            let name = CGRect(x: frame.midX, y: tray.midY - 3 * render.scale,
                              width: frame.width / 2 - render.scale, height: 6 * render.scale)
            XCTAssertGreaterThan(try contrast(in: name, of: render.image, with: fill), 0.3, "\(label): placeholder")
        }
    }

    private func brightness(_ color: NSColor) -> CGFloat {
        (color.redComponent + color.greenComponent + color.blueComponent) / 3
    }

    /// The largest brightness difference from `color` among the opaque pixels in `rect`.
    private func contrast(in rect: CGRect, of image: NSBitmapImageRep, with color: NSColor) throws -> CGFloat {
        let reference = brightness(color)
        var largest: CGFloat = 0
        for x in Int(rect.minX)..<Int(rect.maxX) {
            for y in Int(rect.minY)..<Int(rect.maxY) {
                let pixel = try XCTUnwrap(image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                if pixel.alphaComponent > 0.5 { largest = max(largest, abs(brightness(pixel) - reference)) }
            }
        }
        return largest
    }

    /// Draws the edit bar into memory, in a window that is never ordered onto the screen.
    /// Trays and widget frames are in pixels; a frame's x is exact, its y depends on the host's flip.
    @MainActor private func editBarImage(_ store: BarStore, on display: BarDisplay) async throws
        -> (image: NSBitmapImageRep, scale: CGFloat, trays: [WidgetPosition: CGRect], frames: [String: CGRect]) {
        let width: CGFloat = 900
        var height = try XCTUnwrap(store.barEditing.geometry(for: display)).layoutHeight
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: BarView(store: store, display: display))
        host.sizingOptions = []
        window.contentView = host
        let expected = Set(store.barEditing.entries(on: display).map(\.id))
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            let measured = try XCTUnwrap(store.barEditing.geometry(for: display)).layoutHeight
            if measured != height {
                height = measured
                window.setContentSize(CGSize(width: width, height: height))
            } else if expected.isSubset(of: descendants(host, of: BarEditDropTargetView.self).flatMap(\.frames.keys)) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        host.layoutSubtreeIfNeeded()
        let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        let scale = CGFloat(image.pixelsWide) / host.bounds.width
        var trays: [WidgetPosition: CGRect] = [:]
        var frames: [String: CGRect] = [:]
        for tray in descendants(host, of: BarEditDropTargetView.self) where trays[tray.position] == nil {
            let bounds = host.convert(tray.bounds, from: tray)
            let pixels = CGRect(x: bounds.minX * scale, y: bounds.minY * scale, width: bounds.width * scale, height: bounds.height * scale)
            trays[tray.position] = pixels
            for (id, frame) in tray.frames {
                frames[id] = CGRect(x: pixels.minX + frame.minX * scale, y: pixels.minY + frame.minY * scale,
                                    width: frame.width * scale, height: frame.height * scale)
            }
        }
        return (image, scale, trays, frames)
    }

    @MainActor private func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        view.subviews.flatMap { child in (child as? T).map { [$0] } ?? descendants(child, of: type) }
    }
}
