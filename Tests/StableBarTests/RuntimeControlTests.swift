import Foundation
import Testing
@testable import StableBar

@Test @MainActor func profileEditsPreserveImportsAndSupportPinningUndoAndAutomaticSaving() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "config.json")
    let module = directory.appending(path: "profiles.json")
    let imported = Data(#"{"profile":"dark","profiles":[{"name":"dark","when":{"appearance":"dark"},"configuration":{"bar":{"height":48}}},{"name":"light","when":{"appearance":"light"},"configuration":{"bar":{"height":32}}}]}"#.utf8)
    try imported.write(to: module)
    let original = Data(#"{"includes":["profiles.json"],"widgets":[]}"#.utf8)
    try original.write(to: url)
    let store = BarStore(configurationURL: url)
    defer { store.stop() }
    store.reloadConfiguration()
    let editor = ConfigurationEditor(store: store)
    #expect(store.pinnedProfile == "dark")
    #expect(store.configuration?.bar.height == 48)
    editor.change(ConfigurationEdit(action: .profile))
    #expect(store.pinnedProfile == nil)
    #expect(store.activeProfiles == ["light"])
    #expect(store.configuration?.bar.height == 32)
    var profile = store.profiles[1]
    profile.when?.onBattery = true
    editor.setProfile(profile)
    #expect(store.activeProfiles.isEmpty)
    #expect(store.configuration?.bar.height == 40)
    editor.undo()
    #expect(store.activeProfiles == ["light"])
    editor.redo()
    #expect(store.activeProfiles.isEmpty)
    editor.change(ConfigurationEdit(action: .profile, name: "light"))
    #expect(store.configuration?.bar.height == 32)
    editor.setProfile(ConfigurationProfile(name: "work", when: nil, configuration: ["bar": .object(["height": .number(36)])]))
    #expect(store.profiles.map(\.name) == ["dark", "light", "work"])
    editor.change(ConfigurationEdit(action: .profile, name: "work"))
    #expect(store.configuration?.bar.height == 36)
    #expect(try Data(contentsOf: url) != original)
    try editor.history.flush()
    #expect(editor.error == nil)
    #expect(store.sessionEdits.isEmpty)
    #expect(try Data(contentsOf: module) == imported)
    let saved = try JSONDecoder().decode([String: ConfigurationValue].self, from: Data(contentsOf: url))
    let savedProfiles = try saved["profiles"]!.decoded([[String: ConfigurationValue]].self)
    #expect(savedProfiles.map { $0["name"] } == [.string("light"), .string("work")])
    #expect(savedProfiles[0] == ["name": .string("light"), "when": .object(["onBattery": .bool(true)])])
    store.reloadConfiguration()
    #expect(store.pinnedProfile == "work")
    #expect(store.profiles[1].when?.onBattery == true)
    editor.change(ConfigurationEdit(action: .profile))
    editor.undo()
    #expect(store.pinnedProfile == "work")
    #expect(store.configuration?.bar.height == 36)
    editor.change(ConfigurationEdit(action: .profiles, profiles: [["name": .string("dark")], ["name": .string("dark")]]))
    #expect(editor.error != nil)
    #expect(store.profiles.count == 3)
    #expect(store.sessionEdits.isEmpty)

    try Data(String(decoding: imported, as: UTF8.self).replacingOccurrences(of: "32", with: "34").utf8).write(to: module)
    store.reloadConfiguration()
    editor.change(ConfigurationEdit(action: .profile, name: "light"))
    #expect(store.configuration?.bar.height == 34)
    var light = store.profiles[1]
    light.when?.appearance = nil
    light.enabled = false
    editor.setProfile(light)
    #expect(editor.error == nil)
    #expect(store.activeProfiles.isEmpty)
    editor.undo()
    #expect(store.activeProfiles == ["light"])
    editor.redo()
    #expect(store.activeProfiles.isEmpty)
    try editor.history.flush()
    let edited = try JSONDecoder().decode([String: ConfigurationValue].self, from: Data(contentsOf: url))
    let lightOverride = try edited["profiles"]!.decoded([[String: ConfigurationValue]].self)[0]
    #expect(lightOverride == ["name": .string("light"), "enabled": .bool(false),
                              "when": .object(["appearance": .null, "onBattery": .bool(true)])])
    try Data(#"{"profiles":[]}"#.utf8).write(to: module)
    store.reloadConfiguration()
    #expect(store.profiles.map(\.name) == ["light", "work"])
    #expect(store.configurationError == nil)
}

