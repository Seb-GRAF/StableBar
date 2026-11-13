import AppKit
import Foundation
import Observation
import Testing
@testable import StableBar

private func presentationConfiguration(_ json: String) throws -> Configuration {
    var loader = ConfigurationLoader()
    return try loader.load(FileManager.default.temporaryDirectory.appending(path: "roles.json"), data: Data(json.utf8))
}

@Test @MainActor func rolesAreExplicitAndTimeIsIsolatedFromDateAndPopupText() throws {
    let config = try presentationConfiguration(#"""
    {"defaults":{"fontSize":13,"fontWeight":"regular"},"popupDefaults":{"fontSize":13},
     "roles":{"time":{"fontName":"Helvetica Neue","fontSize":16,"fontWeight":"light"},"secondary":{"fontSize":12}},
     "widgets":[{"id":"time","type":"clock","role":"time","format":"HH:mm","position":"right","popup":{"style":{},"layout":{"type":"text","text":"Details"}}},
       {"id":"date","type":"clock","role":"secondary","format":"EEE d MMM","position":"right"},
       {"id":"plain","type":"clock","position":"right"},
       {"id":"explicit","type":"clock","role":"time","position":"right","style":{"fontSize":19}}]}
    """#)
    let store = BarStore(configurationURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
    store.configuration = config
    store.preparePresentations()
    defer { store.stop() }
    #expect(store.presentations["time"]?.style.base.fontSize == 16)
    #expect(store.presentations["time"]?.style.base.fontWeight == "light")
    #expect(store.presentations["date"]?.style.base.fontSize == 12)
    #expect(store.presentations["plain"]?.style.base.fontSize == 13)
    #expect(store.presentations["explicit"]?.style.base.fontSize == 19)
    let time = config.widgets[0]
    let popup = try #require(time.popup)
    let defaults = config.popupDefaults.inheriting(config.defaults)
    #expect(popup.baseStyle(widget: time, defaults: defaults).fontSize == 13)
    #expect(popup.baseStyle(widget: time, defaults: defaults).fontWeight == "regular")
    #expect(popup.baseStyle(widget: config.widgets[3], defaults: defaults).fontSize == 19)
    #expect(config.roleStyle(.button) == WidgetStyle())
}

@Test func roleCascadeUsesExplicitStyleThenOrderedOutputsThenActiveStates() throws {
    let config = try presentationConfiguration(##"""
    {"defaults":{"fontSize":13},"roles":{"time":{"fontSize":16,"states":{"mode.command":{"foreground":"#aa8844"}}}},
     "widgets":[{"id":"a","type":"text","text":"A","position":"left"},
       {"id":"clock","type":"clock","role":"time","style":{"fontSize":18,"foreground":"#ffffff"},"position":"right"}]}
    """##)
    let output = try ScriptOutput.read(Data(#"{"text":"A","widgetStyles":{"clock":{"fontSize":20}}}"#.utf8))
    let own = try ScriptOutput.read(Data(#"{"text":"B","style":{"fontSize":21}}"#.utf8))
    let overrides = OrderedStyleOverrides(widgets: config.widgets) { $0 == "a" ? output : own }
    let clock = config.widgets[1]
    let layers = widgetStyleLayers(clock, defaults: config.defaults, overrides: overrides, own: own, role: config.roleStyle(clock.role))
    #expect(resolveStyle(layers).fontSize == 21)
    #expect(resolveStyle(layers, states: StyleStates(mode: ModePresentation(mode: "tailing", aliases: ["tailing":"command"]))).foreground
        == HexColor(0xaa8844ff))
}

@Test func roleBlocksOwnTheirBoxWhileChildrenOnlyInheritTypographyAndNestedTextStates() throws {
    let config = try presentationConfiguration(##"""
    {"roles":{"heading":{"fontSize":16,"background":"#123456","paddingHorizontal":9,"width":200,
      "states":{"mode.command":{"fontSize":18,"background":"#abcdef"}}}},"widgets":[]}
    """##)
    let block = try JSONDecoder().decode(PopupBlock.self, from: Data(#"{"type":"column","role":"heading","style":{"fontSize":17},"styleSource":"emphasis","children":[]}"#.utf8))
    let mode = StyleStates(mode: ModePresentation(mode: "tailing", aliases: ["tailing":"command"]))
    let resolved = block.resolvedStyle(inherited: WidgetStyle(fontSize: 13), styles: ["emphasis": WidgetStyle(fontSize: 19)],
        fields: [:], states: mode, roles: config.roles)
    #expect(resolved.text.fontSize == 18) // active state beats every base layer
    #expect(resolved.box.background == .color(HexColor(0xabcdefff)))
    #expect(resolved.box.paddingHorizontal == 9)
    #expect(resolved.inherited.background == nil)
    #expect(resolved.inherited.width == nil)
    #expect(resolved.inherited.paddingHorizontal == nil)
    let child = PopupBlock(content: .text("Child"))
    let nested = child.resolvedStyle(inherited: resolved.inherited, styles: [:], fields: [:], states: mode, roles: config.roles)
    #expect(nested.text.fontSize == 18)
    #expect(nested.text.background == nil)
    #expect(nested.box == WidgetStyle())
}

@Test func unknownRolesAndBehaviorInsideRoleStylesAreRejectedWhileMissingRolesFallBack() throws {
    for json in [
        #"{"roles":{"unknown":{}},"widgets":[]}"#,
        #"{"roles":{"unknown":null},"widgets":[]}"#,
        #"{"widgets":[{"id":"x","type":"clock","role":"clock","position":"left"}]}"#,
        #"{"roles":{"time":{"onClick":"true"}},"widgets":[]}"#,
        #"{"roles":{"primary":{"hidden":true}},"widgets":[]}"#,
        #"{"widgets":[{"id":"x","type":"clock","position":"left","layout":{"type":"text","role":"unknown","text":"X"}}]}"#,
        #"{"workspaceDefaults":{"showEmpty":true},"widgets":[]}"#
    ] { #expect(throws: (any Error).self) { try presentationConfiguration(json) } }
    #expect(try presentationConfiguration(#"{"roles":{"time":null},"widgets":[]}"#).roleStyle(.time) == WidgetStyle())
    #expect(try presentationConfiguration(#"{"widgets":[{"id":"x","type":"clock","role":"time","position":"left"}]}"#).roleStyle(.time) == WidgetStyle())
}

@Test func workspaceDefaultsStayBelowLocalAliasesStatesGlyphsAndNulls() throws {
    let config = try presentationConfiguration(##"""
    {"workspaceDefaults":{"indicator":"underline","indicatorStyle":{"placement":"belowBar","height":2,"background":"#111111"},
      "style":{"fontSize":13,"states":{"focused":{"foreground":"#222222","fontWeight":"medium"}}},
      "appStyle":{"fontSize":14,"states":{"focused":{"foreground":"#444444"}}},
      "focusedWindowStyle":{"background":"#777777","cornerRadius":5}},"widgets":[
      {"id":"spaces","type":"workspaces","position":"left","workspace":{"showApps":false,"appGlyphs":{"Finder":"F"},
        "indicatorStyle":{"background":null},"focusedStyle":{"foreground":"#333333"},"focusedAppStyle":{"fontSize":15},
        "focusedWindowStyle":{"cornerRadius":7}}},
      {"id":"explicit","type":"workspaces","position":"right","workspace":{"indicator":"none","focusedStyle":{"foreground":"#555555"},
        "style":{"states":{"focused":{"foreground":"#666666"}}}}}]}
    """##)
    let space = try #require(config.widgets[0].workspace)
    #expect(space.indicator == .underline)
    #expect(space.indicatorStyle.placement == .belowBar)
    #expect(space.indicatorStyle.background == nil)
    #expect(space.cellStyle(.focused).resting.foreground == HexColor(0x333333ff))
    #expect(space.cellStyle(.focused).resting.fontWeight == "medium")
    #expect(space.cellStyle(.focused).app.fontSize == 15)
    #expect(space.cellStyle(.focused).app.foreground == HexColor(0x444444ff))
    #expect(space.focusedWindowStyle.background == .color(HexColor(0x777777ff)))
    #expect(space.focusedWindowStyle.cornerRadius == 7)
    #expect(space.appGlyphs == ["Finder":"F"])
    #expect(space.showApps == false)
    #expect(config.widgets[1].workspace?.indicator == WorkspaceConfiguration.Indicator.none)
    #expect(config.widgets[1].workspace?.cellStyle(.focused).resting.foreground == HexColor(0x666666ff))
    #expect(config.barGeometry(for: BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil)).outsideExtent == 2)
}

@Test func presentationComposesThroughIncludesTemplatesOverridesProfilesAndSharedEdits() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let include = #"{"roles":{"time":{"fontSize":16}},"workspaceDefaults":{"indicator":"underline","style":{"fontSize":12}},"templates":{"clock":{"type":"clock","role":"time","position":"right"}}}"#
    try Data(include.utf8).write(to: directory.appending(path: "base.json"))
    let root = #"{"includes":["base.json"],"widgets":[{"id":"time","template":"clock"},{"id":"spaces","type":"workspaces","position":"left"}],"widgetOverrides":{"time":{"role":"secondary"}},"profiles":[{"name":"work","configuration":{"roles":{"secondary":{"fontSize":14}},"workspaceDefaults":{"style":{"height":24}},"modeAliases":{"tailing":"command"}}}]}"#
    var loader = ConfigurationLoader()
    var document = try JSONDecoder().decode([String: ConfigurationValue].self, from: Data(root.utf8))
    let url = directory.appending(path: "config.json")
    let first = try loader.load(url, data: configurationData(document))
    #expect(first.widgets[0].role == .secondary)
    #expect(first.roleStyle(.secondary).fontSize == 14)
    #expect(first.widgets[1].workspace?.style.fontSize == 12)
    #expect(first.widgets[1].workspace?.style.height == 24)
    #expect(first.modeAliases == ["tailing":"command"])
    var ids = first.widgets.map(\.id)
    for edit in [ConfigurationEdit(action: .roles, properties: ["time": .object(["fontWeight": .string("light")])]),
                 ConfigurationEdit(action: .workspaceDefaults, properties: ["indicatorStyle": .object(["placement": .string("belowBar")])]),
                 ConfigurationEdit(action: .modeAliases, properties: ["resize": .string("command")])] {
        document = try edit.applying(to: document, widgetIDs: &ids)
    }
    let changed = try loader.load(url, data: configurationData(document))
    #expect(changed.roleStyle(.time).fontSize == 16)
    #expect(changed.roleStyle(.time).fontWeight == "light")
    #expect(changed.widgets[1].workspace?.indicatorStyle.placement == .belowBar)
    #expect(changed.modeAliases == ["tailing":"command", "resize":"command"])
    #expect(loader.origins["roles.time.fontSize"]?.file.hasSuffix("base.json") == true)
    #expect(loader.origins["roles.secondary.fontSize"]?.detail == "(profile work)")
}

@Test func packagesCanAnnotateRolesButCannotOwnGlobalStylesOrModeMappings() throws {
    let annotations = try JSONDecoder().decode([String: ConfigurationValue].self, from: Data(#"{"widgets":[{"id":"x","type":"clock","position":"right","role":"time","popup":{"style":{},"layout":{"type":"text","role":"heading","text":"Time"}}}]}"#.utf8))
    try validateWidgetsDocument(annotations)
    try validateCommandPackagePresentation(annotations)
    for property in ["roles", "workspaceDefaults", "modeAliases"] {
        let document: [String: ConfigurationValue] = [property: .object([:])]
        #expect(throws: (any Error).self) { try validateWidgetsDocument(document) }
        #expect(throws: (any Error).self) { try validateCommandPackagePresentation(document) }
        if property == "modeAliases" { #expect(throws: (any Error).self) { try validateThemeDocument(document) } }
        else { try validateThemeDocument(document) }
        let profile: [String: ConfigurationValue] = ["profiles": .array([.object(["name": .string("p"), "configuration": .object(document)])])]
        #expect(throws: (any Error).self) { try validateWidgetsDocument(profile) }
        #expect(throws: (any Error).self) { try validateCommandPackagePresentation(profile) }
    }
}

@Test @MainActor func popupKeepsItsBackgroundDuringCriticalDataAndCanOptIntoModeStyling() throws {
    let config = try presentationConfiguration(##"""
    {"defaults":{"background":"#111111","fontSize":13,"states":{"critical":{"background":"#ff0000"}}},
      "popupDefaults":{"background":"#222222"},"roles":{"time":{"fontSize":16}},"modeAliases":{"tailing":"command"},
      "widgets":[{"id":"clock","type":"script","command":"true","role":"time","position":"right",
       "popup":{"style":{"states":{"mode.command":{"borderColor":"#aa8844"}}},"layout":{"type":"text","role":"heading","text":"Status"}}}]}
    """##)
    let store = BarStore(configurationURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
    store.configuration = config
    let script = ScriptWidget()
    try script.accept(ScriptOutput.read(Data(#"{"text":"Time","state":"critical"}"#.utf8)))
    store.scripts["clock"] = script
    store.preparePresentations()
    defer { store.stop() }
    let widget = config.widgets[0], popup = try #require(widget.popup)
    let view = PopupView(popup: popup, style: popup.baseStyle(widget: widget, defaults: config.popupDefaults.inheriting(config.defaults)), store: store, widget: widget)
    #expect(view.presentationStyle.background == .color(HexColor(0x222222ff)))
    #expect(view.presentationStyle.fontSize == 13)
    store.workspaceStore.acceptMode("tailing")
    #expect(view.presentationStyle.background == .color(HexColor(0x222222ff)))
    #expect(view.presentationStyle.borderColor == HexColor(0xaa8844ff))
}

@Test @MainActor func queryExplainsRoleAndWorkspaceDefaultsWithSourceAndTokenOrigins() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
    var loader = ConfigurationLoader()
    let configuration = try loader.load(url, data: Data(##"""
    {"tokens":{"ink":"#123456"},"defaults":{"fontSize":13},"roles":{"time":{"fontSize":16,"foreground":"@token.ink"}},
     "workspaceDefaults":{"indicator":"underline","indicatorStyle":{"placement":"belowBar"}},
     "widgets":[{"id":"time","type":"clock","role":"time","position":"right"},
                 {"id":"spaces","type":"workspaces","position":"left"},
                 {"id":"source","type":"script","command":"true","position":"left"}]}
    """##.utf8))
    let store = BarStore(configurationURL: url)
    store.configuration = configuration
    store.effectiveDocument = loader.document
    store.origins = loader.origins
    let script = ScriptWidget()
    try script.accept(ScriptOutput.read(Data(##"{"text":"Source","barStyle":{"borderColor":"#aabbcc"}}"##.utf8)))
    store.scripts["source"] = script
    store.preparePresentations()
    defer { store.stop() }
    let snapshot = try store.snapshot(id: "time").decoded([String: ConfigurationValue].self)
    #expect(snapshot["role"] == .string("time"))
    let origins = try #require(snapshot["origins"]).decoded([String: String].self)
    #expect(origins["roles.time.foreground"]?.contains("token ink") == true)
    let layers = try #require(snapshot["presentationLayers"]).decoded([[String: ConfigurationValue]].self)
    #expect(layers.compactMap { $0["source"] } == [.string("defaults"), .string("roles.time"), .string("widgets.time.style")])
    #expect(try snapshot["resolvedStyle"]?.decoded(WidgetStyle.self).fontSize == 16)
    let spaces = try store.snapshot(id: "spaces").decoded([String: ConfigurationValue].self)
    #expect(try spaces["workspacePresentation"]?.decoded(WorkspaceConfiguration.self).indicatorStyle.placement == .belowBar)
    let root = try store.snapshot().decoded([String: ConfigurationValue].self)
    let barLayers = try #require(root["barPresentationLayers"]).decoded([[String: ConfigurationValue]].self)
    #expect(barLayers.compactMap { $0["source"] } == [.string("bar.style"), .string("output.source.barStyle")])
}

@Test @MainActor func barOnlyModeChangeDoesNotInvalidateAnUnrelatedOpenPopupView() async throws {
    let config = try presentationConfiguration(##"""
    {"bar":{"style":{"states":{"mode":{"borderColor":"#aa8844"}}}},"widgets":[
      {"id":"clock","type":"clock","position":"right","popup":{"style":{},"layout":{"type":"text","text":"Time"}}}]}
    """##)
    let store = BarStore(configurationURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
    store.configuration = config
    store.preparePresentations()
    defer { store.stop() }
    let widget = config.widgets[0], popup = try #require(widget.popup)
    let view = PopupView(popup: popup, style: popup.baseStyle(widget: widget, defaults: config.defaults), store: store, widget: widget)
    await confirmation("unrelated popup stays valid", expectedCount: 0) { invalidated in
        withObservationTracking { _ = view.body } onChange: { invalidated() }
        store.workspaceStore.acceptMode("command")
    }
}

@Test func workspaceAliasNullFallbackMatchesLegacyDecodingWithoutDefaults() throws {
    let definitions = [
        ##"{"focusedStyle":{"foreground":"#123456"},"style":{"states":{"focused":null}}}"##,
        ##"{"focusedStyle":{"foreground":"#123456"},"style":{"states":null}}"##,
        ##"{"focusedStyle":{"foreground":"#123456"},"style":null}"##,
        ##"{"focusedStyle":{"foreground":"#123456","hoverBackground":"#abcdef"},"style":{"states":{"focused":{"foreground":null}}}}"##,
        ##"{"visibleAppStyle":{"foreground":"#123456"},"appStyle":{"states":{"visible":null}}}"##,
        ##"{"focusedStyle":{"hoverBackground":"#222222"},"style":{"states":{"focused":{"hoverBackground":"#111111"}}}}"##,
        ##"{"focusedStyle":{"states":{"hover":{"background":"#222222"}}},"style":{"states":{"focused":{"hoverBackground":"#111111"}}}}"##,
        ##"{"focusedStyle":{"hoverBackground":"#222222"},"style":{"states":{"focused":{"states":{"hover":{"background":"#111111"}}}}}}"##,
        ##"{"visibleAppStyle":{"hoverForeground":"#222222"},"appStyle":{"states":{"visible":{"hoverForeground":"#111111"}}}}"##,
        ##"{"focusedStyle":{"states":{"mode":{"hoverForeground":"#222222"}}},"style":{"states":{"focused":{"states":{"mode":{"hoverForeground":"#111111"}}}}}}"##,
        #"{"focusedStyle":null,"style":{"states":{"focused":null}}}"#
    ]
    for json in definitions {
        let own = try JSONDecoder().decode(ConfigurationValue.self, from: Data(json.utf8))
        let legacy = try own.decoded(WorkspaceConfiguration.self)
        let merged = try WorkspaceDefaults().merging(own)
        let layered = try #require(merged)
        for state: WorkspaceState? in [nil, .focused, .visible, .empty] {
            #expect(layered.cellStyle(state) == legacy.cellStyle(state))
        }
    }
}

@Test @MainActor func customizeShowsTheResolvedFontWhenRoleOrWidgetPropertiesAreNull() throws {
    let config = try presentationConfiguration(#"""
    {"defaults":{"fontSize":13,"fontWeight":"regular"},"roles":{"time":{"fontSize":16,"fontWeight":null}},
     "widgets":[{"id":"time","type":"clock","role":"time","position":"right","style":{"fontSize":null}},
                {"id":"date","type":"clock","role":"time","position":"right","style":null}]}
    """#)
    let store = BarStore(configurationURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
    store.configuration = config
    let editor = ConfigurationEditor(store: store)
    #expect(editor.selectedStyle["fontSize"] == .number(16))
    #expect(editor.selectedStyle["fontWeight"] == .string("regular"))
    editor.selectedID = "date"
    #expect(editor.selectedStyle["fontSize"] == .number(16))
}

@Test func widgetWorkspaceHoverOverridesDefaultsIndependentlyOfOtherAliases() throws {
    for aliases in ["", #","focusedStyle":{"fontSize":16},"focusedAppStyle":{"fontSize":16}"#] {
        let json = ##"""
        {"workspaceDefaults":{"style":{"states":{"hover":{"background":"#222222"}}},
          "appStyle":{"states":{"hover":{"foreground":"#444444"}}}},"widgets":[
          {"id":"spaces","type":"workspaces","position":"left","workspace":{
            "style":{"hoverBackground":"#111111"},"appStyle":{"hoverForeground":"#555555"}\##(aliases)}}]}
        """##
        let config = try presentationConfiguration(json)
        let workspace = try #require(config.widgets[0].workspace)
        #expect(workspace.cellStyle(nil).hovered.background == .color(HexColor(0x111111ff)))
        #expect(workspace.cellStyle(.focused).hovered.background == .color(HexColor(0x111111ff)))
        #expect(workspace.cellStyle(nil).hoveredApp.foreground == HexColor(0x555555ff))
        #expect(workspace.cellStyle(.focused).hoveredApp.foreground == HexColor(0x555555ff))
    }
}
