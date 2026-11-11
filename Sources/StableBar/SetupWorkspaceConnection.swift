import Foundation
import Observation

/// These results are advice only: a workspace connection never prevents finishing setup.
enum SetupWorkspaceResult: Equatable, Sendable {
    case checking, connected
    case signalsMissing(configuration: String)
    case reloadYabai(configuration: String)
    case ipcOff
    case couldntCheck(String)
}

/// A check lives only while Finishing touches shows. Repeated activation events share an in-flight check.
@MainActor @Observable
final class SetupWorkspaceConnection {
    private(set) var result = SetupWorkspaceResult.checking
    private(set) var source: WorkspaceSource?
    private(set) var isChecking = false
    var showsSignals = false
    @ObservationIgnored private var task: Task<Void, Never>?
    private let check: @Sendable (WorkspaceSource) async -> SetupWorkspaceResult

    init(check: @escaping @Sendable (WorkspaceSource) async -> SetupWorkspaceResult) {
        self.check = check
    }

    func show(_ source: WorkspaceSource?) {
        hide()
        self.source = source
        result = .checking
        checkAgain()
    }

    func checkAgain() {
        guard let source, task == nil else { return }
        isChecking = true
        let check = check
        task = Task { [weak self] in
            let work = Task.detached(priority: .utility) { await check(source) }
            let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled else { return }
            self?.result = result
            self?.isChecking = false
            self?.task = nil
        }
    }

    func hide() {
        task?.cancel()
        task = nil
        isChecking = false
        source = nil
    }

    deinit { task?.cancel() }
}

/// Uses the already-resolved login environment, never a new login shell that might take a minute to start.
/// All lookup, config reads and IPC run away from the main actor, with a deadline covering the whole check.
struct SetupWorkspaceChecker: Sendable {
    var configurationURL: URL
    var environment: @Sendable () -> [String: String] = { shellEnvironment.withLock { $0 } }
    var executable: @Sendable (WorkspaceSource, String) -> String? = { $0.executable(path: $1) }
    var isRunning: @Sendable (WorkspaceSource) -> Bool = { $0.isRunning }
    var timeout = 3.0
    var clock: any Clock<Duration> = ContinuousClock()

    func check(_ source: WorkspaceSource) async -> SetupWorkspaceResult {
        let unverified = SetupWorkspaceResult.couldntCheck("Couldn’t check \(source.title) just now. Check that it’s running, then try again.")
        let (results, continuation) = AsyncStream.makeStream(of: SetupWorkspaceResult.self, bufferingPolicy: .bufferingOldest(1))
        let work = Task {
            let result: SetupWorkspaceResult
            do { result = try await inspect(source) }
            catch let failure as OmniWMFailure where failure.code == "transport_failure" { result = .ipcOff }
            catch { result = unverified }
            continuation.yield(result)
            continuation.finish()
        }
        let deadline = Task {
            do {
                try await clock.sleep(for: .seconds(timeout))
                continuation.yield(unverified)
                continuation.finish()
            } catch { }
        }
        // Don't await cancelled work here: even executable lookup can stall on a disconnected network volume.
        return await withTaskCancellationHandler {
            defer { work.cancel(); deadline.cancel(); continuation.finish() }
            for await result in results { return result }
            return unverified
        } onCancel: {
            work.cancel()
            deadline.cancel()
            continuation.finish()
        }
    }

