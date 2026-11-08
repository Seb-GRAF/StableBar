import Foundation
import Observation
import os

struct ScriptEvent: Sendable {
    var sender: String
    var environment: [String: String] = [:]

    func commandEnvironment(_ configured: [String: String], secret: @Sendable (String) -> String = packageSecret) async -> [String: String] {
        // A source's token belongs to its requests only; configuration can't read it.
        let resolved = configured.mapValues { value in
            guard value.hasPrefix("@secret.") else { return value }
            let account = String(value.dropFirst("@secret.".count))
            return account.hasPrefix("source:") ? "" : secret(account)
        }
        var variables = resolved.merging(environment) { _, event in event }
        variables["NAME"] = configured["NAME"]
        variables["CONFIG_DIR"] = configured["CONFIG_DIR"]
        variables["SENDER"] = sender
        return variables
    }
}

struct WidgetMenuItem: Decodable, Equatable, Sendable {
    let title: String
    var detail: String?
    var onClick: String?

    enum CodingKeys: String, CodingKey, CaseIterable { case title, detail, onClick }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        title = try values.decode(String.self, forKey: .title)
        detail = try values.decodeIfPresent(String.self, forKey: .detail)
        onClick = try values.decodeIfPresent(String.self, forKey: .onClick)
    }
}

struct ScriptOutput: Decodable, Equatable, Sendable {
    var text: String
    var icon: String?
    var color: HexColor?
    var tooltip: String?
    var hidden: Bool?
    var menu: [WidgetMenuItem]?
    var value: Double?
    var fields: [String: String]?
    var lists: [String: [[String: String]]]?
    var values: [String: Double]?
    var targets: [String: Double]?
    var style: WidgetStyle?
    var styles: [String: WidgetStyle]?
    var barStyle: WidgetStyle?
    var animation: WidgetAnimation?
    var display: DisplaySelection?
    var series: [String: [Double]]?
    var onClick: String?
    var widgetStyles: [String: WidgetStyle]?
    var interval: Double?
    /// The widget's data state. Earlier versions ignored this field, so any JSON value decodes;
    /// `dataState(_:rules:)` uses only a string.
    var state: ConfigurationValue?
    /// Fields shown over this output's own for a while, such as the volume after a change.
    var temporary: TemporaryOutput?

    static func read(_ data: Data) throws -> ScriptOutput {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("{") {
            var output = try JSONDecoder().decode(ScriptOutput.self, from: data)
            output.series = output.series?.mapValues { Array($0.suffix(60)) }
            return output
        }
        return ScriptOutput(text: text)
    }
}

/// Fields an output shows over its own for `duration` seconds before the widget returns to it.
struct TemporaryOutput: Decodable, Equatable, Sendable {
    let fields: [String: String]
    let duration: Double

    static let longestDuration = 86_400.0

    enum CodingKeys: String, CodingKey, CaseIterable { case fields, duration }

    init(fields: [String: String], duration: Double) {
        self.fields = fields
        self.duration = duration
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fields = try values.decode([String: String].self, forKey: .fields)
        duration = try values.decode(Double.self, forKey: .duration)
        guard duration > 0, duration <= Self.longestDuration else {
            throw DecodingError.dataCorruptedError(forKey: .duration, in: values,
                                                   debugDescription: "A temporary duration must be greater than zero and at most one day (86400 seconds).")
        }
    }
}

