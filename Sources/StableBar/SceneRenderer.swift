import AppKit
import Foundation
import os
import SwiftUI

/// Draws scene files offscreen. A scene's store is built the way the tests build theirs: its
/// configuration is read and its widgets get the scene's sample outputs, so no command, provider,
/// window manager or network request runs, and nothing asks for a permission.
@MainActor
enum SceneRenderer {
    /// A store showing `scene` in `appearance`, which runs nothing. `directory` holds the local Store
    /// index. A configuration path is relative to `sceneURL`, and an inline configuration reads as if it
    /// were `<scene>.configuration.json` beside it, so its includes resolve there and Settings shows the
    /// same path on every run.
    static func store(for scene: SceneFile, at sceneURL: URL, in directory: URL, themes: URL?,
                      appearance: SceneFile.Appearance = .light) throws -> BarStore {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let folder = sceneURL.deletingLastPathComponent()
        let configurationURL: URL
        let data: Data?
        switch scene.configuration {
        case let .inline(document):
            configurationURL = folder.appending(path: "\(sceneURL.deletingPathExtension().lastPathComponent).configuration.json")
            data = try JSONEncoder().encode(document)
        case let .file(path):
            configurationURL = URL(filePath: path, relativeTo: folder).standardizedFileURL
            data = nil
        }
        let store = BarStore(configurationURL: configurationURL, themesDirectory: themes)
        var loader = ConfigurationLoader()
        loader.themesDirectory = themes
        let context = ConfigurationContext(appearance: appearance.rawValue)
        let configuration = try loader.load(configurationURL, data: data, context: context)
        store.showWithoutRunning(configuration, loader: loader, context: context, setup: ScreenSetup([display]))

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
        store.workspaceStore.source = configuration.workspaceSource
        store.workspaceStore.desktopShortcuts = DesktopShortcuts(read: {
            Dictionary(uniqueKeysWithValues: scene.desktopShortcuts.map { number in
                (String(117 + number), ["enabled": true, "value": ["parameters": [65535, number, 262144]]] as [String: Any])
            })
        })
        if let workspaces = scene.workspaces {
            store.workspaceStore.workspaces = try workspaceSnapshot(workspaces: JSONEncoder().encode(workspaces),
                                                                    windows: JSONEncoder().encode(scene.windows ?? []))
        }
        store.workspaceStore.refreshDesktopShortcuts()
        store.activeApp = SampleApp(bundleIdentifier: scene.activeApp ?? "com.apple.finder")
        try DocsImages.offline(store, in: directory)
        store.preparePresentations()
        return store
    }

    struct Report {
        var failures = 0
    }

