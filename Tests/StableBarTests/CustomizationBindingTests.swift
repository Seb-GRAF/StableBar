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
