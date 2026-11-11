import AppKit
import SwiftUI

/// The Switch to Desktop shortcuts macOS offers. Reading them never changes the person's keys or settings.
struct DesktopShortcuts {
    static let desktops = 1...16
    static let title = "Desktop shortcuts"
    static let actionTitle = "Open Keyboard Shortcuts…"
    var read: () -> [String: Any]? = {
        UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys")
    }

    struct Shortcut: Equatable {
        let key: CGKeyCode
        let modifiers: UInt64
    }

    struct Status: Equatable {
        let desktops: [Int]
        let disabled: [Int]
        let unsupported: [Int]
        var allEnabled: Bool { !desktops.isEmpty && disabled.isEmpty }

        var detail: String {
            guard !desktops.isEmpty else {
                return "Couldn't check your desktops. Review Switch to Desktop under Mission Control in Keyboard Shortcuts."
            }
            if allEnabled && unsupported.isEmpty { return "Switch to Desktop is on for every desktop." }
            var parts: [String] = []
            if !disabled.isEmpty {
                parts.append("\(disabled.count) \(disabled.count == 1 ? "desktop can't" : "desktops can't") be switched from the bar yet. Turn on Switch to Desktop under Mission Control.")
            }
            if !unsupported.isEmpty {
                let names = unsupported.map(String.init).joined(separator: ", ")
                parts.append("macOS has no shortcut for \(unsupported.count == 1 ? "desktop" : "desktops") \(names). Use Mission Control to reach \(unsupported.count == 1 ? "it" : "them").")
            }
            return parts.joined(separator: " ")
        }
    }

    func status(for desktops: [Int]) -> Status {
        let desktops = Set(desktops.filter { $0 > 0 }).sorted()
        let hotKeys = read()
        return Status(desktops: desktops,
                      disabled: desktops.filter { Self.desktops.contains($0) && Self.shortcut(for: $0, in: hotKeys) == nil },
                      unsupported: desktops.filter { !Self.desktops.contains($0) })
    }

    func shortcut(for desktop: Int) -> Shortcut? {
        Self.shortcut(for: desktop, in: read())
    }

    private static func shortcut(for desktop: Int, in hotKeys: [String: Any]?) -> Shortcut? {
        guard desktops.contains(desktop),
              let hotKey = hotKeys?[String(117 + desktop)] as? [String: Any], hotKey["enabled"] as? Bool == true,
              let parameters = (hotKey["value"] as? [String: Any])?["parameters"] as? [Int], parameters.count == 3,
              let key = CGKeyCode(exactly: parameters[1]), key != CGKeyCode.max,
              let modifiers = UInt64(exactly: parameters[2]) else { return nil }
        return Shortcut(key: key, modifiers: modifiers)
    }

    /// Opens the public Keyboard Shortcuts URL; macOS may show the Keyboard pane first.
    @MainActor static func openSettings(open: (URL) -> Bool = { NSWorkspace.shared.open($0) }) throws {
        if open(URL(string: "x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts")!) { return }
        throw CommandFailure(message: "Open System Settings → Keyboard → Keyboard Shortcuts → Mission Control to turn on Switch to Desktop.")
    }
}

extension Configuration {
    var usesSpacesWorkspaces: Bool {
        workspaceSource == .spaces && widgets.contains { $0.enabled && $0.content == .workspaces }
    }
}

/// General → Access uses the same status and action as setup's permissions step.
struct DesktopShortcutSettings: View {
    let workspaces: WorkspaceStore
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(DesktopShortcuts.title)
                    Text(workspaces.desktopShortcutStatus.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if workspaces.desktopShortcutStatus.allEnabled {
                    Label("Ready", systemImage: "checkmark").foregroundStyle(SettingsPalette.success)
                } else {
                    Button(DesktopShortcuts.actionTitle) {
                        do { try DesktopShortcuts.openSettings(); error = nil }
                        catch { self.error = errorMessage(error) }
                    }
                }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
        }
        .onAppear { workspaces.refreshDesktopShortcuts() }
    }
}
