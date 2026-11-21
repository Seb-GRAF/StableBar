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
    /// same path on every run. A scene's packages are installed in `directory`, and since packages are read
    /// from beside the configuration, its inline configuration is then written there.
    static func store(for scene: SceneFile, at sceneURL: URL, in directory: URL, themes: URL?,
                      appearance: SceneFile.Appearance = .light) throws -> BarStore {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let folder = sceneURL.deletingLastPathComponent()
        let configurationURL: URL
        let data: Data?
        switch scene.configuration {
        case let .inline(document):
            let name = "\(sceneURL.deletingPathExtension().lastPathComponent).configuration.json"
            let encoded = try JSONEncoder().encode(document)
            if scene.packages.isEmpty {
                configurationURL = folder.appending(path: name)
            } else {
                // A package's settings are read from the configuration file.
                configurationURL = directory.appending(path: name)
                try encoded.write(to: configurationURL)
            }
            data = encoded
        case let .file(path):
            configurationURL = URL(filePath: path, relativeTo: folder).standardizedFileURL
            data = nil
        }
        let packages = WidgetPackageStore(directory: directory.appending(path: "packages"))
        for path in scene.packages {
            var record = scene.barLink == nil && scene.draw != .shareLink ? PackageInstallRecord.local : PackageInstallRecord(.store)
            record.origin = scene.packageOrigins[path]
            _ = try packages.install(URL(filePath: path, relativeTo: folder).standardizedFileURL, record: record)
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
                store.widgetScripts.scripts[widget.id] = script
            case .script:
                store.widgetScripts.scripts[widget.id] = try sample(scene, keys: [widget.id])
            default:
                break
            }
        }
        AudioMixer.shared = AudioMixer(sample: scene.mixer?.state ?? MixerState())
        // The Sound details read their providers by name, and a provider no widget shows, such as the microphone behind
        // them, takes its sample by name.
        store.widgetScripts.providers = providers
        for name in scene.outputs.keys where providers[name] == nil && !configuration.widgets.contains(where: { $0.id == name }) {
            store.widgetScripts.providers[name] = try sample(scene, keys: [name])
        }
        store.workspaceStore.source = configuration.workspaceSource
        store.workspaceStore.desktopShortcuts = DesktopShortcuts(read: {
            Dictionary(uniqueKeysWithValues: scene.desktopShortcuts.map { number in
                (String(117 + number), ["enabled": true, "value": ["parameters": [65535, number, 262144]]] as [String: Any])
            })
        })
        if let workspaces = scene.workspaces {
            store.workspaceStore.workspaces = try workspaceSnapshot(workspaces: JSONEncoder().encode(workspaces),
                                                                    windows: JSONEncoder().encode(scene.windows ?? []),
                                                                    focusedWindow: scene.focusedWindow)
        }
        if let spaces = scene.yabaiSpaces {
            let bundleIDs = try Dictionary(uniqueKeysWithValues: scene.yabaiApps.map { key, bundleID in
                guard let pid = Int32(exactly: key) else { throw CommandFailure(message: "yabaiApps: \(key) isn't a process ID.") }
                return (pid, bundleID)
            })
            store.workspaceStore.workspaces = try yabaiSnapshot(spaces: JSONEncoder().encode(spaces),
                                                                windows: JSONEncoder().encode(scene.yabaiWindows ?? []),
                                                                displays: Data(#"[{"id":1,"index":1}]"#.utf8), screenIDs: [1],
                                                                bundleIDs: bundleIDs)
        }
        store.workspaceStore.dockBadges.labels = scene.dockBadges
        store.workspaceStore.refreshDesktopShortcuts()
        store.appWatcher.activeApp = SampleApp(bundleIdentifier: scene.activeApp ?? "com.apple.finder")
        store.windowClearance.checkManagerGap = { configuration in
            let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
            return scene.windowsUnderBar.flatMap {
                var gap = managerGap($0, windows: [screen], displays: [WindowClearanceDisplay(frame: screen, visibleFrame: screen, configuration: configuration,
                                                                                              display: display, desktopTop: screen.maxY)],
                                     menuBarHides: true)
                let file = switch $0 {
                case .yabai: ".yabairc"
                case .omniwm: ".config/omniwm/settings.toml"
                default: ".config/aerospace/aerospace.toml"
                }
                gap?.configuration = FileManager.default.homeDirectoryForCurrentUser.appending(path: file)
                return gap
            }
        }
        // Crashes and Send feedback read these samples, never the crash reports of the Mac that draws.
        let crashes = directory.appending(path: "DiagnosticReports")
        try FileManager.default.createDirectory(at: crashes, withIntermediateDirectories: true)
        if scene.section == .crashes { try writeCrashSamples(to: crashes) }
        guard let crashDefaults = SceneDefaults(suiteName: "org.stablebar.scene") else {
            throw CommandFailure(message: "crashes: No defaults to draw with.")
        }
        let now = DocsImages.date
        store.crashReports = CrashReports(directories: [crashes], defaults: crashDefaults, now: { now })
        try DocsImages.offline(store, in: directory)
        store.barPresentation.preparePresentations()
        if let path = scene.themeLink {
            let source = URL(filePath: path, relativeTo: folder).standardizedFileURL
            let link = ThemeLink(manifest: try Data(contentsOf: source.appending(path: "package.json")),
                                 configuration: try Data(contentsOf: source.appending(path: "config.json")))
            _ = store.receive([link.link])
            if let message = store.pendingLinks.themeError { throw CommandFailure(message: "themeLink: \(message)") }
        }
        if let path = scene.barLink {
            // The Store lists the packages it installed, so the card reads them without downloading anything.
            let listed = try packages.list().map { manifest in
                ConfigurationValue.object(["id": .string(manifest.id), "name": .string(manifest.name), "version": .string(manifest.version),
                                           "kind": manifest.kind.map { .string($0.rawValue) } ?? .null,
                                           "archive": .string("\(manifest.id).tar.gz"), "sha256": .string("")])
            }
            try JSONEncoder().encode(ConfigurationValue.object(["packages": .array(listed)])).write(to: directory.appending(path: "index.json"))
            let link = try BarLink(payload: Data(contentsOf: URL(filePath: path, relativeTo: folder).standardizedFileURL))
            _ = store.receive([try link.url()])
            if let message = store.pendingLinks.barError { throw CommandFailure(message: "barLink: \(message)") }
            store.pendingLinks.bar!.unticked = Set(scene.untickedWidgets)
        }
        return store
    }

    struct Report {
        var failures = 0
    }

    /// What `--render-scenes` draws: a single scene file in this process, and several each in a process of its own,
    /// as many at a time as the Mac has cores, up to six.
    static func render(_ inputs: [URL], to output: URL) async -> Report {
        guard sceneFiles(in: inputs).count > 1, let executable = Bundle.main.executableURL else {
            return await renderAll(inputs, to: output)
        }
        return await renderEach(inputs, to: output, processes: min(ProcessInfo.processInfo.activeProcessorCount, 6),
                                draw: drawInProcess(executable))
    }

    /// Draws every scene file in `inputs`, a folder standing for its `*.json` files at any depth, to
    /// `<name>-<appearance>.png` in `output`, and writes `scenes.json` there: each scene's images, or
    /// the error that stopped it. A scene's name is its file name; a second scene with the same name,
    /// ignoring case, is an error. Times are drawn in UTC.
    static func renderAll(_ inputs: [URL], to output: URL) async -> Report {
        DocsImages.useUTC()
        let work = FileManager.default.temporaryDirectory.appending(path: "stablebar-scenes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        guard makeFolder(output) else { return Report(failures: 1) }
        let (scenes, duplicates) = named(sceneFiles(in: inputs))
        var report = Report(failures: duplicates.count)
        var entries = duplicates
        for (name, file) in scenes {
            do {
                let scene = try SceneFile.read(file)
                var images: [ConfigurationValue] = []
                for appearance in scene.appearances {
                    let store = try store(for: scene, at: file, in: work.appending(path: "\(name)-\(appearance.rawValue)"),
                                          themes: bundledThemesDirectory, appearance: appearance)
                    defer { store.stop() }
                    let image = "\(name)-\(appearance.rawValue).png"
                    try await draw(scene, store: store, appearance: appearance, to: output.appending(path: image))
                    images.append(.string(image))
                }
                entries[name] = .object(["images": .array(images)])
            } catch {
                report.failures += 1
                entries[name] = .object(["error": .string(errorMessage(error))])
            }
        }
        if !writeReport(entries, to: output) { report.failures += 1 }
        return report
    }

    /// Draws the scene files in `inputs` as `renderAll` does, each in a process of its own, `processes` at a time. What
    /// a process has drawn can change what it draws later, such as which version of the app's icon an image gets, so
    /// each scene's images depend on that scene alone. `draw` draws one scene file to a folder as `--render-scenes`
    /// does, and returns its exit status.
    static func renderEach(_ inputs: [URL], to output: URL, processes: Int,
                           draw: @escaping @Sendable (_ scene: URL, _ folder: URL) async -> Int32) async -> Report {
        let work = FileManager.default.temporaryDirectory.appending(path: "stablebar-scenes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        guard makeFolder(output) else { return Report(failures: 1) }
        let (scenes, duplicates) = named(sceneFiles(in: inputs))
        var report = Report(failures: duplicates.count)
        var entries = duplicates
        await withTaskGroup(of: (name: String, folder: URL, status: Int32).self) { group in
            var next = 0, running = 0
            while true {
                while running < max(processes, 1), next < scenes.count {
                    let (name, file) = scenes[next]
                    let folder = work.appending(path: "\(next)")
                    next += 1
                    running += 1
                    group.addTask { (name, folder, await draw(file, folder)) }
                }
                guard let drawn = await group.next() else { break }
                running -= 1
                let entry = collect(drawn.name, from: drawn.folder, status: drawn.status, to: output)
                if case let .object(fields) = entry, fields["error"] != nil { report.failures += 1 }
                entries[drawn.name] = entry
            }
        }
        if !writeReport(entries, to: output) { report.failures += 1 }
        return report
    }

    /// Runs `--render-scenes` for one scene file in another process of `executable`, and returns its exit status.
    nonisolated private static func drawInProcess(_ executable: URL) -> @Sendable (URL, URL) async -> Int32 {
        { scene, folder in
            await withCheckedContinuation { continuation in
                let process = Process()
                process.executableURL = executable
                process.arguments = ["--render-scenes", folder.path, scene.path]
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    FileHandle.standardError.write(Data("\(scene.lastPathComponent): \(errorMessage(error))\n".utf8))
                    continuation.resume(returning: -1)
                }
            }
        }
    }

    /// The entry the process that drew `name` wrote to `folder`, with its images moved to `output`, or why it has none.
    private static func collect(_ name: String, from folder: URL, status: Int32, to output: URL) -> ConfigurationValue {
        guard let data = try? Data(contentsOf: folder.appending(path: "scenes.json")),
              case let .object(scenes)? = try? JSONDecoder().decode([String: ConfigurationValue].self, from: data)["scenes"],
              let entry = scenes[name] else {
            return .object(["error": .string("Drawing \(name) stopped with status \(status) before it reported.")])
        }
        guard case let .object(fields) = entry, case let .array(images)? = fields["images"] else { return entry }
        for case let .string(image) in images {
            let target = output.appending(path: image)
            do {
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: folder.appending(path: image), to: target)
            } catch {
                return .object(["error": .string("\(image): \(errorMessage(error))")])
            }
        }
        return entry
    }

    /// `files` with their names, and an error entry for each file named like an earlier one, ignoring case: their images
    /// would be one file on a disk that ignores case, as macOS's does by default.
    private static func named(_ files: [URL]) -> (scenes: [(name: String, file: URL)], duplicates: [String: ConfigurationValue]) {
        var scenes: [(name: String, file: URL)] = []
        var duplicates: [String: ConfigurationValue] = [:]
        var names: [String: String] = [:]
        for file in files {
            let name = file.deletingPathExtension().lastPathComponent
            // Folded as APFS compares names, which lowercasing doesn't do for all of them: `Straße` and `STRASSE` are one.
            let key = name.folding(options: .caseInsensitive, locale: nil)
            if let other = names[key] {
                let message = other == name ? "Another scene is also named \(name)." : "Another scene is named \(other), which differs only in case."
                duplicates[file.path] = .object(["error": .string(message)])
            } else {
                names[key] = name
                scenes.append((name, file))
            }
        }
        return (scenes, duplicates)
    }

    private static func makeFolder(_ folder: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return true
        } catch {
            FileHandle.standardError.write(Data("\(errorMessage(error))\n".utf8))
            return false
        }
    }

    /// Writes `entries` to `scenes.json` in `output`, and returns whether it could.
    private static func writeReport(_ entries: [String: ConfigurationValue], to output: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(["scenes": ConfigurationValue.object(entries)]).write(to: output.appending(path: "scenes.json"))
            return true
        } catch {
            FileHandle.standardError.write(Data("scenes.json: \(errorMessage(error))\n".utf8))
            return false
        }
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

    private static let display = BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil)

    /// Draws what `scene` asks for, from `store`, in one appearance, to the PNG file `url`.
    static func draw(_ scene: SceneFile, store: BarStore, appearance: SceneFile.Appearance, to url: URL) async throws {
        guard let configuration = store.configuration else { throw CommandFailure(message: "The scene has no configuration.") }
        let dark = appearance == .dark
        let width = CGFloat(scene.width ?? 1100)
        let macOSVersion = MacOSVersion(major: scene.macOSMajorVersion)
        switch scene.draw {
        case .bar:
            let height = CGFloat(scene.height ?? configuration.barGeometry(for: display).panelHeight)
            let view = if let id = scene.widget {
                AnyView(try barWithPopup(of: id, store: store))
            } else {
                AnyView(bar(store))
            }
            try await OffscreenSnapshot.write(drawn(view.background { OffscreenSnapshot.backdrop(dark: dark) }, with: scene.accessibilityDisplay),
                                              size: NSSize(width: width, height: height), dark: dark, to: url)
        case .editBar:
            store.barEditing.begin()
            let height = CGFloat(scene.height ?? configuration.barGeometry(for: display).panelHeight)
            try await OffscreenSnapshot.write(drawn(bar(store).background { OffscreenSnapshot.backdrop(dark: dark) }, with: []),
                                              size: NSSize(width: width, height: height), dark: dark, to: url)
        case .popup:
            let look = configuration.look(on: .monitor)
            let id = scene.widget ?? ""
            guard let widget = look.widgets.first(where: { $0.id == id }) else {
                throw CommandFailure(message: "widget: The configuration has no widget \(id).")
            }
            guard let popup = scene.menu.map({ AppMenu.popup($0.map(menuEntry)) }) ?? widgetPopup(widget, store: store) else {
                throw CommandFailure(message: "widget: \(id) has no popup.")
            }
            let navigation = PopupNavigation()
            if let view = scene.view {
                guard popup.views[view] != nil else { throw CommandFailure(message: "view: \(id)'s popup has no view \(view).") }
                navigation.view = view
            }
            try await drawPopup(popup, of: widget, store: store, navigation: navigation, height: CGFloat(scene.height ?? 600), dark: dark,
                                accessibilityDisplay: scene.accessibilityDisplay, to: url)
        case .update:
            store.update = AppUpdate.sample(star: (scene.starRequest ?? .repository).state)
            let popup = AppUpdate.popup
            try await drawPopup(popup, of: AppUpdate.tile(.available), store: store, height: CGFloat(scene.height ?? (popup.height ?? 420) + 48),
                                dark: dark, accessibilityDisplay: [], to: url)
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
                case .look, .placement: break
                }
            } else if let group = scene.group {
                guard configuration.widgets.contains(where: { $0.group == group }) else {
                    throw CommandFailure(message: "group: No widget in the configuration is in group \(group).")
                }
                editor.showGroup(group)
            } else if let tab = scene.tab, tab.isBarTab {
                editor.section = .widgets
                editor.barItem = .bar
                editor.barTab = tab == .placement ? .placement : .look
            } else {
                switch scene.section ?? .general {
                case .general: editor.section = .general
                case .bar: editor.section = .widgets
                case .theme: editor.section = .appearance
                case .profiles: editor.section = .profiles
                case .packages:
                    editor.section = .packages
                    editor.selectedPackageID = scene.package
                case .help:
                    editor.section = .help
                    editor.expandedQuestion = HelpQuestion.all[0].id
                case .feedback:
                    editor.showFeedback()
                    editor.feedback = feedbackDraft
                case .crashes:
                    editor.showCrashes()
                }
            }
            let waitsForThemes = scene.widget == nil && scene.section == .theme
            let waitsForCrashes = scene.widget == nil && scene.section == .crashes
            let library = store.packageLibrary
            // A package widget's Content tab loads the package's settings, which a busy Mac can take seconds to do.
            let widgetPackage = scene.widget.flatMap { id in
                (scene.tab ?? .content) == .content && !store.builtInWidgetIDs.contains(id) ? store.widgetPackageIDs[id] : nil
            }
            let move = settingsApplicationMove(for: scene)
            store.barEditing.setupIsOpen = scene.applicationMove == .setupOpen
            let settings = SettingsView(store: store, editor: editor, applicationMove: move)
                .environment(\.macOSVersion, macOSVersion).background(Color(nsColor: .windowBackgroundColor))
                .environment(\.feedbackSample, feedbackSample)
                .environment(\.starRequestSample, (scene.starRequest ?? .repository).state)
                .environment(\.calendarsSample, calendarsSample)
            try await OffscreenSnapshot.write(drawn(settings, with: []),
                                              size: NSSize(width: CGFloat(scene.width ?? 1080), height: CGFloat(scene.height ?? 760)),
                                              dark: dark, ready: {
                (!waitsForThemes || (!editor.gallery.choices.isEmpty && editor.gallery.choices.allSatisfy { editor.gallery.previews[$0.key] != nil }))
                    && (store.pendingLinks.theme.map { editor.gallery.previews[$0.choice.linkedPreviewKey] != nil } ?? true)
                    && (store.pendingLinks.bar.map { $0.entries != nil } ?? true)
                    // Crashes marks what it shows as seen once it has read the reports.
                    && (!waitsForCrashes || (!store.crashReports.reports.isEmpty && store.crashReports.unseen.isEmpty))
                    && (scene.package == nil || library.draft?.inspection.manifest.id == scene.package)
                    && (widgetPackage.map { id in
                        library.error != nil || library.draft.map { $0.inspection.manifest.id == id && library.isActive($0) } == true
                    } ?? true)
            }, to: url)
        case .uninstall:
            try await OffscreenSnapshot.write(uninstallSheet(scene, store: store),
                                              size: NSSize(width: 520, height: CGFloat(scene.height ?? 460)), dark: dark, to: url)
        case .barLinkReview:
            let candidate = store.pendingLinks.bar!
            await candidate.loadStore()
            await candidate.use()
            guard !candidate.reviews.isEmpty else { throw CommandFailure(message: "barLink: No package the link needs asks for a review.") }
            try await OffscreenSnapshot.write(BarLinkReview(candidate: candidate, store: store).background(Color(nsColor: .windowBackgroundColor)),
                                              size: NSSize(width: 540, height: CGFloat(scene.height ?? 540)), dark: dark, to: url)
        case .accessibilityGuide:
            let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap(NSImage.init(contentsOf:)).flatMap { image in
                var rect = NSRect(x: 0, y: 0, width: 256, height: 256)
                image.size = rect.size
                return image.cgImage(forProposedRect: &rect, context: nil, hints: nil).map { NSImage(cgImage: $0, size: rect.size) }
            }
            try await OffscreenSnapshot.write(AccessibilityGuideView(icon: icon ?? NSApp.applicationIconImage) {}
                .padding(24).background(Color(nsColor: .windowBackgroundColor)),
                                              size: NSSize(width: CGFloat(scene.width ?? 408), height: CGFloat(scene.height ?? 181)), dark: dark, to: url)
        case .share, .shareLink:
            let share = BarShare(store: store, display: display, screen: CGSize(width: 1512, height: 982), menuBar: setupMenuBarHeight,
                                 wallpaper: nil)
            share.format.screen = scene.shareScreen
            share.format.preset = scene.sharePreset
            try await OffscreenSnapshot.write(BarShareView(share: share, showsLink: scene.draw == .shareLink, showsDetails: scene.draw == .shareLink),
                                              size: NSSize(width: CGFloat(scene.width ?? 680), height: CGFloat(scene.height ?? 460)),
                                              dark: dark, ready: { share.image != nil }, to: url)
        case .setup:
            try await drawSetup(scene.setup ?? SceneFile.Setup(), move: scene.applicationMove, store: store, macOSVersion: macOSVersion,
                                size: NSSize(width: CGFloat(scene.width ?? 1512), height: CGFloat(scene.height ?? 982)),
                                dark: dark, to: url)
        }
    }

    /// Existing scenes keep reading the app location as before; only move scenes override their controls.
    static func settingsApplicationMove(for scene: SceneFile) -> ApplicationMoveController? {
        scene.applicationMove.map { ApplicationMoveController.sample($0) }
    }

    /// The sample display's macOS menu bar height in setup scenes.
    private static let setupMenuBarHeight = 30.0

    /// Draws setup's tour at `setup`'s step, over a stand-in for the Mac that reads and changes nothing on it, with the
    /// bar above it. The scene's choices are made once the tour shows, as a person makes them, so the tour sees the menu
    /// bar hide or show.
    private static func drawSetup(_ setup: SceneFile.Setup, move: SceneFile.ApplicationMove?, store: BarStore,
                                  macOSVersion: MacOSVersion, size: NSSize, dark: Bool, to url: URL) async throws {
        guard let defaults = SceneDefaults(suiteName: "org.stablebar.scene") else {
            throw CommandFailure(message: "setup: No defaults to draw with.")
        }
        var hides = setup.menuBarHides
        var system = SetupSystem()
        system.macOSVersion = macOSVersion
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
        system.suggestedPackages = { _ in setup.suggested }
        let session = SetupSession(store: store, system: system,
                                   applicationMove: .sample(move, inApplications: setup.inApplications))
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
            await session.loadSuggestions()
            choices.made = true
        }
        try await OffscreenSnapshot.write(drawn(view, with: []), size: size, dark: dark, ready: {
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
            let settings = store.configuration?.onScreen(ScreenKind(display)).bar
            ZStack(alignment: .top) {
                if let settings, settings.position == .bottom {
                    bar(store).padding(.bottom, settings.offset)
                } else {
                    bar(store).padding(.top, settings?.top(menuBar: menuBar) ?? 0)
                }
                if !session.menuBarHides {
                    Rectangle().fill(.black.opacity(0.5)).frame(height: setupMenuBarHeight)
                }
            }
        }
    }

    /// The bar on the edge it sits on, with the popup of the widget `id` open under it, or above it at the bottom. A
    /// widget without a popup shows its hover controls in their tooltip instead.
    private static func barWithPopup(of id: String, store: BarStore) throws -> some View {
        let configuration = store.configuration!
        let look = configuration.look(on: .monitor)
        guard let widget = look.widgets.first(where: { $0.id == id }) else {
            throw CommandFailure(message: "widget: The configuration has no widget \(id).")
        }
        let defaults = look.popupDefaults.popupStyle(over: look.defaults)
        let open: AnyView
        let gap: Double
        if let popup = widgetPopup(widget, store: store) {
            open = AnyView(PopupView(popup: popup, style: popup.baseStyle(widget: widget, defaults: defaults), store: store, widget: widget)
                .frame(width: CGFloat(popup.style.width ?? 360))
                .fixedSize(horizontal: false, vertical: true))
            gap = popup.gap(below: look.bar)
        } else if widget.hoverLayout != nil
                    || widget.layout == nil && configuration.providerType(of: widget) == DataSourceType.audio.name
                    && store.widgetScripts.scripts[id]?.output.values?["volume"] != nil {
            let style = tooltipStyle(defaults: defaults, widget: widget.tooltipStyle,
                                     states: StyleStates(mode: store.barPresentation.modePresentation(on: .monitor)))
            let appearance = WidgetAppearance(style, defaults: WidgetStyle())
            let shadowInset = CGFloat(appearance.shadowRadius * 2 + 2)
            let states = store.barPresentation.presentations[id]?.style(on: .monitor).blockStates(open: false) ?? StyleStates()
            open = AnyView(TooltipWidth(maxWidth: TooltipWidth.widgetMaxWidth - shadowInset * 2) {
                    HoverControls(widget: widget, store: store, style: LayoutStyle(inherited: style, states: states, tracksHover: true),
                                  runAction: { _, _ in })
                        .font(appearance.font)
                        .foregroundStyle(appearance.foreground)
                        .padding(.horizontal, appearance.paddingHorizontal)
                        .padding(.vertical, appearance.paddingVertical)
                }
                .modifier(PopupBackground(style: style, glass: look.bar.glass, backgrounds: PopupBackgrounds()))
                .fixedSize())
            gap = look.bar.popupGap(inPopup: false)
        } else {
            throw CommandFailure(message: "widget: \(id) has no popup or hover controls.")
        }
        let geometry = configuration.barGeometry(for: display)
        let upward = look.bar.position == .bottom
        let edge = upward ? geometry.panelHeight - geometry.drawingBottom - gap : geometry.drawingBottom + gap
        return BarView(store: store, display: display)
            .environment(\.screenKind, .monitor)
            .frame(height: geometry.panelHeight)
            .overlayPreferenceValue(BarAnchorPreference.self) { anchors in
                GeometryReader { proxy in
                    if let anchor = anchors.widgets[id] {
                        open
                            .environment(\.screenKind, .monitor)
                            .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
                            .frame(width: 0, height: 0, alignment: upward ? .bottom : .top)
                            .offset(x: proxy[anchor.bounds].midX, y: edge)
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: upward ? .bottom : .top)
    }

    /// `widget`'s popup over the backdrop, with its shadow, as the bar opens it.
    private static func drawPopup(_ popup: PopupConfiguration, of widget: WidgetConfiguration, store: BarStore,
                                  navigation: PopupNavigation = PopupNavigation(), height: CGFloat, dark: Bool,
                                  accessibilityDisplay: [SceneFile.AccessibilityDisplay], to url: URL) async throws {
        guard let look = store.configuration?.look(on: .monitor) else { throw CommandFailure(message: "The scene has no configuration.") }
        let popupWidth = CGFloat(popup.style.width ?? 360)
        let content = PopupView(popup: popup, style: popup.baseStyle(widget: widget, defaults: look.popupDefaults.popupStyle(over: look.defaults)),
                                store: store, widget: widget, navigation: navigation)
            .environment(\.screenKind, .monitor)
            .frame(width: popupWidth)
            .fixedSize(horizontal: false, vertical: true)
            .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background { OffscreenSnapshot.backdrop(dark: dark) }
        try await OffscreenSnapshot.write(drawn(content, with: accessibilityDisplay), size: NSSize(width: popupWidth + 48, height: height),
                                          dark: dark, to: url)
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

    /// The Calendars control's sample Mac: an iCloud account, and a Google account whose main calendar takes its address.
    private static let calendarsSample = ["iCloud": ["Family", "Home", "Work"], "jane@example.com": ["Holidays", "jane@example.com"]]

    /// Crash reports as macOS writes them, for Crashes in Status: one of a release, one of a development build, and one
    /// of a launch that dyld stopped, which Crashes leaves out.
    private static func writeCrashSamples(to folder: URL) throws {
        func write(_ name: String, version: String, captured: String, exception: [String: Any], termination: [String: Any],
                   message: String?, frames: [[String: Any]]) throws {
            let header: [String: Any] = [
                "app_name": "StableBar", "name": "StableBar", "bug_type": "309", "incident_id": name, "app_version": version,
                "build_version": version.isEmpty ? "" : "470", "os_version": "macOS 26.1 (25B78)"
            ]
            var body: [String: Any] = [
                "captureTime": captured, "modelCode": "Mac16,8", "exception": exception, "termination": termination, "faultingThread": 0,
                "threads": [["triggered": true, "queue": "com.apple.main-thread", "frames": frames]],
                "usedImages": [["name": "StableBar"], ["name": "libswiftCore.dylib"], ["name": "dyld"]]
            ]
            if let message { body["asi"] = ["libswiftCore.dylib": [message]] }
            let data = try JSONSerialization.data(withJSONObject: header, options: .sortedKeys) + Data("\n".utf8)
                + JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
            try data.write(to: folder.appending(path: "StableBar-\(name).ips"))
        }
        try write("2026-10-22-081240", version: "0.11.0", captured: "2026-10-22 08:12:40.5125 +0000",
                  exception: ["type": "EXC_BREAKPOINT", "signal": "SIGTRAP"],
                  termination: ["namespace": "SIGNAL", "indicator": "Trace/BPT trap: 5", "code": 5],
                  message: "WidgetPopup.swift:50: Fatal error: Unexpectedly found nil while unwrapping an Optional value",
                  frames: [["imageIndex": 1, "imageOffset": 4096, "symbol": "_assertionFailure(_:_:file:line:flags:)", "symbolLocation": 276],
                           ["imageIndex": 0, "imageOffset": 6_192_548, "symbol": "WidgetPopup.toggle(_:widget:defaults:store:anchor:)",
                            "symbolLocation": 1308, "sourceFile": "WidgetPopup.swift", "sourceLine": 50]])
        try write("2026-10-21-174503", version: "", captured: "2026-10-21 17:45:03.0841 +0000",
                  exception: ["type": "EXC_BAD_ACCESS", "signal": "SIGSEGV", "subtype": "KERN_INVALID_ADDRESS at 0x0000000000000010"],
                  termination: ["namespace": "SIGNAL", "indicator": "Segmentation fault: 11", "code": 11], message: nil,
                  frames: [["imageIndex": 0, "imageOffset": 2_210_140, "symbol": "ConfigurationLoader.load(_:data:context:)",
                            "symbolLocation": 912, "sourceFile": "ConfigurationLoader.swift", "sourceLine": 214]])
        try write("2026-10-22-090211", version: "", captured: "2026-10-22 09:02:11.3307 +0000",
                  exception: ["type": "EXC_CRASH", "signal": "SIGABRT"],
                  termination: ["namespace": "DYLD", "indicator": "Library missing", "code": 1,
                                "details": ["(terminated at launch; ignore backtrace)"],
                                "reasons": ["Library not loaded: @rpath/Sparkle.framework/Versions/B/Sparkle"]],
                  message: nil, frames: [["imageIndex": 2, "imageOffset": 25_424, "symbol": "dyld4::prepare(dyld4::APIs&, mach_o::UnsafeHeader const*)",
                                          "symbolLocation": 4004],
                                         ["imageIndex": 2, "imageOffset": 6_356, "symbol": "start", "symbolLocation": 2840]])
    }

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
