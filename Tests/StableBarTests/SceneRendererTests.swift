import AppKit
import Foundation
import Testing
@testable import StableBar

private let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let themes = repository.appending(path: "Resources/themes")

/// A new folder for one test. The caller removes it.
private func scratch() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "scene-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func scene(_ json: String) throws -> SceneFile {
    try JSONDecoder().decode(SceneFile.self, from: Data(json.utf8))
}

@MainActor private func store(_ json: String, in directory: URL) throws -> BarStore {
    try SceneRenderer.store(for: scene(json), at: directory.appending(path: "scene.json"), in: directory.appending(path: "work"),
                            themes: themes)
}

@Test @MainActor func sceneStoreShowsSampleOutputs() throws {
    let directory = try scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try store(#"""
    {
      "configuration": { "widgets": [
        { "id": "shell", "type": "script", "position": "left", "command": "echo live" },
        { "id": "cpu", "type": "system", "position": "right" },
        { "id": "silent", "type": "script", "position": "right", "command": "echo live" }
      ] },
      "outputs": { "shell": { "text": "Sample" }, "system": { "text": "18%" } },
      "history": { "cpu": [0.1, 0.2] },
      "draw": "bar"
    }
    """#, in: directory)
    defer { store.stop() }
    #expect(store.scripts["shell"]?.output.text == "Sample")
    #expect(store.scripts["cpu"]?.output.text == "18%")
    #expect(store.scripts["cpu"]?.samples == [0.1, 0.2])
    #expect(store.scripts["silent"]?.output.text == "")
}

@Test @MainActor func sceneStoreRunsNoCommand() async throws {
    let directory = try scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let widget = directory.appending(path: "widget-ran"), provider = directory.appending(path: "provider-ran")
    let store = try store(#"""
    {
      "configuration": {
        "providers": { "probe": { "type": "command", "command": "touch '\#(provider.path)'", "interval": 1 } },
        "widgets": [
          { "id": "shell", "type": "script", "position": "left", "command": "touch '\#(widget.path)'", "interval": 1 },
          { "id": "probe", "type": "provider", "provider": "probe", "position": "right" }
        ]
      },
      "draw": "bar"
    }
    """#, in: directory)
    defer { store.stop() }
    try await Task.sleep(for: .seconds(1.5))
    // A started script records its start before its command launches, which can wait seconds for the login shell.
    #expect(store.scripts.values.allSatisfy { $0.diagnostics.lastStarted == nil })
    #expect(!FileManager.default.fileExists(atPath: widget.path))
    #expect(!FileManager.default.fileExists(atPath: provider.path))
}

@Test @MainActor func sceneStoreReadsAeroSpaceWorkspaces() throws {
    let directory = try scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try store(#"""
    {
      "configuration": { "widgets": [{ "id": "spaces", "type": "workspaces", "position": "left" }] },
      "workspaces": [
        { "workspace": "1", "workspace-is-focused": false, "workspace-is-visible": false, "monitor-appkit-nsscreen-screens-id": 1 },
        { "workspace": "2", "workspace-is-focused": true, "workspace-is-visible": true, "monitor-appkit-nsscreen-screens-id": 1 },
        { "workspace": "3", "workspace-is-focused": false, "workspace-is-visible": false, "monitor-appkit-nsscreen-screens-id": 1 },
        { "workspace": "4", "workspace-is-focused": false, "workspace-is-visible": false, "monitor-appkit-nsscreen-screens-id": 1 }
      ],
      "windows": [
        { "workspace": "2", "app-name": "Xcode", "app-bundle-id": "com.apple.dt.Xcode", "window-id": 2, "window-title": "StableBar" },
        { "workspace": "2", "app-name": "Terminal", "app-bundle-id": "com.apple.Terminal", "window-id": 3, "window-title": "zsh" }
      ],
      "draw": "bar"
    }
    """#, in: directory)
    defer { store.stop() }
    let workspaces = store.workspaceStore.workspaces
    #expect(workspaces.count == 4)
    #expect(workspaces.first(where: \.isFocused)?.name == "2")
    #expect(workspaces.first { $0.name == "2" }?.apps.count == 2)
}

@Test @MainActor func sceneStoreMakesNoNetworkRequest() async throws {
    let directory = try scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try store(#"{"configuration": {"widgets": []}, "draw": "settings", "section": "theme"}"#, in: directory)
    defer { store.stop() }
    let index = await store.packageStoreClient.store.url
    #expect(index.isFileURL)
    #expect(index.path.hasPrefix(directory.path))
}

@Test @MainActor func sceneStoreLoadsAConfigurationFile() throws {
    let directory = try scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data(#"{"widgets": [{"id": "hello", "type": "text", "position": "left", "text": "Hello"}]}"#.utf8)
        .write(to: directory.appending(path: "config.json"))
    let store = try store(#"{"configuration": "config.json", "draw": "bar"}"#, in: directory)
    defer { store.stop() }
    #expect(store.configuration?.widgets.map(\.id) == ["hello"])
}

private let display = BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil)

/// Draws `json` in the dark appearance, with a short settle, and returns its image and the store that drew it.
@MainActor private func drawn(_ json: String, in directory: URL) async throws -> (image: NSBitmapImageRep, store: BarStore) {
    let scene = try scene(json)
    let store = try SceneRenderer.store(for: scene, at: directory.appending(path: "scene.json"), in: directory.appending(path: "work"),
                                        themes: themes)
    let url = directory.appending(path: "out.png")
    try await SceneRenderer.draw(scene, store: store, appearance: .dark, to: url, settle: .milliseconds(300))
    return (try #require(NSBitmapImageRep(data: Data(contentsOf: url))), store)
}

/// How many different colors a grid of samples across `image` finds: 1 for a flat image.
private func colors(_ image: NSBitmapImageRep) -> Int {
    var found = Set<String>()
    for x in stride(from: 0, to: image.pixelsWide, by: max(1, image.pixelsWide / 40)) {
        for y in stride(from: 0, to: image.pixelsHigh, by: max(1, image.pixelsHigh / 40)) {
            found.insert(image.colorAt(x: x, y: y).map { "\($0)" } ?? "none")
        }
    }
    return found.count
}

@Test @MainActor func barSceneDrawsAtTwiceItsSize() async throws {
    let directory = try scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (image, store) = try await drawn(#"""
    {"configuration": {"widgets": [{"id": "hello", "type": "text", "position": "left", "text": "Hello"}]}, "draw": "bar"}
    """#, in: directory)
    defer { store.stop() }
    let height = try #require(store.configuration).barGeometry(for: display).panelHeight
    #expect(image.pixelsWide == 2200)
    #expect(image.pixelsHigh == Int((2 * height).rounded()))
    #expect(colors(image) > 1)
}

@Test @MainActor func popupSceneDrawsTheClockCalendar() async throws {
    let directory = try scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (image, store) = try await drawn(#"""
    {"configuration": {"widgets": [{"id": "clock", "type": "clock", "position": "right", "details": true}]}, "draw": "popup", "widget": "clock"}
    """#, in: directory)
    defer { store.stop() }
    let widget = try #require(store.configuration?.widgets.first)
    let popup = try #require(widgetPopup(widget, store: store))
    #expect(image.pixelsWide == Int((2 * ((popup.style.width ?? 360) + 48)).rounded()))
    #expect(image.pixelsHigh == 1200)
    #expect(colors(image) > 10)
}

@Test @MainActor func editBarSceneFitsItsLayoutHeight() async throws {
    let directory = try scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (image, store) = try await drawn(#"""
    {"configuration": {"widgets": [
      {"id": "one", "type": "text", "position": "left", "text": "One"},
      {"id": "two", "type": "text", "position": "center", "text": "Two"},
      {"id": "three", "type": "text", "position": "right", "text": "Three"}
    ]}, "draw": "editBar"}
    """#, in: directory)
    defer { store.stop() }
    #expect(store.barEditing.isActive)
    let height = try #require(store.barEditing.geometry(for: display)).layoutHeight
    #expect(image.pixelsHigh == Int((2 * height).rounded()))
    #expect(height >= (try #require(store.configuration).barGeometry(for: display).panelHeight))
}

@Test @MainActor func settingsSceneDrawsTheThemeSection() async throws {
    let directory = try scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (image, store) = try await drawn(#"{"configuration": {"widgets": []}, "draw": "settings", "section": "theme"}"#, in: directory)
    defer { store.stop() }
    #expect(image.pixelsWide == 2160)
    #expect(image.pixelsHigh == 1520)
    #expect(colors(image) > 10)
}

@Test @MainActor func popupSceneWithoutAPopupFails() async throws {
    let directory = try scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let error = await #expect(throws: (any Error).self) {
        _ = try await drawn(#"""
        {"configuration": {"widgets": [{"id": "hello", "type": "text", "position": "left", "text": "Hello"}]}, "draw": "popup", "widget": "hello"}
        """#, in: directory)
    }
    #expect(errorMessage(try #require(error)).contains("hello"))
}

@Test func renderScenesCommandParses() throws {
    guard case let .renderScenes(output, scenes) = try LaunchCommand(arguments: ["--render-scenes", "/tmp/out", "a.json", "scenes"]) else {
        Issue.record("Expected renderScenes")
        return
    }
    #expect(output.path == "/tmp/out")
    #expect(scenes.map(\.lastPathComponent) == ["a.json", "scenes"])
    #expect(throws: CommandFailure.self) { try LaunchCommand(arguments: ["--render-scenes", "/tmp/out"]) }
    #expect(!LaunchCommand.usage.contains("--render-scenes"))
}

/// The scenes object of the report `renderAll` wrote to `output`.
private func report(in output: URL) throws -> [String: ConfigurationValue] {
    let document = try JSONDecoder().decode([String: ConfigurationValue].self, from: Data(contentsOf: output.appending(path: "scenes.json")))
    guard case let .object(scenes)? = document["scenes"] else { throw CommandFailure(message: "scenes.json has no scenes") }
    return scenes
}

private let darkBar = #"{"configuration": {"widgets": [{"id": "hello", "type": "text", "position": "left", "text": "Hello"}]}, "draw": "bar", "appearances": ["dark"]}"#

@Test @MainActor func renderAllReportsEachScene() async throws {
    let directory = try scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let scenes = directory.appending(path: "scenes"), output = directory.appending(path: "out")
    try FileManager.default.createDirectory(at: scenes, withIntermediateDirectories: true)
    try Data(darkBar.utf8).write(to: scenes.appending(path: "good.json"))
    try Data(#"{"configuration": {}, "draw": "bar", "colour": 1}"#.utf8).write(to: scenes.appending(path: "bad.json"))
    let summary = await SceneRenderer.renderAll([scenes], to: output, settle: .milliseconds(300))
    #expect(summary.failures == 1)
    let entries = try report(in: output)
    #expect(entries["good"] == .object(["images": .array([.string("good-dark.png")])]))
    guard case let .object(bad)? = entries["bad"], case let .string(message)? = bad["error"] else {
        Issue.record("Expected an error for bad.json")
        return
    }
    #expect(message.contains("colour"))
    #expect(FileManager.default.fileExists(atPath: output.appending(path: "good-dark.png").path))
}

@Test @MainActor func renderAllRejectsDuplicateNames() async throws {
    let directory = try scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let scenes = directory.appending(path: "scenes"), output = directory.appending(path: "out")
    for folder in ["a", "b"] {
        try FileManager.default.createDirectory(at: scenes.appending(path: folder), withIntermediateDirectories: true)
        try Data(darkBar.utf8).write(to: scenes.appending(path: "\(folder)/clock.json"))
    }
    let summary = await SceneRenderer.renderAll([scenes], to: output, settle: .milliseconds(300))
    #expect(summary.failures == 1)
    let errors = try report(in: output).values.compactMap { entry -> String? in
        if case let .object(fields) = entry, case let .string(message)? = fields["error"] { message } else { nil }
    }
    #expect(errors.count == 1)
    #expect(errors.first?.contains("clock") == true)
}
