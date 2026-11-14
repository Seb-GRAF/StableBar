import AppKit
import ServiceManagement

/// What StableBar changed or added on this Mac, read before uninstalling it.
struct UninstallSnapshot: Equatable {
    /// Other StableBar processes, such as the bar when the command line uninstalls.
    var running = 0
    var menuBarHides = false
    var turnedOnMenuBarAutoHide = false
    var opensAtLogin = false
    var commands: [URL] = []
    var hasKeychainItems = false
    /// `~/.config/stablebar`, when it exists.
    var configuration: URL?
    /// Caches and HTTP storage that exist; preferences are removed through `UserDefaults`.
    var files: [URL] = []
    /// The app bundle, when StableBar runs from one.
    var app: URL?
    var homebrew = false
    /// Removing a command needs an administrator password, because its folder isn't writable.
    var asksForPassword = false

    static let homebrewCommand = "brew uninstall --cask stablebar"

    func steps(_ options: UninstallOptions) -> [UninstallStep] {
        stepsBeforeQuit(options) + stepsAfterQuit
    }

    /// What Settings does while the bar still runs, so a step that fails leaves StableBar whole.
    func stepsBeforeQuit(_ options: UninstallOptions) -> [UninstallStep] {
        var steps: [UninstallStep] = running > 0 ? [.quit(running)] : []
        if menuBarHides && options.showsMenuBar { steps.append(.showMenuBar) }
        if opensAtLogin { steps.append(.loginItem) }
        steps += commands.map(UninstallStep.command)
        if hasKeychainItems { steps.append(.keychain) }
        if let configuration, options.removesConfiguration { steps.append(.configuration(configuration)) }
        return steps
    }

    /// What a running bar can't do to itself: it would lose its permissions, write back its caches and preferences,
    /// and read files from an app in the Trash. Settings leaves these to `--finish-uninstall` once the bar has quit.
    /// They also come after the menu bar, because turning auto-hide off uses StableBar's access to System Events.
    var stepsAfterQuit: [UninstallStep] {
        var steps: [UninstallStep] = [.permissions, .files(files)]
        if let app, !homebrew { steps.append(.app(app)) }
        return steps
    }

    static func files(home: URL, bundleID: String) -> [URL] {
        ["Library/Caches/\(bundleID)", "Library/Caches/\(bundleID).sparkle", "Library/Caches/StableBar", "Library/HTTPStorages/\(bundleID)"]
            .map { home.appending(path: $0, directoryHint: .isDirectory) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func installedByHomebrew(caskrooms: [URL] = ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"].map {
        URL(filePath: $0, directoryHint: .isDirectory)
    }) -> Bool {
        caskrooms.contains { FileManager.default.fileExists(atPath: $0.appending(path: "stablebar").path) }
    }
}

struct UninstallOptions: Equatable {
    /// Turn off auto-hide; on by default only when StableBar turned it on.
    var showsMenuBar: Bool
    var removesConfiguration = false

    init(_ snapshot: UninstallSnapshot) {
        showsMenuBar = snapshot.turnedOnMenuBarAutoHide
    }
}

enum UninstallStep: Hashable {
    case quit(Int)
    case showMenuBar
    case loginItem
    case command(URL)
    case keychain
    case configuration(URL)
    case permissions
    case files([URL])
    case app(URL)

    var title: String {
        switch self {
        case let .quit(count): count == 1 ? "Quit the StableBar that’s running" : "Quit the \(count) StableBars that are running"
        case .showMenuBar: "Turn off the macOS menu bar’s auto-hide"
        case .loginItem: "Turn off Open at login"
        case let .command(url): "Remove the \(CommandLineTool.name) command from \(abbreviated(url.deletingLastPathComponent()))"
        case .keychain: "Delete package and source tokens from the Keychain"
        case let .configuration(url): "Move \(abbreviated(url)) to the Trash"
        case .permissions: "Reset StableBar’s permissions in Privacy & Security"
        case .files: "Delete StableBar’s caches and preferences"
        case let .app(url): "Move \(abbreviated(url)) to the Trash"
        }
    }

