import AppKit
import SwiftUI

extension EnvironmentValues {
    /// A version to show instead of this build's, so a render draws the same version row on every commit.
    @Entry var fixedVersion: AppVersion?
}

struct AboutView: View {
    let update: AppUpdate?

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
            Section { rows }
        }
        .formStyle(.grouped)
    }

    var rows: some View {
        Group {
            VersionRow(update: update)
            if let update {
                UpdateSettings(update: update)
            } else {
                SettingRow(title: "Releases page", hint: "This build doesn't install updates. Download new versions there.") {
                    Button("Open") { NSWorkspace.shared.open(URL(string: "https://github.com/Seb-GRAF/StableBar/releases")!) }
                }
            }
        }
    }
}

/// This build's version and channel. A view of its own because Settings shows `AboutView.rows` without
/// installing `AboutView`, which would leave its environment unread.
private struct VersionRow: View {
    let update: AppUpdate?
    @Environment(\.fixedVersion) private var fixedVersion

    var body: some View {
        let version = fixedVersion ?? AppVersion()
        SettingRow(title: "StableBar \(version.version ?? "version unavailable")",
                   hint: version.build.map { "\(version.channel.rawValue) · build \($0)" } ?? version.channel.rawValue) {
            if let update, update.version == nil {
                Button("Check now", action: update.checkForUpdates)
            }
        }
        .textSelection(.enabled)
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
        if let version = update.version {
            SettingRow(title: "StableBar \(version) is available") {
                Button(update.action, action: update.proceed).disabled(!update.canProceed)
            }
        }
        SettingRow(title: "Track", hint: "Beta also gets stable releases, whichever is newer. Switching back to Stable keeps your beta until a newer stable release is out.") {
            SettingsSegments(selection: $track, options: [("stable", "Stable"), ("beta", "Beta")], stretches: false)
        }
        SettingRow(title: "Check for updates automatically") {
            Toggle("Check for updates automatically", isOn: $checksAutomatically)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .onChange(of: checksAutomatically) { update.updater.automaticallyChecksForUpdates = checksAutomatically }
        }
        SettingRow(title: "Install updates automatically") {
            Toggle("Install updates automatically", isOn: $installsAutomatically)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!checksAutomatically)
                .onChange(of: installsAutomatically) { update.updater.automaticallyDownloadsUpdates = installsAutomatically }
        }
    }
}
