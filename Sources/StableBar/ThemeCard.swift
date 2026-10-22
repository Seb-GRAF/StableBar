import SwiftUI

struct ThemeCard: View {
    let title: String
    let look: Configuration?
    var appearance: BarAppearance = .light
    var isSelected = false
    var progress: String?
    var error: String?
    var isStore = false
    var source: PackageSource? = .included
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        Group {
            if isStore {
                card
            } else {
                Button(action: select) { card }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(title) theme")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .onHover { hovering = $0 }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 7) {
            preview
            HStack(spacing: 6) {
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
                Group {
                    if let progress {
                        ProgressView().controlSize(.mini).accessibilityLabel(progress)
                    } else if isStore {
                        Button("Get", action: select)
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.capsule)
                            .controlSize(.small)
                            .accessibilityLabel("Get \(title)")
                    } else if let source {
                        PackageSourceBadge(source: source)
                    } else {
                        Text("Installed").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                }
                .frame(minWidth: 72, minHeight: 20, maxHeight: 20)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(isSelected ? 1 : 0)
            }
            .frame(height: 20)
            .padding(.horizontal, 2)
        }
        .padding(EdgeInsets(top: 6, leading: 6, bottom: 8, trailing: 6))
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .background(SettingsPalette.group, in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(isSelected ? Color.accentColor : hovering ? Color(nsColor: .tertiaryLabelColor) : SettingsPalette.groupBorder,
                              lineWidth: isSelected ? 2 : 1)
        }
        .animation(.snappy(duration: 0.2), value: isSelected)
        .contentShape(RoundedRectangle(cornerRadius: 11))
    }

    private var preview: some View {
        Group {
            if let look {
                GeometryReader { proxy in
                    ThemeSampleBar(look: look)
                        .frame(width: proxy.size.width * 2)
                        .scaleEffect(0.5)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            } else {
                Text(isStore && error == nil ? "Loading preview…" : "Preview unavailable")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: 46)
        .background(SampleWallpaper())
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .environment(\.colorScheme, appearance.colorScheme)
        .accessibilityHidden(true)
    }
}

struct ThemeSampleBar: View {
    let look: Configuration

    var barStyle: WidgetStyle { look.bar.style.resolved(for: StyleStates()) }
    var stripHeight: Double { max(0, look.bar.height - 2 * look.bar.margin) }
    private let workspace: WorkspaceConfiguration?

    init(look: Configuration) {
        self.look = look
        workspace = try? look.workspaceDefaults.merging(nil)
    }

    var body: some View {
        HStack(spacing: look.bar.spacing) {
            workspaces(active: 1)
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
        .background((barStyle.background ?? look.bar.background).shapeStyle,
                    in: RoundedRectangle(cornerRadius: barStyle.cornerRadius ?? 0))
        .overlay { BarBorder(style: barStyle) }
        .padding(look.bar.margin)
        .frame(minWidth: 0, maxWidth: .infinity)
        .frame(height: 76)
        .clipped()
        .allowsHitTesting(false)
    }

    func workspaces(active: Int) -> some View {
        let style = look.defaults.resolved(for: StyleStates())
        let appearance = WidgetAppearance(style, defaults: WidgetStyle())
        let focused = workspace?.cellStyle(.focused) ?? WorkspaceCellStyle()
        let underline = focused.underline
        return HStack(spacing: appearance.spacing) {
            ForEach(1...3, id: \.self) { number in
                workspaceCell(number, focused: number == active, appearance: appearance)
            }
        }
        .modifier(ThemeSampleTile(style: style, verticalPadding: false))
        .frame(height: stripHeight)
        .overlay(alignment: .bottomLeading) {
            if workspace?.indicator == .underline && underline.placement == .belowBar {
                RoundedRectangle(cornerRadius: underline.cornerRadius ?? 0)
                    .fill(underline.background?.firstColor.color ?? appearance.accent)
                    .frame(width: underline.width ?? 24, height: max(0, underline.height ?? 2))
                    .offset(x: (style.paddingLeading ?? appearance.paddingHorizontal) + (underline.offsetX ?? 0),
                            y: max(0, underline.height ?? 2) + (underline.offsetY ?? 0))
            }
        }
    }

    private func workspaceCell(_ number: Int, focused: Bool, appearance: WidgetAppearance) -> some View {
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
                        .fill(underline.background?.shapeStyle ?? AnyShapeStyle(appearance.accent))
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
                        .fill(style.background?.shapeStyle ?? AnyShapeStyle(appearance.accent))
                }
            }
    }

    func tile<Content: View>(role: PresentationRole, @ViewBuilder content: () -> Content) -> some View {
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
