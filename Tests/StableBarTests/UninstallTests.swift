import Foundation
import Testing
@testable import StableBar

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "Stable Bar's \(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private struct Refusal: LocalizedError {
    var errorDescription: String? { "Not allowed." }
}

private let command = URL(filePath: "/usr/local/bin/stablebar")
private let configuration = URL(filePath: "/Users/me/.config/stablebar", directoryHint: .isDirectory)
private let cache = URL(filePath: "/Users/me/Library/Caches/org.stablebar.app", directoryHint: .isDirectory)
private let app = URL(filePath: "/Applications/StableBar.app", directoryHint: .isDirectory)

@Test func menuBarAutoHideSetupTurnsOnIsStableBars() {
    #expect(MenuBarAutoHide.turnedOnByStableBar(after: true, wasOn: false, wasStableBars: false))
}

@Test func menuBarAutoHideTheUserTurnedOnIsNotStableBars() {
    #expect(!MenuBarAutoHide.turnedOnByStableBar(after: true, wasOn: true, wasStableBars: false))
}

@Test func menuBarAutoHideStaysStableBarsWhenSetupShowsAndHidesTheMenuBarAgain() {
    #expect(MenuBarAutoHide.turnedOnByStableBar(after: true, wasOn: true, wasStableBars: true))
}

@Test func menuBarAutoHideTurnedOffIsNoLongerStableBars() {
    #expect(!MenuBarAutoHide.turnedOnByStableBar(after: false, wasOn: false, wasStableBars: true))
    #expect(!MenuBarAutoHide.turnedOnByStableBar(after: false, wasOn: true, wasStableBars: true))
}

@Test func menuBarAutoHideIsRememberedInPreferences() throws {
    let suite = "StableBarTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(!MenuBarAutoHide.turnedOnByStableBar(in: defaults))
    MenuBarAutoHide.setTurnedOnByStableBar(true, in: defaults)
    #expect(MenuBarAutoHide.turnedOnByStableBar(in: defaults))
    MenuBarAutoHide.setTurnedOnByStableBar(false, in: defaults)
    #expect(defaults.object(forKey: MenuBarAutoHide.turnedOnKey) == nil)
}

@Test func menuBarAutoHideRecordIsForgottenOnceTheMenuBarShows() throws {
    let suite = "StableBarTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    MenuBarAutoHide.setTurnedOnByStableBar(true, in: defaults)
    defaults.set(true, forKey: "_HIHideMenuBar")
    MenuBarAutoHide.forgetIfShown(in: defaults)
    #expect(MenuBarAutoHide.turnedOnByStableBar(in: defaults))
    defaults.set(false, forKey: "_HIHideMenuBar")
    MenuBarAutoHide.forgetIfShown(in: defaults)
    #expect(!MenuBarAutoHide.turnedOnByStableBar(in: defaults))
}

@Test func uninstallRunsEveryStepInOrder() {
    let snapshot = UninstallSnapshot(running: 1, menuBarHides: true, turnedOnMenuBarAutoHide: true, opensAtLogin: true,
                                     commands: [command], hasKeychainItems: true, configuration: configuration,
                                     files: [cache], app: app)
    var options = UninstallOptions(snapshot)
    options.removesConfiguration = true
    #expect(snapshot.steps(options) == [.quit(1), .showMenuBar, .loginItem, .command(command), .keychain,
                                        .configuration(configuration), .permissions, .files([cache]), .app(app)])
}

@Test func uninstallLeavesWhatTheBarRunsOnUntilItQuits() {
    let snapshot = UninstallSnapshot(running: 1, menuBarHides: true, turnedOnMenuBarAutoHide: true, opensAtLogin: true,
                                     commands: [command], hasKeychainItems: true, configuration: configuration,
                                     files: [cache], app: app)
    var options = UninstallOptions(snapshot)
    options.removesConfiguration = true
    #expect(snapshot.stepsBeforeQuit(options) == [.quit(1), .showMenuBar, .loginItem, .command(command), .keychain,
                                                  .configuration(configuration)])
    #expect(snapshot.stepsAfterQuit == [.permissions, .files([cache]), .app(app)])
    #expect(snapshot.steps(options) == snapshot.stepsBeforeQuit(options) + snapshot.stepsAfterQuit)
}

