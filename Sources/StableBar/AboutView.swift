import AppKit
import SwiftUI

struct AboutView: View {
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
        }
        .formStyle(.grouped)
    }
}
