import Foundation
import Testing
@testable import StableBar

@Test func aLoginShellReadThatTimesOutIsRetried() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let shell = directory.appending(path: "zsh"), started = directory.appending(path: "started")
    // The first read hangs like a profile right after login; the next one answers.
    try Data("""
    #!/bin/sh
    [ -e '\(started.path)' ] || { touch '\(started.path)'; exec /bin/sleep 30; }
    /usr/bin/printf 'PATH=/opt/homebrew/bin:/usr/bin\\0EMPTY=\\0'
    """.utf8).write(to: shell)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shell.path)
    let environment = try await readLoginShellEnvironment(shell: shell.path, timeout: 0.5, retryDelay: 0)
    #expect(environment == ["PATH": "/opt/homebrew/bin:/usr/bin", "EMPTY": ""])
}

@Test func waitingForATaskLeavesItRunningPastTheLimit() async throws {
    let slow = Task {
        try await Task.sleep(for: .milliseconds(500))
        return "done"
    }
    #expect(await !slow.finishes(within: .milliseconds(50)))
    #expect(try await slow.value == "done")
    #expect(await slow.finishes(within: .seconds(5)))
}

@Test @MainActor func aLateLoginShellEnvironmentRerunsScriptsAndReconnectsWorkspaces() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appending(path: "aerospace-fixture"), runs = directory.appending(path: "runs")
    try Data("""
    #!/bin/sh
    [ "$1" = subscribe ] || { echo '[]'; exit 0; }
    printf '%s\\n' '{"_event":"mode-changed","mode":"tailing"}'
    exec /bin/sleep 30
    """.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let command = "echo run >> '\(runs.path)'; wc -l < '\(runs.path)' | tr -d ' '"
    let root = directory.appending(path: "config.json")
    try JSONSerialization.data(withJSONObject: ["widgets": [
        ["id": "s", "type": "script", "position": "left", "command": command, "interval": NSNull()],
        ["id": "spaces", "type": "workspaces", "position": "left"],
    ]]).write(to: root)
    let store = BarStore(configurationURL: root)
    // Until the login shell's environment arrives, AeroSpace isn't on the app's own PATH.
    store.workspaceStore.executablePath = { throw CommandFailure(message: "AeroSpace is not on your login shell's PATH.") }
    store.workspaceStore.reconnectDelay = 30
    defer { store.stop() }
    store.configurationStore.reloadConfiguration()
    let script = try #require(store.widgetScripts.scripts["s"])
    for _ in 0..<200 {
        if script.output.text == "1" && store.workspaceStore.connectionError != nil { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(script.output.text == "1")
    #expect(store.workspaceStore.connectionError == "AeroSpace is not on your login shell's PATH.")

    store.workspaceStore.executablePath = { executable.path }
    store.loginShellEnvironmentLoaded()
    for _ in 0..<200 {
        if script.output.text == "2" && store.workspaceStore.mode == "tailing" { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(script.output.text == "2")
    #expect(store.workspaceStore.mode == "tailing")
    #expect(store.workspaceStore.connectionError == nil)
}