@Test @MainActor func profilesUpdateEvenWhenEffectiveSettingsStayTheSame() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data(#"{"widgets":[]}"#.utf8).write(to: url)
    let store = BarStore(configurationURL: url)
    defer { store.stop() }
    store.reloadConfiguration()
    let editor = ConfigurationEditor(store: store)
    let original = store.effectiveDocument
    editor.setProfile(ConfigurationProfile(name: "work", when: nil, configuration: [:]))
    #expect(store.effectiveDocument == original)
    #expect(store.profiles.map(\.name) == ["work"])
    editor.change(ConfigurationEdit(action: .profile, name: "work"))
    #expect(store.pinnedProfile == "work")
    editor.undo()
    #expect(store.pinnedProfile == nil)
    editor.undo()
    #expect(store.profiles.isEmpty)
}

@Test @MainActor func batchesAreAtomicAndPersistenceKeepsImportedFiles() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.appending(path: "config.json")
    let module = directory.appending(path: "module.json")
    let moduleData = Data(#"{"widgets":[{"id":"a","type":"text","position":"left","text":"A"},{"id":"b","type":"clock","position":"right"}]}"#.utf8)
    try moduleData.write(to: module)
    let rootData = Data(#"{"includes":["module.json"]}"#.utf8)
    try rootData.write(to: root)
    let store = BarStore(configurationURL: root)
    defer { store.stop() }
    store.reloadConfiguration()
    #expect(throws: (any Error).self) {
        try store.applyEdits([ConfigurationEdit(action: .set, id: "a", properties: ["text": .string("Changed")]),
                              ConfigurationEdit(action: .set, id: "b", properties: ["position": .string("invalid")])], persist: true)
    }
    #expect(store.configuration?.widgets[0].content == .text("A"))
    #expect(store.sessionEdits.isEmpty)
    #expect(try Data(contentsOf: root) == rootData)
    try store.applyEdits([ConfigurationEdit(action: .set, id: "a", properties: ["text": .string("Live")])], persist: false)
    #expect(store.configuration?.widgets[0].content == .text("Live"))
    #expect(try Data(contentsOf: root) == rootData)
    try store.applyEdits([ConfigurationEdit(action: .add, properties: ["id": .string("c"), "type": .string("text"),
        "position": .string("left"), "text": .string("C")]), ConfigurationEdit(action: .remove, id: "b"),
        ConfigurationEdit(action: .reorder, ids: ["c", "a"])], persist: true)
    #expect(store.configuration?.widgets.map(\.id) == ["c", "a", "b"])
    #expect(store.configuration?.widgets[2].enabled == false)
    #expect(store.sessionEdits.isEmpty)
    #expect(try Data(contentsOf: module) == moduleData)
    let saved = try JSONDecoder().decode([String: ConfigurationValue].self, from: Data(contentsOf: root))
    #expect(saved["includes"] == .array([.string("module.json")]))
    var loader = ConfigurationLoader()
    #expect(try loader.load(root).widgets[1].content == .text("Live"))
    #expect(saved["widgets"] == .array([.object(["id": .string("c"), "type": .string("text"), "position": .string("left"), "text": .string("C")])]))
    try store.applyEdits([ConfigurationEdit(action: .remove, id: "c"),
                         ConfigurationEdit(action: .add, properties: ["id": .string("c"), "type": .string("clock"), "position": .string("right")])], persist: false)
    #expect(store.configuration?.widgets.first(where: { $0.id == "c" })?.content == .clock(format: "EEE d MMM  HH:mm"))
}

