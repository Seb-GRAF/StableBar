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
    @Environment(BarStore.self) private var store
    @Environment(ApplicationMoveController.self) private var applicationMove: ApplicationMoveController?
    @State private var status = SMAppService.mainApp.status
    @State private var error: String?

    private var isInApplications: Bool { applicationMove?.isInApplications ?? appIsInApplications() }
    private var hint: String? {
        if isInApplications { return nil }
        return store.barEditing.setupIsOpen ? ApplicationMoveController.setupHint
            : "Move StableBar to Applications to open it at login."
    }

    var body: some View {
        SettingRow(title: "Open at login", hint: hint) {
            if let applicationMove, applicationMove.canMoveFromSettings(setupIsOpen: store.barEditing.setupIsOpen) {
                ApplicationMoveControls(controller: applicationMove, resume: {
                    applicationMove.resumeFromSettings(store: store)
                })
            } else {
                if status == .requiresApproval {
                    Button("Allow StableBar in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                }
                Toggle("Open at login", isOn: Binding(get: { status == .enabled || status == .requiresApproval }, set: { enabled in
                    do {
                        try setLaunchAtLogin(enabled)
                        error = nil
                    } catch {
                        self.error = errorMessage(error)
                    }
                    status = SMAppService.mainApp.status
                }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!isInApplications)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            status = SMAppService.mainApp.status
        }
        if let error {
            Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
        }
    }
}
