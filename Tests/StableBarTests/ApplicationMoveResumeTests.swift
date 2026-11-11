import Foundation
import ServiceManagement
import Testing
@testable import StableBar

@Test func applicationMoveResumeRoundTripsAndIsDeletedBeforeUse() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ApplicationMoveResumeStore(domain: "StableBarTests.MoveResume.\(directory.lastPathComponent)")
    defer { UserDefaults.standard.removePersistentDomain(forName: store.domain) }
    let configuration = directory.appending(path: "config.json")
    let preferences = SetupPreferences(appearance: .dark, placement: .top, clock: .twelveHour,
        theme: .package(id: "phosphor", version: "1.0.0"), widgetSets: [.workspaces(.spaces), .meetings, .sound],
        workspaces: .spaces, keepWindowsClear: true, keepNotificationsClear: false, deferMeetings: true)
    let snapshot = ApplicationMoveResume.Setup(step: 2, preferences: preferences, preset: .developer, openAtLogin: true,
        placementChoice: .top, placementAwaitingAccess: .belowMenuBar, menuBarHidAtStart: false,
        stableBarHidMenuBarAtStart: false, opensAtLoginAtStart: false)
    let edit = ConfigurationEdit(action: .bar, properties: ["height": .number(38)], profile: "Night")
    let resume = ApplicationMoveResume(kind: .setup, configuration: configuration, setup: snapshot,
                                       edits: [.init(edit)])
    try store.save(resume)
    let read = try #require(store.take(configuration: configuration, now: resume.timestamp))
    #expect(UserDefaults(suiteName: store.domain)?.data(forKey: ApplicationMoveResumeStore.key) == nil)
    #expect(read.kind == .setup)
    #expect(read.setup?.preferences == preferences)
    #expect(read.setup?.step == 2)
    #expect(read.setup?.preset == .developer)
    #expect(read.setup?.openAtLogin == true)
    #expect(read.setup?.placementAwaitingAccess == .belowMenuBar)
    #expect(read.edits.first?.restored.profile == "Night")
    #expect(read.edits.first?.restored.properties == edit.properties)
    #expect(store.take(configuration: configuration) == nil)
}

@Test(arguments: ["expired", "boundary", "future", "corrupt", "wrongType", "version", "missingSetup", "step"])
func applicationMoveResumeDiscardsUnusableRecords(reason: String) throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ApplicationMoveResumeStore(domain: "StableBarTests.MoveResume.\(directory.lastPathComponent)")
    defer { UserDefaults.standard.removePersistentDomain(forName: store.domain) }
    let configuration = directory.appending(path: "config.json")
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    var resume = ApplicationMoveResume(kind: .settings, configuration: configuration, timestamp: now)
    switch reason {
    case "expired": resume.timestamp = now.addingTimeInterval(-901)
    case "boundary": resume.timestamp = now.addingTimeInterval(-900)
    case "future": resume.timestamp = now.addingTimeInterval(1)
    case "version": resume.version = 2
    case "missingSetup": resume.kind = .setup
    case "step":
        resume.kind = .setup
        resume.setup = .init(step: 99, preferences: SetupPreferences(), openAtLogin: true,
                            menuBarHidAtStart: false, stableBarHidMenuBarAtStart: false, opensAtLoginAtStart: false)
    default: break
    }
    try store.save(resume)
    if reason == "corrupt" {
        UserDefaults(suiteName: store.domain)?.set(Data("broken json".utf8), forKey: ApplicationMoveResumeStore.key)
    }
    if reason == "wrongType" {
        UserDefaults(suiteName: store.domain)?.set("broken json", forKey: ApplicationMoveResumeStore.key)
    }
    #expect(store.take(configuration: configuration, now: now) == nil)
    #expect(UserDefaults(suiteName: store.domain)?.object(forKey: ApplicationMoveResumeStore.key) == nil)
}

