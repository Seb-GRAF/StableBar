import AppKit
import Testing
@testable import StableBar

@Suite @MainActor
struct SetupClearanceTests {
    @Test(arguments: [false, true])
    func clearanceChoicesWaitUntilSetupFinishes(finish: Bool) async throws {
        let fixture = try ClearanceSetupFixture()
        defer { fixture.close() }
        let store = fixture.store
        let saved = try Data(contentsOf: fixture.files.url)
        var updates: [[Bool]] = []
        store.onConfigurationChange = { [weak store] in
            updates.append([store?.clearanceConfiguration?.bar.keepWindowsClear == true,
                            store?.clearanceConfiguration?.bar.keepNotificationsClear == true])
        }
        let session = SetupSession(store: store, system: fixture.system)
        session.preferences.keepWindowsClear = true
        session.preferences.keepNotificationsClear = true
        #expect(store.configuration?.bar.keepWindowsClear == true)
        #expect(store.configuration?.bar.keepNotificationsClear == true)
        #expect(!updates.isEmpty)
        #expect(updates.allSatisfy { $0 == [false, false] })
        #expect(try Data(contentsOf: fixture.files.url) == saved)

        if finish {
            session.finish()
            #expect(session.finished)
            #expect(session.error == nil)
            // The preview already matches the saved result, so a no-op reload must still update clearance now.
            #expect(updates.last == [true, true])
        } else {
            session.cancel()
            for _ in 0..<1000 where store.windowClearance.hold != nil { await Task.yield() }
            #expect(updates.allSatisfy { $0 == [false, false] })
            #expect(try Data(contentsOf: fixture.files.url) == saved)
        }
        #expect(store.clearanceConfiguration?.bar.keepWindowsClear == finish)
        #expect(store.clearanceConfiguration?.bar.keepNotificationsClear == finish)

        // Setup's snapshot is gone: later edits follow the normal configuration again.
        try store.applyEdits([ConfigurationEdit(action: .bar, properties: [
            "keepWindowsClear": .bool(!finish), "keepNotificationsClear": .bool(!finish)
        ])], persist: false)
        #expect(updates.last == [!finish, !finish])
    }

