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
      "activeApp": "com.apple.finder",
      "draw": "settings",
      "widget": "clock",
      "tab": "style",
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
    #expect(decoded.activeApp == "com.apple.finder")
    #expect(decoded.draw == .settings)
    #expect(decoded.widget == "clock")
    #expect(decoded.tab == .style)
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
    #expect(decoded.widget == nil)
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
    (#"{"configuration": {}, "draw": "settings", "section": "theme", "tab": "style"}"#, "tab")
])
func sceneNamesWhatItDraws(json: String, key: String) throws {
    let error = #expect(throws: (any Error).self) { try scene(json) }
    #expect(errorMessage(try #require(error)).contains(key))
}

@Test func sceneRejectsAnUnknownDraw() {
    #expect(throws: (any Error).self) { try scene(#"{"configuration": {}, "draw": "window"}"#) }
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