    private func inspect(_ source: WorkspaceSource) async throws -> SetupWorkspaceResult {
        try Task.checkCancellation()
        if source == .omniwm && !isRunning(source) {
            return .couldntCheck("OmniWM isn’t running. Open OmniWM, then check again.")
        }
        let variables = environment()
        guard let executable = executable(source, variables["PATH", default: ""]) else {
            return .couldntCheck("\(source == .omniwm ? "omniwmctl" : source.title) isn’t available yet. Check your login shell’s PATH, then try again.")
        }
        try Task.checkCancellation()
        if source == .omniwm {
            _ = try await readOmniWMWorkspaces(executable, screenIDs: [], timeout: timeout)
            return .connected
        }
        guard source == .yabai else { return .connected }
        _ = try await readYabaiWorkspaces(executable, screenIDs: [], bundleIDs: [:], timeout: timeout)
        let signals = try await runCommand(executable, arguments: ["-m", "signal", "--list"], timeout: timeout)
        let registered = try JSONDecoder().decode([YabaiSetupSignals.Signal].self, from: signals)
        let active = Set(registered.filter { $0.isRefresh(for: configurationURL) }.map(\.event))
        let loaded = Set(YabaiSetupSignals.events).isSubset(of: active)
        let home = variables["HOME"].map { URL(filePath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
        let configuration = try YabaiSetupSignals.configuration(home: home, xdg: variables["XDG_CONFIG_HOME"])
        guard let configuration else {
            return loaded
                ? .couldntCheck("yabai’s refresh signals are loaded, but no default config was found. Check your custom config with the yabai guide.")
                : .signalsMissing(configuration: home.appending(path: ".yabairc").path)
        }
        let text: String
        do {
            guard try configuration.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw CommandFailure(message: "Not a regular yabai configuration file.")
            }
            let handle = try FileHandle(forReadingFrom: configuration)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 262_145) ?? Data()
            guard data.count <= 262_144, let contents = String(data: data, encoding: .utf8) else {
                throw CommandFailure(message: "Unreadable yabai configuration.")
            }
            text = contents
        } catch {
            return .couldntCheck("Couldn’t read \(configuration.path). Check the yabai signals in the guide, then try again.")
        }
        try Task.checkCancellation()
        let saved = YabaiSetupSignals.savedEvents(in: text, for: configurationURL)
        guard Set(YabaiSetupSignals.events).isSubset(of: saved) else {
            // Sourced scripts and computed shell commands cannot be verified without executing the person's config.
            let commands = YabaiSetupSignals.commands(in: text)
            if loaded {
                return .couldntCheck("yabai’s refresh signals are loaded, but couldn’t confirm them in \(configuration.path). Check the yabai guide.")
            }
            if commands.contains(where: { $0.first == "." || $0.first == "source" }) {
                return .couldntCheck("\(configuration.path) loads another script. Check its refresh signals with the yabai guide.")
            }
            return .signalsMissing(configuration: configuration.path)
        }
        return loaded ? .connected : .reloadYabai(configuration: configuration.path)
    }
}

/// The guide's signals, shared by the passive config check and the exact lines setup copies. Configs are read only;
/// even a sourced script is never executed. Custom shell logic that this small reader cannot confirm stays unverified.
enum YabaiSetupSignals {
    static let events = [
        "space_changed", "space_created", "space_destroyed", "display_changed", "display_added", "display_removed", "display_moved",
        "window_created", "window_destroyed", "window_focused", "window_moved", "window_minimized", "window_deminimized",
        "window_title_changed", "application_hidden", "application_visible", "system_woke"
    ]