@Test func applicationMoveResumeLeavesAnotherConfigurationsRecordUntilItMatchesOrExpires() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let store = ApplicationMoveResumeStore(domain: "StableBarTests.MoveResume.\(directory.lastPathComponent)")
    defer { UserDefaults.standard.removePersistentDomain(forName: store.domain) }
    let configuration = directory.appending(path: "config.json")
    let other = directory.appending(path: "other.json")
    let now = Date()
    let resume = ApplicationMoveResume(kind: .settings, configuration: configuration, timestamp: now)
    try store.save(resume)
    let data = UserDefaults(suiteName: store.domain)?.data(forKey: ApplicationMoveResumeStore.key)
    #expect(store.take(configuration: other, now: now) == nil)
    #expect(UserDefaults(suiteName: store.domain)?.data(forKey: ApplicationMoveResumeStore.key) == data)
    #expect(store.take(configuration: configuration, now: now)?.kind == .settings)
    #expect(UserDefaults(suiteName: store.domain)?.data(forKey: ApplicationMoveResumeStore.key) == nil)

    try store.save(resume)
    #expect(store.take(configuration: other, now: now.addingTimeInterval(900)) == nil)
    #expect(UserDefaults(suiteName: store.domain)?.data(forKey: ApplicationMoveResumeStore.key) == nil)
}

@Test func applicationMoveResumeAcceptsARecentRecordForTheSameStandardizedPath() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ApplicationMoveResumeStore(domain: "StableBarTests.MoveResume.\(directory.lastPathComponent)")
    defer { UserDefaults.standard.removePersistentDomain(forName: store.domain) }
    let configuration = directory.appending(path: "config.json")
    let now = Date()
    try store.save(ApplicationMoveResume(kind: .settings, configuration: configuration, timestamp: now.addingTimeInterval(-899)))
    #expect(store.take(configuration: directory.appending(path: "sub/../config.json"), now: now)?.kind == .settings)
}

@Test func applicationMoveRelaunchKeepsArgumentsAndResolvesTheConfiguration() {
    let configuration = URL(filePath: "/tmp/a folder/config.json")
    #expect(ApplicationMoveRelaunch.arguments(["--config", "relative.json"], configuration: configuration)
            == ["--config", configuration.path])
    #expect(ApplicationMoveRelaunch.arguments([], configuration: configuration) == ["--config", configuration.path])
    #expect(ApplicationMoveRelaunch.arguments(["--config", "relative.json", "kept"], configuration: configuration)
            == ["--config", configuration.path, "kept"])
    if case let .finishApplicationMove(url, pid) = try? LaunchCommand(arguments: ["--finish-application-move", "/tmp/plan.json", "42"]) {
        #expect(url.path == "/tmp/plan.json")
        #expect(pid == 42)
    } else { Issue.record("Missing helper command") }
}

@Test func applicationMoveResumeDoesNotApplyAnOwnBarsEditsToAnotherScreenSetup() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ApplicationMoveResumeStore(domain: "StableBarTests.MoveResume.\(directory.lastPathComponent)")
    defer { UserDefaults.standard.removePersistentDomain(forName: store.domain) }
    let configuration = directory.appending(path: "config.json")
    let ownBar = directory.appending(path: "setup-monitor.json")
    let record = ApplicationMoveResume(kind: .settings, configuration: configuration, barConfiguration: ownBar)
    try store.save(record)
    #expect(store.take(configuration: configuration, barConfiguration: configuration) == nil)
    #expect(UserDefaults(suiteName: store.domain)?.data(forKey: ApplicationMoveResumeStore.key) != nil)
    #expect(store.take(configuration: configuration, barConfiguration: ownBar)?.barConfiguration == ownBar)
}

