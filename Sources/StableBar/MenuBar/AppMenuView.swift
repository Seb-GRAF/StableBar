import SwiftUI

extension AppMenuView {
    /// How many menus, from the app's name on, fit in `available` points, leaving room for the overflow button when
    /// some don't. The app's name always stays.
    static func visibleCount(widths: [CGFloat], available: CGFloat, overflowWidth: CGFloat) -> Int {
        guard !widths.isEmpty else { return 0 }
        if widths.reduce(0, +) <= available + 0.5 { return widths.count }
        var used = overflowWidth
        var count = 0
        for width in widths {
            if count > 0 && used + width > available + 0.5 { break }
            used += width
            count += 1
        }
        return count
    }
}

/// How much narrower than all its menus the bar needs an App menus widget to be; 0 shows every menu.
private struct AppMenuShrinkKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }

extension EnvironmentValues {
    var appMenuShrink: CGFloat {
        get { self[AppMenuShrinkKey.self] }
        set { self[AppMenuShrinkKey.self] = newValue }
    }
}

struct AppMenuView: View {
    let appMenu: AppMenu
    let items: [AppMenuItem]
    var expandOnHover = false
    var hovering = false
    var expanded = false
    var isAppleMenu = false
    var displayMode: AppMenuDisplayMode = .name
    var appIcon: NSImage?
    var appleLogo = "apple.logo"
    let appearance: WidgetAppearance
    let padding: EdgeInsets
    var openAnchor: ObjectIdentifier?
    let open: (AppMenuItem, NSView) -> Void
    let requestAccess: () -> Void
    var expansionChanged: (Bool) -> Void = { _ in }
    /// Opens the menus that don't fit, from the overflow button.
    var openOverflow: ([AppMenuItem], NSView) -> Void = { _, _ in }
    @State private var hoveredItem: AppMenuItem?
    @State private var anchors: [Int: NSView] = [:]
    /// Each menu title's width by its place and title, measured in a hidden row.
    @State private var titleWidths: [String: CGFloat] = [:]
    @State private var overflowWidth: CGFloat = 0
    @State private var overflowAnchor = NSView()
    @State private var hoveringOverflow = false
    @Environment(\.appMenuShrink) private var shrink
    @Environment(\.macOSVersion) private var macOSVersion

    private var widths: [CGFloat]? {
        let widths = items.enumerated().compactMap { titleWidths["\($0.offset):\($0.element.title)"] }
        return widths.count == items.count ? widths : nil
    }

