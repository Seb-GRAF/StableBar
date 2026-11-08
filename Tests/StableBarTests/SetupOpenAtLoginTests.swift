import Foundation
import Testing
@testable import StableBar

/// A setup session over a stand-in Mac that records what setup asks macOS to change about opening at login.
@MainActor private func loginSession(inApplications: Bool) throws -> (SetupSession, ThemeGalleryFixture, BarStore, () -> [Bool]) {
    let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"clock","type":"clock","position":"right"}]}"#)
    let store = BarStore(configurationURL: fixture.url, themesDirectory: fixture.themes)
    store.reloadConfiguration()
    var hides = false
    var logins: [Bool] = []
    var system = SetupSystem()
    system.automationAccess = { _ in .allowed }
    system.setMenuBarHidden = { hides = $0 }
    system.menuBarHides = { hides }
    system.isTrusted = { true }
    system.calendarAccess = { .fullAccess }
    system.defaults = try #require(UserDefaults(suiteName: "StableBarTests.\(UUID().uuidString)"))
    system.workspaceSource = { $0 ?? .spaces }
    system.isInApplications = { inApplications }
    system.setOpenAtLogin = { logins.append($0) }
    return (SetupSession(store: store, system: system), fixture, store, { logins })
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