    /// Draws every scene file in `inputs`, a folder standing for its `*.json` files at any depth, to
    /// `<name>-<appearance>.png` in `output`, and writes `scenes.json` there: each scene's images, or
    /// the error that stopped it. A scene's name is its file name; a second scene with the same name
    /// is an error. Times are drawn in UTC.
    static func renderAll(_ inputs: [URL], to output: URL, settle: Duration = settle) async -> Report {
        DocsImages.useUTC()
        var report = Report()
        var entries: [String: ConfigurationValue] = [:]
        let work = FileManager.default.temporaryDirectory.appending(path: "stablebar-scenes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("\(errorMessage(error))\n".utf8))
            return Report(failures: 1)
        }
        for file in sceneFiles(in: inputs) {
            let name = file.deletingPathExtension().lastPathComponent
            if entries[name] != nil {
                report.failures += 1
                entries[file.path] = .object(["error": .string("Another scene is also named \(name).")])
                continue
            }
            do {
                let scene = try SceneFile.read(file)
                var images: [ConfigurationValue] = []
                for appearance in scene.appearances {
                    let store = try store(for: scene, at: file, in: work.appending(path: "\(name)-\(appearance.rawValue)"),
                                          themes: bundledThemesDirectory, appearance: appearance)
                    defer { store.stop() }
                    let image = "\(name)-\(appearance.rawValue).png"
                    try await draw(scene, store: store, appearance: appearance, to: output.appending(path: image), settle: settle)
                    images.append(.string(image))
                }
                entries[name] = .object(["images": .array(images)])
            } catch {
                report.failures += 1
                entries[name] = .object(["error": .string(errorMessage(error))])
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(["scenes": ConfigurationValue.object(entries)]).write(to: output.appending(path: "scenes.json"))
        } catch {
            report.failures += 1
            FileHandle.standardError.write(Data("scenes.json: \(errorMessage(error))\n".utf8))
        }
        return report
    }

    /// The scene files `inputs` name, sorted: files as given, and the `*.json` files at any depth in folders.
    private static func sceneFiles(in inputs: [URL]) -> [URL] {
        inputs.flatMap { input -> [URL] in
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: input.path, isDirectory: &isFolder), isFolder.boolValue else { return [input] }
            let files = FileManager.default.enumerator(at: input, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "json" } ?? []
            return files.sorted { $0.path < $1.path }
        }
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
            try await OffscreenSnapshot.write(drawn(bar(store).background { OffscreenSnapshot.backdrop(dark: dark) }, with: scene.accessibilityDisplay),
                                              size: NSSize(width: width, height: height), dark: dark, settle: settle, to: url)
        case .editBar:
            store.barEditing.begin()
            var height = CGFloat(scene.height ?? 0)
            if scene.height == nil { height = try await editBarHeight(store, width: width) }
            try await OffscreenSnapshot.write(drawn(bar(store).background { OffscreenSnapshot.backdrop(dark: dark) }, with: []),
                                              size: NSSize(width: width, height: height), dark: dark, settle: settle, to: url)
        case .popup:
            let look = configuration.look(on: .monitor)
            let id = scene.widget ?? ""
            guard let widget = look.widgets.first(where: { $0.id == id }) else {
                throw CommandFailure(message: "widget: The configuration has no widget \(id).")
            }
            guard let popup = scene.menu.map({ AppMenu.popup($0.map(menuEntry)) }) ?? widgetPopup(widget, store: store) else {
                throw CommandFailure(message: "widget: \(id) has no popup.")
            }
            try await drawPopup(popup, of: widget, store: store, height: CGFloat(scene.height ?? 600), dark: dark,
                                accessibilityDisplay: scene.accessibilityDisplay, settle: settle, to: url)
        case .update:
            store.update = AppUpdate.sample(star: (scene.starRequest ?? .repository).state)
            let popup = AppUpdate.popup
            try await drawPopup(popup, of: AppUpdate.tile(.available), store: store, height: CGFloat(scene.height ?? (popup.height ?? 420) + 48),
                                dark: dark, accessibilityDisplay: [], settle: settle, to: url)
        case .settings:
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
                case .size, .look, .placement: break
                }
            } else if let tab = scene.tab, tab.isBarTab {
                editor.section = .widgets
                editor.barItem = .bar
                editor.barTab = switch tab {
                case .look: .look
                case .placement: .placement
                default: .size
                }
            } else {
                switch scene.section ?? .general {
                case .general: editor.section = .general
                case .bar: editor.section = .widgets
                case .theme: editor.section = .appearance
                case .profiles: editor.section = .profiles
                case .packages: editor.section = .packages
                case .feedback:
                    editor.showFeedback()
                    editor.feedback = feedbackDraft
                }
            }
            let waitsForThemes = scene.widget == nil && scene.section == .theme
            let settings = SettingsView(store: store, editor: editor).background(Color(nsColor: .windowBackgroundColor))
                .environment(\.feedbackSample, feedbackSample)
            try await OffscreenSnapshot.write(drawn(settings, with: []),
                                              size: NSSize(width: CGFloat(scene.width ?? 1080), height: CGFloat(scene.height ?? 760)),
                                              dark: dark, settle: settle, ready: {
                !waitsForThemes || (!editor.gallery.choices.isEmpty && editor.gallery.choices.allSatisfy { editor.gallery.previews[$0.key] != nil })
            }, to: url)
        case .uninstall:
            try await OffscreenSnapshot.write(uninstallSheet(scene, store: store),
                                              size: NSSize(width: 520, height: CGFloat(scene.height ?? 460)), dark: dark, settle: settle, to: url)
        case .accessibilityGuide:
            try await OffscreenSnapshot.write(AccessibilityGuideView {}.padding(24).background(Color(nsColor: .windowBackgroundColor)),
                                              size: NSSize(width: CGFloat(scene.width ?? 408), height: CGFloat(scene.height ?? 181)), dark: dark, settle: settle, to: url)
        case .setup:
            try await drawSetup(scene.setup ?? SceneFile.Setup(), store: store,
                                size: NSSize(width: CGFloat(scene.width ?? 1512), height: CGFloat(scene.height ?? 982)),
                                dark: dark, settle: settle, to: url)
        }
    }

    /// The height of `display`'s macOS menu bar in setup scenes: a display without a notch, on macOS 26 and later.
    private static let setupMenuBarHeight = 30.0

    /// Draws setup's tour at `setup`'s step, over a stand-in for the Mac that reads and changes nothing on it, with the
    /// bar above it. The scene's choices are made once the tour shows, as a person makes them, so the tour sees the menu
    /// bar hide or show.
    private static func drawSetup(_ setup: SceneFile.Setup, store: BarStore, size: NSSize, dark: Bool, settle: Duration,
                                  to url: URL) async throws {
        guard let defaults = SceneDefaults(suiteName: "org.stablebar.scene") else {
            throw CommandFailure(message: "setup: No defaults to draw with.")
        }
        var hides = setup.menuBarHides
        var system = SetupSystem()
        system.automationAccess = { _ in setup.automation ? .allowed : .denied }
        system.setMenuBarHidden = { hides = $0 }
        system.menuBarHides = { hides }
        system.isTrusted = { setup.accessibility }
        system.calendarAccess = { setup.calendars ? .fullAccess : .notDetermined }
        system.defaults = defaults
        system.workspaceSource = { $0 ?? .spaces }
        system.windowManagerRuns = { false }
        system.hasBattery = { setup.battery }
        system.hasNotchedDisplay = { setup.notch }
        system.isInApplications = { setup.inApplications }
        system.previewsOnTheBar = false
        system.checkWorkspaces = { source, _ in
            setup.workspaceCheck?.result ?? (source == .yabai ? .signalsMissing(configuration: "~/.yabairc") : .ipcOff)
        }
        system.yabaiSignalScript = YabaiSetupSignals.script()
        let session = SetupSession(store: store, system: system)
        defer { session.workspaceConnection.hide() }
        session.step = setup.step.rawValue
        store.appMenu.hidesAccessWarning = true
        store.barEditing.setupIsOpen = true
        let choices = SetupChoices()
        let view = ZStack(alignment: .top) {
            SetupTourView(session: session, display: display, menuBarHeight: { hides ? 0 : setupMenuBarHeight }, dock: 0,
                          intro: false, finish: {}, skip: {}, reveal: {}, lower: {}, showProfile: nil)
            SetupChrome(session: session, store: store)
        }
        .task {
            if let placement = setup.placement { await session.place(placement) }
            if let preset = setup.preset { session.toggle(preset) }
            choices.made = true
        }
        try await OffscreenSnapshot.write(drawn(view, with: []), size: size, dark: dark, settle: settle, ready: {
            choices.made && (setup.step != .touches || session.workspaceCheckSource == nil
                            || session.workspaceConnection.result != .checking)
        }, to: url)
    }

    /// Whether a setup scene's choices are made, which its drawing waits for.
    @MainActor private final class SetupChoices {
        var made = false
    }

    /// The bar above setup's tour where its configuration puts it, since setup's choices show in the tour, not on the
    /// bar, and the macOS menu bar over the top of the screen while it shows. The tour points at the bar from the same
    /// configuration and the same menu bar, so the two agree.
    private struct SetupChrome: View {
        let session: SetupSession
        let store: BarStore

        var body: some View {
            let menuBar = session.menuBarHides ? 0 : setupMenuBarHeight
            let top = store.configuration.map { $0.onScreen(ScreenKind(display)).bar.top(menuBar: menuBar) } ?? 0
            ZStack(alignment: .top) {
                bar(store).padding(.top, top)
                if !session.menuBarHides {
                    Rectangle().fill(.black.opacity(0.5)).frame(height: setupMenuBarHeight)
                }
            }
        }
    }

    /// `widget`'s popup over the backdrop, with its shadow, as the bar opens it.
    private static func drawPopup(_ popup: PopupConfiguration, of widget: WidgetConfiguration, store: BarStore, height: CGFloat,
                                  dark: Bool, accessibilityDisplay: [SceneFile.AccessibilityDisplay], settle: Duration, to url: URL) async throws {
        guard let look = store.configuration?.look(on: .monitor) else { throw CommandFailure(message: "The scene has no configuration.") }
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
        try await OffscreenSnapshot.write(drawn(content, with: accessibilityDisplay), size: NSSize(width: popupWidth + 48, height: height),
                                          dark: dark, settle: settle, to: url)
    }

    /// `view` with the Accessibility display settings `settings` names on and the others off, since an offscreen drawing
    /// would otherwise read them from the Mac that draws it.
    static func drawn(_ view: some View, with settings: [SceneFile.AccessibilityDisplay]) -> some View {
        view.environment(\._accessibilityReduceTransparency, settings.contains(.reduceTransparency))
            .environment(\._colorSchemeContrast, settings.contains(.increaseContrast) ? .increased : .standard)
    }

    /// A bug as someone writes it in Send feedback.
    private static let feedbackDraft = Feedback(
        kind: .bug, title: "The clock disappears after waking from sleep",
        answers: ["what-happens": "After the Mac wakes from sleep, the clock widget is gone from the bar until I reload the configuration.",
                  "steps": "1. Put the Mac to sleep with an external display connected\n2. Wake it",
                  "expected": "The clock shows the time again, as the other widgets do."])

    /// Send feedback's sample Mac: signed in to the GitHub CLI, with Claude Code installed.
    private static let feedbackSample = FeedbackSample(
        report: BugReport(version: "0.11.0 (Stable, build 470)", system: "26.1 (25B78), arm64", mac: "Mac16,8, Apple M4 Pro",
                          displays: ["Built-in Retina Display: built-in, 1512×982 points at 2x, notch, main"],
                          configuration: "~/.config/stablebar/config.json, valid, 7 widgets in 1 file", theme: "default (bundled)",
                          packages: [], workspaceTool: "macOS Spaces", crashes: [],
                          live: BugReport.Live(access: ["Accessibility allowed", "Calendars allowed"], workspaces: "",
                                               profiles: [], problems: [])),
        account: "octocat", agents: [.claude])

    /// A Mac where StableBar changed everything Uninstall puts back: the sheet's sample.
    private static let uninstallSample = UninstallSnapshot(
        menuBarHides: true, turnedOnMenuBarAutoHide: true, opensAtLogin: true,
        commands: [URL(filePath: "/usr/local/bin/stablebar")], hasKeychainItems: true,
        configuration: URL(filePath: NSHomeDirectory()).appending(path: ".config/stablebar", directoryHint: .isDirectory),
        app: URL(filePath: "/Applications/StableBar.app", directoryHint: .isDirectory), asksForPassword: true)

    /// The Uninstall sheet, confirming or listing the step that failed: the password prompt for the command, cancelled.
    private static func uninstallSheet(_ scene: SceneFile, store: BarStore) -> some View {
        let snapshot = uninstallSample
        let failed = scene.uninstall == .failed
        let outcomes = snapshot.stepsBeforeQuit(UninstallOptions(snapshot)).map { step in
            UninstallOutcome(step: step, error: step == .command(snapshot.commands[0]) ? "Cancelled." : nil)
        }
        return UninstallSheet(store: store, snapshot: snapshot, outcomes: failed ? outcomes : nil, finishing: failed)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(SettingsPalette.background)
    }

    /// An app menu's entry for a scene's sample menu item, which nothing presses.
    private static func menuEntry(_ item: SceneFile.MenuItem) -> AppMenuEntry {
        AppMenuEntry(title: item.title, element: AXUIElementCreateSystemWide(), isEnabled: item.enabled, isChecked: item.checked,
                     hasSubmenu: item.submenu, shortcut: MenuShortcut(character: item.key, virtualKey: item.virtualKey,
                                                                      glyph: item.glyph, modifiers: item.modifiers))
    }

    private static func bar(_ store: BarStore) -> some View {
        BarView(store: store, display: display)
            .environment(\.screenKind, .monitor)
            .frame(maxHeight: .infinity, alignment: .top)
    }

    /// The edit bar's height once its layout settles: edit mode measures its trays after the first
    /// layout, and a crowded tray reports its extra rows after the next, so the strip grows to fit them.
    /// Lays the bar out offscreen until every widget has a frame and the height holds for a few passes,
    /// as BarEditViewTests does.
    private static func editBarHeight(_ store: BarStore, width: CGFloat) async throws -> CGFloat {
        guard var height = store.barEditing.geometry(for: display)?.layoutHeight else {
            throw CommandFailure(message: "draw: Edit mode needs a configuration.")
        }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: drawn(BarView(store: store, display: display).environment(\.screenKind, .monitor)
            .environment(\.fixedDate, DocsImages.date), with: []))
        host.sizingOptions = []
        window.contentView = host
        let expected = Set(store.barEditing.entries(on: display).map(\.id))
        var settled = 0
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            let measured = store.barEditing.geometry(for: display)?.layoutHeight ?? height
            if measured != height {
                height = measured
                settled = 0
                window.setContentSize(CGSize(width: width, height: height))
            } else if expected.isSubset(of: dropTargets(in: host).flatMap(\.frames.keys)) {
                settled += 1
                if settled == 3 { break }
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

/// The preferences setup reads and writes while a scene draws it, kept in memory, so drawing leaves nothing on disk.
private final class SceneDefaults: UserDefaults, @unchecked Sendable {
    private let values = OSAllocatedUnfairLock<[String: Any]>(uncheckedState: [:])

    override func object(forKey defaultName: String) -> Any? { values.withLockUnchecked { $0[defaultName] } }
    override func set(_ value: Any?, forKey defaultName: String) { values.withLockUnchecked { $0[defaultName] = value } }
    override func removeObject(forKey defaultName: String) { values.withLockUnchecked { $0[defaultName] = nil } }
}
