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
