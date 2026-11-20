import AppKit
import CoreServices
import EventKit
import Foundation
import Testing
@testable import StableBar

private struct Refusal: Error {}

@MainActor
private func preferences(menuBarHides: Bool, turnedOnByStableBar: Bool) throws -> (UserDefaults, String) {
    let suite = "StableBarTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.set(menuBarHides, forKey: "_HIHideMenuBar")
    MenuBarAutoHide.setTurnedOnByStableBar(turnedOnByStableBar, in: defaults)
    return (defaults, suite)
}

@MainActor
@Test func menuBarAutoHideTurnedOnInSettingsIsStableBars() async throws {
    let (defaults, suite) = try preferences(menuBarHides: false, turnedOnByStableBar: false)
    defer { defaults.removePersistentDomain(forName: suite) }
    var requested: [Bool] = []
    try await MenuBarAutoHide.change(to: true, in: defaults) { requested.append($0) }
    #expect(requested == [true])
    #expect(MenuBarAutoHide.turnedOnByStableBar(in: defaults))
}

@MainActor
@Test func menuBarAutoHideTurnedOffInSettingsIsForgotten() async throws {
    let (defaults, suite) = try preferences(menuBarHides: true, turnedOnByStableBar: true)
    defer { defaults.removePersistentDomain(forName: suite) }
    try await MenuBarAutoHide.change(to: false, in: defaults) { _ in }
    #expect(!MenuBarAutoHide.turnedOnByStableBar(in: defaults))
}

@MainActor
@Test func menuBarAutoHideKeepsItsRecordWhenTheChangeFails() async throws {
    let (defaults, suite) = try preferences(menuBarHides: false, turnedOnByStableBar: false)
    defer { defaults.removePersistentDomain(forName: suite) }
    await #expect(throws: Refusal.self) { try await MenuBarAutoHide.change(to: true, in: defaults) { _ in throw Refusal() } }
    #expect(!MenuBarAutoHide.turnedOnByStableBar(in: defaults))
}

@Test func settingsSearchFindsMenuBarAutoHide() {
    #expect(SettingsSearchResult.allCases.filter { $0.matches("auto-hide menu bar") }.contains(.menuBar))
    #expect(SettingsSearchResult.menuBar.matches("automatically hide"))
}

@Test func menuBarAutoHideAccessFollowsTheAppleEventsPermission() {
    #expect(MenuBarAutoHide.access(for: OSStatus(noErr)) == .allowed)
    #expect(MenuBarAutoHide.access(for: OSStatus(errAEEventNotPermitted)) == .denied)
    #expect(MenuBarAutoHide.access(for: OSStatus(errAEEventWouldRequireUserConsent)) == .undecided)
    #expect(MenuBarAutoHide.access(for: OSStatus(procNotFound)) == .undecided)
}

/// Holds macOS's Automation dialog open until the test answers it.
@MainActor
private final class AutomationDialog {
    private var answer: CheckedContinuation<MenuBarAutoHide.Access, Never>?
    private(set) var shown = 0
    var isOpen: Bool { answer != nil }

    func ask() async -> MenuBarAutoHide.Access {
        shown += 1
        return await withCheckedContinuation { answer = $0 }
    }

    func reply(_ access: MenuBarAutoHide.Access) {
        answer?.resume(returning: access)
        answer = nil
    }

    /// False when setup never asked macOS.
    func waitUntilOpen() async -> Bool {
        for _ in 0..<1000 where !isOpen { await Task.yield() }
        return isOpen
    }
}

/// A setup session over a scratch configuration whose macOS state is faked and whose menu bar changes are
/// recorded instead of made.
@MainActor
private func setupSession(configuration: String = #"{"widgets":[{"id":"clock","type":"clock","position":"right"}]}"#,
                          menuBarHides: Bool = false, trusted: Bool = true, calendars: EKAuthorizationStatus = .fullAccess,
                          completed: Bool = false, workspaces: @escaping (WorkspaceSource?) -> WorkspaceSource = { $0 ?? .spaces },
                          _ access: @escaping (Bool) async -> MenuBarAutoHide.Access)
    throws -> (SetupSession, ThemeGalleryFixture, BarStore, () -> [Bool]) {
    let fixture = try ThemeGalleryFixture(configuration)
    let store = BarStore(configurationURL: fixture.url, themesDirectory: fixture.themes)
    store.configurationStore.reloadConfiguration()
    var changes: [Bool] = []
    let defaults = UserDefaults(suiteName: "StableBarTests.\(UUID().uuidString)")!
    if completed { defaults.set(true, forKey: SetupProgress.completedKey) }
    let system = SetupSystem(automationAccess: access, setMenuBarHidden: { changes.append($0) },
                             menuBarHides: { changes.last ?? menuBarHides }, isTrusted: { trusted },
                             calendarAccess: { calendars }, defaults: defaults, workspaceSource: workspaces)
    return (SetupSession(store: store, system: system), fixture, store, { changes })
}

