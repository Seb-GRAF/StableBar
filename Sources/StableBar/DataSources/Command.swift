import Darwin
import Foundation
import os

let shellEnvironment = OSAllocatedUnfairLock(initialState: ProcessInfo.processInfo.environment)

/// Reads the environment a login shell exports. Right after login, a profile that runs `brew shellenv`,
/// keychain lookups or nvm can take far longer than usual, so a failed read is retried with backoff
/// until one succeeds: until then, commands get the app's own launchd `PATH`.
func readLoginShellEnvironment(shell: String = "/bin/zsh", timeout: Double = 60,
                               retryDelay: Double = 10) async throws -> [String: String] {
    var failures = 0
    while true {
        do {
            let output = try await runCommand(shell, arguments: ["-lc", "/usr/bin/env -0"], timeout: timeout)
            let variables = output.split(separator: 0).map { $0.split(separator: UInt8(ascii: "="), maxSplits: 1, omittingEmptySubsequences: false) }
            return Dictionary(uniqueKeysWithValues: variables.map { (String(decoding: $0[0], as: UTF8.self), String(decoding: $0[1], as: UTF8.self)) })
        } catch {
            try Task.checkCancellation()
            failures += 1
            FileHandle.standardError.write(Data("Couldn't read the login shell's environment: \(errorMessage(error))\n".utf8))
            try await Task.sleep(for: .seconds(providerRetryDelay(interval: retryDelay, failures: failures)))
        }
    }
}

extension Task {
    /// Whether the task finishes within `duration`. It keeps running either way.
    func finishes(within duration: Duration) async -> Bool {
        let (results, continuation) = AsyncStream.makeStream(of: Bool.self)
        Task<Void, Never> {
            _ = await result
            continuation.yield(true)
        }
        Task<Void, Never> {
            try? await Task<Never, Never>.sleep(for: duration)
            continuation.yield(false)
        }
        for await finished in results { return finished }
        return false
    }
}

/// The first executable file called `name` in the directories of `path`, a `PATH` value.
func executableFile(named name: String, path: String) -> URL? {
    path.split(separator: ":").lazy.map { URL(filePath: String($0)).appending(path: name) }.first {
        FileManager.default.isExecutableFile(atPath: $0.path)
            && (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true
    }
}

struct CommandFailure: LocalizedError {
    let message: String
    var stdout = Data()
    var stderr = Data()
    var timedOut = false
    /// Only a completed, unsuccessful exit is definitive; a timeout or signal leaves the outcome unknown.
    var exitStatus: Int32?
    var errorDescription: String? { message }
}

struct CommandResult: Sendable {
    var stdout: Data
    var stderr: Data
    var cpuTime: Double = 0
}

func runCommand(_ executable: String, arguments: [String], timeout: Double = 10,
                environment: [String: String] = [:]) async throws -> Data {
    try await runCommandResult(executable, arguments: arguments, timeout: timeout, environment: environment).stdout
}

func runCommandResult(_ executable: String, arguments: [String], timeout: Double = 10,
                      environment: [String: String] = [:]) async throws -> CommandResult {
    let command = CommandProcess()
    let result = try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            command.start(executable, arguments: arguments, timeout: timeout, environment: environment,
                          continuation: continuation)
        }
    } onCancel: {
        command.cancel()
    }
    try Task.checkCancellation()
    return result
}

func commandLines(_ executable: String, arguments: [String], environment: [String: String] = [:]) -> AsyncThrowingStream<CommandResult, Error> {
    AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { updates in
        let command = CommandProcess()
        let task = Task {
            do {
                _ = try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        command.start(executable, arguments: arguments, timeout: nil, environment: environment,
                                      onLine: { updates.yield($0) }, continuation: continuation)
                    }
                } onCancel: {
                    command.cancel()
                }
                updates.finish()
            } catch {
                updates.finish(throwing: error)
            }
        }
        updates.onTermination = { _ in task.cancel() }
    }
}

private final class CommandProcess: @unchecked Sendable {
    private let queue = DispatchQueue(label: "StableBar.Command")
    private var continuation: CheckedContinuation<CommandResult, Error>?
    private var onLine: (@Sendable (CommandResult) -> Void)?
    private var processGroup: pid_t = 0
    private var processSource: DispatchSourceProcess?
    private var outputSources: [DispatchSourceRead] = []
    private var timer: DispatchSourceTimer?
    private var stdout = Data()
    private var stderr = Data()
    private var lastLine = Data()
    private var cpuTime = 0.0
    private var closedStreams = 0
    private var exitStatus: Int32?
    private var failure: Error?