@Test(arguments: [false, true]) @MainActor
func applicationMoveManualSetupOpenBeforeAutomaticResumeUsesSavedChoices(ownBar: Bool) throws {
    let fixture = try ThemeGalleryFixture(#"{"widgets":[]}"#)
    let store = BarStore(configurationURL: fixture.url, themesDirectory: fixture.themes)
    let domain = "StableBarTests.MoveLaunch.\(UUID().uuidString)"
    let resumeStore = ApplicationMoveResumeStore(domain: domain)
    let defaults = try #require(UserDefaults(suiteName: domain))
    defer { store.stop(); fixture.close(); defaults.removePersistentDomain(forName: domain) }
    let screenSetup = ScreenSetup([BarDisplay(id: 1, isBuiltIn: true, isMain: true, notch: nil)])
    if ownBar {
        try FileManager.default.copyItem(at: fixture.url, to: store.ownBarURL(for: screenSetup))
    }
    store.prepareScreenSetup(screenSetup)
    let preferences = SetupPreferences(appearance: .dark, clock: .twelveHour, workspaces: .spaces,
                                       keepWindowsClear: true, keepNotificationsClear: false, deferMeetings: true)
    let snapshot = ApplicationMoveResume.Setup(step: SetupSession.Step.touches.rawValue,
        preferences: preferences, preset: .developer, openAtLogin: true,
        menuBarHidAtStart: false, stableBarHidMenuBarAtStart: false, opensAtLoginAtStart: false)
    let edit = ConfigurationEdit(action: .bar, properties: ["height": .number(38)])
    let record = ApplicationMoveResume(kind: .setup, configuration: fixture.url, barConfiguration: store.configurationURL,
                                       setup: snapshot, edits: [.init(edit)], failure: "Recovered setup.")
    try resumeStore.save(record)
    let launchResume = ApplicationMoveLaunchResume()
    // This happens before loading the shell environment or starting the bar.
    launchResume.load(for: store, from: resumeStore)
    #expect(launchResume.wasResuming)
    #expect(launchResume.pendingKind == .setup)
    #expect(defaults.data(forKey: ApplicationMoveResumeStore.key) == nil)
    #expect(store.sessionEdits.first?.properties == edit.properties)
    store.reloadConfiguration()
    let window = SetupWindow(launchResume: launchResume)
    var system = SetupSystem()
    system.defaults = defaults
    system.isInApplications = { true }
    system.loginStatus = { .notRegistered }
    system.menuBarHides = { false }
    system.setMenuBarHidden = { _ in Issue.record("Preparing a window must not change this Mac’s menu bar") }
    system.setOpenAtLogin = { _ in Issue.record("Preparing a window must not register a login item") }
    system.isTrusted = { true }
    system.calendarAccess = { .fullAccess }
    system.workspaceSource = { _ in .spaces }
    // Exercise the first-open path without displaying a window or changing this Mac's settings.
    let session = window.prepareSession(store: store, system: system)
    #expect(session.step == snapshot.step)
    #expect(session.preferences == preferences)
    #expect(session.preset == .developer)
    #expect(session.openAtLogin == true)
    #expect(session.applicationMove.error == record.failure)
    #expect(launchResume.pendingKind == nil)
    #expect(launchResume.wasResuming) // The automatic launch must not fall back to a second setup.
    session.preferences.clock = .twentyFourHour
    #expect(window.prepareSession(store: store, system: system) === session)
    #expect(session.preferences.clock == .twentyFourHour)
    #expect(launchResume.take(for: .setup) == nil)
    session.cancel()
    #expect(store.sessionEdits.first?.properties == edit.properties)
}

@Test @MainActor func applicationMoveManualSettingsOpenBeforeAutomaticResumeKeepsTheFailure() throws {
    let fixture = try ThemeGalleryFixture(#"{"widgets":[]}"#)
    let store = BarStore(configurationURL: fixture.url, themesDirectory: fixture.themes)
    let resumeStore = ApplicationMoveResumeStore(domain: "StableBarTests.MoveLaunch.\(UUID().uuidString)")
    defer { store.stop(); fixture.close(); UserDefaults.standard.removePersistentDomain(forName: resumeStore.domain) }
    let record = ApplicationMoveResume(kind: .settings, configuration: fixture.url,
                                       failure: "Couldn’t open StableBar in Applications. Try again or use Finder.")
    try resumeStore.save(record)
    let launchResume = ApplicationMoveLaunchResume()
    launchResume.load(for: store, from: resumeStore)
    // Opening the other window must not consume Settings' record.
    #expect(launchResume.take(for: .setup) == nil)
    #expect(launchResume.pendingKind == .settings)
    let window = CustomizationWindow(launchResume: launchResume)
    let controller = window.applicationMove
    #expect(controller.error == record.failure)
    #expect(launchResume.pendingKind == nil)
    #expect(launchResume.wasResuming)
    #expect(window.applicationMove === controller)
    #expect(window.applicationMove.error == record.failure)
    #expect(launchResume.take(for: .settings) == nil)
}

@Test(arguments: SetupSession.Step.allCases.indices) @MainActor
func applicationMoveResumesSetupChoicesWithoutSavingThem(step: Int) async throws {
    let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"clock","type":"clock","position":"right"}]}"#)
    let store = BarStore(configurationURL: fixture.url, themesDirectory: fixture.themes)
    store.reloadConfiguration()
    defer { store.stop(); fixture.close() }
    let original = try Data(contentsOf: fixture.url)
    let existingEdit = ConfigurationEdit(action: .bar, properties: ["height": .number(38)])
    try store.setSessionEdits([existingEdit])
    var hides = false
    let suite = "StableBarTests.MoveResume.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var system = SetupSystem()
    system.defaults = defaults
    system.automationAccess = { _ in .allowed }
    system.setMenuBarHidden = { hides = $0 }
    system.menuBarHides = { hides }
    system.isTrusted = { true }
    system.calendarAccess = { .fullAccess }
    system.isInApplications = { true }
    system.loginStatus = { .notRegistered }
    system.setOpenAtLogin = { _ in Issue.record("Register only at Finish setup") }
    system.workspaceSource = { _ in .spaces }
    let before = SetupSession(store: store, system: system)
    await before.place(.top)
    before.step = step
    before.toggle(.developer)
    before.preferences.clock = .twelveHour
    before.preferences.keepWindowsClear = true
    before.preferences.keepNotificationsClear = false
    before.preferences.deferMeetings = true
    let record = before.resumeAfterMoving()
    let resumed = SetupSession(store: store, system: system, resume: record)
    #expect(resumed.step == step)
    #expect(resumed.preferences == before.preferences)
    #expect(resumed.preset == .developer)
    #expect(resumed.placementChoice == .top)
    #expect(resumed.placementTookEffect)
    #expect(resumed.opensAtLogin)
    #expect(resumed.openAtLogin == true)
    #expect(resumed.changedMenuBar)
    #expect(!resumed.finished)
    #expect(try Data(contentsOf: fixture.url) == original)
    // Main's preset merge also applies after relaunch: selecting and deselecting keep later choices.
    for preset in [SetupPreferences.Preset.minimal, .minimal] {
        resumed.toggle(preset)
        #expect(resumed.preferences.placement == .top)
        #expect(resumed.preferences.workspaces == .spaces)
        #expect(resumed.preferences.clock == .twelveHour)
        #expect(resumed.preferences.keepWindowsClear == true)
        #expect(resumed.preferences.keepNotificationsClear == false)
        #expect(resumed.preferences.deferMeetings)
        #expect(resumed.openAtLogin == true)
        #expect(try Data(contentsOf: fixture.url) == original)
    }
    #expect(resumed.preset == nil)
    resumed.cancel()
    for _ in 0..<1000 {
        if !hides { break }
        await Task.yield()
    }
    #expect(!hides)
    #expect(store.sessionEdits.count == 1)
    #expect(store.sessionEdits.first?.properties == existingEdit.properties)
    #expect(try Data(contentsOf: fixture.url) == original)
}

