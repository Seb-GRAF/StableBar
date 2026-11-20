import SwiftUI

struct ThemeCard: View {
    let title: String
    let look: Configuration?
    var description: String?
    var appearance: BarAppearance = .light
    var isSelected = false
    var isEdited = false
    /// Draws the two ends of the sample bar side by side at real size, without its middle, and the battery's popup under
    /// them, instead of the whole bar at half.
    var showsBarEndsAndPopup = false
    var progress: String?
    var error: String?
    var isStore = false
    var source: PackageOrigin? = .included
    /// The context menu of an installed theme that isn't bundled. Delete… asks first, and is off while the theme is
    /// selected or `inUse` on any screen.
    var showInFinder: (() -> Void)?
    var delete: (() -> Void)?
    var inUse = false
    let select: () -> Void
    @State private var hovering = false
    @State private var confirmingDelete = false
    @State private var barWidth: CGFloat = 0

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
        .contextMenu {
            if let showInFinder { Button("Show in Finder", action: showInFinder) }
            if delete != nil {
                Divider()
                Button("Delete…", role: .destructive) { confirmingDelete = true }
                    .disabled(isSelected || inUse)
                    .help(isSelected || inUse ? "Choose another theme first" : "")
            }
        }
        .confirmationDialog("Delete \(title)?", isPresented: $confirmingDelete) {
            if let delete { Button("Delete", role: .destructive, action: delete) }
        } message: {
            Text("Every installed version of \(title) will be deleted. This cannot be undone.")
        }
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
                        HStack(spacing: 4) {
                            if case .privateSource? = source, let source { PackageOriginBadge(source: source) }
                            Button("Get", action: select)
                                .buttonStyle(.borderedProminent)
                                .buttonBorderShape(.capsule)
                                .controlSize(.small)
                                .accessibilityLabel("Get \(title)")
                        }
                    } else if let source {
                        // The gallery's Included section already says where these come from.
                        if source != .included { PackageOriginBadge(source: source) }
                    } else {
                        Text("Installed").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                }
                .frame(minWidth: isStore ? 72 : nil, minHeight: 20, maxHeight: 20)
                if isEdited {
                    Text("Edited")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.teal)
                        .padding(.horizontal, 6)
                        .frame(height: 17)
                        .background(Color.teal.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
                        .fixedSize()
                }
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(isSelected ? 1 : 0)
            }
            .frame(height: 20)
            .padding(.horizontal, 2)
            if let description {
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                    .padding(.horizontal, 2)
                    .padding(.top, -5)
            }
        }
        .padding(EdgeInsets(top: 6, leading: 6, bottom: 8, trailing: 6))
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            if let look, showsBarEndsAndPopup {
                GeometryReader { proxy in
                    // The clock at the right end is wider than the workspaces at the left.
                    HStack(spacing: 10) {
                        end(of: look, alignment: .leading).frame(width: (proxy.size.width - 10) * 0.4)
                        end(of: look, alignment: .trailing)
                    }
                    .frame(height: 60)
                }
                .overlay(alignment: .topTrailing) {
                    popup(of: look)
                        .scaleEffect(0.6, anchor: .topTrailing)
                        .padding(.top, 30 + ThemeSampleBar(look: look).stripHeight / 2 + look.bar.popupOffset)
                        .padding(.trailing, look.bar.margin + look.bar.inset)
                }
            } else if let look {
                GeometryReader { proxy in
                    let scale = min(0.5, proxy.size.width / barWidth)
                    ThemeSampleBar(look: look)
                        .frame(width: proxy.size.width / scale)
                        .scaleEffect(scale)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .background {
                            ThemeSampleBar(look: look)
                                .fixedSize()
                                .hidden()
                                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { barWidth = $0 }
                        }
                }
            } else {
                Text(isStore && error == nil ? "Loading preview…" : "Preview unavailable")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: showsBarEndsAndPopup ? 190 : 46)
        .background(SampleWallpaper())
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .environment(\.colorScheme, appearance.colorScheme)
        .accessibilityHidden(true)
    }

    /// The battery's popup in `look`, with sample data.
    private func popup(of look: Configuration) -> some View {
        let popup = EssentialsPopup.battery.popup(timeZone: nil)
        let style = popup.baseStyle(widget: ThemeSampleBar.sampleWidgets.first { $0.id == "battery" }!,
                                    defaults: look.popupDefaults.popupStyle(over: look.defaults))
        let resolved = style.resolved(for: StyleStates())
        let appearance = WidgetAppearance(resolved, defaults: WidgetStyle(spacing: PopupConfiguration.blockSpacing))
        return PopupBlockView(block: popup.layout, inheritedStyle: style, fields: ["percent": "82", "state": "battery", "timeRemaining": "312"],
                              context: BlockContext(values: ["percent": 0.82], roles: look.roles, open: { _ in }, runAction: { _, _ in }),
                              topLevel: true)
            .padding(.horizontal, appearance.paddingHorizontal)
            .padding(.vertical, appearance.paddingVertical)
            .frame(width: popup.style.width.map { CGFloat($0) })
            .modifier(PopupBackground(style: resolved, glass: look.bar.glass, backgrounds: PopupBackgrounds()))
            .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
    }

    /// The end of the sample bar on `alignment`'s side, fading out toward the middle.
    private func end(of look: Configuration, alignment: Alignment) -> some View {
        ThemeSampleBar(look: look)
            .fixedSize()
            .frame(minWidth: 0, maxWidth: .infinity, alignment: alignment)
            .clipped()
            .mask {
                LinearGradient(stops: [.init(color: .black, location: 0.75), .init(color: .clear, location: 1)],
                               startPoint: alignment == .leading ? .leading : .trailing,
                               endPoint: alignment == .leading ? .trailing : .leading)
            }
    }
}