    func start(_ executable: String, arguments: [String], timeout: Double?, environment: [String: String],
               onLine: (@Sendable (CommandResult) -> Void)? = nil,
               continuation: CheckedContinuation<CommandResult, Error>) {
        queue.async { [self] in
            self.continuation = continuation
            self.onLine = onLine
            if let failure {
                self.continuation = nil
                continuation.resume(throwing: failure)
                return
            }
            let output = Pipe()
            let errors = Pipe()
            let pipes = [output, errors]
            var actions: posix_spawn_file_actions_t?
            var attributes: posix_spawnattr_t?
            posix_spawn_file_actions_init(&actions)
            posix_spawnattr_init(&attributes)
            defer {
                posix_spawn_file_actions_destroy(&actions)
                posix_spawnattr_destroy(&attributes)
            }
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT |
                                                       POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
            posix_spawnattr_setpgroup(&attributes, 0)
            var signals = sigset_t()
            sigemptyset(&signals)
            posix_spawnattr_setsigmask(&attributes, &signals)
            sigfillset(&signals)
            posix_spawnattr_setsigdefault(&attributes, &signals)
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
            posix_spawn_file_actions_adddup2(&actions, output.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
            posix_spawn_file_actions_adddup2(&actions, errors.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
            var variables = shellEnvironment.withLock { $0 }
            variables.merge(environment) { _, value in value }
            var argv = ([executable] + arguments).map { strdup($0) } + [nil]
            var envp = variables.map { strdup("\($0.key)=\($0.value)") } + [nil]
            defer {
                argv.forEach { free($0) }
                envp.forEach { free($0) }
            }
            let result = posix_spawn(&processGroup, executable, &actions, &attributes, &argv, &envp)
            for pipe in pipes { pipe.fileHandleForWriting.closeFile() }
            guard result == 0 else {
                for pipe in pipes { pipe.fileHandleForReading.closeFile() }
                processGroup = 0
                self.continuation = nil
                continuation.resume(throwing: CommandFailure(message: String(cString: strerror(result))))
                return
            }
            for (index, pipe) in pipes.enumerated() {
                let handle = pipe.fileHandleForReading
                let source = DispatchSource.makeReadSource(fileDescriptor: handle.fileDescriptor, queue: queue)
                source.setEventHandler { [self] in
                    var buffer = [UInt8](repeating: 0, count: 8192)
                    let count = read(handle.fileDescriptor, &buffer, buffer.count)
                    if count == -1 && errno == EINTR { return }
                    if count == -1 {
                        terminate(CommandFailure(message: String(cString: strerror(errno))))
                        return
                    }
                    if count == 0 {
                        outputSources[index].cancel()
                        closedStreams += 1
                        finish()
                    } else if failure == nil {
                        let size = index == 0 ? stdout.count : stderr.count
                        if onLine != nil && index == 0 {
                            stdout.append(buffer, count: count)
                            while let newline = stdout.firstIndex(of: 10) {
                                let line = Data(stdout[..<newline])
                                stdout.removeSubrange(...newline)
                                if line.count > 1_048_576 {
                                    terminate(CommandFailure(message: "Provider line exceeded 1 MiB."))
                                    return
                                }
                                if !line.isEmpty {
                                    lastLine = line
                                    onLine!(CommandResult(stdout: line, stderr: stderr))
                                }
                            }
                            if stdout.count > 1_048_576 {
                                terminate(CommandFailure(message: "Provider line exceeded 1 MiB."))
                            }
                        } else if onLine != nil {
                            stderr.append(buffer, count: count)
                            stderr = Data(stderr.suffix(16_384))
                        } else if size + count > 1_048_576 {
                            terminate(CommandFailure(message: "Command output exceeded 1 MiB."))
                        } else if index == 0 {
                            stdout.append(buffer, count: count)
                        } else {
                            stderr.append(buffer, count: count)
                        }
                    }
                }
                source.setCancelHandler { handle.closeFile() }
                outputSources.append(source)
                source.resume()
            }
            let process = DispatchSource.makeProcessSource(identifier: processGroup, eventMask: .exit, queue: queue)
            process.setEventHandler { [self] in
                var status: Int32 = 0
                var usage = rusage()
                while wait4(processGroup, &status, 0, &usage) == -1 && errno == EINTR {}
                cpuTime = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                    + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
                exitStatus = status
                processSource!.cancel()
                if onLine != nil {
                    kill(-processGroup, SIGKILL)
                    self.timer?.schedule(deadline: .now() + 1)
                }
                finish()
            }
            processSource = process
            process.resume()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: timeout.map { .now() + $0 } ?? .distantFuture)
            timer.setEventHandler { [self] in
                let message = timeout.map { "Command timed out after \($0) seconds." }
                    ?? "Provider exited while a child kept its output open."
                terminate(CommandFailure(message: message, timedOut: timeout != nil))
            }
            self.timer = timer
            timer.resume()
        }
    }

    func cancel() {
        queue.async { self.terminate(CancellationError()) }
    }

    private func terminate(_ error: Error) {
        if failure == nil { failure = error }
        if processGroup != 0 {
            kill(-processGroup, SIGKILL)
            if exitStatus == nil { kill(processGroup, SIGKILL) }
            for source in outputSources { source.cancel() }
            closedStreams = 2
            finish()
        }
    }

    private func finish() {
        guard let exitStatus, closedStreams == 2 else { return }
        let continuation = continuation!
        self.continuation = nil
        processGroup = 0
        timer!.cancel()
        timer = nil
        processSource = nil
        outputSources.removeAll()
        if var failure = failure as? CommandFailure {
            failure.stdout = onLine == nil ? stdout : lastLine
            failure.stderr = stderr
            continuation.resume(throwing: failure)
        } else if let failure {
            continuation.resume(throwing: failure)
        } else if exitStatus != 0 {
            let message = String(decoding: stderr.isEmpty ? stdout : stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let status = exitStatus & 0x7f == 0
                ? "Command exited with status \(exitStatus >> 8)."
                : "Command terminated by signal \(exitStatus & 0x7f)."
            continuation.resume(throwing: CommandFailure(message: message.isEmpty ? status : message,
                                                       stdout: onLine == nil ? stdout : lastLine, stderr: stderr,
                                                       exitStatus: exitStatus & 0x7f == 0 ? exitStatus >> 8 : nil))
        } else {
            if let onLine, !stdout.isEmpty {
                onLine(CommandResult(stdout: stdout, stderr: stderr, cpuTime: cpuTime))
            }
            continuation.resume(returning: CommandResult(stdout: stdout, stderr: stderr, cpuTime: cpuTime))
        }
    }
}