    var body: some View {
        let collapsed = expandOnHover && !expanded
        let count = collapsed ? min(items.count, 1)
            : shrink > 0.5 && !isAppleMenu ? widths.map { Self.visibleCount(widths: $0, available: $0.reduce(0, +) - shrink, overflowWidth: overflowWidth) } ?? items.count
            : items.count
        HStack(spacing: 0) {
            if !appMenu.isTrusted && !appMenu.hidesAccessWarning {
                Button(action: requestAccess) {
                    Image(systemName: "exclamationmark.triangle").padding(padding).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Allow StableBar in Privacy & Security → \(macOSVersion.accessibilityName) to show the app's menus. Click to open System Settings and drag StableBar into the list.")
            }
            ForEach(Array(items.prefix(count).enumerated()), id: \.offset) { index, item in
                let anchor = anchors[index].map(ObjectIdentifier.init)
                AppMenuTitle(item: item, index: index, isAppleMenu: isAppleMenu,
                             appIcon: displayMode.showsIcon(forMenuIndex: index, isAppleMenu: isAppleMenu) ? appIcon : nil,
                             appleLogo: appleLogo, appearance: appearance, padding: padding,
                             highlighted: openAnchor.map { $0 == anchor } ?? (hoveredItem == item), anchors: $anchors) {
                    open(item, anchors[index]!)
                }
                .onHover { inside in
                    hoveredItem = inside ? item : nil
                    if inside, openAnchor != nil, openAnchor != anchor { open(item, anchors[index]!) }
                }
                .transition(.opacity)
            }
            if !collapsed && count < items.count {
                AppMenuOverflowButton(appearance: appearance, padding: padding, anchor: overflowAnchor,
                                      highlighted: openAnchor.map { $0 == ObjectIdentifier(overflowAnchor) } ?? hoveringOverflow) {
                    openOverflow(Array(items.dropFirst(count)), overflowAnchor)
                }
                .onHover { inside in
                    hoveringOverflow = inside
                    hoveredItem = nil
                    if inside, openAnchor != nil, openAnchor != ObjectIdentifier(overflowAnchor) {
                        openOverflow(Array(items.dropFirst(count)), overflowAnchor)
                    }
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .clipped()
        .background { measuringRow }
        .onHover { if $0 { appMenu.refresh() } }
        .onChange(of: hovering || openAnchor != nil, initial: true) { _, expanded in expansionChanged(expanded) }
        .onDisappear { expansionChanged(false) }
    }
}

extension AppMenuView {
    /// Every menu title and the overflow button, hidden, to measure what fits.
    private var measuringRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                Group {
                    if displayMode.showsIcon(forMenuIndex: index, isAppleMenu: isAppleMenu), let appIcon {
                        Image(nsImage: appIcon).resizable().scaledToFit().frame(width: appearance.iconSize, height: appearance.iconSize)
                    } else {
                        Text(item.title).fontWeight(index == 0 ? .bold : nil)
                    }
                }
                .padding(.horizontal, isAppleMenu ? 0 : 7)
                .padding(padding)
                .fixedSize()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { titleWidths["\(index):\(item.title)"] = $0 }
            }
            AppMenuOverflowButton.label(padding: padding)
                .fixedSize()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { overflowWidth = $0 }
        }
        .hidden()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// » after the menus that fit, which opens the rest.
private struct AppMenuOverflowButton: View {
    let appearance: WidgetAppearance
    let padding: EdgeInsets
    let anchor: NSView
    let highlighted: Bool
    let open: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func label(padding: EdgeInsets) -> some View {
        Image(systemName: "chevron.right.2").font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(padding)
    }

    var body: some View {
        Button(action: open) {
            Self.label(padding: padding)
                .foregroundStyle(appearance.foreground)
                .background {
                    if highlighted { RoundedRectangle(cornerRadius: max(appearance.cornerRadius - 4, 0)).fill(appearance.hoverBackground) }
                }
                .background(MenuAnchor(view: anchor))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("More menus")
        .accessibilityLabel("More menus")
        .animation(hoverAnimation(highlighted, reduceMotion: reduceMotion), value: highlighted)
    }
}

private struct AppMenuTitle: View {
    let item: AppMenuItem
    let index: Int
    let isAppleMenu: Bool
    let appIcon: NSImage?
    let appleLogo: String
    let appearance: WidgetAppearance
    let padding: EdgeInsets
    let highlighted: Bool
    @Binding var anchors: [Int: NSView]
    let open: () -> Void
    @State private var anchor = NSView()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: open) {
            Group {
                if isAppleMenu {
                    Image(systemName: appleLogo).accessibilityLabel(item.title)
                } else if let appIcon {
                    Image(nsImage: appIcon).resizable().scaledToFit().frame(width: appearance.iconSize, height: appearance.iconSize)
                        .accessibilityLabel(item.title)
                } else {
                    Text(item.title).fontWeight(index == 0 ? .bold : nil)
                }
            }
            .foregroundStyle(appearance.foreground)
            .padding(.horizontal, isAppleMenu ? 0 : 7)
            .padding(padding)
            .background {
                if highlighted { RoundedRectangle(cornerRadius: max(appearance.cornerRadius - 4, 0)).fill(appearance.hoverBackground) }
            }
            .background(MenuAnchor(view: anchor))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(hoverAnimation(highlighted, reduceMotion: reduceMotion), value: highlighted)
        .onAppear { anchors[index] = anchor }
    }
}

struct MenuAnchor: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
