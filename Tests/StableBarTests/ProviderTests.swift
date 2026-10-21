import Darwin
import Foundation
import Testing
@testable import StableBar

private func provider(_ command: String, type: String = "stream", interval: Double = 0.05) throws -> ProviderConfiguration {
    try JSONDecoder().decode(ProviderConfiguration.self, from: JSONSerialization.data(withJSONObject: [
        "type": type, "command": command, "interval": interval
    ]))
}

@Test func streamingCommandsReadSplitLinesAndTheFinalUnterminatedLine() async throws {
    var texts: [String] = []
    for try await result in commandLines("/bin/zsh", arguments: ["-c", """
        printf '{"text":"fir'; sleep 0.05; printf 'st"}\\n'
        sleep 0.05; printf '{"text":"last"}'
        """]) {
        texts.append(try ScriptOutput.read(result.stdout).text)
    }
    #expect(texts == ["first", "last"])
}

@Test func streamingCommandsRejectOversizedUnterminatedLines() async {
    do {
        for try await _ in commandLines("/bin/zsh", arguments: ["-c", "head -c 1048577 /dev/zero; sleep 30"]) {}
        Issue.record("The oversized line was accepted.")
    } catch {
        #expect(error.localizedDescription == "Provider line exceeded 1 MiB.")
    }
}

@Test func streamingWarningsKeepOnlyABoundedTail() async throws {
    var last: CommandResult?
    for try await result in commandLines("/bin/zsh", arguments: ["-c", "head -c 1048577 /dev/zero >&2; sleep 0.05; printf '{\"text\":\"ok\"}\\n'"]) {
        last = result
    }
    #expect(try ScriptOutput.read(#require(last).stdout).text == "ok")
    #expect(last?.stderr.count == 16_384)
}

