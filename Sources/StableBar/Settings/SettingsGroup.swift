import SwiftUI

struct SettingsGroup<Content: View>: View {
    let title: String
    let reset: (() -> Void)?
    @ViewBuilder let content: Content

    init(_ title: String, reset: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.reset = reset
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let reset {
                    Button("Reset", action: reset)
                        .buttonStyle(.link)
                        .font(.system(size: 11.5))
                        .accessibilityLabel("Reset \(title)")
                }
            }
            .padding(.horizontal, 4)
            VStack(spacing: 0) { content }
                .labeledContentStyle(GroupRowStyle())
                .padding(.top, -1)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .background(SettingsPalette.group, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(SettingsPalette.groupBorder))
        }
        .padding(.top, 22)
        .id(title)
    }
}

private struct GroupRowStyle: LabeledContentStyle {
    func makeBody(configuration: LabeledContentStyleConfiguration) -> some View {
        HStack(spacing: 10) {
            configuration.label.frame(maxWidth: .infinity, alignment: .leading)
            configuration.content
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .frame(minHeight: 46)
        .overlay(alignment: .top) { SettingsPalette.separator.frame(height: 1) }
    }
}

extension View {
    func groupRow() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .overlay(alignment: .top) { SettingsPalette.separator.frame(height: 1) }
    }
}
