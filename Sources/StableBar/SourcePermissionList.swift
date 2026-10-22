import AppKit
@preconcurrency import ApplicationServices
import EventKit
import SwiftUI

struct SourcePermissionList: View {
    let permissions: [SourcePermission]
    var accessChanged: () -> Void = {}
    @State private var calendarAccess = EKEventStore.authorizationStatus(for: .event)
    @State private var accessibilityAccess = AXIsProcessTrusted()
    @State private var requestingCalendar = false
    @State private var error: String?

    var body: some View {
        ForEach(permissions, id: \.self) { permission in
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(permission.title)
                    Text(permission.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                switch permission.privacyPane {
                case "Privacy_Calendars":
                    if calendarAccess == .fullAccess {
                        allowed
                    } else if calendarAccess == .notDetermined {
                        Button("Allow…") {
                            requestingCalendar = true
                            Task {
                                do {
                                    _ = try await EKEventStore().requestFullAccessToEvents()
                                    error = nil
                                } catch {
                                    self.error = errorMessage(error)
                                }
                                calendarAccess = EKEventStore.authorizationStatus(for: .event)
                                requestingCalendar = false
                                accessChanged()
                            }
                        }
                        .disabled(requestingCalendar)
                    } else {
                        Text(calendarAccess == .restricted ? "Restricted by this Mac" : "Not allowed").foregroundStyle(.secondary)
                        Button("Open Settings…") { openPrivacyPane(permission.privacyPane) }
                    }
                case "Privacy_Accessibility":
                    if accessibilityAccess {
                        allowed
                    } else {
                        Button("Allow…") {
                            requestAccessibility()
                            accessibilityAccess = AXIsProcessTrusted()
                        }
                    }
                default:
                    Button("Open Settings…") { openPrivacyPane(permission.privacyPane) }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            calendarAccess = EKEventStore.authorizationStatus(for: .event)
            accessibilityAccess = AXIsProcessTrusted()
            accessChanged()
        }
        if let error {
            Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
        }
    }

    private var allowed: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark").fontWeight(.bold)
            Text("Allowed")
        }
        .font(.callout)
        .foregroundStyle(SettingsPalette.success)
    }
}

@MainActor
func requestAccessibility() {
    if UserDefaults.standard.bool(forKey: "promptedForAccessibility") {
        openPrivacyPane("Privacy_Accessibility")
    } else {
        UserDefaults.standard.set(true, forKey: "promptedForAccessibility")
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
}

@MainActor
private func openPrivacyPane(_ pane: String) {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
}