@Test @MainActor func editorUndoRedoAndSessionReloadKeepExternalEdits() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.appending(path: "config.json")
    let original = #"{"widgets":[{"id":"a","type":"text","position":"left","text":"A"}],"bar":{"height":40}}"#
    try Data(original.utf8).write(to: root)
    let store = BarStore(configurationURL: root)
    defer { store.stop() }
    store.reloadConfiguration()
    try store.applyEdits([ConfigurationEdit(action: .set, id: "a", properties: ["text": .string("Session")])], persist: false)
    try Data(original.replacingOccurrences(of: "40", with: "50").utf8).write(to: root)
    store.reloadConfiguration()
    #expect(store.configuration?.bar.height == 50)
    #expect(store.configuration?.widgets[0].content == .text("Session"))
    let editor = ConfigurationEditor(store: store)
    editor.set(["position": .string("right")])
    #expect(store.configuration?.widgets[0].position == .right)
    #expect(store.sessionEdits.count == 1)
    #expect(store.customizationEdits.count == 1)
    editor.undo()
    #expect(store.configuration?.widgets[0].position == .left)
    editor.redo()
    #expect(store.configuration?.widgets[0].position == .right)
    editor.change(ConfigurationEdit(action: .add, properties: ["id": .string("new"), "type": .string("text"),
        "position": .string("left"), "text": .string("New")]))
    editor.selectedID = "new"
    editor.undo()
    #expect(editor.selectedID == "a")
    editor.saveCommandLineChanges()
    #expect(store.configuration?.bar.height == 50)
    #expect(store.configuration?.widgets[0].position == .right)
    #expect(store.sessionEdits.isEmpty)
    try store.applyEdits([ConfigurationEdit(action: .set, id: "a", properties: ["text": .string("Temporary")])], persist: false)
    _ = try store.handle(RuntimeRequest(action: .reset))
    #expect(store.configuration?.widgets[0].content == .text("Session"))
}