@MainActor @Observable
final class ScriptWidget {
    var output = ScriptOutput(text: "…")
    var error: String?
    var samples: [Double] = []
    var diagnostics = ScriptDiagnostics()
    /// Called when the output or the error changes, so the store can re-resolve the styles it affects,
    /// and for each output with a `temporary`, which the store shows again after it ran out.
    @ObservationIgnored var onUpdate: (() -> Void)?
    /// Called when an output replaces an earlier one, so the store can send the events that a data
    /// source's changes stand for, such as `powerSourceChange`.
    @ObservationIgnored var onOutputChange: ((_ previous: ScriptOutput, _ output: ScriptOutput) -> Void)?
    /// Numbers each accepted output, unique across scripts, so the store can tell a new output from
    /// one it applies again. 0 before the first.
    @ObservationIgnored private(set) var outputNumber = 0
    private static var acceptedOutputs = 0
    private var task: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var events: AsyncStream<ScriptEvent>.Continuation?
    private var makeSource: (@MainActor () -> any DataSource)?
    private var source: (any DataSource)?
    private var schedule = SourceSchedule()
    private var changeObserver: (any NSObjectProtocol)?
    /// A continuous run open this long is steady: an update it sends, or the failure that ends it,
    /// starts a new failure streak. Tests shorten it.
    @ObservationIgnored var steadyRun: Duration = .seconds(10)
    /// What runs are timed with and the next run waits on; tests set a clock they advance themselves.
    @ObservationIgnored var clock: any Clock<Duration> = ContinuousClock()

    func start(command: String, interval: Double?, timeout: Double = 10, environment: [String: String] = [:]) {
        start(schedule: SourceSchedule(interval: interval)) {
            PollingSource.command(command, timeout: timeout, environment: environment)
        }
    }

    func start(provider: ProviderConfiguration, registry: DataSourceRegistry = .builtIn, environment: [String: String] = [:]) {
        var variables = environment.merging(provider.environment) { _, value in value }
        variables["NAME"] = environment["NAME"]
        variables["CONFIG_DIR"] = environment["CONFIG_DIR"]
        guard let type = registry[provider.type] else {
            stop()
            error = "Unknown data source type: \(provider.type)."
            return
        }
        let change = type.changeNotification.map { SourceChange(notification: $0, event: type.name) }
        start(schedule: SourceSchedule(interval: provider.interval, continuous: type.continuous, change: change)) {
            type.makeSource(provider, variables)
        }
    }

    /// Runs the source that `makeSource` creates. A fresh instance runs at startup, on resume and
    /// when a refresh restarts a continuous source. While it runs, the schedule's `change`
    /// notification refreshes it.
    func start(schedule: SourceSchedule, source makeSource: @escaping @MainActor () -> any DataSource) {
        stop()
        self.schedule = schedule
        self.makeSource = makeSource
        begin(ScriptEvent(sender: "startup"))
    }

