import AppKit
import Foundation
import SwiftUI
import Testing
@testable import StableBar

private func spacingConfiguration(_ json: String) throws -> Configuration {
    var loader = ConfigurationLoader()
    return try loader.load(FileManager.default.temporaryDirectory.appending(path: "popup-spacing.json"), data: Data(json.utf8))
}

private func padding(_ style: WidgetStyle) -> [Double?] {
    [style.paddingHorizontal, style.paddingVertical, style.spacing]
}

@Test func popupsTakeTheirOwnPaddingNotTheBarWidgets() throws {
    let config = try spacingConfiguration(#"""
    {"defaults":{"foreground":"#111111","paddingHorizontal":2,"paddingVertical":3,"spacing":1},
     "widgets":[{"id":"agenda","type":"text","text":"Agenda","position":"right","style":{"paddingHorizontal":4,"spacing":5},
       "popup":{"style":{},"layout":{"type":"text","text":"Today"}}}]}
    """#)
    let widget = config.widgets[0]
    let style = try #require(widget.popup).baseStyle(widget: widget, defaults: config.popupDefaults.popupStyle(over: config.defaults))
    #expect(padding(style) == [16, 16, nil])
    #expect(style.foreground == HexColor(0x111111FF))
}

/// The height of `layout` drawn in a popup under `popupDefaults`.
@MainActor private func popupHeight(_ layout: String, popupDefaults: String = "{}") throws -> CGFloat {
    let config = try spacingConfiguration(#"""
    {"defaults":{"spacing":2},"popupDefaults":\#(popupDefaults),
     "widgets":[{"id":"agenda","type":"text","text":"Agenda","position":"right","popup":{"style":{},"layout":\#(layout)}}]}
    """#)
    let store = BarStore(configurationURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
    store.configuration = config
    defer { store.stop() }
    let script = ScriptWidget()
    try script.accept(ScriptOutput.read(Data(#"{"text":"Agenda","lists":{"days":[{"name":"Today"},{"name":"Tomorrow"}]}}"#.utf8)))
    store.scripts["agenda"] = script
    let widget = config.widgets[0], popup = try #require(widget.popup)
    let style = popup.baseStyle(widget: widget, defaults: config.popupDefaults.popupStyle(over: config.defaults))
    return NSHostingView(rootView: PopupView(popup: popup, style: style, store: store, widget: widget)).fittingSize.height
}

@Test @MainActor func popupsSpaceTheirTopBlocks12AndWhatRowsColumnsAndListsHold6() throws {
    let lines = #"[{"type":"text","text":"Today"},{"type":"text","text":"Tomorrow"}]"#
    let top = #"{"type":"column","children":\#(lines)}"#
    let nested = #"{"type":"column","children":[{"type":"column","children":\#(lines)}]}"#
    let list = #"{"type":"list","source":"days","row":{"type":"field","field":"name"}}"#
    #expect(try popupHeight(top) - popupHeight(nested) == 6)
    // A list's rows aren't blocks, even when the list is the popup's whole layout.
    #expect(try popupHeight(list) == popupHeight(nested))
    #expect(try popupHeight(#"{"type":"column","children":[\#(list)]}"#) == popupHeight(nested))
    // A spacing that popupDefaults sets reaches every level, as before.
    #expect(try popupHeight(top, popupDefaults: #"{"spacing":9}"#) == popupHeight(nested, popupDefaults: #"{"spacing":9}"#))
    #expect(try popupHeight(top, popupDefaults: #"{"spacing":9}"#) - popupHeight(top) == -3)
}

@Test func popupDefaultsPadAndSpaceEveryPopupThatSetsNoneOfItsOwn() throws {
    let config = try spacingConfiguration(#"""
    {"defaults":{"paddingHorizontal":2},"popupDefaults":{"paddingHorizontal":20,"paddingVertical":21,"spacing":9},
     "widgets":[{"id":"agenda","type":"text","text":"Agenda","position":"right","popup":{"style":{},"layout":{"type":"text","text":"Today"}}},
       {"id":"tight","type":"text","text":"Tight","position":"right","popup":{"style":{"paddingHorizontal":8},"layout":{"type":"text","text":"Now"}}}]}
    """#)
    let defaults = config.popupDefaults.popupStyle(over: config.defaults)
    let agenda = config.widgets[0], tight = config.widgets[1]
    #expect(padding(try #require(agenda.popup).baseStyle(widget: agenda, defaults: defaults)) == [20, 21, 9])
    #expect(padding(try #require(tight.popup).baseStyle(widget: tight, defaults: defaults)) == [8, 21, 9])
}

@Test @MainActor func builtInPopupsFollowPopupDefaultsButAppMenusKeepTheirMenuPadding() throws {
    let config = try spacingConfiguration(#"""
    {"popupDefaults":{"paddingHorizontal":20,"paddingVertical":21,"spacing":9},
     "widgets":[{"id":"actions","type":"text","text":"Actions","position":"right","menu":[{"title":"Restart","onClick":"true"}]},
       {"id":"clock","type":"clock","position":"right"}]}
    """#)
    let store = BarStore(configurationURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
    store.configuration = config
    defer { store.stop() }
    let defaults = config.popupDefaults.popupStyle(over: config.defaults)
    let actions = config.widgets[0], clock = config.widgets[1]
    let menu = try #require(widgetPopup(actions, store: store))
    #expect(padding(menu.baseStyle(widget: actions, defaults: defaults)) == [20, 21, 4])
    for kind in [EssentialsPopup.clock, .battery, .system, .network, .calendar] {
        #expect(padding(kind.popup(timeZone: nil).baseStyle(widget: clock, defaults: defaults)) == [20, 21, 9])
    }
    #expect(padding(AppUpdate.popup.baseStyle(widget: clock, defaults: defaults)) == [20, 21, 9])
    #expect(padding(AppMenu.popup([]).baseStyle(widget: clock, defaults: defaults)) == [5, 5, 0])
}

@Test func tooltipsStayCompactWhateverThePopupAndBarPadding() throws {
    let config = try spacingConfiguration(#"""
    {"defaults":{"paddingVertical":3,"spacing":2},"popupDefaults":{"background":"#202020","paddingHorizontal":20,"paddingVertical":21,"spacing":9},
     "widgets":[{"id":"sound","type":"text","text":"Sound","position":"right","style":{"paddingHorizontal":0}}]}
    """#)
    let style = tooltipStyle(defaults: config.popupDefaults.popupStyle(over: config.defaults), widget: config.widgets[0].tooltipStyle)
    #expect(padding(style) == [10, 6, 6])
    #expect(style.background == .color(HexColor(0x202020FF)))
}

/// Hover controls lay out the widget's hover layout and apply its data state again when they draw, so they keep the
/// widget's own spacing, in its states too, but no state's padding.
@Test func tooltipsTakeTheWidgetsOwnSpacingButNotItsPaddingInEveryState() throws {
    let config = try spacingConfiguration(#"""
    {"popupDefaults":{"spacing":9,"states":{"warning":{"spacing":30}}},
     "widgets":[{"id":"sound","type":"text","text":"Sound","position":"right",
       "style":{"spacing":3,"states":{"warning":{"paddingHorizontal":20,"spacing":40,"foreground":"#ff0000"}}}},
      {"id":"plain","type":"text","text":"Plain","position":"right","style":{"states":{"critical":{"paddingVertical":12}}}}]}
    """#)
    let defaults = config.popupDefaults.popupStyle(over: config.defaults)
    let sound = tooltipStyle(defaults: defaults, widget: config.widgets[0].tooltipStyle)
    #expect(padding(sound) == [10, 6, 3])
    let warning = sound.resolved(for: StyleStates(data: "warning"))
    #expect(padding(warning) == [10, 6, 40])
    #expect(warning.foreground == HexColor(0xFF0000FF))
    let plain = tooltipStyle(defaults: defaults, widget: config.widgets[1].tooltipStyle)
    #expect(padding(plain.resolved(for: StyleStates(data: "warning"))) == [10, 6, 6])
    #expect(padding(plain.resolved(for: StyleStates(data: "critical"))) == [10, 6, 6])
}

@Test func barPopupOffsetSetsTheGapBelowTheBarUnlessAPopupSetsItsOwn() throws {
    let config = try spacingConfiguration(#"""
    {"bar":{"popupOffset":14},"screens":{"laptop":{"bar":{"popupOffset":0}}},
     "widgets":[{"id":"agenda","type":"text","text":"Agenda","position":"right","popup":{"style":{},"layout":{"type":"text","text":"Today"}}},
       {"id":"flush","type":"text","text":"Flush","position":"right","popup":{"offset":2,"style":{},"layout":{"type":"text","text":"Now"}}}]}
    """#)
    let agenda = try #require(config.widgets[0].popup), flush = try #require(config.widgets[1].popup)
    #expect(agenda.gap(below: config.bar(on: .monitor)) == 14)
    #expect(agenda.gap(below: config.bar(on: .laptop)) == 0)
    #expect(flush.gap(below: config.bar(on: .monitor)) == 2)
    #expect(agenda.gap(below: BarSettings()) == 6)
}

/// The window a popup or tooltip of `kind` opens in under a bar with `bar`'s settings, anchored on the bar or, with
/// `insidePopup`, on a row of the widget's open popup, and the frame of that anchor on screen.
@MainActor private func opened(_ kind: String, bar: String, insidePopup: Bool = false) async throws -> (window: NSRect, anchor: NSRect) {
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data(#"""
    {"bar":{"motion":"none"\#(bar)},
     "widgets":[{"id":"agenda","type":"text","text":"Agenda","position":"right","popup":{"style":{},"layout":{"type":"text","text":"Today"}}}]}
    """#.utf8))
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
    var anchor = try #require(bar.anchors(widget.id).first)
    let defaults = configuration.popupDefaults.popupStyle(over: configuration.defaults)
    var opener = popup
    if insidePopup {
        popup.toggle(try #require(widget.popup), widget: widget, defaults: defaults, store: store, anchor: anchor)
        let row = NSView(frame: NSRect(x: 30, y: 30, width: 80, height: 20))
        try #require(presented?.contentView).addSubview(row)
        anchor = row
        opener = WidgetPopup(present: { panel, _ in presented = panel })
    }
    defer { opener.close(); popup.close() }
    let anchorFrame = try #require(anchor.window).convertToScreen(anchor.convert(anchor.bounds, to: nil))
    switch kind {
    case "popup": opener.toggle(try #require(widget.popup), widget: widget, defaults: defaults, store: store, anchor: anchor)
    case "controls": opener.showControls(widget: widget, defaults: defaults, store: store, anchor: anchor) { _ in Text("Volume") }
    case "row": opener.showRow(widget: widget, defaults: defaults, store: store, anchor: anchor, sidePadding: 0) { Text("Items") }
    case "padded row": opener.showRow(widget: widget, defaults: defaults, store: store, anchor: anchor, sidePadding: 4) { Text("Items") }
    default: opener.showTooltip("Agenda", widget: widget, defaults: defaults, store: store, anchor: anchor)
    }
    return (try #require(presented).frame, anchorFrame)
}

@Test(.serialized, arguments: ["popup", "tooltip", "controls"]) @MainActor
func popupsAndTooltipsOpenAtTheBarsPopupGap(kind: String) async throws {
    let standard = try await opened(kind, bar: "").window
    let wide = try await opened(kind, bar: #","popupOffset":20"#).window
    #expect(standard.maxY - wide.maxY == 14)
}

@Test(.serialized, arguments: ["popup", "tooltip"]) @MainActor
func popupsAndTooltipsOpenedInsideAPopupKeepTheirGapWhateverTheBarsPopupGap(kind: String) async throws {
    let standard = try await opened(kind, bar: "", insidePopup: true)
    let wide = try await opened(kind, bar: #","popupOffset":20"#, insidePopup: true)
    #expect(standard.anchor.minY - standard.window.maxY == wide.anchor.minY - wide.window.maxY)
}

/// The app menu row lines its titles up with the widget's on the bar, so its sides take the widget's padding.
@Test(.serialized) @MainActor func theAppMenuRowPadsItsSidesLikeItsWidget() async throws {
    let flush = try await opened("row", bar: "").window
    let padded = try await opened("padded row", bar: "").window
    #expect(padded.width - flush.width == 8)
}
