import SwiftUI

struct PackageListPreview: View {
    let key: String
    let load: () async throws -> PackagePreviewData
    @State private var preview: PackagePreviewData?
    @State private var failed = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if let preview {
                PackagePreview(screenshotData: preview.screenshot,
                               look: preview.theme?.configuration(for: scheme == .dark ? .dark : .light), widgets: preview.widgets)
            } else if failed {
                Label("Preview unavailable", systemImage: "photo").font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity).frame(height: 64)
        .background(SettingsPalette.field, in: RoundedRectangle(cornerRadius: 8))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: key) {
            preview = nil
            failed = false
            do { preview = try await load() }
            catch { failed = true }
        }
    }
}

struct WidgetSample: View {
    let widget: WidgetConfiguration

    var body: some View {
        Group {
            switch widget.content {
            case .workspaces:
                HStack(spacing: 12) { Text("1").foregroundStyle(Color.accentColor); Text("2"); Text("3") }
            case .appleMenu: Image(systemName: "apple.logo")
            case .appMenu: Text("File   Edit   View")
            case .spacer: Label("Space", systemImage: "arrow.left.and.right")
            default:
                let label = widget.label(output: output, activeApp: "Finder", date: Date(timeIntervalSince1970: 1_792_573_260))
                let layout = widget.defaultLayout(label, output: output, appIcon: false)!
                PopupBlockView(block: layout, inheritedStyle: WidgetStyle(), fields: label.fields,
                               context: BlockContext(samples: (0..<60).map { [0.2, 0.35, 0.24, 0.5, 0.38, 0.24][$0 % 6] }, fillsWidth: false,
                                                     open: { _ in }, runAction: { _, _ in }))
            }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(SettingsPalette.group, in: RoundedRectangle(cornerRadius: 7))
        .allowsHitTesting(false)
    }

    private var output: ScriptOutput {
        switch widget.providerName {
        case "battery": ScriptOutput(text: "82%", icon: "battery.75percent", value: 0.82)
        case "audio": ScriptOutput(text: "45%", icon: "speaker.wave.2", value: 0.45)
        case "system": ScriptOutput(text: "24%", icon: "cpu", value: 0.24)
        case "network": ScriptOutput(text: "↓ 1.2 MB/s  ↑ 80 KB/s", icon: "network")
        case "calendar": ScriptOutput(text: "Team meeting", icon: "calendar")
        default: ScriptOutput(text: "Sample", icon: widget.icon ?? "terminal")
        }
    }
}
