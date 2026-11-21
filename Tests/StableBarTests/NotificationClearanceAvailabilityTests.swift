import AppKit
import SwiftUI
import Testing
@testable import StableBar

/// Loads a shared configuration without running its widgets or starting clearance.
@MainActor private func notificationStore(in directory: URL, configured: Bool = true) throws -> BarStore {
    let json = #"""
    {"configuration": {"bar": {"keepNotificationsClear": \#(configured)}, "widgets": []}, "draw": "settings", "section": "general"}
    """#
    let scene = try JSONDecoder().decode(SceneFile.self, from: Data(json.utf8))
    return try SceneRenderer.store(for: scene, at: directory.appending(path: "scene.json"), in: directory.appending(path: "work"),
                                   themes: nil)
}

/// Waits by layout passes for the controls to appear, without showing a window or bounding main-actor work by time.
@MainActor private func inspectNotificationControls(_ content: some View, ready: (NSView) -> Bool,
                                                   inspect: (NSView) throws -> Void) async throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: CGRect(x: -9000, y: -6000, width: 1200, height: 1700), styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: content.environment(\.offline, true).environment(\.fixedDate, DocsImages.date)
        .frame(width: 1200, height: 1700))
    window.contentView = host
    // SwiftUI exposes its controls only once ordered. The window stays entirely offscreen.
    window.orderFrontRegardless()
    for _ in 0..<100 {
        host.layoutSubtreeIfNeeded()
        if ready(host) { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    try #require(ready(host))
    try inspect(host)
    #expect(window.frame.maxX < 0 && window.frame.maxY < 0)
}

/// Native switches can be inspected even when the test host doesn't expose SwiftUI's accessibility tree.
@MainActor private func notificationSwitches(in view: NSView) -> [NSSwitch] {
    (view as? NSSwitch).map { [$0] } ?? view.subviews.flatMap(notificationSwitches)
}

@Test(arguments: [14, 15, 26, 27], [false, true]) @MainActor
func settingsNotificationClearanceShowsTheSavedValueAndAvailability(major: Int, configured: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "notification-settings-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try notificationStore(in: directory, configured: configured)
    defer { store.stop() }
    let editor = ConfigurationEditor(store: store)
    let bar = StyleFields(store: store, path: "bar",
        values: try #require(store.effectiveDocument["bar"]).decoded([String: ConfigurationValue].self),
        set: { editor.change(ConfigurationEdit(action: .bar, properties: $0)) },
        unset: { editor.change(ConfigurationEdit(action: .unset, properties: ["bar": .object($0)])) })
    let view = NotificationClearanceSettings(bar: bar, macOSVersion: MacOSVersion(major: major))
    #expect(view.hint == (major >= 26 ? "macOS 26 and later" : "Needs macOS 26 or later."))
    try await inspectNotificationControls(view, ready: { notificationSwitches(in: $0).count == 1 }) { host in
        let toggle = try #require(notificationSwitches(in: host).first)
        #expect(toggle.isEnabled == (major >= 26))
        #expect((toggle.state == .on) == configured)
        #expect(store.configuration?.bar.keepNotificationsClear == configured)
        #expect(store.configurationStore.sessionEdits.isEmpty)
        #expect(editor.undoSteps.isEmpty)
    }
}

/// On unsupported macOS, a saved true value must not start clearance's permission timer or observers.
@Test(arguments: [14, 15]) @MainActor
func notificationClearanceStaysInactiveOnOlderMacOS(major: Int) {
    let clearance = WindowClearance(macOSVersion: MacOSVersion(major: major))
    defer { clearance.stop() }
    clearance.update(windows: false, notifications: true, displays: [])
    #expect(!clearance.isRunning)
}
