import SwiftUI

struct SettingsGroup<Content: View>: View {
    let title: String
    let detail: String?
    let reset: (() -> Void)?
    /// Makes the header a button that closes the group.
    let close: (() -> Void)?
    @ViewBuilder let content: Content

    init(_ title: String, detail: String? = nil, reset: (() -> Void)? = nil, close: (() -> Void)? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.reset = reset
        self.close = close
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let close {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { close() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.secondary)
                            heading
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(title)
                    .accessibilityValue("Expanded")
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
            VStack(spacing: 0) { content }
                .labeledContentStyle(GroupRowStyle())
                .padding(.top, -1)
                .settingsCard()
        }
        .padding(.top, 22)
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

/// A closed group as a row of a card: a click opens it. `detail` sits on the right, with Reset when there's one.
struct ClosedSettingsGroup: View {
    let title: String
    let detail: String?
    let reset: (() -> Void)?
    let open: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { open() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text(title)
                    Spacer(minLength: 8)
                    if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(.secondary) }
                }
                .padding(.leading, 16)
                .frame(minHeight: 46)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue("Collapsed")
            if let reset {
                Button("Reset", action: reset)
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                    .accessibilityLabel("Reset \(title)")
            }
        }
        .padding(.trailing, 16)
        .overlay(alignment: .top) { SettingsPalette.separator.frame(height: 1) }
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