/// Without Automation access the macOS menu bar stays, so the bar sits below it, and setup still waits to put it in
/// the menu bar's place once access is allowed.
@MainActor
@Test func setupPutsTheBarBelowTheMenuBarWithoutAutomationAccess() async throws {
    let (session, fixture, store, changes) = try setupSession { _ in .denied }
    defer { store.stop(); fixture.close() }
    #expect(session.preferences.placement == .top)
    await session.place(.top)
    #expect(changes().isEmpty)
    #expect(!session.menuBarHides)
    #expect(session.placementAwaitingAccess == .top)
    #expect(session.preferences.placement == .belowMenuBar)
    #expect(store.configuration?.bar.belowMenuBar == true)
    #expect(session.error == nil)
}

@MainActor
@Test func setupAsksForAutomationAccessOnceBeforeHidingTheMenuBar() async throws {
    let dialog = AutomationDialog()
    let (session, fixture, store, changes) = try setupSession { asking in asking ? await dialog.ask() : .undecided }
    defer { store.stop(); fixture.close() }
    let first = Task { await session.place(.top) }
    try #require(await dialog.waitUntilOpen())
    #expect(session.waitingForMenuBarAccess)
    let second = Task { await session.place(.top) }
    await Task.yield()
    dialog.reply(.allowed)
    await first.value
    await second.value
    #expect(dialog.shown == 1)
    #expect(changes() == [true])
    #expect(session.menuBarHides)
    #expect(session.preferences.placement == .top)
    #expect(!session.waitingForMenuBarAccess)
}

@MainActor
@Test func setupHidesTheMenuBarOnceAutomationAccessIsAllowed() async throws {
    var allowed = false
    let (session, fixture, store, changes) = try setupSession { _ in allowed ? .allowed : .denied }
    defer { store.stop(); fixture.close() }
    await session.place(.top)
    #expect(changes().isEmpty)
    #expect(session.preferences.placement == .belowMenuBar)
    session.refreshAccess()
    for _ in 0..<20 { await Task.yield() }
    #expect(changes().isEmpty)
    allowed = true
    session.refreshAccess()
    for _ in 0..<200 where changes().isEmpty || session.preferences.placement != .top { await Task.yield() }
    #expect(changes() == [true])
    #expect(session.placementAwaitingAccess == nil)
    #expect(session.preferences.placement == .top)
}

@MainActor
@Test func setupAlwaysNeedsAccessibilityAndWontFinishWithoutIt() async throws {
    let (session, fixture, store, _) = try setupSession(trusted: false) { _ in .allowed }
    defer { store.stop(); fixture.close() }
    let saved = try Data(contentsOf: fixture.url)
    #expect(session.neededPermissions == [.accessibility])
    #expect(session.missingPermissions == [.accessibility])
    session.finish()
    #expect(!session.finished)
    #expect(session.error?.contains(session.system.macOSVersion.accessibilityName) == true)
    #expect(try Data(contentsOf: fixture.url) == saved)
}

@MainActor
@Test func setupNeedsCalendarsForMeetingsUntilSetUpLater() async throws {
    let (session, fixture, store, _) = try setupSession(calendars: .notDetermined) { _ in .allowed }
    defer { store.stop(); fixture.close() }
    #expect(!session.neededPermissions.contains(.calendars))
    session.preferences.widgetSets.append(.meetings)
    #expect(session.missingPermissions == [.calendars])
    session.finish()
    #expect(!session.finished)
    session.preferences.deferMeetings = true
    #expect(session.missingPermissions.isEmpty)
}

