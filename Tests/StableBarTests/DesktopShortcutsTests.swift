import AppKit
import Testing
@testable import StableBar

private func hotKey(enabled: Bool = true, parameters: [Int] = [65535, 18, 262144]) -> [String: Any] {
    ["enabled": enabled, "value": ["parameters": parameters]]
}

private func desktop(_ number: Int) -> Workspace {
    Workspace(name: String(number), isFocused: number == 1, isVisible: number == 1, monitor: 1)
}

@Suite struct DesktopShortcutsTests {
    @Test func missingDomainAndMissingEntriesAreOff() {
        for dictionary: [String: Any]? in [nil, [:], ["not-a-hotkey": true]] {
            let reader = DesktopShortcuts(read: { dictionary })
            #expect(reader.status(for: [1, 2]).disabled == [1, 2])
            #expect(!reader.status(for: [1, 2]).allEnabled)
            #expect(reader.shortcut(for: 1) == nil)
        }
    }

    @Test func malformedEntriesAreOffAndNeverIndexShortParameters() {
        let entries: [Any] = [
            "invalid", true, ["enabled": "true"], ["enabled": true],
            ["enabled": true, "value": "invalid"],
            ["enabled": true, "value": ["parameters": ["18", "1", "262144"]]],
            hotKey(parameters: []), hotKey(parameters: [65535]), hotKey(parameters: [65535, 18]),
            hotKey(parameters: [65535, 18, 262144, 0]), hotKey(parameters: [65535, -1, 262144]),
            hotKey(parameters: [65535, 65536, 262144]), hotKey(parameters: [65535, 65535, 0]),
            hotKey(parameters: [65535, 18, -1])
        ]
        for entry in entries {
            let reader = DesktopShortcuts(read: { ["118": entry] })
            #expect(reader.shortcut(for: 1) == nil)
            #expect(reader.status(for: [1]).disabled == [1])
        }
    }

    @Test func checksOnlyExistingDesktopsAndPreservesChosenKeys() {
        var reads = 0
        let reader = DesktopShortcuts(read: {
            reads += 1
            return ["118": hotKey(parameters: [97, 0, 1179648]), "119": hotKey(enabled: false), "120": hotKey()]
        })
        let status = reader.status(for: [2, 1, 2, 0, -1])
        #expect(reads == 1)
        #expect(status.desktops == [1, 2])
        #expect(status.disabled == [2])
        #expect(status.unsupported.isEmpty)
        #expect(status.detail.contains("1 desktop can't"))
        #expect(reader.shortcut(for: 1) == DesktopShortcuts.Shortcut(key: 0, modifiers: 1179648))
    }

    @Test func allEnabledAndMoreDesktopsThanShortcuts() {
        let hotKeys = Dictionary(uniqueKeysWithValues: (1...18).map { (String(117 + $0), hotKey()) })
        let reader = DesktopShortcuts(read: { hotKeys })
        #expect(reader.status(for: Array(1...16)).allEnabled)
        let status = reader.status(for: Array(1...18))
        #expect(status.disabled.isEmpty)
        #expect(status.unsupported == [17, 18])
        #expect(status.allEnabled)
        #expect(status.detail.contains("macOS has no shortcut for desktops 17, 18"))
        #expect(!status.detail.contains("on for every desktop"))
        #expect(reader.shortcut(for: 17) == nil)
        #expect(reader.shortcut(for: Int.max) == nil)
    }

    @Test func disabledShortcutsStillNeedActionAlongsideUnsupportedDesktops() {
        let status = DesktopShortcuts(read: { ["118": hotKey()] }).status(for: [1, 2, 17, 18])
        #expect(!status.allEnabled)
        #expect(status.disabled == [2])
        #expect(status.unsupported == [17, 18])
        #expect(status.detail.contains("1 desktop can't"))
        #expect(status.detail.contains("macOS has no shortcut for desktops 17, 18"))
    }

    @Test func unsupportedDesktopsAloneNeedNoAction() {
        let status = DesktopShortcuts(read: { nil }).status(for: [17, 18])
        #expect(status.allEnabled)
        #expect(status.disabled.isEmpty)
        #expect(status.unsupported == [17, 18])
        #expect(status.detail.contains("macOS has no shortcut for desktops 17, 18"))
    }

    @Test func noSnapshotDoesNotPromiseEveryShortcutIsOn() {
        let status = DesktopShortcuts(read: { [:] }).status(for: [])
        #expect(!status.allEnabled)
        #expect(status.detail.contains("Couldn't check"))
    }

