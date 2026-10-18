import SwiftUI

struct ThemeCard: View {
    let title: String
    let look: Configuration?
    var appearance: BarAppearance = .light
    var isSelected = false
    var progress: String?
    var error: String?
    var isStore = false
    let select: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isStore {
                preview
                HStack {
                    Text(title).font(.callout).lineLimit(1)
                    Spacer()
                    if let progress {
                        ProgressView().controlSize(.small)
                        Text(progress).font(.caption).lineLimit(1)
                    } else {
                        Button("Get", action: select).accessibilityLabel("Get \(title)")
                    }
                }
            } else {
                Button(action: select) {
                    VStack(alignment: .leading, spacing: 8) {
                        preview
                        HStack {
                            Text(title).lineLimit(1)
                            if isSelected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                        }.font(.callout)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title) theme")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    private var preview: some View {
        Group {
            if let look {
                ThemeSampleBar(look: look)
            } else {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                    .overlay { Text(isStore && error == nil ? "Loading preview…" : "Preview unavailable").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .frame(height: 76)
        .background(Color(nsColor: .underPageBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: isSelected ? 2 : 1)
        }
        .environment(\.colorScheme, appearance.colorScheme)
        .accessibilityHidden(true)
    }
}

struct ThemeSampleBar: View {
    let look: Configuration

    private var barStyle: WidgetStyle { look.bar.style.resolved(for: StyleStates()) }
    private var stripHeight: Double { max(0, look.bar.height - 2 * look.bar.margin) }
    private let workspace: WorkspaceConfiguration?

    init(look: Configuration) {
        self.look = look
        workspace = try? look.workspaceDefaults.merging(nil)
    }

    var body: some View {
        HStack(spacing: look.bar.spacing) {
            workspaces
            tile(role: .primary) { Text("Finder") }
            Spacer(minLength: 0)
            tile(role: .value) {
                HStack(spacing: 4) {
                    Image(systemName: "battery.75percent")
                    Text("82%")
                }
            }
            tile(role: .time) { Text("9:41") }
        }
        .lineLimit(1)
        .padding(.horizontal, look.bar.inset)
        .frame(minWidth: 0, maxWidth: .infinity)
        .frame(height: stripHeight)
        .background((barStyle.background ?? look.bar.background).color,
                    in: RoundedRectangle(cornerRadius: barStyle.cornerRadius ?? 0))
        .overlay { BarBorder(style: barStyle) }
        .padding(look.bar.margin)
        .frame(minWidth: 0, maxWidth: .infinity)
        .frame(height: 76)
        .clipped()
        .allowsHitTesting(false)
    }

    private var workspaces: some View {
        let style = look.defaults.resolved(for: StyleStates())
        let appearance = WidgetAppearance(style, defaults: WidgetStyle())
        let focused = workspace?.cellStyle(.focused) ?? WorkspaceCellStyle()
        let underline = focused.underline
        return HStack(spacing: appearance.spacing) {
            ForEach(1...3, id: \.self) { number in
                workspaceCell(number, appearance: appearance)
            }
        }
        .modifier(ThemeSampleTile(style: style, verticalPadding: false))
        .frame(height: stripHeight)
        .overlay(alignment: .bottomLeading) {
            if workspace?.indicator == .underline && underline.placement == .belowBar {
                RoundedRectangle(cornerRadius: underline.cornerRadius ?? 0)
                    .fill(underline.background?.color ?? appearance.accent)
                    .frame(width: underline.width ?? 24, height: max(0, underline.height ?? 2))
                    .offset(x: (style.paddingLeading ?? appearance.paddingHorizontal) + (underline.offsetX ?? 0),
                            y: max(0, underline.height ?? 2) + (underline.offsetY ?? 0))
            }
        }
    }

    private func workspaceCell(_ number: Int, appearance: WidgetAppearance) -> some View {
        let focused = number == 1
        let cell = workspace?.cellStyle(focused ? .focused : .empty) ?? WorkspaceCellStyle()
        let style = cell.resting
        let underline = cell.underline
        let label = Text("\(number)")
            .font(WidgetAppearance(style, defaults: look.defaults).font)
            .foregroundStyle(style.foreground?.color ?? (focused ? appearance.accentText : appearance.foreground))
            .padding(.leading, style.paddingLeading ?? style.paddingHorizontal ?? 7)
            .padding(.trailing, style.paddingTrailing ?? style.paddingHorizontal ?? 7)
            .frame(width: style.width.map { CGFloat($0) }, height: style.height.map { CGFloat($0) })
            .overlay(alignment: .bottom) {
                if focused && workspace?.indicator == .underline && underline.placement != .belowBar {
                    RoundedRectangle(cornerRadius: underline.cornerRadius ?? 0)
                        .fill(underline.background?.color ?? appearance.accent)
                        .frame(width: underline.width.map { CGFloat($0) }, height: max(0, underline.height ?? 2))
                        .offset(x: underline.offsetX ?? 0, y: underline.offsetY ?? 0)
                }
            }
        return label
            .padding(.top, look.defaults.paddingTop ?? appearance.paddingVertical)
            .padding(.bottom, look.defaults.paddingBottom ?? appearance.paddingVertical)
            .background {
                if focused && workspace?.indicator != .underline {
                    RoundedRectangle(cornerRadius: style.cornerRadius ?? max(appearance.cornerRadius - 4, 0))
                        .fill(style.background?.color ?? appearance.accent)
                }
            }
    }

    private func tile<Content: View>(role: PresentationRole, @ViewBuilder content: () -> Content) -> some View {
        let style = look.roleStyle(role).inheriting(look.defaults).resolved(for: StyleStates())
        return content().modifier(ThemeSampleTile(style: style))
    }
}

private struct ThemeSampleTile: ViewModifier {
    let style: WidgetStyle
    var verticalPadding = true

    func body(content: Content) -> some View {
        let appearance = WidgetAppearance(style, defaults: WidgetStyle())
        content
            .font(appearance.font)
            .foregroundStyle(appearance.foreground)
            .padding(.leading, style.paddingLeading ?? appearance.paddingHorizontal)
            .padding(.trailing, style.paddingTrailing ?? appearance.paddingHorizontal)
            .padding(.top, verticalPadding ? style.paddingTop ?? appearance.paddingVertical : 0)
            .padding(.bottom, verticalPadding ? style.paddingBottom ?? appearance.paddingVertical : 0)
            .background(appearance.background, in: RoundedRectangle(cornerRadius: appearance.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: appearance.cornerRadius)
                    .strokeBorder(appearance.borderColor, lineWidth: appearance.borderWidth)
            }
            .shadow(color: appearance.shadowColor, radius: appearance.shadowRadius, y: 1)
    }
}