/// Skip setup asks first once something would be lost: a choice, Open at login, or the menu bar setup changed.
@MainActor
@Test func setupKnowsWhenSkippingWouldLoseChoices() async throws {
    let (session, fixture, store, _) = try setupSession { _ in .allowed }
    defer { store.stop(); fixture.close() }
    #expect(!session.hasChanges)
    session.step = .tune
    #expect(!session.hasChanges)
    session.preferences.theme = .package(id: "glass", version: nil)
    #expect(session.hasChanges)
    session.preferences.theme = .current
    #expect(!session.hasChanges)
    session.openAtLogin = true
    #expect(session.hasChanges)
    session.openAtLogin = nil
    await session.place(.top)
    // The bar was already headed for the top edge, so the hidden menu bar alone is a change.
    #expect(session.changedMenuBar)
    #expect(session.hasChanges)
}

@Test func setupOpensByItselfUntilItIsFinishedOrSkipped() throws {
    let defaults = try #require(UserDefaults(suiteName: "StableBarTests.\(UUID().uuidString)"))
    #expect(SetupProgress.opensAtLaunch(in: defaults))
    #expect(!SetupProgress.wasSkipped(in: defaults))
    defaults.set(true, forKey: SetupProgress.skippedKey)
    #expect(!SetupProgress.opensAtLaunch(in: defaults))
    #expect(SetupProgress.wasSkipped(in: defaults))
    defaults.set(true, forKey: SetupProgress.completedKey)
    #expect(!SetupProgress.opensAtLaunch(in: defaults))
    #expect(!SetupProgress.wasSkipped(in: defaults))
}

@MainActor
@Test func skippingSetupRemembersItAndFinishingMarksItCompleted() async throws {
    let (skipped, skippedFixture, skippedStore, _) = try setupSession { _ in .allowed }
    defer { skippedStore.stop(); skippedFixture.close() }
    skipped.cancel()
    #expect(SetupProgress.wasSkipped(in: skipped.system.defaults))
    let (finished, finishedFixture, finishedStore, _) = try setupSession(menuBarHides: true) { _ in .allowed }
    defer { finishedStore.stop(); finishedFixture.close() }
    finished.finish()
    #expect(finished.finished)
    #expect(finished.system.defaults.bool(forKey: SetupProgress.completedKey))
    #expect(!SetupProgress.opensAtLaunch(in: finished.system.defaults))
}

@Test func settingsOffersToFinishASkippedSetup() {
    #expect(!SetupProgress.offersToFinish(skipped: false, completed: false))
    #expect(SetupProgress.offersToFinish(skipped: true, completed: false))
    #expect(!SetupProgress.offersToFinish(skipped: true, completed: true))
}

/// The stage shows the starter for the menu bar's place from the start, and without Automation access the starter for
/// below the menu bar, which leaves out what the menu bar shows.
@MainActor
@Test func setupShowsTheStarterForWhereTheBarLands() async throws {
    let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    var starter = try JSONDecoder().decode([String: ConfigurationValue].self,
                                           from: Data(contentsOf: repository.appending(path: "Resources/config.json")))
    // Setup's preview reads with the app's bundled themes, which tests don't have.
    starter["theme"] = nil
    let below: [String: ConfigurationValue] = ["bar": .object(["belowMenuBar": .bool(true)]), "workspaceSource": .string("spaces"),
                                               "widgets": .array(SetupPreferences.belowMenuBarStarter.map(ConfigurationValue.object))]
    for document in [starter, below] {
        let (session, fixture, store, changes) = try setupSession(configuration: String(decoding: configurationData(document), as: UTF8.self)) { _ in .denied }
        defer { store.stop(); fixture.close() }
        #expect(store.configuration?.bar.belowMenuBar == false)
        #expect(store.configuration?.widgets.map(\.id) == ["apple", "app-menu", "sound", "clock", "menu-bar-items"])
        await session.place(.top)
        #expect(changes().isEmpty)
        #expect(store.configuration?.bar.belowMenuBar == true)
        #expect(store.configuration?.widgets.map(\.id) == ["workspaces", "system-monitor", "sound"])
        #expect(store.configuration?.workspaceSource == session.workspaceSource)
    }
}

