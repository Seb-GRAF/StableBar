import Foundation
import Testing
@testable import StableBar

private let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func scene(_ json: String) throws -> SceneFile {
    try JSONDecoder().decode(SceneFile.self, from: Data(json.utf8))
}

@Test func sceneDecodesEveryProperty() throws {
    let decoded = try scene(#"""
    {
      "$schema": "../scene.schema.json",
      "configuration": { "widgets": [] },
      "outputs": { "shell": { "text": "Sample" }, "plain": "Text" },
      "history": { "system": [0.1, 0.2] },
      "workspaces": [{ "workspace": "1" }],
      "windows": [],
      "desktopShortcuts": [1, 3],
      "activeApp": "com.apple.finder",
      "draw": "settings",
      "widget": "clock",
      "tab": "style",
      "macOSMajorVersion": 15,
      "appearances": ["light"],
      "width": 900,
      "height": 500
    }
    """#)
    #expect(decoded.configuration == .inline(["widgets": .array([])]))
    #expect(decoded.outputs["shell"] == .object(["text": .string("Sample")]))
    #expect(decoded.outputs["plain"] == .string("Text"))
    #expect(decoded.history["system"] == [0.1, 0.2])
    #expect(decoded.workspaces?.count == 1)
    #expect(decoded.windows?.isEmpty == true)
    #expect(decoded.desktopShortcuts == [1, 3])
    #expect(decoded.activeApp == "com.apple.finder")
    #expect(decoded.draw == .settings)
    #expect(decoded.widget == "clock")
    #expect(decoded.tab == .style)
    #expect(decoded.macOSMajorVersion == 15)
    #expect(decoded.appearances == [.light])
    #expect(decoded.width == 900)
    #expect(decoded.height == 500)
    #expect(try scene(#"{"configuration": "config.json", "draw": "bar"}"#).configuration == .file("config.json"))
}

@Test func sceneDefaultsToBothAppearances() throws {
    let decoded = try scene(#"{"configuration": {"widgets": []}, "draw": "bar"}"#)
    #expect(decoded.appearances == [.dark, .light])
    #expect(decoded.outputs.isEmpty)
    #expect(decoded.history.isEmpty)
    #expect(decoded.workspaces == nil)
    #expect(decoded.desktopShortcuts.isEmpty)
    #expect(decoded.widget == nil)
    #expect(decoded.menu == nil)
    #expect(decoded.macOSMajorVersion == 26)
}

@Test(arguments: [0, 13])
func sceneRejectsUnsupportedMacOSVersions(version: Int) throws {
    let error = #expect(throws: (any Error).self) {
        try scene(#"{"configuration": {}, "draw": "bar", "macOSMajorVersion": \#(version)}"#)
    }
    #expect(errorMessage(try #require(error)).contains("macOSMajorVersion"))
}

@Test func sceneDecodesASampleMenu() throws {
    let decoded = try scene(#"""
    {
      "configuration": { "widgets": [] },
      "draw": "popup",
      "widget": "menus",
      "menu": [
        { "title": "Fill", "key": "F", "virtualKey": 3, "glyph": 70, "modifiers": 28, "enabled": false, "checked": true, "submenu": true },
        { "title": "Copy" }
      ]
    }
    """#)
    #expect(decoded.menu == [
        SceneFile.MenuItem(title: "Fill", key: "F", virtualKey: 3, glyph: 70, modifiers: 28, enabled: false, checked: true, submenu: true),
        SceneFile.MenuItem(title: "Copy", key: nil, virtualKey: nil, glyph: nil, modifiers: 0, enabled: true, checked: false, submenu: false),
    ])
}

@Test func sceneRejectsUnknownProperties() throws {
    let error = #expect(throws: (any Error).self) { try scene(#"{"configuration": {}, "draw": "bar", "colour": 1}"#) }
    let message = errorMessage(try #require(error))
    #expect(message.contains("colour"))
    #expect(message.contains("Unknown property."))
}

@Test(arguments: [
    (#"{"configuration": {}, "draw": "popup"}"#, "widget"),
    (#"{"configuration": {}, "draw": "settings"}"#, "section"),
    (#"{"configuration": {}, "draw": "settings", "section": "theme", "tab": "style"}"#, "tab"),
    (#"{"configuration": {}, "draw": "settings", "section": "theme", "tab": "placement"}"#, "tab"),
    (#"{"configuration": {}, "draw": "settings", "widget": "clock", "tab": "placement"}"#, "tab"),
    (#"{"configuration": {}, "draw": "bar", "menu": [{"title": "Copy"}]}"#, "menu"),
    (#"{"configuration": {}, "draw": "settings", "section": "theme", "accessibilityDisplay": ["reduceTransparency"]}"#, "accessibilityDisplay"),
    (#"{"configuration": {}, "draw": "popup", "widget": "menus", "menu": [{"title": "Copy", "shortcut": "⌘C"}]}"#, "shortcut"),
    // As scene.schema.json says: a negative value would set every flag, fn and ⌃⌥⇧ without ⌘.
    (#"{"configuration": {}, "draw": "popup", "widget": "menus", "menu": [{"title": "Copy", "key": "C", "modifiers": -1}]}"#,
     "menu.0.modifiers"),
    (#"{"configuration": {}, "draw": "setup", "desktopShortcuts": [0]}"#, "desktopShortcuts"),
    (#"{"configuration": {}, "draw": "setup", "desktopShortcuts": [17]}"#, "desktopShortcuts"),
    (#"{"configuration": {}, "draw": "setup", "desktopShortcuts": [1, 1]}"#, "desktopShortcuts")
])
func sceneNamesWhatItDraws(json: String, key: String) throws {
    let error = #expect(throws: (any Error).self) { try scene(json) }
    #expect(errorMessage(try #require(error)).contains(key))
}

@Test func sceneCanOpenATabOfTheBarsSettings() throws {
    let decoded = try scene(#"{"configuration": {}, "draw": "settings", "section": "bar", "tab": "placement"}"#)
    #expect(decoded.section == .bar)
    #expect(decoded.tab == .placement)
}

@Test func sceneDrawsTheStarRequest() throws {
    #expect(try scene(#"{"configuration": {}, "draw": "update", "starRequest": "thanked"}"#).starRequest == .thanked)
    #expect(try scene(#"{"configuration": {}, "draw": "update"}"#).starRequest == nil)
    #expect(try scene(#"{"configuration": {}, "draw": "settings", "section": "help", "starRequest": "thanked"}"#).starRequest == .thanked)
    #expect(throws: (any Error).self) { try scene(#"{"configuration": {}, "draw": "bar", "starRequest": "thanked"}"#) }
    #expect(throws: (any Error).self) {
        try scene(#"{"configuration": {}, "draw": "settings", "section": "general", "starRequest": "thanked"}"#)
    }
    #expect(throws: (any Error).self) { try scene(#"{"configuration": {}, "draw": "update", "starRequest": "starred"}"#) }
}

@Test func sceneRejectsAnUnknownDraw() {
    #expect(throws: (any Error).self) { try scene(#"{"configuration": {}, "draw": "window"}"#) }
}

/// A setup scene names the step to draw and pins what setup reads from the Mac, so a drawing doesn't depend on it.
@Test func sceneDecodesASetupStep() throws {
    let decoded = try scene(#"""
    {
      "configuration": { "widgets": [] },
      "draw": "setup",
      "setup": { "step": "permissions", "placement": "belowMenuBar", "preset": "developer", "menuBarHides": true,
                 "accessibility": false, "automation": false, "calendars": false, "battery": false, "notch": false }
    }
    """#)
    #expect(decoded.draw == .setup)
    #expect(decoded.setup == SceneFile.Setup(step: .permissions, placement: .belowMenuBar, preset: .developer, menuBarHides: true,
                                             accessibility: false, automation: false, calendars: false, battery: false, notch: false))
    let plain = try scene(#"{"configuration": {"widgets": []}, "draw": "setup", "setup": {}}"#)
    #expect(plain.setup == SceneFile.Setup())
    #expect(SceneFile.Setup() == SceneFile.Setup(step: .placement, placement: nil, preset: nil, menuBarHides: false,
                                                 accessibility: true, automation: true, calendars: true, battery: true, notch: true))
    #expect(try scene(#"{"configuration": {"widgets": []}, "draw": "setup"}"#).setup == nil)
}

@Test(arguments: SceneFile.ApplicationMove.allCases)
func sceneDecodesApplicationMoveRows(state: SceneFile.ApplicationMove) throws {
    let setup = try scene(#"{"configuration":{},"draw":"setup","setup":{"inApplications":false},"applicationMove":"\#(state.rawValue)"}"#)
    #expect(setup.applicationMove == state)
    #expect(setup.setup?.inApplications == false)
    let settings = try scene(#"{"configuration":{},"draw":"settings","section":"general","applicationMove":"\#(state.rawValue)"}"#)
    #expect(settings.applicationMove == state)
    #expect(throws: (any Error).self) {
        try scene(#"{"configuration":{},"draw":"bar","applicationMove":"\#(state.rawValue)"}"#)
    }
    // Setup in Applications has no move row to draw.
    #expect(throws: (any Error).self) {
        try scene(#"{"configuration":{},"draw":"setup","applicationMove":"\#(state.rawValue)"}"#)
    }
    #expect(throws: (any Error).self) {
        try scene(#"{"configuration":{},"draw":"setup","setup":{"step":"touches"},"applicationMove":"\#(state.rawValue)"}"#)
    }
}

@Test(arguments: [
    #""draw": "setup", "setup": {"stage": "look"}"#,
    #""draw": "setup", "setup": {"step": "intro"}"#,
    #""draw": "setup", "setup": {"placement": "current"}"#,
    #""draw": "setup", "setup": {"preset": "gaming"}"#,
    #""draw": "bar", "setup": {"step": "look"}"#,
])
func sceneRejectsASetupItCannotDraw(json: String) {
    #expect(throws: (any Error).self) { try scene(#"{"configuration": {"widgets": []}, \#(json)}"#) }
}

@Test func sceneSchemaListsTheSamePropertiesAsTheDecoder() throws {
    let schema = try JSONDecoder().decode([String: ConfigurationValue].self,
                                          from: Data(contentsOf: repository.appending(path: "scene.schema.json")))
    guard case let .object(properties)? = schema["properties"] else { Issue.record("scene.schema.json has no properties"); return }
    #expect(Set(properties.keys) == Set(SceneFile.CodingKeys.allCases.map(\.stringValue) + ["$schema"]))
    /// The strings of the `enum` in `value`, or in its `items` for an array.
    func choices(_ value: ConfigurationValue?) -> Set<String> {
        guard case let .object(object)? = value else { return [] }
        if case let .array(values)? = object["enum"] {
            return Set(values.compactMap { if case let .string(text) = $0 { text } else { nil } })
        }
        return choices(object["items"])
    }
    #expect(choices(properties["draw"]) == Set(SceneFile.Draw.allCases.map(\.rawValue)))
    #expect(choices(properties["section"]) == Set(SceneFile.Section.allCases.map(\.rawValue)))
    #expect(choices(properties["tab"]) == Set(SceneFile.Tab.allCases.map(\.rawValue)))
    #expect(choices(properties["appearances"]) == Set(SceneFile.Appearance.allCases.map(\.rawValue)))
    #expect(choices(properties["accessibilityDisplay"]) == Set(SceneFile.AccessibilityDisplay.allCases.map(\.rawValue)))
    #expect(choices(properties["starRequest"]) == Set(SceneFile.StarRequestLine.allCases.map(\.rawValue)))
    #expect(choices(properties["applicationMove"]) == Set(SceneFile.ApplicationMove.allCases.map(\.rawValue)))
    guard case let .object(setup)? = properties["setup"], case let .object(setupProperties)? = setup["properties"] else {
        Issue.record("scene.schema.json describes no setup properties"); return
    }
    #expect(Set(setupProperties.keys) == Set(SceneFile.Setup.CodingKeys.allCases.map(\.stringValue)))
    #expect(choices(setupProperties["step"]) == Set(SetupSession.Step.allCases.map { "\($0)" }))
    #expect(choices(setupProperties["placement"]) == ["top", "belowMenuBar"])
    #expect(choices(setupProperties["preset"]) == Set(SetupPreferences.Preset.allCases.map { "\($0)" }))
    #expect(choices(setupProperties["workspaceCheck"]) == Set(SceneFile.Setup.WorkspaceCheck.allCases.map(\.rawValue)))
}

@Test(arguments: SceneFile.Setup.WorkspaceCheck.allCases)
func sceneStubsWorkspaceChecks(result: SceneFile.Setup.WorkspaceCheck) throws {
    let decoded = try scene(#"{"configuration": {}, "draw": "setup", "setup": {"workspaceCheck": "\#(result.rawValue)"}}"#)
    #expect(decoded.setup?.workspaceCheck == result)
    #expect(throws: (any Error).self) {
        try scene(#"{"configuration": {}, "draw": "setup", "setup": {"workspaceCheck": "failed"}}"#)
    }
}

@Test @MainActor func everySceneInTheRepositoryLoads() throws {
    let folder = repository.appending(path: "scenes")
    let files = (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)?
        .compactMap { $0 as? URL }.filter { $0.pathExtension == "json" } ?? []).sorted { $0.path < $1.path }
    #expect(files.count >= 4)
    let work = FileManager.default.temporaryDirectory.appending(path: "scenes-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: work) }
    for file in files {
        #expect(throws: Never.self, "\(file.lastPathComponent)") {
            let store = try SceneRenderer.store(for: SceneFile.read(file), at: file, in: work.appending(path: file.lastPathComponent),
                                                themes: repository.appending(path: "Resources/themes"))
            store.stop()
        }
    }
}

@Test(arguments: [#""width": 0"#, #""height": 0"#, #""width": 1e30"#, #""height": 99999"#])
func sceneRejectsImpossibleSizes(size: String) throws {
    let error = #expect(throws: (any Error).self) { try scene(#"{"configuration": {}, "draw": "bar", \#(size)}"#) }
    let message = errorMessage(try #require(error))
    #expect(message.contains("width") || message.contains("height"))
}

// As scene.schema.json says: at least one appearance, each once. An empty list would draw nothing and report success.
@Test(arguments: [#"[]"#, #"["dark", "dark"]"#])
func sceneRejectsEmptyOrRepeatedAppearances(appearances: String) throws {
    let error = #expect(throws: (any Error).self) { try scene(#"{"configuration": {}, "draw": "bar", "appearances": \#(appearances)}"#) }
    #expect(errorMessage(try #require(error)).contains("ppearance"))
    #expect(try scene(#"{"configuration": {}, "draw": "bar", "appearances": ["light"]}"#).appearances == [.light])
}

@Test @MainActor func sceneSettingsKeepsExistingApplicationLocationBehaviour() throws {
    for name in ["settings-general", "settings-general-spaces"] {
        let scene = try SceneFile.read(repository.appending(path: "scenes/\(name).json"))
        #expect(scene.applicationMove == nil)
        #expect(SceneRenderer.settingsApplicationMove(for: scene) == nil)
    }
    let moveScene = try SceneFile.read(repository.appending(path: "scenes/settings-general-move.json"))
    let move = try #require(SceneRenderer.settingsApplicationMove(for: moveScene))
    #expect(!move.isInApplications)
    #expect(move.canMoveFromSettings(setupIsOpen: false))
}
