import Foundation
import Sparkle
import Testing
@testable import StableBar

private let setVersion = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "scripts/set-version.sh").path

@Test(arguments: ["1.2.3-beta.4", "1.2.3-beta.20261020103000.114"])
func releaseVersionWritesTheVersionAndBuildNumberAndNothingElse(version: String) async throws {
    let plist = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).plist")
    defer { try? FileManager.default.removeItem(at: plist) }
    try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
            <key>CFBundleShortVersionString</key><string>0.1.0</string>
            <key>CFBundleVersion</key>
            <string>1</string>
            <key>LSMinimumSystemVersion</key><string>14.0</string>
        </dict></plist>

        """.utf8).write(to: plist)
    _ = try await runCommand(setVersion, arguments: [version, "57", plist.path])
    #expect(try String(contentsOf: plist, encoding: .utf8) == """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
            <key>CFBundleShortVersionString</key><string>\(version)</string>
            <key>CFBundleVersion</key>
            <string>57</string>
            <key>LSMinimumSystemVersion</key><string>14.0</string>
        </dict></plist>

        """)
}

@Test func releaseVersionLeavesThePlistUntouchedWhenAVersionKeyIsMissing() async throws {
    let plist = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).plist")
    defer { try? FileManager.default.removeItem(at: plist) }
    let original = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
            <key>CFBundleShortVersionString</key><string>0.1.0</string>
        </dict></plist>

        """.utf8)
    try original.write(to: plist)
    await #expect(throws: CommandFailure.self) {
        try await runCommand(setVersion, arguments: ["1.2.3", "57", plist.path])
    }
    #expect(try Data(contentsOf: plist) == original)
}

