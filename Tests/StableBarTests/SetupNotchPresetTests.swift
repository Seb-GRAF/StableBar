import Foundation
import Testing
@testable import StableBar

/// Opening or closing the lid can change which presets fit, without losing a choice already made.
@Test @MainActor func setupUpdatesNotchPresetsWhenDisplaysChange() throws {
    let fixture = try ThemeGalleryFixture()
    let store = try fixture.store()
    defer { store.stop(); fixture.close() }
    let suite = "StableBarTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var notched = false
    var system = SetupSystem()
    system.menuBarHides = { true }
    system.isTrusted = { true }
    system.calendarAccess = { .fullAccess }
    system.hasBattery = { true }
    system.hasNotchedDisplay = { notched }
    system.loginStatus = { .notRegistered }
    system.defaults = defaults
    system.previewsOnTheBar = false
    system.workspaceSource = { $0 ?? .spaces }
    let session = SetupSession(store: store, system: system)
    #expect(session.preferences.placement == .current)
    #expect(session.placement == .top)
    #expect(!session.hasNotchedDisplay)
    #expect(!session.offeredPresets.contains(.notch))

    notched = true
    session.refreshDisplays()
    #expect(session.hasNotchedDisplay)
    #expect(session.offeredPresets.contains(.notch))
    session.toggle(.notch)
    let preferences = session.preferences

    notched = false
    session.refreshDisplays()
    #expect(!session.hasNotchedDisplay)
    #expect(session.preset == .notch)
    #expect(session.preferences == preferences)
    #expect(session.offeredPresets.contains(.notch))

    session.toggle(.notch)
    #expect(session.preset == nil)
    #expect(!session.offeredPresets.contains(.notch))
    notched = true
    session.refreshDisplays()
    #expect(session.offeredPresets.contains(.notch))
    session.preferences.placement = .belowMenuBar
    #expect(!session.offeredPresets.contains(.notch))
    session.preferences.placement = .top
    #expect(session.offeredPresets.contains(.notch))
}