    @Test @MainActor func keyboardURLOpensOnceAndReportsFailure() throws {
        let expected = ["x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts"]
        var opened: [String] = []
        try DesktopShortcuts.openSettings { opened.append($0.absoluteString); return true }
        #expect(opened == expected)
        opened = []
        let error = #expect(throws: CommandFailure.self) {
            try DesktopShortcuts.openSettings { opened.append($0.absoluteString); return false }
        }
        #expect(opened == expected)
        #expect(error?.localizedDescription.contains("System Settings → Keyboard → Keyboard Shortcuts → Mission Control") == true)
    }

    @Test @MainActor func failedClickClearsAsSoonAsThatShortcutIsReadAsOn() throws {
        let store = WorkspaceStore()
        store.source = .spaces
        var hotKeys = ["118": hotKey(enabled: false), "119": hotKey(enabled: false)]
        store.desktopShortcuts = DesktopShortcuts(read: { hotKeys })
        store.workspaces = [desktop(1), desktop(2)]
        store.select(desktop(1))
        #expect(store.error == "Turn on “Switch to Desktop 1” in System Settings → Keyboard → Keyboard Shortcuts → Mission Control.")
        hotKeys["119"] = hotKey()
        store.refreshDesktopShortcuts()
        #expect(store.error != nil, "Enabling another desktop must not clear this click's failure.")
        hotKeys["118"] = hotKey()
        // Every menu reads error just before showing it, even when StableBar hasn't activated and no Space changed.
        #expect(store.error == nil)
        store.refreshDesktopShortcuts()
        hotKeys["118"] = hotKey(enabled: false)
        #expect(store.error == nil, "A completed re-check forgets the old failed click.")
        store.error = "An unrelated workspace failure"
        hotKeys["118"] = hotKey()
        store.refreshDesktopShortcuts()
        #expect(store.error == "An unrelated workspace failure")
    }

    @Test @MainActor func activationAndSpaceEventsRecheckAndStopRemovesObservers() async throws {
        let notificationCenter = NotificationCenter()
        let workspaceNotificationCenter = NotificationCenter()
        let store = WorkspaceStore(notificationCenter: notificationCenter,
                                   workspaceNotificationCenter: workspaceNotificationCenter)
        store.source = .spaces
        var desktops = [desktop(1)]
        store.readSpaces = { desktops }
        var reads = 0
        var hotKeys = ["118": hotKey(enabled: false)]
        store.desktopShortcuts = DesktopShortcuts(read: { reads += 1; return hotKeys })
        store.start()
        defer { store.stop() }
        for _ in 0..<1000 where store.workspaces.isEmpty { await Task.yield() }
        try #require(store.workspaces == desktops)
        store.select(desktop(1))
        hotKeys["118"] = hotKey()
        notificationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(store.desktopShortcutStatus.allEnabled)
        #expect(store.error == nil)
        desktops.append(desktop(2))
        workspaceNotificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        for _ in 0..<1000 where store.workspaces.count != 2 { await Task.yield() }
        #expect(store.desktopShortcutStatus.disabled == [2])
        desktops.removeLast()
        workspaceNotificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        for _ in 0..<1000 where store.workspaces.count != 1 { await Task.yield() }
        #expect(store.desktopShortcutStatus.allEnabled)
        store.stop()
        let before = reads
        notificationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        workspaceNotificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        for _ in 0..<20 { await Task.yield() }
        #expect(reads == before)
    }

    @Test func rowOnlyAppliesToEnabledSpacesWorkspaces() throws {
        #expect(SettingsSearchResult.access.matches("desktop shortcuts"))
        for (json, shows) in [
            (#"{"workspaceSource":"spaces","widgets":[{"id":"spaces","type":"workspaces","position":"left"}]}"#, true),
            (#"{"workspaceSource":"spaces","widgets":[{"id":"spaces","type":"workspaces","enabled":false,"position":"left"}]}"#, false),
            (#"{"workspaceSource":"spaces","widgets":[]}"#, false),
            (#"{"workspaceSource":"yabai","widgets":[{"id":"spaces","type":"workspaces","position":"left"}]}"#, false),
            (#"{"widgets":[{"id":"spaces","type":"workspaces","position":"left"}]}"#, false)
        ] {
            #expect(try JSONDecoder().decode(Configuration.self, from: Data(json.utf8)).usesSpacesWorkspaces == shows)
        }
    }

    @Test(arguments: [false, true]) @MainActor
    func setupShowsShortcutsAndNeverWaitsForThem(allSupportedEnabled: Bool) async throws {
        let fixture = try ThemeGalleryFixture(#"{"bar":{"belowMenuBar":true},"workspaceSource":"spaces","widgets":[{"id":"spaces","type":"workspaces","position":"left"}]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        store.workspaceStore.source = .spaces
        let desktops = (1...18).map(desktop)
        let hotKeys = Dictionary(uniqueKeysWithValues: (1...16).map { (String(117 + $0), hotKey()) })
        store.workspaceStore.desktopShortcuts = DesktopShortcuts(read: { allSupportedEnabled ? hotKeys : nil })
        store.workspaceStore.readSpaces = { desktops }
        store.workspaceStore.workspaces = desktops
        let suite = "StableBarTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var system = SetupSystem()
        system.automationAccess = { _ in .allowed }
        system.setMenuBarHidden = { _ in Issue.record("Setup must not change the Mac's settings.") }
        system.menuBarHides = { false }
        system.isTrusted = { true }
        system.calendarAccess = { .fullAccess }
        system.loginStatus = { .notRegistered }
        system.setOpenAtLogin = { _ in Issue.record("Setup must not change login settings.") }
        system.workspaceSource = { _ in .spaces }
        system.defaults = defaults
        system.previewsOnTheBar = false
        let session = SetupSession(store: store, system: system)
        await session.place(.belowMenuBar)
        #expect(session.showsSpacesGuidance)
        let status = store.workspaceStore.desktopShortcutStatus
        #expect(status.allEnabled == allSupportedEnabled)
        #expect(status.disabled == (allSupportedEnabled ? [] : Array(1...16)))
        #expect(status.unsupported == [17, 18])
        #expect(status.detail.contains("macOS has no shortcut for desktops 17, 18"))
        #expect(session.missingPermissions.isEmpty)
        #expect(!session.blocksContinue(at: .permissions))
        #expect(!session.blocksContinue(at: .tryIt))
        session.finish()
        #expect(session.finished)
        #expect(session.error == nil)
    }
}
