import Foundation
import Observation
import os

/// Where a widget's output comes from: a command, a stream, a native reading or a native listener.
/// The runner (`ScriptWidget`) drives each run: it calls `start(emit:)`, then `refresh(event:)` with
/// the event that began the run, and `stop()` when the run ends, the widget suspends or it stops.
/// One source serves several runs: the runner may stop a source that never started, stop it twice
/// in one run, and start it again after it stopped.
@MainActor
protocol DataSource: AnyObject {
    /// Connects the source for one run. `emit` hands updates to the runner's single-slot queue and
    /// may be called from any thread: while the runner applies one update, only the newest waits.
    /// A failure ends the run: the runner applies the output sent before it, reports the failure
    /// and ignores later updates.
    func start(emit: @escaping @Sendable (SourceUpdate) -> Void)
    /// Produces output for `event`: runs a command, reads native data, or launches a stream.
    func refresh(event: ScriptEvent)
    /// Ends the run: cancels work, ends processes and removes listeners. Later updates are ignored,
    /// and stopping a source that has already stopped, or never started, does nothing.
    func stop()
}

/// What a data source reports to its runner.
enum SourceUpdate: Sendable {
    /// New output, or the reason there is none, with the process output behind it for diagnostics.
    case output(Result<ScriptOutput, any Error>, process: CommandResult? = nil)
    /// The run's work is done, such as a finished command. Sources that stay open never send it.
    case finished
}

/// How the runner paces a source.
struct SourceSchedule: Equatable, Sendable {
    /// Seconds between runs, or for a continuous source the first retry delay after a failure.
    /// `nil` runs only on events.
    var interval: Double?
    /// Runs stay open and the source sends updates as they happen, like a stream or a native
    /// listener. A refresh restarts the run.
    var continuous = false
    /// Notifications that refresh the source while it runs, such as calendar's
    /// `EKEventStoreChanged`.
    var change: SourceChange? = nil
}

/// Notifications that refresh a source, the centre they're posted on, and the event that refresh sends.
struct SourceChange: Equatable, Sendable {
    enum Center: Sendable {
        /// `NotificationCenter.default`.
        case standard
        /// `NSWorkspace.shared.notificationCenter`, where volume mounts are posted.
        case workspace
    }

    var notifications: [Notification.Name]
    var center: Center = .standard
    var event: String
}

/// Adapts a one-shot reading, such as a command or CPU usage, to a source: each refresh reads once
/// and finishes. The runner refreshes it every `interval`.
@MainActor
final class PollingSource: DataSource {
    private let read: @MainActor (ScriptEvent) async -> SourceUpdate
    private var emit: (@Sendable (SourceUpdate) -> Void)?
    private var task: Task<Void, Never>?

    init(read: @escaping @MainActor (ScriptEvent) async -> SourceUpdate) {
        self.read = read
    }

    func start(emit: @escaping @Sendable (SourceUpdate) -> Void) {
        self.emit = emit
    }

    func refresh(event: ScriptEvent) {
        task?.cancel()
        task = Task { [read, emit] in
            let update = await read(event)
            if Task.isCancelled { return }
            emit?(update)
            emit?(.finished)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        emit = nil
    }
}

extension PollingSource {
    /// A shell command run once per refresh, for script widgets and `command` providers.
    static func command(_ command: String, timeout: Double, environment: [String: String]) -> PollingSource {
        PollingSource { event in
            do {
                let result = try await runCommandResult("/bin/zsh", arguments: ["-c", command], timeout: timeout,
                                                        environment: event.commandEnvironment(environment))
                return .output(Result { try ScriptOutput.read(result.stdout) }, process: result)
            } catch {
                return .output(.failure(error))
            }
        }
    }
}

/// A command that prints one JSON object per line for as long as it runs. Malformed output and
/// exits end the run, and the runner restarts it with backoff.
@MainActor
final class StreamSource: DataSource {
    private let command: String
    private let environment: [String: String]
    private var emit: (@Sendable (SourceUpdate) -> Void)?
    private var task: Task<Void, Never>?

    init(command: String, environment: [String: String]) {
        self.command = command
        self.environment = environment
    }

    func start(emit: @escaping @Sendable (SourceUpdate) -> Void) {
        self.emit = emit
    }

