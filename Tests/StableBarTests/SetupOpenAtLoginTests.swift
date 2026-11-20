import EventKit
import Foundation
import ServiceManagement
import Testing
@testable import StableBar

/// A setup session over a stand-in Mac that records what setup asks macOS to change about opening at login.
@MainActor private func loginSession(inApplications: Bool,
                                    configuration: String = #"{"widgets":[{"id":"clock","type":"clock","position":"right"}]}"#,
                                    calendars: EKAuthorizationStatus = .fullAccess,
                                    status: @escaping () -> SMAppService.Status = { .notRegistered })
    throws -> (SetupSession, ThemeGalleryFixture, BarStore, () -> [Bool]) {
    let fixture = try ThemeGalleryFixture(configuration)
    let store = BarStore(configurationURL: fixture.url, themesDirectory: fixture.themes)
    store.configurationStore.reloadConfiguration()
    var hides = false
    var logins: [Bool] = []
    var system = SetupSystem()
    system.automationAccess = { _ in .allowed }
    system.setMenuBarHidden = { hides = $0 }
    system.menuBarHides = { hides }
    system.isTrusted = { true }
    system.calendarAccess = { calendars }
    system.hasBattery = { true }
    system.defaults = try #require(UserDefaults(suiteName: "StableBarTests.\(UUID().uuidString)"))
    system.workspaceSource = { $0 ?? .spaces }
    system.windowManagerRuns = { false }
    system.isInApplications = { inApplications }
    system.loginStatus = status
    system.setOpenAtLogin = { logins.append($0) }
    return (SetupSession(store: store, system: system), fixture, store, { logins })
}

/// Going back to choose another preset, or deselect it, keeps the choices made elsewhere in the tour.
@Test(arguments: SetupPreferences.Preset.allCases, [false, true]) @MainActor
func changingOrDeselectingASetupPresetKeepsLaterChoices(preset: SetupPreferences.Preset, opensAtLogin: Bool) async throws {
    let (session, fixture, store, logins) = try loginSession(inApplications: true)
    defer { store.stop(); fixture.close() }
    await session.place(.top)
    session.toggle(preset == .workday ? .minimal : .workday)
    session.preferences.deferMeetings = true
    session.preferences.theme = .package(id: "slate", version: nil)
    session.openAtLogin = opensAtLogin
    let choices = session.preferences
    session.step = .choose

    session.toggle(preset)
    let presetChoices = preset.preferences(workspaces: session.workspaceSource, placement: .top, hasBattery: true)
    var expected = choices
    // Without an answer from the Store, a preset has only its built-in widgets.
    expected.widgetSets = presetChoices.widgetSets.filter { if case .store = $0 { false } else { true } }
    #expect(session.preset == preset)
    #expect(session.preferences == expected)
    #expect(session.error == nil)
    #expect(session.openAtLogin == opensAtLogin)
    #expect(session.opensAtLogin == opensAtLogin)
    #expect(session.placementChoice == .top)
    #expect(session.readyToLand)
    #expect(session.menuBarHides)
    #expect(session.step == .choose)
    #expect(logins().isEmpty)

    session.toggle(preset)
    expected.widgetSets = []
    #expect(session.preset == nil)
    #expect(session.preferences == expected)
    #expect(session.error == nil)
    #expect(session.openAtLogin == opensAtLogin)
    #expect(session.opensAtLogin == opensAtLogin)
    #expect(session.placementChoice == .top)
    #expect(session.readyToLand)
    #expect(session.menuBarHides)
    #expect(session.step == .choose)

    session.finish()
    #expect(session.finished)
    let saved = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: fixture.url))
    #expect(saved.bar.keepWindowsClear)
    #expect(logins() == (opensAtLogin ? [true] : []))
}

/// Retained choices can stop applying and apply again: a preset without Meetings needs no Calendars access. Choosing
/// Meetings again keeps it deferred and lets setup finish.
@Test(arguments: [SetupPreferences.Preset?.none, .minimal, .workday]) @MainActor
func setupFinishesWithKeptChoicesForMissingWidgets(preset: SetupPreferences.Preset?) async throws {
    let (session, fixture, store, logins) = try loginSession(
        inApplications: true, configuration: #"{"bar":{"belowMenuBar":true},"widgets":[]}"#, calendars: .denied)
    defer { store.stop(); fixture.close() }
    await session.place(.belowMenuBar)
    session.toggle(.workday)
    session.preferences.deferMeetings = true
    session.toggle(.minimal)
    if let preset {
        if preset != .minimal { session.toggle(preset) }
    } else {
        session.toggle(.minimal)
    }
    #expect(session.preset == preset)
    #expect(session.preferences.deferMeetings)
    #expect(session.needsCalendarSetup == (preset == .workday))
    #expect(!session.needsCalendarAccess)
    #expect(session.missingPermissions.isEmpty)
    session.finish()
    #expect(session.finished)
    #expect(session.error == nil)
    // Workday's meeting names the theme's tokens, which only the loader resolves.
    let saved = try #require(fixture.document()["widgets"]).decoded([[String: ConfigurationValue]].self)
    #expect(!saved.contains { $0["type"] == .string("clock") })
    if preset == .workday {
        #expect(saved.first { $0["id"] == .string("meeting") }?["enabled"] == .bool(false))
    } else {
        #expect(!saved.contains { $0["type"] == .string("calendar") })
    }
    #expect(try fixture.document()["widgetOverrides"] == nil)
    #expect(logins() == [true])
}

/// In the menu bar's place, the bar keeps the menu bar hidden even while StableBar isn't running, so setup turns on
/// Open at login for an app in Applications, unless the person turns it off.
@Test @MainActor func setupTurnsOnOpenAtLogin() async throws {
    let (session, fixture, store, logins) = try loginSession(inApplications: true)
    defer { store.stop(); fixture.close() }
    #expect(session.opensAtLogin)
    await session.place(.top)
    session.finish()
    #expect(session.finished)
    #expect(logins() == [true])
}

@Test @MainActor func openAtLoginTurnedOffStaysOff() async throws {
    let (session, fixture, store, logins) = try loginSession(inApplications: true)
    defer { store.stop(); fixture.close() }
    await session.place(.top)
    session.openAtLogin = false
    #expect(!session.opensAtLogin)
    session.finish()
    #expect(session.finished)
    #expect(logins().isEmpty)
}

/// Open at login needs StableBar in Applications, so from elsewhere setup leaves it as it is.
@Test @MainActor func openAtLoginStaysAsItIsOutsideApplications() async throws {
    let (session, fixture, store, logins) = try loginSession(inApplications: false)
    defer { store.stop(); fixture.close() }
    await session.place(.top)
    #expect(!session.opensAtLogin)
    session.finish()
    #expect(session.finished)
    #expect(logins().isEmpty)
}

/// Turning Open at login off in System Settings while setup is open keeps it off: the recommendation only applies
/// while the status is still the one setup opened with.
@Test @MainActor func openAtLoginTurnedOffInSystemSettingsDuringSetupStaysOff() async throws {
    var status = SMAppService.Status.enabled
    let (session, fixture, store, logins) = try loginSession(inApplications: true, status: { status })
    defer { store.stop(); fixture.close() }
    #expect(session.opensAtLogin)
    await session.place(.top)
    status = .notRegistered
    session.refreshAccess()
    #expect(!session.opensAtLogin)
    session.finish()
    #expect(session.finished)
    #expect(logins().isEmpty)
}
