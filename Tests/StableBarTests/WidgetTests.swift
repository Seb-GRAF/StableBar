import Foundation
import Observation
import SwiftUI
import Testing
@testable import StableBar

@Test func scriptOutputSupportsTextAndRichUpdates() throws {
    let plain = try ScriptOutput.read(Data("  1.42\n".utf8))
    #expect(plain.text == "1.42")
    let rich = try ScriptOutput.read(Data(##"{"text":"Building","icon":"hammer","color":"#f7821b80","tooltip":"App build"}"##.utf8))
    #expect(rich.text == "Building")
    #expect(rich.icon == "hammer")
    #expect(rich.color?.rgba == 0xf7821b80)
    #expect(rich.tooltip == "App build")
    let popup = try ScriptOutput.read(Data(#"{"text":"30%","value":0.3,"fields":{"usage":"30%"},"lists":{"processes":[{"name":"Window Server","cpu":"90.1%","memory":"108 MB"}]}}"#.utf8))
    #expect(popup.fields?["usage"] == "30%")
    #expect(popup.lists?["processes"]?.first?["name"] == "Window Server")
    #expect(popup.value == 0.3)
}

@Test func brokenRichOutputIsNotRenderedAsText() {
    #expect(throws: DecodingError.self) {
        try ScriptOutput.read(Data(#"{"text":"Building","color":"orange"}"#.utf8))
    }
    #expect(throws: DecodingError.self) {
        try ScriptOutput.read(Data(#"{"text":"30%","lists":{"processes":[{"cpu":30}]}}"#.utf8))
    }
}

@Test func namedGraphsKeepOnlyTheLatestSixtySamples() throws {
    let values = (0..<80).map { Double($0) / 100 }
    let data = try JSONSerialization.data(withJSONObject: ["text": "History", "series": ["cpu": values]])
    let output = try ScriptOutput.read(data)
    #expect(output.series?["cpu"] == Array(values.suffix(60)))
}

@Test func progressClipsNumbersBeforeDrawingAndConvertingToPercent() {
    #expect(progressFraction(0.4) == 0.4)
    #expect(progressFraction(-10) == 0)
    #expect(progressFraction(1e300) == 1)
    #expect(progressFraction(.infinity) == 0)
    #expect(progressFraction(.nan) == 0)
}

@Test func triggerArgumentsPreserveLiteralValuesWithoutShellExpansion() throws {
    let command = try LaunchCommand(arguments: ["--trigger", "build", "INFO=hello = 'world' $(date)", "EMPTY="])
    guard case let .trigger(name, environment) = command else {
        Issue.record("Expected an event command.")
        return
    }
    #expect(name == "build")
    #expect(environment == ["INFO": "hello = 'world' $(date)", "EMPTY": ""])
    for arguments in [["--trigger"], ["--trigger", "build", "INFO"], ["--trigger", "build", "=value"], ["--unknown"]] {
        #expect(throws: CommandFailure.self) { try LaunchCommand(arguments: arguments) }
    }
}

@Test func popupStylesInheritWidgetOverridesAndGlobalTheme() {
    let defaults = WidgetStyle(foreground: HexColor(0xeeeeeeff), background: HexColor(0x222222ff),
                               fontName: "Helvetica", fontSize: 12, paddingHorizontal: 7, width: 80)
    let widget = WidgetStyle(background: HexColor(0x333333ff), fontWeight: "bold", width: 85)
    let popup = WidgetStyle(fontSize: 18, paddingHorizontal: 16, width: 380)
    let style = popup.inheriting(widget.inheriting(defaults))
    #expect(style.foreground == defaults.foreground)
    #expect(style.background == widget.background)
    #expect(style.fontName == "Helvetica")
    #expect(style.fontWeight == "bold")
    #expect(style.fontSize == 18)
    #expect(style.paddingHorizontal == 16)
    #expect(style.width == 380)
}

@Test @MainActor func popupObservesScriptFieldsAndHistory() async throws {
    let widget = try JSONDecoder().decode(WidgetConfiguration.self, from: Data(#"{"id":"cpu","type":"script","command":"echo","position":"right","popup":{"height":200,"style":{},"layout":{"type":"field","field":"usage"}}}"#.utf8))
    let store = BarStore()
    let script = ScriptWidget()
    store.scripts[widget.id] = script
    let view = PopupView(popup: widget.popup!, style: WidgetStyle(), store: store, widget: widget)
    await confirmation("Popup observes new fields") { changed in
        withObservationTracking { _ = view.body } onChange: { changed() }
        script.output = ScriptOutput(text: "30%", fields: ["usage": "30%"])
    }
    await confirmation("Popup observes new graph samples") { changed in
        withObservationTracking { _ = view.body } onChange: { changed() }
        script.samples.append(0.3)
    }
}

@Test func duplicateIdsCannotBreakWidgetIdentity() {
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(Configuration.self, from: Data(#"{"widgets":[{"id":"clock","type":"clock","position":"left"},{"id":"clock","type":"clock","position":"right"}]}"#.utf8))
    }
}

@Test func zeroIntervalCannotStartABusyLoop() {
    #expect(throws: CommandFailure.self) {
        try JSONDecoder().decode(Configuration.self, from: Data(#"{"widgets":[{"id":"test","type":"script","position":"left","command":"date","interval":0}]}"#.utf8))
    }
}

@Test func commandOutputLargerThanAPipeBufferCompletes() async throws {
    let data = try await runCommand("/usr/bin/head", arguments: ["-c", "131072", "/dev/zero"])
    #expect(data.count == 131072)
}

@Test func commandFailureIncludesStderr() async {
    do {
        _ = try await runCommand("/bin/zsh", arguments: ["-c", "printf 'widget failed' >&2; exit 3"])
        Issue.record("The failed command was accepted.")
    } catch {
        #expect(error.localizedDescription == "widget failed")
    }
}

@Test func cancellingAWidgetStopsItsRunningCommand() async throws {
    let start = ContinuousClock.now
    let task = Task { try await runCommand("/bin/sleep", arguments: ["5"]) }
    try await Task.sleep(for: .milliseconds(100))
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(start.duration(to: .now) < .seconds(2))
}

@Test func workspaceSnapshotKeepsMonitorFocusAndDeduplicatesAppWindows() throws {
    let spaces = Data(#"[{"workspace":"10","workspace-is-focused":false,"workspace-is-visible":false,"monitor-appkit-nsscreen-screens-id":2},{"workspace":"2","workspace-is-focused":false,"workspace-is-visible":true,"monitor-appkit-nsscreen-screens-id":2},{"workspace":"1","workspace-is-focused":true,"workspace-is-visible":true,"monitor-appkit-nsscreen-screens-id":1}]"#.utf8)
    let windows = Data(#"[{"workspace":"1","app-name":"Finder","app-bundle-id":"com.apple.finder"},{"workspace":"1","app-name":"Finder","app-bundle-id":"com.apple.finder"},{"workspace":"2","app-name":"Finder","app-bundle-id":"com.apple.finder"}]"#.utf8)
    let snapshot = try workspaceSnapshot(workspaces: spaces, windows: windows)
    #expect(snapshot.map(\.name) == ["1", "2", "10"])
    #expect(snapshot[0].isFocused)
    #expect(!snapshot[1].isFocused)
    #expect(snapshot[1].isVisible)
    #expect(snapshot[1].monitor == 2)
    #expect(snapshot[0].apps.count == 1)
    #expect(snapshot[1].apps.count == 1)
    #expect(snapshot[2].apps.isEmpty)
}

@Test func yabaiSnapshotMapsDisplaysAndAppWindowsToWorkspaces() throws {
    let spaces = Data(#"[{"index":10,"display":1,"has-focus":false,"is-visible":false},{"index":2,"display":1,"has-focus":true,"is-visible":true},{"index":1,"display":2,"has-focus":false,"is-visible":true}]"#.utf8)
    let windows = Data(#"[{"pid":41,"app":"Safari","space":1},{"pid":42,"app":"Finder","space":1},{"pid":43,"app":"Safari","space":1},{"pid":41,"app":"Safari","space":2}]"#.utf8)
    let displays = Data(#"[{"id":80,"index":1},{"id":90,"index":2}]"#.utf8)
    let snapshot = try yabaiSnapshot(spaces: spaces, windows: windows, displays: displays, screenIDs: [90, 80],
                                     bundleIDs: [41: "com.apple.Safari", 42: "com.apple.finder", 43: "com.apple.Safari"])
    #expect(snapshot.map(\.name) == ["1", "2", "10"])
    #expect(snapshot.map(\.monitor) == [1, 2, 2])
    #expect(snapshot[1].isFocused)
    #expect(snapshot[0].isVisible)
    #expect(snapshot[0].apps.map(\.bundleID) == ["com.apple.finder", "com.apple.Safari"])
    #expect(snapshot[1].apps.count == 1)
    #expect(snapshot[2].apps.isEmpty)
    let disconnected = try yabaiSnapshot(spaces: spaces, windows: windows, displays: displays, screenIDs: [90], bundleIDs: [:])
    #expect(disconnected.map(\.name) == ["1"])
    #expect(disconnected[0].apps.map(\.name) == ["Finder", "Safari"])
}

@Test @MainActor func displayedWorkspacesKeepEmptyVisibleSpacesOnTheirMonitor() {
    let workspaceStore = WorkspaceStore()
    workspaceStore.workspaces = [
        Workspace(name: "1", isFocused: false, isVisible: false, monitor: 1,
                  apps: [WorkspaceApp(workspace: "1", name: "Finder", bundleID: "com.apple.finder")]),
        Workspace(name: "2", isFocused: false, isVisible: false, monitor: 1),
        Workspace(name: "3", isFocused: true, isVisible: true, monitor: 1),
        Workspace(name: "4", isFocused: false, isVisible: true, monitor: 2)
    ]
    #expect(workspaceStore.workspaces(on: 1, showEmpty: false).map(\.name) == ["1", "3"])
    #expect(workspaceStore.workspaces(on: 1, showEmpty: true).map(\.name) == ["1", "2", "3"])
    #expect(workspaceStore.workspaces(on: 2, showEmpty: false).map(\.name) == ["4"])
    #expect(workspaceStore.workspaces(on: 3, showEmpty: false).isEmpty)

    workspaceStore.workspaces[2] = Workspace(name: "3", isFocused: false, isVisible: false, monitor: 1)
    #expect(workspaceStore.workspaces(on: 1, showEmpty: false).map(\.name) == ["1"])
}

@Test @MainActor func workspaceRowGrowsWhenAnEmptyWorkspaceAppears() throws {
    let workspaceStore = WorkspaceStore()
    workspaceStore.workspaces = [
        Workspace(name: "1", isFocused: false, isVisible: false, monitor: 1,
                  apps: [WorkspaceApp(workspace: "1", name: "Finder", bundleID: "com.apple.finder")]),
        Workspace(name: "2", isFocused: true, isVisible: true, monitor: 1,
                  apps: [WorkspaceApp(workspace: "2", name: "Finder", bundleID: "com.apple.finder")])
    ]
    let view = WorkspaceView(workspaceStore: workspaceStore, monitor: 1,
                             appearance: WidgetAppearance(WidgetStyle(), defaults: WidgetStyle()), animationDuration: 0)
    let initialWidth = try #require(ImageRenderer(content: view).nsImage).size.width
    workspaceStore.workspaces[1] = Workspace(name: "2", isFocused: false, isVisible: false, monitor: 1,
                                       apps: workspaceStore.workspaces[1].apps)
    workspaceStore.workspaces.append(Workspace(name: "3", isFocused: true, isVisible: true, monitor: 1))
    let expandedWidth = try #require(ImageRenderer(content: view).nsImage).size.width
    let renderer = ImageRenderer(content: view)
    renderer.proposedSize = ProposedViewSize(width: initialWidth, height: nil)
    #expect(expandedWidth > initialWidth)
    #expect(try #require(renderer.nsImage).size.width == expandedWidth)
}

@Test func notchGroupsStayOutsideAnOffCenterNotch() {
    let layout = BarLayout(inset: 12, spacing: 8, notchSpacing: 16, notch: 720...940)
    let x = layout.origins(width: 1728, sizes: [180, 260, 0, 200, 340])
    #expect(x[0] == 12)
    #expect(x[1] + 260 == 704)
    #expect(x[3] == 956)
    #expect(x[4] + 340 == 1716)
}

@Test func externalDisplayCentersTheCombinedGroupWithoutPhantomGaps() {
    let layout = BarLayout(inset: 12, spacing: 8, notchSpacing: 16, notch: nil)
    let x = layout.origins(width: 1920, sizes: [180, 260, 0, 100, 340])
    #expect(x[1] == 776)
    #expect(x[3] == 1044)
    #expect(x[1] == 1920 - (x[3] + 100))
    let musicOnly = layout.origins(width: 1920, sizes: [180, 260, 0, 0, 340])
    #expect(musicOnly[1] == 830)
    let center = layout.origins(width: 1920, sizes: [180, 0, 100, 0, 340])
    #expect(center[2] == 910)
}

@Test func displayFilteringTracksFocusAndScreenSelectors() {
    let laptop = BarDisplay(id: 2, isBuiltIn: true, isMain: false, notch: 650...870)
    let monitor = BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil)
    #expect(DisplaySelection.active.includes(laptop, activeID: 2))
    #expect(!DisplaySelection.active.includes(laptop, activeID: 1))
    #expect(DisplaySelection.ids([1]).includes(monitor, activeID: 2))
    #expect(!DisplaySelection.ids([2]).includes(monitor, activeID: 2))
    #expect(DisplaySelection.notched.includes(laptop, activeID: 1))
    #expect(DisplaySelection.unnotched.includes(monitor, activeID: 1))
    #expect(DisplaySelection.external.includes(monitor, activeID: 2))
}

@Test @MainActor func scriptRecoversAfterACommandFailure() async throws {
    let marker = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let script = ScriptWidget()
    defer {
        script.stop()
        try? FileManager.default.removeItem(at: marker)
    }
    script.start(command: "if [ -f '\(marker.path)' ]; then echo Ready; else touch '\(marker.path)'; echo Offline >&2; exit 1; fi", interval: 0.02)
    for _ in 0..<100 {
        if script.output.text == "Ready" { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(script.output.text == "Ready")
    #expect(script.error == nil)
}

@Test @MainActor func invalidRuntimeIntervalKeepsTheLastGoodOutput() async throws {
    let script = ScriptWidget()
    script.output = ScriptOutput(text: "Ready")
    defer { script.stop() }
    script.start(command: "echo '{\"text\":\"Broken\",\"interval\":0}'", interval: 30)
    for _ in 0..<100 {
        if script.error != nil { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(script.output.text == "Ready")
    #expect(script.error == "A script interval must be greater than zero.")
}

@Test func setupKeepsUntouchedConfigurationByteForByte() throws {
    let data = Data(#"{ "widgets": [{"id":"time","type":"clock","position":"right","format":"HH.mm"}], "bar": {"height": 30} }"#.utf8)
    #expect(try SetupPreferences().applying(to: data, menuBarHeight: 38) == data)
}

@Test func setupChangesOnlySelectedSettingsAndPreservesCustomWidgets() throws {
    let data = Data(##"""
    {
      "bar": {"height": 48, "offset": 12, "notchSpacing": 20},
      "defaults": {"fontName": "Helvetica", "accent": "#ff8800", "paddingHorizontal": 15},
      "widgets": [
        {"id": "time", "type": "clock", "position": "right", "format": "HH.mm", "style": {"foreground": "#abcdef"}},
        {"id": "custom", "type": "script", "position": "left", "command": "~/my-widget.sh", "interval": 12,
         "layout": {"type": "field", "field": "text"}, "events": ["wake"]}
      ]
    }
    """##.utf8)
    let preferences = SetupPreferences(appearance: .dark, placement: .belowMenuBar, clock: .twelveHour)
    let updated = try preferences.applying(to: data, menuBarHeight: 38)
    let configuration = try JSONDecoder().decode(Configuration.self, from: updated)
    #expect(configuration.bar.offset == 38)
    #expect(configuration.bar.height == 48)
    #expect(configuration.bar.notchSpacing == 20)
    #expect(configuration.defaults.foreground == HexColor(0xf5f5f7ff))
    #expect(configuration.defaults.fontName == "Helvetica")
    #expect(configuration.defaults.accent == HexColor(0xff8800ff))
    #expect(configuration.widgets[0].content == .clock(format: "EEE d MMM  h:mm a"))
    #expect(configuration.widgets[0].style.foreground == HexColor(0xabcdefff))
    let original = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let result = try JSONSerialization.jsonObject(with: updated) as! [String: Any]
    #expect((original["widgets"] as! [NSDictionary])[1] == (result["widgets"] as! [NSDictionary])[1])
    let clockOnly = try SetupPreferences(clock: .twentyFourHour).applying(to: updated, menuBarHeight: 24)
    let clockResult = try JSONSerialization.jsonObject(with: clockOnly) as! [String: Any]
    #expect(clockResult["defaults"] as! NSDictionary == result["defaults"] as! NSDictionary)
    #expect(clockResult["bar"] as! NSDictionary == result["bar"] as! NSDictionary)
}

@Test func setupRejectsInvalidConfigurationBeforeEditing() {
    #expect(throws: CommandFailure.self) {
        try SetupPreferences(appearance: .dark).applying(
            to: Data(#"{"widgets":[{"id":"custom","type":"script","position":"left","command":"date","interval":0}]}"#.utf8),
            menuBarHeight: 24)
    }
}

@Test func setupOverridesImportedAndTemplatedClocksWithoutChangingModules() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let module = directory.appending(path: "clocks.json")
    let moduleData = Data(#"{"widgets":[{"id":"imported","type":"clock","position":"right","format":"HH.mm"}]}"#.utf8)
    try moduleData.write(to: module)
    let root = directory.appending(path: "config.json")
    let data = Data(#"""
    {
      "includes": ["clocks.json"],
      "templates": {"clock": {"type":"clock", "position":"left"}},
      "widgets": [{"id":"local", "template":"clock"}],
      "widgetOverrides": {"imported": {"style": {"fontSize": 15}}}
    }
    """#.utf8)
    let updated = try SetupPreferences(clock: .twelveHour).applying(to: data, menuBarHeight: 24, configurationURL: root)
    var loader = ConfigurationLoader()
    let configuration = try loader.load(root, data: updated)
    #expect(configuration.widgets.map(\.content) == [.clock(format: "EEE d MMM  h:mm a"), .clock(format: "EEE d MMM  h:mm a")])
    #expect(configuration.widgets[0].style.fontSize == 15)
    #expect(try Data(contentsOf: module) == moduleData)
    let document = try JSONDecoder().decode([String: ConfigurationValue].self, from: updated)
    #expect(document["includes"] == .array([.string("clocks.json")]))
    #expect(document["widgets"] == .array([.object(["id": .string("local"), "template": .string("clock"), "format": .string("EEE d MMM  h:mm a")])]))
    #expect(document["widgetOverrides"] == .object(["imported": .object(["style": .object(["fontSize": .number(15)]), "format": .string("EEE d MMM  h:mm a")])]))
}

@Test func setupWritesRootSettingsThatActiveProfilesCanStillOverride() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "setup-profile.json")
    let data = Data(##"""
    {
      "bar": {"height": 40, "offset": 5},
      "defaults": {"fontSize": 16, "foreground": "#abcdef"},
      "widgets": [{"id": "clock", "type": "clock", "position": "right"}],
      "profiles": [{"name": "desktop", "configuration": {
        "defaults": {"foreground": "#112233"},
        "bar": {"offset": 90},
        "widgetOverrides": {"clock": {"format": "ss"}}
      }}]
    }
    """##.utf8)
    let updated = try SetupPreferences(appearance: .dark, placement: .belowMenuBar, clock: .twelveHour)
        .applying(to: data, menuBarHeight: 24, configurationURL: root)
    let document = try JSONDecoder().decode([String: ConfigurationValue].self, from: updated)
    let original = try JSONDecoder().decode([String: ConfigurationValue].self, from: data)
    #expect(document["bar"] == .object(["height": .number(40), "offset": .number(24)]))
    #expect(try document["defaults"]?.decoded(WidgetStyle.self).foreground == HexColor(0xf5f5f7ff))
    #expect(document["widgets"] == .array([.object(["id": .string("clock"), "type": .string("clock"), "position": .string("right"),
                                                    "format": .string("EEE d MMM  h:mm a")])]))
    #expect(document["profiles"] == original["profiles"])
    var loader = ConfigurationLoader()
    let configuration = try loader.load(root, data: updated)
    #expect(configuration.defaults.foreground == HexColor(0x112233ff))
    #expect(configuration.bar.offset == 90)
    #expect(configuration.widgets[0].content == .clock(format: "ss"))
}

@Test func setupFindsClocksIntroducedByTheCurrentProfile() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "setup-profile-clock.json")
    let data = Data(#"""
    {"widgets":[],"profiles":[
      {"name":"portable","when":{"onBattery":true},"configuration":{
        "widgets":[{"id":"portable-clock","type":"clock","position":"right","format":"ss"}]
      }}
    ]}
    """#.utf8)
    let context = ConfigurationContext(onBattery: true)
    let updated = try SetupPreferences(clock: .twelveHour)
        .applying(to: data, menuBarHeight: 24, configurationURL: root, context: context)
    var loader = ConfigurationLoader()
    let configuration = try loader.load(root, data: updated, context: context)
    #expect(configuration.widgets[0].content == .clock(format: "EEE d MMM  h:mm a"))
}