    /// What to do by hand when the step fails.
    var fix: String {
        switch self {
        case .quit: "Quit StableBar from its menu-bar icon, then uninstall again."
        case .showMenuBar: "Turn off Automatically hide and show the menu bar in System Settings → Menu Bar, or Control Center before macOS 26."
        case .loginItem: "Remove StableBar in System Settings → General → Login Items."
        case let .command(url): "Run sudo rm '\(url.path.replacingOccurrences(of: "'", with: "'\\''"))' in Terminal."
        case .keychain: "Run security delete-generic-password -s StableBar in Terminal until it finds no item."
        case let .configuration(url): "Move \(abbreviated(url)) to the Trash in Finder."
        case .permissions: "Remove StableBar in System Settings → Privacy & Security → Accessibility, Screen Recording, Calendars and Automation."
        case let .files(urls): "Delete \((urls.map(abbreviated) + ["~/Library/Preferences/org.stablebar.app.plist"]).joined(separator: ", "))."
        case .app: "Drag StableBar from Applications to the Trash."
        }
    }
}

struct UninstallOutcome: Equatable {
    let step: UninstallStep
    /// Why the step failed, or nil when it's done.
    let error: String?
}

enum Uninstall {
    /// Runs every step, even after one fails, so as much as possible is put back. Only a StableBar that won't quit
    /// stops the rest, because it would write back the files and preferences the later steps remove.
    @MainActor
    static func run(_ steps: [UninstallStep], perform: (UninstallStep) async throws -> Void) async -> [UninstallOutcome] {
        var outcomes: [UninstallOutcome] = []
        for step in steps {
            do {
                try await perform(step)
                outcomes.append(UninstallOutcome(step: step, error: nil))
            } catch {
                outcomes.append(UninstallOutcome(step: step, error: error is CancellationError ? "Cancelled." : errorMessage(error)))
                if case .quit = step { break }
            }
        }
        return outcomes
    }

    /// Whether the steps after quitting can follow: not when another StableBar kept running, because it would write back
    /// the files and preferences they remove.
    static func finishesAfterQuit(_ outcomes: [UninstallOutcome]) -> Bool {
        !outcomes.contains { if case .quit = $0.step { $0.error != nil } else { false } }
    }

    /// Checks `isRunning` every `interval`, at most `polls` times, and returns whether it stopped.
    @MainActor
    static func waitForQuit(polls: Int = .max, every interval: Duration = .milliseconds(100),
                            _ isRunning: () -> Bool) async throws -> Bool {
        for _ in 0..<polls {
            if !isRunning() { return true }
            try await Task.sleep(for: interval)
        }
        return !isRunning()
    }

    /// The steps that failed, each with what to do by hand.
    static func leftToDo(_ outcomes: [UninstallOutcome]) -> String {
        outcomes.compactMap { outcome in outcome.error.map { "\(outcome.step.title)\n\($0) \(outcome.step.fix)" } }
            .joined(separator: "\n\n")
    }

    static func remove(_ urls: [URL]) throws {
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

/// Starts a process in a session of its own, reading and writing nothing, so it keeps running after StableBar quits.
func spawnDetached(_ executable: String, arguments: [String]) throws {
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawnattr_init(&attributes)
    defer {
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attributes)
    }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT |
                                               POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
    var signals = sigset_t()
    sigemptyset(&signals)
    posix_spawnattr_setsigmask(&attributes, &signals)
    sigfillset(&signals)
    posix_spawnattr_setsigdefault(&attributes, &signals)
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
    let argv = ([executable] + arguments).map { strdup($0) } + [nil]
    let envp = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
        argv.forEach { free($0) }
        envp.forEach { free($0) }
    }
    var process: pid_t = 0
    let result = posix_spawn(&process, executable, &actions, &attributes, argv, envp)
    guard result == 0 else { throw CommandFailure(message: "\(String(cString: strerror(result))).") }
}

/// Reads this Mac and performs the steps, for Settings and `--uninstall`.
@MainActor
enum UninstallSystem {
    /// Only an app bundle reads and removes StableBar's own preferences.
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }
    static var bundleID: String { Bundle.main.bundleIdentifier ?? "org.stablebar.app" }

    static func snapshot() -> UninstallSnapshot {
        let configuration = LaunchCommand.configurationURL.deletingLastPathComponent()
        let commands = CommandLineTool.installedScripts(path: shellEnvironment.withLock { $0["PATH"] })
        let status = SMAppService.mainApp.status
        return UninstallSnapshot(
            running: otherCopies().count,
            menuBarHides: MenuBarAutoHide.isOn(),
            turnedOnMenuBarAutoHide: MenuBarAutoHide.turnedOnByStableBar(),
            opensAtLogin: status == .enabled || status == .requiresApproval,
            commands: commands,
            hasKeychainItems: packageSecretsExist(),
            configuration: FileManager.default.fileExists(atPath: configuration.path) ? configuration : nil,
            files: files(),
            app: app,
            homebrew: UninstallSnapshot.installedByHomebrew(),
            asksForPassword: commands.contains { !FileManager.default.isWritableFile(atPath: $0.deletingLastPathComponent().path) })
    }

    private static var app: URL? { Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL : nil }

    private static func files() -> [URL] {
        UninstallSnapshot.files(home: FileManager.default.homeDirectoryForCurrentUser, bundleID: bundleID)
    }