    func refresh(event: ScriptEvent) {
        task?.cancel()
        task = Task { [command, environment, emit] in
            do {
                for try await line in await commandLines("/bin/zsh", arguments: ["-c", command],
                                                         environment: event.commandEnvironment(environment)) {
                    let output = Result { try JSONDecoder().decode(ScriptOutput.self, from: line.stdout) }
                    emit?(.output(output, process: line))
                    if case .failure = output { return }
                }
                if Task.isCancelled { return }
                emit?(.output(.failure(CommandFailure(message: "Streaming provider exited."))))
            } catch {
                if Task.isCancelled { return }
                emit?(.output(.failure(error)))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        emit = nil
    }
}

/// Native data that macOS reports changes to, such as the battery or the default audio device.
/// A push source reads it once per change. Tests replace it with a fake.
protocol ChangeMonitor: AnyObject, Sendable {
    /// Reads the current state. Called on the main actor.
    func read() throws -> ScriptOutput
    /// Calls `changed` on the main actor whenever the state may have changed, until `stop()`. A
    /// monitor that hears of changes on another thread hops to the main actor first, so that a
    /// change never runs between a refresh's read and its send. `start` and `stop` are called on
    /// the main actor. Like a data source, a monitor may be stopped before it starts or twice, and
    /// started again after it stops.
    func start(changed: @escaping @Sendable () -> Void) throws
    func stop()
}

/// Hands a monitor's changes from the thread that hears of them to the main queue. At most one hop
/// waits per run, so a burst of changes reads once, and a hop that arrives after its run stopped
/// is dropped, so `changed` never runs after `stop`.
final class MainQueueRelay: Sendable {
    private struct State {
        var run = 0
        var changed: (@Sendable () -> Void)?
        var waiting = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Starts a run that calls `changed` on the main queue, ending the one before it.
    func start(_ changed: @escaping @Sendable () -> Void) {
        state.withLock { $0 = State(run: $0.run + 1, changed: changed) }
    }

    func stop() {
        state.withLock { $0 = State(run: $0.run + 1) }
    }

    /// Reports a change from any thread. While a hop of this run waits for the main queue, it
    /// carries this change too.
    func notify() {
        let run: Int? = state.withLock { state in
            guard state.changed != nil, !state.waiting else { return nil }
            state.waiting = true
            return state.run
        }
        guard let run else { return }
        DispatchQueue.main.async { [state] in
            let changed = state.withLock { state -> (@Sendable () -> Void)? in
                guard state.run == run else { return nil }
                state.waiting = false
                return state.changed
            }
            changed?()
        }
    }
}

/// A source that updates when macOS reports a change, without a timer: its run stays open, reading
/// once when it starts and again after each change, and sends only reads that differ.
@MainActor
final class PushSource: DataSource {
    private let monitor: any ChangeMonitor
    /// The last output read, so a notification that changes nothing sends nothing. Only read on the
    /// main actor, where a monitor delivers changes; the lock lets the `@Sendable` closure share it.
    private let last = OSAllocatedUnfairLock<ScriptOutput?>(initialState: nil)
    private var emit: (@Sendable (SourceUpdate) -> Void)?

    init(monitor: any ChangeMonitor) {
        self.monitor = monitor
    }

    func start(emit: @escaping @Sendable (SourceUpdate) -> Void) {
        self.emit = emit
        let monitor = monitor
        let last = last
        do {
            try monitor.start {
                let output = Result { try monitor.read() }
                if case let .success(next) = output {
                    let changed = last.withLock { previous in
                        defer { previous = next }
                        return previous != next
                    }
                    guard changed else { return }
                }
                emit(.output(output))
            }
        } catch {
            emit(.output(.failure(error)))
        }
    }

    func refresh(event: ScriptEvent) {
        let output = Result { try monitor.read() }
        if case let .success(next) = output { last.withLock { $0 = next } }
        emit?(.output(output))
    }

    func stop() {
        monitor.stop()
        emit = nil
    }
}

/// Combines other providers: their `values`, `fields`, `lists` and `series` under each one's name, such as
/// `power.percent`, without text of its own. Its run stays open and sends again whenever one of them changes.
@MainActor
final class MergeSource: DataSource {
    private let inputs: [String]
    /// The runner of a provider while it runs.
    private let runner: @MainActor (String) -> ScriptWidget?
    private var emit: (@Sendable (SourceUpdate) -> Void)?

    init(inputs: [String], runner: @escaping @MainActor (String) -> ScriptWidget?) {
        self.inputs = inputs
        self.runner = runner
    }

    func start(emit: @escaping @Sendable (SourceUpdate) -> Void) {
        self.emit = emit
    }

    func refresh(event: ScriptEvent) {
        send()
    }

    func stop() {
        emit = nil
    }

    private func send() {
        guard let emit else { return }
        let outputs = withObservationTracking {
            inputs.compactMap { name in runner(name).map { (name, $0.output) } }
        } onChange: { [weak self] in
            // Observation reports a change before it's made.
            Task { @MainActor in self?.send() }
        }
        func prefixed<Value>(_ entries: KeyPath<ScriptOutput, [String: Value]?>) -> [String: Value] {
            Dictionary(outputs.flatMap { name, output in
                (output[keyPath: entries] ?? [:]).map { ("\(name).\($0.key)", $0.value) }
            }, uniquingKeysWith: { $1 })
        }
        emit(.output(.success(ScriptOutput(text: "", fields: prefixed(\.fields), lists: prefixed(\.lists),
                                           values: prefixed(\.values), series: prefixed(\.series)))))
    }
}
