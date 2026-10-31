import AppKit
import Foundation

/// Draws scene files offscreen. A scene's store is built the way the tests build theirs: its
/// configuration is read and its widgets get the scene's sample outputs, so no command, provider,
/// window manager or network request runs, and nothing asks for a permission.
@MainActor
enum SceneRenderer {
    /// A store showing `scene`, which runs nothing. `directory` holds the files the store needs: an
    /// inline configuration and the local Store index. A configuration path is relative to `sceneURL`.
    static func store(for scene: SceneFile, at sceneURL: URL, in directory: URL, themes: URL?) throws -> BarStore {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configurationURL: URL
        switch scene.configuration {
        case let .inline(document):
            configurationURL = directory.appending(path: "config.json")
            try JSONEncoder().encode(document).write(to: configurationURL)
        case let .file(path):
            configurationURL = URL(filePath: path, relativeTo: sceneURL.deletingLastPathComponent()).standardizedFileURL
        }
        let store = BarStore(configurationURL: configurationURL, themesDirectory: themes)
        var loader = ConfigurationLoader()
        loader.themesDirectory = themes
        let configuration = try loader.load(configurationURL)
        store.configuration = configuration
        store.effectiveDocument = loader.document
        store.origins = loader.origins
        store.widgetPackageNames = loader.widgetPackageNames
        store.activeProfiles = loader.activeProfiles

        var providers: [String: ScriptWidget] = [:]
        for widget in configuration.widgets where widget.enabled {
            switch widget.content {
            case let .provider(name):
                let script = try providers[name] ?? sample(scene, keys: [widget.id, name])
                providers[name] = script
                store.scripts[widget.id] = script
            case .script:
                store.scripts[widget.id] = try sample(scene, keys: [widget.id])
            default:
                break
            }
        }
        if let workspaces = scene.workspaces {
            store.workspaceStore.workspaces = try workspaceSnapshot(workspaces: JSONEncoder().encode(workspaces),
                                                                    windows: JSONEncoder().encode(scene.windows ?? []))
        }
        store.activeApp = NSRunningApplication.runningApplications(withBundleIdentifier: scene.activeApp ?? "com.apple.finder").first
        try DocsImages.offline(store, in: directory)
        store.preparePresentations()
        return store
    }

    /// A script that never runs, showing the scene's output and history for the first of `keys` that
    /// has them, or an empty output.
    private static func sample(_ scene: SceneFile, keys: [String]) throws -> ScriptWidget {
        let script = ScriptWidget()
        let output: ScriptOutput
        switch keys.lazy.compactMap({ scene.outputs[$0] }).first {
        case let .string(text)?: output = try ScriptOutput.read(Data(text.utf8))
        case let value?: output = try ScriptOutput.read(JSONEncoder().encode(value))
        case nil: output = ScriptOutput(text: "")
        }
        try script.accept(output)
        if let samples = keys.lazy.compactMap({ scene.history[$0] }).first { script.samples = samples }
        return script
    }
}
