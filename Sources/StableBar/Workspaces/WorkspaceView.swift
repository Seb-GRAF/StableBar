import SwiftUI

struct WorkspaceView: View {
    let workspaceStore: WorkspaceStore
    let monitor: Int
    let appearance: WidgetAppearance
    var padding = EdgeInsets()
    var configuration: WorkspaceConfiguration?
    let animation: WidgetAnimation
    var defaults = WidgetStyle()
    var modeAliases: [String: String] = [:]
    var widgetID = ""
    var allowsWindowDragging = true
    var appNameTooltip: (Bool, String, NSView) -> Void = { _, _, _ in }
    @Environment(\.measuringBarWidths) private var measuring
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @Namespace private var selection
    @State private var hoveredWorkspace: String?
    @State private var appIcons = WorkspaceAppIcons()
    @State private var magnifier = WorkspaceMagnifier()

    var body: some View {
        let workspaces = workspaceStore.workspaces(on: monitor,
            showEmpty: configuration?.showEmpty == true
                || (workspaceStore.source.supportsWindowMoves && workspaceStore.windowDrag.active != nil),
            hideApps: configuration?.hideApps ?? [], hideWorkspaces: configuration?.hideWorkspaces ?? [])
        let indicator = configuration?.indicator ?? .background
        HStack(spacing: appearance.spacing) {
            ForEach(workspaces) { workspace in
                let mode = configuration?.usesModeStates == true
                    ? ModePresentation(mode: workspaceStore.mode, aliases: modeAliases) : ModePresentation()
                let styles = configuration?.cellStyle(WorkspaceState(workspace), mode: mode) ?? WorkspaceCellStyle()
                let hovered = hoveredWorkspace == workspace.name
                let style = styles.label(hovered: hovered)
                let show = style.show ?? .both
                let glyph = styles.glyph(hovered: hovered)
                let zoomedBelow = magnification.map { (glyph.height ?? 14) * ($0 - 1) } ?? 0
                let textColor = style.foreground?.color ?? (workspace.isFocused ? appearance.accentText : appearance.foreground)
                let highlight = configuration?.focusedWindowStyle
                    .map { $0.resolved(for: StyleStates(workspace: WorkspaceState(workspace), mode: mode, hover: hovered)) }
                    .map { FocusedWindowHighlight(style: $0, color: textColor, magnifying: magnifying,
                                                  cornerRadius: $0.cornerRadius ?? styles.resting.cornerRadius ?? max(appearance.cornerRadius - 4, 0)) }
                HStack(spacing: style.spacing ?? 4) {
                    if show == .both || show == .label {
                        Button { workspaceStore.select(workspace) } label: {
                            HStack(spacing: style.spacing ?? 4) {
                                Text(workspace.label)
                                if let layout = workspace.layout, let glyph = configuration?.layoutGlyphs?[layout] {
                                    Text(glyph)
                                }
                            }
                        }
                        .magnified(.label, by: magnifier, upTo: magnification)
                        .help("Switch to workspace \(workspace.label)")
                        .accessibilityLabel("Workspace \(workspace.label)\(workspace.isFocused ? ", focused" : workspace.isVisible ? ", visible" : "")")
                        .accessibilityValue(layoutValue(for: workspace))
                        .accessibilityAddTraits(workspace.isFocused ? .isSelected : [])
                    }
                    if configuration?.showApps != false && (show == .both || show == .apps) {
                        if configuration?.windows == true {
                            ForEach(workspace.windows) { window in
                                windowButton(windows: [window], below: zoomedBelow, action: { workspaceStore.focus(window) }) {
                                    HStack(spacing: style.spacing ?? 4) {
                                        appIcon(window.app, style: glyph, color: textColor, spacing: style.spacing ?? 4,
                                                highlight: window.isFocused ? highlight : nil)
                                        if window.stackIndex > 0 {
                                            Text(String(window.stackIndex)).magnified(.label, by: magnifier, upTo: magnification)
                                        }
                                        if let length = configuration?.titleLength, length > 0 {
                                            Text(String(window.title.prefix(length))).magnified(.label, by: magnifier, upTo: magnification)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .help(magnification == nil ? window.title : "")
                                .accessibilityLabel("\(window.app.name): \(window.title)\(window.stackIndex > 0 ? ", stack position \(window.stackIndex)" : "")\(window.isFocused ? ", focused" : "")")
                                .accessibilityAddTraits(window.isFocused ? .isSelected : [])
                                .accessibilityValue(badgeValue(for: window.app))
                            }
                        } else {
                            ForEach(workspace.apps) { app in
                                let windows = workspace.windows.filter { $0.app.bundleID == app.bundleID }
                                let focused = windows.contains(where: \.isFocused)
                                windowButton(windows: windows, below: zoomedBelow, action: { workspaceStore.select(workspace) }) {
                                    appIcon(app, style: glyph, color: textColor, spacing: style.spacing ?? 4, highlight: focused ? highlight : nil)
                                }
                                .help(magnification == nil ? app.name : "")
                                .accessibilityValue(badgeValue(for: app))
                                .accessibilityLabel("\(app.name)\(focused ? ", focused" : "")")
                                .accessibilityAddTraits(focused ? .isSelected : [])
                            }
                        }
                    }
                }
                .font(WidgetAppearance(style, defaults: defaults).font)
                .foregroundStyle(textColor)
                .padding(.leading, style.paddingLeading ?? style.paddingHorizontal ?? 7)
                .padding(.trailing, style.paddingTrailing ?? style.paddingHorizontal ?? 7)
                .frame(width: style.width.map { CGFloat($0) }, height: style.height.map { CGFloat($0) })
                .background {
                    if indicator == .cells {
                        let shape = RoundedRectangle(cornerRadius: styles.resting.cornerRadius ?? max(appearance.cornerRadius - 4, 0))
                        shape.fill(styles.resting.background?.shapeStyle ?? AnyShapeStyle(Color.clear))
                            .overlay {
                                if let border = styles.resting.borderColor { shape.strokeBorder(border.color, lineWidth: styles.resting.borderWidth ?? 1) }
                            }
                            .magnified(.background, by: magnifier, upTo: magnification)
                            .allowsHitTesting(false)
                    }
                }
                .padding(padding)
                .background {
                    Button { workspaceStore.select(workspace) } label: {
                        Color.clear.contentShape(Rectangle())
                    }
                    .accessibilityLabel("Switch to workspace \(workspace.label)")
                }
                .buttonStyle(.plain)
                .modifier(WorkspaceWindowDrop(store: workspaceStore, workspace: workspace.name, enabled: canDragWindows))
                .overlay(alignment: .bottom) {
                    if indicator == .underline && workspace.isVisible && styles.underline.placement != .belowBar {
                        RoundedRectangle(cornerRadius: styles.underline.cornerRadius ?? 0)
                            .fill(styles.underline.background?.shapeStyle ?? AnyShapeStyle(appearance.accent))
                            .frame(width: styles.underline.width.map { CGFloat($0) }, height: styles.underline.height ?? 2)
                            .magnified(.background, by: magnifier, upTo: magnification)
                            .matchedGeometryEffect(id: "workspace-underline", in: selection)
                            .offset(x: styles.underline.offsetX ?? 0, y: (styles.underline.offsetY ?? 0) - padding.bottom)
                    }
                }
                .background {
                    if indicator == .background && workspace.isFocused {
                        RoundedRectangle(cornerRadius: styles.resting.cornerRadius ?? max(appearance.cornerRadius - 4, 0))
                            .fill(styles.resting.background?.shapeStyle ?? AnyShapeStyle(appearance.accent))
                            .magnified(.background, by: magnifier, upTo: magnification)
                            .matchedGeometryEffect(id: "focused-workspace", in: selection)
                    } else if indicator == .background && workspace.isVisible {
                        RoundedRectangle(cornerRadius: styles.resting.cornerRadius ?? max(appearance.cornerRadius - 4, 0))
                            .strokeBorder(styles.resting.borderColor?.color ?? appearance.accent, lineWidth: styles.resting.borderWidth ?? 1)
                            .magnified(.background, by: magnifier, upTo: magnification)
                    }
                }
                .overlay {
                    if canDragWindows && workspaceStore.windowDrag.target == workspace.name {
                        RoundedRectangle(cornerRadius: styles.resting.cornerRadius ?? max(appearance.cornerRadius - 4, 0))
                            .strokeBorder(appearance.accent, lineWidth: 2)
                            .allowsHitTesting(false)
                    }
                }
                .anchorPreference(key: BarAnchorPreference.self, value: .bounds) { anchor in
                    guard !measuring, indicator == .underline, workspace.isVisible, styles.underline.placement == .belowBar else {
                        return BarAnchors()
                    }
                    // One visible selection per widget/display keeps its identity as focus moves.
                    return BarAnchors(underlines: [widgetID: WorkspaceUnderlineAnchor(widget: widgetID, cell: anchor,
                        selection: workspace.name,
                        style: styles.underline, color: styles.underline.background?.firstColor.color ?? appearance.accent,
                        animation: animation)])
                }
                .onHover { hoveredWorkspace = $0 ? workspace.name : nil }
                .animation(hoverAnimation(hovered, reduceMotion: reduceMotion), value: hovered)
            }
            if let error = workspaceStore.error {
                Image(systemName: "exclamationmark.triangle").padding(padding).help(error)
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .global) { phase in
            if workspaceStore.windowDrag.active == nil { magnifier.track(phase) }
        }
        .onChange(of: workspaceStore.windowDrag.active != nil) { _, dragging in
            if dragging { magnifier.track(.ended) }
        }
        .fixedSize(horizontal: true, vertical: false)
        .animation(reduceMotion ? nil : animation.value, value: workspaces)
    }

    private var magnification: CGFloat? { configuration?.magnification.map { CGFloat($0) } }

    /// The magnifier tracks the pointer even with magnification off, when nothing zooms.
    private var magnifying: Bool { magnification != nil && magnifier.isActive }

    private var canDragWindows: Bool {
        allowsWindowDragging && !measuring && workspaceStore.source.supportsWindowMoves
    }

    @ViewBuilder private func windowButton(windows: [WorkspaceWindow], below: CGFloat, action: @escaping () -> Void,
                                           @ViewBuilder label: @escaping () -> some View) -> some View {
        if canDragWindows && !windows.isEmpty {
            WorkspaceWindowDragSource(store: workspaceStore, windows: windows, action: action) {
                Button(action: action) { label().padding(.bottom, below).contentShape(Rectangle()) }.buttonStyle(.plain)
            }
            .padding(.bottom, -below)
        } else {
            Button(action: action) { label().padding(.bottom, below).contentShape(Rectangle()) }
                .padding(.bottom, -below)
        }
    }

    private func layoutValue(for workspace: Workspace) -> String {
        guard let layout = workspace.layout, configuration?.layoutGlyphs?[layout] != nil else { return "" }
        return "\(layout) layout"
    }

    private func badgeValue(for app: WorkspaceApp) -> String {
        guard configuration?.badges != nil, let label = workspaceStore.dockBadges.labels[app.bundleID] else { return "" }
        return "Badge \(label)"
    }

    @ViewBuilder private func appIcon(_ app: WorkspaceApp, style: WidgetStyle, color: Color, spacing: CGFloat,
                                      highlight: FocusedWindowHighlight? = nil) -> some View {
        let zoom = magnification ?? 1
        let style = highlight.map { $0.style.inheriting(style) } ?? style
        let icon = Group {
            if let glyphs = configuration?.appGlyphs, let text = appGlyph(for: app, in: glyphs) {
                Text(text)
                    .font(WidgetAppearance(style, defaults: WidgetStyle()).font)
                    .foregroundStyle(style.foreground?.color ?? appearance.foreground)
            } else if let image = appIcons.image(for: app.bundleID,
                                                 size: NSSize(width: (style.width ?? 14) * zoom, height: (style.height ?? 14) * zoom),
                                                 scale: displayScale) {
                Image(nsImage: image)
                    .renderingMode(.original)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: style.width ?? 14, height: style.height ?? 14)
                    .styledAppIcon(style.appIcons ?? appearance.appIcons, color: style.foreground?.color ?? color)
            }
        }
        // Inside the icon, so magnification zooms and slides the highlight with it.
        .background { highlight }
        .overlay(alignment: .topTrailing) {
            if let badges = configuration?.badges, let label = workspaceStore.dockBadges.labels[app.bundleID] {
                DockBadge(style: badges, label: label, iconHeight: style.height ?? 14)
            }
        }
        if let magnification {
            icon
                .modifier(WorkspaceMagnification(magnifier: magnifier, part: .icon, maximum: magnification))
                .modifier(AppNameTooltip(name: app.name, magnifier: magnifier, spacing: spacing, hover: appNameTooltip))
        } else {
            icon
        }
    }
}

/// The focused window's highlight, drawn outside the icon's frame so focus moving doesn't shift the icons.
private struct FocusedWindowHighlight: View {
    let style: WidgetStyle
    let color: Color
    /// Scaled with a magnified icon, so it hugs the icon then to stay small and below the bar's top edge.
    let magnifying: Bool
    let cornerRadius: Double

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        let horizontal = style.paddingHorizontal ?? 3
        shape.fill(style.background?.shapeStyle ?? AnyShapeStyle(color.opacity(0.22)))
            .overlay {
                if let border = style.borderColor { shape.strokeBorder(border.color, lineWidth: style.borderWidth ?? 1) }
            }
            .padding(.horizontal, -(magnifying ? min(horizontal, 2) : horizontal))
            .padding(.vertical, magnifying ? 0 : -(style.paddingVertical ?? 2))
            .allowsHitTesting(false)
    }
}

func appGlyph(for app: WorkspaceApp, in glyphs: [String: String]) -> String? {
    if let glyph = glyphs[app.bundleID] ?? glyphs[app.name] { return glyph }
    return glyphs.filter { $0.key.hasSuffix("*") && appMatches(app, key: $0.key) }.max { $0.key.count < $1.key.count }?.value
}

/// Whether an `appGlyphs` or `hideApps` key names the app: its bundle ID, its name, or a name prefix followed by `*`.
func appMatches(_ app: WorkspaceApp, key: String) -> Bool {
    key == app.bundleID || key == app.name || key.hasSuffix("*") && app.name.hasPrefix(key.dropLast())
}