@Test func controlCLIParsesAtomicBatchesAndRejectsMissingPackagePaths() throws {
    let command = try LaunchCommand(arguments: ["--config", "/tmp/custom.json", "--batch",
        #"[{"action":"set","id":"clock","properties":{"format":"HH:mm"}},{"action":"reorder","ids":["clock"]}]"#, "--persist"])
    guard case let .control(url, request) = command else { Issue.record("Expected control command"); return }
    #expect(url.path == "/tmp/custom.json")
    #expect(request.persist)
    #expect(request.edits?.count == 2)
    for flag in ["--inspect-package", "--install-package", "--add", "--set", "--enable-package", "--uninstall-package"] {
        #expect(throws: (any Error).self) { try LaunchCommand(arguments: [flag]) }
    }
}

@Test @MainActor func acceptedSessionEditsSurviveAutomaticProfileChanges() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "config.json")
    let original = Data(#"""
        {
          "widgets":[{"id":"base","type":"text","position":"left","text":"Base"}],
          "profiles":[{"name":"light","when":{"appearance":"light"},"configuration":{"widgets":[
            {"id":"a","type":"text","position":"left","text":"A"},
            {"id":"b","type":"text","position":"left","text":"B"},
            {"id":"c","type":"text","position":"left","text":"C"}
          ]}}]
        }
        """#.utf8)
    try original.write(to: url)
    let store = BarStore(configurationURL: url)
    defer { store.stop() }
    store.reloadConfiguration()
    try store.applyEdits([
        ConfigurationEdit(action: .set, id: "a", properties: ["text": .string("Session")]),
        ConfigurationEdit(action: .remove, id: "b"),
        ConfigurationEdit(action: .reorder, ids: ["c", "a"])
    ], persist: false)
    #expect(store.configuration?.widgets.map(\.id) == ["c", "a", "base"])
    store.context.appearance = "dark"
    store.reloadConfiguration()
    #expect(store.configurationError == nil)
    #expect(store.configuration?.widgets.map(\.id) == ["base"])
    #expect(throws: (any Error).self) {
        try store.applyEdits([ConfigurationEdit(action: .set, id: "a", properties: ["text": .string("Invalid")])], persist: false)
    }
    #expect(throws: (any Error).self) {
        try store.applyEdits([ConfigurationEdit(action: .reorder, ids: ["a"])], persist: false)
    }
    #expect(store.sessionEdits.count == 3)
    #expect(try Data(contentsOf: url) == original)
    store.context.appearance = "light"
    store.reloadConfiguration()
    #expect(store.configurationError == nil)
    #expect(store.configuration?.widgets.map(\.id) == ["c", "a", "base"])
    #expect(store.configuration?.widgets[1].content == .text("Session"))
    store.context.appearance = "dark"
    store.reloadConfiguration()
    let editor = ConfigurationEditor(store: store)
    editor.set(["text": .string("Edited base")])
    #expect(editor.error == nil)
    try editor.history.flush()
    #expect(editor.error == nil)
    #expect(store.sessionEdits.count == 3)
    store.context.appearance = "light"
    store.reloadConfiguration()
    #expect(store.configurationError == nil)
    #expect(store.configuration?.widgets.map(\.id) == ["c", "a", "base"])
    #expect(store.configuration?.widgets[1].content == .text("Session"))
    #expect(store.configuration?.widgets[2].content == .text("Edited base"))
}

@Test @MainActor func repeatedEditorFieldValuesDoNotCreateHistoryOrClearRedo() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.appending(path: "config.json")
    try Data(#"""
    {"defaults":{"fontSize":12,"paddingHorizontal":10,"cornerRadius":14},"widgets":[
      {"id":"title","type":"text","position":"left","text":"Ready","style":{"minWidth":80,"maxWidth":100}}
    ]}
    """#.utf8).write(to: root)
    let store = BarStore(configurationURL: root)
    defer { store.stop() }
    store.reloadConfiguration()
    let editor = ConfigurationEditor(store: store)
    for _ in 0..<2 {
        editor.set(["style": .object(["fontSize": .number(12)])])
        editor.set(["style": .object(["paddingHorizontal": .number(10)])])
        editor.set(["style": .object(["cornerRadius": .number(14)])])
    }
    #expect(store.sessionEdits.isEmpty)
    #expect(editor.undoSteps.isEmpty)
    editor.set(["text": .string("Changed")])
    editor.undo()
    editor.set(["text": .string("Ready")])
    #expect(editor.redoSteps.count == 1)
    editor.redo()
    #expect(store.configuration?.widgets[0].content == .text("Changed"))
    editor.set(["style": .object(["minWidth": .number(200)])])
    #expect(editor.error != nil)
    #expect(store.configuration?.widgets[0].style.minWidth == 80)
    editor.set(["style": .object(["minWidth": .number(80)])])
    #expect(editor.error == nil)
    editor.undo()
    #expect(store.sessionEdits.isEmpty)
    for size in [13.0, 14, 15] { editor.set(["style": .object(["fontSize": .number(size)])]) }
    #expect(store.customizationEdits.count == 1)
    #expect(store.sessionEdits.isEmpty)
    #expect(store.configuration?.widgets[0].style.fontSize == 15)
    editor.set(["text": .string("Other")])
    editor.undo()
    #expect(store.configuration?.widgets[0].content == .text("Ready"))
    editor.undo()
    #expect(store.configuration?.widgets[0].style.fontSize == nil)
    #expect(editor.undoSteps.isEmpty)
    editor.replaceProperties(["type": .string("text"), "position": .string("right"), "text": .string("Ready")])
    #expect(store.configuration?.widgets[0].position == .right)
    #expect(store.configuration?.widgets[0].style.minWidth == nil)
}

@Test func savedEditsKeepTheLayoutOfUntouchedValues() throws {
    let original = Data("""
    {
        "bar": { "height": 40, "offset": 0 },
        "widgets": [
            {"id": "a", "type": "text", "position": "left", "text": "A"},
            {
                "id": "b",
                "type": "clock",
                "position": "right"
            }
        ],
        "defaults": {}
    }

    """.utf8)
    var document = try JSONDecoder().decode([String: ConfigurationValue].self, from: original)
    #expect(try configurationData(document, editing: original) == original)
    document["bar"] = .object(["height": .number(44), "offset": .number(0)])
    document["widgets"] = .array([
        .object(["id": .string("b"), "type": .string("clock"), "position": .string("right"), "format": .string("HH:mm")]),
        .object(["id": .string("a"), "type": .string("text"), "position": .string("left"), "text": .string("A")]),
        .object(["id": .string("c"), "type": .string("text"), "position": .string("left"), "text": .string("C")])
    ])
    document["defaults"] = .object(["fontSize": .number(12)])
    document["profile"] = .string("dark")
    #expect(String(decoding: try configurationData(document, editing: original), as: UTF8.self) == """
    {
        "bar": { "height": 44, "offset": 0 },
        "widgets": [
            {
                "id": "b",
                "type": "clock",
                "position": "right",
                "format": "HH:mm"
            },
            {"id": "a", "type": "text", "position": "left", "text": "A"},
            {
                "id": "c",
                "position": "left",
                "text": "C",
                "type": "text"
            }
        ],
        "defaults": {
            "fontSize": 12
        },
        "profile": "dark"
    }

    """)
}

@Test @MainActor func resetRemovesOnlyTheMainFilesValueAndTokenEditsKeepWidgetsLinked() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.appending(path: "config.json")
    try Data(##"""
    {"tokens":{"text":"#111111"},
     "widgets":[{"id":"imported","type":"text","position":"left","text":"I","style":{"background":"#222222"}}]}
    """##.utf8).write(to: directory.appending(path: "module.json"))
    try Data(##"""
    {"includes":["module.json"],"tokens":{"text":"#333333"},"defaults":{"foreground":"@token.text","fontSize":13},
     "widgets":[{"id":"local","type":"text","position":"right","text":"L","style":{"foreground":"#444444","fontSize":14}}],
     "widgetOverrides":{"imported":{"style":{"background":"#555555"}}}}
    """##.utf8).write(to: root)
    let store = BarStore(configurationURL: root)
    defer { store.stop() }
    store.reloadConfiguration()
    #expect(store.origins["defaults.foreground"]?.token == "text")
    #expect(store.sourceText(store.origins["widgets.imported.style.background"]!) == "your configuration (widget override)")
    #expect(store.setsInMainFile(store.origins["widgets.imported.style.background"]!))
    try store.applyEdits([ConfigurationEdit(action: .tokens, properties: ["text": .object(["light": .string("#666666"), "dark": .string("#777777")])])],
                         persist: false)
    #expect(store.configuration?.defaults.foreground == HexColor(light: 0x666666ff, dark: 0x777777ff))
    try store.applyEdits([ConfigurationEdit(action: .unset, id: "local", properties: ["style": .object(["foreground": .null])]),
                          ConfigurationEdit(action: .unset, id: "imported", properties: ["style": .object(["background": .null])]),
                          ConfigurationEdit(action: .unset, properties: ["tokens": .object(["text": .null])])], persist: true)
    let widgets = try #require(store.configuration?.widgets)
    #expect(widgets.first(where: { $0.id == "local" })?.style.foreground == nil)
    #expect(widgets.first(where: { $0.id == "local" })?.style.fontSize == 14)
    #expect(widgets.first(where: { $0.id == "imported" })?.style.background == HexColor(0x222222ff))
    #expect(store.configuration?.defaults.foreground == HexColor(0x111111ff))
    #expect(store.sourceText(store.origins["widgets.imported.style.background"]!) == "module.json")
    let saved = try JSONDecoder().decode([String: ConfigurationValue].self, from: Data(contentsOf: root))
    #expect(saved["tokens"] == nil)
    #expect(saved["widgetOverrides"] == nil)
    #expect(saved["widgets"] == .array([.object(["id": .string("local"), "type": .string("text"), "position": .string("right"),
                                                 "text": .string("L"), "style": .object(["fontSize": .number(14)])])]))
    #expect(throws: CommandFailure.self) {
        try store.applyEdits([ConfigurationEdit(action: .unset, id: "missing", properties: ["style": .object(["fontSize": .null])])], persist: false)
    }
    var ids: [String] = []
    let tokenDefaults: [String: ConfigurationValue] = ["defaults": .string("@token.card"), "widgets": .array([])]
    #expect(try ConfigurationEdit(action: .unset, properties: ["defaults": .object(["foreground": .null])])
        .applying(to: tokenDefaults, widgetIDs: &ids) == tokenDefaults)
}

@Test @MainActor func editsAndTheEditorMergeStatesLikeOtherStyleProperties() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.appending(path: "config.json")
    try Data(##"""
    {"defaults":{"states":{"warning":{"foreground":"#111111"}}},
     "widgets":[{"id":"a","type":"text","position":"left","text":"A","style":{"states":{"hover":{"background":"#222222"}}}}]}
    """##.utf8).write(to: root)
    let store = BarStore(configurationURL: root)
    defer { store.stop() }
    store.reloadConfiguration()
    try store.applyEdits([
        ConfigurationEdit(action: .defaults, properties: ["states": .object(["warning": .object(["background": .string("#333333")])])]),
        ConfigurationEdit(action: .set, id: "a", properties: ["style": .object(["states": .object(["hover": .object(["foreground": .string("#444444")])])])])
    ], persist: true)
    #expect(store.configuration?.defaults.states?["warning"] == WidgetStyle(foreground: HexColor(0x111111ff), background: HexColor(0x333333ff)))
    #expect(store.configuration?.widgets[0].style.states?["hover"] == WidgetStyle(foreground: HexColor(0x444444ff), background: HexColor(0x222222ff)))
    let saved = try JSONDecoder().decode([String: ConfigurationValue].self, from: Data(contentsOf: root))
    #expect(saved["defaults"] == .object(["states": .object(["warning": .object(["foreground": .string("#111111"), "background": .string("#333333")])])]))
    let editor = ConfigurationEditor(store: store)
    editor.set(["style": .object(["foreground": .string("#555555")])])
    #expect(editor.error == nil)
    #expect(store.configuration?.widgets[0].style.foreground == HexColor(0x555555ff))
    #expect(store.configuration?.widgets[0].style.states?["hover"]?.background == HexColor(0x222222ff))
}

@Test @MainActor func customizesHoverBackgroundBeatsALowerHoverStateWhileAnActiveProfileStillWins() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.appending(path: "config.json")
    let includes = ["{}", ##"{"states":{"hover":{"background":"#123456","foreground":"#abcdef"}}}"##,
                    ##"{"hoverBackground":"#123456","hoverForeground":"#abcdef"}"##]
    let profiles: [(defaults: String?, hover: HexColor)] = [(nil, HexColor(0x445566ff)),
                                                            (##"{"hoverBackground":"#778899"}"##, HexColor(0x778899ff)),
                                                            (##"{"states":{"hover":{"background":"#99aabb"}}}"##, HexColor(0x99aabbff))]
    for include in includes {
        try Data(#"{"defaults":\#(include)}"#.utf8).write(to: directory.appending(path: "theme.json"))
        for profile in profiles {
            let active = profile.defaults.map { #","profiles":[{"name":"p","configuration":{"defaults":\#($0)}}]"# } ?? ""
            try Data(#"{"includes":["theme.json"],"widgets":[]\#(active)}"#.utf8).write(to: root)
            let store = BarStore(configurationURL: root)
            defer { store.stop() }
            store.reloadConfiguration()
            ConfigurationEditor(store: store).change(ConfigurationEdit(action: .defaults, properties: HoverBackgroundRow.properties(.string("#445566"))))
            let message = "include \(include), profile \(profile.defaults ?? "none")"
            #expect(store.configuration?.defaults.hoverBackground == profile.hover, "\(message)")
            #expect(store.configuration?.defaults.hoverForeground == (include == "{}" ? nil : HexColor(0xabcdefff)), "\(message)")
        }
    }
}

@Test @MainActor func customizesHoverBackgroundRowsShowTheDrawnHoverAndResetBringsTheLowerOneBack() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data(##"""
    {"defaults":{"states":{"hover":{"background":"#123456"}}},
     "templates":{"label":{"type":"text","position":"left","style":{"states":{"hover":{"background":"#222222"}}}}}}
    """##.utf8).write(to: directory.appending(path: "theme.json"))
    let root = directory.appending(path: "config.json")
    let original = Data(##"""
    {"includes":["theme.json"],
     "widgets":[{"id":"a","template":"label","text":"A"},{"id":"b","type":"text","position":"left","text":"B"}]}
    """##.utf8)
    try original.write(to: root)
    let store = BarStore(configurationURL: root)
    defer { store.stop() }
    store.reloadConfiguration()
    let editor = ConfigurationEditor(store: store)
    func row(_ id: String? = nil) -> (path: String, source: String, color: HexColor?)? {
        HoverBackgroundRow.drawn(in: store.effectiveDocument, widget: id).map {
            ($0.path, store.sourceText(store.origins[$0.path]!), try? $0.value.decoded(HexColor.self))
        }
    }
    func drawn(_ id: String) throws -> HexColor? {
        let configuration = try #require(store.configuration)
        return try resolveStyle([configuration.defaults, #require(configuration.widgets.first { $0.id == id }).style]).hoverBackground
    }
    #expect(row()! == ("defaults.states.hover.background", "theme.json", HexColor(0x123456ff)))
    #expect(row("a")! == ("widgets.a.style.states.hover.background", "theme.json (template label)", HexColor(0x222222ff)))
    #expect(row("b")! == ("defaults.states.hover.background", "theme.json", HexColor(0x123456ff)))
    #expect(try drawn("a") == HexColor(0x222222ff))
    editor.change(ConfigurationEdit(action: .defaults, properties: HoverBackgroundRow.properties(.string("#445566"))))
    editor.selectedID = "a"
    editor.set(["style": .object(HoverBackgroundRow.properties(.string("#556677")))])
    #expect(editor.error == nil)
    #expect(try drawn("a") == HexColor(0x556677ff))
    #expect(try drawn("b") == HexColor(0x445566ff))
    #expect(row()! == ("defaults.hoverBackground", "your configuration", HexColor(0x445566ff)))
    #expect(row("a")! == ("widgets.a.style.hoverBackground", "your configuration", HexColor(0x556677ff)))
    #expect(row("b")! == ("defaults.hoverBackground", "your configuration", HexColor(0x445566ff)))
    #expect(store.setsInMainFile(store.origins["widgets.a.style.hoverBackground"]!))
    editor.change(ConfigurationEdit(action: .defaults, properties: HoverBackgroundRow.properties(.string("#667788"))))
    #expect(try drawn("b") == HexColor(0x667788ff))
    editor.change(ConfigurationEdit(action: .unset, properties: ["defaults": .object(HoverBackgroundRow.reset)]))
    editor.change(ConfigurationEdit(action: .unset, id: "a", properties: ["style": .object(HoverBackgroundRow.reset)]))
    #expect(editor.error == nil)
    #expect(try drawn("a") == HexColor(0x222222ff))
    #expect(try drawn("b") == HexColor(0x123456ff))
    #expect(row("a")! == ("widgets.a.style.states.hover.background", "theme.json (template label)", HexColor(0x222222ff)))
    try editor.history.flush()
    #expect(try JSONDecoder().decode(ConfigurationValue.self, from: Data(contentsOf: root))
        == JSONDecoder().decode(ConfigurationValue.self, from: original))
}
