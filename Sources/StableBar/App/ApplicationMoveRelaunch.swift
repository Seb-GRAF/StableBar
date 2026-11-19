import AppKit
import Foundation

/// Sparkle owns update relaunches; a move needs its own helper. Like Uninstall, it uses a detached process, with no
/// shell interpolation. The helper acknowledges it is ready before the bar quits, then waits for that PID's exit.
enum ApplicationMoveRelaunch {
    struct Plan: Codable, Sendable {
        var transaction: ApplicationMoveTransaction
        var resume: ApplicationMoveResume
        var resumeStore: ApplicationMoveResumeStore
        var arguments: [String]
    }

    static func arguments(_ arguments: [String], configuration: URL) -> [String] {
        var arguments = arguments
        // Finder launches from a different working directory, so resolve an explicit relative --config too.
        if arguments.first == "--config", arguments.count >= 2 { arguments.removeFirst(2) }
        return ["--config", configuration.standardizedFileURL.path] + arguments
    }

    static func prepare(_ transaction: ApplicationMoveTransaction, resume: ApplicationMoveResume,
                        store: ApplicationMoveResumeStore = ApplicationMoveResumeStore(),
                        arguments: [String] = Array(CommandLine.arguments.dropFirst()),
                        spawn: @Sendable (String, [String]) throws -> Void = { try spawnDetached($0, arguments: $1) }) async throws {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appending(path: "StableBar-relaunch-\(UUID().uuidString)")
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let planURL = directory.appending(path: "plan.json")
        do {
            try store.save(resume)
            let plan = Plan(transaction: transaction, resume: resume, resumeStore: store,
                            arguments: self.arguments(arguments, configuration: resume.configuration))
            try JSONEncoder().encode(plan).write(to: planURL, options: .atomic)
            let identity = try ApplicationBundleIdentity(at: transaction.source)
            try spawn(transaction.source.appending(path: "Contents/MacOS/\(identity.executable)").path,
                      ["--finish-application-move", planURL.path, String(getpid())])
            // Only this user-initiated transition waits; never on the main actor or in steady state.
            for _ in 0..<200 {
                if files.fileExists(atPath: directory.appending(path: "ready").path) { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw CommandFailure(message: "The relaunch helper didn’t start. Try again or move StableBar with Finder.")
        } catch {
            try? files.removeItem(at: directory)
            try? store.discard()
            throw error
        }
    }

    static func finish(planURL: URL, parent: pid_t) async -> Int32 {
        let directory = planURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let plan = try JSONDecoder().decode(Plan.self, from: Data(contentsOf: planURL))
            do {
                try await ApplicationMoveExitWaiter().wait(for: parent, ready: directory.appending(path: "ready"))
            } catch {
                guard FileManager.default.fileExists(atPath: planURL.path) else { return 0 }
                try await plan.transaction.rollback(using: ApplicationMoveSystem())
                try plan.resumeStore.discard()
                throw error
            }
            // A failed/cancelled preparation removes this file and leaves the original process running.
            guard FileManager.default.fileExists(atPath: planURL.path) else { return 0 }
            let note = try await complete(plan, using: ApplicationMoveSystem()) { app, arguments in
                _ = try await runCommand("/usr/bin/open", arguments: ["-n", app.path, "--args"] + arguments, timeout: 15)
            }
            if let note {
                CFUserNotificationDisplayAlert(0, kCFUserNotificationNoteAlertLevel, nil, nil, nil,
                                               "Moving StableBar" as CFString, note as CFString,
                                               "OK" as CFString, nil, nil, nil)
            }
            return 0
        } catch {
            guard FileManager.default.fileExists(atPath: planURL.path) else { return 0 }
            CFUserNotificationDisplayAlert(0, kCFUserNotificationCautionAlertLevel, nil, nil, nil,
                                           "StableBar couldn’t finish moving" as CFString,
                                           ("\(errorMessage(error)) Open StableBar with Finder to continue.") as CFString,
                                           "OK" as CFString, nil, nil, nil)
            return 1
        }
    }

    /// Separately injectable so tests exercise a failed launch and its recovery without opening any application.
    @discardableResult
    static func complete(_ plan: Plan, using system: ApplicationMoveSystem,
                         pause: @Sendable () async throws -> Void = { try await Task.sleep(for: .milliseconds(500)) },
                         saveResume: @Sendable (ApplicationMoveResumeStore, ApplicationMoveResume) throws -> Void = { try $0.save($1) },
                         launch: @Sendable (URL, [String]) async throws -> Void) async throws -> String? {
        var exitedWithError = false
        do {
            try await launch(plan.transaction.destination, plan.arguments)
        } catch {
            exitedWithError = (error as? CommandFailure)?.exitStatus != nil
        }
        if exitedWithError, !(await system.isRunning(plan.transaction.destination)) {
            try await plan.transaction.rollback(using: system)
            // A failed `open` can still have handed off a launch. Check immediately after restoring the old copy.
            guard !(await system.isRunning(plan.transaction.destination)) else {
                return "The copy in Applications is now running. \(plan.transaction.originalNote(using: system))"
            }
            var resume = plan.resume
            resume.timestamp = Date()
            resume.setup?.openAtLogin = nil
            resume.failure = "Couldn’t open StableBar in Applications. \(plan.transaction.originalNote(using: system)) Try again or use Finder."
            var recoveryNote: String?
            do { try saveResume(plan.resumeStore, resume) }
            catch { recoveryNote = "Couldn’t restore where setup left off. Open Getting Started or Settings to continue." }
            guard !(await system.isRunning(plan.transaction.destination)) else {
                return "The copy in Applications is now running. \(plan.transaction.originalNote(using: system))\(recoveryNote.map { " \($0)" } ?? "")"
            }
            do { try await launch(plan.transaction.source, plan.arguments) }
            catch {
                guard let recoveryNote else { throw error }
                throw CommandFailure(message: "\(errorMessage(error)) \(recoveryNote) \(plan.transaction.originalNote(using: system))")
            }
            return recoveryNote
        }
        // An exit of 0 only means `open` accepted the request. Timeouts and other unknown outcomes may launch late.
        // Poll only during this one-off handoff; never undo an uncertain launch or start a second bar.
        var running = await system.isRunning(plan.transaction.destination)
        for _ in 0..<10 {
            if running { break }
            try await pause()
            running = await system.isRunning(plan.transaction.destination)
        }
        guard running else {
            return "Couldn’t confirm that StableBar opened. The copy in Applications is at \(plan.transaction.destination.path). \(plan.transaction.originalNote(using: system))\(plan.transaction.previousCopyNote(using: system)) Open StableBar from Applications with Finder to continue."
        }
        // Only a confirmed running copy permits cleanup. Failures leave recoverable copies and a calm note.
        return plan.transaction.finish(using: system)
    }
}

/// An event, not a polling loop: nothing launches until the parent process really has exited.
final class ApplicationMoveExitWaiter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "StableBar.MoveRelaunch")
    private var source: DispatchSourceProcess?
    private var timer: DispatchSourceTimer?
    private var continuation: CheckedContinuation<Void, Error>?

    func wait(for pid: pid_t, ready: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                self.continuation = continuation
                let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
                self.source = source
                source.setEventHandler { [self] in finish(nil) }
                let timer = DispatchSource.makeTimerSource(queue: queue)
                self.timer = timer
                timer.schedule(deadline: .now() + 60)
                timer.setEventHandler { [self] in
                    finish(CommandFailure(message: "StableBar didn’t quit, so the other copy was not opened."))
                }
                source.resume()
                timer.resume()
                do { try Data().write(to: ready, options: .atomic) } catch { finish(error); return }
                if kill(pid, 0) != 0 && errno == ESRCH { finish(nil) }
            }
        }
    }

    private func finish(_ error: (any Error)?) {
        source?.cancel()
        source = nil
        timer?.cancel()
        timer = nil
        let reply = continuation
        continuation = nil
        if let error { reply?.resume(throwing: error) } else { reply?.resume() }
    }
}