    static func perform(_ step: UninstallStep) async throws {
        switch step {
        case .quit:
            let copies = otherCopies()
            copies.forEach { $0.terminate() }
            guard try await Uninstall.waitForQuit(polls: 100, { copies.contains { kill($0.processIdentifier, 0) == 0 } }) else {
                throw CommandFailure(message: "StableBar is still running.")
            }
        case .showMenuBar:
            try await MenuBarAutoHide.set(false)
        case .loginItem:
            try setLaunchAtLogin(false)
        case let .command(url):
            try await CommandLineTool.remove(url)
        case .keychain:
            try deletePackageSecrets()
        case let .configuration(url), let .app(url):
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        case .permissions:
            _ = try await runCommand("/usr/bin/tccutil", arguments: ["reset", "All", bundleID])
        case let .files(urls):
            try Uninstall.remove(urls)
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
    }

    /// Starts `--finish-uninstall` for this bar, which does the steps after quitting once the bar has quit, even if it crashes.
    static func finishAfterQuit() throws {
        guard let executable = Bundle.main.executablePath else { throw CommandFailure(message: "StableBar’s executable is missing.") }
        try spawnDetached(executable, arguments: ["--finish-uninstall", String(getpid())])
    }

    /// `--finish-uninstall PID`: waits for the bar to quit, then resets its permissions, deletes its caches and preferences,
    /// including what the bar wrote as it quit, and moves the app to the Trash. An alert lists any step that failed.
    static func finish(after bar: pid_t) async -> Int32 {
        _ = try? await Uninstall.waitForQuit { kill(bar, 0) == 0 }
        let snapshot = UninstallSnapshot(files: files(), app: app, homebrew: UninstallSnapshot.installedByHomebrew())
        let outcomes = await Uninstall.run(snapshot.stepsAfterQuit, perform: perform)
        guard outcomes.contains(where: { $0.error != nil }) else { return 0 }
        CFUserNotificationDisplayAlert(0, kCFUserNotificationCautionAlertLevel, nil, nil, nil,
                                       "StableBar couldn’t finish uninstalling" as CFString,
                                       Uninstall.leftToDo(outcomes) as CFString, "OK" as CFString, nil, nil, nil)
        return 1
    }

    private static func otherCopies() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { $0.processIdentifier != getpid() }
    }
}

/// `StableBar --uninstall`: the same steps as Settings, confirmed in Terminal.
@MainActor
enum UninstallCommand {
    nonisolated static func plan(_ snapshot: UninstallSnapshot, options: UninstallOptions) -> String {
        var lines = ["Uninstalling StableBar will:"] + snapshot.steps(options).map { "  - \($0.title)" }
        if snapshot.asksForPassword {
            lines.append("macOS asks for an administrator password to remove the \(CommandLineTool.name) command.")
        }
        if snapshot.menuBarHides && !options.showsMenuBar {
            lines.append("The macOS menu bar hides automatically, but StableBar didn’t turn that on, so it stays that way. Add --show-menu-bar to turn it off.")
        }
        if let configuration = snapshot.configuration, !options.removesConfiguration {
            lines.append("\(abbreviated(configuration)) stays. Add --remove-config to move it to the Trash.")
        }
        if snapshot.homebrew {
            lines.append("Homebrew installed StableBar, so the app stays in place. Afterwards, run: \(UninstallSnapshot.homebrewCommand)")
        }
        return lines.joined(separator: "\n")
    }

    static func run(removesConfiguration: Bool, showsMenuBar: Bool, confirmed: Bool) async -> Int32 {
        if let problem = getuid() == 0 ? "Run --uninstall without sudo; it asks for a password when it needs one."
            : UninstallSystem.isAvailable ? nil : "Run --uninstall from StableBar.app/Contents/MacOS/StableBar." {
            FileHandle.standardError.write(Data("\(problem)\n".utf8))
            return 1
        }
        let snapshot = UninstallSystem.snapshot()
        var options = UninstallOptions(snapshot)
        options.showsMenuBar = options.showsMenuBar || showsMenuBar
        options.removesConfiguration = removesConfiguration
        print(plan(snapshot, options: options))
        if !confirmed {
            guard isatty(STDIN_FILENO) != 0 else {
                FileHandle.standardError.write(Data("Add --yes to uninstall without a prompt.\n".utf8))
                return 1
            }
            print("Uninstall StableBar? [y/N] ", terminator: "")
            fflush(stdout)
            guard let answer = readLine(), ["y", "yes"].contains(answer.lowercased()) else {
                print("StableBar wasn’t uninstalled.")
                return 1
            }
        }
        let outcomes = await Uninstall.run(snapshot.steps(options), perform: UninstallSystem.perform)
        for outcome in outcomes {
            if let error = outcome.error {
                print("Not done: \(outcome.step.title). \(error) \(outcome.step.fix)")
            } else {
                print("Done: \(outcome.step.title)")
            }
        }
        if snapshot.homebrew { print("Finish with: \(UninstallSnapshot.homebrewCommand)") }
        return outcomes.contains { $0.error != nil } ? 1 : 0
    }
}

private func abbreviated(_ url: URL) -> String {
    url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
}