// CFBundleVersion takes one to three dot-separated integers, so a prerelease version must not end
// up there. A plist path in second place is the old two-argument call.
@Test(arguments: ["1.2.3-beta.4", "1.2.3.4", "Resources/Info.plist"])
func releaseVersionRejectsABuildNumberThatIsNotOneToThreeIntegers(build: String) async throws {
    let plist = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).plist")
    defer { try? FileManager.default.removeItem(at: plist) }
    let original = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
            <key>CFBundleShortVersionString</key><string>0.1.0</string>
            <key>CFBundleVersion</key><string>1</string>
        </dict></plist>

        """.utf8)
    try original.write(to: plist)
    await #expect(throws: CommandFailure.self) {
        try await runCommand(setVersion, arguments: ["1.2.3-beta.4", build, plist.path])
    }
    #expect(try Data(contentsOf: plist) == original)
}

private let setSiteVersion = URL(filePath: setVersion).deletingLastPathComponent()
    .appending(path: "set-site-version.sh").path

// A stable release runs it on the website, so every place there that names the version, and every
// download, must move to the new release's DMG.
@Test func siteVersionPointsEveryDownloadOnTheWebsiteAtTheVersion() async throws {
    let website = URL(filePath: setVersion).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "site/index.html")
    let original = try String(contentsOf: website, encoding: .utf8)
    let current = try #require(original.firstMatch(of: /"softwareVersion": "([^"]+)"/)).output.1
    let page = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).html")
    defer { try? FileManager.default.removeItem(at: page) }
    try Data(original.utf8).write(to: page)
    _ = try await runCommand(setSiteVersion, arguments: ["12.34.56", page.path])
    let updated = try String(contentsOf: page, encoding: .utf8)
    #expect(!updated.contains(current))
    #expect(!updated.contains("releases/latest"))
    #expect(updated == original.replacingOccurrences(of: current, with: "12.34.56"))
}

@Test(arguments: ["1.2.3-beta.4", "1.2.3-beta.20261020103000.114", "v1.2.3", "1.2"])
func siteVersionRejectsAnythingButAStableVersion(version: String) async throws {
    let page = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).html")
    defer { try? FileManager.default.removeItem(at: page) }
    let original = Data("""
        "softwareVersion": "0.1.0",
        <a href="https://github.com/o/r/releases/download/v0.1.0/StableBar.dmg">Get<span class="ver">v0.1.0</span></a>

        """.utf8)
    try original.write(to: page)
    await #expect(throws: CommandFailure.self) {
        try await runCommand(setSiteVersion, arguments: [version, page.path])
    }
    #expect(try Data(contentsOf: page) == original)
}

@Test func siteVersionLeavesThePageUntouchedWhenItNamesNoVersion() async throws {
    let page = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).html")
    defer { try? FileManager.default.removeItem(at: page) }
    let original = Data("""
        <a href="https://github.com/o/r/releases/download/v0.1.0/StableBar.dmg">Get<span class="ver">v0.1.0</span></a>

        """.utf8)
    try original.write(to: page)
    await #expect(throws: CommandFailure.self) {
        try await runCommand(setSiteVersion, arguments: ["1.2.3", page.path])
    }
    #expect(try Data(contentsOf: page) == original)
}

// The whole suite runs in parallel, and on CI a single git command there has taken over ten seconds.
private let historyTimeout = 60.0

private struct ReleaseHistory {
    let repository = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

    init() async throws {
        let scripts = repository.appending(path: "scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(filePath: setVersion).deletingLastPathComponent()
            .appending(path: "unchanged-app.sh"), to: scripts.appending(path: "unchanged-app.sh"))
        try FileManager.default.createDirectory(at: repository.appending(path: ".github"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(filePath: setVersion).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: ".github/app-paths"), to: repository.appending(path: ".github/app-paths"))
        try await git(["init", "--quiet"])
        try await git(["add", "."])
        try await git(["commit", "--quiet", "-m", "chore: start"])
    }

    func remove() {
        try? FileManager.default.removeItem(at: repository)
    }

    @discardableResult
    func git(_ arguments: [String]) async throws -> Data {
        try await runCommand("/usr/bin/git", arguments: [
            "-C", repository.path,
            "-c", "user.name=StableBar Tests",
            "-c", "user.email=tests@example.invalid",
            "-c", "init.defaultBranch=main",
            "-c", "commit.gpgSign=false",
            "-c", "tag.gpgSign=false",
            "-c", "core.hooksPath=/dev/null"
        ] + arguments, timeout: historyTimeout)
    }

    func commit(_ message: String, changing path: String) async throws {
        let file = repository.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(UUID().uuidString.utf8).write(to: file)
        try await git(["add", "."])
        try await git(["commit", "--quiet", "-m", message])
    }

    /// The release whose app the newest commit still ships, or nil when the script says the app changed.
    /// Any other failure, such as a timeout, is an error, so it can't pass for a changed app.
    func unchangedApp() async throws -> String? {
        do {
            let output = try await runCommand(repository.appending(path: "scripts/unchanged-app.sh").path,
                                              arguments: [], timeout: historyTimeout)
            return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let failure as CommandFailure where failure.message == "Command exited with status 1." {
            return nil
        }
    }
}

// CI publishes no beta for such a commit, and a stable release ships it as the beta before it.
@Test func unchangedAppNamesTheBetaWhenLaterCommitsChangeOnlyMaintenanceAndTheWebsite() async throws {
    let history = try await ReleaseHistory()
    defer { history.remove() }
    try await history.commit("feat: add a clock", changing: "Sources/StableBar/Clock.swift")
    try await history.git(["tag", "v0.8.0-beta.20261024075505.382"])
    try await history.commit("ci(deps): bump the actions group", changing: ".github/workflows/ci.yml")
    try await history.git(["tag", "appcast"])
    try await history.git(["switch", "--quiet", "-c", "docs/clock"])
    try await history.commit("docs: explain the clock", changing: "docs/clock.md")
    try await history.commit("test: cover the clock", changing: "Tests/StableBarTests/ClockTests.swift")
    try await history.commit("chore: review pull requests with CodeRabbit", changing: ".coderabbit.yaml")
    try await history.commit("fix: correct the guide", changing: "docs/clock.md")
    try await history.commit("feat: redraw the website", changing: "site/index.html")
    try await history.commit("fix: update the website download links", changing: "scripts/set-site-version.sh")
    try await history.commit("refactor: tidy the guide", changing: "docs/clock.md")
    try await history.commit("docs!: rename the guide", changing: "docs/clock.md")
    try await history.git(["switch", "--quiet", "main"])
    try await history.git(["merge", "--quiet", "--no-ff", "-m", "Merge pull request #1 from someone/docs/clock", "docs/clock"])
    #expect(try await history.unchangedApp() == "v0.8.0-beta.20261024075505.382")
}

@Test func unchangedAppNamesTheBetaOfTheNewestCommit() async throws {
    let history = try await ReleaseHistory()
    defer { history.remove() }
    try await history.commit("fix: keep the clock visible", changing: "Sources/StableBar/Clock.swift")
    try await history.git(["tag", "v0.8.0-beta.20261024075505.382"])
    #expect(try await history.unchangedApp() == "v0.8.0-beta.20261024075505.382")
}

@Test(arguments: [
    ("docs: explain the clock in its help", "Sources/StableBar/Clock.swift"),
    ("docs: describe the night theme", "Resources/themes/night.json"),
    ("ci: lay out the DMG", "scripts/package.sh"),
    ("ci(deps): bump Sparkle", "Package.resolved")
])
func unchangedAppRejectsCommitsThatCanChangeTheApp(message: String, path: String) async throws {
    let history = try await ReleaseHistory()
    defer { history.remove() }
    try await history.git(["tag", "v0.8.0-beta.20261024075505.382"])
    try await history.commit("docs: explain the clock", changing: "docs/clock.md")
    try await history.commit(message, changing: path)
    #expect(try await history.unchangedApp() == nil)
}

@Test func unchangedAppRejectsAMergeThatChangesTheApp() async throws {
    let history = try await ReleaseHistory()
    defer { history.remove() }
    try await history.git(["tag", "v0.8.0-beta.20261024075505.382"])
    try await history.git(["switch", "--quiet", "-c", "docs/clock"])
    try await history.commit("docs: explain the clock", changing: "docs/clock.md")
    try await history.git(["switch", "--quiet", "main"])
    try await history.git(["merge", "--quiet", "--no-ff", "--no-commit", "docs/clock"])
    try await history.commit("Merge pull request #1 from someone/docs/clock", changing: "Sources/StableBar/Clock.swift")
    #expect(try await history.unchangedApp() == nil)
}

@Test func unchangedAppNeedsARelease() async throws {
    let history = try await ReleaseHistory()
    defer { history.remove() }
    try await history.commit("docs: explain the clock", changing: "docs/clock.md")
    #expect(try await history.unchangedApp() == nil)
}

@Test @MainActor func updateChangesReadGeneratedAndChangelogNotes() {
    #expect(AppUpdate.changes(in: """
        ## What's Changed
        * fix: ignore unchanged settings selections by @M4n0x in https://github.com/Seb-GRAF/StableBar/pull/61

        ## New Contributors
        * @M4n0x made their first contribution in https://github.com/Seb-GRAF/StableBar/pull/59

        **Full Changelog**: https://github.com/Seb-GRAF/StableBar/compare/v0.5.0-beta.84...v0.5.0-beta.85
        """) == ["fix: ignore unchanged settings selections by @M4n0x"])
    #expect(AppUpdate.changes(in: """
        ## [0.4.0](https://github.com/Seb-GRAF/StableBar/compare/v0.3.0...v0.4.0) (2026-10-15)

        ### Features

        * add yabai workspaces and profile editing ([5c30c63](https://github.com/Seb-GRAF/StableBar/commit/5c30c63))
        """) == ["add yabai workspaces and profile editing ([5c30c63](https://github.com/Seb-GRAF/StableBar/commit/5c30c63))"])
}

@MainActor private final class ProbeUpdater: SPUUpdater {
    var checksAutomatically = true
    var busy = false
    var probes = 0
    var backgroundChecks = 0
    var userChecks = 0

    override var automaticallyChecksForUpdates: Bool {
        get { checksAutomatically }
        set { checksAutomatically = newValue }
    }

    override var sessionInProgress: Bool { busy }

    override func checkForUpdateInformation() {
        #expect(!busy)
        probes += 1
        busy = true
    }

    override func checkForUpdatesInBackground() {
        #expect(!busy)
        backgroundChecks += 1
        busy = true
    }

    override func checkForUpdates() {
        #expect(!busy)
        userChecks += 1
        busy = true
    }
}

@MainActor private func updateProbe() -> (AppUpdate, ProbeUpdater) {
    let update = AppUpdate { driver, delegate in
        ProbeUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: delegate)
    }
    return (update, update.updater as! ProbeUpdater)
}

@Test @MainActor func updateProbesRespectAutomaticChecksAndDoNotOverlapSessions() {
    let (update, updater) = updateProbe()
    updater.checksAutomatically = false
    update.checkForUpdateInformation()
    #expect(updater.probes == 0)
    updater.checksAutomatically = true
    update.checkForUpdateInformation()
    #expect(updater.probes == 1)
    update.checkForUpdateInformation()
    #expect(updater.probes == 1)
    updater.busy = false
    update.updater(updater, didFinishUpdateCycleFor: .updateInformation, error: nil)
    update.checkForUpdateInformation()
    #expect(updater.probes == 2)
}

@Test @MainActor func updateProbeHandsOffOnlyAfterFindingAReleaseAndFinishingWithAutomaticChecksOn() {
    let (update, updater) = updateProbe()
    update.checkForUpdateInformation()
    update.updater(updater, didFindValidUpdate: .empty())
    #expect(updater.backgroundChecks == 0)
    updater.busy = false
    update.updater(updater, didFinishUpdateCycleFor: .updateInformation, error: nil)
    #expect(updater.backgroundChecks == 1)
    update.checkForUpdateInformation()
    #expect(updater.probes == 1)
    let (disabled, disabledUpdater) = updateProbe()
    disabled.checkForUpdateInformation()
    disabled.updater(disabledUpdater, didFindValidUpdate: .empty())
    disabledUpdater.checksAutomatically = false
    disabledUpdater.busy = false
    disabled.updater(disabledUpdater, didFinishUpdateCycleFor: .updateInformation, error: nil)
    #expect(disabledUpdater.backgroundChecks == 0)
    for check in [SPUUpdateCheck.updates, .updatesInBackground] {
        let (completed, completedUpdater) = updateProbe()
        completed.updater(completedUpdater, didFindValidUpdate: .empty())
        completed.updater(completedUpdater, didFinishUpdateCycleFor: check, error: nil)
        #expect(completedUpdater.backgroundChecks == 0, "\(check)")
    }
}

@Test @MainActor func failedUpdateProbesWaitForTheNextPollAndForgetThePreviousResult() {
    let (update, updater) = updateProbe()
    update.checkForUpdateInformation()
    update.updater(updater, didFindValidUpdate: .empty())
    updater.busy = false
    update.updater(updater, didFinishUpdateCycleFor: .updateInformation, error: URLError(.notConnectedToInternet))
    #expect(updater.backgroundChecks == 0)
    #expect(updater.probes == 1)
    update.checkForUpdateInformation()
    updater.busy = false
    update.updater(updater, didFinishUpdateCycleFor: .updateInformation, error: nil)
    #expect(updater.probes == 2)
    #expect(updater.backgroundChecks == 0)
}

private func updateState(_ stage: SPUUserUpdateStage = .notDownloaded) throws -> SPUUserUpdateState {
    let encoder = NSKeyedArchiver(requiringSecureCoding: true)
    encoder.encode(stage.rawValue, forKey: "SPUUserUpdateStateStage")
    encoder.encode(false, forKey: "SPUUserUpdateStateUserInitiated")
    encoder.finishEncoding()
    let decoder = try NSKeyedUnarchiver(forReadingFrom: encoder.encodedData)
    defer { decoder.finishDecoding() }
    return try #require(SPUUserUpdateState(coder: decoder))
}

private func appcastItem(_ version: String, notes: String = "") throws -> SUAppcastItem {
    let encoder = NSKeyedArchiver(requiringSecureCoding: true)
    encoder.encode(version, forKey: "displayVersionString")
    encoder.encode(version, forKey: "versionString")
    encoder.encode(notes, forKey: "itemDescription")
    encoder.encode(URL(string: "https://example.com/StableBar.zip")! as NSURL, forKey: "fileURL")
    encoder.encode("application", forKey: "SUAppcastItemInstallationType")
    encoder.encode([String: String]() as NSDictionary, forKey: "propertiesDictionary")
    encoder.finishEncoding()
    let decoder = try NSKeyedUnarchiver(forReadingFrom: encoder.encodedData)
    defer { decoder.finishDecoding() }
    return try #require(SUAppcastItem(coder: decoder))
}

/// An offer of `version` found in the background, as Sparkle ends its session once the offer is answered.
@MainActor private func offer(_ version: String, notes: String = "", to update: AppUpdate, _ updater: ProbeUpdater) throws {
    update.showUpdateFound(with: try appcastItem(version, notes: notes), state: try updateState()) { _ in }
    update.dismissUpdateInstallation()
    updater.busy = false
    update.updater(updater, didFinishUpdateCycleFor: .updatesInBackground, error: nil)
}

@Test @MainActor func waitingOffersLetLaterUpdatePollsReplaceThem() throws {
    let (update, updater) = updateProbe()
    var choices: [SPUUserUpdateChoice] = []
    update.showUpdateFound(with: try appcastItem("0.16.0-beta.1", notes: "* add a clock"), state: try updateState()) { choices.append($0) }
    #expect(choices == [.dismiss])
    update.dismissUpdateInstallation()
    update.updater(updater, didFinishUpdateCycleFor: .updatesInBackground, error: nil)
    #expect(update.version == "0.16.0-beta.1")
    #expect(update.changes == ["add a clock"])
    #expect(update.canProceed)

    update.checkForUpdateInformation()
    update.updater(updater, didFindValidUpdate: .empty())
    updater.busy = false
    update.updater(updater, didFinishUpdateCycleFor: .updateInformation, error: nil)
    #expect(updater.backgroundChecks == 1)
    update.showUpdateFound(with: try appcastItem("0.16.0-beta.2", notes: "* add a calendar"), state: try updateState()) { choices.append($0) }
    #expect(choices == [.dismiss, .dismiss])
    #expect(update.version == "0.16.0-beta.2")
    #expect(update.changes == ["add a calendar"])
    #expect(update.stage == .available)
    #expect(update.canProceed)
}

@Test @MainActor func checkForUpdatesReplacesAWaitingOffer() throws {
    let (update, updater) = updateProbe()
    try offer("0.16.0-beta.1", to: update, updater)
    update.checkForUpdates()
    #expect(updater.userChecks == 1)
    var choices: [SPUUserUpdateChoice] = []
    update.showUpdateFound(with: try appcastItem("0.16.0-beta.2"), state: try updateState()) { choices.append($0) }
    #expect(choices == [.dismiss])
    #expect(update.version == "0.16.0-beta.2")
    #expect(update.canProceed)
}

@Test @MainActor func updatePollsRemoveAnOfferOnlyWhenNoUpdateIsLeft() throws {
    let (update, updater) = updateProbe()
    try offer("0.16.0-beta.1", to: update, updater)
    update.checkForUpdateInformation()
    updater.busy = false
    update.updater(updater, didFinishUpdateCycleFor: .updateInformation, error: URLError(.notConnectedToInternet))
    #expect(update.version == "0.16.0-beta.1")

    update.checkForUpdateInformation()
    updater.busy = false
    let noUpdate = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue))
    update.updater(updater, didFinishUpdateCycleFor: .updateInformation, error: noUpdate)
    #expect(update.version == nil)
}

@Test @MainActor func downloadingAWaitingOfferChecksAgainAndInstallsOnlyTheNewOffer() throws {
    let (update, updater) = updateProbe()
    try offer("0.16.0-beta.1", to: update, updater)

    update.proceed()
    #expect(updater.userChecks == 1)
    #expect(!update.canProceed)
    #expect(update.action == "Checking…")

    var choices: [SPUUserUpdateChoice] = []
    update.showUpdateFound(with: try appcastItem("0.16.0-beta.2"), state: try updateState()) { choices.append($0) }
    #expect(choices == [.install])
    #expect(update.version == "0.16.0-beta.2")
    #expect(update.stage == .downloading)
    #expect(!update.canProceed)
    update.checkForUpdateInformation()
    #expect(updater.probes == 0)

    var installChoices: [SPUUserUpdateChoice] = []
    update.showReady(toInstallAndRelaunch: { installChoices.append($0) })
    update.proceed()
    #expect(installChoices == [.install])
    #expect(updater.userChecks == 1)
}

@Test @MainActor func downloadDuringAnUpdatePollWaitsForIt() throws {
    let (update, updater) = updateProbe()
    try offer("0.16.0-beta.1", to: update, updater)
    update.checkForUpdateInformation()
    update.updater(updater, didFindValidUpdate: .empty())
    update.proceed()
    #expect(updater.userChecks == 0)
    #expect(!update.canProceed)
    #expect(update.action == "Checking…")
    updater.busy = false
    update.updater(updater, didFinishUpdateCycleFor: .updateInformation, error: nil)
    #expect(updater.userChecks == 1)
    #expect(updater.backgroundChecks == 0)

    let (polled, polledUpdater) = updateProbe()
    try offer("0.16.0-beta.1", to: polled, polledUpdater)
    polled.checkForUpdateInformation()
    polled.updater(polledUpdater, didFindValidUpdate: .empty())
    polledUpdater.busy = false
    polled.updater(polledUpdater, didFinishUpdateCycleFor: .updateInformation, error: nil)
    polled.proceed()
    var choices: [SPUUserUpdateChoice] = []
    polled.showUpdateFound(with: try appcastItem("0.16.0-beta.2"), state: try updateState()) { choices.append($0) }
    #expect(choices == [.install])
    #expect(polled.version == "0.16.0-beta.2")
    #expect(polled.stage == .downloading)
    #expect(polledUpdater.userChecks == 0)
}

@Test @MainActor func failedDownloadChecksDoNotDownloadALaterOffer() throws {
    let (update, updater) = updateProbe()
    try offer("0.16.0-beta.1", to: update, updater)
    update.proceed()
    update.dismissUpdateInstallation()
    updater.busy = false
    update.updater(updater, didFinishUpdateCycleFor: .updates, error: URLError(.notConnectedToInternet))
    #expect(update.version == nil)
    #expect(updater.userChecks == 1)

    var choices: [SPUUserUpdateChoice] = []
    update.showUpdateFound(with: try appcastItem("0.16.0-beta.2"), state: try updateState()) { choices.append($0) }
    #expect(choices == [.dismiss])
    #expect(update.canProceed)
    #expect(update.action == "Download")
}

@Test @MainActor func alreadyDownloadedUpdatesInstallWithoutCheckingAgain() throws {
    let (update, updater) = updateProbe()
    var choices: [SPUUserUpdateChoice] = []
    update.showUpdateFound(with: .empty(), state: try updateState(.downloaded)) { choices.append($0) }
    #expect(choices.isEmpty)
    update.proceed()
    #expect(choices == [.install])
    #expect(updater.userChecks == 0)
}

@Test func updateHistoryIncludesEveryReleaseInTheInstalledToOfferedRange() async throws {
    let data = Data("""
        [
          {"tag_name":"v0.5.0-beta.99","body":"* First fix","published_at":"2026-10-19T10:05:00Z"},
          {"tag_name":"v0.5.0-beta.94","body":"* Already installed","published_at":"2026-10-19T10:00:00Z"},
          {"tag_name":"appcast","body":"Feed","published_at":"2026-10-19T10:06:00Z"},
          {"tag_name":"v0.5.0-beta.113","body":"* Second fix","published_at":"2026-10-19T10:10:00Z"},
          {"tag_name":"v0.5.0-beta.121","body":"* Not offered yet","published_at":"2026-10-20T08:00:00Z"},
          {"tag_name":"v0.4.0","body":"* Old release","published_at":"2026-10-15T08:00:00Z"}
        ]
        """.utf8)
    let releases = try await UpdateRelease.load(after: "0.5.0-beta.94", through: "0.5.0-beta.113") { _ in data }
    #expect(releases.map(\.tagName) == ["v0.5.0-beta.113", "v0.5.0-beta.99"])
    #expect(releases.map(\.body) == ["* Second fix", "* First fix"])
}

@Test func updateHistoryReadsPastTheFirstPageAndIncludesTheStableRelease() async throws {
    let firstPage = try JSONSerialization.data(withJSONObject: (0..<100).map { index in
        ["tag_name": "v0.6.0-beta.\(index)", "body": "* Future change", "published_at": "2026-10-21T08:00:00Z"]
    })
    let secondPage = Data("""
        [
          {"tag_name":"v0.5.0","body":"* Stable release","published_at":"2026-10-20T12:00:00Z"},
          {"tag_name":"v0.5.0-beta.113","body":null,"published_at":"2026-10-20T11:00:00Z"},
          {"tag_name":"v0.5.0-beta.99","body":"* Already installed","published_at":"2026-10-19T10:05:00Z"}
        ]
        """.utf8)
    var pages: [String] = []
    let releases = try await UpdateRelease.load(after: "0.5.0-beta.99", through: "0.5.0") { url in
        pages.append(url.query!)
        return pages.count == 1 ? firstPage : secondPage
    }
    #expect(pages == ["per_page=100&page=1", "per_page=100&page=2"])
    #expect(releases.map(\.tagName) == ["v0.5.0", "v0.5.0-beta.113"])
}

@Test func updateHistoryReportsMissingReleaseBoundariesInsteadOfShowingAnIncompleteRange() async {
    await #expect(throws: URLError.self) {
        try await UpdateRelease.load(after: "0.5.0-beta.99", through: "0.5.0") { _ in Data("[]".utf8) }
    }
}
