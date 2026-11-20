import AppKit
import Testing
@testable import StableBar

@Suite @MainActor
struct SetupClearanceTests {
    @Test(arguments: [WorkspaceSource.spaces, .aerospace, .yabai, .omniwm, .rift])
    func windowClearanceDefaultsToOnOnlyWithoutAManager(source: WorkspaceSource) throws {
        let fixture = try ClearanceSetupFixture(workspaceSource: source)
        defer { fixture.close() }
        let saved = try Data(contentsOf: fixture.files.url)
        #expect(fixture.store.configuration?.bar.keepWindowsClear == false)
        let session = SetupSession(store: fixture.store, system: fixture.system)
        #expect(fixture.store.configuration?.bar.keepWindowsClear == (source == .spaces))
        #expect(session.preferences.keepWindowsClear == nil)
        #expect(!session.hasChanges)
        #expect(fixture.store.configurationStore.clearanceConfiguration?.bar.keepWindowsClear == false)
        #expect(try Data(contentsOf: fixture.files.url) == saved)
        session.finish()
        #expect(session.finished)
        #expect(session.error == nil)
        let bar = try fixture.files.document()["bar"]?.decoded([String: ConfigurationValue].self)
        #expect(bar?["keepWindowsClear"] == (source == .spaces ? .bool(true) : nil))
    }

    @Test(arguments: [false, true])
    func configuredSpacesStillChecksForARunningManager(windowManagerRuns: Bool) throws {
        let fixture = try ClearanceSetupFixture(configuration: #"{"workspaceSource":"spaces","widgets":[]}"#,
                                                windowManagerRuns: windowManagerRuns)
        defer { fixture.close() }
        fixture.system.defaults.set(true, forKey: SetupProgress.completedKey)
        let session = SetupSession(store: fixture.store, system: fixture.system)
        #expect(session.workspaceSource == .spaces)
        #expect(fixture.store.configuration?.bar.keepWindowsClear == !windowManagerRuns)
        #expect(session.preferences.keepWindowsClear == nil)
        session.finish()
        #expect(session.finished)
        #expect(session.error == nil)
        let bar = try fixture.files.document()["bar"]?.decoded([String: ConfigurationValue].self)
        #expect(bar?["keepWindowsClear"] == (windowManagerRuns ? nil : .bool(true)))
    }

    @Test(arguments: [false, true])
    func firstLaunchSpacesStarterStillChecksForARunningManager(windowManagerRuns: Bool) throws {
        let document: [String: ConfigurationValue] = [
            "workspaceSource": .string("spaces"),
            "widgets": .array(SetupPreferences.belowMenuBarStarter.map(ConfigurationValue.object))
        ]
        let configuration = String(decoding: try JSONEncoder().encode(document), as: UTF8.self)
        let fixture = try ClearanceSetupFixture(configuration: configuration, windowManagerRuns: windowManagerRuns)
        defer { fixture.close() }
        #expect(SetupPreferences.isFirstLaunchSpacesStarter(try fixture.files.document()))
        var system = fixture.system
        system.workspaceSource = { configured in
            #expect(configured == nil)
            return .spaces
        }
        let session = SetupSession(store: fixture.store, system: system)
        #expect(session.workspaceSource == .spaces)
        #expect(fixture.store.configuration?.bar.keepWindowsClear == !windowManagerRuns)
        #expect(session.preferences.keepWindowsClear == nil)
        session.finish()
        #expect(session.finished)
        #expect(session.error == nil)
        let bar = try fixture.files.document()["bar"]?.decoded([String: ConfigurationValue].self)
        #expect(bar?["keepWindowsClear"] == (windowManagerRuns ? nil : .bool(true)))
    }

    @Test(arguments: [WorkspaceSource.spaces, .aerospace, .yabai, .omniwm, .rift], [false, true])
    func setupKeepsConfiguredWindowClearance(source: WorkspaceSource, enabled: Bool) throws {
        let fixture = try ClearanceSetupFixture(configuration: #"{"bar":{"keepWindowsClear":\#(enabled)},"widgets":[]}"#,
                                                workspaceSource: source)
        defer { fixture.close() }
        let session = SetupSession(store: fixture.store, system: fixture.system)
        #expect(fixture.store.configuration?.bar.keepWindowsClear == enabled)
        #expect(session.preferences.keepWindowsClear == nil)
        #expect(!session.hasChanges)
        session.finish()
        #expect(session.finished)
        #expect(session.error == nil)
        #expect(fixture.store.configuration?.bar.keepWindowsClear == enabled)
    }

