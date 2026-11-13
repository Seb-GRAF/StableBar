import Foundation
import Testing
@testable import StableBar

private func style(_ json: String) throws -> WidgetStyle {
    try JSONDecoder().decode(WidgetStyle.self, from: Data(json.utf8))
}

private func output(_ json: String) throws -> ScriptOutput {
    try ScriptOutput.read(Data(json.utf8))
}

@Test func hoverShorthandBecomesTheHoverStateOfItsOwnStyle() throws {
    let decoded = try style(##"{"foreground":"#333333","hoverForeground":"#222222","hoverBackground":"#111111"}"##)
    #expect(decoded.foreground == HexColor(0x333333ff))
    #expect(decoded.states == ["hover": WidgetStyle(foreground: HexColor(0x222222ff), background: .color(HexColor(0x111111ff)))])
    #expect(decoded.hoverForeground == HexColor(0x222222ff))
    #expect(decoded.hoverBackground == .color(HexColor(0x111111ff)))
    #expect(try style(##"{"foreground":"#333333"}"##).states == nil)
    var loader = ConfigurationLoader()
    loader.themesDirectory = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Resources/themes")
    let builtIn = try loader.load(FileManager.default.temporaryDirectory.appending(path: "built-in.json"), data: Data(#"{"widgets":[]}"#.utf8))
    #expect(builtIn.defaults.hoverBackground == .color(HexColor(light: 0xffffffff, dark: 0x36383cff)))
}

@Test func aHoverWithoutABackgroundKeepsTheBackground() throws {
    let plain = try style(##"{"background":"#111111","foreground":"#444444"}"##)
    let hover = StyleStates(hover: true)
    #expect(resolveStyle([plain]).background == .color(HexColor(0x111111ff)))
    #expect(resolveStyle([plain], states: hover).background == .color(HexColor(0x111111ff)))
    #expect(resolveStyle([plain], states: hover).foreground == HexColor(0x444444ff))
    #expect(ResolvedWidgetStyle(base: plain).style(hovered: true).background == .color(HexColor(0x111111ff)))
    let theme = try style(##"{"hoverBackground":"#222222"}"##)
    let own = try style(##"{"background":"#111111","hoverBackground":"#333333","hoverForeground":"#555555"}"##)
    #expect(resolveStyle([theme, plain], states: hover).background == .color(HexColor(0x222222ff)))
    #expect(resolveStyle([theme, own], states: hover).background == .color(HexColor(0x333333ff)))
    #expect(resolveStyle([theme, own], states: hover).foreground == HexColor(0x555555ff))
    #expect(resolveStyle([theme, own]).foreground == nil)
    let resolution = ResolvedWidgetStyle(base: resolveStyle([theme, plain]))
    #expect(resolution.style(hovered: false).background == .color(HexColor(0x111111ff)))
    #expect(resolution.style(hovered: true).background == .color(HexColor(0x222222ff)))
    #expect(resolution.base.hoverBackground == .color(HexColor(0x222222ff)))
}

@Test func widgetStylesApplyInConfigurationOrderBelowTheWidgetsOwnOutput() throws {
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data(##"""
    {"defaults":{"fontSize":12},"bar":{"style":{"background":"#000000","cornerRadius":2}},"widgets":[
      {"id":"a","type":"script","command":"true","position":"left"},
      {"id":"b","type":"script","command":"true","position":"left"},
      {"id":"c","type":"script","command":"true","position":"right","style":{"foreground":"#999999"}}]}
    """##.utf8))
    var outputs = try [
        "a": output(##"{"text":"A","widgetStyles":{"c":{"foreground":"#ff0000","background":"#ff0000"}},"barStyle":{"background":"#111111","cornerRadius":4}}"##),
        "b": output(##"{"text":"B","widgetStyles":{"c":{"foreground":"#00ff00"}},"barStyle":{"background":"#222222"}}"##)
    ]
    let c = configuration.widgets[2]
    func resolved() -> WidgetStyle {
        resolveStyle(widgetStyleLayers(c, defaults: configuration.defaults, widgets: configuration.widgets, output: { outputs[$0] }))
    }
    #expect(resolved().foreground == HexColor(0x00ff00ff))
    #expect(resolved().background == .color(HexColor(0xff0000ff)))
    #expect(resolved().fontSize == 12)
    outputs["c"] = try output(##"{"text":"C","style":{"background":"#0000ff"},"color":"#ffff00"}"##)
    #expect(resolved().background == .color(HexColor(0x0000ffff)))
    #expect(resolved().foreground == HexColor(0xffff00ff))
    let bar = resolveStyle(barStyleLayers(configuration.bar.style, widgets: configuration.widgets, output: { outputs[$0] }))
    #expect(bar.background == .color(HexColor(0x222222ff)))
    #expect(bar.cornerRadius == 4)
    outputs = [:]
    #expect(resolved().foreground == HexColor(0x999999ff))
}

@Test func gradientAndColorBackgroundsReplaceEachOtherAcrossLayersAndStates() throws {
    let defaults = try style(##"{"background":"#111111","states":{"warning":{"background":{"gradient":{"colors":["#ff0000","#ffaa00"]}}}}}"##)
    let hovering = try style(##"{"hoverBackground":{"gradient":{"colors":["#000000","#ffffff"],"angle":180}}}"##)
    let painted = try style(##"{"background":{"gradient":{"colors":["#222222","#333333"]}},"states":{"warning":{"background":"#444444"}}}"##)
    let warning = BackgroundFill.gradient(BackgroundGradient(colors: [HexColor(0xff0000ff), HexColor(0xffaa00ff)]))
    let hover = BackgroundFill.gradient(BackgroundGradient(colors: [HexColor(0x000000ff), HexColor(0xffffffff)], angle: 180))
    let gradient = BackgroundFill.gradient(BackgroundGradient(colors: [HexColor(0x222222ff), HexColor(0x333333ff)]))
    #expect(ResolvedWidgetStyle(base: resolveStyle([defaults, hovering])).style(hovered: false).background == .color(HexColor(0x111111ff)))
    let state = ResolvedWidgetStyle(base: resolveStyle([defaults, hovering]), state: "warning")
    #expect(state.style(hovered: false).background == warning)
    #expect(state.style(hovered: true).background == hover)
    #expect(resolveStyle([defaults, painted]).background == gradient)
    #expect(ResolvedWidgetStyle(base: resolveStyle([defaults, painted]), state: "warning").style(hovered: false).background
        == .color(HexColor(0x444444ff)))
    let own = try #require(output(##"{"text":"A","style":{"background":"#555555"}}"##).style)
    #expect(resolveStyle([defaults, painted, own]).background == .color(HexColor(0x555555ff)))
    for fill in [hover, .gradient(BackgroundGradient(colors: [HexColor(0x000000ff), HexColor(0xffffffff)], locations: [0.2, 0.8]))] {
        #expect(try fill.configurationValue.decoded(BackgroundFill.self) == fill)
    }
}

@Test(arguments: [
    ("", UInt32(0x111111ff), UInt32(0x222222ff), UInt32(0x111111ff)),
    (##", "background":"#00000000""##, 0x00000000, 0x222222ff, 0x111111ff),
    (##", "background":"#00000000", "popupBackground":"#334455""##, 0x00000000, 0x334455ff, 0x111111ff),
    (##", "background":"#00000000", "popupBackground":"#334455", "tooltipBackground":"#556677""##,
     0x00000000, 0x334455ff, 0x556677ff)
])
func widgetBackgroundsOverrideOnlyTheirOwnSurface(properties: String, bar: UInt32, popup: UInt32, tooltip: UInt32) throws {
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data(##"""
    {"defaults":{"background":"#888888"},"popupDefaults":{"background":"#999999"},
     "popups":{"details":{"style":{"background":"#222222"},"layout":{"type":"text","text":"Details"}}},
     "widgets":[{"id":"clock","type":"clock","position":"right","popupName":"details",
       "style":{"background":"#111111","fontSize":17}\##(properties)}]}
    """##.utf8))
    let widget = configuration.widgets[0]
    let defaults = configuration.popupDefaults.inheriting(configuration.defaults)
    let barStyle = resolveStyle(widgetStyleLayers(widget, defaults: configuration.defaults, widgets: configuration.widgets, output: { _ in nil }))
    let popupStyle = try #require(configuration.popups["details"]).baseStyle(widget: widget, defaults: defaults)
    let tooltipStyle = resolveStyle([defaults, widget.tooltipStyle])
    #expect(barStyle.background == .color(HexColor(bar)))
    #expect(popupStyle.background == .color(HexColor(popup)))
    #expect(tooltipStyle.background == .color(HexColor(tooltip)))
    #expect(popupStyle.fontSize == 17)
    #expect(tooltipStyle.fontSize == 17)
}

@Test func transparentWidgetBackgroundKeepsPopupAndTooltipDefaults() throws {
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data(##"""
    {"defaults":{"background":"#888888"},"popupDefaults":{"background":"#999999"},
     "widgets":[{"id":"clock","type":"clock","position":"right","background":"#00000000",
       "popup":{"style":{},"layout":{"type":"text","text":"Details"}}}]}
    """##.utf8))
    let widget = configuration.widgets[0]
    let defaults = configuration.popupDefaults.inheriting(configuration.defaults)
    let barStyle = resolveStyle(widgetStyleLayers(widget, defaults: configuration.defaults, widgets: configuration.widgets, output: { _ in nil }))
    #expect(barStyle.background == .color(HexColor(0)))
    #expect(widget.popup?.baseStyle(widget: widget, defaults: defaults).background == .color(HexColor(0x999999ff)))
    #expect(widget.tooltipStyle.inheriting(defaults).background == .color(HexColor(0x999999ff)))
}

@Test func gradientAnglesRunClockwiseFromTowardsTheTopAsInCSS() {
    func points(_ angle: Double) -> [CGFloat] {
        let points = BackgroundGradient(colors: [HexColor(0), HexColor(0)], angle: angle).points
        return [points.start.x, points.start.y, points.end.x, points.end.y].map { ($0 * 1000).rounded() / 1000 }
    }
    #expect(points(90) == [0, 0.5, 1, 0.5])
    #expect(points(180) == [0.5, 0, 0.5, 1])
    #expect(points(0) == [0.5, 1, 0.5, 0])
    #expect(points(45) == [0, 1, 1, 0])
    #expect(points(120) == [-0.092, 0.158, 1.092, 0.842])
}

private func workspace(_ json: String) throws -> WorkspaceConfiguration {
    try JSONDecoder().decode(WorkspaceConfiguration.self, from: Data(json.utf8))
}

@Test func workspaceShorthandStylesResolveLikeBefore() throws {
    let configuration = try workspace(##"""
    {"style":{"foreground":"#111111","hoverForeground":"#222222","paddingHorizontal":5},
     "focusedStyle":{"foreground":"#333333","background":"#444444"},
     "visibleStyle":{"borderColor":"#555555","hoverForeground":"#666666"},
     "emptyStyle":{"foreground":"#777777"},
     "indicatorStyle":{"height":3,"background":"#888888"},
     "appStyle":{"foreground":"#999999","width":12},"focusedAppStyle":{"foreground":"#aaaaaa"},"visibleAppStyle":{"fontSize":10}}
    """##)
    let focused = configuration.cellStyle(.focused)
    #expect(focused.resting.foreground == HexColor(0x333333ff))
    #expect(focused.resting.background == .color(HexColor(0x444444ff)))
    #expect(focused.resting.paddingHorizontal == 5)
    #expect(focused.label(hovered: true).foreground == HexColor(0x222222ff))
    #expect(focused.label(hovered: true).background == .color(HexColor(0x444444ff)))
    let visible = configuration.cellStyle(.visible)
    #expect(visible.resting.borderColor == HexColor(0x555555ff))
    #expect(visible.resting.foreground == HexColor(0x111111ff))
    #expect(visible.label(hovered: true).foreground == HexColor(0x666666ff))
    #expect(configuration.cellStyle(.empty).resting.foreground == HexColor(0x777777ff))
    #expect(configuration.cellStyle(nil).resting.foreground == HexColor(0x111111ff))
    #expect(configuration.cellStyle(nil).label(hovered: true).foreground == HexColor(0x222222ff))
    #expect(focused.underline.height == 3)
    #expect(focused.underline.background == .color(HexColor(0x888888ff)))
    #expect(focused.glyph(hovered: false).foreground == HexColor(0xaaaaaaff))
    #expect(focused.glyph(hovered: false).width == 12)
    #expect(visible.glyph(hovered: false).fontSize == 10)
    #expect(visible.glyph(hovered: false).foreground == HexColor(0x999999ff))
    #expect(configuration.cellStyle(.empty).glyph(hovered: false).foreground == HexColor(0x999999ff))
}

@Test func blocksInheritTextStylesButKeepTheirOwnBox() throws {
    let block = try JSONDecoder().decode(PopupBlock.self, from: Data(##"""
    {"type":"field","field":"text","styleField":"tone","style":{"background":"#111111","paddingHorizontal":4}}
    """##.utf8))
    let inherited = try style(##"{"foreground":"#222222","hoverForeground":"#333333","hoverBackground":"#444444","fontSize":13}"##)
    let named = ["warm": try style(##"{"foreground":"#555555"}"##)]
    let resting = block.resolvedStyle(inherited: inherited, styles: named, fields: ["tone": "warm"], states: StyleStates())
    #expect(resting.text.foreground == HexColor(0x555555ff))
    #expect(resting.text.fontSize == 13)
    #expect(resting.box.background == .color(HexColor(0x111111ff)))
    #expect(resting.box.paddingHorizontal == 4)
    #expect(resting.box.fontSize == nil)
    #expect(resting.inherited == resting.text)
    let hovered = block.resolvedStyle(inherited: inherited, styles: named, fields: ["tone": "warm"], states: StyleStates(hover: true))
    #expect(hovered.text.foreground == HexColor(0x333333ff))
    #expect(hovered.box.background == .color(HexColor(0x111111ff)))
    #expect(hovered.inherited == resting.inherited)
    let ownHover = try JSONDecoder().decode(PopupBlock.self, from: Data(##"{"type":"divider","style":{"hoverBackground":"#666666"}}"##.utf8))
    #expect(ownHover.resolvedStyle(inherited: inherited, styles: [:], fields: [:], states: StyleStates(hover: true)).box.background
        == .color(HexColor(0x666666ff)))
    #expect(block.resolvedStyle(inherited: inherited, styles: named, fields: [:], states: StyleStates()).text.foreground
        == HexColor(0x222222ff))
}

@Test func namedOutputStylesWinOverTheBlocksOwnStyle() throws {
    let block = try JSONDecoder().decode(PopupBlock.self, from: Data(##"""
    {"type":"divider","styleSource":"warm","style":{"foreground":"#111111","background":"#222222","paddingHorizontal":4}}
    """##.utf8))
    let named = ["warm": try style(##"{"foreground":"#555555","background":"#666666"}"##)]
    let resolved = block.resolvedStyle(inherited: WidgetStyle(), styles: named, fields: [:], states: StyleStates())
    #expect(resolved.text.foreground == HexColor(0x555555ff))
    #expect(resolved.box.background == .color(HexColor(0x666666ff)))
    #expect(resolved.box.paddingHorizontal == 4)
    #expect(block.resolvedStyle(inherited: WidgetStyle(), styles: [:], fields: [:], states: StyleStates()).box.background
        == .color(HexColor(0x222222ff)))
}

@Test func hoveringACellRestylesItsAppGlyphsButNotItsIndicators() throws {
    let configuration = try workspace(##"""
    {"focusedStyle":{"background":"#444444","hoverBackground":"#555555"},
     "indicatorStyle":{"background":"#888888","hoverBackground":"#777777"},
     "appStyle":{"foreground":"#999999","hoverForeground":"#aaaaaa"},"focusedAppStyle":{"fontSize":10,"hoverForeground":"#bbbbbb"}}
    """##)
    let focused = configuration.cellStyle(.focused)
    let visible = configuration.cellStyle(.visible)
    #expect(focused.glyph(hovered: false).foreground == HexColor(0x999999ff))
    #expect(focused.glyph(hovered: true).foreground == HexColor(0xbbbbbbff))
    #expect(focused.glyph(hovered: true).fontSize == 10)
    #expect(visible.glyph(hovered: false).foreground == HexColor(0x999999ff))
    #expect(visible.glyph(hovered: true).foreground == HexColor(0xaaaaaaff))
    #expect(focused.resting.background == .color(HexColor(0x444444ff)))
    #expect(focused.underline.background == .color(HexColor(0x888888ff)))
}

@Test func explicitStatesWinOverHoverShorthandPropertyByProperty() throws {
    let decoded = try style(##"""
    {"hoverBackground":"#222222","hoverForeground":"#333333",
     "states":{"hover":{"background":"#111111"},"warning":{"foreground":"#ff0000"}}}
    """##)
    #expect(decoded.states?["hover"] == WidgetStyle(foreground: HexColor(0x333333ff), background: .color(HexColor(0x111111ff))))
    #expect(decoded.states?["warning"]?.foreground == HexColor(0xff0000ff))
    #expect(try style(#"{"states":{"hover":null}}"#).states == nil)
    #expect(try style(#"{"states":{}}"#).states == nil)
    let split = try style(##"""
    {"hoverBackground":"#222222","hoverForeground":"#333333","states":{"hover":{"foreground":"#444444","borderColor":"#555555"}}}
    """##)
    let resolved = resolveStyle([split], states: StyleStates(hover: true))
    #expect(resolved.background == .color(HexColor(0x222222ff)))
    #expect(resolved.foreground == HexColor(0x444444ff))
    #expect(resolved.borderColor == HexColor(0x555555ff))
}

@Test func themeStatesMergeWithWidgetStatesAndWinOverTheBase() throws {
    let defaults = try style(##"{"states":{"hover":{"background":"#111111","foreground":"#222222"}}}"##)
    let widget = try style(##"{"background":"#333333","hoverBackground":"#444444"}"##)
    let hovered = resolveStyle([defaults, widget], states: StyleStates(hover: true))
    #expect(hovered.background == .color(HexColor(0x444444ff)))
    #expect(hovered.foreground == HexColor(0x222222ff))
    let plain = try style(##"{"background":"#333333","foreground":"#555555"}"##)
    #expect(resolveStyle([defaults, plain], states: StyleStates(hover: true)).foreground == HexColor(0x222222ff))
    let nested = try style(##"{"states":{"focused":{"foreground":"#666666","states":{"hover":{"foreground":"#777777"}}}}}"##)
    #expect(resolveStyle([defaults, nested], states: StyleStates(workspace: .focused, hover: true)).foreground == HexColor(0x777777ff))
    #expect(resolveStyle([defaults, nested], states: StyleStates(hover: true)).foreground == HexColor(0x222222ff))
}

@Test func workspaceAndUnderlineStatesComeFromTheStatesMap() throws {
    let configuration = try workspace(##"""
    {"style":{"states":{"focused":{"foreground":"#111111"}}},"focusedStyle":{"foreground":"#222222","background":"#333333"},
     "indicator":"underline","indicatorStyle":{"height":2,"background":"#444444","states":{"visible":{"background":"#555555"}}}}
    """##)
    #expect(configuration.cellStyle(.focused).resting.foreground == HexColor(0x111111ff))
    #expect(configuration.cellStyle(.focused).resting.background == .color(HexColor(0x333333ff)))
    #expect(configuration.cellStyle(.focused).underline.background == .color(HexColor(0x444444ff)))
    #expect(configuration.cellStyle(.visible).underline.background == .color(HexColor(0x555555ff)))
    #expect(configuration.cellStyle(.visible).underline.height == 2)
}

@Test func scriptOutputStylesCarryStatesThatMergeWithTheConfiguredOnes() throws {
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data(##"""
    {"defaults":{"states":{"hover":{"background":"#111111"}}},
     "widgets":[{"id":"a","type":"script","command":"true","position":"left"}]}
    """##.utf8))
    let outputs = ["a": try output(##"{"text":"A","style":{"states":{"hover":{"foreground":"#222222"}}}}"##)]
    let layers = widgetStyleLayers(configuration.widgets[0], defaults: configuration.defaults, widgets: configuration.widgets,
                                   output: { outputs[$0] })
    let hovered = resolveStyle(layers, states: StyleStates(hover: true))
    #expect(hovered.background == .color(HexColor(0x111111ff)))
    #expect(hovered.foreground == HexColor(0x222222ff))
    #expect(resolveStyle(layers).foreground == nil)
}

@Test func nothingSetOnAWidgetRemovesAStateSetInDefaults() throws {
    var loader = ConfigurationLoader()
    let configuration = try loader.load(FileManager.default.temporaryDirectory.appending(path: "states.json"), data: Data(##"""
    {"defaults":{"states":{"hover":{"background":"#111111"}}},
     "templates":{"label":{"type":"text","position":"left","text":"T","style":{"states":{"hover":null}}}},
     "widgets":[{"id":"own","type":"text","position":"left","text":"A","style":{"states":{"hover":null}}},
                {"id":"templated","template":"label"},
                {"id":"overridden","type":"text","position":"left","text":"C"},
                {"id":"scripted","type":"script","command":"true","position":"left"}],
     "widgetOverrides":{"overridden":{"style":{"states":{"hover":null}}}}}
    """##.utf8))
    let outputs = ["scripted": try output(#"{"text":"S","style":{"states":{"hover":null}}}"#)]
    for widget in configuration.widgets {
        let layers = widgetStyleLayers(widget, defaults: configuration.defaults, widgets: configuration.widgets, output: { outputs[$0] })
        #expect(resolveStyle(layers, states: StyleStates(hover: true)).background == .color(HexColor(0x111111ff)), "\(widget.id)")
    }
}

@Test func openAppliesAfterHoverAndTheDataStateSoItsStyleShowsWhileThePointerRests() throws {
    let resolution = ResolvedWidgetStyle(base: try style(##"""
    {"background":"#000000","states":{"hover":{"background":"#111111"},"open":{"background":"#222222","borderColor":"#333333"}}}
    """##))
    #expect(resolution.style(hovered: false, open: false).background == .color(HexColor(0x000000ff)))
    #expect(resolution.style(hovered: true, open: false).background == .color(HexColor(0x111111ff)))
    #expect(resolution.style(hovered: false, open: true).background == .color(HexColor(0x222222ff)))
    #expect(resolution.style(hovered: true, open: true).background == .color(HexColor(0x222222ff)))
    let borderOnly = ResolvedWidgetStyle(base: try style(##"{"background":"#000000","states":{"open":{"borderColor":"#333333"}}}"##))
    #expect(borderOnly.style(hovered: true, open: true).background == .color(HexColor(0x000000ff)))
    #expect(borderOnly.style(hovered: true, open: true).borderColor == HexColor(0x333333ff))
    #expect(borderOnly.style(hovered: false, open: true).background == .color(HexColor(0x000000ff)))
    #expect(borderOnly.blockStates(open: true) == StyleStates(open: true))
    let warning = ResolvedWidgetStyle(base: try style(##"""
    {"foreground":"#ffffff","states":{"warning":{"foreground":"#ff0000","background":"#110000"},"open":{"background":"#222222"}}}
    """##), state: "warning")
    #expect(warning.style(hovered: false, open: true).background == .color(HexColor(0x222222ff)))
    #expect(warning.style(hovered: false, open: true).foreground == HexColor(0xff0000ff))
    #expect(warning.style(hovered: false, open: false).background == .color(HexColor(0x110000ff)))
}

@Test func dataStatesApplyBeforeHoverAndOpenAndThemeStatesBeatTheBase() throws {
    let defaults = try style(##"{"states":{"warning":{"foreground":"#ff0000","background":"#110000"}}}"##)
    let widget = try style(##"{"foreground":"#ffffff","hoverBackground":"#222222"}"##)
    let resolution = ResolvedWidgetStyle(base: resolveStyle([defaults, widget]), state: "warning")
    #expect(resolution.style(hovered: false, open: false).foreground == HexColor(0xff0000ff))
    #expect(resolution.style(hovered: false, open: false).background == .color(HexColor(0x110000ff)))
    #expect(resolution.style(hovered: true, open: false).background == .color(HexColor(0x222222ff)))
    #expect(resolution.style(hovered: true, open: false).foreground == HexColor(0xff0000ff))
    let own = try style(##"{"states":{"warning":{"foreground":"#00ff00"}}}"##)
    #expect(ResolvedWidgetStyle(base: resolveStyle([defaults, widget, own]), state: "warning").style(hovered: false).foreground
        == HexColor(0x00ff00ff))
    #expect(ResolvedWidgetStyle(base: resolveStyle([defaults, widget]), state: "unknown").style(hovered: false).foreground
        == HexColor(0xffffffff))
    #expect(resolution.blockStates(open: true) == StyleStates(data: "warning", open: true))
}

@Test func outputStateIgnoresReservedNamesAndNonStringValues() throws {
    #expect(dataState(try output(#"{"text":"x","state":"warning"}"#)) == "warning")
    #expect(dataState(try output(#"{"text":"x","state":"open"}"#)) == nil)
    #expect(dataState(try output(#"{"text":"x","state":{"door":"open"}}"#)) == nil)
    #expect(dataState(try output(#"{"text":"x","state":3}"#)) == nil)
    #expect(dataState(try output(#"{"text":"x"}"#)) == nil)
    #expect(dataState(nil) == nil)
}

@Test func layoutBlocksApplyTheWidgetsDataState() throws {
    let block = try JSONDecoder().decode(PopupBlock.self, from: Data(##"""
    {"type":"symbol","name":"bolt","style":{"states":{"warning":{"foreground":"#ff0000","background":"#330000"}}}}
    """##.utf8))
    let resolved = block.resolvedStyle(inherited: try style(##"{"foreground":"#ffffff"}"##), styles: [:], fields: [:],
                                       states: StyleStates(data: "warning"))
    #expect(resolved.text.foreground == HexColor(0xff0000ff))
    #expect(resolved.box.background == .color(HexColor(0x330000ff)))
    #expect(resolved.inherited.foreground == HexColor(0xffffffff))
}

private func rules(_ json: String) throws -> [StyleRule] {
    try JSONDecoder().decode([StyleRule].self, from: Data(json.utf8))
}

@Test func rulesMatchAtTheirThresholdsAndTheFirstMatchWins() throws {
    let battery = try rules(#"""
    [{"when":{"value":"percent","below":0.1},"state":"critical"},
     {"when":{"value":"percent","below":0.2},"state":"warning"},
     {"when":{"value":"percent","above":0.4,"below":0.6},"state":"muted"},
     {"when":{"field":"state","equals":"charging"},"state":"active"}]
    """#)
    func state(_ json: String) throws -> String? { dataState(try output(json), rules: battery) }
    #expect(try state(#"{"text":"","values":{"percent":0.2}}"#) == "warning")
    #expect(try state(#"{"text":"","values":{"percent":0.1}}"#) == "critical")
    #expect(try state(#"{"text":"","values":{"percent":0.05}}"#) == "critical")
    #expect(try state(#"{"text":"","values":{"percent":0.21}}"#) == nil)
    #expect(try state(#"{"text":"","values":{"percent":0.4}}"#) == "muted")
    #expect(try state(#"{"text":"","values":{"percent":0.6}}"#) == "muted")
    #expect(try state(#"{"text":"","values":{"percent":0.61},"fields":{"state":"charging"}}"#) == "active")
    #expect(try state(#"{"text":"","values":{"percent":0.15},"fields":{"state":"charging"}}"#) == "warning")
    #expect(try state(#"{"text":"AC","fields":{"state":"Charging"}}"#) == nil)
    #expect(try state(#"{"text":"AC"}"#) == nil)
    #expect(try state(#"{"text":"","values":{"percent":0.15},"state":"active"}"#) == "active")
    #expect(try state(#"{"text":"","values":{"percent":0.15},"state":"open"}"#) == "warning")
}

@Test func anEmptyOutputStateCountsAsNoStateSoRulesStillApply() throws {
    let battery = try rules(#"[{"when":{"value":"percent","below":0.2},"state":"warning"}]"#)
    #expect(dataState(try output(#"{"text":"","values":{"percent":0.15},"state":""}"#), rules: battery) == "warning")
    #expect(dataState(try output(#"{"text":"","values":{"percent":0.5},"state":""}"#), rules: battery) == nil)
    #expect(dataState(try output(#"{"text":"x","state":""}"#)) == nil)
}

@Test func invalidRulesNameTheirProblem() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "rules.json")
    var loader = ConfigurationLoader()
    let comparison = "Compare a value with below or above, or a field with equals."
    for (rule, message) in [
        (#"{"state":"warning"}"#, "widgets.power: rules.0: Missing property when."),
        (#"{"when":{"value":"percent","field":"state","below":0.2},"state":"warning"}"#, "widgets.power: rules.0.when: \(comparison)"),
        (#"{"when":{"value":"percent","equals":"low"},"state":"warning"}"#, "widgets.power: rules.0.when: \(comparison)"),
        (#"{"when":{"field":"state","below":1},"state":"warning"}"#, "widgets.power: rules.0.when: \(comparison)"),
        (#"{"when":{"value":"percent"},"state":"warning"}"#, "widgets.power: rules.0.when: \(comparison)"),
        (#"{"when":{"value":"percent","below":0.2},"state":"hover"}"#,
         "widgets.power: rules.0.state: hover is set by StableBar. Use a data state such as warning."),
        (#"{"when":{"value":"percent","below":0.2},"state":""}"#,
         "widgets.power: rules.0.state: A rule's state must not be empty. Use a data state such as warning."),
        (#"{"when":{"value":"percent","below":0.2},"state":"warning","color":"red"}"#, "widgets.power: rules.0.color: Unknown property.")
    ] {
        let json = #"{"widgets":[{"id":"power","type":"battery","position":"right","rules":["# + rule + "]}]}"
        let error = #expect(throws: (any Error).self) { try loader.load(url, data: Data(json.utf8)) }
        #expect(error.map(errorMessage) == message)
    }
    let clock = #"{"widgets":[{"id":"time","type":"clock","position":"right","rules":[{"when":{"value":"x","below":1},"state":"warning"}]}]}"#
    let error = #expect(throws: (any Error).self) { try loader.load(url, data: Data(clock.utf8)) }
    #expect(error.map(errorMessage) == "widgets.time: rules: Rules need a script or provider widget.")
}

@Test func rulesComeFromTemplatesTokensAndOverridesLikeOtherWidgetProperties() throws {
    var loader = ConfigurationLoader()
    let configuration = try loader.load(FileManager.default.temporaryDirectory.appending(path: "rules.json"), data: Data(#"""
    {"tokens":{"low":0.2},
     "templates":{"meter":{"type":"battery","position":"right","rules":[{"when":{"value":"percent","below":"@token.low"},"state":"warning"}]}},
     "widgets":[{"id":"power","template":"meter"},{"id":"spare","template":"meter"}],
     "widgetOverrides":{"spare":{"rules":[{"when":{"value":"percent","below":0.1},"state":"critical"}]}}}
    """#.utf8))
    #expect(configuration.widgets[0].rules.map(\.state) == ["warning"])
    #expect(configuration.widgets[0].rules.first?.when.below == 0.2)
    #expect(configuration.widgets[1].rules.map(\.state) == ["critical"])
    #expect(configuration.widgets[1].rules.first?.when.below == 0.1)
}

@Test func unannotatedNestedBlocksPreserveThemeCornersAndMenuHover() throws {
    let theme = try style(##"{"cornerRadius":0,"states":{"hover":{"background":"#123456"}}}"##)
    let column = PopupBlock(content: .column([]))
    let inherited = column.resolvedStyle(inherited: theme, styles: [:], fields: [:], states: StyleStates()).inherited
    let row = PopupBlock(content: .row([]), style: WidgetStyle(background: .color(HexColor(0xabcdefef))))
    let resolved = row.resolvedStyle(inherited: inherited, styles: [:], fields: [:], states: StyleStates())
    #expect(WidgetAppearance(resolved.text, defaults: WidgetStyle()).cornerRadius == 0)
    let menu = PopupBlock(content: .menu).resolvedStyle(inherited: resolved.inherited, styles: [:], fields: [:], states: StyleStates())
    #expect(menu.text.hoverBackground == .color(HexColor(0x123456ff)))
    #expect(menu.text.cornerRadius == 0)
}

@Test func focusedWindowStyleDecodesOnItsOwn() throws {
    let configuration = try workspace(##"{"focusedWindowStyle":{"background":"#123456","cornerRadius":6}}"##)
    #expect(configuration.focusedWindowStyle.background == .color(HexColor(0x123456ff)))
    #expect(configuration.focusedWindowStyle.cornerRadius == 6)
    #expect(configuration.cellStyle(.focused).glyph(hovered: false).background == nil)
}
