import ServiceManagement
import SwiftUI

func appIsInApplications() -> Bool {
    let directory = Bundle.main.bundleURL.deletingLastPathComponent().standardizedFileURL
    return directory == URL(filePath: "/Applications", directoryHint: .isDirectory)
        || directory == FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications", directoryHint: .isDirectory)
}

@MainActor
func setLaunchAtLogin(_ enabled: Bool) throws {
    if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
}

struct LoginItemSettings: View {
    @State private var status = SMAppService.mainApp.status
    @State private var error: String?

    var body: some View {
        Toggle("Open at login", isOn: Binding(get: { status == .enabled || status == .requiresApproval }, set: { enabled in
            do {
                try setLaunchAtLogin(enabled)
                error = nil
            } catch {
                self.error = errorMessage(error)
            }
            status = SMAppService.mainApp.status
        }))
        .disabled(!appIsInApplications())
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            status = SMAppService.mainApp.status
        }
        if !appIsInApplications() {
            Text("Move StableBar to Applications to open it at login.")
                .font(.callout).foregroundStyle(.secondary)
        }
        if status == .requiresApproval {
            Button("Allow StableBar in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
        }
        if let error {
            Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
        }
    }
}