struct ThemeSampleBar: View {
    let look: Configuration
    /// The widgets to draw with sample data, in their places, instead of `sampleWidgets`. They join the look's groups by
    /// its members, and leave their own, which the look may not have.
    let widgets: [WidgetConfiguration]?
    /// Built-in widgets that need no permission, which join a theme's groups as on the bar.
    static let sampleWidgets = try! JSONDecoder().decode([WidgetConfiguration].self, from: Data(#"""
        [
          { "id": "workspaces", "type": "workspaces", "position": "left" },
          { "id": "app", "type": "activeApp", "position": "left" },
          {
            "id": "system", "type": "system", "position": "right",
            "layout": {
              "type": "row", "style": { "spacing": 6 },
              "children": [
                { "type": "text", "text": "CPU", "role": "key", "style": { "fontWeight": "medium" } },
                { "type": "field", "field": "text" },
                { "type": "progress", "source": "cpu", "height": 4, "role": "meter", "style": { "width": 32 } }
              ]
            }
          },
          { "id": "battery", "type": "battery", "position": "right" },
          { "id": "clock", "type": "clock", "position": "right", "format": "EEE d MMM  HH:mm" }
        ]
        """#.utf8))

    var barStyle: WidgetStyle { look.bar.style.resolved(for: StyleStates()) }
    var stripHeight: Double { max(0, look.bar.height - 2 * look.bar.margin) }
    private let workspace: WorkspaceConfiguration?

    init(look: Configuration, widgets: [WidgetConfiguration]? = nil) {
        self.look = look
        self.widgets = widgets
        workspace = try? look.workspaceDefaults.merging(nil)
    }

    var body: some View {
        let ungrouped = (widgets ?? Self.sampleWidgets).map { widget in
            var widget = widget
            widget.ownGroup = nil
            return widget
        }
        let units = BarUnit.make(widgets: WidgetGroupConfiguration.joining(ungrouped, groups: look.groups), groups: look.groups)
        HStack(spacing: look.bar.spacing) {
            run(units.filter { $0.position == .left })
            Spacer(minLength: 0)
            run(units.filter { [.notchLeft, .center, .notchRight].contains($0.position) })
            Spacer(minLength: 0)
            run(units.filter { $0.position == .right })
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

    func workspaces(active: Int, group: WidgetStyle) -> some View {
        let style = resolveStyle([look.defaults, group])
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
        let show = style.show ?? .both
        let label = HStack {
            if show == .both || show == .label { Text("\(number)") }
        }
            .font(WidgetAppearance(style, defaults: look.defaults).font)
            .foregroundStyle(style.foreground?.color ?? (focused ? appearance.accentText : appearance.foreground))
            .padding(.leading, style.paddingLeading ?? style.paddingHorizontal ?? 7)
            .padding(.trailing, style.paddingTrailing ?? style.paddingHorizontal ?? 7)
            .frame(width: style.width.map { CGFloat($0) }, height: style.height.map { CGFloat($0) })
            .background {
                if workspace?.indicator == .cells {
                    let shape = RoundedRectangle(cornerRadius: style.cornerRadius ?? max(appearance.cornerRadius - 4, 0))
                    shape.fill(style.background?.shapeStyle ?? AnyShapeStyle(Color.clear))
                        .overlay {
                            if let border = style.borderColor { shape.strokeBorder(border.color, lineWidth: style.borderWidth ?? 1) }
                        }
                }
            }
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
                // As on the bar: no indicator means the background one, and `none` leaves the focused label alone.
                if focused && (workspace?.indicator ?? .background) == .background {
                    RoundedRectangle(cornerRadius: style.cornerRadius ?? max(appearance.cornerRadius - 4, 0))
                        .fill(style.background?.shapeStyle ?? AnyShapeStyle(appearance.accent))
                }
            }
    }

    /// Units that sit side by side, with a divider in the gap between two of them, as on the bar.
    private func run(_ units: [BarUnit]) -> some View {
        ForEach(units.indices, id: \.self) { index in
            unit(units[index]).overlay(alignment: .leading) {
                if let divider = look.bar.divider, divider.background != nil, index > 0, !units[index].isSpacer, !units[index - 1].isSpacer {
                    BarDividerLine(divider: divider).offset(x: -(look.bar.spacing + (divider.width ?? 1)) / 2)
                }
            }
        }
    }

    private func unit(_ unit: BarUnit) -> some View {
        BarUnitSurface(style: unit.style ?? WidgetStyle(), defaults: look.defaults, spacing: look.bar.spacing) {
            ForEach(unit.widgets) { sample($0, group: look.groupStyle(of: $0)) }
        }
        .fixedSize()
    }

    @ViewBuilder private func sample(_ widget: WidgetConfiguration, group: WidgetStyle = WidgetStyle()) -> some View {
        if widget.content == .workspaces {
            workspaces(active: 1, group: group)
        } else {
            let style = resolveStyle([look.defaults, look.roleStyle(widget.role), group, widget.barStyle])
            WidgetSampleContent(widget: widget, inheritedStyle: style.inheritedByBlocks, roles: look.roles)
                .modifier(ThemeSampleTile(style: style))
                .layoutPriority(1)
        }
    }

    func tile<Content: View>(role: PresentationRole, @ViewBuilder content: () -> Content) -> some View {
        let style = look.roleStyle(role).inheriting(look.defaults).resolved(for: StyleStates())
        return content().modifier(ThemeSampleTile(style: style))
    }

    /// The battery a battery widget draws in this look, at its value tiles' icon size.
    var battery: some View {
        let style = look.roleStyle(.value).inheriting(look.defaults).resolved(for: StyleStates())
        return BatteryGlyph(level: 0.82, power: .battery, needsService: false, iconSize: WidgetAppearance(style, defaults: WidgetStyle()).iconSize)
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
            .background {
                RoundedRectangle(cornerRadius: appearance.cornerRadius).fill(appearance.background)
                    .styledShadow(appearance.shadowFrom == .shape ? appearance : nil)
            }
            .overlay {
                RoundedRectangle(cornerRadius: appearance.cornerRadius)
                    .strokeBorder(appearance.borderColor, lineWidth: appearance.borderWidth)
            }
            .styledShadow(appearance.shadowFrom == .content ? appearance : nil)
    }
}
