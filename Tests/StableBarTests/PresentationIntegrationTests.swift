import AppKit
import Foundation
import Observation
import SwiftUI
import Testing
import os
@testable import StableBar

private var presentationRepository: URL {
    URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

@MainActor private func waitForPopup(_ condition: () -> Bool) async throws {
    for _ in 0..<100 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
}

/// Moves `clock` on by `step` each time the popup waits on it, until `done`, at most ten times. A sleep starts on
/// another executor, so each step waits for it with as many polls as `TestClock.waitForSleepers`.
@MainActor private func advance(_ clock: TestClock, by step: Duration = .milliseconds(200),
                                until done: () -> Bool) async throws {
    for _ in 0..<10 {
        for _ in 0..<500 {
            if done() || clock.sleeping > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        if done() { return }
        clock.advance(by: step)
        await TestClock.settle()
    }
}

/// Lets `duration` pass on `clock` once what just started waits on it, for a check that nothing happens meanwhile.
@MainActor private func letPass(_ duration: Duration, on clock: TestClock) async {
    await TestClock.settle()
    clock.advance(by: duration)
    await TestClock.settle()
}

/// A pointer above `anchor`, which is never on its way into a popup below the bar.
@MainActor private func pointer(above anchor: NSView) -> NSPoint {
    let frame = anchor.window!.convertToScreen(anchor.convert(anchor.bounds, to: nil))
    return NSPoint(x: frame.midX, y: frame.maxY + 100)
}

@Test(arguments: [false, true]) @MainActor func hoverTooltipsFitTheirTextAndDoNotCaptureClicks(long: Bool) async throws {
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data(##"""
    {"defaults":{"foreground":"#f4f4f5","background":"#25252c","borderWidth":0,"cornerRadius":9,"fontSize":12},
     "widgets":[{"id":"session","type":"text","text":"Amphetamine","position":"right",
      "popup":{"style":{},"layout":{"type":"text","text":"Session details"}}}]}
    """##.utf8))
    var presentations: [(panel: PopupPanel, onHover: Bool)] = []
    var mouse = NSPoint.zero
    let clock = TestClock()
    let popup = WidgetPopup(present: { presentations.append(($0, $1)) }, mouseLocation: { mouse }, clock: clock)
    let store = BarStore(configurationURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), popup: popup)
    store.configuration = configuration
    store.preparePresentations()
    defer { store.stop() }
    let bar = OffscreenBar(configuration: configuration,
                           display: BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil), width: 600, sharedStore: store)
    defer { bar.close() }
    await bar.settle()
    _ = try bar.bitmap(name: "hover-tooltip-before-\(long)")
    let widget = configuration.widgets[0]
    let anchor = try #require(bar.anchors(widget.id).first)
    mouse = pointer(above: anchor)
    let text = long ? Array(repeating: "Will not sleep for 1 hour", count: 20).joined(separator: " ") : "Will not sleep for 1 hour"
    func hover(_ inside: Bool) {
        popup.hover(inside, store: store, anchor: anchor) {
            popup.showTooltip(text, widget: widget, defaults: configuration.popupDefaults.inheriting(configuration.defaults),
                              store: store, anchor: anchor)
        }
    }
    hover(true)
    #expect(presentations.isEmpty)
    try await advance(clock, by: .milliseconds(400)) { !presentations.isEmpty }
    let tooltip = try #require(presentations.first)
    try capturePopup(tooltip.panel, name: "hover-tooltip-after-\(long)")
    #expect(tooltip.onHover)
    #expect(tooltip.panel.ignoresMouseEvents)
    #expect(tooltip.panel.animationBehavior == .none)
    #expect(tooltip.panel.frame.width <= 320)
    #expect(tooltip.panel.frame.height > (long ? 100 : 20))
    #expect(bar.panel.screen!.visibleFrame.contains(tooltip.panel.frame))
    #expect(store.presentations[widget.id]?.popupAnchor == nil)
    popup.toggle(widget.popup!, widget: widget, defaults: configuration.defaults, store: store, anchor: anchor)
    #expect(presentations.count == 2)
    #expect(presentations.last?.onHover == false)
    try capturePopup(try #require(presentations.last?.panel), name: "hover-tooltip-click-popup-\(long)")
    #expect(store.presentations[widget.id]?.popupAnchor == ObjectIdentifier(anchor))
    hover(false)
    await letPass(.milliseconds(250), on: clock)
    #expect(popup.isOpen)
    popup.close()
    hover(true)
    try await advance(clock, by: .milliseconds(400)) { popup.isOpen }
    hover(false)
    try await advance(clock) { !popup.isOpen }
    #expect(!popup.isOpen)
    #expect(presentations.allSatisfy { !$0.panel.isVisible })
}

@Test @MainActor func popupCommandTogglesTheWidgetsPopupOnTheActiveDisplay() async throws {
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data(#"""
    {"widgets":[{"id":"agenda-command","type":"text","text":"Agenda","position":"right",
      "popup":{"style":{},"layout":{"type":"text","text":"Today"}}}]}
    """#.utf8))
    let popup = WidgetPopup(present: { _, _ in })
    let store = BarStore(configurationURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), popup: popup)
    store.configuration = configuration
    store.preparePresentations()
    defer { store.stop() }
    let bar = OffscreenBar(configuration: configuration,
                           display: BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil), width: 600, sharedStore: store)
    defer { bar.close() }
    await bar.settle()
    store.barPanel = { _ in bar.panel }
    let anchor = try #require(bar.anchors("agenda-command").first)
    _ = try store.handle(RuntimeRequest(action: .popup, id: "agenda-command"))
    #expect(store.presentations["agenda-command"]?.popupAnchor == ObjectIdentifier(anchor))
    _ = try store.handle(RuntimeRequest(action: .popup, id: "agenda-command"))
    #expect(!popup.isOpen)
    #expect(throws: CommandFailure.self) { try store.handle(RuntimeRequest(action: .popup, id: "missing")) }
}

/// VoiceOver reads each widget's name and what it shows, and a widget's popup as the open state of a button that
/// expands. `--focus` gives the bar the keyboard at its leftmost widget; the arrow keys move along the bar, and Return
/// or Space clicks.
@Test @MainActor func focusCommandAndVoiceOverReachTheBarsWidgets() async throws {
    _ = NSApplication.shared
    // SwiftUI builds its accessibility elements only once an assistive app asks for them.
    let assistive = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
    NSApp.accessibilitySetValue(true, forAttribute: assistive)
    defer { NSApp.accessibilitySetValue(false, forAttribute: assistive) }
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data(#"""
    {"widgets":[{"id":"agenda","type":"text","text":"Agenda","position":"right",
      "popup":{"style":{},"layout":{"type":"text","text":"Today"}}},
      {"id":"bolt","type":"text","text":"","icon":"bolt.fill","position":"left","onClick":"exit 3"},
      {"id":"note","type":"text","text":"Note","position":"left"}]}
    """#.utf8))
    let popup = WidgetPopup(present: { _, _ in })
    let store = BarStore(configurationURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), popup: popup)
    store.configuration = configuration
    store.preparePresentations()
    defer { store.stop() }
    let bar = OffscreenBar(configuration: configuration,
                           display: BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil), width: 600, sharedStore: store)
    defer { bar.close() }
    bar.panel.alphaValue = 0
    await bar.settle()
    store.barPanel = { _ in bar.panel }

    func elements() async throws -> [String: NSObject] {
        func attribute(_ element: NSObject, _ getter: String) -> String? {
            element.perform(NSSelectorFromString(getter))?.takeUnretainedValue() as? String
        }
        for _ in 0..<50 {
            bar.host.layoutSubtreeIfNeeded()
            let children = bar.host.accessibilityChildren() as? [NSObject] ?? []
            let elements = Dictionary(children.map { (attribute($0, "accessibilityIdentifier") ?? "", $0) }) { first, _ in first }
            if ["agenda", "bolt", "note"].allSatisfy({ elements[$0] != nil }) { return elements }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CommandFailure(message: "The bar has no accessibility elements for its widgets.")
    }
    func read(_ element: NSObject) -> [String?] {
        ["accessibilityRole", "accessibilityLabel", "accessibilityValue"].map {
            element.perform(NSSelectorFromString($0))?.takeUnretainedValue() as? String
        }
    }
    var shown = try await elements()
    #expect(read(try #require(shown["bolt"])) == ["AXButton", "bolt", ""])
    #expect(read(try #require(shown["note"])) == ["AXStaticText", "note", "Note"])
    let agenda = try #require(shown["agenda"] as? PopupButtonAccessibilityView)
    #expect(read(agenda) == ["AXButton", "agenda", "Agenda"])
    #expect(!agenda.isAccessibilityExpanded())

    func press(_ keyCode: UInt16, _ characters: String) async throws {
        bar.panel.sendEvent(try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: bar.panel.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode)))
        await bar.settle()
    }
    _ = try store.handle(RuntimeRequest(action: .focus))
    #expect(bar.panel.focusesWidgets)
    await bar.settle()
    try await press(36, "\r")
    for _ in 0..<100 where store.actionErrors["bolt"] == nil { try await Task.sleep(for: .milliseconds(20)) }
    #expect(store.actionErrors["bolt"] != nil)
    let right = String(UnicodeScalar(NSRightArrowFunctionKey)!)
    try await press(124, right)
    try await press(124, right)
    try await press(49, " ")
    #expect(store.presentations["agenda"]?.popupAnchor != nil)
    shown = try await elements()
    #expect(try #require(shown["agenda"] as? PopupButtonAccessibilityView).isAccessibilityExpanded())
}

@Test @MainActor func hoveringPopupsWaitsAndKeepsBothTheWidgetAndPopupReachable() async throws {
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data(#"""
    {"popups":{"details":{"openOnHover":true,"style":{},"layout":{"type":"text","text":"Details"}}},
     "widgets":[{"id":"first","type":"text","text":"First","position":"right","popupName":"details"},
                {"id":"second","type":"text","text":"Second","position":"right","popupName":"details"}]}
    """#.utf8))
    var presentations: [(panel: PopupPanel, onHover: Bool)] = []
    var mouse = NSPoint.zero
    let clock = TestClock()
    let popup = WidgetPopup(present: { presentations.append(($0, $1)) }, mouseLocation: { mouse }, clock: clock)
    let store = BarStore(configurationURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), popup: popup)
    store.configuration = configuration
    store.preparePresentations()
    defer { store.stop() }
    let bar = OffscreenBar(configuration: configuration,
                           display: BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil), width: 600, sharedStore: store)
    defer { bar.close() }
    await bar.settle()
    let anchors = try configuration.widgets.map { try #require(bar.anchors($0.id).first) }
    mouse = pointer(above: anchors[0])
    let details = try #require(configuration.popups["details"])
    func hover(_ inside: Bool, _ index: Int = 0) {
        popup.hover(inside, store: store, anchor: anchors[index]) {
            popup.open(details, widget: configuration.widgets[index], defaults: configuration.defaults,
                       store: store, anchor: anchors[index], onHover: true)
        }
    }
    func click(_ index: Int = 0) {
        popup.toggle(details, widget: configuration.widgets[index], defaults: configuration.defaults, store: store, anchor: anchors[index])
    }

    hover(true)
    try await clock.waitForSleepers()
    hover(false)
    #expect(clock.sleeping == 0)
    await letPass(.milliseconds(450), on: clock)
    #expect(presentations.isEmpty)

    hover(true)
    try await clock.waitForSleepers()
    clock.advance(by: .milliseconds(399))
    await TestClock.settle()
    #expect(!popup.isOpen)
    try await advance(clock, by: .milliseconds(1)) { popup.isOpen }
    #expect(popup.isOpen)
    #expect(presentations.count == 1)
    #expect(presentations.first?.onHover == true)
    #expect(store.presentations["first"]?.popupAnchor == ObjectIdentifier(anchors[0]))
    hover(false)
    #expect(popup.isOpen)
    popup.hoverPopup(true)
    await letPass(.milliseconds(250), on: clock)
    #expect(popup.isOpen)
    popup.hoverPopup(false)
    hover(true)
    await letPass(.milliseconds(250), on: clock)
    #expect(popup.isOpen)
    #expect(presentations.count == 1)
    hover(false)
    try await advance(clock) { !popup.isOpen }
    #expect(!popup.isOpen)
    #expect(store.presentations["first"]?.popupAnchor == nil)

    hover(true)
    try await advance(clock, by: .milliseconds(400)) { popup.isOpen }
    hover(false)
    hover(true, 1)
    popup.hoverPopup(false)
    try await advance(clock) { store.presentations["second"]?.popupAnchor != nil }
    #expect(popup.isOpen)
    #expect(store.presentations["first"]?.popupAnchor == nil)
    #expect(store.presentations["second"]?.popupAnchor == ObjectIdentifier(anchors[1]))
    click(1)
    let count = presentations.count
    hover(false, 1)
    hover(true)
    await letPass(.milliseconds(500), on: clock)
    #expect(presentations.count == count)
    #expect(store.presentations["second"]?.popupAnchor == ObjectIdentifier(anchors[1]))
    click(1)
    #expect(!popup.isOpen)

    hover(true)
    click()
    #expect(presentations.last?.onHover == false)
    hover(false)
    await letPass(.milliseconds(500), on: clock)
    #expect(popup.isOpen)
    #expect(presentations.count == count + 1)
    click()
    #expect(!popup.isOpen)
    #expect(presentations.allSatisfy { !$0.panel.isVisible })
}

@Test(arguments: [-400.0, 0.0, 400.0]) func popupHoverTriangleFollowsThePopupEdges(originX: Double) {
    let origin = NSPoint(x: originX, y: 100)
    let frame = NSRect(x: -200, y: -100, width: 200, height: 100)
    let left = (origin.x + frame.minX) / 2
    let right = (origin.x + frame.maxX) / 2
    #expect(popupHoverTriangleContains(NSPoint(x: (left + right) / 2, y: 50), from: origin, to: frame))
    #expect(popupHoverTriangleContains(NSPoint(x: left, y: 50), from: origin, to: frame))
    #expect(popupHoverTriangleContains(NSPoint(x: right, y: 50), from: origin, to: frame))
    #expect(!popupHoverTriangleContains(NSPoint(x: left - 1, y: 50), from: origin, to: frame))
    #expect(!popupHoverTriangleContains(NSPoint(x: right + 1, y: 50), from: origin, to: frame))
    #expect(!popupHoverTriangleContains(NSPoint(x: origin.x, y: 101), from: origin, to: frame))
    #expect(!popupHoverTriangleContains(NSPoint(x: frame.midX, y: -1), from: origin, to: frame))
    #expect(!popupHoverTriangleContains(origin, from: origin, to: frame.offsetBy(dx: 0, dy: 100)))
}

@Test func resizingAPopupMovesTheDraggedEdgesWithinItsScreenAndMinimumSize() {
    let frame = NSRect(x: 100, y: 100, width: 300, height: 200)
    let screen = NSRect(x: 0, y: 0, width: 1000, height: 800)
    let minSize = NSSize(width: 240, height: 140)
    #expect(resizedPopupFrame(frame, moving: [.bottom, .leading], by: NSPoint(x: -50, y: -30), minSize: minSize, within: screen)
            == NSRect(x: 50, y: 70, width: 350, height: 230))
    #expect(resizedPopupFrame(frame, moving: .trailing, by: NSPoint(x: -100, y: -30), minSize: minSize, within: screen)
            == NSRect(x: 100, y: 100, width: 240, height: 200))
    #expect(resizedPopupFrame(frame, moving: .top, by: NSPoint(x: 0, y: 900), minSize: minSize, within: screen)
            == NSRect(x: 100, y: 100, width: 300, height: 700))
    #expect(resizedPopupFrame(frame, moving: .leading, by: NSPoint(x: -500, y: 0), minSize: minSize, within: screen)
            == NSRect(x: 0, y: 100, width: 400, height: 200))
}

@Test(arguments: [false, true], ["enter", "stop", "away"]) @MainActor
func hoverTriangleProtectsDiagonalMovementUntilThePointerEntersStopsOrLeaves(replace: Bool, finish: String) async throws {
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data(#"""
    {"bar":{"morphPopups":false},
     "popups":{"details":{"openOnHover":true,"animation":{"duration":0},
       "style":{},"layout":{"type":"text","text":"Details"}}},
     "widgets":[{"id":"first","type":"text","text":"First","position":"right","popupName":"details"},
                {"id":"second","type":"text","text":"Second","position":"right","popupName":"details"}]}
    """#.utf8))
    var presentations: [PopupPanel] = []
    var point = NSPoint.zero
    var moving = false
    var samples = 0
    let clock = TestClock()
    let popup = WidgetPopup(present: { panel, _ in presentations.append(panel) }, mouseLocation: {
        if moving {
            point.y -= 0.25
            samples += 1
        }
        return point
    }, clock: clock)
    let store = BarStore(configurationURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), popup: popup)
    store.configuration = configuration
    store.preparePresentations()
    defer { store.stop() }
    let bar = OffscreenBar(configuration: configuration,
                           display: BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil), width: 600, sharedStore: store)
    defer { bar.close() }
    await bar.settle()
    let anchors = try configuration.widgets.map { try #require(bar.anchors($0.id).first) }
    let details = try #require(configuration.popups["details"])
    let frame = bar.panel.convertToScreen(anchors[0].convert(anchors[0].bounds, to: nil))
    popup.open(details, widget: configuration.widgets[0], defaults: configuration.defaults,
               store: store, anchor: anchors[0], onHover: true)
    point = NSPoint(x: frame.midX, y: frame.minY)
    popup.hover(false, store: store, anchor: anchors[0]) {}
    let target = try #require(presentations.first).frame
    point.x += (target.midX - point.x) * (frame.maxY - point.y) / (frame.maxY - target.maxY)
    moving = true
    if replace {
        popup.hover(true, store: store, anchor: anchors[1]) {
            popup.showTooltip("Neighbour", widget: configuration.widgets[1], defaults: configuration.defaults,
                              store: store, anchor: anchors[1])
        }
    }
    try await advance(clock) { samples >= 4 }
    #expect(samples >= 4)
    #expect(popup.isOpen)
    #expect(presentations.count == 1)
    moving = false
    if finish == "enter" {
        if replace { popup.hover(false, store: store, anchor: anchors[1]) {} }
        popup.hoverPopup(true)
        await letPass(.milliseconds(250), on: clock)
        #expect(popup.isOpen)
        #expect(presentations.count == 1)
        popup.hoverPopup(false)
        try await advance(clock) { !popup.isOpen }
        #expect(!popup.isOpen)
    } else {
        if finish == "away" { point.x = target.minX - 100 }
        try await advance(clock) { replace ? presentations.count == 2 : !popup.isOpen }
        #expect(replace ? presentations.count == 2 : !popup.isOpen)
    }
    #expect(presentations.allSatisfy { !$0.isVisible })
}

/// Moving on cancels what a hover would show, also when its wait ran out while the main thread was busy and only its
/// continuation is left to run: the test clock ends the wait, and the cancel comes before the main actor runs it.
@Test @MainActor func aHoverCancelledAfterItsWaitRanOutDoesNotShow() async throws {
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data(#"""
    {"bar":{"morphPopups":false},
     "popups":{"details":{"openOnHover":true,"animation":{"duration":0},
       "style":{},"layout":{"type":"text","text":"Details"}}},
     "widgets":[{"id":"first","type":"text","text":"First","position":"right","popupName":"details"},
                {"id":"second","type":"text","text":"Second","position":"right","popupName":"details"}]}
    """#.utf8))
    var presentations: [PopupPanel] = []
    var point = NSPoint.zero
    var moving = false
    let clock = TestClock()
    let popup = WidgetPopup(present: { panel, _ in presentations.append(panel) }, mouseLocation: {
        if moving { point.y -= 0.25 }
        return point
    }, clock: clock)
    let store = BarStore(configurationURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), popup: popup)
    store.configuration = configuration
    store.preparePresentations()
    defer { store.stop() }
    let bar = OffscreenBar(configuration: configuration,
                           display: BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil), width: 600, sharedStore: store)
    defer { bar.close() }
    await bar.settle()
    let anchors = try configuration.widgets.map { try #require(bar.anchors($0.id).first) }
    let details = try #require(configuration.popups["details"])
    let frame = bar.panel.convertToScreen(anchors[0].convert(anchors[0].bounds, to: nil))
    popup.open(details, widget: configuration.widgets[0], defaults: configuration.defaults,
               store: store, anchor: anchors[0], onHover: true)
    let target = try #require(presentations.first).frame

    // The pointer heads for the popup across the neighbour, whose tooltip waits while it moves.
    point = NSPoint(x: frame.midX, y: frame.minY)
    popup.hover(false, store: store, anchor: anchors[0]) {}
    point.x += (target.midX - point.x) * (frame.maxY - point.y) / (frame.maxY - target.maxY)
    moving = true
    popup.hover(true, store: store, anchor: anchors[1]) {
        popup.showTooltip("Neighbour", widget: configuration.widgets[1], defaults: configuration.defaults,
                          store: store, anchor: anchors[1])
    }
    for _ in 0..<2 {
        try await clock.waitForSleepers()
        clock.advance(by: .milliseconds(200))
    }
    try await clock.waitForSleepers()
    clock.advance(by: .milliseconds(200))
    moving = false
    popup.hover(false, store: store, anchor: anchors[1]) {}
    popup.hoverPopup(true)
    await TestClock.settle()
    #expect(presentations.count == 1)
}

/// Coming back into a popup keeps it open, also when its close delay ran out while the main thread was busy: the test
/// clock ends the delay, and the pointer comes back before the main actor runs what's left of it.
@Test @MainActor func aPopupEnteredAfterItsCloseDelayRanOutStaysOpen() async throws {
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data(#"""
    {"popups":{"details":{"openOnHover":true,"animation":{"duration":0},"style":{},"layout":{"type":"text","text":"Details"}}},
     "widgets":[{"id":"first","type":"text","text":"First","position":"right","popupName":"details"}]}
    """#.utf8))
    let clock = TestClock()
    let popup = WidgetPopup(present: { _, _ in }, mouseLocation: { .zero }, clock: clock)
    let store = BarStore(configurationURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), popup: popup)
    store.configuration = configuration
    store.preparePresentations()
    defer { store.stop() }
    let bar = OffscreenBar(configuration: configuration,
                           display: BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil), width: 600, sharedStore: store)
    defer { bar.close() }
    await bar.settle()
    let anchor = try #require(bar.anchors("first").first)
    popup.open(try #require(configuration.popups["details"]), widget: configuration.widgets[0], defaults: configuration.defaults,
               store: store, anchor: anchor, onHover: true)
    popup.hoverPopup(true)
    popup.hover(false, store: store, anchor: anchor) {}
    popup.hoverPopup(false)
    try await clock.waitForSleepers()
    clock.advance(by: .milliseconds(200))
    popup.hoverPopup(true)
    await TestClock.settle()
    #expect(popup.isOpen)
}

/// Only the open state sets a background, so opening the popup makes glass start drawing behind the widget,
/// as leaving a widget whose hover background disappears does.
@Test(arguments: [false, true]) @MainActor func clickedPopupStaysOpenWhenItsWidgetBackgroundChanges(glass: Bool) async throws {
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data(#"""
    {"bar":{"glass":{"enabled":\#(glass)}},
     "popups":{"details":{"style":{},"layout":{"type":"text","text":"Details"}}},
     "widgets":[{"id":"first","type":"text","text":"First","position":"right","popupName":"details",
                 "style":{"states":{"open":{"background":"#ff0000"}}}}]}
    """#.utf8))
    let popup = WidgetPopup(present: { _, _ in })
    let store = BarStore(configurationURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), popup: popup)
    store.configuration = configuration
    store.preparePresentations()
    defer { store.stop() }
    let bar = OffscreenBar(configuration: configuration,
                           display: BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil), width: 600, sharedStore: store)
    defer { bar.close() }
    await bar.settle()
    let anchor = try #require(bar.anchors("first").first)
    let details = try #require(configuration.popups["details"])

    popup.toggle(details, widget: configuration.widgets[0], defaults: configuration.defaults, store: store, anchor: anchor)
    await bar.settle()
    try await Task.sleep(for: .milliseconds(100))
    #expect(popup.isOpen)
    #expect(store.presentations["first"]?.popupAnchor == ObjectIdentifier(anchor))
}

/// A popup whose content is read when it opens, such as the Menu bar items row, opens once the read ends while the pointer
/// stays, and not at all when the pointer leaves during the read.
@Test(arguments: [false, true]) @MainActor func hoverThatReadsItsPopupFirstOpensOnlyIfThePointerStays(leaves: Bool) async throws {
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data(#"""
    {"widgets":[{"id":"items","type":"text","text":"Items","position":"right",
      "popup":{"openOnHover":true,"style":{},"layout":{"type":"text","text":"Items"}}}]}
    """#.utf8))
    let clock = TestClock()
    let popup = WidgetPopup(present: { _, _ in }, clock: clock)
    let store = BarStore(configurationURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), popup: popup)
    store.configuration = configuration
    store.preparePresentations()
    defer { store.stop() }
    let bar = OffscreenBar(configuration: configuration,
                           display: BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil), width: 600, sharedStore: store)
    defer { bar.close() }
    await bar.settle()
    let widget = configuration.widgets[0]
    let anchor = try #require(bar.anchors(widget.id).first)
    var reading = false
    popup.hover(true, store: store, anchor: anchor) {
        reading = true
        try? await clock.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        popup.open(widget.popup!, widget: widget, defaults: configuration.defaults, store: store, anchor: anchor, onHover: true)
    }
    try await advance(clock, by: .milliseconds(400)) { reading }
    #expect(reading)
    // The read's sleep starts on another executor, after `reading` is set.
    try await clock.waitForSleepers()
    if leaves { popup.hover(false, store: store, anchor: anchor) {} }
    await letPass(.milliseconds(500), on: clock)
    #expect(popup.isOpen == !leaves)
    popup.close()
}

/// A click on a widget whose popup is open keeps one opened on hover open and closes one opened by a click, without the
/// popup's configuration, which the Menu bar items widget reads only to open its row.
@Test @MainActor func clickingAWidgetWithItsPopupOpenKeepsAHoverPopupAndClosesAClickedOne() async throws {
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data(#"""
    {"widgets":[{"id":"items","type":"text","text":"Items","position":"right",
      "popup":{"openOnHover":true,"style":{},"layout":{"type":"text","text":"Items"}}}]}
    """#.utf8))
    let clock = TestClock()
    let popup = WidgetPopup(present: { _, _ in }, clock: clock)
    let store = BarStore(configurationURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), popup: popup)
    store.configuration = configuration
    store.preparePresentations()
    defer { store.stop() }
    let bar = OffscreenBar(configuration: configuration,
                           display: BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil), width: 600, sharedStore: store)
    defer { bar.close() }
    await bar.settle()
    let widget = configuration.widgets[0]
    let anchor = try #require(bar.anchors(widget.id).first)
    #expect(!popup.toggleIfOpen(widget.id, anchor: anchor))

    popup.open(widget.popup!, widget: widget, defaults: configuration.defaults, store: store, anchor: anchor, onHover: true)
    #expect(popup.toggleIfOpen(widget.id, anchor: anchor))
    popup.hover(false, store: store, anchor: anchor) {}
    popup.hoverPopup(false)
    await letPass(.milliseconds(300), on: clock)
    #expect(popup.isOpen)
    #expect(popup.toggleIfOpen(widget.id, anchor: anchor))
    #expect(!popup.isOpen)

    popup.toggle(widget.popup!, widget: widget, defaults: configuration.defaults, store: store, anchor: anchor)
    #expect(popup.toggleIfOpen(widget.id, anchor: anchor))
    #expect(!popup.isOpen)
}

@Test(arguments: [false, true]) @MainActor func pendingHoverIsCancelledWhenDismissedOrRemoved(remove: Bool) async throws {
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data(#"""
    {"widgets":[{"id":"agenda","type":"text","text":"Agenda","position":"right",
      "popup":{"openOnHover":true,"style":{},"layout":{"type":"text","text":"Today"}}}]}
    """#.utf8))
    var presentations = 0
    let clock = TestClock()
    let popup = WidgetPopup(present: { _, _ in presentations += 1 }, clock: clock)
    let store = BarStore(configurationURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), popup: popup)
    store.configuration = configuration
    store.preparePresentations()
    defer { store.stop() }
    let bar = OffscreenBar(configuration: configuration,
                           display: BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil), width: 600, sharedStore: store)
    defer { bar.close() }
    await bar.settle()
    let widget = configuration.widgets[0]
    let anchor = try #require(bar.anchors(widget.id).first)
    popup.hover(true, store: store, anchor: anchor) {
        popup.open(widget.popup!, widget: widget, defaults: configuration.defaults, store: store, anchor: anchor, onHover: true)
    }
    try await clock.waitForSleepers()
    if remove { popup.removeAnchor(anchor) } else { popup.close() }
    #expect(clock.sleeping == 0)
    await letPass(.milliseconds(500), on: clock)
    #expect(presentations == 0)
    #expect(!popup.isOpen)
    #expect(store.presentations[widget.id]?.popupAnchor == nil)
}

/// A widget drawn in the tiles of the bar being edited in place has an anchor in no window.
@Test @MainActor func hoverOnAnAnchorOutsideAnyWindowShowsNothing() async throws {
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data(#"""
    {"widgets":[{"id":"battery","type":"text","text":"Battery","position":"right"}]}
    """#.utf8))
    var presentations = 0
    let clock = TestClock()
    let popup = WidgetPopup(present: { _, _ in presentations += 1 }, clock: clock)
    let store = BarStore(configurationURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), popup: popup)
    store.configuration = configuration
    defer { store.stop() }
    let widget = configuration.widgets[0]
    let anchor = NSView()
    popup.hover(true, store: store, anchor: anchor) {
        popup.showTooltip("Charging", widget: widget, defaults: configuration.defaults, store: store, anchor: anchor)
    }
    try await clock.waitForSleepers()
    await letPass(.milliseconds(500), on: clock)
    #expect(presentations == 0)
}

@Test(arguments: [false, true], [false, true]) @MainActor
func popupResizesWithItsContentAndKeepsItsWidthAndTopEdge(fixedHeight: Bool, animated: Bool) async throws {
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data("""
    {"widgets":[{"id":"update","type":"text","text":"Update","position":"right","popup":{
        \(fixedHeight ? "\"height\":140," : "")
        \(animated ? "\"animation\":{\"duration\":0.05}," : "")
        "style":{"width":300,"paddingHorizontal":14,"paddingVertical":14},
        "layout":{"type":"text","text":"An update is available"}}}]}
    """.utf8))
    var presented: PopupPanel?
    let popup = WidgetPopup(present: { panel, _ in presented = panel })
    let store = BarStore(configurationURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), popup: popup)
    store.configuration = configuration
    store.preparePresentations()
    defer { store.stop() }
    let bar = OffscreenBar(configuration: configuration,
                           display: BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil), width: 600, sharedStore: store)
    defer { bar.close() }
    await bar.settle()
    let widget = configuration.widgets[0]
    popup.toggle(widget.popup!, widget: widget, defaults: configuration.defaults, store: store,
                 anchor: try #require(bar.anchors(widget.id).first))
    let panel = try #require(presented)
    defer { popup.close() }
    let opened = panel.frame
    for _ in 0..<8 {
        panel.contentView!.layoutSubtreeIfNeeded()
        let host = panel.contentView!.subviews[0]
        host.cacheDisplay(in: host.bounds, to: try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds)))
        try await Task.sleep(for: .milliseconds(25))
    }
    let initial = panel.frame
    #expect(initial == opened)
    for lines in [5, 100, 0] {
        store.actionErrors[widget.id] = lines == 0 ? nil : Array(repeating: "Download progress", count: lines).joined(separator: "\n")
        for _ in 0..<8 {
            panel.contentView!.layoutSubtreeIfNeeded()
            let host = panel.contentView!.subviews[0]
            host.cacheDisplay(in: host.bounds, to: try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds)))
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(panel.frame.width == initial.width)
        #expect(abs(panel.frame.maxY - initial.maxY) < 0.5)
        #expect(panel.frame.minY >= bar.panel.screen!.visibleFrame.minY + 8)
        #expect(panel.contentView!.subviews[0].frame == panel.contentView!.bounds)
        if fixedHeight || lines == 0 {
            #expect(abs(panel.frame.height - initial.height) < 0.5)
        } else {
            #expect(panel.frame.height > initial.height)
        }
        #expect(!panel.isVisible)
    }
}

/// A pinned popup outlives what closes the open popup, keeps resizing with its content until it's resized by hand, returns
/// under its widget when unpinned, and goes back to where it was dragged, at its size, when pinned again or reopened after
/// closing pinned. Dragging an open popup pins it (#89).
@Test @MainActor func pinnedPopupsStayOnScreenAndReturnUnderTheirWidget() async throws {
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data("""
    {"widgets":[{"id":"ask","type":"text","text":"Ask","position":"right","popup":{"pinnable":true,
        "style":{"width":300},"layout":{"type":"text","text":"Answer"}}},
                {"id":"other","type":"text","text":"Other","position":"right","popup":{"style":{},"layout":{"type":"text","text":"Other"}}}]}
    """.utf8))
    var presented: [PopupPanel] = []
    let popup = WidgetPopup(present: { panel, _ in presented.append(panel) })
    let store = BarStore(configurationURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), popup: popup)
    store.configuration = configuration
    store.preparePresentations()
    defer { store.stop() }
    let bar = OffscreenBar(configuration: configuration,
                           display: BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil), width: 600, sharedStore: store)
    defer { bar.close() }
    await bar.settle()
    let (ask, other) = (configuration.widgets[0], configuration.widgets[1])
    let anchor = try #require(bar.anchors(ask.id).first)
    func click(_ widget: StableBar.WidgetConfiguration) throws {
        popup.toggle(widget.popup!, widget: widget, defaults: configuration.defaults, store: store, anchor: try #require(bar.anchors(widget.id).first))
    }
    func layOut(_ panel: PopupPanel) async throws {
        for _ in 0..<8 {
            panel.contentView!.layoutSubtreeIfNeeded()
            let host = panel.contentView!.subviews[0]
            host.cacheDisplay(in: host.bounds, to: try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds)))
            try await Task.sleep(for: .milliseconds(25))
        }
    }
    var closed: [ObjectIdentifier] = []
    let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
        let window = ObjectIdentifier(note.object as AnyObject)
        MainActor.assumeIsolated { closed.append(window) }
    }
    defer { NotificationCenter.default.removeObserver(observer) }

    try click(ask)
    let panel = try #require(presented.last)
    try await layOut(panel)
    let home = panel.frame
    popup.pin()
    #expect(popup.pins.ids == ["ask"])
    #expect(!popup.isOpen)
    #expect(panel.isMovableByWindowBackground)
    #expect(panel.resizeEdges?.resizable == .all)
    #expect(store.presentations[ask.id]?.popupAnchor == nil)

    popup.close()
    try click(other)
    #expect(popup.isOpen)
    store.actionErrors[ask.id] = Array(repeating: "A longer answer", count: 5).joined(separator: "\n")
    try await layOut(panel)
    #expect(panel.frame.height > home.height)
    #expect(abs(panel.frame.maxY - home.maxY) < 0.5)
    #expect(!closed.contains(ObjectIdentifier(panel)))

    let edges = try #require(panel.resizeEdges)
    let corner = NSPoint(x: edges.inset + 2, y: edges.inset + 12)
    #expect(panel.contentView!.hitTest(corner) === edges)
    let dragged = NSRect(x: panel.frame.minX - 120, y: panel.frame.minY - 200, width: panel.frame.width + 120, height: panel.frame.height + 200)
    func mouse(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber,
                                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
    edges.mouseDown(with: try mouse(.leftMouseDown, at: corner))
    edges.mouseDragged(with: try mouse(.leftMouseDragged, at: NSPoint(x: corner.x - 120, y: corner.y - 200)))
    #expect(panel.frame == dragged)
    #expect(popup.pins.resized == ["ask"])
    store.actionErrors[ask.id] = nil
    try await layOut(panel)
    #expect(panel.frame == dragged)
    #expect(panel.contentView!.subviews[0].frame == panel.contentView!.bounds)
    popup.unpin(ask.id)
    #expect(popup.pins.ids.isEmpty)
    #expect(edges.resizable == [.leading, .trailing, .bottom])
    #expect(store.presentations[ask.id]?.popupAnchor == ObjectIdentifier(anchor))
    #expect(store.presentations[other.id]?.popupAnchor == nil)
    try await waitForPopup { panel.frame.maxY == home.maxY }
    #expect(panel.frame.size == dragged.size && panel.frame.maxY == home.maxY)

    popup.pin()
    try await waitForPopup { panel.frame == dragged }
    #expect(panel.frame == dragged)
    try click(ask)
    #expect(popup.pins.ids.isEmpty)
    #expect(!popup.isOpen)
    try await waitForPopup { closed.contains(ObjectIdentifier(panel)) }
    #expect(closed.contains(ObjectIdentifier(panel)))

    try click(ask)
    let reopened = try #require(presented.last)
    #expect(reopened !== panel)
    #expect(popup.pins.ids == ["ask"], "A popup closed while pinned opens pinned again")
    try await waitForPopup { reopened.frame == dragged }
    #expect(reopened.frame == dragged)
    reopened.sendEvent(try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: reopened.windowNumber, context: nil, characters: "\u{1b}",
                                                     charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)))
    #expect(popup.pins.ids.isEmpty)
    try await waitForPopup { closed.contains(ObjectIdentifier(reopened)) }
    #expect(closed.contains(ObjectIdentifier(reopened)))

    try click(ask)
    let draggedAway = try #require(presented.last)
    popup.unpin(ask.id)
    let close = try #require(EditMenu.make().items[0].submenu?.items.first { $0.keyEquivalent == "w" })
    #expect(!draggedAway.validateMenuItem(close))
    NotificationCenter.default.post(name: NSWindow.willMoveNotification, object: draggedAway)
    #expect(popup.pins.ids == ["ask"])
    #expect(!popup.isOpen)
    #expect(draggedAway.validateMenuItem(close))
    draggedAway.performClose(close)
    #expect(popup.pins.ids.isEmpty)
    try await waitForPopup { closed.contains(ObjectIdentifier(draggedAway)) }
    #expect(closed.contains(ObjectIdentifier(draggedAway)))
}

/// macOS outlines a window and shapes its shadow from what the window draws, so a popup's own shadow, drawn in the
/// popup's window, got an outline near its outer edge (#180). That shadow is drawn in a window behind the popup instead.
@Test(arguments: [nil, "#00000000", "#00000059"] as [String?]) @MainActor
func popupDrawsItsOwnShadowInAWindowBehindIt(shadowColor: String?) async throws {
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data("""
    {"widgets":[{"id":"work","type":"text","text":"Work","position":"right","popup":{
        "style":{"width":300,"cornerRadius":14,"background":"#202020","shadowRadius":14,
                 "shadowColor":\(shadowColor.map { "\"\($0)\"" } ?? "null")},
        "layout":{"type":"text","text":"Reviews"}}}]}
    """.utf8))
    var presented: PopupPanel?
    let popup = WidgetPopup(present: { panel, _ in presented = panel })
    let store = BarStore(configurationURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), popup: popup)
    store.configuration = configuration
    store.preparePresentations()
    defer { store.stop() }
    let bar = OffscreenBar(configuration: configuration,
                           display: BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil), width: 600, sharedStore: store)
    defer { bar.close() }
    await bar.settle()
    let widget = configuration.widgets[0]
    popup.toggle(widget.popup!, widget: widget, defaults: configuration.defaults, store: store,
                 anchor: try #require(bar.anchors(widget.id).first))
    let panel = try #require(presented)
    func settle() async throws {
        for _ in 0..<8 {
            _ = try alpha(of: panel.contentView!, at: NSPoint(x: 1, y: 1))
            try await Task.sleep(for: .milliseconds(25))
        }
    }
    try await settle()
    #expect(panel.hasShadow)
    // The panel leaves 14 × 2 + 2 points around the popup. This point is 4 points left of it.
    let beside = NSPoint(x: 26, y: panel.frame.height / 2)
    #expect(try alpha(of: panel.contentView!, at: beside) == 0)
    guard shadowColor == "#00000059" else {
        #expect(popup.shadowWindow == nil)
        popup.close()
        return
    }
    let shadow = try #require(popup.shadowWindow)
    #expect(!shadow.hasShadow)
    #expect(shadow.ignoresMouseEvents)
    #expect(!shadow.isVisible)
    #expect(shadow.frame == panel.frame)
    #expect(try alpha(of: shadow.contentView!, at: beside) > 0)
    #expect(try alpha(of: shadow.contentView!, at: NSPoint(x: panel.frame.width / 2, y: beside.y)) == 0)
    let opened = panel.frame
    store.actionErrors[widget.id] = Array(repeating: "Pipeline failed", count: 5).joined(separator: "\n")
    try await settle()
    #expect(panel.frame.height > opened.height)
    #expect(shadow.frame == panel.frame)
    popup.close()
    #expect(popup.shadowWindow == nil)
}

@MainActor private func alpha(of view: NSView, at point: NSPoint) throws -> CGFloat {
    view.layoutSubtreeIfNeeded()
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
    // Bitmap rows run from the top.
    return try #require(bitmap.colorAt(x: Int(point.x * scale), y: Int((view.bounds.height - point.y) * scale))).alphaComponent
}

@MainActor private final class PresentationFixtureSource: DataSource {
    let output: ScriptOutput
    var starts = 0
    var stops = 0
    private var emit: (@Sendable (SourceUpdate) -> Void)?
    init(output: ScriptOutput) { self.output = output }
    func start(emit: @escaping @Sendable (SourceUpdate) -> Void) { starts += 1; self.emit = emit }
    func refresh(event: ScriptEvent) { emit?(.output(.success(output))) }
    func stop() { stops += 1; emit = nil }
}

@MainActor private func capturePopup(_ panel: PopupPanel, name: String) throws {
    guard let output = ProcessInfo.processInfo.environment["STABLEBAR_RENDER_OUTPUT"], let view = panel.contentView else { return }
    view.layoutSubtreeIfNeeded()
    let size = view.bounds.size
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((size.width * 2).rounded()),
        pixelsHigh: Int((size.height * 2).rounded()), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    bitmap.size = size
    view.cacheDisplay(in: view.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(filePath: output).appending(path: name + ".png"))
}

@Test @MainActor func deliveredTonhalleExampleRendersTwoDisplaysAndKeepsSourcesAndPopupLifecycle() async throws {
    let repository = presentationRepository
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.copyItem(at: repository.appending(path: "examples/presentation"), to: directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let packages = WidgetPackageStore(directory: directory.appending(path: "packages"))
    let inspection = try packages.install(repository.appending(path: "examples/packages/tonhalle-line"))
    #expect(inspection.manifest.version == "1.1.0")
    #expect(inspection.commands.isEmpty)
    let source = PresentationFixtureSource(output: try ScriptOutput.read(Data(contentsOf: directory.appending(path: "sample.json"))))
    var command = DataSourceType.command
    command.continuous = true
    command.makeSource = { _, _ in source }
    let registry = DataSourceRegistry(types: [command])
    var popupPanel: PopupPanel?
    let popup = WidgetPopup(present: { panel, _ in popupPanel = panel }) // actual native popup, never ordered
    let store = BarStore(configurationURL: directory.appending(path: "config.json"), registry: registry, popup: popup,
                         themesDirectory: repository.appending(path: "Resources/themes"))
    let executable = directory.appending(path: "aerospace-fixture")
    let script = #"""
    #!/bin/sh
    case "$1" in
      subscribe) printf '%s\n' '{"_event":"mode-changed","mode":"main"}'; exec /bin/sleep 60 ;;
      list-workspaces) printf '%s\n' '[{"workspace":"1","workspace-is-focused":true,"workspace-is-visible":true,"monitor-appkit-nsscreen-screens-id":1},{"workspace":"2","workspace-is-focused":false,"workspace-is-visible":false,"monitor-appkit-nsscreen-screens-id":1},{"workspace":"3","workspace-is-focused":false,"workspace-is-visible":true,"monitor-appkit-nsscreen-screens-id":2}]' ;;
      list-windows) printf '%s\n' '[{"workspace":"1","app-name":"Finder","app-bundle-id":"com.apple.finder","window-id":1,"window-title":"Window 1"},{"workspace":"1","app-name":"Terminal","app-bundle-id":"com.apple.Terminal","window-id":2,"window-title":"Window 2"},{"workspace":"3","app-name":"Finder","app-bundle-id":"com.apple.finder","window-id":3,"window-title":"Window 3"}]' ;;
    esac
    """#
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    store.workspaceStore.executablePath = { executable.path }
    store.activeApp = nil
    store.reloadConfiguration()
    defer { store.stop() }
    for _ in 0..<100 {
        if store.scripts["music"]?.output.fields?["track"] != nil && store.workspaceStore.mode == "main" { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(store.configurationError == nil)
    let configuration = try #require(store.configuration)
    #expect(configuration.widgets.count >= 15)
    let shared = try #require(store.providers["sample"])
    #expect(store.scripts["music"] === shared && store.scripts["cpu"] === shared && store.scripts["memory"] === shared)
    let laptop = OffscreenBar(configuration: configuration, display: BarDisplay(id: 1, isBuiltIn: true, isMain: true, notch: 661...851),
                             width: 1512, sharedStore: store)
    let external = OffscreenBar(configuration: configuration, display: BarDisplay(id: 2, isBuiltIn: false, isMain: false, notch: nil),
                               width: 2560, sharedStore: store)
    defer { laptop.close(); external.close() }
    store.onConfigurationChange = { laptop.refreshGeometry(); external.refreshGeometry() }
    await laptop.settle()
    await external.settle()
    #expect(laptop.anchors("hidden-example").isEmpty && external.anchors("hidden-example").isEmpty)
    #expect(laptop.anchors("mode").isEmpty)
    #expect(laptop.anchors("time").count == 1 && external.anchors("time").count == 1)
    #expect(store.presentations["time"]?.style.base.fontSize == 16)
    #expect(store.presentations["time"]?.style.base.fontWeight == "light")
    #expect(store.presentations["date"]?.style.base.fontSize == 12)
    let frames = [laptop.panel.frame, external.panel.frame, laptop.panel.drawingFrame, external.panel.drawingFrame]
    _ = try laptop.bitmap(name: "tonhalle-dark-1512-main")
    _ = try external.bitmap(name: "tonhalle-dark-2560-main")

    for (id, popupName) in [("music", "music"), ("cpu", "system"), ("meeting", "agenda"), ("time", "clock")] {
        let widget = try #require(configuration.widgets.first { $0.id == id })
        let anchor = try #require(external.anchors(id).first)
        popup.toggle(try #require(configuration.popups[popupName]), widget: widget,
            defaults: configuration.popupDefaults.inheriting(configuration.defaults), store: store, anchor: anchor)
        await external.settle()
        let panel = try #require(popupPanel)
        #expect(!panel.isVisible && popup.isOpen)
        #expect(store.presentations[id]?.popupAnchor == ObjectIdentifier(anchor))
        #expect(laptop.anchors(id).first.map(ObjectIdentifier.init) != store.presentations[id]?.popupAnchor)
        try capturePopup(panel, name: "tonhalle-dark-\(popupName)-popup")
        store.workspaceStore.acceptMode("tailing")
        #expect(popup.isOpen)
        #expect(store.barStyle.borderEdges == .all)
        #expect(store.barStyle.borderColor == HexColor(light: 0x806323ff, dark: 0xc8a866ff))
        popup.close()
        store.workspaceStore.acceptMode("main")
    }
    store.workspaceStore.acceptMode("tailing")
    for _ in 0..<100 {
        if store.presentations["mode"]?.hidden == false { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    await laptop.settle()
    _ = try laptop.bitmap(name: "tonhalle-dark-1512-command")
    _ = try external.bitmap(name: "tonhalle-dark-2560-command")
    #expect(laptop.anchors("mode").count == 1)
    #expect([laptop.panel.frame, external.panel.frame, laptop.panel.drawingFrame, external.panel.drawingFrame] == frames)
    #expect(source.starts == 1)
    let time = try #require(configuration.widgets.first { $0.id == "time" })
    popup.toggle(try #require(time.popupName.flatMap { configuration.popups[$0] }), widget: time,
        defaults: configuration.popupDefaults.inheriting(configuration.defaults), store: store, anchor: try #require(external.anchors("time").first))
    #expect(popup.isOpen)
    try store.applyEdits([ConfigurationEdit(action: .bar, properties: ["appearance": .string("light")])], persist: false)
    #expect(!popup.isOpen)
    #expect(store.workspaceStore.mode == "tailing")
    #expect(store.providers["sample"] === shared && source.starts == 1)
    await laptop.settle()
    _ = try laptop.bitmap(name: "tonhalle-light-1512-command")
    _ = try external.bitmap(name: "tonhalle-light-2560-command")
    let light = try #require(store.configuration)
    for (id, popupName) in [("music", "music"), ("cpu", "system"), ("meeting", "agenda"), ("time", "clock")] {
        let widget = try #require(light.widgets.first { $0.id == id })
        popup.toggle(try #require(light.popups[popupName]), widget: widget,
            defaults: light.popupDefaults.inheriting(light.defaults), store: store, anchor: try #require(external.anchors(id).first))
        await external.settle()
        try capturePopup(try #require(popupPanel), name: "tonhalle-light-\(popupName)-popup")
        popup.close()
    }
    store.workspaceStore.acceptMode("main")
    await laptop.settle()
    _ = try laptop.bitmap(name: "tonhalle-light-1512-main")
    _ = try external.bitmap(name: "tonhalle-light-2560-main")
    store.workspaceStore.acceptMode("tailing")
    let music = try #require(light.widgets.first { $0.id == "music" })
    popup.toggle(try #require(light.popups["music"]), widget: music, defaults: light.popupDefaults.inheriting(light.defaults),
                 store: store, anchor: try #require(external.anchors("music").first))
    #expect(popup.isOpen)
    try store.applyEdits([ConfigurationEdit(action: .theme)], persist: false)
    #expect(!popup.isOpen)
    #expect(store.workspaceStore.mode == "tailing")
    #expect(store.barStyle.borderEdges != .all)
    #expect(store.presentations["time"]?.style.base.fontSize == store.configuration?.defaults.fontSize)
    #expect(store.providers["sample"] === shared && source.starts == 1)
    await laptop.settle()
    _ = try laptop.bitmap(name: "built-in-light-1512-command")
    _ = try external.bitmap(name: "built-in-light-2560-command")
    #expect(laptop.panel.decorationPanel == nil && external.panel.decorationPanel == nil)
    let builtIn = try #require(store.configuration)
    for (id, popupName) in [("music", "music"), ("cpu", "system"), ("meeting", "agenda"), ("time", "clock")] {
        let widget = try #require(builtIn.widgets.first { $0.id == id })
        popup.toggle(try #require(builtIn.popups[popupName]), widget: widget,
            defaults: builtIn.popupDefaults.inheriting(builtIn.defaults), store: store, anchor: try #require(external.anchors(id).first))
        await external.settle()
        try capturePopup(try #require(popupPanel), name: "built-in-light-\(popupName)-popup")
        popup.close()
    }
}

@Test @MainActor func presentationPerformanceSeparatesStyleResolutionInvalidationAndNativeGeometry() async throws {
    let repository = presentationRepository
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.copyItem(at: repository.appending(path: "examples/presentation"), to: directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try WidgetPackageStore(directory: directory.appending(path: "packages"))
        .install(repository.appending(path: "examples/packages/tonhalle-line"))
    var loader = ConfigurationLoader()
    loader.themesDirectory = repository.appending(path: "Resources/themes")
    let config = try loader.load(directory.appending(path: "config.json"))
    let store = BarStore(configurationURL: directory.appending(path: "config.json"))
    store.configuration = config
    store.activeApp = nil
    store.workspaceStore.workspaces = [Workspace(name: "1", isFocused: true, isVisible: true, monitor: 1),
                                        Workspace(name: "2", isFocused: false, isVisible: true, monitor: 2)]
    let shared = ScriptWidget()
    try shared.accept(ScriptOutput.read(Data(contentsOf: directory.appending(path: "sample.json"))))
    let mode = ScriptWidget()
    try mode.accept(ScriptOutput.read(Data(#"{"text":"","hidden":true}"#.utf8)))
    for widget in config.widgets where widget.providerName == "sample" { store.scripts[widget.id] = shared }
    store.scripts["mode"] = mode
    store.preparePresentations()
    defer { store.stop() }
    let laptopDisplay = BarDisplay(id: 1, isBuiltIn: true, isMain: true, notch: 661...851)
    let externalDisplay = BarDisplay(id: 2, isBuiltIn: false, isMain: false, notch: nil)
    let laptop = OffscreenBar(configuration: config, display: laptopDisplay, width: 1512, sharedStore: store)
    let external = OffscreenBar(configuration: config, display: externalDisplay, width: 2560, sharedStore: store)
    defer { laptop.close(); external.close() }
    await laptop.settle()
    await external.settle()
    let anchorsBefore = external.anchors("time").map { $0.convert($0.bounds, to: external.host) }
    let framesBefore = [laptop.panel.drawingFrame, external.panel.drawingFrame]
    let hostingBefore = laptop.host.layoutCalls + external.host.layoutCalls
    let start = ContinuousClock.now
    for _ in 0..<100 { store.updatePresentations() }
    let elapsed = start.duration(to: .now).components
    let milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
    let changes = OSAllocatedUnfairLock(initialState: (layout: 0, widget: 0, bar: 0))
    let bar = BarView(store: store, display: laptopDisplay, nativeDecorations: true)
    for index in 0..<100 {
        withObservationTracking { _ = bar.body } onChange: { changes.withLock { $0.layout += 1 } }
        withObservationTracking { for presentation in store.presentations.values { _ = presentation.style } }
            onChange: { changes.withLock { $0.widget += 1 } }
        withObservationTracking { _ = store.barStyle } onChange: { changes.withLock { $0.bar += 1 } }
        store.workspaceStore.acceptMode(index.isMultiple(of: 2) ? "tailing" : "main")
    }
    let invalidations = changes.withLock { $0 }
    #expect(invalidations.layout == 0)
    #expect(invalidations.widget == 0)
    #expect(invalidations.bar == 100)
    await laptop.settle()
    await external.settle()
    #expect(external.anchors("time").map { $0.convert($0.bounds, to: external.host) } == anchorsBefore)
    #expect([laptop.panel.drawingFrame, external.panel.drawingFrame] == framesBefore)
    let hostingLayouts = laptop.host.layoutCalls + external.host.layoutCalls - hostingBefore
    let visibility = OSAllocatedUnfairLock(initialState: 0)
    withObservationTracking { _ = bar.body } onChange: { visibility.withLock { $0 += 1 } }
    try mode.accept(ScriptOutput.read(Data(#"{"text":"Mode","hidden":false}"#.utf8)))
    #expect(visibility.withLock { $0 } == 1)
    if let output = ProcessInfo.processInfo.environment["STABLEBAR_RENDER_OUTPUT"] {
        let metrics: [String: ConfigurationValue] = [
            "widgets": .number(Double(config.widgets.count)), "displays": .array([.number(1512), .number(2560)]),
            "styleResolutionPasses": .number(100), "styleResolutionMilliseconds": .number(milliseconds),
            "modeUpdates": .number(100), "barDecorationInvalidations": .number(Double(invalidations.bar)),
            "barLayoutViewInvalidations": .number(Double(invalidations.layout)), "widgetStyleInvalidations": .number(Double(invalidations.widget)),
            "nativeHostingLayoutCalls": .number(Double(hostingLayouts)), "anchorAndPanelGeometryUnchanged": .bool(true),
            "modeWidgetVisibilityInvalidations": .number(1),
            "note": .string("Native hosting layout calls include SwiftUI/AppKit maintenance; they are not horizontal planner executions. No speedup claim is made.")]
        try configurationData(metrics).write(to: URL(filePath: output).appending(path: "performance.json"))
    }
}

@Observable @MainActor private final class Turns {
    var rows: [[String: String]] = []
}

/// A list block drawn as a popup draws its content: inside a scroll view, animating its data changes.
private struct TurnsPopup: View {
    let turns: Turns
    let block: PopupBlock

    var body: some View {
        ScrollView {
            PopupBlockView(block: block, inheritedStyle: WidgetStyle(fontSize: 13), fields: [:],
                           context: BlockContext(lists: ["turns": turns.rows], open: { _ in }, runAction: { _, _ in }))
                .frame(width: 300)
                .animation(.snappy(duration: 0.35), value: turns.rows)
        }
    }
}

@Test @MainActor func aListThatScrollsFollowsItsEndAndShowsANewEntry() async throws {
    guard #available(macOS 15, *) else { return }
    let block = try JSONDecoder().decode(PopupBlock.self, from: Data(#"""
    {"type":"list","source":"turns","maxHeight":120,"row":{"type":"field","field":"text","wrap":true}}
    """#.utf8))
    let turns = Turns()
    let answer = String(repeating: "A line of an answer that keeps going. ", count: 6)
    turns.rows = (0..<4).map { ["text": "Turn \($0). " + answer] }
    let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: TurnsPopup(turns: turns, block: block))
    window.contentView = host
    window.orderFrontRegardless()
    defer { window.close() }
    func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
    }
    try await waitForPopup { scrollViews(in: host).count == 2 }
    let list = try #require(scrollViews(in: host).last)
    var height: CGFloat { list.documentView!.frame.height }
    var gap: CGFloat { height - list.documentVisibleRect.maxY }
    func grow(_ change: () -> Void) async throws {
        let before = height
        change()
        try await waitForPopup { height > before && gap < 1 }
    }
    try await waitForPopup { height > 120 && gap < 1 }
    #expect(gap < 1, "It opens at the end")

    try await grow { turns.rows[3]["text"]! += answer }
    #expect(gap < 1, "Growth at the end keeps the end in view")

    list.contentView.scroll(to: .zero)
    list.reflectScrolledClipView(list.contentView)
    try await grow { turns.rows.append(["text": "A new question"]) }
    #expect(gap < 1, "A new entry comes into view")
    try await grow { turns.rows[4]["text"]! += answer }
    #expect(gap < 1, "Its answer is followed as it arrives")
}

@Test @MainActor func shiftReturnStartsANewLineInAnInputThatWrapsAndReturnSends() async throws {
    let block = try JSONDecoder().decode(PopupBlock.self, from: Data(#"""
    {"type":"input","title":"Question","wrap":true,"sendButton":true,"autofocus":true,"onSubmit":"send"}
    """#.utf8))
    var sent: [String] = []
    let window = NSPanel(contentRect: NSRect(x: -6000, y: -6000, width: 300, height: 200), styleMask: [.titled, .nonactivatingPanel],
                         backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: PopupBlockView(block: block, inheritedStyle: WidgetStyle(fontSize: 13), fields: [:],
                                                                context: BlockContext(open: { _ in }, runAction: { _, environment in
                                                                    sent.append(environment["VALUE"] ?? "")
                                                                })).frame(width: 300))
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }
    try await waitForPopup { window.firstResponder is NSTextView }
    func type(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = []) throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            window.sendEvent(try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                                                           windowNumber: window.windowNumber, context: nil, characters: characters,
                                                           charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)))
        }
    }
    try type("a", code: 0)
    try type("\r", code: 36, flags: .shift)
    try type("b", code: 11)
    try await waitForPopup { (window.firstResponder as? NSTextView)?.string == "a\nb" }
    #expect((window.firstResponder as? NSTextView)?.string == "a\nb")
    #expect(sent.isEmpty)
    try type("\r", code: 36)
    try await waitForPopup { !sent.isEmpty }
    #expect(sent == ["a\nb"])
}