@Test(arguments: [false, true]) @MainActor
func applicationMoveRestoresOpenAtLoginOnlyInApplications(inApplications: Bool) throws {
    let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"clock","type":"clock","position":"right"}]}"#)
    let store = BarStore(configurationURL: fixture.url, themesDirectory: fixture.themes)
    store.reloadConfiguration()
    defer { store.stop(); fixture.close() }
    let domain = "StableBarTests.MoveLogin.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain) }
    var logins: [Bool] = []
    var system = SetupSystem()
    system.defaults = defaults
    system.isTrusted = { true }
    system.calendarAccess = { .fullAccess }
    system.isInApplications = { inApplications }
    system.loginStatus = { .notRegistered }
    system.setOpenAtLogin = { logins.append($0) }
    system.menuBarHides = { true }
    system.workspaceSource = { _ in .spaces }
    let snapshot = ApplicationMoveResume.Setup(step: 2, preferences: SetupPreferences(), openAtLogin: true,
        menuBarHidAtStart: true, stableBarHidMenuBarAtStart: false, opensAtLoginAtStart: false)
    let resume = ApplicationMoveResume(kind: .setup, configuration: fixture.url, setup: snapshot)
    let session = SetupSession(store: store, system: system, resume: resume)
    #expect(session.openAtLogin == (inApplications ? true : nil))
    #expect(session.opensAtLogin == inApplications)
    // Also guard Finish setup against a stale choice from a hidden switch outside Applications.
    session.openAtLogin = true
    session.finish()
    #expect(session.finished)
    #expect(logins == (inApplications ? [true] : []))
}

@Test func applicationMoveResumeIsRemovedWithTheDefaultsDomain() throws {
    let domain = "StableBarTests.MoveUninstall.\(UUID().uuidString)"
    let store = ApplicationMoveResumeStore(domain: domain)
    defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
    let configuration = URL(filePath: "/tmp/stand-in-config.json")
    try store.save(ApplicationMoveResume(kind: .settings, configuration: configuration))
    let defaults = try #require(UserDefaults(suiteName: domain))
    #expect(defaults.data(forKey: ApplicationMoveResumeStore.key) != nil)
    // Uninstall clears this same domain; no separate Application Support file is left behind.
    defaults.removePersistentDomain(forName: domain)
    defaults.synchronize()
    #expect(store.take(configuration: configuration) == nil)
}
