import CoreAudio
import EventKit
import Foundation
import Observation
import os
import SwiftUI
import Testing
@testable import StableBar

private func scriptOutput(_ json: String) throws -> ScriptOutput {
    try ScriptOutput.read(Data(json.utf8))
}

@Test @MainActor func anUpdateThatRepeatsTheOutputInvalidatesNothing() async throws {
    let script = ScriptWidget()
    let repeated = try scriptOutput(#"{"text":"40%","icon":"cpu","fields":{"load":"low"},"menu":[{"title":"Open"}]}"#)
    try script.accept(repeated)
    var updates = 0
    script.onUpdate = { updates += 1 }
    try await confirmation("Nothing a view reads changes", expectedCount: 0) { changed in
        withObservationTracking { _ = script.output; _ = script.error; _ = script.samples } onChange: { changed() }
        try script.accept(repeated)
    }
    #expect(updates == 0)
    script.error = "Offline"
    try script.accept(repeated)
    #expect(script.error == nil)
    #expect(updates == 1)
    try await confirmation("A changed output invalidates the widget", expectedCount: 1) { changed in
        withObservationTracking { _ = script.output } onChange: { changed() }
        try script.accept(scriptOutput(#"{"text":"41%","icon":"cpu","fields":{"load":"low"},"menu":[{"title":"Open"}]}"#))
    }
    #expect(updates == 2)
}

@Test @MainActor func aRepeatedReadingAddsOneGraphSampleAndTheHistoryKeepsTheNewestSixty() async throws {
    let script = ScriptWidget()
    let reading = ScriptOutput(text: "50%", value: 0.5)
    try script.accept(reading)
    var updates = 0
    script.onUpdate = { updates += 1 }
    try await confirmation("The history gains a sample", expectedCount: 1) { sampled in
        try await confirmation("The output and the error stay as they are", expectedCount: 0) { changed in
            withObservationTracking { _ = script.samples } onChange: { sampled() }
            withObservationTracking { _ = script.output; _ = script.error } onChange: { changed() }
            try script.accept(reading)
        }
    }
    #expect(script.samples == [0.5, 0.5])
    #expect(updates == 0)
    for _ in 0..<70 { try script.accept(reading) }
    #expect(script.samples == Array(repeating: 0.5, count: 60))
    try await confirmation("A full history of equal samples stays as it is", expectedCount: 0) { changed in
        withObservationTracking { _ = script.samples } onChange: { changed() }
        try script.accept(reading)
    }
    for index in 0..<70 { try script.accept(ScriptOutput(text: "reading", value: Double(index) / 100)) }
    #expect(script.samples == (10..<70).map { Double($0) / 100 })
}

@MainActor
private final class FakeSource: DataSource {
    private(set) var started = 0
    private(set) var stopped = 0
    private(set) var refreshes: [String] = []
    private(set) var emit: (@Sendable (SourceUpdate) -> Void)?

    func start(emit: @escaping @Sendable (SourceUpdate) -> Void) {
        started += 1
        self.emit = emit
    }

    func refresh(event: ScriptEvent) {
        refreshes.append(event.sender)
    }

    func stop() {
        stopped += 1
        emit = nil
    }
}

/// Makes a new `FakeSource` each time the runner asks for one, and keeps them in order.
@MainActor
private final class FakeSources {
    private(set) var made: [FakeSource] = []

    func make() -> FakeSource {
        let source = FakeSource()
        made.append(source)
        return source
    }
}

/// Waits up to two seconds for `condition`, then requires it.
@MainActor
func awaitCondition(_ condition: () -> Bool) async throws {
    for _ in 0..<100 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    try #require(condition())
}

@Test @MainActor func aBurstOfUpdatesReachesTheWidgetAsItsNewestValue() async throws {
    let sources = FakeSources()
    let script = ScriptWidget()
    defer { script.stop() }
    script.start(schedule: SourceSchedule(interval: nil, continuous: true)) { sources.make() }
    try await awaitCondition { sources.made.first?.emit != nil }
    let source = try #require(sources.made.first)
    #expect(source.refreshes == ["startup"])
    let emit = try #require(source.emit)
    for index in 1...50 { emit(.output(.success(ScriptOutput(text: "\(index)", value: Double(index) / 100)))) }
    try await awaitCondition { script.output.text == "50" }
    #expect(script.samples.count <= 2)
    #expect(script.samples.last == 0.5)
    await Task.detached {
        for index in 51...100 { emit(.output(.success(ScriptOutput(text: "\(index)")))) }
    }.value
    try await awaitCondition { script.output.text == "100" }
    #expect(script.diagnostics.executionCount == 1)
    #expect(script.diagnostics.running)
}

@Test @MainActor func suspendingStopsTheSourceAndIgnoresUpdatesDeliveredAsItSuspendsOrLater() async throws {
    let sources = FakeSources()
    let script = ScriptWidget()
    defer { script.stop() }
    script.start(schedule: SourceSchedule(interval: nil, continuous: true)) { sources.make() }
    try await awaitCondition { sources.made.first?.emit != nil }
    let first = try #require(sources.made.first)
    let emit = try #require(first.emit)
    emit(.output(.success(ScriptOutput(text: "live", value: 0.4))))
    try await awaitCondition { script.output.text == "live" }
    let updated = script.diagnostics.lastUpdated
    emit(.output(.success(ScriptOutput(text: "stale", value: 0.9))))
    script.suspend()
    #expect(first.stopped == 1)
    #expect(!script.diagnostics.running)
    emit(.output(.success(ScriptOutput(text: "late"))))
    try await Task.sleep(for: .milliseconds(50))
    #expect(script.output.text == "live")
    #expect(script.diagnostics.lastUpdated == updated)
    script.resume()
    try await awaitCondition { sources.made.count == 2 && sources.made[1].emit != nil }
    #expect(sources.made[1].refreshes == ["resume"])
    #expect(first.started == 1)
    #expect(script.samples == [0.4])
}

@Test @MainActor func aFailedRunRetriesWithBackoffAndARefreshRestartsAContinuousSource() async throws {
    let sources = FakeSources()
    let script = ScriptWidget()
    defer { script.stop() }
    script.start(schedule: SourceSchedule(interval: 0.05, continuous: true)) { sources.make() }
    try await awaitCondition { sources.made.first?.emit != nil }
    let first = try #require(sources.made.first)
    first.emit?(.output(.success(ScriptOutput(text: "Ready"))))
    try await awaitCondition { script.output.text == "Ready" }
    first.emit?(.output(.failure(CommandFailure(message: "Disconnected."))))
    try await awaitCondition { script.error == "Disconnected." }
    #expect(script.output.text == "Ready")
    #expect(script.diagnostics.nextDelay == 1)
    #expect(first.stopped == 1)
    script.refresh(ScriptEvent(sender: "manual"))
    try await awaitCondition { sources.made.count == 2 && sources.made[1].refreshes == ["manual"] }
    #expect(script.diagnostics.restartCount == 1)
    #expect(script.diagnostics.nextDelay == nil)
}

@Test @MainActor func aCommandWhoseOutputDoesNotDecodeStillRecordsItsProcess() async throws {
    let script = ScriptWidget()
    defer { script.stop() }
    script.start(command: "printf '{broken'; printf warning >&2", interval: nil)
    try await awaitCondition { script.error != nil }
    #expect(script.diagnostics.lastStdout == "{broken")
    #expect(script.diagnostics.lastStderr == "warning")
    #expect(script.diagnostics.failureCount == 1)
    #expect(script.output.text == "…")
}

@Test @MainActor func aRepeatedFailureReportsOnceUntilItsMessageChanges() async throws {
    let sources = FakeSources()
    let script = ScriptWidget()
    defer { script.stop() }
    var updates = 0
    script.onUpdate = { updates += 1 }
    script.start(schedule: SourceSchedule(interval: nil)) { sources.make() }
    try await awaitCondition { sources.made.first?.emit != nil }
    let source = try #require(sources.made.first)
    source.emit?(.output(.failure(CommandFailure(message: "Offline"))))
    try await awaitCondition { script.diagnostics.failureCount == 1 }
    #expect(script.error == "Offline")
    #expect(updates == 1)
    try await confirmation("A repeated failure changes nothing a view reads", expectedCount: 0) { changed in
        withObservationTracking { _ = script.error; _ = script.output } onChange: { changed() }
        script.refresh(ScriptEvent(sender: "again"))
        try await awaitCondition { source.started == 2 }
        source.emit?(.output(.failure(CommandFailure(message: "Offline"))))
        try await awaitCondition { script.diagnostics.failureCount == 2 }
    }
    #expect(updates == 1)
    #expect(script.diagnostics.consecutiveFailures == 2)
    script.refresh(ScriptEvent(sender: "later"))
    try await awaitCondition { source.started == 3 }
    source.emit?(.output(.failure(CommandFailure(message: "Still offline"))))
    try await awaitCondition { script.diagnostics.failureCount == 3 }
    #expect(script.error == "Still offline")
    #expect(updates == 2)
}

@Test @MainActor func aFailureIsReportedAfterTheOutputSentBeforeIt() async throws {
    let sources = FakeSources()
    let script = ScriptWidget()
    defer { script.stop() }
    script.start(schedule: SourceSchedule(interval: nil, continuous: true)) { sources.make() }
    try await awaitCondition { sources.made.first?.emit != nil }
    let source = try #require(sources.made.first)
    let emit = try #require(source.emit)
    emit(.output(.success(ScriptOutput(text: "A", value: 0.1))))
    emit(.output(.success(ScriptOutput(text: "B", value: 0.2))))
    emit(.output(.failure(CommandFailure(message: "Disconnected."))))
    try await awaitCondition { script.error != nil }
    #expect(script.output.text == "B")
    #expect(script.samples.last == 0.2)
    #expect(script.error == "Disconnected.")
    #expect(script.diagnostics.failureCount == 1)
    #expect(source.stopped == 1)
}

private func writeTemporaryConfiguration(_ json: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "config.json")
    try Data(json.utf8).write(to: url)
    return url
}

@Test @MainActor func snapshotsNameTheDataSourceOfProviderWidgets() async throws {
    let url = try writeTemporaryConfiguration(#"""
    {"widgets":[{"id":"cpu","type":"system","position":"right"},{"id":"label","type":"text","text":"A","position":"left"}]}
    """#)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = BarStore(configurationURL: url)
    defer { store.stop() }
    store.reloadConfiguration()
    guard case let .object(cpu) = try store.snapshot(id: "cpu") else {
        Issue.record("Expected an object snapshot")
        return
    }
    #expect(cpu["source"] == .object(["provider": .string("system"), "type": .string("system"), "push": .bool(false),
                                      "events": .array([])]))
    guard case let .object(label) = try store.snapshot(id: "label") else {
        Issue.record("Expected an object snapshot")
        return
    }
    #expect(label["source"] == nil)
}

@Test @MainActor func editsAddAndRejectSourceTypesThroughTheRegistry() throws {
    let url = try writeTemporaryConfiguration(#"{"widgets":[]}"#)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = BarStore(configurationURL: url)
    defer { store.stop() }
    store.reloadConfiguration()
    try store.applyEdits([ConfigurationEdit(action: .add, properties: ["id": .string("cpu"), "type": .string("system"),
                                                                        "position": .string("right")])], persist: false)
    #expect(store.configuration?.widgets.first?.content == .provider("system"))
    let error = #expect(throws: (any Error).self) {
        try store.applyEdits([ConfigurationEdit(action: .add, properties: ["id": .string("disk"), "type": .string("disk"),
                                                                            "position": .string("right")])], persist: false)
    }
    #expect(error.map(errorMessage) == "widgets.disk: type: Unknown widget type.")
}

@Test @MainActor func aStoreStartsItsProvidersFromItsOwnRegistry() async throws {
    let sources = FakeSources()
    let fake = DataSourceType(name: "system", isNative: true, symbol: "cpu", settings: [], continuous: true) { _, _ in sources.make() }
    let url = try writeTemporaryConfiguration(#"{"widgets":[{"id":"cpu","type":"system","position":"right"}]}"#)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = BarStore(configurationURL: url, registry: DataSourceRegistry(types: [fake]))
    defer { store.stop() }
    store.reloadConfiguration()
    try await awaitCondition { sources.made.first?.emit != nil }
    let source = try #require(sources.made.first)
    #expect(source.refreshes == ["startup"])
    guard case let .object(cpu) = try store.snapshot(id: "cpu") else {
        Issue.record("Expected an object snapshot")
        return
    }
    #expect(cpu["source"] == .object(["provider": .string("system"), "type": .string("system"), "push": .bool(true),
                                      "events": .array([])]))
    source.emit?(.output(.success(ScriptOutput(text: "from the fake"))))
    try await awaitCondition { store.scripts["cpu"]?.output.text == "from the fake" }
}

@Test @MainActor func aNativeReadingSetsItsOwnNextInterval() async throws {
    let reading = DataSourceType(name: "calendar", isNative: true, symbol: "calendar", settings: [], continuous: false) { _, _ in
        PollingSource { _ in .output(.success(ScriptOutput(text: "Standup", interval: 0.05))) }
    }
    let provider = try JSONDecoder().decode(ProviderConfiguration.self, from: Data(#"{"type":"calendar","interval":60}"#.utf8))
    let script = ScriptWidget()
    defer { script.stop() }
    script.start(provider: provider, registry: DataSourceRegistry(types: [reading]))
    try await awaitCondition { script.diagnostics.executionCount >= 3 }
    #expect(script.diagnostics.lastEvent == "routine")
    #expect(script.output.text == "Standup")
}

@Test @MainActor func aSourceRefreshesOnItsChangeNotificationWhileItRuns() async throws {
    let changed = Notification.Name("StableBarTests.change.\(UUID().uuidString)")
    let sources = FakeSources()
    let watched = DataSourceType(name: "calendar", isNative: true, symbol: "calendar", settings: [], continuous: false,
                                 changeNotification: changed) { _, _ in sources.make() }
    let script = ScriptWidget()
    defer { script.stop() }
    func refreshes() -> [String] { sources.made.flatMap(\.refreshes) }
    func finishRun() async throws {
        let source = try #require(sources.made.last)
        source.emit?(.output(.success(ScriptOutput(text: "Standup"))))
        source.emit?(.finished)
        try await awaitCondition { !script.diagnostics.running && script.diagnostics.nextDelay == 5 }
    }
    script.start(provider: ProviderConfiguration(type: "calendar"), registry: DataSourceRegistry(types: [watched]))
    try await awaitCondition { refreshes() == ["startup"] }
    try await finishRun()
    NotificationCenter.default.post(name: changed, object: nil)
    try await awaitCondition { refreshes() == ["startup", "calendar"] }
    try await finishRun()
    script.suspend()
    NotificationCenter.default.post(name: changed, object: nil)
    try await Task.sleep(for: .milliseconds(100))
    #expect(refreshes() == ["startup", "calendar"])
    script.resume()
    try await awaitCondition { refreshes() == ["startup", "calendar", "resume"] }
    try await finishRun()
    NotificationCenter.default.post(name: changed, object: nil)
    try await awaitCondition { refreshes() == ["startup", "calendar", "resume", "calendar"] }
    script.stop()
    NotificationCenter.default.post(name: changed, object: nil)
    try await Task.sleep(for: .milliseconds(100))
    #expect(refreshes() == ["startup", "calendar", "resume", "calendar"])
}

@Test @MainActor func widgetStatusTellsMissingAccessFailuresPausedDisabledAndConnectedSourcesApart() throws {
    let store = BarStore()
    store.configuration = try JSONDecoder().decode(Configuration.self, from: Data(#"""
    {"widgets":[{"id":"meeting","type":"calendar","position":"right"},
                {"id":"power","type":"battery","position":"right"},
                {"id":"off","type":"battery","position":"right","enabled":false}]}
    """#.utf8))
    let widget = store.configuration!.widgets[0]
    let script = ScriptWidget()
    store.scripts[widget.id] = script
    #expect(store.widgetStatus(for: widget) == .starting)
    try script.accept(ScriptOutput(text: "No calendar access", fields: ["access": "denied"]))
    #expect(script.error == nil)
    #expect(store.widgetStatus(for: widget) == .accessNeeded(.calendars))
    #expect(store.widgetStatus(for: widget).needsAttention)
    try script.accept(ScriptOutput(text: "No meetings", fields: ["access": "granted"]))
    #expect(store.widgetStatus(for: widget) == .working)
    script.error = "Calendar unavailable"
    #expect(store.widgetStatus(for: widget) == .failed("Calendar unavailable"))
    store.actionErrors[widget.id] = "Meeting link failed"
    #expect(store.widgetStatus(for: widget) == .failed("Click action: Meeting link failed"))
    let power = store.configuration!.widgets[1]
    let disabled = store.configuration!.widgets[2]
    let battery = ScriptWidget()
    store.scripts[power.id] = battery
    try battery.accept(ScriptOutput(text: "80%"))
    battery.diagnostics.running = true
    #expect(store.widgetStatus(for: power) == .connected)
    battery.diagnostics.running = false
    battery.diagnostics.suspended = true
    #expect(store.widgetStatus(for: power) == .paused)
    store.actionErrors[disabled.id] = "An earlier error"
    #expect(store.widgetStatus(for: disabled) == .disabled)
    #expect(!store.widgetStatus(for: disabled).needsAttention)
}

@Test @MainActor func aProviderWhoseTypeIsNotRegisteredReportsAnError() {
    let script = ScriptWidget()
    defer { script.stop() }
    script.start(provider: ProviderConfiguration(type: "disk"), registry: DataSourceRegistry(types: [.command]))
    #expect(script.error == "Unknown data source type: disk.")
    #expect(script.output.text == "…")
    #expect(script.diagnostics.executionCount == 0)
}

/// Native data a test changes by hand, in place of IOKit or CoreAudio.
private final class FakeMonitor: ChangeMonitor {
    private struct State {
        var output: Result<ScriptOutput, any Error>
        var changed: (@Sendable () -> Void)?
        var startError: (any Error)?
    }

    private let state: OSAllocatedUnfairLock<State>

    init(_ output: ScriptOutput) {
        state = OSAllocatedUnfairLock(initialState: State(output: .success(output)))
    }

    var listening: Bool { state.withLock { $0.changed != nil } }

    func read() throws -> ScriptOutput { try state.withLock { $0.output }.get() }

    func start(changed: @escaping @Sendable () -> Void) throws {
        if let error = state.withLock({ $0.startError }) { throw error }
        state.withLock { $0.changed = changed }
    }

    /// Makes `start` throw, as when macOS refuses the listener, or work again with `nil`.
    func failToStart(with error: (any Error)?) {
        state.withLock { $0.startError = error }
    }

    func stop() {
        state.withLock { $0.changed = nil }
    }

    /// Replaces the data and notifies the listener, as macOS would.
    func change(to output: ScriptOutput) {
        state.withLock { $0.output = .success(output) }
        notify()
    }

    func fail(_ error: any Error) {
        state.withLock { $0.output = .failure(error) }
        notify()
    }

    private func notify() {
        let changed = state.withLock { $0.changed }
        changed?()
    }
}

private extension DataSourceRegistry {
    /// This registry with the source of one type replaced, such as a battery backed by a fake.
    func replacing(_ name: String, with makeSource: @escaping @MainActor @Sendable (ProviderConfiguration, [String: String]) -> any DataSource) -> DataSourceRegistry {
        DataSourceRegistry(types: types.map { type in
            var type = type
            if type.name == name { type.makeSource = makeSource }
            return type
        })
    }
}

@Test @MainActor func pushSourcesSendOnlyChangesAndCanStopBeforeTheyStartStopTwiceAndStartAgain() {
    let monitor = FakeMonitor(ScriptOutput(text: "80%"))
    let source = PushSource(monitor: monitor)
    let sent = OSAllocatedUnfairLock<[String]>(initialState: [])
    func emit(_ run: String) -> @Sendable (SourceUpdate) -> Void {
        { update in
            guard case let .output(result, _) = update else { return }
            let text = (try? result.get())?.text ?? "failure"
            sent.withLock { $0.append("\(run) \(text)") }
        }
    }
    source.stop()
    #expect(!monitor.listening)
    source.start(emit: emit("first"))
    #expect(monitor.listening)
    source.refresh(event: ScriptEvent(sender: "startup"))
    monitor.change(to: ScriptOutput(text: "80%"))
    monitor.change(to: ScriptOutput(text: "79%"))
    monitor.fail(CommandFailure(message: "No battery."))
    source.stop()
    source.stop()
    #expect(!monitor.listening)
    monitor.change(to: ScriptOutput(text: "78%"))
    source.start(emit: emit("second"))
    #expect(monitor.listening)
    source.refresh(event: ScriptEvent(sender: "routine"))
    monitor.change(to: ScriptOutput(text: "77%"))
    #expect(sent.withLock { $0 } == ["first 80%", "first 79%", "first failure", "second 78%", "second 77%"])
}

@Test @MainActor func aFailedPushSourceStopsListeningAndListensAgainWhenItRetries() async throws {
    let monitor = FakeMonitor(ScriptOutput(text: "80%"))
    let made = OSAllocatedUnfairLock(initialState: 0)
    let script = ScriptWidget()
    defer { script.stop() }
    script.start(schedule: SourceSchedule(interval: 0.05, continuous: true)) {
        made.withLock { $0 += 1 }
        return PushSource(monitor: monitor)
    }
    try await awaitCondition { script.output.text == "80%" && monitor.listening }
    monitor.fail(CommandFailure(message: "No battery."))
    try await awaitCondition { script.error == "No battery." }
    #expect(!monitor.listening)
    #expect(script.diagnostics.nextDelay == 1)
    monitor.change(to: ScriptOutput(text: "79%"))
    try await awaitCondition { script.output.text == "79%" && monitor.listening }
    #expect(script.error == nil)
    #expect(script.diagnostics.restartCount == 1)
    #expect(made.withLock { $0 } == 1)
}

@Test @MainActor func aContinuousRunThatStayedOpenStartsANewFailureStreakWhenItFails() async throws {
    let sources = FakeSources()
    let script = ScriptWidget()
    defer { script.stop() }
    // The test clock moves only when the test says, so the runs that fail at once stay short however long other
    // tests hold the main actor.
    let clock = TestClock()
    script.clock = clock
    script.start(schedule: SourceSchedule(interval: 0.05, continuous: true)) { sources.make() }
    for run in 0..<2 {
        try await awaitCondition { sources.made.count == run + 1 && sources.made[run].emit != nil }
        sources.made[run].emit?(.output(.failure(CommandFailure(message: "Disconnected."))))
        try await awaitCondition { script.diagnostics.failureCount == run + 1 }
        #expect(script.diagnostics.nextDelay == Double(run + 1))
        script.refresh(ScriptEvent(sender: "manual"))
    }
    try await awaitCondition { sources.made.count == 3 && sources.made[2].emit != nil }
    clock.advance(by: script.steadyRun - .milliseconds(1))
    sources.made[2].emit?(.output(.failure(CommandFailure(message: "Disconnected."))))
    try await awaitCondition { script.diagnostics.failureCount == 3 }
    #expect(script.diagnostics.consecutiveFailures == 3, "A run that ends just short of steady continues the streak")
    script.refresh(ScriptEvent(sender: "manual"))
    try await awaitCondition { sources.made.count == 4 && sources.made[3].emit != nil }
    clock.advance(by: script.steadyRun)
    sources.made[3].emit?(.output(.failure(CommandFailure(message: "Disconnected."))))
    try await awaitCondition { script.diagnostics.failureCount == 4 }
    #expect(script.diagnostics.consecutiveFailures == 1)
    #expect(script.diagnostics.nextDelay == 1)
}

@Test @MainActor func batteryListensOnlyWhileAWidgetUsesIt() async throws {
    let url = try writeTemporaryConfiguration(#"""
    {"providers":{"battery":{"type":"battery","interval":0.05,"whenVisible":true}},
     "widgets":[{"id":"power","type":"battery","position":"right"}]}
    """#)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let monitor = FakeMonitor(ScriptOutput(text: "80%", value: 0.8))
    let store = BarStore(configurationURL: url, registry: .builtIn.replacing("battery") { _, _ in PushSource(monitor: monitor) })
    defer { store.stop() }
    store.reloadConfiguration()
    let power = try #require(store.scripts["power"])
    #expect(power.diagnostics.suspended)
    #expect(!monitor.listening)
    store.setVisibleWidgets(ids: ["power"], displayID: 1)
    try await awaitCondition { power.output.text == "80%" && monitor.listening }
    monitor.change(to: ScriptOutput(text: "79%", value: 0.79))
    try await awaitCondition { power.output.text == "79%" }
    let updated = power.diagnostics.lastUpdated
    monitor.change(to: ScriptOutput(text: "79%", value: 0.79))
    try await Task.sleep(for: .milliseconds(200))
    #expect(power.diagnostics.lastUpdated == updated)
    #expect(power.diagnostics.executionCount == 1)
    #expect(power.diagnostics.nextDelay == nil)
    #expect(power.samples == [0.8, 0.79])
    store.setPaused(true, because: .systemAsleep)
    #expect(!monitor.listening)
    store.setPaused(false, because: .systemAsleep)
    try await awaitCondition { monitor.listening }
    #expect(power.output.text == "79%")
    try store.applyEdits([ConfigurationEdit(action: .set, id: "power", properties: ["enabled": .bool(false)])], persist: false)
    #expect(!monitor.listening)
    #expect(store.providers.isEmpty)
}

@Test @MainActor func aMonitorThatCannotStartShowsItsErrorRetriesAndHoldsNoRunOpen() async throws {
    let monitor = FakeMonitor(ScriptOutput(text: "80%"))
    monitor.failToStart(with: CommandFailure(message: "No listener."))
    let script = ScriptWidget()
    defer { script.stop() }
    script.start(schedule: SourceSchedule(interval: 0.05, continuous: true)) { PushSource(monitor: monitor) }
    try await awaitCondition { script.error == "No listener." }
    try await awaitCondition { !script.diagnostics.running }
    #expect(!monitor.listening)
    #expect(script.diagnostics.nextDelay == 1)
    #expect(script.diagnostics.failureCount == 1)
    monitor.failToStart(with: nil)
    try await awaitCondition { script.error == nil && script.output.text == "80%" && monitor.listening }
    #expect(script.diagnostics.running)
}

private func battery(_ state: String) -> ScriptOutput {
    ScriptOutput(text: "50%", value: 0.5, fields: ["state": state, "present": "true"], values: ["percent": 0.5])
}

@Test @MainActor func outputChangesAfterTheFirstReachTheChangeHook() throws {
    let script = ScriptWidget()
    var changes: [String] = []
    script.onOutputChange = { previous, output in changes.append("\(previous.text)→\(output.text)") }
    try script.accept(ScriptOutput(text: "a"))
    try script.accept(ScriptOutput(text: "a"))
    try script.accept(ScriptOutput(text: "b"))
    #expect(changes == ["a→b"])
}

@Test func powerSourceChangesOnlyWhenTheMacSwitchesBetweenAdapterAndBattery() {
    let event = BuiltInEvent.powerSourceChange
    #expect(event.variables(from: battery("charging"), to: battery("battery")) == ["INFO": "battery"])
    #expect(event.variables(from: battery("battery"), to: battery("charged")) == ["INFO": "ac"])
    #expect(event.variables(from: battery("charging"), to: battery("charged")) == nil)
    #expect(event.variables(from: battery("battery"), to: ScriptOutput(text: "51%", fields: ["state": "battery"])) == nil)
    #expect(BuiltInEvent.frontApp.variables(from: battery("battery"), to: battery("charged")) == nil)
    #expect(DataSourceType.battery.events == [.powerSourceChange])
}

@Test func subscribedSourceEventsAddTheProvidersThatSendThem() throws {
    func configuration(_ json: String) throws -> Configuration {
        var loader = ConfigurationLoader()
        return try loader.load(FileManager.default.temporaryDirectory.appending(path: "events.json"), data: Data(json.utf8))
    }
    let subscribed = try configuration(#"""
    {"templates":{"notice":{"type":"script","position":"left","interval":null,"events":["powerSourceChange"]}},
     "widgets":[{"id":"notice","template":"notice","command":"true"},{"id":"cpu","type":"system","position":"right"}]}
    """#)
    #expect(subscribed.activeProviders == ["battery", "system"])
    #expect(subscribed.providers["battery"] == ProviderConfiguration(type: "battery"))
    let shown = try configuration(#"""
    {"providers":{"power":{"type":"battery"}},
     "widgets":[{"id":"power","type":"provider","provider":"power","position":"right","events":["powerSourceChange"]}]}
    """#)
    #expect(shown.activeProviders == ["power"])
    let disabled = try configuration(#"""
    {"widgets":[{"id":"notice","type":"script","position":"left","command":"true","enabled":false,"events":["powerSourceChange"]}]}
    """#)
    #expect(disabled.activeProviders.isEmpty)
    let own = try configuration(#"""
    {"providers":{"battery":{"type":"command","command":"true"}},
     "widgets":[{"id":"notice","type":"script","position":"left","command":"true","events":["powerSourceChange"]}]}
    """#)
    #expect(own.providers["battery"]?.type == "command")
    #expect(own.activeProviders.isEmpty)
}

@Test @MainActor func subscribingToASourceEventRunsThatSource() async throws {
    let url = try writeTemporaryConfiguration(#"""
    {"widgets":[{"id":"notice","type":"script","position":"left","interval":null,"events":["powerSourceChange"],
      "command":"printf '%s' \"${INFO:-none}\""}]}
    """#)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let monitor = FakeMonitor(battery("charging"))
    let store = BarStore(configurationURL: url, registry: .builtIn.replacing("battery") { _, _ in PushSource(monitor: monitor) })
    defer { store.stop() }
    store.reloadConfiguration()
    let notice = try #require(store.scripts["notice"])
    try await awaitCondition { notice.output.text == "none" && store.providers["battery"]?.diagnostics.lastUpdated != nil }
    #expect(store.scripts["battery"] == nil)
    monitor.change(to: battery("battery"))
    try await awaitCondition { notice.output.text == "battery" }
    monitor.change(to: battery("charged"))
    try await awaitCondition { notice.output.text == "ac" }
    try store.applyEdits([ConfigurationEdit(action: .set, id: "notice", properties: ["events": .array([])])], persist: false)
    #expect(!monitor.listening)
    #expect(store.providers.isEmpty)
}

@Test @MainActor func aProviderNamedAfterABuiltInSourceKeepsThatSourceFromStarting() async throws {
    let url = try writeTemporaryConfiguration(#"""
    {"providers":{"battery":{"type":"command","command":"printf helper"}},
     "widgets":[{"id":"helper","type":"provider","provider":"battery","position":"right"},
                {"id":"notice","type":"script","position":"left","interval":null,"events":["powerSourceChange"],
                 "command":"printf '%s' \"${INFO:-none}\""}]}
    """#)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let sources = FakeSources()
    let store = BarStore(configurationURL: url, registry: .builtIn.replacing("battery") { _, _ in sources.make() })
    defer { store.stop() }
    store.reloadConfiguration()
    #expect(store.configurationError == nil)
    let notice = try #require(store.scripts["notice"])
    try await awaitCondition { notice.output.text == "none" && store.scripts["helper"]?.output.text == "helper" }
    store.refreshScripts(for: "powerSourceChange", environment: ["INFO": "battery"])
    try await awaitCondition { notice.output.text == "battery" }
    #expect(sources.made.isEmpty)
    #expect(Array(store.providers.keys) == ["battery"])
}

@Test @MainActor func aProviderWhoseEventsAreSubscribedIgnoresWhenVisible() async throws {
    let url = try writeTemporaryConfiguration(#"""
    {"providers":{"battery":{"type":"battery","whenVisible":true}},
     "widgets":[{"id":"power","type":"battery","position":"right"},
                {"id":"notice","type":"script","position":"left","interval":null,"events":["powerSourceChange"],"command":"true"}]}
    """#)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let monitor = FakeMonitor(battery("charging"))
    let store = BarStore(configurationURL: url, registry: .builtIn.replacing("battery") { _, _ in PushSource(monitor: monitor) })
    defer { store.stop() }
    store.reloadConfiguration()
    try await awaitCondition { monitor.listening }
    #expect(store.scripts["power"]?.diagnostics.suspended == false)
    try store.applyEdits([ConfigurationEdit(action: .set, id: "notice", properties: ["enabled": .bool(false)])], persist: false)
    #expect(store.scripts["power"]?.diagnostics.suspended == true)
    #expect(!monitor.listening)
}

@Test @MainActor func aSourceEventRefreshesItsSubscribersButNotTheProviderThatSentIt() async throws {
    let url = try writeTemporaryConfiguration(#"""
    {"widgets":[{"id":"power","type":"battery","position":"right","events":["powerSourceChange"]},
                {"id":"notice","type":"script","position":"left","interval":null,"events":["powerSourceChange"],
                 "command":"printf '%s' \"${INFO:-none}\""}]}
    """#)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let sources = FakeSources()
    let store = BarStore(configurationURL: url, registry: .builtIn.replacing("battery") { _, _ in sources.make() })
    defer { store.stop() }
    store.reloadConfiguration()
    let power = try #require(store.scripts["power"])
    let notice = try #require(store.scripts["notice"])
    try await awaitCondition { sources.made.first?.emit != nil && notice.output.text == "none" }
    let source = try #require(sources.made.first)
    source.emit?(.output(.success(battery("charging"))))
    try await awaitCondition { power.output.fields?["state"] == "charging" }
    source.emit?(.output(.success(battery("battery"))))
    try await awaitCondition { notice.output.text == "battery" }
    #expect(power.diagnostics.restartCount == 0)
    #expect(sources.made.count == 1)
    #expect(notice.diagnostics.executionCount == 2)
}

@Test @MainActor func stoppingTheStoreStopsProvidersThatOnlySendEvents() async throws {
    let url = try writeTemporaryConfiguration(#"""
    {"widgets":[{"id":"notice","type":"script","position":"left","interval":null,"events":["powerSourceChange"],"command":"true"}]}
    """#)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let monitor = FakeMonitor(battery("charging"))
    let store = BarStore(configurationURL: url, registry: .builtIn.replacing("battery") { _, _ in PushSource(monitor: monitor) })
    defer { store.stop() }
    store.reloadConfiguration()
    try await awaitCondition { monitor.listening }
    store.stop()
    #expect(!monitor.listening)
}

private func audio(_ volume: Double?, muted: Bool = false, device: String = "Speakers", id: String = "42") -> ScriptOutput {
    var fields = ["device": device, "deviceID": id, "volumeAvailable": String(volume != nil), "muted": String(muted)]
    if volume == nil { fields["muted"] = nil }
    return ScriptOutput(text: volume.map { "\(Int($0 * 100))%" } ?? device, value: volume, fields: fields,
                        values: volume.map { ["volume": $0] })
}

@Test func volumeAndDeviceEventsFollowTheDefaultOutputDevice() {
    #expect(BuiltInEvent.volumeChange.variables(from: audio(0.5), to: audio(0.62)) == ["INFO": "62", "MUTED": "false"])
    #expect(BuiltInEvent.volumeChange.variables(from: audio(0.5), to: audio(0.5, muted: true)) == ["INFO": "50", "MUTED": "true"])
    #expect(BuiltInEvent.volumeChange.variables(from: audio(0.5), to: audio(0.5, device: "AirPods", id: "77")) == nil)
    #expect(BuiltInEvent.volumeChange.variables(from: audio(0.5), to: audio(nil, device: "HDMI", id: "9")) == ["INFO": "", "MUTED": "false"])
    #expect(BuiltInEvent.outputDeviceChange.variables(from: audio(0.5), to: audio(0.5, device: "AirPods", id: "77")) == ["INFO": "AirPods"])
    #expect(BuiltInEvent.outputDeviceChange.variables(from: audio(0.5), to: ScriptOutput(text: "No output")) == ["INFO": ""])
    #expect(BuiltInEvent.outputDeviceChange.variables(from: audio(0.5), to: audio(0.7)) == nil)
    #expect(DataSourceType.audio.continuous)
    #expect(DataSourceType.audio.events == [.volumeChange, .outputDeviceChange])
}

@Test func theSpeakerShowsMoreWavesAsTheVolumeRises() {
    let levels: [(Double, String)] = [(0, "speaker"), (0.004, "speaker"), (0.01, "speaker.wave.1"), (0.33, "speaker.wave.1"),
                                      (0.34, "speaker.wave.2"), (0.66, "speaker.wave.2"), (0.67, "speaker.wave.3"), (1, "speaker.wave.3")]
    for (volume, icon) in levels {
        #expect(AudioMonitor.icon(volume: volume, muted: false) == icon, "\(volume)")
        #expect(AudioMonitor.icon(volume: volume, muted: true) == "speaker.slash", "\(volume) muted")
    }
    #expect(AudioMonitor.icon(volume: nil, muted: false) == "speaker.wave.2", "Without a volume control")
}

@Test func audioShowsTheVolumeForAMomentAfterItChanges() {
    func shown(_ output: ScriptOutput, after previous: ScriptOutput?) -> [String: String]? {
        let next = AudioMonitor.showingChange(to: output, from: previous)
        if let temporary = next.temporary { #expect(temporary.duration == 1.5) }
        #expect(next.text == output.text && next.values == output.values, "The output keeps its own text and volume")
        return next.temporary?.fields
    }
    #expect(shown(audio(0.5), after: nil) == nil, "The first read shows nothing")
    #expect(shown(audio(0.5), after: audio(0.5)) == nil)
    #expect(shown(audio(0.62), after: audio(0.5)) == ["changedVolume": "62%"])
    #expect(shown(audio(0.5, muted: true), after: audio(0.5)) == ["changedVolume": ""], "Muting hides the volume")
    #expect(shown(audio(0.5), after: audio(0.5, muted: true)) == ["changedVolume": "50%"])
    #expect(shown(audio(0.5, device: "AirPods", id: "77"), after: audio(0.5)) == nil, "A new device at the same volume shows nothing")
    #expect(shown(audio(nil, device: "HDMI", id: "9"), after: audio(0.5)) == ["changedVolume": ""])
}

@Test func theDeviceListSkipsADeviceWhoseNameCannotBeRead() {
    let rows = AudioMonitor.deviceRows([42, 77, 9]) { device in
        guard device != 77 else { throw CommandFailure(message: "Could not read audio device name (560947818).") }
        return device == 42 ? "Speakers" : "HDMI"
    }
    #expect(rows == [["id": "42", "name": "Speakers"], ["id": "9", "name": "HDMI"]])
}

@Test func aDeviceListChangeMovesTheVolumeListenerUnlessItWatchesEveryPropertyOfTheDevice() {
    let volume = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput,
                                            mElement: kAudioObjectPropertyElementMain)
    let mute = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput,
                                          mElement: kAudioObjectPropertyElementMain)
    #expect(AudioMonitor.covers(device: 42, properties: [volume, mute], watched: 42, addresses: [mute, volume]))
    #expect(AudioMonitor.covers(device: 42, properties: [mute], watched: 42, addresses: [volume, mute]))
    #expect(AudioMonitor.covers(device: AudioObjectID(kAudioObjectUnknown), properties: [],
                                watched: AudioObjectID(kAudioObjectUnknown), addresses: []))
    #expect(!AudioMonitor.covers(device: 42, properties: [volume, mute], watched: 42, addresses: [mute]))
    #expect(!AudioMonitor.covers(device: 77, properties: [volume, mute], watched: 42, addresses: [volume, mute]))
}

/// Runs what the main queue holds now, such as a relay's waiting hops.
@MainActor
private func drainMainQueue() async {
    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
}

/// A relay whose runs record their changes under their names, and the queue a monitor would hear of changes on.
private struct RelayProbe {
    let relay = MainQueueRelay()
    let changes = OSAllocatedUnfairLock<[String]>(initialState: [])
    let listener = DispatchQueue(label: "StableBarTests.listener")

    func start(_ run: String) {
        relay.start { [changes] in changes.withLock { $0.append(run) } }
    }

    /// Reports `count` changes from the listener queue while the main queue waits.
    func notify(_ count: Int = 1) {
        listener.sync { for _ in 0..<count { relay.notify() } }
    }

    var recorded: [String] { changes.withLock { $0 } }
}

@Test @MainActor func aBurstOfChangesReachesTheMainQueueOnce() async {
    let probe = RelayProbe()
    probe.start("first")
    probe.notify(20)
    await drainMainQueue()
    #expect(probe.recorded == ["first"])
    probe.notify(3)
    await drainMainQueue()
    #expect(probe.recorded == ["first", "first"])
}

@Test @MainActor func aChangeAfterStopIsDroppedAndOneAfterARestartReachesTheMainQueue() async {
    let probe = RelayProbe()
    probe.start("first")
    probe.notify()
    probe.relay.stop()
    probe.notify()
    await drainMainQueue()
    #expect(probe.recorded.isEmpty)
    probe.start("second")
    probe.notify()
    await drainMainQueue()
    #expect(probe.recorded == ["second"])
    probe.start("third")
    probe.notify()
    await drainMainQueue()
    #expect(probe.recorded == ["second", "third"])
}

@Test @MainActor func aVolumeBurstRunsSubscribedScriptsAtMostTwice() async throws {
    let url = try writeTemporaryConfiguration(#"""
    {"widgets":[{"id":"volume","type":"script","position":"right","interval":null,"events":["volumeChange"],
      "command":"printf '%s' \"${INFO:-start}\""}]}
    """#)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let monitor = FakeMonitor(audio(0.5))
    let store = BarStore(configurationURL: url, registry: .builtIn.replacing("audio") { _, _ in PushSource(monitor: monitor) })
    defer { store.stop() }
    store.reloadConfiguration()
    let volume = try #require(store.scripts["volume"])
    try await awaitCondition { volume.output.text == "start" && store.providers["audio"]?.diagnostics.lastUpdated != nil }
    for level in 51...80 { monitor.change(to: audio(Double(level) / 100)) }
    try await awaitCondition { volume.output.text == "80" }
    #expect(volume.diagnostics.executionCount <= 3)
}

@Test @MainActor func setupListsThePermissionsOfTheSourcesAConfigurationRuns() throws {
    let calendars = SourcePermission(title: "Calendars", detail: "Read upcoming events.", symbol: "calendar", privacyPane: "Privacy_Calendars")
    let registry = DataSourceRegistry(types: DataSourceRegistry.builtIn.types.map { type in
        var type = type
        if type.name == "battery" || type.name == "audio" { type.permission = calendars }
        return type
    })
    func configuration(_ json: String) throws -> Configuration {
        try JSONDecoder().decode(Configuration.self, from: Data(json.utf8))
    }
    #expect(registry.permissions(for: try configuration(#"""
    {"widgets":[{"id":"power","type":"battery","position":"right"},{"id":"sound","type":"audio","position":"right"},
                {"id":"cpu","type":"system","position":"right"}]}
    """#)) == [calendars])
    #expect(registry.permissions(for: try configuration(#"""
    {"widgets":[{"id":"notice","type":"script","position":"left","command":"true","events":["powerSourceChange"]}]}
    """#)) == [calendars])
    #expect(registry.permissions(for: try configuration(#"""
    {"widgets":[{"id":"power","type":"battery","position":"right","enabled":false},{"id":"cpu","type":"system","position":"right"}]}
    """#)).isEmpty)
    for type in ["appMenu", "appleMenu", "controlCenter", "menuBarItems"] {
        #expect(registry.permissions(for: try configuration(#"""
        {"widgets":[{"id":"menus","type":"\#(type)","position":"left"},{"id":"power","type":"battery","position":"right"}]}
        """#)) == [calendars, .accessibility])
        #expect(registry.permissions(for: try configuration(#"""
        {"widgets":[{"id":"menus","type":"\#(type)","position":"left","enabled":false}]}
        """#)).isEmpty)
    }
    for click in ["systemSettings", "lockScreen"] {
        #expect(registry.permissions(for: try configuration(#"""
        {"widgets":[{"id":"apple","type":"appleMenu","position":"left","click":"\#(click)"}]}
        """#)).isEmpty)
    }
    // Workspaces on macOS Spaces switches desktops with keyboard events; window managers switch for themselves.
    #expect(registry.permissions(for: try configuration(#"""
    {"workspaceSource":"spaces","widgets":[{"id":"spaces","type":"workspaces","position":"left"}]}
    """#)) == [.accessibility])
    #expect(registry.permissions(for: try configuration(#"""
    {"workspaceSource":"spaces","widgets":[{"id":"spaces","type":"workspaces","position":"left","enabled":false}]}
    """#)).isEmpty)
    for source in ["aerospace", "yabai", "omniwm", "rift"] {
        #expect(registry.permissions(for: try configuration(#"""
        {"workspaceSource":"\#(source)","widgets":[{"id":"spaces","type":"workspaces","position":"left"}]}
        """#)).isEmpty)
    }
    #expect(registry.permissions(for: nil).isEmpty)
    #expect(DataSourceRegistry.builtIn.permissions(for: try configuration(#"""
    {"providers":{"meetings":{"type":"calendar","calendars":["Work"]}},
     "widgets":[{"id":"work","type":"provider","provider":"meetings","position":"right"},{"id":"cpu","type":"system","position":"right"}]}
    """#)) == [.calendars])
    #expect(DataSourceRegistry.builtIn.permissions(for: try configuration(#"""
    {"providers":{"meetings":{"type":"calendar"}},"widgets":[{"id":"cpu","type":"system","position":"right"}]}
    """#)).isEmpty)
    #expect(DataSourceRegistry.builtIn.types.filter { $0.permission != nil }.map(\.name) == ["calendar"])
    let listed = ImageRenderer(content: VStack { SourcePermissionList(permissions: [calendars]) }.frame(width: 480))
    #expect((listed.nsImage?.size.height ?? 0) > 0)
    let empty = ImageRenderer(content: VStack { SourcePermissionList(permissions: []) }.frame(width: 480))
    #expect((empty.nsImage?.size.height ?? 0) == 0)
}
