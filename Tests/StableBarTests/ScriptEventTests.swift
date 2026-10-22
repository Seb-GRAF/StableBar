import Foundation
import Testing
@testable import StableBar

@Test @MainActor func eventOnlyScriptsRunAtStartupAndOnExplicitRefresh() async throws {
    let log = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let script = ScriptWidget()
    defer {
        script.stop()
        try? FileManager.default.removeItem(at: log)
    }
    script.start(command: """
        printf '%s\n' "$SENDER" >> "$LOG"
        printf '{"text":"%s","interval":0.01}' "$SENDER"
        """, interval: nil, environment: ["LOG": log.path])
    for _ in 0..<100 {
        if script.output.text == "startup" { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(script.output.text == "startup")
    try await Task.sleep(for: .milliseconds(120))
    #expect(try String(contentsOf: log, encoding: .utf8) == "startup\n")
    script.refresh(ScriptEvent(sender: "manual"))
    for _ in 0..<100 {
        if script.output.text == "manual" { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(script.output.text == "manual")
    try await Task.sleep(for: .milliseconds(120))
    #expect(try String(contentsOf: log, encoding: .utf8) == "startup\nmanual\n")
}

@Test @MainActor func eventBurstsFinishCurrentCommandThenRunLatestPayloadWithoutOverlap() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let log = directory.appending(path: "commands")
    let started = directory.appending(path: "started")
    let release = directory.appending(path: "release")
    let script = ScriptWidget()
    defer {
        script.stop()
        try? FileManager.default.removeItem(at: directory)
    }
    script.start(command: """
        printf 'begin:%s:%s\n' "$SENDER" "$INFO" >> "$LOG"
        if [ "$SENDER" = startup ]; then
            touch "$STARTED"
            while [ ! -f "$RELEASE" ]; do sleep 0.01; done
        fi
        printf 'end:%s:%s\n' "$SENDER" "$INFO" >> "$LOG"
        printf '%s:%s' "$SENDER" "$INFO"
        """, interval: nil, timeout: 4,
        environment: ["LOG": log.path, "STARTED": started.path, "RELEASE": release.path, "INFO": "initial"])
    for _ in 0..<100 {
        if FileManager.default.fileExists(atPath: started.path) { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    try #require(FileManager.default.fileExists(atPath: started.path))
    script.refresh(ScriptEvent(sender: "first", environment: ["INFO": "discarded"]))
    script.refresh(ScriptEvent(sender: "second", environment: ["INFO": "discarded too"]))
    script.refresh(ScriptEvent(sender: "latest", environment: ["INFO": "final 'quoted' = value"]))
    try Data().write(to: release)
    for _ in 0..<100 {
        if script.output.text == "latest:final 'quoted' = value" { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(script.output.text == "latest:final 'quoted' = value")
    #expect(script.error == nil)
    #expect(try String(contentsOf: log, encoding: .utf8) == """
        begin:startup:initial
        end:startup:initial
        begin:latest:final 'quoted' = value
        end:latest:final 'quoted' = value

        """)
}

@Test @MainActor func startingAScriptAgainStopsItsPreviousCommand() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let started = directory.appending(path: "started")
    let release = directory.appending(path: "release")
    let completed = directory.appending(path: "completed")
    let script = ScriptWidget()
    defer {
        script.stop()
        try? FileManager.default.removeItem(at: directory)
    }
    script.start(command: """
        touch "$STARTED"
        while [ ! -f "$RELEASE" ]; do sleep 0.01; done
        touch "$COMPLETED"
        printf Old
        """, interval: nil, timeout: 4,
        environment: ["STARTED": started.path, "RELEASE": release.path, "COMPLETED": completed.path])
    for _ in 0..<100 {
        if FileManager.default.fileExists(atPath: started.path) { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    try #require(FileManager.default.fileExists(atPath: started.path))
    script.start(command: "printf New", interval: nil)
    for _ in 0..<100 {
        if script.output.text == "New" { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(script.output.text == "New")
    try Data().write(to: release)
    try await Task.sleep(for: .milliseconds(120))
    #expect(script.output.text == "New")
    #expect(!FileManager.default.fileExists(atPath: completed.path))
}

@Test @MainActor func completedActionCannotRestartAReplacedWidget() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let configurationDirectory = directory.appending(path: "config")
    try FileManager.default.createDirectory(at: configurationDirectory, withIntermediateDirectories: true)
    let url = configurationDirectory.appending(path: "config.json")
    let log = directory.appending(path: "commands")
    let started = directory.appending(path: "started")
    let release = directory.appending(path: "release")
    var widget: [String: Any] = [
        "id": "replace", "type": "script", "position": "right", "interval": NSNull(),
        "command": "printf 'old\\n' >> \"$LOG\"; printf Old"
    ]
    var configuration: [String: Any] = [
        "widgets": [widget],
        "environment": ["LOG": log.path, "STARTED": started.path, "RELEASE": release.path]
    ]
    try JSONSerialization.data(withJSONObject: configuration).write(to: url, options: .atomic)
    let store = BarStore(configurationURL: url)
    defer {
        store.stop()
        try? FileManager.default.removeItem(at: directory)
    }
    store.reloadConfiguration()
    let original = try #require(store.scripts["replace"])
    for _ in 0..<100 {
        if original.output.text == "Old" { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    try #require(original.output.text == "Old")
    let originalWidget = try #require(store.configuration?.widgets.first)
    let action = store.runAction("touch \"$STARTED\"; while [ ! -f \"$RELEASE\" ]; do sleep 0.01; done", widget: originalWidget)
    for _ in 0..<100 {
        if FileManager.default.fileExists(atPath: started.path) { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    try #require(FileManager.default.fileExists(atPath: started.path))
    widget["command"] = "printf 'new\\n' >> \"$LOG\"; printf New"
    configuration["widgets"] = [widget]
    try JSONSerialization.data(withJSONObject: configuration).write(to: url, options: .atomic)
    store.reloadConfiguration()
    let replacement = try #require(store.scripts["replace"])
    #expect(replacement !== original)
    for _ in 0..<100 {
        if replacement.output.text == "New" { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    try #require(replacement.output.text == "New")
    try Data().write(to: release)
    await action.value
    try await Task.sleep(for: .milliseconds(120))
    #expect(replacement.output.text == "New")
    #expect(store.actionErrors.isEmpty)
    #expect(try String(contentsOf: log, encoding: .utf8) == "old\nnew\n")
}

@Test @MainActor func styleReloadPreservesErroredScriptOutputAndHistory() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let configurationDirectory = directory.appending(path: "config")
    try FileManager.default.createDirectory(at: configurationDirectory, withIntermediateDirectories: true)
    let url = configurationDirectory.appending(path: "config.json")
    let failure = directory.appending(path: "failure")
    var widget: [String: Any] = [
        "id": "history", "type": "script", "position": "right", "interval": NSNull(),
        "command": """
            if [ -f "$FAILURE" ]; then printf Offline >&2; exit 1; fi
            printf '{"text":"Ready","value":0.3}'
            """,
        "environment": ["FAILURE": failure.path]
    ]
    try JSONSerialization.data(withJSONObject: ["widgets": [widget]]).write(to: url, options: .atomic)
    let store = BarStore(configurationURL: url)
    defer {
        store.stop()
        try? FileManager.default.removeItem(at: directory)
    }
    store.reloadConfiguration()
    let script = try #require(store.scripts["history"])
    for _ in 0..<100 {
        if script.output.text == "Ready" { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    try #require(script.output.text == "Ready")
    try Data().write(to: failure)
    script.refresh(ScriptEvent(sender: "check"))
    for _ in 0..<100 {
        if script.error == "Offline" { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    try #require(script.error == "Offline")
    widget["style"] = ["background": "#112233"]
    try JSONSerialization.data(withJSONObject: ["widgets": [widget]]).write(to: url, options: .atomic)
    store.reloadConfiguration()
    #expect(store.configurationError == nil)
    #expect(store.scripts["history"] === script)
    #expect(script.output.text == "Ready")
    #expect(script.samples == [0.3])
    #expect(script.error == "Offline")
}

@Test @MainActor func scriptEnvironmentCombinesConfigurationWidgetAndEventContext() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "config.json")
    let configuration: [String: Any] = [
        "environment": ["ROOT_ONLY": "root", "SHARED": "root", "NAME": "incorrect", "CONFIG_DIR": "incorrect"],
        "widgets": [[
            "id": "environment", "type": "script", "position": "right", "interval": NSNull(),
            "events": ["custom"],
            "environment": ["SHARED": "widget", "NAME": "also incorrect", "CONFIG_DIR": "also incorrect", "INFO": "initial"],
            "command": "printf '%s|%s|%s|%s|%s|%s' \"$ROOT_ONLY\" \"$SHARED\" \"$NAME\" \"$CONFIG_DIR\" \"$SENDER\" \"$INFO\""
        ]]
    ]
    try JSONSerialization.data(withJSONObject: configuration).write(to: url, options: .atomic)
    let store = BarStore(configurationURL: url)
    defer {
        store.stop()
        try? FileManager.default.removeItem(at: directory)
    }
    store.reloadConfiguration()
    let script = try #require(store.scripts["environment"])
    let startup = "root|widget|environment|\(directory.path)|startup|initial"
    for _ in 0..<100 {
        if script.output.text == startup { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(script.output.text == startup)
    store.refreshScripts(for: "custom", environment: [
        "SHARED": "event", "NAME": "incorrect", "CONFIG_DIR": "incorrect", "SENDER": "incorrect", "INFO": "quoted ' = value"
    ])
    let refreshed = "root|event|environment|\(directory.path)|custom|quoted ' = value"
    for _ in 0..<100 {
        if script.output.text == refreshed { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(script.output.text == refreshed)
    #expect(script.error == nil)
}

@Test(arguments: [false, true]) @MainActor
func widgetActionsRunInOrderAndStoppingCancelsQueuedWork(stop: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let log = directory.appending(path: "actions")
    let started = directory.appending(path: "started")
    let release = directory.appending(path: "release")
    let configuration: [String: Any] = [
        "environment": ["LOG": log.path, "STARTED": started.path, "RELEASE": release.path],
        "widgets": [
            // The first action runs until the test releases it, which other tests can delay for seconds.
            ["id": "volume", "type": "text", "position": "right", "text": "Volume", "timeout": 60],
            ["id": "other", "type": "text", "position": "left", "text": "Other", "timeout": 4]
        ]
    ]
    let store = BarStore()
    store.configuration = try JSONDecoder().decode(Configuration.self, from: JSONSerialization.data(withJSONObject: configuration))
    defer {
        store.stop()
        try? FileManager.default.removeItem(at: directory)
    }
    let widgets = try #require(store.configuration?.widgets)
    let first = store.runAction("""
        printf 'begin:first\n' >> "$LOG"
        touch "$STARTED"
        while [ ! -f "$RELEASE" ]; do sleep 0.01; done
        printf 'end:first\n' >> "$LOG"
        """, widget: widgets[0])
    for _ in 0..<100 {
        if FileManager.default.fileExists(atPath: started.path) { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    try #require(FileManager.default.fileExists(atPath: started.path))
    let second = store.runAction("printf 'second\\n' >> \"$LOG\"", widget: widgets[0])
    let third = store.runAction("printf 'third\\n' >> \"$LOG\"", widget: widgets[0])
    let other = store.runAction("printf 'other\\n' >> \"$LOG\"", widget: widgets[1])
    await other.value
    #expect(try String(contentsOf: log, encoding: .utf8) == "begin:first\nother\n")
    if stop {
        store.stop()
    } else {
        try Data().write(to: release)
    }
    await first.value
    await second.value
    await third.value
    let expected = stop ? "begin:first\nother\n" : "begin:first\nother\nend:first\nsecond\nthird\n"
    #expect(try String(contentsOf: log, encoding: .utf8) == expected)
    #expect(store.actionErrors.isEmpty)
}

@Test @MainActor func triggerDataCannotReplaceLoginShellVariables() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "config.json")
    try Data(#"""
    {"widgets":[{"id":"external","type":"script","position":"right","interval":null,"events":["external"],
      "command":"printf '%s|%s' \"$HOME\" \"$INFO\""}]}
    """#.utf8).write(to: url)
    let store = BarStore(configurationURL: url)
    defer {
        store.stop()
        try? FileManager.default.removeItem(at: directory)
    }
    store.reloadConfiguration()
    let script = try #require(store.scripts["external"])
    let home = try #require(shellEnvironment.withLock { $0["HOME"] })
    for _ in 0..<100 {
        if script.output.text == "\(home)|" { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    _ = try store.handle(RuntimeRequest(action: .trigger, id: "external", environment: ["HOME": "/nowhere", "INFO": "payload"]))
    for _ in 0..<100 {
        if script.output.text == "\(home)|payload" { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(script.output.text == "\(home)|payload")
}

@Test func builtInEventsMatchTheGuideTable() throws {
    let guide = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "docs/create-a-widget.md")
    let lines = try String(contentsOf: guide, encoding: .utf8).components(separatedBy: "\n")
    let header = try #require(lines.firstIndex(of: "| Event | Sent when | `INFO` |"))
    let rows = lines[(header + 2)...].prefix { $0.hasPrefix("| ") }.map { row in
        row.dropFirst(2).dropLast(2).components(separatedBy: " | ")
    }
    try #require(rows.allSatisfy { $0.count == 3 })
    #expect(rows.map { $0[0] } == BuiltInEvent.allCases.map { "`\($0.rawValue)`" })
    #expect(rows.map { $0[1] } == BuiltInEvent.allCases.map(\.trigger))
    #expect(rows.map { $0[2] } == BuiltInEvent.allCases.map(\.info))
}

@Test @MainActor func sendingABuiltInEventRefreshesItsSubscribers() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "config.json")
    try Data(#"""
    {"widgets":[{"id":"woke","type":"script","position":"right","interval":null,"events":["wake"],
      "command":"printf '%s:%s' \"$SENDER\" \"${INFO:-none}\""}]}
    """#.utf8).write(to: url)
    let store = BarStore(configurationURL: url)
    defer {
        store.stop()
        try? FileManager.default.removeItem(at: directory)
    }
    store.reloadConfiguration()
    let script = try #require(store.scripts["woke"])
    for _ in 0..<100 {
        if script.output.text == "startup:none" { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(script.output.text == "startup:none")
    store.send(.wake)
    for _ in 0..<100 {
        if script.output.text == "wake:none" { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(script.output.text == "wake:none")
}

@Test @MainActor func sendingABuiltInEventPassesItsVariablesToTheScript() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "config.json")
    try Data(#"""
    {"widgets":[{"id":"front","type":"script","position":"right","interval":null,"events":["frontApp"],
      "command":"printf '%s:%s' \"$SENDER\" \"${INFO:-none}\""}]}
    """#.utf8).write(to: url)
    let store = BarStore(configurationURL: url)
    defer {
        store.stop()
        try? FileManager.default.removeItem(at: directory)
    }
    store.reloadConfiguration()
    let script = try #require(store.scripts["front"])
    for _ in 0..<100 {
        if script.output.text == "startup:none" { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(script.output.text == "startup:none")
    store.send(.frontApp, ["INFO": "Safari"])
    for _ in 0..<100 {
        if script.output.text == "frontApp:Safari" { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(script.output.text == "frontApp:Safari")
}
