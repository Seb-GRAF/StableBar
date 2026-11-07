import AppKit
import CoreServices

/// The macOS setting **Automatically hide and show the menu bar**, which setup turns on for the top edge.
enum MenuBarAutoHide {
    /// Set while auto-hide is on because StableBar turned it on, so Uninstall knows to turn it off.
    static let turnedOnKey = "turnedOnMenuBarAutoHide"

    static func isOn(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: "_HIHideMenuBar")
    }

    static func turnedOnByStableBar(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: turnedOnKey)
    }

    static func setTurnedOnByStableBar(_ turnedOn: Bool, in defaults: UserDefaults = .standard) {
        if turnedOn { defaults.set(true, forKey: turnedOnKey) } else { defaults.removeObject(forKey: turnedOnKey) }
    }

    /// Forgets that StableBar turned auto-hide on once it's off, so auto-hide the user turns on later stays theirs.
    static func forgetIfShown(in defaults: UserDefaults = .standard) {
        if !isOn(in: defaults) { setTurnedOnByStableBar(false, in: defaults) }
    }

    /// Whether auto-hide is StableBar's doing once it's set to `hidden`, given how it was before.
    /// Auto-hide the user had on stays theirs, even after setup shows the menu bar and hides it again.
    static func turnedOnByStableBar(after hidden: Bool, wasOn: Bool, wasStableBars: Bool) -> Bool {
        hidden && (!wasOn || wasStableBars)
    }

    /// Turns auto-hide on or off from Settings and keeps the record, as setup does.
    @MainActor
    static func change(to hidden: Bool) async throws {
        try await change(to: hidden, in: .standard) { try await set($0) }
    }

    @MainActor
    static func change(to hidden: Bool, in defaults: UserDefaults, set: (Bool) async throws -> Void) async throws {
        let wasOn = isOn(in: defaults), wasStableBars = turnedOnByStableBar(in: defaults)
        try await set(hidden)
        setTurnedOnByStableBar(turnedOnByStableBar(after: hidden, wasOn: wasOn, wasStableBars: wasStableBars), in: defaults)
    }

    /// Changes the setting through System Events, which macOS asks the user to allow once.
    static func set(_ hidden: Bool) async throws {
        _ = try await runCommand("/usr/bin/osascript", arguments: [
            "-e", "tell application \"System Events\" to set autohide menu bar of dock preferences to \(hidden)"
        ], timeout: 120)
    }

    /// Whether StableBar may control System Events, which changes the setting.
    enum Access: Equatable, Sendable {
        case allowed, denied, undecided
    }

    static let systemEvents = "com.apple.systemevents"
    static let accessHint = "Turn on System Events under StableBar in System Settings → Privacy & Security → Automation."

    /// StableBar's Automation access to System Events. With `asking`, macOS shows its dialog when the person
    /// hasn't decided yet, and this waits for the answer.
    @MainActor
    static func access(asking: Bool) async -> Access {
        var status = await permission(asking: asking)
        if Int(status) == procNotFound, await launchSystemEvents() {
            for _ in 0..<20 where Int(status) == procNotFound {
                try? await Task.sleep(for: .milliseconds(100))
                status = await permission(asking: asking)
            }
        }
        return access(for: status)
    }

    static func access(for status: OSStatus) -> Access {
        switch Int(status) {
        case Int(noErr): .allowed
        case errAEEventNotPermitted: .denied
        default: .undecided
        }
    }

    @MainActor
    static func openAutomationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }

    /// AEDeterminePermissionToAutomateTarget blocks while macOS's dialog is up, so it runs off the main actor.
    private static func permission(asking: Bool) async -> OSStatus {
        await Task.detached {
            var target = AEAddressDesc()
            let bundleID = Array(systemEvents.utf8)
            guard AECreateDesc(DescType(typeApplicationBundleID), bundleID, bundleID.count, &target) == noErr else {
                return OSStatus(paramErr)
            }
            defer { AEDisposeDesc(&target) }
            return AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), asking)
        }.value
    }

    /// The check needs System Events running; it otherwise starts on the first script.
    @MainActor
    private static func launchSystemEvents() async -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: systemEvents) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        return (try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)) != nil
    }
}
