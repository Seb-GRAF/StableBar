import Foundation
import Testing
@testable import StableBar

@Test @MainActor func profileEditsPreserveImportsAndSupportPinningUndoAndSave() throws {
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
    var profiles = store.profiles
    profiles[1].when?.onBattery = true
    editor.change(ConfigurationEdit(action: .profiles, profiles: profiles))
    #expect(store.activeProfiles.isEmpty)
    #expect(store.configuration?.bar.height == 40)
    editor.undo()
    #expect(store.activeProfiles == ["light"])
    editor.redo()
    #expect(store.activeProfiles.isEmpty)
    editor.change(ConfigurationEdit(action: .profile, name: "light"))
    #expect(store.configuration?.bar.height == 32)
    editor.change(ConfigurationEdit(action: .profiles, profiles: store.profiles + [
        ConfigurationProfile(name: "work", when: nil, configuration: ["bar": .object(["height": .number(36)])])
    ]))
    #expect(store.profiles.map(\.name) == ["dark", "light", "work"])
    editor.change(ConfigurationEdit(action: .profile, name: "work"))
    #expect(store.configuration?.bar.height == 36)
    #expect(try Data(contentsOf: url) == original)
    editor.save()
    #expect(editor.error == nil)
    #expect(store.sessionEdits.isEmpty)
    #expect(try Data(contentsOf: module) == imported)
    store.reloadConfiguration()
    #expect(store.pinnedProfile == "work")
    #expect(store.profiles[1].when?.onBattery == true)
    editor.change(ConfigurationEdit(action: .profile))
    editor.discard()
    #expect(store.pinnedProfile == "work")
    #expect(store.configuration?.bar.height == 36)
    editor.change(ConfigurationEdit(action: .profiles, profiles: store.profiles + [store.profiles[0]]))
    #expect(editor.error != nil)
    #expect(store.profiles.count == 3)
    #expect(store.sessionEdits.isEmpty)
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
    editor.change(ConfigurationEdit(action: .profiles, profiles: [ConfigurationProfile(name: "work", when: nil, configuration: [:])]))
    #expect(store.effectiveDocument == original)
    #expect(store.profiles.map(\.name) == ["work"])
    editor.change(ConfigurationEdit(action: .profile, name: "work"))
    #expect(store.pinnedProfile == "work")
    editor.undo()
    #expect(store.pinnedProfile == nil)
    editor.discard()
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
    #expect(store.sessionEdits.count == 2)
    editor.undo()
    #expect(store.configuration?.widgets[0].position == .left)
    editor.redo()
    #expect(store.configuration?.widgets[0].position == .right)
    editor.change(ConfigurationEdit(action: .add, properties: ["id": .string("new"), "type": .string("text"),
        "position": .string("left"), "text": .string("New")]))
    editor.selectedID = "new"
    editor.undo()
    #expect(editor.selectedID == "a")
    editor.save()
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
    for flag in ["--inspect-package", "--install-package", "--add", "--set", "--enable-package"] {
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
    editor.save()
    #expect(editor.error == nil)
    #expect(store.sessionEdits.isEmpty)
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
    editor.discard()
    #expect(store.sessionEdits.isEmpty)
    for size in [13.0, 14, 15] { editor.set(["style": .object(["fontSize": .number(size)])]) }
    #expect(store.sessionEdits.count == 1)
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