/// When the first launch finds no window manager, such as before the login shell's PATH arrives, it writes Spaces
/// into the starter below the menu bar. Setup looks for a manager again until one finishes; after that, or once the
/// bar has changed, through its widgets, an override or its offset, Spaces is a choice it keeps.
@MainActor
@Test(arguments: [(false, "", WorkspaceSource.yabai), (true, "", .spaces), (false, "widget", .spaces), (false, "override", .spaces),
                  (false, "offset", .spaces)])
func setupLooksAgainForAManagerTheFirstLaunchMissed(completed: Bool, change: String, expected: WorkspaceSource) async throws {
    let mine: [String: ConfigurationValue] = ["id": .string("mine"), "type": .string("text"), "position": .string("left"), "text": .string("Hi")]
    let widgets = SetupPreferences.belowMenuBarStarter + (change == "widget" ? [mine] : [])
    // What the first launch writes: the starter's bar, below the menu bar, with the starter for that placement.
    var document: [String: ConfigurationValue] = [
        "bar": .object(["height": .number(40), "offset": .number(change == "offset" ? 6 : 0), "inset": .number(12), "spacing": .number(8),
                        "belowMenuBar": .bool(true)]),
        "workspaceSource": .string("spaces"), "widgets": .array(widgets.map(ConfigurationValue.object))
    ]
    if change == "override" { document["widgetOverrides"] = .object(["sound": .object(["priority": .number(5)])]) }
    let json = try #require(String(bytes: JSONEncoder().encode(document), encoding: .utf8))
    // Without Automation the bar stays below the menu bar, where the starter keeps its Workspaces.
    let (session, fixture, store, _) = try setupSession(configuration: json, completed: completed, workspaces: { $0 ?? .yabai }) { _ in .denied }
    defer { store.stop(); fixture.close() }
    await session.place(.top)
    #expect(session.workspaceSource == expected)
    #expect(store.configuration?.workspaceSource == expected)
    // Finishing saves what the preview showed.
    session.finish()
    #expect(session.finished)
    #expect(session.system.defaults.bool(forKey: SetupProgress.completedKey))
    let saved = try JSONDecoder().decode([String: ConfigurationValue].self, from: Data(contentsOf: fixture.url))
    #expect(saved["workspaceSource"] == .string(expected.rawValue))
}

/// Finishing touches checks the Switch to Desktop shortcuts whenever the bar setup builds shows macOS Spaces in
/// Workspaces, including the starter below the menu bar, which has Workspaces without any preset.
@MainActor
@Test func setupExplainsTheDesktopShortcutsForEveryBarWithSpaces() async throws {
    let starter: [String: ConfigurationValue] = ["bar": .object(["belowMenuBar": .bool(true)]), "workspaceSource": .string("spaces"),
                                                 "widgets": .array(SetupPreferences.belowMenuBarStarter.map(ConfigurationValue.object))]
    let json = try #require(String(bytes: JSONEncoder().encode(starter), encoding: .utf8))
    let (session, fixture, store, _) = try setupSession(configuration: json, workspaces: { _ in .spaces }) { _ in .denied }
    defer { store.stop(); fixture.close() }
    await session.place(.top)
    #expect(session.showsSpacesGuidance)
    // A bar without Workspaces has no desktops to switch.
    let (plain, plainFixture, plainStore, _) = try setupSession(workspaces: { _ in .spaces }) { _ in .allowed }
    defer { plainStore.stop(); plainFixture.close() }
    #expect(!plain.showsSpacesGuidance)
    // A preset that adds Workspaces brings the desktops, and the guidance, with it.
    plain.preferences = SetupPreferences.Preset.developer.preferences(workspaces: .spaces, placement: .top)
    #expect(plain.showsSpacesGuidance)
}

/// Allow on the stage hides the macOS menu bar live, with the starter for the menu bar's place, and the bar flies
/// there once macOS has answered.
@MainActor
@Test func setupsStageReplacesTheMenuBarLive() async throws {
    let starter: [String: ConfigurationValue] = ["bar": .object(["belowMenuBar": .bool(true)]), "workspaceSource": .string("spaces"),
                                                 "widgets": .array(SetupPreferences.belowMenuBarStarter.map(ConfigurationValue.object))]
    let json = try #require(String(bytes: JSONEncoder().encode(starter), encoding: .utf8))
    let (session, fixture, store, changes) = try setupSession(configuration: json) { _ in .allowed }
    defer { store.stop(); fixture.close() }
    #expect(session.step == .menuBar)
    #expect(!session.readyToLand)
    #expect(changes().isEmpty)
    await session.place(.top)
    #expect(changes() == [true])
    #expect(session.menuBarHides)
    #expect(session.readyToLand)
    #expect(store.configuration?.bar.belowMenuBar == false)
    #expect(store.configuration?.widgets.map(\.id) == ["apple", "app-menu", "sound", "clock", "menu-bar-items"])
}

