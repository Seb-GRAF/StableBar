import AppKit
import Observation
import SwiftUI
import Testing
@testable import StableBar

@Suite @MainActor struct SetupAccessibilityTests {
    /// Each preset's card names its widgets in bar order. Below the menu bar they leave out what the menu bar shows, and
    /// on a Mac without a battery, Battery.
    @Test(arguments: SetupPreferences.Preset.allCases, [false, true])
    func presetLabelsNameWidgets(preset: SetupPreferences.Preset, hasBattery: Bool) {
        let expected: (heading: String, top: [String], below: [String]) = switch preset {
        case .everyday: ("Everyday.",
                        ["Apple menu", "App menus", "Now playing", "Weather", "Sound", "Battery", "Date and time", "Menu bar items"],
                        ["Now playing", "Weather", "Sound", "Battery"])
        case .minimal: ("Minimal.",
                       ["Apple menu", "App menus", "Battery", "Date and time", "Menu bar items"],
                       ["Workspaces", "Battery"])
        case .developer: ("Developer.",
                         ["Apple menu", "Workspaces", "App menus", "Development servers", "AI usage", "System", "Battery", "Date and time",
                          "Menu bar items"],
                         ["Workspaces", "Development servers", "AI usage", "System", "Battery"])
        case .workday: ("Workday.",
                       ["Apple menu", "App menus", "Meetings", "Dock badges", "Microphone & camera", "Sound", "Battery", "Date and time",
                        "Menu bar items"],
                       ["Meetings", "Dock badges", "Microphone & camera", "Sound", "Battery"])
        case .dashboard: ("Dashboard.",
                         ["Apple menu", "Workspaces", "App menus", "Now playing", "Weather", "System", "Battery", "Sound", "Date and time",
                          "Menu bar items"],
                         ["Workspaces", "Now playing", "Weather", "System", "Battery", "Sound"])
        }
        for placement in [SetupPreferences.Placement.top, .belowMenuBar] {
            let widgets = (placement == .top ? expected.top : expected.below).filter { hasBattery || $0 != "Battery" }
            let sets = preset.preferences(workspaces: .spaces, placement: placement, hasBattery: hasBattery).widgetSets
            #expect(preset.accessibilityLabel(widgetSets: sets) == "\(expected.heading) Widgets: \(widgets.joined(separator: ", ")).")
        }
    }

    @Test func progressLabelsDistinguishTheIntroduction() {
        #expect(SetupTourView.progressLabel(step: nil, count: 5) == "Introduction")
        for step in 0..<5 {
            #expect(SetupTourView.progressLabel(step: step, count: 5) == "Step \(step + 1) of 5")
        }
    }

    @Test func permissionActionsNameTheirPermission() {
        for (permission, name) in [(SetupPermission.accessibility, "Accessibility"), (.automation, "Automation"), (.calendars, "Calendars")] {
            #expect(SetupPermission.Action.allow.accessibilityLabel(for: permission, on: MacOSVersion(major: 26)) == "Allow \(name)")
            #expect(SetupPermission.Action.openSettings.accessibilityLabel(for: permission, on: MacOSVersion(major: 26)) == "Open \(name) Settings")
        }
        #expect(SetupPermission.Action.allow.accessibilityLabel(for: .accessibility, on: MacOSVersion(major: 27)) == "Allow Device Control and Data Access")
    }

    @Test func tabReachesTilesAndSpaceChoosesWhileReturnContinues() async throws {
        let probe = TileKeyboardProbe()
        let (window, host) = host(TileKeyboardHarness(probe: probe), width: 500, height: 180)
        defer { window.close() }
        try #require(await poll(host) { probe.ready })
        window.makeFirstResponder(nil)
        try #require(await poll(host) { probe.focus == nil })
        window.selectNextKeyView(nil)
        try #require(await poll(host) { probe.focus == 0 })
        window.selectNextKeyView(nil)
        try #require(await poll(host) { probe.focus == 1 })

        func key(_ code: UInt16, _ characters: String) throws {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
        }
        try key(49, " ")
        #expect(await poll(host) { probe.activated == [1] })
        try key(36, "\r")
        #expect(await poll(host) { probe.continued == 1 })
        #expect(probe.activated == [1])
    }
}

@MainActor @Observable private final class TileKeyboardProbe {
    var ready = false
    var focus: Int?
    var activated: [Int] = []
    var continued = 0
}

private struct TileKeyboardHarness: View {
    let probe: TileKeyboardProbe

    var body: some View {
        HStack {
            ForEach(0..<2) { index in
                SetupTile(selected: index == 0, focusChanged: { focused in
                    if focused { probe.focus = index }
                    else if probe.focus == index { probe.focus = nil }
                }) { probe.activated.append(index) } label: { Text("Tile \(index)").padding() }
            }
            Button("Continue") { probe.continued += 1 }.keyboardShortcut(.defaultAction)
        }
        .task { probe.ready = true }
    }
}

/// An offscreen host without opening setup or starting a bar.
@MainActor private func host(_ content: some View, width: Double, height: Double) -> (NSWindow, NSView) {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: CGRect(x: -9000, y: -6000, width: width, height: height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: content)
    window.contentView = host
    window.orderFrontRegardless()
    return (window, host)
}

@MainActor private func poll(_ view: NSView, until condition: () -> Bool) async -> Bool {
    for _ in 0..<500 {
        view.layoutSubtreeIfNeeded()
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}
