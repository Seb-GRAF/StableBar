import AppKit
import SwiftUI
@testable import StableBar

/// How StableBar drew built-in widgets before default layouts, kept as the reference
/// `DefaultLayoutTests` compares default layouts with. Delete it with those tests when a change
/// restyles default layouts on purpose.
struct BuiltInLabel: View {
    let content: WidgetContent
    let label: WidgetLabel
    var appIcon: NSImage?
    /// The script's graph samples, when its output has a `value`.
    var samples: [Double]?
    let appearance: WidgetAppearance

    var body: some View {
        switch content {
        case .activeApp:
            HStack(spacing: appearance.spacing) {
                if let appIcon {
                    Image(nsImage: appIcon).resizable().frame(width: appearance.iconSize, height: appearance.iconSize)
                }
                Text(label.text).lineLimit(1)
            }
        case .script, .provider:
            HStack(spacing: appearance.spacing) {
                if let samples {
                    Sparkline(samples: samples)
                        .stroke(appearance.accent, lineWidth: 1.2)
                        .frame(width: 40, height: 16)
                }
                text
            }
                .foregroundStyle(appearance.foreground)
        default:
            text
        }
    }

    private var text: some View {
        ZStack {
            Text(" ").hidden()
            HStack(spacing: appearance.spacing) {
                if let icon = label.icon { Image(systemName: icon).font(.system(size: appearance.iconSize)) }
                if !label.text.isEmpty { Text(label.text).lineLimit(1).monospacedDigit() }
            }
        }
    }
}