    private func begin(_ firstEvent: ScriptEvent) {
        guard let makeSource else { return }
        let source = makeSource()
        let schedule = schedule
        self.source = source
        diagnostics.suspended = false
        if let change = schedule.change, changeObserver == nil {
            changeObserver = NotificationCenter.default.addObserver(forName: change.notification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh(ScriptEvent(sender: change.event)) }
            }
        }
        let (stream, events) = AsyncStream<ScriptEvent>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.events = events
        events.yield(firstEvent)
        task = Task {
            for await event in stream {
                if Task.isCancelled { return }
                timer?.cancel()
                diagnostics.running = true
                diagnostics.nextDelay = nil
                diagnostics.lastEvent = event.sender
                diagnostics.lastStarted = Date()
                diagnostics.executionCount += 1
                let elapsed = clock.stopwatch()
                var delay = schedule.interval
                // The single-slot queue: while an update is being applied, only the newest waits. A
                // failure ends the run, so it waits outside the slot until the output sent before it is applied.
                let (updates, queue) = AsyncStream<SourceUpdate>.makeStream(bufferingPolicy: .bufferingNewest(1))
                let failure = OSAllocatedUnfairLock<(any Error, CommandResult?)?>(initialState: nil)
                source.start { update in
                    if case let .output(.failure(error), process) = update {
                        failure.withLock { $0 = $0 ?? (error, process) }
                        queue.finish()
                    } else if case .finished = update { queue.finish() } else { queue.yield(update) }
                }
                source.refresh(event: event)
                do {
                    for await update in updates {
                        try Task.checkCancellation()
                        guard case let .output(result, process) = update else { continue }
                        if let process { record(process) }
                        try accept(result.get())
                        if schedule.continuous, elapsed() >= steadyRun { diagnostics.consecutiveFailures = 0 }
                    }
                    try Task.checkCancellation()
                    if case let (error, process)? = failure.withLock({ $0 }) {
                        if let process { record(process) }
                        throw error
                    }
                    diagnostics.consecutiveFailures = 0
                    if delay != nil { delay = output.interval ?? delay }
                } catch {
                    if Task.isCancelled { return }
                    let message = error.localizedDescription
                    if self.error != message {
                        self.error = message
                        onUpdate?()
                    }
                    diagnostics.failureCount += 1
                    if schedule.continuous, elapsed() >= steadyRun { diagnostics.consecutiveFailures = 0 }
                    diagnostics.consecutiveFailures += 1
                    if let failure = error as? CommandFailure {
                        if !failure.stdout.isEmpty { diagnostics.lastStdout = String(decoding: failure.stdout.suffix(16_384), as: UTF8.self) }
                        if !failure.stderr.isEmpty { diagnostics.lastStderr = String(decoding: failure.stderr.suffix(16_384), as: UTF8.self) }
                    }
                    if let interval = delay {
                        delay = providerRetryDelay(interval: interval, failures: diagnostics.consecutiveFailures)
                    }
                }
                source.stop()
                let duration = elapsed().components
                diagnostics.lastDuration = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
                diagnostics.running = false
                diagnostics.nextDelay = delay
                if let delay {
                    timer = Task {
                        do {
                            try await clock.sleep(for: .seconds(delay))
                            try Task.checkCancellation()
                            if schedule.continuous { diagnostics.restartCount += 1 }
                            events.yield(ScriptEvent(sender: "routine"))
                        } catch {}
                    }
                }
            }
        }
    }

    private func record(_ result: CommandResult) {
        diagnostics.lastStdout = String(decoding: result.stdout.suffix(16_384), as: UTF8.self)
        diagnostics.lastStderr = String(decoding: result.stderr.suffix(16_384), as: UTF8.self)
        diagnostics.cpuTime += result.cpuTime
    }

    /// Applies a source's new output. Only what changed is assigned, so an update that repeats the
    /// current output invalidates no views; its `value` still adds a graph sample, and its `temporary`
    /// still reaches the store, so it can show again after it ran out.
    func accept(_ next: ScriptOutput) throws {
        if let interval = next.interval, !interval.isFinite || interval <= 0 {
            throw CommandFailure(message: "A script interval must be greater than zero.")
        }
        var next = next
        next.series = next.series?.mapValues { Array($0.suffix(60)) }
        let previous = diagnostics.lastUpdated == nil ? nil : output
        let outputChanged = next != output
        let changed = outputChanged || error != nil
        if outputChanged { output = next }
        if let value = next.value {
            let history = Array((samples + [value]).suffix(60))
            if history != samples { samples = history }
        }
        if error != nil { error = nil }
        diagnostics.lastUpdated = Date()
        Self.acceptedOutputs += 1
        outputNumber = Self.acceptedOutputs
        if changed || next.temporary != nil { onUpdate?() }
        if let previous, outputChanged { onOutputChange?(previous, next) }
    }

    func refresh(_ event: ScriptEvent) {
        if makeSource == nil || diagnostics.suspended { return }
        if schedule.continuous {
            cancel()
            diagnostics.restartCount += 1
            begin(event)
        } else {
            timer?.cancel()
            events?.yield(event)
        }
    }

    func suspend() {
        if makeSource == nil || diagnostics.suspended { return }
        cancel()
        diagnostics.suspended = true
    }

    func resume() {
        if !diagnostics.suspended { return }
        begin(ScriptEvent(sender: "resume"))
    }

    private func cancel() {
        task?.cancel()
        timer?.cancel()
        events?.finish()
        source?.stop()
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        task = nil
        timer = nil
        events = nil
        source = nil
        changeObserver = nil
        diagnostics.running = false
        diagnostics.nextDelay = nil
    }

    func stop() {
        cancel()
        makeSource = nil
        diagnostics.suspended = false
    }
}

private extension Clock where Duration == Swift.Duration {
    /// Starts measuring on this clock: each call of what it returns gives the time since.
    func stopwatch() -> () -> Swift.Duration {
        let start = now
        return { start.duration(to: self.now) }
    }
}
