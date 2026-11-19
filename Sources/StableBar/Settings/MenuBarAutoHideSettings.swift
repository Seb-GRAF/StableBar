import AppKit
import SwiftUI

/// Settings › General › Native menu bar: the macOS setting that setup turns on for the top edge.
struct MenuBarAutoHideSettings: View {
    @State private var isOn = MenuBarAutoHide.isOn()
    @State private var changing = false
    @State private var asking = false
    @State private var error: String?
    /// The change that waits for Automation access to System Events; it applies once access is allowed.
    @State private var awaitingAccess: Bool?

    var body: some View {
        SettingRow(title: "Automatically hide the menu bar",
                   hint: "The macOS setting that lets the bar take the menu bar’s place on the top edge. macOS asks once to let StableBar control System Events.") {
            Toggle("Automatically hide the menu bar", isOn: Binding(get: { isOn }, set: { change($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(changing)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isOn = MenuBarAutoHide.isOn()
            guard let hidden = awaitingAccess, !changing else { return }
            Task {
                guard await MenuBarAutoHide.access(asking: false) == .allowed, awaitingAccess == hidden else { return }
                change(hidden)
            }
        }
        if asking {
            Text("macOS asks to let StableBar control System Events. Choose Allow to change the menu bar.")
                .font(.callout).foregroundStyle(.secondary)
        }
        if let hidden = awaitingAccess {
            HStack(alignment: .firstTextBaseline) {
                Text("StableBar needs Automation access to \(hidden ? "hide" : "show") the menu bar. \(MenuBarAutoHide.accessHint)")
                    .font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button("Open Settings…") { MenuBarAutoHide.openAutomationSettings() }
            }
        }
        if let error {
            Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
        }
    }

    private func change(_ hidden: Bool) {
        changing = true
        Task {
            defer { changing = false }
            var access = await MenuBarAutoHide.access(asking: false)
            if access == .undecided {
                asking = true
                access = await MenuBarAutoHide.access(asking: true)
                asking = false
            }
            guard access == .allowed else {
                awaitingAccess = hidden
                error = nil
                return
            }
            awaitingAccess = nil
            do {
                try await MenuBarAutoHide.change(to: hidden)
                isOn = hidden
                error = nil
            } catch {
                let detail = errorMessage(error).contains("-1743") ? MenuBarAutoHide.accessHint : errorMessage(error)
                self.error = "StableBar couldn’t \(hidden ? "hide" : "show") the macOS menu bar. \(detail)"
            }
        }
    }
}