@Test func uninstallAfterQuitLeavesAHomebrewAppToHomebrew() {
    let snapshot = UninstallSnapshot(files: [cache], app: app, homebrew: true)
    #expect(snapshot.stepsAfterQuit == [.permissions, .files([cache])])
}

@Test func uninstallFinishesAfterQuitUnlessAnotherStableBarKeptRunning() {
    #expect(Uninstall.finishesAfterQuit([]))
    #expect(Uninstall.finishesAfterQuit([UninstallOutcome(step: .quit(1), error: nil),
                                         UninstallOutcome(step: .command(command), error: "Cancelled.")]))
    #expect(!Uninstall.finishesAfterQuit([UninstallOutcome(step: .quit(1), error: "StableBar is still running.")]))
}

@MainActor
@Test func uninstallWaitsForTheBarToQuit() async throws {
    var checks = 0
    #expect(try await Uninstall.waitForQuit(every: .milliseconds(1)) {
        checks += 1
        return checks < 3
    })
    #expect(checks == 3)
    #expect(try await !Uninstall.waitForQuit(polls: 3, every: .milliseconds(1)) { true })
}

@Test func uninstallAfterQuitSaysWhatIsLeftToDoByHand() {
    let text = Uninstall.leftToDo([UninstallOutcome(step: .permissions, error: "tccutil failed."),
                                   UninstallOutcome(step: .files([cache]), error: nil),
                                   UninstallOutcome(step: .app(app), error: "Not allowed.")])
    #expect(text == """
        Reset StableBar’s permissions in Privacy & Security
        tccutil failed. \(UninstallStep.permissions.fix)

        Move /Applications/StableBar.app to the Trash
        Not allowed. \(UninstallStep.app(app).fix)
        """)
}

@Test func uninstallStartsTheRestInItsOwnSessionSoItOutlivesTheBar() throws {
    let directory = try temporaryDirectory()
    let report = directory.appending(path: "session")
    // The child writes its process ID and its group's. A new session makes it the leader of a new group, which the bar's
    // process group ending doesn't reach.
    try spawnDetached("/bin/sh", arguments: ["-c", "echo \"$$ $(ps -o pgid= -p $$ | tr -d ' ')\" > \"$1.tmp\" && mv \"$1.tmp\" \"$1\"",
                                             "sh", report.path])
    let deadline = Date().addingTimeInterval(10)
    while !FileManager.default.fileExists(atPath: report.path) && Date() < deadline { usleep(20_000) }
    let ids = try String(contentsOf: report, encoding: .utf8).split(separator: " ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    #expect(ids.count == 2)
    #expect(ids.first == ids.last)
    #expect(ids.first != String(getpid()))
}

@Test func uninstallStillResetsPermissionsAndPreferencesOnACleanMac() {
    let snapshot = UninstallSnapshot()
    #expect(snapshot.steps(UninstallOptions(snapshot)) == [.permissions, .files([])])
}

@Test func uninstallTurnsOffTheAutoHideStableBarTurnedOn() {
    let snapshot = UninstallSnapshot(menuBarHides: true, turnedOnMenuBarAutoHide: true)
    #expect(UninstallOptions(snapshot).showsMenuBar)
    #expect(snapshot.steps(UninstallOptions(snapshot)).contains(.showMenuBar))
}

@Test func uninstallLeavesAutoHideStableBarDidNotTurnOnUnlessAsked() {
    let snapshot = UninstallSnapshot(menuBarHides: true)
    var options = UninstallOptions(snapshot)
    #expect(!options.showsMenuBar)
    #expect(!snapshot.steps(options).contains(.showMenuBar))
    options.showsMenuBar = true
    #expect(snapshot.steps(options).contains(.showMenuBar))
}

@Test func uninstallLeavesAVisibleMenuBarAlone() {
    let snapshot = UninstallSnapshot(menuBarHides: false, turnedOnMenuBarAutoHide: true)
    var options = UninstallOptions(snapshot)
    options.showsMenuBar = true
    #expect(!snapshot.steps(options).contains(.showMenuBar))
}

@Test func uninstallKeepsTheConfigurationUnlessAsked() {
    let snapshot = UninstallSnapshot(configuration: configuration)
    var options = UninstallOptions(snapshot)
    #expect(!snapshot.steps(options).contains(.configuration(configuration)))
    options.removesConfiguration = true
    #expect(snapshot.steps(options).contains(.configuration(configuration)))
}

@Test func uninstallLeavesAHomebrewAppToHomebrew() {
    let snapshot = UninstallSnapshot(app: app, homebrew: true)
    #expect(!snapshot.steps(UninstallOptions(snapshot)).contains(.app(app)))
    #expect(UninstallSnapshot.homebrewCommand == "brew uninstall --cask stablebar")
}

@Test func uninstallStepsSayWhatTheyChange() {
    #expect(UninstallStep.showMenuBar.title == "Turn off the macOS menu bar’s auto-hide")
    #expect(UninstallStep.command(command).title == "Remove the stablebar command from /usr/local/bin")
    #expect(UninstallStep.quit(1).title == "Quit the StableBar that’s running")
    #expect(UninstallStep.quit(2).title == "Quit the 2 StableBars that are running")
    #expect(UninstallStep.command(command).fix.contains("sudo rm '/usr/local/bin/stablebar'"))
    #expect(UninstallStep.app(app).title == "Move /Applications/StableBar.app to the Trash")
}

@Test func uninstallFindsTheFilesThatExist() throws {
    let home = try temporaryDirectory()
    let caches = home.appending(path: "Library/Caches/org.stablebar.app", directoryHint: .isDirectory)
    let storage = home.appending(path: "Library/HTTPStorages/org.stablebar.app", directoryHint: .isDirectory)
    for directory in [caches, storage] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    #expect(UninstallSnapshot.files(home: home, bundleID: "org.stablebar.app").map(\.path) == [caches.path, storage.path])
}

@Test func uninstallFindsAHomebrewInstall() throws {
    let prefix = try temporaryDirectory()
    let caskroom = prefix.appending(path: "Caskroom", directoryHint: .isDirectory)
    #expect(!UninstallSnapshot.installedByHomebrew(caskrooms: [caskroom]))
    try FileManager.default.createDirectory(at: caskroom.appending(path: "stablebar/0.8.0"), withIntermediateDirectories: true)
    #expect(UninstallSnapshot.installedByHomebrew(caskrooms: [prefix.appending(path: "missing"), caskroom]))
}

@Test func uninstallRemovesFilesAndSkipsMissingOnes() throws {
    let directory = try temporaryDirectory()
    let folder = directory.appending(path: "Caches/org.stablebar.app", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: folder.appending(path: "Cache.db"))
    try Uninstall.remove([folder, directory.appending(path: "missing")])
    #expect(!FileManager.default.fileExists(atPath: folder.path))
}

@MainActor
@Test func uninstallKeepsGoingAfterAFailedStep() async {
    var performed: [UninstallStep] = []
    let outcomes = await Uninstall.run([.loginItem, .command(command), .keychain]) { step in
        performed.append(step)
        if step == .command(command) { throw Refusal() }
    }
    #expect(performed == [.loginItem, .command(command), .keychain])
    #expect(outcomes == [UninstallOutcome(step: .loginItem, error: nil), UninstallOutcome(step: .command(command), error: "Not allowed."),
                         UninstallOutcome(step: .keychain, error: nil)])
}

@MainActor
@Test func uninstallStopsWhenStableBarDoesNotQuit() async {
    var performed: [UninstallStep] = []
    let outcomes = await Uninstall.run([.quit(1), .loginItem, .files([cache]), .app(app)]) { step in
        performed.append(step)
        if case .quit = step { throw Refusal() }
    }
    #expect(performed == [.quit(1)])
    #expect(outcomes == [UninstallOutcome(step: .quit(1), error: "Not allowed.")])
}

@MainActor
@Test func uninstallCountsACancelledPasswordPromptAsNotDone() async {
    let outcomes = await Uninstall.run([.command(command)]) { _ in throw CancellationError() }
    #expect(outcomes == [UninstallOutcome(step: .command(command), error: "Cancelled.")])
}

@Test func uninstallCommandPlanNamesWhatStaysAndHowToChangeIt() {
    let snapshot = UninstallSnapshot(menuBarHides: true, configuration: configuration, app: app, homebrew: true)
    let plan = UninstallCommand.plan(snapshot, options: UninstallOptions(snapshot))
    #expect(plan.contains("  - Reset StableBar’s permissions in Privacy & Security"))
    #expect(plan.contains("Add --show-menu-bar to turn it off."))
    #expect(plan.contains("Add --remove-config to move it to the Trash."))
    #expect(plan.contains("brew uninstall --cask stablebar"))
}

@Test func uninstallCommandPlanLeavesOutNotesThatDoNotApply() {
    let snapshot = UninstallSnapshot(menuBarHides: true, turnedOnMenuBarAutoHide: true, configuration: configuration)
    var options = UninstallOptions(snapshot)
    options.removesConfiguration = true
    let plan = UninstallCommand.plan(snapshot, options: options)
    #expect(!plan.contains("--show-menu-bar"))
    #expect(!plan.contains("--remove-config"))
    #expect(!plan.contains("brew"))
}

@Test func uninstallCommandTakesItsOptionsInAnyOrder() throws {
    guard case let .uninstall(removesConfiguration, showsMenuBar, confirmed) = try LaunchCommand(arguments: ["--uninstall"]) else {
        Issue.record("--uninstall wasn't parsed")
        return
    }
    #expect(!removesConfiguration && !showsMenuBar && !confirmed)
    guard case let .uninstall(removes, shows, yes) = try LaunchCommand(arguments: ["--uninstall", "--yes", "--show-menu-bar", "--remove-config"]) else {
        Issue.record("--uninstall options weren't parsed")
        return
    }
    #expect(removes && shows && yes)
    for arguments in [["--uninstall", "--yes", "--yes"], ["--uninstall", "--keep"], ["--uninstall", "--persist"],
                      ["--config", "/tmp/config.json", "--uninstall"]] {
        #expect(throws: CommandFailure.self) { try LaunchCommand(arguments: arguments) }
    }
}

@Test func finishUninstallTakesTheBarsProcessID() throws {
    guard case let .finishUninstall(pid) = try LaunchCommand(arguments: ["--finish-uninstall", "4242"]) else {
        Issue.record("--finish-uninstall wasn't parsed")
        return
    }
    #expect(pid == 4242)
    for arguments in [["--finish-uninstall"], ["--finish-uninstall", "bar"], ["--finish-uninstall", "0"], ["--finish-uninstall", "-1"],
                      ["--finish-uninstall", "1", "2"], ["--config", "/tmp/config.json", "--finish-uninstall", "1"]] {
        #expect(throws: CommandFailure.self) { try LaunchCommand(arguments: arguments) }
    }
}

@Test func settingsSearchFindsUninstall() {
    #expect(SettingsSearchResult.allCases.filter { $0.matches("uninstall stablebar") } == [.uninstall])
    #expect(SettingsSearchResult.uninstall.matches("remove app"))
}