    /// yabai's get_config_file order: XDG first, then ~/.config, then the legacy dotfile.
    static func configuration(home: URL, xdg: String?) throws -> URL? {
        var candidates: [URL] = []
        if let xdg, !xdg.isEmpty { candidates.append(URL(filePath: xdg).appending(path: "yabai/yabairc")) }
        candidates += [home.appending(path: ".config/yabai/yabairc"), home.appending(path: ".yabairc")]
        for url in candidates {
            do {
                if try url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]).isDirectory == false { return url }
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile { continue }
        }
        return nil
    }

    static func script(executable: String = "/Applications/StableBar.app/Contents/MacOS/StableBar") -> String {
        // Broadcast even for custom configurations: frequent signals must not wait for a runtime snapshot reply.
        let action = "\(quote(executable)) --trigger yabai"
        return """
        for event in \(events[0..<7].joined(separator: " ")) \\
                     \(events[7..<14].joined(separator: " ")) \\
                     \(events[14...].joined(separator: " ")); do
          yabai -m signal --add label="stablebar-$event" event="$event" \\
            action=\(quote(action))
        done
        """
    }

    private static func quote(_ word: String) -> String {
        if !word.isEmpty && word.allSatisfy({ $0.isLetter || $0.isNumber || "/._-:".contains($0) }) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    struct Signal: Decodable {
        let event: String
        let action: String
        var app: String?
        var title: String?
        var active: Bool?

        func isRefresh(for configuration: URL) -> Bool {
            (app ?? "").isEmpty && (title ?? "").isEmpty && active == nil && isTrigger(action, for: configuration)
        }
    }

    private static func isTrigger(_ action: String, for configuration: URL) -> Bool {
        for var words in commands(in: action) {
            if words.first == "exec" { words.removeFirst() }
            guard let executable = words.first, URL(filePath: executable).lastPathComponent.lowercased() == "stablebar",
                  let command = try? LaunchCommand(arguments: Array(words.dropFirst())) else { continue }
            switch command {
            case .trigger("yabai", _): return true // Without --config, the event reaches every running bar.
            case let .control(url, request) where request.action == .trigger && request.id == "yabai":
                if url.resolvingSymlinksInPath().standardizedFileURL
                    == configuration.resolvingSymlinksInPath().standardizedFileURL { return true }
            default: break
            }
        }
        return false
    }

    /// Recognizes explicit signal commands and the guide's for-loop, including quotes, continuations and comments.
    static func savedEvents(in text: String, for configuration: URL) -> Set<String> {
        var loops: [String: [String]] = [:]
        var found = Set<String>()
        for var words in commands(in: text) {
            if words.first == "for", words.count > 3, words[2] == "in" { loops[words[1]] = Array(words.dropFirst(3)); continue }
            if words.first == "done" { loops = [:] }
            if words.first == "do" { words.removeFirst() }
            guard words.count >= 4, URL(filePath: words[0]).lastPathComponent == "yabai",
                  words[1...3] == ["-m", "signal", "--add"],
                  !words.contains(where: { word in
                      ["app=", "app!=", "title=", "title!=", "active="].contains { word.hasPrefix($0) }
                  }),
                  let action = words.first(where: { $0.hasPrefix("action=") }),
                  isTrigger(String(action.dropFirst(7)), for: configuration),
                  let event = words.first(where: { $0.hasPrefix("event=") }) else { continue }
            let value = String(event.dropFirst(6))
            if value.hasPrefix("$") {
                let variable = value.dropFirst().trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
                found.formUnion(loops[variable] ?? [])
            } else { found.insert(value) }
        }
        return found
    }

    /// Shell words only, with no expansion or evaluation. Unknown shell logic never becomes a successful check.
    static func commands(in text: String) -> [[String]] {
        var commands: [[String]] = [], words: [String] = []
        var word = "", quote: Character?, escaped = false, comment = false
        func endWord() { if !word.isEmpty { words.append(word); word = "" } }
        func endCommand() { endWord(); if !words.isEmpty { commands.append(words); words = [] } }
        for character in text {
            if comment {
                if character == "\n" { comment = false; endCommand() }
            } else if escaped {
                if character != "\n" { word.append(character) }
                escaped = false
            } else if character == "\\" && quote != "'" { escaped = true }
            else if let quoted = quote {
                if character == quoted { quote = nil } else { word.append(character) }
            } else if character == "'" || character == "\"" { quote = character }
            else if character == "#" && word.isEmpty { comment = true }
            else if character == "\n" || character == ";" { endCommand() }
            else if character.isWhitespace { endWord() }
            else { word.append(character) }
        }
        guard quote == nil, !escaped else { return [] }
        endCommand()
        return commands
    }
}
