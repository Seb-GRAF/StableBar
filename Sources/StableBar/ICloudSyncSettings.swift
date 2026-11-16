import SwiftUI

struct ICloudSyncSettings: View {
    let store: BarStore
    @State private var state: ICloudSync.State = .off
    @State private var conflicts: [String] = []
    @State private var choosing = false
    @State private var working = false
    @State private var error: String?

    private var sync: ICloudSync { ICloudSync(folder: store.configurationURL.deletingLastPathComponent()) }

    /// Only the default folder: a configuration opened with `--config` can sit in a folder of unrelated files.
    private var syncs: Bool {
        sync.folder.standardizedFileURL == LaunchCommand.configurationURL.deletingLastPathComponent().standardizedFileURL
    }

    private var hint: String {
        if case let .unavailable(reason) = state { return reason }
        return "Keeps the configuration folder in iCloud Drive → StableBar, so every Mac signed in to your Apple Account shows "
            + "the same bar."
    }

    var body: some View {
        SettingRow(title: "Sync with iCloud", hint: hint) {
            if working { ProgressView().controlSize(.small) }
            Toggle("Sync with iCloud", isOn: Binding(get: { state == .on }, set: { on in
                if !on { perform { try $0.turnOff() } }
                else if sync.hasSyncedConfiguration { choosing = true }
                else { perform { try $0.turnOn() } }
            }))
            .labelsHidden().toggleStyle(.switch).controlSize(.small)
            .disabled(working || state != .on && state != .off)
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        .confirmationDialog("iCloud Drive already has a StableBar configuration", isPresented: $choosing) {
            Button("Use iCloud’s") { perform { try $0.turnOn(keeping: .iCloud) } }
            Button("Keep This Mac’s") { perform { try $0.turnOn(keeping: .thisMac) } }
        } message: {
            Text("Another Mac synced it. Choose the bar every Mac uses; the other configuration moves to the Trash.")
        }
        if !conflicts.isEmpty {
            Label("Two Macs saved at once, so iCloud Drive kept \(conflicts.joined(separator: ", ")) beside the original. "
                  + "StableBar loads the original: compare them, then delete the copy.", systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(SettingsPalette.warning)
        }
        if let error {
            Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
        }
    }

    private func refresh() {
        state = syncs ? sync.state : .unavailable("Sync works with the configuration in ~/.config/stablebar.")
        conflicts = syncs ? sync.conflicts : []
    }

    private func perform(_ change: @escaping @Sendable (ICloudSync) throws -> Void) {
        let sync = sync
        working = true
        Task {
            do {
                // Turning it off copies the folder, which waits for iCloud to download the files macOS evicted.
                try await BlockingWork.run { try change(sync) }
                error = nil
            } catch {
                self.error = errorMessage(error)
            }
            working = false
            refresh()
            NotificationCenter.default.post(name: RuntimeControl.configurationFolderMoved, object: nil)
            store.reloadMovedFolder()
        }
    }
}

extension BarStore {
    /// Reads the bar again after its folder was replaced, choosing the screen setup's bar again: the new folder can lack
    /// the setup's own bar, or have one.
    func reloadMovedFolder() {
        let before = configurationURL
        if let screenSetup { showScreenSetup(screenSetup) }
        if configurationURL == before { reloadConfiguration() }
    }
}
