import Foundation
import Testing
@testable import StableBar

private struct WorkspaceCheckFixture: Sendable {
    let directory: URL
    var configuration: URL { directory.appending(path: "stablebar config.json") }
    var yabairc: URL { directory.appending(path: ".yabairc") }
    var calls: URL { directory.appending(path: "calls") }
    var action: String { "/Applications/StableBar.app/Contents/MacOS/StableBar --config '\(configuration.path)' --trigger yabai" }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "workspace-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func close() { try? FileManager.default.removeItem(at: directory) }

    func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func tool(_ name: String, _ body: String) throws {
        let url = directory.appending(path: name)
        try write("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"${0%/*}/calls\"\n" + body, to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    func yabai(registered: [String]? = nil) throws {
        let signals = (registered ?? YabaiSetupSignals.events).map { ["event": $0, "action": action] }
        try JSONSerialization.data(withJSONObject: signals).write(to: directory.appending(path: "signals.json"))
        try tool("yabai", """
        if [ "$2" = signal ]; then /bin/cat "${0%/*}/signals.json"; else echo '[]'; fi
        """)
    }

    func checker(timeout: Double = 60, running: Bool = true) -> SetupWorkspaceChecker {
        let environment = ["PATH": directory.path, "HOME": directory.path, "XDG_CONFIG_HOME": ""]
        return SetupWorkspaceChecker(configurationURL: configuration, environment: { environment }, executable: { source, path in
            // No app-bundle fallback: these tests can only ever run their scratch tools.
            let url = URL(filePath: path).appending(path: source == .omniwm ? "omniwmctl" : "yabai")
            return FileManager.default.isExecutableFile(atPath: url.path) ? url.path : nil
        }, isRunning: { _ in running }, timeout: timeout)
    }

    var log: [String] { ((try? String(contentsOf: calls, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
    var script: String { YabaiSetupSignals.script() }
}

@Suite struct SetupWorkspaceConnectionTests {
    @Test func yabaiChecksSavedAndLoadedSignalsUsingTheWidgetSnapshot() async throws {
        let fixture = try WorkspaceCheckFixture()
        defer { fixture.close() }
        try fixture.yabai()
        try fixture.write(fixture.script, to: fixture.yabairc)
        let before = try Data(contentsOf: fixture.yabairc)
        #expect(await fixture.checker().check(.yabai) == .connected)
        #expect(Set(fixture.log) == ["-m query --spaces", "-m query --windows", "-m query --displays", "-m signal --list"])
        #expect(try Data(contentsOf: fixture.yabairc) == before)
    }

    @Test(arguments: ["missing", "partial", "commented", "differentConfig", "echo"])
    func yabaiNamesMissingSignalsWithoutChangingTheConfig(kind: String) async throws {
        let fixture = try WorkspaceCheckFixture()
        defer { fixture.close() }
        try fixture.yabai(registered: [])
        let script: String
        switch kind {
        case "partial": script = fixture.script.replacingOccurrences(of: "space_destroyed", with: "not_an_event")
        case "commented": script = fixture.script.split(separator: "\n").map { "# " + $0 }.joined(separator: "\n")
        case "differentConfig":
            let action = fixture.action.replacingOccurrences(of: "stablebar config.json", with: "another config.json")
            script = YabaiSetupSignals.events.map {
                "yabai -m signal --add event=\($0) action=\"\(action)\""
            }.joined(separator: "\n")
        case "echo": script = fixture.script.replacingOccurrences(of: "action='", with: "action='echo ")
        default: script = "#!/bin/sh\n# No StableBar signals\n"
        }
        try fixture.write(script, to: fixture.yabairc)
        #expect(await fixture.checker().check(.yabai) == .signalsMissing(configuration: fixture.yabairc.path))
        #expect(try String(contentsOf: fixture.yabairc, encoding: .utf8) == script)
    }

    @Test func yabaiWithNoConfigNamesTheLegacyDotfile() async throws {
        let fixture = try WorkspaceCheckFixture()
        defer { fixture.close() }
        try fixture.yabai(registered: [])
        #expect(await fixture.checker().check(.yabai) == .signalsMissing(configuration: fixture.yabairc.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.yabairc.path))
    }

    @Test func savedSignalsStillNeedToBeLoadedByYabai() async throws {
        let fixture = try WorkspaceCheckFixture()
        defer { fixture.close() }
        try fixture.yabai(registered: Array(YabaiSetupSignals.events.dropLast()))
        try fixture.write(fixture.script, to: fixture.yabairc)
        #expect(await fixture.checker().check(.yabai) == .reloadYabai(configuration: fixture.yabairc.path))
    }

    @Test func aSourcedConfigIsUnverifiedAndNeverExecuted() async throws {
        let fixture = try WorkspaceCheckFixture()
        defer { fixture.close() }
        try fixture.yabai(registered: [])
        try fixture.write(". ./other-signals.sh\ntouch '\(fixture.directory.appending(path: "executed").path)'", to: fixture.yabairc)
        let result = await fixture.checker().check(.yabai)
        guard case .couldntCheck = result else { Issue.record("Expected an unverified config, got \(result)"); return }
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appending(path: "executed").path))
    }

    @Test(arguments: [Data([0xff]), Data(repeating: 0x20, count: 262_145)])
    func anUnreadableConfigStaysUnverified(data: Data) async throws {
        let fixture = try WorkspaceCheckFixture()
        defer { fixture.close() }
        try fixture.yabai()
        try data.write(to: fixture.yabairc)
        guard case let .couldntCheck(reason) = await fixture.checker().check(.yabai) else {
            Issue.record("Expected couldn't check"); return
        }
        #expect(reason.contains("Couldn’t read"))
        #expect(try Data(contentsOf: fixture.yabairc) == data)
    }

    @Test func yabaiUsesItsOwnConfigPrecedence() throws {
        let fixture = try WorkspaceCheckFixture()
        defer { fixture.close() }
        let xdg = fixture.directory.appending(path: "xdg")
        let xdgConfig = xdg.appending(path: "yabai/yabairc")
        let standard = fixture.directory.appending(path: ".config/yabai/yabairc")
        #expect(try YabaiSetupSignals.configuration(home: fixture.directory, xdg: xdg.path) == nil)
        try fixture.write("", to: fixture.yabairc)
        #expect(try YabaiSetupSignals.configuration(home: fixture.directory, xdg: xdg.path) == fixture.yabairc)
        try fixture.write("", to: standard)
        #expect(try YabaiSetupSignals.configuration(home: fixture.directory, xdg: xdg.path) == standard)
        try fixture.write("", to: xdgConfig)
        #expect(try YabaiSetupSignals.configuration(home: fixture.directory, xdg: xdg.path) == xdgConfig)
        #expect(try YabaiSetupSignals.configuration(home: fixture.directory, xdg: "") == standard)
    }

    @Test func anInactiveYabaiConfigCannotMakeTheCheckPass() async throws {
        let fixture = try WorkspaceCheckFixture()
        defer { fixture.close() }
        try fixture.yabai(registered: [])
        try fixture.write(fixture.script, to: fixture.yabairc)
        let used = fixture.directory.appending(path: ".config/yabai/yabairc")
        try fixture.write("# This config wins over ~/.yabairc", to: used)
        #expect(await fixture.checker().check(.yabai) == .signalsMissing(configuration: used.path))
    }

    @Test(arguments: [false, true])
    func yabaiFollowsConfigSymlinksLikeItsOwnFileLookup(directory: Bool) async throws {
        let fixture = try WorkspaceCheckFixture()
        defer { fixture.close() }
        try fixture.yabai()
        try fixture.write(fixture.script, to: fixture.yabairc)
        let standard = fixture.directory.appending(path: ".config/yabai/yabairc")
        let target = fixture.directory.appending(path: "linked-config")
        if directory { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true) }
        else { try fixture.write(fixture.script, to: target) }
        try FileManager.default.createDirectory(at: standard.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: standard, withDestinationURL: target)
        #expect(try YabaiSetupSignals.configuration(home: fixture.directory, xdg: nil) == (directory ? fixture.yabairc : standard))
        #expect(await fixture.checker().check(.yabai) == .connected)
    }

    @Test func explicitSignalsAndTheGuidesLoopAreRecognized() throws {
        let fixture = try WorkspaceCheckFixture()
        defer { fixture.close() }
        let explicit = YabaiSetupSignals.events.map {
            "yabai -m signal --add event=\($0) action=\"\(fixture.action)\" # refresh"
        }.joined(separator: "\n")
        #expect(YabaiSetupSignals.savedEvents(in: explicit, for: fixture.configuration) == Set(YabaiSetupSignals.events))
        #expect(YabaiSetupSignals.savedEvents(in: fixture.script, for: fixture.configuration) == Set(YabaiSetupSignals.events))
    }

    @Test func copiedSignalsBroadcastToDefaultAndCustomStableBarConfigurations() throws {
        let fixture = try WorkspaceCheckFixture()
        defer { fixture.close() }
        #expect(!fixture.script.contains("--config"))
        for configuration in [URL(filePath: "/Users/me/.config/stablebar/config.json"), fixture.configuration] {
            #expect(YabaiSetupSignals.savedEvents(in: fixture.script, for: configuration) == Set(YabaiSetupSignals.events))
        }
    }

    @Test(arguments: [false, true])
    func targetedSignalsResolveSymlinksOnBothConfigurationPaths(actionUsesLink: Bool) throws {
        let fixture = try WorkspaceCheckFixture()
        defer { fixture.close() }
        try fixture.write("{}", to: fixture.configuration)
        let link = fixture.directory.appending(path: "linked-config.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.configuration)
        let actionPath = actionUsesLink ? link : fixture.configuration
        let checkedPath = actionUsesLink ? fixture.configuration : link
        let action = "stablebar --config '\(actionPath.path)' --trigger yabai"
        let signal = YabaiSetupSignals.Signal(event: "space_changed", action: action)
        #expect(signal.isRefresh(for: checkedPath))
        let script = YabaiSetupSignals.events.map {
            "yabai -m signal --add event=\($0) action=\"\(action)\""
        }.joined(separator: "\n")
        #expect(YabaiSetupSignals.savedEvents(in: script, for: checkedPath) == Set(YabaiSetupSignals.events))
    }

    @Test(arguments: ["app=Finder", "title!=Private", "active=yes", "action='stablebar --query --trigger yabai'",
                      "action='stablebar --trigger yabai --config /tmp/config.json'"])
    func filteredOrInvalidSavedCommandsAreNotRefreshSignals(option: String) throws {
        let fixture = try WorkspaceCheckFixture()
        defer { fixture.close() }
        let action = option.hasPrefix("action=") ? option : "action=\"\(fixture.action)\" \(option)"
        let script = YabaiSetupSignals.events.map { "yabai -m signal --add event=\($0) \(action)" }.joined(separator: "\n")
        #expect(YabaiSetupSignals.savedEvents(in: script, for: fixture.configuration).isEmpty)
    }

    @Test(arguments: [false, true])
    func loadedSignalsFromAnUnrecognizedConfigDoNotSuggestAddingDuplicates(hasDefaultConfig: Bool) async throws {
        let fixture = try WorkspaceCheckFixture()
        defer { fixture.close() }
        try fixture.yabai()
        if hasDefaultConfig { try fixture.write("# Signals were loaded elsewhere", to: fixture.yabairc) }
        guard case let .couldntCheck(reason) = await fixture.checker().check(.yabai) else {
            Issue.record("Expected an unverified config"); return
        }
        #expect(reason.contains("signals are loaded"))
    }

    @Test func copiedSignalsMatchTheGuideExactly() throws {
        let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let guide = try String(contentsOf: repository.appending(path: "docs/widgets.md"), encoding: .utf8)
        let start = try #require(guide.range(of: "for event in ")?.lowerBound)
        let end = try #require(guide.range(of: "\n```", range: start..<guide.endIndex)?.lowerBound)
        #expect(YabaiSetupSignals.script() == String(guide[start..<end]))
    }

    @Test func copiedSignalsQuoteTheAppPath() async throws {
        let fixture = try WorkspaceCheckFixture()
        defer { fixture.close() }
        let app = "/Applications/Steve's StableBar.app/Contents/MacOS/StableBar"
        let script = YabaiSetupSignals.script(executable: app)
        #expect(YabaiSetupSignals.savedEvents(in: script, for: fixture.configuration) == Set(YabaiSetupSignals.events))
        let file = fixture.directory.appending(path: "signals.sh")
        try fixture.write(script, to: file)
        try fixture.tool("yabai", "exit 0")
        // Runs only the fake client. It records arguments and never executes the action passed to it.
        _ = try await runCommand("/bin/sh", arguments: [file.path], timeout: 60,
                                 environment: ["PATH": fixture.directory.path])
        #expect(fixture.log.count == YabaiSetupSignals.events.count)
        let quotedApp = "'/Applications/Steve'\\''s StableBar.app/Contents/MacOS/StableBar'"
        for event in YabaiSetupSignals.events {
            #expect(fixture.log.contains("-m signal --add label=stablebar-\(event) event=\(event) action=\(quotedApp) --trigger yabai"))
        }
    }

    @Test(arguments: [false, true]) @MainActor
    func copiedSignalsUseAPermanentAppPath(inApplications: Bool) throws {
        let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"clock","type":"clock","position":"right"}]}"#)
        defer { fixture.close() }
        let store = BarStore(configurationURL: fixture.url, themesDirectory: fixture.themes)
        defer { store.stop() }
        var loader = ConfigurationLoader()
        let configuration = try loader.load(fixture.url)
        store.showWithoutRunning(configuration, loader: loader, context: ConfigurationContext(), setup: ScreenSetup([]))
        var system = SetupSystem()
        system.previewsOnTheBar = false
        system.workspaceSource = { $0 ?? .spaces }
        system.isInApplications = { inApplications }
        let session = SetupSession(store: store, system: system)
        let executable = inApplications ? try #require(Bundle.main.executableURL).path
            : "/Applications/StableBar.app/Contents/MacOS/StableBar"
        #expect(session.yabaiSignalScript == YabaiSetupSignals.script(executable: executable))
        #expect(!session.yabaiSignalScript.contains("--config"))
    }

    @Test(arguments: ["app", "title", "active", "config"])
    func filteredOrMisdirectedRegisteredSignalsAreNotReady(filter: String) async throws {
        let fixture = try WorkspaceCheckFixture()
        defer { fixture.close() }
        try fixture.yabai()
        try fixture.write(fixture.script, to: fixture.yabairc)
        let signals: [[String: Any]] = YabaiSetupSignals.events.map { event in
            var signal: [String: Any] = ["event": event, "action": fixture.action]
            if filter == "active" { signal["active"] = false }
            else if filter == "config" { signal["action"] = "stablebar --config /another/config.json --trigger yabai" }
            else { signal[filter] = "Finder" }
            return signal
        }
        try JSONSerialization.data(withJSONObject: signals).write(to: fixture.directory.appending(path: "signals.json"))
        #expect(await fixture.checker().check(.yabai) == .reloadYabai(configuration: fixture.yabairc.path))
    }

    @Test func omniWMUsesTheWidgetQueriesAndJSONEnvelope() async throws {
        let fixture = try WorkspaceCheckFixture()
        defer { fixture.close() }
        try fixture.tool("omniwmctl", """
        printf '{"ok":true,"result":{"payload":{"%s":[]}}}\n' "$2"
        """)
        #expect(await fixture.checker().check(.omniwm) == .connected)
        #expect(Set(fixture.log) == [
            "query workspaces --fields raw-name,display-name,display,is-visible,is-current --format json",
            "query windows --fields id,window-id,workspace,app,title,is-scratchpad,is-focused --format json"
        ])
    }

    @Test(arguments: [0, 2]) func omniWMTransportFailureNamesEnableIPC(exitStatus: Int) async throws {
        let fixture = try WorkspaceCheckFixture()
        defer { fixture.close() }
        try fixture.tool("omniwmctl", """
        echo '{"ok":false,"code":"transport_failure","message":"No such file or directory"}'
        exit \(exitStatus)
        """)
        #expect(await fixture.checker().check(.omniwm) == .ipcOff)
    }

    @Test(arguments: [false, true])
    func omniWMNotRunningIsUnverifiedWithoutQueryingIPC(toolAvailable: Bool) async throws {
        let fixture = try WorkspaceCheckFixture()
        defer { fixture.close() }
        if toolAvailable {
            try fixture.tool("omniwmctl", "echo '{\"ok\":false,\"code\":\"transport_failure\"}'; exit 2")
        }
        #expect(await fixture.checker(running: false).check(.omniwm)
            == .couldntCheck("OmniWM isn’t running. Open OmniWM, then check again."))
        #expect(fixture.log.isEmpty)
    }

    @Test(arguments: ["echo 'not JSON'", "echo '{\"ok\":false,\"code\":\"invalid_command\"}'; exit 2"])
    func anUnknownOmniWMFailureDoesNotClaimIPCIsOff(body: String) async throws {
        let fixture = try WorkspaceCheckFixture()
        defer { fixture.close() }
        try fixture.tool("omniwmctl", body)
        guard case .couldntCheck = await fixture.checker().check(.omniwm) else {
            Issue.record("Expected couldn't check"); return
        }
    }

    @Test(arguments: [WorkspaceSource.yabai, .omniwm]) func aMissingToolIsUnverified(source: WorkspaceSource) async throws {
        let fixture = try WorkspaceCheckFixture()
        defer { fixture.close() }
        guard case let .couldntCheck(reason) = await fixture.checker().check(source) else {
            Issue.record("Expected couldn't check"); return
        }
        #expect(reason.contains("PATH"))
        #expect(fixture.log.isEmpty)
    }

    // This deadline bounds an external command off the main actor, never main-actor scheduling.
    @Test(arguments: [WorkspaceSource.yabai, .omniwm]) func aTimeoutIsUnverified(source: WorkspaceSource) async throws {
        let fixture = try WorkspaceCheckFixture()
        defer { fixture.close() }
        try fixture.tool(source == .yabai ? "yabai" : "omniwmctl", "exec /bin/sleep 30")
        guard case .couldntCheck = await fixture.checker(timeout: 0.1).check(source) else {
            Issue.record("Expected couldn't check after timeout"); return
        }
    }

    @Test func aTimedOutOmniWMCommandDoesNotTreatPartialOutputAsAnIPCFailure() async throws {
        let fixture = try WorkspaceCheckFixture()
        defer { fixture.close() }
        try fixture.tool("omniwmctl", """
        echo '{"ok":false,"code":"transport_failure"}'
        exec /bin/sleep 30
        """)
        do {
            _ = try await omniwmCommand(fixture.directory.appending(path: "omniwmctl").path,
                                        arguments: ["query", "workspaces"], timeout: 0.1)
            Issue.record("Expected timeout")
        } catch let failure as CommandFailure {
            #expect(failure.timedOut)
        }
    }

    @Test @MainActor func theDeadlineReturnsEvenWhileExecutableLookupIsStuck() async throws {
        let clock = TestClock()
        let lookup = BlockedWorkspaceLookup()
        let checker = SetupWorkspaceChecker(configurationURL: URL(filePath: "/tmp/unused-stablebar-config.json"),
                                            environment: { [:] }, executable: { _, _ in lookup.find() }, clock: clock)
        var result: SetupWorkspaceResult?
        let task = Task { result = await checker.check(.yabai) }
        defer { lookup.release(); task.cancel() }
        try await waitFor { lookup.entered && clock.sleeping == 1 }
        clock.advance(by: .seconds(3))
        try await waitFor { result != nil }
        guard case .couldntCheck? = result else { Issue.record("Expected couldn't check at the deadline"); return }
        #expect(!lookup.returned)
        lookup.release()
        try await waitFor { lookup.returned }
        #expect(clock.sleeping == 0)
    }

    @Test @MainActor func leavingTheStepCancelsAndActivationDoesNothingWhileHidden() async throws {
        let gate = WorkspaceCheckGate()
        let connection = SetupWorkspaceConnection { await gate.check($0) }
        connection.show(.yabai)
        try await waitFor { await gate.calls == 1 }
        connection.checkAgain() // Returning to the app shares the check already running.
        #expect(await gate.calls == 1)
        connection.hide()
        try await waitFor { await gate.cancellations == 1 }
        #expect(connection.source == nil)
        #expect(connection.result == .checking) // The cancelled result must not overwrite this state.
        connection.checkAgain()
        #expect(await gate.calls == 1)
        connection.show(.omniwm)
        try await waitFor { await gate.calls == 2 }
        connection.hide()
        try await waitFor { await gate.cancellations == 2 }
        #expect(await gate.ranOnMainThread == false)
    }

    @Test @MainActor func checksRunOnlyOnAppearanceAndExplicitRetry() async throws {
        let gate = WorkspaceCheckGate()
        await gate.finishImmediately()
        let connection = SetupWorkspaceConnection { await gate.check($0) }
        connection.show(nil)
        #expect(await gate.calls == 0)
        connection.show(.yabai)
        try await waitFor { await MainActor.run { connection.result == .connected } }
        #expect(await gate.calls == 1)
        for _ in 0..<20 { await Task.yield() }
        #expect(await gate.calls == 1)
        connection.checkAgain()
        try await waitFor { await gate.calls == 2 }
        connection.hide()
    }

    @Test(arguments: [SetupWorkspaceResult.connected, .signalsMissing(configuration: "~/.yabairc"),
                      .ipcOff, .couldntCheck("Try again")]) @MainActor
    func recheckingKeepsTheLastResultAndExpandedSignals(result: SetupWorkspaceResult) async throws {
        let gate = WorkspaceCheckGate()
        await gate.finishImmediately(with: result)
        let connection = SetupWorkspaceConnection { await gate.check($0) }
        connection.show(.yabai)
        try await waitFor { connection.result == result && !connection.isChecking }
        connection.showsSignals = true
        await gate.holdChecks()
        connection.checkAgain() // Returning from the editor uses the same re-check as Check Again.
        #expect(connection.isChecking)
        #expect(connection.result == result)
        #expect(connection.showsSignals)
        try await waitFor { await gate.calls == 2 }
        connection.checkAgain()
        #expect(await gate.calls == 2)
        connection.hide()
        try await waitFor { await gate.cancellations == 1 }
        #expect(!connection.isChecking)
        #expect(connection.result == result)
        #expect(connection.showsSignals)
    }

    @Test(arguments: [WorkspaceSource.yabai, .omniwm, .aerospace, .spaces]) @MainActor
    func onlyThePreviewedWorkspacesSourceIsChecked(source: WorkspaceSource) throws {
        let fixture = try ThemeGalleryFixture("""
        {"workspaceSource":"\(source.rawValue)","widgets":[{"id":"workspaces","type":"workspaces","position":"left"}]}
        """)
        defer { fixture.close() }
        let store = BarStore(configurationURL: fixture.url, themesDirectory: fixture.themes)
        defer { store.stop() }
        var loader = ConfigurationLoader()
        let configuration = try loader.load(fixture.url)
        store.showWithoutRunning(configuration, loader: loader, context: ConfigurationContext(), setup: ScreenSetup([]))
        var system = SetupSystem()
        system.previewsOnTheBar = false
        system.workspaceSource = { _ in .omniwm } // Detected advice never replaces the previewed source.
        let session = SetupSession(store: store, system: system)
        #expect(session.workspaceCheckSource == (source == .yabai || source == .omniwm ? source : nil))
        let disabled = try loader.load(fixture.url, data: Data("""
        {"workspaceSource":"\(source.rawValue)","widgets":[{"id":"workspaces","type":"workspaces","position":"left","enabled":false}]}
        """.utf8))
        store.showWithoutRunning(disabled, loader: loader, context: ConfigurationContext(), setup: ScreenSetup([]))
        #expect(session.workspaceCheckSource == nil)
    }

    @Test @MainActor func workspaceAdviceNeverBlocksFinishingSetup() async throws {
        let fixture = try ThemeGalleryFixture(#"{"workspaceSource":"omniwm","widgets":[{"id":"workspaces","type":"workspaces","position":"left"}]}"#)
        defer { fixture.close() }
        let store = BarStore(configurationURL: fixture.url, themesDirectory: fixture.themes)
        defer { store.stop() }
        var loader = ConfigurationLoader()
        let configuration = try loader.load(fixture.url)
        store.showWithoutRunning(configuration, loader: loader, context: ConfigurationContext(), setup: ScreenSetup([]))
        for result in [SetupWorkspaceResult.ipcOff, .signalsMissing(configuration: "~/.yabairc"), .couldntCheck("Not yet") ] {
            var system = SetupSystem()
            system.previewsOnTheBar = false
            system.workspaceSource = { $0 ?? .spaces }
            system.menuBarHides = { true }
            system.isTrusted = { true }
            system.calendarAccess = { .fullAccess }
            system.checkWorkspaces = { _, _ in result }
            let session = SetupSession(store: store, system: system)
            session.workspaceConnection.show(.omniwm)
            #expect(!session.blocksContinue(at: .touches)) // Checking is advice too.
            try await waitFor { await MainActor.run { session.workspaceConnection.result == result } }
            #expect(!session.blocksContinue(at: .tryIt))
            session.workspaceConnection.hide()
        }
    }

    @MainActor private func waitFor(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("The check did not reach the expected state after 200 polls")
    }
}

private actor WorkspaceCheckGate {
    var calls = 0
    var cancellations = 0
    var ranOnMainThread = false
    private var immediate = false
    private var result = SetupWorkspaceResult.connected
    func finishImmediately(with result: SetupWorkspaceResult = .connected) {
        immediate = true
        self.result = result
    }
    func holdChecks() { immediate = false }
    func check(_ source: WorkspaceSource) async -> SetupWorkspaceResult {
        calls += 1
        ranOnMainThread = ranOnMainThread || Thread.isMainThread
        if !immediate {
            do { try await Task.sleep(for: .seconds(300)) }
            catch { cancellations += 1 }
        }
        return result
    }
}

/// A slow filesystem or PATH lookup, released by the test, so its deadline needs no real-time wait.
private final class BlockedWorkspaceLookup: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var state = (entered: false, returned: false)
    var entered: Bool { lock.withLock { state.entered } }
    var returned: Bool { lock.withLock { state.returned } }
    func find() -> String? {
        lock.withLock { state.entered = true }
        gate.wait()
        lock.withLock { state.returned = true }
        return nil
    }
    func release() { gate.signal() }
}
