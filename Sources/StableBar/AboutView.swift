import AppKit
import SwiftUI

struct AboutView: View {
    let update: AppUpdate?
    private let version = AppVersion()

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("StableBar").font(.title).fontWeight(.semibold)
                        Text("A configurable native macOS bar.").foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
            }
            Section("Release") {
                LabeledContent("Channel", value: version.channel.rawValue)
                LabeledContent("Version", value: version.version ?? "Unavailable")
                if let build = version.build {
                    LabeledContent("Build", value: build)
                }
            }
            .textSelection(.enabled)
            Section("Updates") {
                if let update {
                    UpdateSettings(update: update)
                } else {
                    Text("This build doesn't install updates. Download new versions from the [releases page](https://github.com/Seb-GRAF/StableBar/releases).")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct UpdateSettings: View {
    let update: AppUpdate
    @AppStorage("updateTrack") private var track = "stable"
    @State private var checksAutomatically: Bool
    @State private var installsAutomatically: Bool

    init(update: AppUpdate) {
        self.update = update
        _checksAutomatically = State(initialValue: update.updater.automaticallyChecksForUpdates)
        _installsAutomatically = State(initialValue: update.updater.automaticallyDownloadsUpdates)
    }

    var body: some View {
        LabeledContent {
            Picker("Update track", selection: $track) {
                Text("Stable").tag("stable")
                Text("Beta").tag("beta")
            }
            .labelsHidden()
            .fixedSize()
        } label: {
            Text("Update track")
            Text("Beta also gets stable releases, whichever is newer. Switching back to Stable keeps your beta until a newer stable release is out.")
        }
        Toggle("Check for updates automatically", isOn: $checksAutomatically)
            .onChange(of: checksAutomatically) { update.updater.automaticallyChecksForUpdates = checksAutomatically }
        Toggle("Download and install updates automatically", isOn: $installsAutomatically)
            .disabled(!checksAutomatically)
            .onChange(of: installsAutomatically) { update.updater.automaticallyDownloadsUpdates = installsAutomatically }
        HStack {
            if let version = update.version {
                Text("StableBar \(version) is available.")
                Spacer()
                Button(update.action, action: update.proceed).disabled(!update.canProceed)
            } else {
                Spacer()
                Button("Check for Updates…", action: update.checkForUpdates)
            }
        }
    }
}