    @Test(arguments: [false, true], [false, true])
    func setupKeepsWindowClearanceFromIncludesAndProfiles(enabled: Bool, profile: Bool) throws {
        let configuration = profile
            ? #"{"profile":"mine","profiles":[{"name":"mine","configuration":{"bar":{"keepWindowsClear":\#(enabled)}}}],"widgets":[]}"#
            : #"{"includes":["included.json"],"widgets":[]}"#
        let fixture = try ClearanceSetupFixture(configuration: configuration,
                                                included: profile ? nil : #"{"bar":{"keepWindowsClear":\#(enabled)}}"#)
        defer { fixture.close() }
        let session = SetupSession(store: fixture.store, system: fixture.system)
        #expect(fixture.store.configuration?.bar.keepWindowsClear == enabled)
        #expect(session.preferences.keepWindowsClear == nil)
        session.finish()
        #expect(session.finished)
        #expect(session.error == nil)
        #expect(fixture.store.configuration?.bar.keepWindowsClear == enabled)
        // Inherited choices stay in their own layer instead of being copied into the main file.
        let bar = try fixture.files.document()["bar"]?.decoded([String: ConfigurationValue].self)
        #expect(bar?["keepWindowsClear"] == nil)
    }

    @Test func changingOrDeselectingPresetsKeepsTheWindowClearanceDefault() throws {
        let fixture = try ClearanceSetupFixture()
        defer { fixture.close() }
        let session = SetupSession(store: fixture.store, system: fixture.system)
        for preset in SetupPreferences.Preset.allCases {
            session.toggle(preset)
            #expect(fixture.store.configuration?.bar.keepWindowsClear == true)
            session.toggle(preset)
            #expect(fixture.store.configuration?.bar.keepWindowsClear == true)
        }
    }

    @Test(arguments: [false, true])
    func resumedSetupHoldsClearanceBeforeItsFirstPreview(finish: Bool) throws {
        let fixture = try ClearanceSetupFixture()
        defer { fixture.close() }
        let store = fixture.store
        let saved = try Data(contentsOf: fixture.files.url)
        let preferences = SetupPreferences(placement: .belowMenuBar, keepWindowsClear: true)
        let snapshot = ApplicationMoveResume.Setup(step: SetupSession.Step.done.rawValue,
            preferences: preferences, openAtLogin: true, placementChoice: .belowMenuBar,
            menuBarHidAtStart: false, stableBarHidMenuBarAtStart: false, opensAtLoginAtStart: false)
        // A fresh store models the relaunched process, with no hold left over from the original session.
        #expect(store.windowClearance.hold == nil)
        let before = try #require(store.configurationStore.clearanceConfiguration)
        var updates: [[Bool]] = []
        store.onConfigurationChange = { [weak store] in
            updates.append([store?.windowClearance.hold != nil,
                            store?.configurationStore.clearanceConfiguration?.bar.keepWindowsClear == true,
                            store?.configurationStore.clearanceConfiguration?.bar.belowMenuBar == true])
        }
        let resume = ApplicationMoveResume(kind: .setup, configuration: fixture.files.url, setup: snapshot)
        var system = fixture.system
        system.menuBarHides = { false }
        let session = SetupSession(store: store, system: system, resume: resume)
        #expect(session.step == .done)
        #expect(session.preferences == preferences)
        #expect(store.configuration?.bar.keepWindowsClear == true)
        #expect(store.configuration?.bar.belowMenuBar == true)
        #expect(!updates.isEmpty)
        #expect(updates.allSatisfy { $0 == [true, false, before.bar.belowMenuBar] })
        #expect(try Data(contentsOf: fixture.files.url) == saved)

        if finish {
            session.finish()
            #expect(session.finished)
            #expect(session.error == nil)
            #expect(updates.last == [false, true, true])
        } else {
            session.cancel()
            #expect(try Data(contentsOf: fixture.files.url) == saved)
            #expect(store.configurationStore.clearanceConfiguration?.bar.belowMenuBar == before.bar.belowMenuBar)
        }
        #expect(store.windowClearance.hold == nil)
        #expect(store.configurationStore.clearanceConfiguration?.bar.keepWindowsClear == finish)
    }

    @Test(arguments: [false, true])
    func recommendedClearanceWaitsUntilSetupFinishes(finish: Bool) throws {
        let fixture = try ClearanceSetupFixture()
        defer { fixture.close() }
        let store = fixture.store
        let saved = try Data(contentsOf: fixture.files.url)
        var updates: [Bool] = []
        store.onConfigurationChange = { [weak store] in
            updates.append(store?.configurationStore.clearanceConfiguration?.bar.keepWindowsClear == true)
        }
        let session = SetupSession(store: store, system: fixture.system)
        #expect(store.configuration?.bar.keepWindowsClear == true)
        #expect(!updates.isEmpty)
        #expect(updates.allSatisfy { !$0 })
        #expect(try Data(contentsOf: fixture.files.url) == saved)

        if finish {
            session.finish()
            #expect(session.finished)
            #expect(session.error == nil)
            // The preview already matches the saved result, so a no-op reload must still update clearance now.
            #expect(updates.last == true)
        } else {
            session.cancel()
            #expect(updates.allSatisfy { !$0 })
            #expect(try Data(contentsOf: fixture.files.url) == saved)
        }
        #expect(store.configurationStore.clearanceConfiguration?.bar.keepWindowsClear == finish)

        // Setup's snapshot is gone: later edits follow the normal configuration again.
        try store.configurationStore.applyEdits([ConfigurationEdit(action: .bar, properties: ["keepWindowsClear": .bool(!finish)])],
                                                persist: false)
        #expect(updates.last == !finish)
    }

    @Test(arguments: [false, true])
    func existingClearanceKeepsWorkingDuringSetupAndAfterSkip(sessionEdits: Bool) throws {
        let fixture = try ClearanceSetupFixture(configuration: #"{"includes":["included.json"],"widgets":[]}"#,
                                                included: #"{"bar":{"keepWindowsClear":\#(!sessionEdits),"offset":4}}"#)
        defer { fixture.close() }
        let store = fixture.store
        if sessionEdits {
            try store.configurationStore.setSessionEdits([ConfigurationEdit(action: .bar, properties: [
                "keepWindowsClear": .bool(true), "offset": .number(17)
            ])])
        }
        let before = try #require(store.configurationStore.clearanceConfiguration)
        let session = SetupSession(store: store, system: fixture.system)
        // Setup puts the bar on the top edge.
        #expect(store.configuration?.bar.offset == 0)
        #expect(store.configurationStore.clearanceConfiguration?.bar.keepWindowsClear == true)
        #expect(store.configurationStore.clearanceConfiguration?.bar.offset == before.bar.offset)
        session.cancel()
        #expect(store.configurationStore.clearanceConfiguration?.bar.keepWindowsClear == true)
        #expect(store.configurationStore.clearanceConfiguration?.bar.offset == before.bar.offset)
    }

    @Test(arguments: [false, true])
    func placementPreviewKeepsClearanceAtTheOriginalBarUntilFinish(finish: Bool) async throws {
        let fixture = try ClearanceSetupFixture(configuration: #"""
            {"bar":{"height":30,"keepWindowsClear":true,"belowMenuBar":true,"displayScale":{"external":1.25}},
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
        await session.place(.top)
        #expect(session.error == nil)
        #expect(store.configuration?.bar.belowMenuBar == false)
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

    @Test func failedFinishKeepsClearanceUnchangedUntilRetry() throws {
        var trusted = false
        let fixture = try ClearanceSetupFixture(isTrusted: { trusted })
        defer { fixture.close() }
        let store = fixture.store
        let session = SetupSession(store: store, system: fixture.system)
        session.finish()
        #expect(!session.finished)
        #expect(session.error?.contains(session.system.macOSVersion.accessibilityName) == true)
        #expect(store.configurationStore.clearanceConfiguration?.bar.keepWindowsClear == false)
        trusted = true
        session.finish()
        #expect(session.finished)
        #expect(session.error == nil)
        #expect(store.configurationStore.clearanceConfiguration?.bar.keepWindowsClear == true)
    }

    @Test func savedFinishReleasesClearanceWhenOpenAtLoginFails() throws {
        struct LoginItemsFailure: Error {}
        let fixture = try ClearanceSetupFixture(setOpenAtLogin: { _ in throw LoginItemsFailure() })
        defer { fixture.close() }
        let store = fixture.store
        var system = fixture.system
        system.isInApplications = { true }
        let session = SetupSession(store: store, system: system)
        session.openAtLogin = true
        session.finish()
        #expect(session.finished)
        #expect(session.error?.hasPrefix("Your bar settings were saved.") == true)
        #expect(store.configurationStore.clearanceConfiguration?.bar.keepWindowsClear == true)
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

    init(configuration: String = #"{"widgets":[]}"#, included: String? = nil, workspaceSource: WorkspaceSource = .spaces,
         windowManagerRuns: Bool = false,
         isTrusted: @escaping () -> Bool = { true },
         setOpenAtLogin: @escaping (Bool) throws -> Void = { _ in Issue.record("Setup must not change real login items") }) throws {
        files = try ThemeGalleryFixture(configuration)
        if let included { try files.write(included, to: files.directory.appending(path: "included.json")) }
        store = BarStore(configurationURL: files.url, themesDirectory: files.themes)
        store.configurationStore.reloadConfiguration()
        #expect(store.configurationError == nil)
        var hides = true
        system = SetupSystem(automationAccess: { _ in .allowed }, setMenuBarHidden: { hides = $0 },
                             menuBarHides: { hides }, isTrusted: isTrusted, calendarAccess: { .fullAccess },
                             hasBattery: { false }, isInApplications: { false }, loginStatus: { .notRegistered },
                             setOpenAtLogin: setOpenAtLogin,
                             defaults: try #require(UserDefaults(suiteName: defaultsDomain)),
                             workspaceSource: { $0 ?? workspaceSource }, windowManagerRuns: { windowManagerRuns })
    }

    func close() {
        store.stop()
        files.close()
        system.defaults.removePersistentDomain(forName: defaultsDomain)
    }
}
