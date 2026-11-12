import AppKit
import Foundation
import os
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

@Test @MainActor func sceneStoreReadsOnlyItsDesktopShortcuts() throws {
    let directory = try scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try store(#"""
    {
      "configuration": { "workspaceSource": "spaces", "widgets": [{"id": "spaces", "type": "workspaces", "position": "left"}] },
      "workspaces": [
        { "workspace": "1", "workspace-is-focused": true, "workspace-is-visible": true, "monitor-appkit-nsscreen-screens-id": 1 },
        { "workspace": "2", "workspace-is-focused": false, "workspace-is-visible": false, "monitor-appkit-nsscreen-screens-id": 1 }
      ],
      "desktopShortcuts": [1], "draw": "setup", "setup": { "step": "permissions" }
    }
    """#, in: directory)
    defer { store.stop() }
    #expect(store.workspaceStore.source == .spaces)
    #expect(store.workspaceStore.desktopShortcutStatus.desktops == [1, 2])
    #expect(store.workspaceStore.desktopShortcutStatus.disabled == [2])
    #expect(!store.workspaceStore.isRunning)
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

@Test @MainActor func popupSceneDrawsASampleAppMenu() async throws {
    let directory = try scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (image, store) = try await drawn(#"""
    {"configuration": {"widgets": [{"id": "menus", "type": "appMenu", "position": "left"}]}, "draw": "popup", "widget": "menus",
     "menu": [{"title": "New Window", "key": "N"}, {"title": ""}, {"title": "Fill", "key": "F", "modifiers": 28}]}
    """#, in: directory)
    defer { store.stop() }
    #expect(image.pixelsWide == Int((2 * (260 + 48.0)).rounded()))
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

@Test @MainActor func settingsSceneDrawsCrashesWithoutTheLaunchDyldStopped() async throws {
    let directory = try scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (image, store) = try await drawn(#"{"configuration": {"widgets": []}, "draw": "settings", "section": "crashes"}"#, in: directory)
    defer { store.stop() }
    #expect(colors(image) > 10)
    #expect(store.crashReports.reports.map(\.versionName) == ["0.11.0", "development build"])
}

@Test @MainActor func settingsSceneDrawsTheSettingsOfAPackageItInstalls() async throws {
    let directory = try scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (_, store) = try await drawn(#"""
    {"configuration": {"packages": [{"id": "system-monitor", "version": "1.1.0"}]},
     "packages": ["\#(repository.appending(path: "examples/packages/system-monitor").path)"],
     "draw": "settings", "section": "packages", "package": "system-monitor"}
    """#, in: directory)
    defer { store.stop() }
    let draft = try #require(store.packageLibrary.draft)
    #expect(store.packageLibrary.isActive(draft))
    #expect(draft.inspection.manifest.settingNames == ["interval", "processes", "sortBy", "cpuWarning", "memoryWarning"])
}

/// The pixels of `image`, to compare two drawings.
private func pixels(_ image: NSBitmapImageRep) -> Data? {
    image.bitmapData.map { Data(bytes: $0, count: image.bytesPerRow * image.pixelsHigh) }
}

/// A setup scene draws the step it names with nothing moving, so two drawings match however long each settles. The
/// first step loads nothing as it opens, unlike the theme cards of the second, and fits without scrolling, and the bar
/// shows no clock, whose time zone other tests change, so only motion could tell the drawings apart.
/// Like every scene it runs nothing: setup's choices show in the tour, not on the bar, where the widgets a preset adds
/// would start their commands.
@Test @MainActor func setupSceneDrawsTheSameStepHoweverLongItSettles() async throws {
    let directory = try scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let json = #"""
    {"configuration": "config.json", "draw": "setup",
     "setup": {"step": "placement", "placement": "top", "preset": "developer"}, "width": 1200, "height": 1000}
    """#
    var images: [NSBitmapImageRep] = []
    for (name, settle) in [("early", Duration.seconds(1)), ("late", .milliseconds(2200))] {
        let folder = directory.appending(path: name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"widgets": [{"id": "hello", "type": "text", "position": "left", "text": "Hello"}]}"#.utf8)
            .write(to: folder.appending(path: "config.json"))
        let store = try store(json, in: folder)
        defer { store.stop() }
        let url = directory.appending(path: "\(name).png")
        try await SceneRenderer.draw(scene(json), store: store, appearance: .dark, to: url, settle: settle)
        images.append(try #require(NSBitmapImageRep(data: Data(contentsOf: url))))
        #expect(store.sessionEdits.isEmpty)
        #expect(store.scripts.isEmpty)
    }
    #expect(images[0].pixelsWide == 2400)
    #expect(images[0].pixelsHigh == 2000)
    #expect(colors(images[0]) > 10)
    if pixels(images[0]) != pixels(images[1]) {
        for name in ["early", "late"] {
            try? FileManager.default.copyItem(at: directory.appending(path: "\(name).png"), to: URL(filePath: "test-results/setup-scene-\(name).png"))
        }
    }
    #expect(pixels(images[0]) == pixels(images[1]))
}

/// A configured manager needs no connection result while its check is off screen. Every setup step must still draw.
@Test(arguments: ["placement", "look", "permissions", "tryIt"]) @MainActor
func setupScenesOutsideFinishingTouchesDoNotWaitForAWorkspaceCheck(step: String) async throws {
    let directory = try scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (_, store) = try await drawn(#"""
    {"configuration": {"workspaceSource": "yabai", "widgets": [{"id": "spaces", "type": "workspaces", "position": "left"}]},
     "draw": "setup", "setup": {"step": "\#(step)"}}
    """#, in: directory)
    defer { store.stop() }
    #expect(!store.workspaceStore.isRunning)
    #expect(store.scripts.isEmpty)
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

// MARK: - Review fixes

/// Records requests to `scene-image.invalid` and fails them, so a test can tell whether a render asked the network for an image.
/// The URL loading system records from its own threads while the test reads on the main actor, so a lock guards the list.
private final class RecordingURLProtocol: URLProtocol, @unchecked Sendable {
    private static let recorded = OSAllocatedUnfairLock<[URL]>(initialState: [])
    static var requests: [URL] { recorded.withLock { $0 } }
    static func reset() { recorded.withLock { $0 = [] } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "scene-image.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let url = request.url { Self.recorded.withLock { $0.append(url) } }
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

@Test @MainActor func settingsSceneLoadsNoOtherBar() async throws {
    let directory = try scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let ran = directory.appending(path: "ran")
    try Data(#"{"widgets": [{"id": "hello", "type": "text", "position": "left", "text": "Hello"}]}"#.utf8)
        .write(to: directory.appending(path: "config.json"))
    try Data(#"{"widgets": [{"id": "probe", "type": "script", "position": "left", "command": "touch '\#(ran.path)'", "interval": 1}]}"#.utf8)
        .write(to: directory.appending(path: ScreenSetup([display]).fileName))
    let scene = try scene(#"{"configuration": "config.json", "draw": "settings", "section": "general"}"#)
    let store = try SceneRenderer.store(for: scene, at: directory.appending(path: "scene.json"), in: directory.appending(path: "work"),
                                        themes: themes)
    defer { store.stop() }
    try await SceneRenderer.draw(scene, store: store, appearance: .light, to: directory.appending(path: "out.png"), settle: .milliseconds(300))
    try await Task.sleep(for: .seconds(1))
    #expect(store.configuration?.widgets.map(\.id) == ["hello"])
    #expect(store.scripts.values.allSatisfy { $0.diagnostics.lastStarted == nil })
    #expect(!FileManager.default.fileExists(atPath: ran.path))
}

@Test @MainActor func sceneRenderMakesNoImageRequest() async throws {
    let directory = try scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    URLProtocol.registerClass(RecordingURLProtocol.self)
    defer { URLProtocol.unregisterClass(RecordingURLProtocol.self) }
    RecordingURLProtocol.reset()
    let (_, store) = try await drawn(#"""
    {"configuration": {"widgets": [{"id": "pic", "type": "text", "position": "left", "text": "Pic",
      "popup": {"style": {"width": 200}, "layout": {"type": "column", "children": [{"type": "image", "path": "https://scene-image.invalid/icon.png"}]}}}]},
     "draw": "popup", "widget": "pic"}
    """#, in: directory)
    defer { store.stop() }
    try await Task.sleep(for: .milliseconds(500))
    #expect(RecordingURLProtocol.requests.isEmpty)
}

@Test @MainActor func updateSceneDrawsASampleOfferWithoutAskingGitHub() async throws {
    let directory = try scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    URLProtocol.registerClass(RecordingURLProtocol.self)
    defer { URLProtocol.unregisterClass(RecordingURLProtocol.self) }
    RecordingURLProtocol.reset()
    let (image, store) = try await drawn(#"{"configuration": {"widgets": []}, "draw": "update"}"#, in: directory)
    defer { store.stop() }
    let update = try #require(store.update)
    #expect(update.version != nil)
    #expect(update.starRequest.state == .repository)
    #expect(image.pixelsWide == Int((2 * (360 + 48.0)).rounded()))
    #expect(image.pixelsHigh == Int((2 * (420 + 48.0)).rounded()))
    #expect(colors(image) > 10)
    try await Task.sleep(for: .milliseconds(500))
    #expect(RecordingURLProtocol.requests.isEmpty)
}

@Test @MainActor func updateSceneDrawsTheStarRequestItNames() async throws {
    let directory = try scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (_, store) = try await drawn(#"{"configuration": {"widgets": []}, "draw": "update", "starRequest": "thanked"}"#, in: directory)
    defer { store.stop() }
    #expect(try #require(store.update).starRequest.state == .thanked(account: "octocat"))
}

@Test @MainActor func sceneActiveAppComesFromItsBundle() throws {
    let directory = try scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try store(#"{"configuration": {"widgets": []}, "activeApp": "com.apple.calculator", "draw": "bar"}"#, in: directory)
    defer { store.stop() }
    #expect(store.activeApp?.localizedName == "Calculator")
    #expect(store.activeApp?.icon != nil)
}

@Test @MainActor func sceneStoreShowsAStablePath() throws {
    let directory = try scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let scene = try scene(#"{"configuration": {"widgets": []}, "draw": "settings", "section": "general"}"#)
    let sceneURL = directory.appending(path: "general.json")
    let first = try SceneRenderer.store(for: scene, at: sceneURL, in: directory.appending(path: "one"), themes: themes)
    let second = try SceneRenderer.store(for: scene, at: sceneURL, in: directory.appending(path: "two"), themes: themes)
    defer { first.stop(); second.stop() }
    #expect(first.configurationURL == second.configurationURL)
    #expect(first.configurationURL.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL)
}

@Test @MainActor func sceneStoreKeepsProfiles() throws {
    let directory = try scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try store(#"""
    {"configuration": {"widgets": [], "profiles": [{"name": "Work", "configuration": {"bar": {"height": 40}}}]}, "draw": "settings", "section": "profiles"}
    """#, in: directory)
    defer { store.stop() }
    #expect(store.profiles.map(\.name) == ["Work"])
}

@Test @MainActor func sceneStoreResolvesProfilesForItsAppearance() throws {
    let directory = try scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let scene = try scene(#"""
    {"configuration": {
      "bar": {"height": 30},
      "widgets": [{"id": "label", "type": "text", "position": "left", "text": "Label"}],
      "profiles": [{"name": "Night", "when": {"appearance": "dark"}, "configuration": {"bar": {"height": 44}}}]
    }, "draw": "bar"}
    """#)
    func height(_ appearance: SceneFile.Appearance) throws -> (Double?, String) {
        let store = try SceneRenderer.store(for: scene, at: directory.appending(path: "scene.json"),
                                            in: directory.appending(path: appearance.rawValue), themes: themes, appearance: appearance)
        defer { store.stop() }
        return (store.configuration?.bar.height,
                "context=\(store.context.appearance) active=\(store.activeProfiles) error=\(String(describing: store.configurationError)) whens=\(store.profiles.map { String(describing: $0.when) })")
    }
    let light = try height(.light), dark = try height(.dark)
    #expect(light.0 == 30, "\(light.1)")
    #expect(dark.0 == 44, "\(dark.1)")
}

@Test @MainActor func inlineSceneResolvesIncludesBesideTheScene() throws {
    let directory = try scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data(#"{"widgets": [{"id": "included", "type": "text", "position": "left", "text": "Included"}]}"#.utf8)
        .write(to: directory.appending(path: "included.json"))
    let store = try store(#"{"configuration": {"includes": ["included.json"]}, "draw": "bar"}"#, in: directory)
    defer { store.stop() }
    #expect(store.configuration?.widgets.map(\.id) == ["included"])
}

@Test @MainActor func renderAllFailsWhenItCannotWriteItsReport() async throws {
    let directory = try scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let scenes = directory.appending(path: "scenes"), output = directory.appending(path: "out")
    try FileManager.default.createDirectory(at: scenes, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: output.appending(path: "scenes.json"), withIntermediateDirectories: true)
    try Data(darkBar.utf8).write(to: scenes.appending(path: "good.json"))
    let summary = await SceneRenderer.renderAll([scenes], to: output, settle: .milliseconds(300))
    #expect(summary.failures >= 1)
}
