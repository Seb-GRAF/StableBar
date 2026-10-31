import AppKit
import Foundation
import SwiftUI

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

    /// How long a scene's views settle before they're drawn.
    static var settle: Duration = .seconds(2)

    private static let display = BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil)

    /// Draws what `scene` asks for, from `store`, in one appearance, to the PNG file `url`.
    static func draw(_ scene: SceneFile, store: BarStore, appearance: SceneFile.Appearance, to url: URL,
                     settle: Duration = settle) async throws {
        guard let configuration = store.configuration else { throw CommandFailure(message: "The scene has no configuration.") }
        let dark = appearance == .dark
        let width = CGFloat(scene.width ?? 1100)
        switch scene.draw {
        case .bar:
            let height = CGFloat(scene.height ?? configuration.barGeometry(for: display).panelHeight)
            try await OffscreenSnapshot.write(bar(store).background { OffscreenSnapshot.backdrop(dark: dark) },
                                              size: NSSize(width: width, height: height), dark: dark, settle: settle, to: url)
        case .editBar:
            store.barEditing.begin()
            var height = CGFloat(scene.height ?? 0)
            if scene.height == nil { height = try await editBarHeight(store, width: width) }
            try await OffscreenSnapshot.write(bar(store).background { OffscreenSnapshot.backdrop(dark: dark) },
                                              size: NSSize(width: width, height: height), dark: dark, settle: settle, to: url)
        case .popup:
            let look = configuration.look(on: .monitor)
            let id = scene.widget ?? ""
            guard let widget = look.widgets.first(where: { $0.id == id }) else {
                throw CommandFailure(message: "widget: The configuration has no widget \(id).")
            }
            guard let popup = widgetPopup(widget, store: store) else { throw CommandFailure(message: "widget: \(id) has no popup.") }
            let popupWidth = CGFloat(popup.style.width ?? 360)
            let content = PopupView(popup: popup, style: popup.baseStyle(widget: widget, defaults: look.popupDefaults.inheriting(look.defaults)),
                                    store: store, widget: widget)
                .environment(\.screenKind, .monitor)
                .frame(width: popupWidth)
                .fixedSize(horizontal: false, vertical: true)
                .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background { OffscreenSnapshot.backdrop(dark: dark) }
            try await OffscreenSnapshot.write(content, size: NSSize(width: popupWidth + 48, height: CGFloat(scene.height ?? 600)),
                                              dark: dark, settle: settle, to: url)
        case .settings:
            store.showScreenSetup(ScreenSetup([display]))
            let editor = ConfigurationEditor(store: store)
            if let id = scene.widget {
                guard configuration.widgets.contains(where: { $0.id == id }) else {
                    throw CommandFailure(message: "widget: The configuration has no widget \(id).")
                }
                editor.showWidget(id)
                switch scene.tab ?? .content {
                case .content: editor.widgetTab = .content
                case .style: editor.widgetTab = .style
                case .behavior: editor.widgetTab = .behavior
                }
            } else {
                switch scene.section ?? .general {
                case .general: editor.section = .general
                case .bar: editor.section = .widgets
                case .theme: editor.section = .appearance
                case .profiles: editor.section = .profiles
                case .packages: editor.section = .packages
                }
            }
            let waitsForThemes = scene.widget == nil && scene.section == .theme
            try await OffscreenSnapshot.write(SettingsView(store: store, editor: editor).background(Color(nsColor: .windowBackgroundColor)),
                                              size: NSSize(width: CGFloat(scene.width ?? 1080), height: CGFloat(scene.height ?? 760)),
                                              dark: dark, settle: settle, ready: {
                !waitsForThemes || (!editor.gallery.choices.isEmpty && editor.gallery.choices.allSatisfy { editor.gallery.previews[$0.key] != nil })
            }, to: url)
        }
    }

    private static func bar(_ store: BarStore) -> some View {
        BarView(store: store, display: display)
            .environment(\.screenKind, .monitor)
            .frame(maxHeight: .infinity, alignment: .top)
    }

    /// The edit bar's height once its layout settles: edit mode measures its trays after the first
    /// layout, so the strip grows to fit them. Lays the bar out offscreen until the height stops
    /// changing and every widget has a frame, as BarEditViewTests does.
    private static func editBarHeight(_ store: BarStore, width: CGFloat) async throws -> CGFloat {
        guard var height = store.barEditing.geometry(for: display)?.layoutHeight else {
            throw CommandFailure(message: "draw: Edit mode needs a configuration.")
        }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: BarView(store: store, display: display).environment(\.screenKind, .monitor)
            .environment(\.fixedDate, DocsImages.date))
        host.sizingOptions = []
        window.contentView = host
        let expected = Set(store.barEditing.entries(on: display).map(\.id))
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            let measured = store.barEditing.geometry(for: display)?.layoutHeight ?? height
            if measured != height {
                height = measured
                window.setContentSize(CGSize(width: width, height: height))
            } else if expected.isSubset(of: dropTargets(in: host).flatMap(\.frames.keys)) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return height
    }

    private static func dropTargets(in view: NSView) -> [BarEditDropTargetView] {
        view.subviews.flatMap { subview in
            (subview as? BarEditDropTargetView).map { [$0] + dropTargets(in: $0) } ?? dropTargets(in: subview)
        }
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
