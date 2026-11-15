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
    #expect(padding(style) == padding(PopupConfiguration.defaultSpacing))
    #expect(style.foreground == HexColor(0x111111FF))
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
    {"defaults":{"paddingVertical":3},"popupDefaults":{"background":"#202020","paddingHorizontal":20,"paddingVertical":21,"spacing":9},
     "widgets":[{"id":"sound","type":"text","text":"Sound","position":"right","style":{"paddingHorizontal":0}}]}
    """#)
    let style = tooltipStyle(defaults: config.popupDefaults.popupStyle(over: config.defaults), widget: config.widgets[0].tooltipStyle)
    #expect(padding(style) == [10, 6, 6])
    #expect(style.background == .color(HexColor(0x202020FF)))
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

/// The top edge of the window a popup or tooltip opens in under a bar with `bar`'s settings.
@MainActor private func openedTop(_ kind: String, bar: String) async throws -> CGFloat {
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
    let anchor = try #require(bar.anchors(widget.id).first)
    let defaults = configuration.popupDefaults.popupStyle(over: configuration.defaults)
    switch kind {
    case "popup": popup.toggle(try #require(widget.popup), widget: widget, defaults: defaults, store: store, anchor: anchor)
    case "controls": popup.showControls(widget: widget, defaults: defaults, store: store, anchor: anchor) { _ in Text("Volume") }
    default: popup.showTooltip("Agenda", widget: widget, defaults: defaults, store: store, anchor: anchor)
    }
    let top = try #require(presented).frame.maxY
    popup.close()
    return top
}

@Test(.serialized, arguments: ["popup", "tooltip", "controls"]) @MainActor
func popupsAndTooltipsOpenAtTheBarsPopupGap(kind: String) async throws {
    let standard = try await openedTop(kind, bar: "")
    let wide = try await openedTop(kind, bar: #","popupOffset":20"#)
    #expect(standard - wide == 14)
}
