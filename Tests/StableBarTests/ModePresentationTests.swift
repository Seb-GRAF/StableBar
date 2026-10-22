import AppKit
import Foundation
import Observation
import Testing
@testable import StableBar

private func modeConfiguration(_ json: String) throws -> Configuration {
    try JSONDecoder().decode(Configuration.self, from: Data(json.utf8))
}

@Test func modeStatesHaveReservedNamesAndTheDocumentedCascade() throws {
    let style = try JSONDecoder().decode(WidgetStyle.self, from: Data(##"""
    {"foreground":"#000000","states":{
      "warning":{"foreground":"#111111","states":{"mode.command":{"background":"#abcdef"}}},
      "focused":{"foreground":"#222222"},"mode":{"foreground":"#333333"},
      "mode.command":{"foreground":"#444444"},"hover":{"foreground":"#555555"},"open":{"foreground":"#666666"}}}
    """##.utf8))
    let mode = ModePresentation(mode: "tailing", aliases: ["tailing": "command"])
    var states = StyleStates(data: "warning", workspace: .focused, mode: mode)
    #expect(states.names == ["warning", "focused", "mode", "mode.command"])
    #expect(style.resolved(for: states).foreground == HexColor(0x444444ff))
    #expect(style.resolved(for: states).background == .color(HexColor(0xabcdefff)))
    states.hover = true
    #expect(style.resolved(for: states).foreground == HexColor(0x555555ff))
    states.open = true
    #expect(style.resolved(for: states).foreground == HexColor(0x666666ff))
    #expect(StyleStates(mode: ModePresentation(mode: "unmapped")).names == ["mode"])
    #expect(StyleStates(mode: ModePresentation(mode: "main", aliases: ["main": "command"])).names.isEmpty)
    #expect(StyleStates(mode: ModePresentation()).names.isEmpty)
    for name in ["mode", "mode.command", "mode.", "mode.user.name"] {
        #expect(dataState(try ScriptOutput.read(Data("{\"text\":\"\",\"state\":\"\(name)\"}".utf8))) == nil)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(StyleRule.self, from: Data("{\"when\":{\"field\":\"a\",\"equals\":\"b\"},\"state\":\"\(name)\"}".utf8))
        }
    }
}

@Test func modeConnectionCoversPresentationAndSubscribersWithoutWorkspaceWidgets() throws {
    for extra in [
        #""bar":{"style":{"states":{"mode.command":{"borderEdges":"all"}}}}"#,
        #""defaults":{"states":{"warning":{"states":{"mode":{"fontSize":20}}}}}"#,
        #""widgets":[{"id":"m","type":"script","position":"left","command":"true","events":["aerospaceMode"]}]"#,
        ##""widgets":[{"id":"m","type":"text","position":"left","text":"M","layout":{"type":"text","text":"M","style":{"states":{"mode":{"foreground":"#111111"}}}}}]"##
    ] {
        let json = extra.hasPrefix("\"widgets\"") ? "{\(extra)}" : "{\"widgets\":[],\(extra)}"
        #expect(try modeConfiguration(json).needsModeConnection)
    }
    #expect(try !modeConfiguration(#"{"widgets":[],"modeAliases":{"tailing":"command"}}"#).needsModeConnection)
    #expect(try !modeConfiguration(#"{"widgets":[],"groups":{"g":{"style":{"states":{"mode":{"fontSize":20}}}}}}"#).needsModeConnection)
    for mapping in [#"{"":"command"}"#, #"{"tailing":""}"#, #"{"tailing":"mode.command"}"#] {
        #expect(throws: (any Error).self) { try modeConfiguration("{\"widgets\":[],\"modeAliases\":\(mapping)}") }
    }
    #expect(try modeConfiguration(#"{"widgets":[],"modeAliases":{"tailing":null}}"#).modeAliases.isEmpty)
}

@Test @MainActor func modeChangesOnlyRestyleAffectedInstancesAndKeepPopupOwnership() async throws {
    let configuration = try modeConfiguration(##"""
    {"modeAliases":{"tailing":"command"},"bar":{"style":{"borderWidth":1,"borderColor":"#111111",
      "states":{"mode.command":{"borderEdges":"all","borderColor":"#ccaa88"}}}},"widgets":[
      {"id":"plain","type":"text","position":"left","text":"P"},
      {"id":"mode","type":"text","position":"right","text":"M","style":{"states":{"mode":{"fontSize":17}}}}]}
    """##)
    let store = BarStore(configurationURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
    store.configuration = configuration
    store.preparePresentations()
    defer { store.stop() }
    let plain = try #require(store.presentations["plain"])
    let affected = try #require(store.presentations["mode"])
    let anchor = NSView()
    store.setPopupVisibleWidget("plain", anchor: anchor)
    let bar = BarView(store: store, display: BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil))
    await confirmation("plain style, ownership and layout remain valid", expectedCount: 0) { changed in
        withObservationTracking { _ = plain.style; _ = plain.popupAnchor; _ = bar.body } onChange: { changed() }
        store.workspaceStore.acceptMode("tailing")
    }
    #expect(store.barStyle.borderEdges == .all)
    #expect(store.barStyle.borderColor == HexColor(0xccaa88ff))
    #expect(affected.style.style(hovered: false).fontSize == 17)
    #expect(plain.popupAnchor == ObjectIdentifier(anchor))
    store.workspaceStore.acceptMode("main")
    #expect(store.barStyle.borderEdges == nil)
    #expect(store.barStyle.borderColor == HexColor(0x111111ff))
    store.workspaceStore.acceptMode("tailing")
    store.workspaceStore.source = .yabai
    #expect(store.workspaceStore.mode == nil)
    #expect(store.barStyle.borderEdges == nil)
    store.workspaceStore.acceptMode("tailing")
    #expect(store.workspaceStore.mode == nil)
}

@Test @MainActor func subscriptionReadsInitialModeReconnectsAndDoesNotQueryWorkspacesForModeOnlyEvents() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appending(path: "aerospace-fixture")
    let log = directory.appending(path: "calls")
    let script = """
    #!/bin/sh
    echo "$1" >> '\(log.path)'
    printf '%s\\n' '{"_event":"mode-changed","mode":"tailing"}'
    /bin/sleep 0.15
    """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let store = WorkspaceStore()
    store.reconnectDelay = 0.04
    store.executablePath = { executable.path }
    var changes: [String?] = []
    store.onModeChange = { changes.append($0) }
    store.configure(source: .aerospace, workspaces: false, mode: true)
    defer { store.stop() }
    for _ in 0..<500 {
        if changes.filter({ $0 == "tailing" }).count >= 2 { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(changes.prefix(3).map { $0 ?? "disconnected" } == ["tailing", "disconnected", "tailing"])
    let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
    #expect(calls.count >= 2)
    #expect(calls.allSatisfy { $0 == "subscribe" })
    store.stop()
    #expect(store.mode == nil)
    #expect(!store.isRunning)
    store.configure(source: .yabai, workspaces: false, mode: true)
    #expect(!store.isRunning)
}

@Test func orderedOutputStylesRemoveStaleTargetsAndKeepOwnOutputLast() throws {
    let configuration = try modeConfiguration(#"{"widgets":[{"id":"a","type":"text","position":"left","text":"A"},{"id":"b","type":"text","position":"left","text":"B"}]}"#)
    var outputs = ["a": try ScriptOutput.read(Data(##"{"text":"A","widgetStyles":{"b":{"fontSize":18,"foreground":"#abcdef"}},"barStyle":{"borderEdges":"all"}}"##.utf8)),
                   "b": try ScriptOutput.read(Data(#"{"text":"B","style":{"fontSize":19}}"#.utf8))]
    var reads = 0
    let overrides = OrderedStyleOverrides(widgets: configuration.widgets) { reads += 1; return outputs[$0] }
    #expect(reads == 2)
    #expect(resolveStyle(widgetStyleLayers(configuration.widgets[1], defaults: WidgetStyle(), overrides: overrides, own: outputs["b"])).fontSize == 19)
    outputs.removeValue(forKey: "a")
    let removed = OrderedStyleOverrides(widgets: configuration.widgets) { outputs[$0] }
    #expect(removed.widgets.isEmpty)
    #expect(removed.bar.borderEdges == nil)
}

@Test @MainActor func themeSwitchInActiveModeRecomputesTokensAndRetainsTheConnectionAndScripts() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    for (id, color) in [("brass", "#aa8844"), ("blue", "#4488aa")] {
        let package = directory.appending(path: "packages/\(id)/1.0.0")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("{\"id\":\"\(id)\",\"name\":\"\(id)\",\"version\":\"1.0.0\",\"kind\":\"theme\",\"entry\":\"config.json\"}".utf8)
            .write(to: package.appending(path: "package.json"))
        try Data("{\"tokens\":{\"warning\":\"\(color)\"},\"bar\":{\"style\":{\"borderWidth\":1,\"states\":{\"mode.command\":{\"borderEdges\":\"all\",\"borderColor\":\"@token.warning\"}}}}}".utf8)
            .write(to: package.appending(path: "config.json"))
    }
    let executable = directory.appending(path: "aerospace-fixture")
    let calls = directory.appending(path: "calls")
    try Data("#!/bin/sh\necho subscribe >> '\(calls.path)'\nprintf '%s\\n' '{\"_event\":\"mode-changed\",\"mode\":\"tailing\"}'\nexec /bin/sleep 30\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let root = directory.appending(path: "config.json")
    try Data(#"{"theme":{"id":"brass","version":"1.0.0"},"modeAliases":{"tailing":"command"},"widgets":[{"id":"s","type":"script","position":"left","command":"printf ready","interval":300}]}"#.utf8).write(to: root)
    let store = BarStore(configurationURL: root)
    store.workspaceStore.executablePath = { executable.path }
    defer { store.stop() }
    store.reloadConfiguration()
    for _ in 0..<500 {
        if store.workspaceStore.mode == "tailing" { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(store.configurationError == nil)
    #expect(store.barStyle.borderColor == HexColor(0xaa8844ff))
    let script = try #require(store.scripts["s"])
    try script.accept(ScriptOutput.read(Data(##"{"text":"Ready","barStyle":{"borderColor":"#ffffff","borderEdges":"bottom"}}"##.utf8)))
    #expect(store.barStyle.borderEdges == .all)
    #expect(store.barStyle.borderColor == HexColor(0xaa8844ff))
    try store.applyEdits([ConfigurationEdit(action: .theme, properties: ["id": .string("blue"), "version": .string("1.0.0")])], persist: false)
    #expect(store.barStyle.borderColor == HexColor(0x4488aaff))
    #expect(store.barStyle.borderEdges == .all)
    #expect(store.scripts["s"] === script)
    #expect(store.workspaceStore.mode == "tailing")
    #expect(try String(contentsOf: calls, encoding: .utf8).split(separator: "\n").count == 1)
    store.workspaceStore.acceptMode("main")
    #expect(store.barStyle.borderColor == HexColor(0xffffffff))
    #expect(store.barStyle.borderEdges == .bottom)
    let before = store.configuration?.modeAliases
    #expect(throws: (any Error).self) {
        try store.applyEdits([ConfigurationEdit(action: .modeAliases, properties: ["tailing": .string("")])], persist: false)
    }
    #expect(store.configuration?.modeAliases == before)
}

@Test @MainActor func scriptOutputOnlyModeDemandSurvivesPresentationEditsAndSourceSwitchClearsIt() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appending(path: "aerospace-fixture"), calls = directory.appending(path: "calls")
    try Data("#!/bin/sh\necho subscribe >> '\(calls.path)'\nprintf '%s\\n' '{\"_event\":\"mode-changed\",\"mode\":\"tailing\"}'\nexec /bin/sleep 30\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let root = directory.appending(path: "config.json")
    let json = #"{"modeAliases":{"tailing":"command"},"widgets":[{"id":"s","type":"script","position":"left","command":"printf ready","interval":300}]}"#
    try Data(json.utf8).write(to: root)
    let store = BarStore(configurationURL: root)
    store.workspaceStore.executablePath = { executable.path }
    defer { store.stop() }
    store.reloadConfiguration()
    let script = try #require(store.scripts["s"])
    for _ in 0..<100 {
        if script.output.text == "ready" { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!store.workspaceStore.isRunning)
    try script.accept(ScriptOutput.read(Data(##"{"text":"Ready","widgetStyles":{"s":{"fontSize":15}},"barStyle":{"states":{"mode.command":{"borderEdges":"all","borderColor":"#aa8844"}}}}"##.utf8)))
    for _ in 0..<500 {
        if store.workspaceStore.mode == "tailing" { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(store.barStyle.borderEdges == .all)
    #expect(store.presentations["s"]?.style.base.fontSize == 15) // legacy self-targeted widgetStyles
    try store.applyEdits([ConfigurationEdit(action: .defaults, properties: ["fontSize": .number(14)])], persist: false)
    #expect(store.workspaceStore.mode == "tailing")
    #expect(store.scripts["s"] === script)
    #expect(try String(contentsOf: calls, encoding: .utf8).split(separator: "\n").count == 1)
    let switched = "{\"workspaceSource\":\"yabai\"," + json.dropFirst()
    try Data(switched.utf8).write(to: root)
    store.reloadConfiguration()
    #expect(store.configurationError == nil)
    #expect(store.workspaceStore.mode == nil)
    #expect(!store.workspaceStore.isRunning)
    #expect(store.barStyle.borderEdges == nil)
}

@Test @MainActor func optionalModeConnectionFailureStaysInDiagnosticsAndStopDoesNotReenter() async throws {
    let workspace = WorkspaceStore()
    workspace.executablePath = { throw CommandFailure(message: "Fixture unavailable") }
    workspace.reconnectDelay = 30
    workspace.configure(source: .aerospace, workspaces: false, mode: true)
    for _ in 0..<40 {
        if workspace.connectionError != nil { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(workspace.error == nil)
    #expect(workspace.connectionError == "Fixture unavailable")
    workspace.acceptMode("tailing")
    workspace.onModeChange = { _ in workspace.configure(source: .aerospace, workspaces: false, mode: true) }
    workspace.stop()
    #expect(!workspace.isRunning)
    #expect(workspace.mode == nil)
}

@Test func workspaceModeStatesApplyAfterWorkspaceStateAndBeforeHover() throws {
    let workspace = try JSONDecoder().decode(WorkspaceConfiguration.self, from: Data(##"""
    {"style":{"states":{"focused":{"foreground":"#111111"},"mode":{"foreground":"#222222"},"hover":{"foreground":"#333333"}}},
     "indicatorStyle":{"states":{"focused":{"height":2},"mode.command":{"height":3}}},
     "appStyle":{"states":{"mode.command":{"foreground":"#aa8844"}}}}
    """##.utf8))
    let styles = workspace.cellStyle(.focused, mode: ModePresentation(mode: "tailing", aliases: ["tailing":"command"]))
    #expect(styles.resting.foreground == HexColor(0x222222ff))
    #expect(styles.hovered.foreground == HexColor(0x333333ff))
    #expect(styles.underline.height == 3)
    #expect(styles.app.foreground == HexColor(0xaa8844ff))
}