    @Test(arguments: [false, true])
    func existingClearanceKeepsWorkingDuringSetupAndAfterSkip(sessionEdits: Bool) throws {
        let fixture = try ClearanceSetupFixture(configuration: #"{"includes":["included.json"],"widgets":[]}"#,
                                                included: #"{"bar":{"keepWindowsClear":\#(!sessionEdits),"keepNotificationsClear":\#(!sessionEdits)}}"#)
        defer { fixture.close() }
        let store = fixture.store
        if sessionEdits {
            try store.setSessionEdits([ConfigurationEdit(action: .bar, properties: [
                "keepWindowsClear": .bool(true), "keepNotificationsClear": .bool(true), "offset": .number(17)
            ])])
        }
        let before = try #require(store.clearanceConfiguration)
        let session = SetupSession(store: store, system: fixture.system)
        session.preferences.keepWindowsClear = false
        session.preferences.keepNotificationsClear = false
        #expect(store.configuration?.bar.keepWindowsClear == false)
        #expect(store.configuration?.bar.keepNotificationsClear == false)
        #expect(store.clearanceConfiguration?.bar.keepWindowsClear == true)
        #expect(store.clearanceConfiguration?.bar.keepNotificationsClear == true)
        #expect(store.clearanceConfiguration?.bar.offset == before.bar.offset)
        session.cancel()
        #expect(store.clearanceConfiguration?.bar.keepWindowsClear == true)
        #expect(store.clearanceConfiguration?.bar.keepNotificationsClear == true)
        #expect(store.clearanceConfiguration?.bar.offset == before.bar.offset)
    }

    @Test(arguments: [false, true])
    func placementPreviewKeepsClearanceAtTheOriginalBarUntilFinish(finish: Bool) async throws {
        let fixture = try ClearanceSetupFixture(configuration: #"""
            {"bar":{"height":30,"keepWindowsClear":true,"displayScale":{"external":1.25}},
             "screens":{"monitor":{"bar":{"offset":8}}},"widgets":[]}
            """#)
        defer { fixture.close() }
        let store = fixture.store
        let app = AppDelegate(store: store)
        let frames = [CGRect(x: 0, y: 0, width: 1512, height: 982),
                      CGRect(x: -1920, y: 982, width: 1920, height: 1080)]
        let displays = [BarDisplay(id: 1, isBuiltIn: true, isMain: true, notch: nil),
                        BarDisplay(id: 2, isBuiltIn: false, isMain: false, notch: nil)]
        let clearance = { [weak app] in
            zip(frames, displays).map { frame, display in
                app?.clearanceDisplay(frame: frame, visibleFrame: frame.insetBy(dx: 0, dy: 24),
                                      display: display, desktopTop: 2062)
            }
        }
        let before = clearance()
        #expect(before.allSatisfy { $0 != nil })
        var updates: [[WindowClearanceDisplay?]] = []
        store.onConfigurationChange = { updates.append(clearance()) }
        let session = SetupSession(store: store, system: fixture.system)
        await session.place(.belowMenuBar)
        #expect(session.error == nil)
        #expect(store.configuration?.bar.belowMenuBar == true)
        #expect(clearance() == before)
        #expect(updates.allSatisfy { $0 == before })

        if finish {
            session.finish()
            #expect(session.finished)
            #expect(session.error == nil)
            let configuration = try #require(store.configuration)
            let expected = zip(frames, displays).map { frame, display in
                WindowClearanceDisplay(frame: frame, visibleFrame: frame.insetBy(dx: 0, dy: 24),
                                       configuration: configuration, display: display, desktopTop: 2062)
            }
            #expect(clearance() == expected.map(Optional.some))
            #expect(updates.last == expected.map(Optional.some))
            #expect(zip(clearance(), before).allSatisfy { $0 != $1 })
        } else {
            session.cancel()
            #expect(clearance() == before)
            #expect(updates.allSatisfy { $0 == before })
        }
    }

    @Test func skipReleasesClearanceOnlyOnceTheMenuBarIsRestored() async throws {
        let fixture = try ClearanceSetupFixture(configuration: #"{"bar":{"keepWindowsClear":true},"widgets":[]}"#)
        defer { fixture.close() }
        let store = fixture.store
        let system = fixture.system
        let session = SetupSession(store: store, system: system)
        await session.place(.belowMenuBar)
        #expect(!system.menuBarHides())
        var menuBarHidesOnRelease: [Bool] = []
        store.onConfigurationChange = { [weak store] in
            if store?.windowClearance.hold == nil { menuBarHidesOnRelease.append(system.menuBarHides()) }
        }
        session.cancel()
        for _ in 0..<1000 where store.windowClearance.hold != nil { await Task.yield() }
        #expect(menuBarHidesOnRelease == [true])
    }

    @Test func failedFinishKeepsClearanceUnchangedUntilRetry() throws {
        var trusted = false
        let fixture = try ClearanceSetupFixture(isTrusted: { trusted })
        defer { fixture.close() }
        let store = fixture.store
        let session = SetupSession(store: store, system: fixture.system)
        session.preferences.keepWindowsClear = true
        session.finish()
        #expect(!session.finished)
        #expect(session.error?.contains("Accessibility") == true)
        #expect(store.clearanceConfiguration?.bar.keepWindowsClear == false)
        trusted = true
        session.finish()
        #expect(session.finished)
        #expect(session.error == nil)
        #expect(store.clearanceConfiguration?.bar.keepWindowsClear == true)
    }

    @Test func savedFinishReleasesClearanceWhenOpenAtLoginFails() throws {
        struct LoginItemsFailure: Error {}
        let fixture = try ClearanceSetupFixture(setOpenAtLogin: { _ in throw LoginItemsFailure() })
        defer { fixture.close() }
        let store = fixture.store
        let session = SetupSession(store: store, system: fixture.system)
        session.preferences.keepWindowsClear = true
        session.openAtLogin = true
        session.finish()
        #expect(!session.finished)
        #expect(session.error?.hasPrefix("Your bar settings were saved.") == true)
        #expect(store.clearanceConfiguration?.bar.keepWindowsClear == true)
    }

    @Test func clearanceDoesNotKeepASetupSessionAlive() throws {
        let fixture = try ClearanceSetupFixture()
        defer { fixture.close() }
        weak var reference: SetupSession?
        do {
            let session = SetupSession(store: fixture.store, system: fixture.system)
            reference = session
        }
        #expect(reference == nil)
    }
}

/// Records setup's macOS changes instead of making them. Clearance is inspected through its configuration and
/// display geometry, never started against real windows or banners.
@MainActor private struct ClearanceSetupFixture {
    let files: ThemeGalleryFixture
    let store: BarStore
    let system: SetupSystem
    private let defaultsDomain = "StableBarTests.\(UUID().uuidString)"

    init(configuration: String = #"{"widgets":[]}"#, included: String? = nil,
         isTrusted: @escaping () -> Bool = { true },
         setOpenAtLogin: @escaping (Bool) throws -> Void = { _ in Issue.record("Setup must not change real login items") }) throws {
        files = try ThemeGalleryFixture(configuration)
        if let included { try files.write(included, to: files.directory.appending(path: "included.json")) }
        store = BarStore(configurationURL: files.url, themesDirectory: files.themes)
        store.reloadConfiguration()
        #expect(store.configurationError == nil)
        var hides = true
        system = SetupSystem(automationAccess: { _ in .allowed }, setMenuBarHidden: { hides = $0 },
                             menuBarHides: { hides }, isTrusted: isTrusted, calendarAccess: { .fullAccess },
                             hasBattery: { false }, isInApplications: { false }, loginStatus: { .notRegistered },
                             setOpenAtLogin: setOpenAtLogin,
                             defaults: try #require(UserDefaults(suiteName: defaultsDomain)),
                             workspaceSource: { $0 ?? .spaces })
    }

    func close() {
        store.stop()
        files.close()
        system.defaults.removePersistentDomain(forName: defaultsDomain)
    }
}
