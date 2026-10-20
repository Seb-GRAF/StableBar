import Foundation
import Testing
@testable import StableBar

@Test @MainActor func unchangedInheritedStyleChoicesKeepTheirSourceAndDoNotCreateEdits() throws {
    try withCustomizationEditor(#"{"includes":["settings.json"],"widgets":[]}"#, included: #"""
    {"defaults":{"fontName":"Helvetica","fontWeight":"regular"},
     "workspaceDefaults":{"indicator":"underline"}}
    """#) { editor, url in
        let store = editor.store
        let origins = store.origins
        let original = try Data(contentsOf: url)
        for (action, key, fallback) in [(ConfigurationEdit.Action.defaults, "fontName", "system"),
                                        (.defaults, "fontWeight", "medium"),
                                        (.workspaceDefaults, "indicator", "background")] {
            let fields = try customizationFields(editor, action: action)
            let selection = fields.stringBinding(key, default: fallback)
            selection.wrappedValue = selection.wrappedValue
            let origin = try #require(store.origins["\(action.rawValue).\(key)"])
            #expect(!store.setsInMainFile(origin))
        }
        #expect(store.sessionEdits.isEmpty)
        #expect(editor.undoSteps.isEmpty)
        #expect(store.origins == origins)
        try editor.history.flush()
        #expect(editor.error == nil)
        #expect(try Data(contentsOf: url) == original)
    }
}

@Test @MainActor func unchangedImplicitStyleChoicesDoNotCreateOverrides() throws {
    try withCustomizationEditor(#"{"widgets":[]}"#) { editor, _ in
        for (action, key, fallback) in [(ConfigurationEdit.Action.defaults, "fontName", "system"),
                                        (.defaults, "fontWeight", "medium"),
                                        (.workspaceDefaults, "indicator", "background")] {
            let fields = try customizationFields(editor, action: action)
            #expect(fields.values.isEmpty)
            fields.stringBinding(key, default: fallback).wrappedValue = fallback
            #expect(editor.store.origins["\(action.rawValue).\(key)"] == nil)
        }
        let border = StyleFields(store: editor.store, path: "bar.style", values: [:],
            set: { editor.change(ConfigurationEdit(action: .bar, properties: ["style": .object($0)])) },
            unset: { _ in })
        border.stringBinding("borderEdges", default: "bottom").wrappedValue = "bottom"
        #expect(editor.store.sessionEdits.isEmpty)
        #expect(editor.undoSteps.isEmpty)
        #expect(editor.store.origins["bar.style.borderEdges"] == nil)
    }
}

@Test @MainActor func styleChoicesRecordChangesAndUnchangedSelectionsPreserveRedo() throws {
    try withCustomizationEditor(#"{"defaults":{"fontWeight":"regular"},"widgets":[]}"#) { editor, _ in
        let initial = try customizationFields(editor, action: .defaults)
        initial.stringBinding("fontWeight", default: "medium").wrappedValue = "bold"
        #expect(editor.store.configuration?.defaults.fontWeight == "bold")
        #expect(editor.store.customizationEdits.count == 1)
        #expect(editor.history.canUndo)
        editor.undo()
        let restored = try customizationFields(editor, action: .defaults)
        restored.stringBinding("fontWeight", default: "medium").wrappedValue = "regular"
        #expect(editor.store.sessionEdits.isEmpty)
        #expect(editor.undoSteps.isEmpty)
        #expect(editor.redoSteps.count == 1)
        editor.redo()
        let edited = try customizationFields(editor, action: .defaults)
        edited.stringBinding("fontWeight", default: "medium").wrappedValue = "bold"
        #expect(editor.store.configuration?.defaults.fontWeight == "bold")
        #expect(editor.store.customizationEdits.isEmpty)
        #expect(editor.undoSteps.count == 1)
    }
}

@Test @MainActor func unchangedInheritedColorChoicesKeepTokenAndCustomSources() throws {
    try withCustomizationEditor(#"{"includes":["settings.json"],"widgets":[]}"#, included: ##"""
    {"tokens":{"accent":"#123456","bespoke":"#234567"},
     "defaults":{"foreground":"@token.accent","background":"@token.bespoke","borderColor":"#345678"}}
    """##) { editor, _ in
        let store = editor.store
        let origins = store.origins
        let defaults = try #require(store.effectiveDocument["defaults"]).decoded([String: ConfigurationValue].self)
        for key in ["foreground", "background", "borderColor"] {
            let origin = try #require(store.origins["defaults.\(key)"])
            let color = try #require(defaults[key]).decoded(HexColor.self)
            let picker = TokenPicker(token: origin.token, color: color) {
                editor.change(ConfigurationEdit(action: .defaults, properties: [key: $0]))
            }
            picker.selection.wrappedValue = picker.selection.wrappedValue
            #expect(!store.setsInMainFile(try #require(store.origins["defaults.\(key)"])))
        }
        #expect(store.sessionEdits.isEmpty)
        #expect(editor.undoSteps.isEmpty)
        #expect(store.origins == origins)
    }
}

@Test @MainActor func colorChoicesAllowDistinctEqualColorTokensAndSwitchingToCustom() throws {
    try withCustomizationEditor(##"""
    {"tokens":{"accent":"#123456","text":"#123456"},
     "defaults":{"foreground":"@token.accent"},"widgets":[]}
    """##) { editor, _ in
        let color = HexColor(0x123456ff)
        let picker = TokenPicker(token: "accent", color: color) {
            editor.change(ConfigurationEdit(action: .defaults, properties: ["foreground": $0]))
        }
        picker.selection.wrappedValue = "text"
        #expect(editor.error == nil)
        #expect(editor.store.origins["defaults.foreground"]?.token == "text")
        #expect(editor.store.configuration?.defaults.foreground == color)
        #expect(editor.store.customizationEdits.count == 1)
        let changed = TokenPicker(token: editor.store.origins["defaults.foreground"]?.token, color: color) {
            editor.change(ConfigurationEdit(action: .defaults, properties: ["foreground": $0]))
        }
        changed.selection.wrappedValue = ""
        #expect(editor.error == nil)
        #expect(editor.store.origins["defaults.foreground"]?.token == nil)
        #expect(editor.store.configuration?.defaults.foreground == color)
        #expect(editor.store.customizationEdits.last?.properties?["foreground"] == color.configurationValue)
        #expect(editor.history.canUndo)
    }
}

@Test @MainActor func maskedStyleControlsEditSavedValuesAndResetRevealsTheInheritedSource() throws {
    try withCustomizationEditor(#"""
    {"includes":["settings.json"],"defaults":{"fontSize":14},
     "profiles":[{"name":"work","configuration":{"defaults":{"fontSize":20}}}],"widgets":[]}
    """#, included: #"{"defaults":{"fontSize":12}}"#) { editor, _ in
        @MainActor func fields() throws -> StyleFields { try customizationFields(editor, action: .defaults) }
        #expect(try fields().numberBinding("fontSize", default: 10).wrappedValue == 14)
        var property = try editor.store.propertySources(path: "defaults", key: "fontSize", values: fields().values)
        #expect(property.isMasked)
        #expect(property.effectiveValue == .number(20))
        #expect(property.sources.map(\.value) == [.number(12), .number(14), .number(20)])
        let binding = try fields().numberBinding("fontSize", default: 10)
        binding.wrappedValue = 16
        #expect(try fields().numberBinding("fontSize", default: 10).wrappedValue == 16)
        #expect(editor.store.configuration?.defaults.fontSize == 20)
        property = try editor.store.propertySources(path: "defaults", key: "fontSize", values: fields().values)
        try editor.store.removePropertySource(#require(property.saved))
        property = try editor.store.propertySources(path: "defaults", key: "fontSize", values: fields().values)
        #expect(property.saved == nil)
        #expect(property.sources.map(\.value) == [.number(12), .number(20)])
        var profile = try #require(editor.store.profiles.first)
        profile.enabled = false
        editor.setProfile(profile)
        #expect(editor.store.configuration?.defaults.fontSize == 12)
    }
}

@Test @MainActor func aSavedNullCanBeRemovedWithoutDiscardingTheInheritedValue() throws {
    try withCustomizationEditor(#"""
    {"includes":["settings.json"],"defaults":{"fontSize":null},"widgets":[]}
    """#, included: #"{"defaults":{"fontSize":12}}"#) { editor, _ in
        let fields = try customizationFields(editor, action: .defaults)
        let property = editor.store.propertySources(path: "defaults", key: "fontSize", values: fields.values)
        #expect(property.saved?.value == .null)
        #expect(property.effectiveValue == nil)
        #expect(!property.isMasked)
        try editor.store.removePropertySource(#require(property.saved))
        #expect(editor.store.configuration?.defaults.fontSize == 12)
        #expect(editor.store.contributions["defaults.fontSize"]?.count == 1)
    }
}

@Test @MainActor func aWidgetEditEqualToItsProfileValueStillUpdatesTheSavedValue() throws {
    try withCustomizationEditor(#"""
    {"widgets":[{"id":"time","type":"clock","position":"right","style":{"fontSize":14}}],
     "profiles":[{"name":"work","configuration":{"widgetOverrides":{"time":{"style":{"fontSize":20}}}}}]}
    """#) { editor, _ in
        let property = editor.store.propertySources(path: "widgets.time.style", key: "fontSize", defaultsPath: "defaults",
                                                    widgetID: "time", values: editor.style(for: "time"))
        #expect(property.saved?.value == .number(14))
        editor.set(["style": .object(["fontSize": .number(20)])], for: "time")
        let changed = editor.store.propertySources(path: "widgets.time.style", key: "fontSize", defaultsPath: "defaults",
                                                   widgetID: "time", values: editor.style(for: "time"))
        #expect(changed.saved?.value == .number(20))
        #expect(!changed.isMasked)
    }
}

@Test @MainActor func removingTheControllingWidgetOverrideKeepsTheWidgetDefinition() throws {
    try withCustomizationEditor(#"""
    {"widgets":[{"id":"time","type":"clock","position":"right","style":{"fontSize":14}}],
     "widgetOverrides":{"time":{"style":{"fontSize":20}}}}
    """#) { editor, _ in
        let property = editor.store.propertySources(path: "widgets.time.style", key: "fontSize", defaultsPath: "defaults",
                                                    widgetID: "time", values: editor.style(for: "time"))
        #expect(property.saved?.value == .number(14))
        let controlling = try #require(property.sources.last)
        #expect(controlling.value == .number(20))
        try editor.store.removePropertySource(controlling)
        #expect(editor.store.configuration?.widgets[0].style.fontSize == 14)
        let root = try editor.store.editedMainDocument(replaying: editor.store.customizationEdits)
        #expect(root["widgetOverrides"] == nil)
    }
}

@Test @MainActor func workspaceEditsUseTheSavedDefinitionAndResetDottedWidgetIDs() throws {
    try withCustomizationEditor(#"""
    {"workspaceDefaults":{"style":{"fontSize":12}},
     "widgets":[{"id":"spaces.main","type":"workspaces","position":"left","enabled":false,
                 "workspace":{"indicator":"background","style":{"fontSize":14}}}],
     "widgetOverrides":{"spaces.main":{"workspace":{"indicator":"underline","style":{"fontSize":20}}}}}
    """#) { editor, _ in
        let store = editor.store
        let workspace = try #require(store.configuration).workspaceDefaults.mergedProperties(editor.properties(for: "spaces.main")["workspace"])
        let style = try #require(workspace["style"]).decoded([String: ConfigurationValue].self)
        let indicator = store.propertySources(path: "widgets.spaces.main.workspace", key: "indicator",
            defaultsPath: "workspaceDefaults", widgetID: "spaces.main", values: workspace)
        var font = store.propertySources(path: "widgets.spaces.main.workspace.style", key: "fontSize",
            defaultsPath: "workspaceDefaults.style", widgetID: "spaces.main", values: style)
        #expect(indicator.editingValue == .string("background"))
        #expect(font.editingValue == .number(14))
        #expect(font.saved?.path == ["widgets", "spaces.main", "workspace", "style", "fontSize"])
        editor.set(["workspace": .object(["indicator": .string("underline"), "style": .object(["fontSize": .number(20)])])],
                   for: "spaces.main")
        font = store.propertySources(path: "widgets.spaces.main.workspace.style", key: "fontSize",
            defaultsPath: "workspaceDefaults.style", widgetID: "spaces.main", values: style)
        let changedIndicator = store.propertySources(path: "widgets.spaces.main.workspace", key: "indicator",
            defaultsPath: "workspaceDefaults", widgetID: "spaces.main", values: workspace)
        #expect(font.saved?.value == .number(20))
        #expect(changedIndicator.saved?.value == .string("underline"))
        try store.removePropertySource(#require(font.saved))
        font = store.propertySources(path: "widgets.spaces.main.workspace.style", key: "fontSize",
            defaultsPath: "workspaceDefaults.style", widgetID: "spaces.main", values: style)
        #expect(font.saved == nil)
        try store.removePropertySource(#require(font.sources.last))
        #expect(store.configuration?.widgets[0].workspace?.style.fontSize == 12)
        let steps = editor.undoSteps.count
        editor.set(["workspace": .object(["style": .object(["fontSize": .number(12)])])], for: "spaces.main")
        #expect(editor.undoSteps.count == steps)
    }
}

@Test(arguments: [false, true]) @MainActor func hoverResetRemovesNullParentsAndBothOrdinaryKeys(widget: Bool) throws {
    let configuration = widget
        ? #"{"includes":["settings.json"],"widgets":[{"id":"time","type":"clock","position":"right","style":null}]}"#
        : #"{"includes":["settings.json"],"defaults":null,"widgets":[]}"#
    try withCustomizationEditor(configuration, included: ##"{"defaults":{"hoverBackground":"#123456"}}"##) { editor, _ in
        let path = widget ? "widgets.time.style" : "defaults"
        let widgetID = widget ? "time" : nil
        let defaultsPath = widget ? "defaults" : nil
        let values = widget ? editor.style(for: "time") : [:]
        let fields = StyleFields(store: editor.store, path: path, defaultsPath: defaultsPath, widgetID: widgetID, values: values,
            set: { properties in
                if widget { editor.set(["style": .object(properties)], for: "time") }
                else { editor.change(ConfigurationEdit(action: .defaults, properties: properties)) }
            },
            unset: { properties in
                if widget { editor.change(ConfigurationEdit(action: .unset, id: "time", properties: ["style": .object(properties)])) }
                else { editor.change(ConfigurationEdit(action: .unset, properties: ["defaults": .object(properties)])) }
            })
        var property = editor.store.propertySources(path: path, key: "hoverBackground", defaultsPath: defaultsPath,
                                                    widgetID: widgetID, values: values, hover: true)
        #expect(property.saved?.value == .null)
        fields.resetHoverBackground(try #require(property.saved))
        #expect(HoverBackgroundRow.drawn(in: editor.store.effectiveDocument, widget: widgetID)?.value == .string("#123456"))
        fields.set(["hoverBackground": .string("#234567"), "states": .object(["hover": .object(["background": .string("#345678")])])])
        property = editor.store.propertySources(path: path, key: "hoverBackground", defaultsPath: defaultsPath,
                                               widgetID: widgetID, values: values, hover: true)
        fields.resetHoverBackground(try #require(property.saved))
        #expect(HoverBackgroundRow.drawn(in: editor.store.effectiveDocument, widget: widgetID)?.value == .string("#123456"))
    }
}

@Test @MainActor func sourceDetailsUseCurrentOutputAndStatePrecedence() throws {
    try withCustomizationEditor(#"""
    {"defaults":{"fontSize":11},"widgets":[{"id":"time","type":"clock","position":"right","style":{"fontSize":14}}]}
    """#) { editor, _ in
        let script = ScriptWidget()
        script.output = ScriptOutput(text: "Time", style: WidgetStyle(fontSize: 18,
            states: ["warning": WidgetStyle(fontSize: 22), "hover": WidgetStyle(fontSize: 26)]), state: .string("warning"))
        editor.store.scripts["time"] = script
        editor.store.updatePresentations()
        let resting = editor.store.propertySources(path: "widgets.time.style", key: "fontSize", defaultsPath: "defaults",
                                                    widgetID: "time", values: editor.style(for: "time"))
        let hovered = editor.store.propertySources(path: "widgets.time.style", key: "fontSize", defaultsPath: "defaults",
                                                   widgetID: "time", values: editor.style(for: "time"), hover: true)
        #expect(resting.editingValue == .number(14))
        #expect(resting.effectiveValue == .number(22))
        #expect(hovered.effectiveValue == .number(26))
        #expect(resting.isMasked)
        #expect(resting.sources.contains { $0.title == "Widget output style" && $0.value == .number(18) })
    }
}

@Test @MainActor func sourceDetailsKeepMaskedReferencesAndShowTokenDefinitions() throws {
    try withCustomizationEditor(##"""
    {"includes":["settings.json"],"tokens":{"accent":"#123456"},"defaults":{"foreground":"@token.missing"},
     "profiles":[{"name":"work","configuration":{"defaults":{"foreground":"@token.accent"}}}],"widgets":[]}
    """##, included: ##"{"tokens":{"accent":"#abcdef"}}"##) { editor, _ in
        let fields = try customizationFields(editor, action: .defaults)
        let property = editor.store.propertySources(path: "defaults", key: "foreground", values: fields.values)
        #expect(property.saved?.value == .string("@token.missing"))
        #expect(property.editingValue == .string("@token.missing"))
        #expect(property.isMasked)
        #expect(property.tokenSources.map(\.value) == [.string("#abcdef"), .string("#123456")])
        #expect(property.sources.last?.origin?.token == "accent")
    }
}

@Test @MainActor func appearanceColorAndDisplayScaleKeepSavedValuesUnderAProfile() throws {
    try withCustomizationEditor(##"""
    {"includes":["settings.json"],"bar":{"appearance":"light","displayScale":{"builtIn":1.25}},
     "tokens":{"accent":"#123456"},
     "profiles":[{"name":"work","configuration":{"bar":{"appearance":"dark","displayScale":{"builtIn":1.75}},
                                                   "tokens":{"accent":"#abcdef"}}}],"widgets":[]}
    """##, included: ##"{"tokens":{"accent":"#234567"}}"##) { editor, _ in
        let store = editor.store
        let bar = try #require(store.effectiveDocument["bar"]).decoded([String: ConfigurationValue].self)
        let appearance = store.propertySources(path: "bar", key: "appearance", values: bar)
        let scales = try #require(bar["displayScale"]).decoded([String: ConfigurationValue].self)
        let scale = store.propertySources(path: "bar.displayScale", key: "builtIn", values: scales)
        let tokens = try #require(store.effectiveDocument["tokens"]).decoded([String: ConfigurationValue].self)
        let color = store.propertySources(path: "tokens", key: "accent", values: tokens)
        #expect(appearance.editingValue == .string("light"))
        #expect(appearance.effectiveValue == .string("dark"))
        #expect(scale.editingValue == .number(1.25))
        #expect(scale.effectiveValue == .number(1.75))
        #expect(color.editingValue == .string("#123456"))
        #expect(color.isMasked)
        try store.removePropertySource(#require(color.saved))
        var profile = try #require(store.profiles.first)
        profile.enabled = false
        editor.setProfile(profile)
        let inherited = try #require(store.effectiveDocument["tokens"]).decoded([String: ConfigurationValue].self)
        #expect(inherited["accent"] == .string("#234567"))
    }
}

@MainActor
private func customizationFields(_ editor: ConfigurationEditor, action: ConfigurationEdit.Action) throws -> StyleFields {
    let values = try editor.store.effectiveDocument[action.rawValue]?.decoded([String: ConfigurationValue].self) ?? [:]
    return StyleFields(store: editor.store, path: action.rawValue, values: values,
        set: { editor.change(ConfigurationEdit(action: action, properties: $0)) }, unset: { _ in })
}

@MainActor
private func withCustomizationEditor(_ configuration: String, included: String? = nil,
                                     _ body: (ConfigurationEditor, URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "config.json")
    try Data(configuration.utf8).write(to: url)
    if let included { try Data(included.utf8).write(to: directory.appending(path: "settings.json")) }
    let store = BarStore(configurationURL: url, themesDirectory: nil)
    defer { store.stop() }
    store.reloadConfiguration()
    #expect(store.configurationError == nil)
    try body(ConfigurationEditor(store: store), url)
}
