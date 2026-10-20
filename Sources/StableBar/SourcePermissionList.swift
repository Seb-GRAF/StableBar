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
        VStack(alignment: .leading, spacing: 18) {
            ForEach(permissions, id: \.self) { permission in
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: permission.symbol).font(.title2).frame(width: 28)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(permission.title).font(.headline)
                        Text(permission.detail).font(.callout).foregroundStyle(.secondary)
                        switch permission.privacyPane {
                        case "Privacy_Calendars":
                            if calendarAccess == .fullAccess {
                                Label("Access allowed", systemImage: "checkmark.circle").foregroundStyle(.green)
                            } else if calendarAccess == .notDetermined {
                                Text("Access needed").foregroundStyle(.secondary)
                                Button("Allow Calendar Access…") {
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
                                Text(calendarAccess == .restricted ? "Access restricted by this Mac" : "Access not allowed")
                                    .foregroundStyle(.secondary)
                                Button("Open Calendar Privacy Settings…") { openPrivacyPane(permission.privacyPane) }
                            }
                        case "Privacy_Accessibility":
                            if accessibilityAccess {
                                Label("Access allowed", systemImage: "checkmark.circle").foregroundStyle(.green)
                            } else {
                                Text("Access needed").foregroundStyle(.secondary)
                                Button("Allow Accessibility Access…") {
                                    AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
                                    openPrivacyPane(permission.privacyPane)
                                    accessibilityAccess = AXIsProcessTrusted()
                                }
                            }
                        default:
                            Button("Open System Settings…") { openPrivacyPane(permission.privacyPane) }
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            calendarAccess = EKEventStore.authorizationStatus(for: .event)
            accessibilityAccess = AXIsProcessTrusted()
            accessChanged()
        }
    }
}

@MainActor
private func openPrivacyPane(_ pane: String) {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
}
