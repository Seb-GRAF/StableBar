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
                          _ access: @escaping (Bool) async -> MenuBarAutoHide.Access)
    throws -> (SetupSession, ThemeGalleryFixture, BarStore, () -> [Bool]) {
    let fixture = try ThemeGalleryFixture(configuration)
    let store = BarStore(configurationURL: fixture.url, themesDirectory: fixture.themes)
    store.reloadConfiguration()
    var changes: [Bool] = []
    let system = SetupSystem(automationAccess: access, setMenuBarHidden: { changes.append($0) },
                             menuBarHides: { changes.last ?? menuBarHides }, isTrusted: { trusted },
                             calendarAccess: { calendars }, defaults: UserDefaults(suiteName: "StableBarTests.\(UUID().uuidString)")!)
    return (SetupSession(store: store, system: system), fixture, store, { changes })
}

@MainActor
@Test func setupLeavesTheMenuBarAloneWithoutAutomationAccess() async throws {
    let (session, fixture, store, changes) = try setupSession { _ in .denied }
    defer { store.stop(); fixture.close() }
    await session.place(.top)
    #expect(changes().isEmpty)
    #expect(!session.menuBarHides)
    #expect(session.placementAwaitingAccess == .top)
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
@Test func setupKeepsTheMenuBarChosenWhileMacOSAsks() async throws {
    let dialog = AutomationDialog()
    let (session, fixture, store, changes) = try setupSession { asking in asking ? await dialog.ask() : .undecided }
    defer { store.stop(); fixture.close() }
    let replace = Task { await session.place(.top) }
    try #require(await dialog.waitUntilOpen())
    await session.place(.belowMenuBar)
    dialog.reply(.allowed)
    await replace.value
    #expect(changes().isEmpty)
    #expect(session.preferences.placement == .belowMenuBar)
    #expect(session.placementAwaitingAccess == nil)
}

@MainActor
@Test func setupHidesTheMenuBarOnceAutomationAccessIsAllowed() async throws {
    var allowed = false
    let (session, fixture, store, changes) = try setupSession { _ in allowed ? .allowed : .denied }
    defer { store.stop(); fixture.close() }
    await session.place(.top)
    #expect(changes().isEmpty)
    session.refreshAccess()
    for _ in 0..<20 { await Task.yield() }
    #expect(changes().isEmpty)
    allowed = true
    session.refreshAccess()
    for _ in 0..<200 where changes().isEmpty { await Task.yield() }
    #expect(changes() == [true])
    #expect(session.placementAwaitingAccess == nil)
    #expect(session.preferences.placement == .top)
}

@MainActor
@Test func setupAlwaysNeedsAccessibilityAndWontFinishWithoutIt() async throws {
    let (session, fixture, store, _) = try setupSession(trusted: false) { _ in .allowed }
    defer { store.stop(); fixture.close() }
    let saved = try Data(contentsOf: fixture.url)
    #expect(session.placement == .top)
    #expect(session.neededPermissions == [.accessibility, .automation])
    session.preferences.placement = .belowMenuBar
    #expect(session.neededPermissions == [.accessibility])
    #expect(session.missingPermissions == [.accessibility])
    session.finish()
    #expect(!session.finished)
    #expect(session.error?.contains("Accessibility") == true)
    #expect(try Data(contentsOf: fixture.url) == saved)
}

@MainActor
@Test func setupNeedsAutomationOnlyToChangeTheMenuBar() async throws {
    let (session, fixture, store, changes) = try setupSession { _ in .denied }
    defer { store.stop(); fixture.close() }
    session.preferences.placement = .belowMenuBar
    #expect(!session.neededPermissions.contains(.automation))
    await session.place(.top)
    #expect(session.missingPermissions == [.automation])
    await session.place(.belowMenuBar)
    #expect(session.missingPermissions.isEmpty)
    #expect(changes().isEmpty)

    let (hidden, hiddenFixture, hiddenStore, _) = try setupSession(menuBarHides: true) { _ in .denied }
    defer { hiddenStore.stop(); hiddenFixture.close() }
    hidden.preferences.placement = .top
    #expect(!hidden.neededPermissions.contains(.automation))
    hidden.preferences.placement = .belowMenuBar
    #expect(hidden.missingPermissions == [.automation])
}

@MainActor
@Test func setupAllowsAutomationAndAppliesTheWaitingPlacement() async throws {
    var answer = MenuBarAutoHide.Access.denied
    let (session, fixture, store, changes) = try setupSession { _ in answer }
    defer { store.stop(); fixture.close() }
    await session.place(.top)
    #expect(session.missingPermissions == [.automation])
    answer = .allowed
    await session.allowAutomation()
    #expect(changes() == [true])
    #expect(session.neededPermissions == [.accessibility, .automation])
    #expect(session.missingPermissions.isEmpty)
}

@MainActor
@Test func setupNeedsCalendarsForMeetingsUntilSetUpLater() async throws {
    let (session, fixture, store, _) = try setupSession(calendars: .notDetermined) { _ in .allowed }
    defer { store.stop(); fixture.close() }
    session.preferences.placement = .belowMenuBar
    #expect(!session.neededPermissions.contains(.calendars))
    session.preferences.widgetSets.append(.meetings)
    #expect(session.missingPermissions == [.calendars])
    session.finish()
    #expect(!session.finished)
    session.preferences.deferMeetings = true
    #expect(session.missingPermissions.isEmpty)
}

@MainActor
@Test(arguments: [(#"{"bar":{"belowMenuBar":true},"widgets":[]}"#, SetupPreferences.Placement.belowMenuBar),
                  (#"{"bar":{"belowMenuBar":true,"offset":8},"widgets":[]}"#, .current),
                  (#"{"bar":{"offset":0},"widgets":[]}"#, .top),
                  (#"{"bar":{"offset":12},"widgets":[]}"#, .current)])
func setupShowsWhereTheBarSits(configuration: String, placement: SetupPreferences.Placement) throws {
    let (session, fixture, store, _) = try setupSession(configuration: configuration) { _ in .allowed }
    defer { store.stop(); fixture.close() }
    #expect(session.placement == placement)
}

/// Setup used to write the menu bar's height as the offset; such a bar still shows as below the menu bar.
@MainActor
@Test func setupShowsAnEarlierBelowMenuBarOffsetAsBelowTheMenuBar() throws {
    let earlier = max(NSStatusBar.system.thickness, NSScreen.main?.safeAreaInsets.top ?? 0)
    let (session, fixture, store, _) = try setupSession(configuration: #"{"bar":{"offset":\#(earlier)},"widgets":[]}"#) { _ in .allowed }
    defer { store.stop(); fixture.close() }
    #expect(session.placement == .belowMenuBar)
}

/// Skip setup asks first once something would be lost: a choice, Open at login, or the menu bar setup changed.
@MainActor
@Test func setupKnowsWhenSkippingWouldLoseChoices() async throws {
    let (session, fixture, store, _) = try setupSession { _ in .allowed }
    defer { store.stop(); fixture.close() }
    #expect(!session.hasChanges)
    session.step = 3
    #expect(!session.hasChanges)
    session.preferences.theme = .builtIn
    #expect(session.hasChanges)
    session.preferences.theme = .current
    #expect(!session.hasChanges)
    session.openAtLogin = true
    #expect(session.hasChanges)
    session.openAtLogin = nil
    let placement = session.preferences.placement
    await session.place(.top)
    #expect(session.hasChanges)
    // place(.top) also changes the placement, so put it back: the hidden menu bar alone is a change.
    #expect(session.changedMenuBar)
    session.preferences.placement = placement
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
    // The menu bar already hides, so a bar on the top edge needs no Automation access to finish.
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

/// Keeping the menu bar turns the starter bar into the one for below the menu bar, live.
@MainActor
@Test func setupKeepingTheMenuBarShowsTheBelowMenuBarStarter() async throws {
    let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let starter = try String(contentsOf: repository.appending(path: "Resources/config.json"), encoding: .utf8)
    let (session, fixture, store, _) = try setupSession(configuration: starter) { _ in .allowed }
    defer { store.stop(); fixture.close() }
    await session.place(.belowMenuBar)
    #expect(store.configuration?.widgets.map(\.id) == ["workspaces", "system-monitor", "sound"])
    #expect(store.configuration?.workspaceSource == session.workspaceSource)
    await session.place(.top)
    #expect(store.configuration?.widgets.map(\.id) == ["apple", "app-menu", "sound", "clock", "menu-bar-items"])
}
