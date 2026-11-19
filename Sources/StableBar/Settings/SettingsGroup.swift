import SwiftUI

struct SettingsGroup<Content: View>: View {
    let title: String
    let detail: String?
    let reset: (() -> Void)?
    /// Makes the group collapse to its header, which then toggles it.
    let isExpanded: Binding<Bool>?
    @ViewBuilder let content: Content

    init(_ title: String, detail: String? = nil, reset: (() -> Void)? = nil, isExpanded: Binding<Bool>? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.reset = reset
        self.isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        let expanded = isExpanded?.wrappedValue ?? true
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let isExpanded {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { isExpanded.wrappedValue.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                            heading
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(title)
                    .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                } else {
                    heading
                }
                Spacer()
                if let reset {
                    Button("Reset", action: reset)
                        .buttonStyle(.link)
                        .font(.system(size: 11.5))
                        .accessibilityLabel("Reset \(title)")
                }
            }
            .padding(.horizontal, 4)
            if expanded {
                VStack(spacing: 0) { content }
                    .labeledContentStyle(GroupRowStyle())
                    .padding(.top, -1)
                    .settingsCard()
            }
        }
        .padding(.top, isExpanded == nil || expanded ? 22 : 14)
        .id(title)
    }

    private var heading: some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 11.5, weight: .semibold))
            if let detail { Text("· \(detail)").font(.system(size: 11.5)) }
        }
        .foregroundStyle(.secondary)
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

    /// The card a group's rows sit in, clipped to its rounded corners.
    func settingsCard() -> some View {
        clipShape(RoundedRectangle(cornerRadius: 10))
            .background(SettingsPalette.group, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(SettingsPalette.groupBorder))
    }
}