/// A menu bar that already hides needs no change, so the bar lands at once.
@MainActor
@Test func setupLandsAtOnceWhenTheMenuBarAlreadyHides() async throws {
    let (session, fixture, store, changes) = try setupSession(menuBarHides: true) { _ in .denied }
    defer { store.stop(); fixture.close() }
    #expect(!session.readyToLand)
    await session.place(.top)
    #expect(changes().isEmpty)
    #expect(session.placementAwaitingAccess == nil)
    #expect(session.readyToLand)
}

/// Holds a call to macOS open until the test answers it.
@MainActor private final class HeldCall<Value: Sendable> {
    private var waiting: CheckedContinuation<Value, Never>?
    private var answer: Value?
    private(set) var started = false

    func wait() async -> Value {
        started = true
        if let answer { return answer }
        return await withCheckedContinuation { waiting = $0 }
    }

    func answer(_ value: Value) {
        answer = value
        waiting?.resume(returning: value)
        waiting = nil
    }
}

/// The bar stays on the stage while macOS asks for Automation access, and lands below the menu bar once it's refused.
@MainActor
@Test func setupLandsOnceMacOSAnswersForAutomation() async throws {
    let question = HeldCall<MenuBarAutoHide.Access>()
    let (session, fixture, store, changes) = try setupSession { asking in asking ? await question.wait() : .undecided }
    defer { store.stop(); fixture.close() }
    let replace = Task { await session.place(.top) }
    for _ in 0..<100 where !question.started { await Task.yield() }
    try #require(question.started)
    #expect(!session.readyToLand)
    question.answer(.denied)
    await replace.value
    #expect(session.placementAwaitingAccess == .top)
    #expect(session.preferences.placement == .belowMenuBar)
    #expect(session.readyToLand)
    #expect(changes().isEmpty)
}

/// The bar stays on the stage until Accessibility is allowed in System Settings, which setup checks again while it
/// shows.
@MainActor
@Test func setupLandsOnceAccessibilityIsAllowed() async throws {
    let fixture = try ThemeGalleryFixture(#"{"widgets":[]}"#)
    let store = BarStore(configurationURL: fixture.url, themesDirectory: fixture.themes)
    store.configurationStore.reloadConfiguration()
    defer { store.stop(); fixture.close() }
    var trusted = false
    let system = SetupSystem(automationAccess: { _ in .allowed }, setMenuBarHidden: { _ in }, menuBarHides: { true },
                             isTrusted: { trusted }, calendarAccess: { .fullAccess },
                             defaults: UserDefaults(suiteName: "StableBarTests.\(UUID().uuidString)")!)
    let session = SetupSession(store: store, system: system)
    await session.place(.top)
    #expect(!session.readyToLand)
    trusted = true
    #expect(!session.readyToLand)
    session.pollAccessibility()
    #expect(session.readyToLand)
}

/// Skip setup while setup is still hiding the menu bar: the menu bar ends as it was before setup, and the discarded
/// preview doesn't come back when the pending change finishes.
@MainActor
@Test func skippingSetupWhileTheMenuBarChangesPutsItBack() async throws {
    let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"clock","type":"clock","position":"right"}]}"#)
    let store = BarStore(configurationURL: fixture.url, themesDirectory: fixture.themes)
    store.configurationStore.reloadConfiguration()
    defer { store.stop(); fixture.close() }
    let gate = HeldCall<Void>()
    var hides = false
    var changes: [Bool] = []
    let system = SetupSystem(automationAccess: { _ in .allowed }, setMenuBarHidden: { hidden in
        changes.append(hidden)
        if hidden { await gate.wait() }
        hides = hidden
    }, menuBarHides: { hides }, isTrusted: { true }, calendarAccess: { .fullAccess },
       defaults: UserDefaults(suiteName: "StableBarTests.\(UUID().uuidString)")!)
    let before = store.configurationStore.sessionEdits.count
    let session = SetupSession(store: store, system: system)
    let replace = Task { await session.place(.top) }
    for _ in 0..<100 where !gate.started { await Task.yield() }
    try #require(gate.started)
    session.cancel()
    gate.answer(())
    await replace.value
    for _ in 0..<1000 where changes.count < 2 || hides { await Task.yield() }
    #expect(changes == [true, false])
    #expect(!hides)
    #expect(store.configurationStore.sessionEdits.count == before)
}