@Test func exitingStreamStopsChildrenHoldingItsPipes() async throws {
    let marker = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: marker) }
    var last: CommandResult?
    let started = ContinuousClock.now
    for try await result in commandLines("/bin/sh", arguments: ["-c", """
        sleep 30 &
        printf '%s' $! > "$MARKER"
        printf '{"text":"done"}\\n'
        """], environment: ["MARKER": marker.path]) {
        last = result
    }
    #expect(started.duration(to: .now) < .seconds(5))
    #expect(try ScriptOutput.read(#require(last).stdout).text == "done")
    let child = try #require(Int32(String(contentsOf: marker, encoding: .utf8)))
    defer { kill(child, SIGKILL) }
    for _ in 0..<100 {
        if kill(child, 0) == -1 { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(kill(child, 0) == -1)
}

@Test @MainActor func malformedStreamingOutputCancelsItsProcessAndKeepsLastGoodValue() async throws {
    let marker = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let script = ScriptWidget()
    defer {
        script.stop()
        try? FileManager.default.removeItem(at: marker)
    }
    script.start(provider: try provider("""
        printf '%s' $$ > "$MARKER"
        printf '{"text":"good","value":0.3}\\n'
        sleep 0.05
        printf 'broken JSON\\n'
        sleep 30
        """), environment: ["MARKER": marker.path])
    for _ in 0..<100 {
        if script.error != nil { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    try #require(script.error != nil)
    #expect(script.output.text == "good")
    #expect(script.samples == [0.3])
    #expect(script.diagnostics.lastStdout == "broken JSON")
    let process = try #require(Int32(String(contentsOf: marker, encoding: .utf8)))
    defer { kill(process, SIGKILL) }
    for _ in 0..<100 {
        if kill(process, 0) == -1 { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(kill(process, 0) == -1)
}

@Test @MainActor func streamExitRestartsWithBackoffWithoutDiscardingOutput() async throws {
    let script = ScriptWidget()
    defer { script.stop() }
    script.start(provider: try provider("printf '{\"text\":\"ready\"}\\n'"))
    for _ in 0..<150 {
        if script.diagnostics.failureCount == 2 { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(script.output.text == "ready")
    #expect(script.diagnostics.failureCount == 2)
    #expect(script.diagnostics.executionCount == 2)
    #expect(script.diagnostics.restartCount == 1)
    #expect(script.diagnostics.nextDelay == 2)
    #expect(script.error == "Streaming provider exited.")
}

@Test @MainActor func suspendedProviderStopsItsProcessAndResumesWithHistory() async throws {
    let marker = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let script = ScriptWidget()
    defer {
        script.stop()
        try? FileManager.default.removeItem(at: marker)
    }
    script.start(provider: try provider("""
        printf '%s' $$ > "$MARKER"
        printf '{"text":"%s","value":0.4}\\n' "$SENDER"
        sleep 30
        """), environment: ["MARKER": marker.path])
    for _ in 0..<100 {
        if script.output.text == "startup" { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    try #require(script.output.text == "startup")
    let process = try #require(Int32(String(contentsOf: marker, encoding: .utf8)))
    script.suspend()
    #expect(script.diagnostics.suspended)
    #expect(!script.diagnostics.running)
    script.refresh(ScriptEvent(sender: "ignored"))
    try await Task.sleep(for: .milliseconds(100))
    #expect(kill(process, 0) == -1)
    #expect(script.output.text == "startup")
    #expect(script.samples == [0.4])
    script.resume()
    for _ in 0..<100 {
        if script.output.text == "resume" { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(script.output.text == "resume")
    #expect(script.samples == [0.4, 0.4])
    #expect(!script.diagnostics.suspended)
}

@Test @MainActor func failedPollingProviderBacksOffAndManualSuccessResetsFailures() async throws {
    let script = ScriptWidget()
    defer { script.stop() }
    script.start(provider: try provider("""
        if [ "$SENDER" = manual ]; then printf good; else printf offline >&2; exit 1; fi
        """, type: "command"))
    for _ in 0..<100 {
        if script.error != nil { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(script.error == "offline")
    #expect(script.diagnostics.lastStderr == "offline")
    #expect(script.diagnostics.nextDelay == 1)
    script.refresh(ScriptEvent(sender: "manual"))
    for _ in 0..<100 {
        // Output arrives before the run's finished update resets retry diagnostics.
        if script.output.text == "good" && script.diagnostics.nextDelay != nil { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(script.output.text == "good")
    #expect(script.error == nil)
    #expect(script.diagnostics.consecutiveFailures == 0)
    #expect(script.diagnostics.failureCount == 1)
    #expect(script.diagnostics.nextDelay == 0.05)
}

@Test func retryDelayDoublesAndCapsAtFiveMinutes() {
    #expect((1...4).map { providerRetryDelay(interval: 5, failures: $0) } == [5, 10, 20, 40])
    #expect(providerRetryDelay(interval: 0.01, failures: 1) == 1)
    #expect(providerRetryDelay(interval: 5, failures: 100) == 300)
    #expect(providerRetryDelay(interval: 600, failures: 100) == 600)
}

@Test func nativeCountersMeasureDeltasAndDiscardResetNetworkCounters() {
    let before = NetworkCounters(received: 1_000, sent: 2_000)
    let rates = NetworkCounters(received: 3_000, sent: 8_000).rates(since: before, elapsed: 2)
    #expect(rates.download == 1_000)
    #expect(rates.upload == 3_000)
    let reset = NetworkCounters(received: 50, sent: 70).rates(since: before, elapsed: 2)
    #expect(reset.download == 0)
    #expect(reset.upload == 0)
    let cpu = CPUTicks(user: 120, system: 120, idle: 150, nice: 110)
    #expect(cpu.usage(since: CPUTicks(user: 100, system: 100, idle: 100, nice: 100)) == 0.5)
    #expect(cpu.usage(since: cpu) == 0)
    #expect(CPUTicks(user: 4, system: 0, idle: 5, nice: 0)
        .usage(since: CPUTicks(user: UInt32.max, system: 0, idle: 0, nice: 0)) == 0.5)
}

@Test func networkRecordsSkipShortAddressMessagesAndDownInterfaces() {
    var interface = if_msghdr2()
    interface.ifm_msglen = UInt16(MemoryLayout<if_msghdr2>.size)
    interface.ifm_type = UInt8(RTM_IFINFO2)
    interface.ifm_flags = IFF_UP
    interface.ifm_index = 3
    interface.ifm_data.ifi_ibytes = 4_294_967_300
    interface.ifm_data.ifi_obytes = 2_000
    var data = withUnsafeBytes(of: &interface) { Data($0) }
    interface.ifm_index = 4
    interface.ifm_flags = 0
    data.append(withUnsafeBytes(of: &interface) { Data($0) })
    var address = ifa_msghdr()
    address.ifam_msglen = UInt16(MemoryLayout<ifa_msghdr>.size)
    address.ifam_type = UInt8(RTM_NEWADDR)
    data.append(withUnsafeBytes(of: &address) { Data($0) })
    let counters = networkCounters(data)
    #expect(counters.count == 1)
    #expect(counters[3]?.received == 4_294_967_300)
    #expect(counters[3]?.sent == 2_000)
}

@Test func meetingPhasesChangeAtTheirLeadTimesAndUpdatesLandOnTheBoundaries() {
    let start = Date(timeIntervalSinceReferenceDate: 3_600)
    let end = start.addingTimeInterval(1_800)
    let countdown = { (offset: Double) in meetingCountdown(start: start, end: end, at: start.addingTimeInterval(offset), soon: 15, now: 5) }
    #expect([-901, -900, -301, -300, -1, 0, 1_799].map { countdown($0).phase } == ["later", "soon", "soon", "now", "now", "live", "live"])
    #expect(countdown(-620).minutes == 11)
    #expect(countdown(-620).delay == 20)
    #expect(countdown(-600).delay == 60)
    #expect(countdown(1_790).minutes == 1)
    #expect(countdown(1_790).delay == 10)
}

@Test func meetingCountdownShrinksBeforeTheStartAndDuringTheMeeting() {
    let start = Date(timeIntervalSinceReferenceDate: 3_600)
    let end = start.addingTimeInterval(1_800)
    let countdown = { (offset: Double) in meetingCountdown(start: start, end: end, at: start.addingTimeInterval(offset), soon: 15, now: 5) }
    #expect(countdown(-3_600).remaining == 1)
    #expect(countdown(-3_600).target == 1)
    #expect(countdown(-600).remaining == 600.0 / 900)
    #expect(countdown(-600).target == 540.0 / 900)
    #expect(countdown(-30).target == 0)
    #expect(countdown(0).remaining == 1)
    #expect(countdown(900).remaining == 0.5)
    #expect(countdown(900).target == 840.0 / 1_800)
    #expect(countdown(1_780).target == 0)
}

@Test func meetingLinksKeepOnlyMeetZoomAndTeamsURLsAndStopAtShellSyntax() {
    #expect(meetingLink(["Room 4", "Join: https://us02web.zoom.us/j/123456789?pwd=abc.DEF"]) == "https://us02web.zoom.us/j/123456789?pwd=abc.DEF")
    #expect(meetingLink(["https://meet.google.com/abc-defg-hij?authuser=0", "https://zoom.us/j/1"]) == "https://meet.google.com/abc-defg-hij?authuser=0")
    #expect(meetingLink(["<https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=%7b%22Tid%22%7d>"])
        == "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=%7b%22Tid%22%7d")
    #expect(meetingLink(["https://example.com/j/1 https://evilzoom.us/j/1 https://zoom.us.example.com/j/1",
                         "https://meet.google.com@example.com/abc", "http://meet.google.com/abc"]) == nil)
    #expect(meetingLink(["https://meet.google.com/abc-defg-hij';touch /tmp/x;'"]) == "https://meet.google.com/abc-defg-hij")
    #expect(meetingLink(["https://zoom.us/j/1$(reboot)"]) == "https://zoom.us/j/1")
    #expect(meetingLink(["https://teams.live.com/meet/9`id`;ls|cat>x\"y\nhttps://zoom.us/j/2"]) == "https://teams.live.com/meet/9")
}

@Test @MainActor func sharedProvidersRunOncePerEventAndSurviveIndependentWidgetEdits() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "config.json")
    let log = directory.appending(path: "runs")
    var widgets: [[String: Any]] = [
        ["id": "first", "type": "provider", "provider": "shared", "position": "left"],
        ["id": "second", "type": "provider", "provider": "shared", "position": "right", "events": ["changed"]]
    ]
    var document: [String: Any] = ["widgets": widgets, "providers": ["shared": [
        "type": "command", "interval": 600, "events": ["changed"],
        "environment": ["LOG": log.path],
        "command": "printf '%s\\n' \"$SENDER\" >> \"$LOG\"; printf '%s' \"$SENDER\""
    ]]]
    try JSONSerialization.data(withJSONObject: document).write(to: url, options: .atomic)
    let store = BarStore(configurationURL: url)
    defer {
        store.stop()
        try? FileManager.default.removeItem(at: directory)
    }
    store.reloadConfiguration()
    let shared = try #require(store.scripts["first"])
    #expect(store.scripts["second"] === shared)
    for _ in 0..<100 {
        if shared.output.text == "startup" { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    try #require(shared.output.text == "startup")
    store.refreshScripts(for: "changed")
    for _ in 0..<100 {
        if shared.output.text == "changed" { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(try String(contentsOf: log, encoding: .utf8) == "startup\nchanged\n")
    widgets[0]["style"] = ["background": "#112233"]
    document["widgets"] = widgets
    try JSONSerialization.data(withJSONObject: document).write(to: url, options: .atomic)
    store.reloadConfiguration()
    #expect(store.scripts["first"] === shared)
    #expect(store.scripts["second"] === shared)
    widgets[0] = ["id": "first", "type": "script", "position": "left", "command": "printf independent", "interval": NSNull()]
    document["widgets"] = widgets
    try JSONSerialization.data(withJSONObject: document).write(to: url, options: .atomic)
    store.reloadConfiguration()
    let independent = try #require(store.scripts["first"])
    #expect(independent !== shared)
    #expect(store.scripts["second"] === shared)
    for _ in 0..<100 {
        if independent.output.text == "independent" { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(independent.output.text == "independent")
    #expect(shared.output.text == "changed")
    #expect(try String(contentsOf: log, encoding: .utf8) == "startup\nchanged\n")
}

@Test @MainActor func sharedVisibilityAndSleepSuspendUntilAConsumerIsVisible() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "config.json")
    let document: [String: Any] = ["widgets": [
        ["id": "first", "type": "provider", "provider": "shared", "position": "left"],
        ["id": "second", "type": "provider", "provider": "shared", "position": "right"]
    ], "providers": ["shared": ["type": "command", "command": "printf '%s' \"$SENDER\"", "interval": 600, "whenVisible": true]]]
    try JSONSerialization.data(withJSONObject: document).write(to: url)
    let store = BarStore(configurationURL: url)
    defer {
        store.stop()
        try? FileManager.default.removeItem(at: directory)
    }
    store.reloadConfiguration()
    let shared = try #require(store.scripts["first"])
    #expect(shared.diagnostics.suspended)
    store.setInspectorOpen(true)
    #expect(shared.diagnostics.suspended)
    let first = try #require(store.configuration?.widgets.first)
    #expect(store.widgetStatus(for: first) == .paused)
    #expect(shared.diagnostics.suspended)
    store.setInspectedWidget("first")
    #expect(!shared.diagnostics.suspended)
    store.setInspectedWidget(nil)
    #expect(shared.diagnostics.suspended)
    store.setInspectedWidget("first")
    store.setInspectorOpen(false)
    #expect(shared.diagnostics.suspended)
    store.setInspectorOpen(true)
    #expect(shared.diagnostics.suspended)
    store.setVisibleWidgets(ids: ["second"], displayID: 1)
    for _ in 0..<100 {
        if shared.output.text == "resume" { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(shared.output.text == "resume")
    #expect(!shared.diagnostics.suspended)
    store.setVisibleWidgets(ids: ["first"], displayID: 2)
    store.setVisibleWidgets(ids: [], displayID: 1)
    #expect(!shared.diagnostics.suspended)
    store.setSleeping(true)
    #expect(shared.diagnostics.suspended)
    store.setSleeping(false)
    #expect(!shared.diagnostics.suspended)
    store.retainDisplays([1])
    #expect(shared.diagnostics.suspended)
    #expect(shared.output.text == "resume")
}

@Test @MainActor func providerLifecycleSurvivesRepeatedSleepReloadAndConsumerChurn() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "config.json")
    let log = directory.appending(path: "processes")
    let first: [String: Any] = ["id": "first", "type": "provider", "provider": "shared", "position": "left"]
    var document: [String: Any] = ["widgets": [first], "providers": ["shared": [
        "type": "stream", "whenVisible": true, "environment": ["LOG": log.path],
        "command": """
            printf '%s\\n' $$ >> "$LOG"
            printf '{"text":"%s","value":0.5}\\n' $$
            sleep 30
            """
    ]]]
    try JSONSerialization.data(withJSONObject: document).write(to: url)
    let store = BarStore(configurationURL: url)
    defer {
        store.stop()
        try? FileManager.default.removeItem(at: directory)
    }
    store.reloadConfiguration()
    let shared = try #require(store.scripts["first"])
    var previousPID: Int32 = 0
    for round in 0..<12 {
        store.setVisibleWidgets(ids: ["first"], displayID: 1)
        store.setSleeping(false)
        for _ in 0..<100 {
            if let pid = Int32(shared.output.text), pid != previousPID, shared.diagnostics.running { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try #require(Int32(shared.output.text))
        #expect(pid != previousPID)
        #expect(shared.diagnostics.running)
        previousPID = pid
        store.setSleeping(true)
        for _ in 0..<100 {
            if kill(pid, 0) == -1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(kill(pid, 0) == -1)
        #expect(shared.diagnostics.suspended)
        var widgets = [first]
        for consumer in 0..<(round % 3) {
            widgets.append(["id": "consumer-\(consumer)", "type": "provider", "provider": "shared", "position": "right"])
        }
        document["widgets"] = widgets
        try JSONSerialization.data(withJSONObject: document).write(to: url, options: .atomic)
        store.reloadConfiguration()
        #expect(store.configurationError == nil)
        #expect(store.scripts.count == widgets.count)
        #expect(store.scripts.values.allSatisfy { $0 === shared })
        #expect(shared.diagnostics.suspended)
    }
    #expect(shared.samples.count == 12)
    #expect(shared.diagnostics.executionCount == 12)
    #expect(shared.diagnostics.failureCount == 0)
    document["widgets"] = [[String: Any]]()
    try JSONSerialization.data(withJSONObject: document).write(to: url, options: .atomic)
    store.reloadConfiguration()
    #expect(store.scripts.isEmpty)
    #expect(!shared.diagnostics.running)
    #expect(!shared.diagnostics.suspended)
    let processes = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map { Int32($0)! }
    #expect(processes.count == 12)
    #expect(processes.allSatisfy { kill($0, 0) == -1 })
}

@Test func nativeWidgetTypesShareABuiltInProviderUnlessOneIsDefined() throws {
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data(#"""
    {"providers":{"system":{"type":"system","interval":2}},
     "widgets":[{"id":"power","type":"battery","position":"right"},{"id":"charge","type":"provider","provider":"battery","position":"right"},
                {"id":"cpu","type":"system","position":"right"}]}
    """#.utf8))
    #expect(configuration.widgets.map(\.content) == [.provider("battery"), .provider("battery"), .provider("system")])
    #expect(configuration.providers["battery"] == ProviderConfiguration(type: "battery"))
    #expect(configuration.providers["system"]?.interval == 2)
    for widget in [#"{"id":"x","type":"command","position":"right"}"#, #"{"id":"x","type":"provider","provider":"stream","position":"right"}"#] {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(Configuration.self, from: Data("{\"widgets\":[\(widget)]}".utf8))
        }
    }
}
