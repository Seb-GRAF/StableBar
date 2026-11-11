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
    store.reloadConfiguration()
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
    session.preferences.clock = .twelveHour
    session.preferences.keepWindowsClear = true
    session.preferences.keepNotificationsClear = true
    session.preferences.deferMeetings = true
    session.preferences.appearance = .light
    session.preferences.theme = .package(id: "slate", version: nil)
    session.openAtLogin = opensAtLogin
    let choices = session.preferences
    session.step = SetupSession.Step.look.rawValue

    session.toggle(preset)
    let presetChoices = preset.preferences(workspaces: session.workspaceSource, placement: .top, hasBattery: true)
    var expected = choices
    expected.appearance = presetChoices.appearance
    expected.theme = presetChoices.theme
    expected.widgetSets = presetChoices.widgetSets
    #expect(session.preset == preset)
    #expect(session.preferences == expected)
    #expect(session.error == nil)
    #expect(session.openAtLogin == opensAtLogin)
    #expect(session.opensAtLogin == opensAtLogin)
    #expect(session.placementChoice == .top)
    #expect(session.placementTookEffect)
    #expect(session.menuBarHides)
    #expect(session.automationAccess == .allowed)
    #expect(session.step == SetupSession.Step.look.rawValue)
    #expect(logins().isEmpty)

    session.toggle(preset)
    expected.appearance = .current
    expected.theme = .current
    expected.widgetSets = []
    #expect(session.preset == nil)
    #expect(session.preferences == expected)
    #expect(session.error == nil)
    #expect(session.openAtLogin == opensAtLogin)
    #expect(session.opensAtLogin == opensAtLogin)
    #expect(session.placementChoice == .top)
    #expect(session.placementTookEffect)
    #expect(session.menuBarHides)
    #expect(session.automationAccess == .allowed)
    #expect(session.step == SetupSession.Step.look.rawValue)

    session.finish()
    #expect(session.finished)
    let saved = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: fixture.url))
    #expect(saved.widgets[0].content == .clock(format: SetupPreferences.clockFormat(hours: .twelveHour)))
    #expect(saved.bar.keepWindowsClear)
    #expect(saved.bar.keepNotificationsClear)
    #expect(logins() == (opensAtLogin ? [true] : []))
}

/// Retained choices can stop applying and apply again: a bar without a clock ignores its format, and a preset
/// without Meetings needs no Calendars access. Choosing Meetings again keeps it deferred and lets setup finish.
@Test(arguments: [SetupPreferences.Preset?.none, .minimal, .workday]) @MainActor
func setupFinishesWithKeptChoicesForMissingWidgets(preset: SetupPreferences.Preset?) async throws {
    let (session, fixture, store, logins) = try loginSession(
        inApplications: true, configuration: #"{"bar":{"belowMenuBar":true},"widgets":[]}"#, calendars: .denied)
    defer { store.stop(); fixture.close() }
    await session.place(.belowMenuBar)
    session.toggle(.workday)
    session.preferences.clock = .twelveHour
    session.preferences.deferMeetings = true
    session.toggle(.minimal)
    if let preset {
        if preset != .minimal { session.toggle(preset) }
    } else {
        session.toggle(.minimal)
    }
    #expect(session.preset == preset)
    #expect(session.preferences.clock == .twelveHour)
    #expect(session.preferences.deferMeetings)
    #expect(session.needsCalendarSetup == (preset == .workday))
    #expect(!session.needsCalendarAccess)
    #expect(session.missingPermissions.isEmpty)
    session.finish()
    #expect(session.finished)
    #expect(session.error == nil)
    let saved = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: fixture.url))
    #expect(!saved.widgets.contains { if case .clock = $0.content { true } else { false } })
    if preset == .workday {
        #expect(saved.widgets.first { $0.id == "meeting" }?.enabled == false)
    } else {
        #expect(!saved.widgets.contains { $0.id == "meeting" })
        #expect(!saved.providers.values.contains { $0.type == "calendar" })
    }
    #expect(try fixture.document()["widgetOverrides"] == nil)
    #expect(logins().isEmpty)
}

/// Replacing the menu bar keeps it hidden even while StableBar isn't running, so setup turns on Open at login for an
/// app in Applications, unless the person turns it off.
@Test @MainActor func replacingTheMenuBarTurnsOnOpenAtLogin() async throws {
    let (session, fixture, store, logins) = try loginSession(inApplications: true)
    defer { store.stop(); fixture.close() }
    #expect(!session.opensAtLogin)
    await session.place(.top)
    #expect(session.opensAtLogin)
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

/// Keeping the menu bar, or running StableBar from outside Applications, leaves Open at login as it is.
@Test(arguments: [(SetupPreferences.Placement.belowMenuBar, true), (.top, false)]) @MainActor
func openAtLoginStaysAsItIsOtherwise(placement: SetupPreferences.Placement, inApplications: Bool) async throws {
    let (session, fixture, store, logins) = try loginSession(inApplications: inApplications)
    defer { store.stop(); fixture.close() }
    await session.place(placement)
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