/// Skip setup while setup checks again whether a placement waiting for Automation access may go ahead: access turning
/// out allowed after setup closed doesn't apply the discarded placement.
@MainActor
@Test func skippingSetupWhileAccessIsCheckedAgainLeavesTheMenuBarAlone() async throws {
    let check = HeldCall<MenuBarAutoHide.Access>()
    var checks = 0
    let (session, fixture, store, changes) = try setupSession { _ in
        checks += 1
        return checks == 1 ? .denied : await check.wait()
    }
    defer { store.stop(); fixture.close() }
    await session.place(.top)
    try #require(session.placementAwaitingAccess == .top)
    session.refreshAccess()
    for _ in 0..<100 where !check.started { await Task.yield() }
    try #require(check.started)
    session.cancel()
    check.answer(.allowed)
    for _ in 0..<1000 where changes().isEmpty { await Task.yield() }
    #expect(changes().isEmpty)
    #expect(!session.menuBarHides)
}

/// A setup session whose menu bar changes go through `change`, which can hold or fail them, while macOS reports the
/// menu bar through `hides`.
@MainActor
private func setupSession(changing change: @escaping (Bool) async throws -> Void, hides: @escaping () -> Bool)
    throws -> (SetupSession, ThemeGalleryFixture, BarStore) {
    let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"clock","type":"clock","position":"right"}]}"#)
    let store = BarStore(configurationURL: fixture.url, themesDirectory: fixture.themes)
    store.configurationStore.reloadConfiguration()
    let system = SetupSystem(automationAccess: { _ in .allowed }, setMenuBarHidden: change, menuBarHides: hides,
                             isTrusted: { true }, calendarAccess: { .fullAccess },
                             defaults: UserDefaults(suiteName: "StableBarTests.\(UUID().uuidString)")!)
    return (SetupSession(store: store, system: system), fixture, store)
}

private struct TimedOut: Error {}

/// System Events can change the menu bar and still fail, as when it times out. Setup then goes by what macOS reports,
/// so skipping setup still puts the menu bar back.
@MainActor
@Test func skippingSetupAfterAFailedChangeThatTookEffectPutsTheMenuBarBack() async throws {
    var hides = false
    var changes: [Bool] = []
    let (session, fixture, store) = try setupSession(changing: { hidden in
        changes.append(hidden)
        hides = hidden
        if hidden { throw TimedOut() }
    }, hides: { hides })
    defer { store.stop(); fixture.close() }
    await session.place(.top)
    #expect(session.error != nil)
    session.cancel()
    for _ in 0..<1000 where changes.count < 2 { await Task.yield() }
    #expect(changes == [true, false])
    #expect(!hides)
}

/// A placement replaced while its menu bar change runs, here by Skip setup, doesn't report that change failing.
@MainActor
@Test func aReplacedPlacementDoesNotReportItsFailedChange() async throws {
    let gate = HeldCall<Void>()
    let (session, fixture, store) = try setupSession(changing: { hidden in
        guard hidden else { return }
        await gate.wait()
        throw TimedOut()
    }, hides: { false })
    defer { store.stop(); fixture.close() }
    let replace = Task { await session.place(.top) }
    for _ in 0..<100 where !gate.started { await Task.yield() }
    try #require(gate.started)
    session.cancel()
    gate.answer(())
    await replace.value
    #expect(session.error == nil)
}

/// A menu bar change that fails leaves the macOS menu bar showing, so the bar lands below it and setup says why.
@MainActor
@Test func aFailedMenuBarChangePutsTheBarBelowTheMenuBar() async throws {
    let (session, fixture, store) = try setupSession(changing: { _ in throw TimedOut() }, hides: { false })
    defer { store.stop(); fixture.close() }
    await session.place(.top)
    #expect(session.error != nil)
    #expect(!session.menuBarHides)
    #expect(session.preferences.placement == .belowMenuBar)
    #expect(session.readyToLand)
}
