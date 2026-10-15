import SwiftUI

struct BarView: View {
    let store: BarStore
    let display: BarDisplay
    @State private var measuredWidths: [String: CGFloat] = [:]
    @State private var overflowAnchor = NSView()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let config = store.configuration {
                let scale = CGFloat(config.bar.scale(for: display))
                let style = config.widgets.reduce(config.bar.style) { style, widget in
                    store.scripts[widget.id]?.output.barStyle?.inheriting(style) ?? style
                }
                let notch = display.notch.map { range in
                    let range = (range.lowerBound / scale)...(range.upperBound / scale)
                    return config.bar.notchWidth.map { width in
                        let center = (range.lowerBound + range.upperBound) / 2
                        return (center - width / 2)...(center + width / 2)
                    } ?? range
                }
                let activeID = store.workspaceStore.workspaces.first(where: \.isFocused)?.monitor ?? store.activeDisplayID
                let widgets = config.widgets.filter { widget in
                    let output = store.scripts[widget.id]?.output
                    if widget.content == .workspaces && widget.layout == nil && store.workspaceStore.error == nil
                        && store.workspaceStore.workspaces(on: display.id, showEmpty: widget.workspace?.showEmpty == true).isEmpty {
                        return false
                    }
                    return widget.enabled && (output?.display ?? widget.display).includes(display, activeID: activeID)
                        && (output?.hidden != true || store.scripts[widget.id]?.error != nil)
                }
                let units = BarUnit.make(widgets: widgets, groups: config.groups)
                GeometryReader { geometry in
                    let items = units.map { unit in
                        BarLayoutItem(id: unit.id, position: unit.position, width: measuredWidths[unit.id] ?? 0,
                                      priority: unit.priority, canOverflow: unit.canOverflow, isSpacer: unit.isSpacer)
                    }
                    let plan = AdaptiveBarPlanner(inset: config.bar.inset, spacing: config.bar.spacing,
                                                  notchSpacing: config.bar.notchSpacing, notch: notch)
                        .plan(width: geometry.size.width / scale, items: items)
                    let visible = Set(units.filter { plan.placements[$0.id] != nil }.flatMap { $0.widgets.map(\.id) })
                    ZStack(alignment: .topLeading) {
                        (style.background ?? config.bar.background).color
                        ForEach(units) { unit in
                            if let placement = plan.placements[unit.id] {
                                unitView(unit, config: config, width: placement.width)
                                    .frame(width: placement.width, height: geometry.size.height / scale)
                                    .offset(x: placement.x)
                            }
                        }
                        if let x = plan.overflowX {
                            overflowMenu(units.filter { plan.overflow.contains($0.id) }, config: config)
                                .frame(width: 30, height: geometry.size.height / scale)
                                .background(PopupAnchor(view: overflowAnchor, popup: store.popup))
                                .offset(x: x)
                        }
                    }
                    .overlay {
                        HStack(spacing: 0) {
                            ForEach(units) { unit in
                                BarUnitView(unit: unit, config: config, store: store, display: display.id)
                                    .fixedSize()
                                    .background {
                                        GeometryReader { proxy in
                                            Color.clear.preference(key: BarWidthPreference.self, value: [unit.id: proxy.size.width])
                                        }
                                    }
                            }
                        }
                        .fixedSize()
                        .hidden()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                    .onPreferenceChange(BarWidthPreference.self) { measuredWidths = $0 }
                    .onChange(of: visible, initial: true) { _, ids in store.setVisibleWidgets(ids: ids, displayID: display.id) }
                    .frame(width: geometry.size.width / scale, height: geometry.size.height / scale)
                    .scaleEffect(scale, anchor: .topLeading)
                }
                .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius ?? 0))
                .overlay(alignment: .bottom) {
                    (style.borderColor?.color ?? .clear).frame(height: style.borderWidth ?? 0)
                }
                .overlay(alignment: .topTrailing) {
                    if let error = store.configurationError {
                        Button { store.onCustomize?() } label: {
                            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(.orange)
                        }
                        .buttonStyle(.plain)
                        .help("\(error)\nClick to open Customize StableBar.")
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: config.bar.animationDuration), value: style)
            }
        }
        .onDisappear { store.setVisibleWidgets(ids: [], displayID: display.id) }
        .contextMenu {
            Text("StableBar")
            Button("Customize StableBar…") { store.onCustomize?() }
            Button("Set up StableBar…") { NSApp.sendAction(#selector(AppDelegate.showSetup), to: NSApp.delegate, from: nil) }
            Button("Open configuration file…") { store.openConfiguration() }
            Button("Reload configuration") { store.reloadConfiguration() }
            Button("Reconnect \(store.workspaceStore.source.title)") { store.workspaceStore.start() }
            if let error = store.configurationError ?? store.workspaceStore.error {
                Divider()
                Text(error)
            }
            Divider()
            Button("Quit StableBar") { NSApp.terminate(nil) }
        }
    }

    @ViewBuilder
    private func unitView(_ unit: BarUnit, config: Configuration, width: CGFloat) -> some View {
        if width < measuredWidths[unit.id, default: 0] - 0.5 {
            ScrollView(.horizontal) {
                BarUnitView(unit: unit, config: config, store: store, display: display.id).fixedSize()
            }
            .scrollIndicators(.hidden)
        } else {
            BarUnitView(unit: unit, config: config, store: store, display: display.id)
        }
    }

    private func overflowMenu(_ units: [BarUnit], config: Configuration) -> some View {
        Menu {
            ForEach(units) { unit in
                Section {
                    ForEach(unit.widgets) { widget in
                        let popup = widgetPopup(widget, store: store)
                        let command = store.scripts[widget.id]?.output.onClick ?? widget.onClick
                        if widget.content == .workspaces && popup == nil && command == nil {
                            ForEach(store.workspaceStore.workspaces.filter { $0.monitor == display.id }) { workspace in
                                Button("Workspace \(workspace.name)") { store.workspaceStore.select(workspace) }
                            }
                        } else {
                            Button(overflowTitle(widget)) {
                                if let popup {
                                    store.popup.toggle(popup, widget: widget, defaults: config.defaults, store: store, anchor: overflowAnchor)
                                } else if let command {
                                    store.runAction(command, widget: widget,
                                                    event: ScriptEvent(sender: "mouse.clicked", environment: ["BUTTON": "left", "SID": String(display.id)]))
                                }
                            }
                            .disabled(popup == nil && command == nil)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis").frame(width: 30, height: 24).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel("More widgets")
        .help("More widgets")
    }

    private func overflowTitle(_ widget: WidgetConfiguration) -> String {
        switch widget.content {
        case let .text(text): return text
        case let .clock(format):
            let formatter = DateFormatter()
            formatter.dateFormat = format
            return formatter.string(from: Date())
        case .activeApp: return store.activeApp?.localizedName ?? "Desktop"
        case .script, .provider:
            let text = store.scripts[widget.id]?.output.text ?? ""
            return text.isEmpty ? widget.id : text
        case .workspaces, .spacer: return widget.id
        }
    }
}

private struct BarWidthPreference: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct BarUnitView: View {
    let unit: BarUnit
    let config: Configuration
    let store: BarStore
    let display: Int

    var body: some View {
        if unit.isSpacer {
            Color.clear.frame(minWidth: unit.widgets[0].style.minWidth ?? 0,
                              idealWidth: unit.widgets[0].style.minWidth ?? 0, maxWidth: .infinity, minHeight: 1)
        } else {
            let style = unit.style ?? WidgetStyle()
            HStack(spacing: style.spacing ?? config.bar.spacing) {
                ForEach(unit.widgets) { widget in
                    WidgetView(widget: widget, defaults: config.defaults, store: store,
                               monitor: display, animationDuration: config.bar.animationDuration)
                }
            }
            .padding(.leading, style.paddingLeading ?? style.paddingHorizontal ?? 0)
            .padding(.trailing, style.paddingTrailing ?? style.paddingHorizontal ?? 0)
            .padding(.top, style.paddingTop ?? style.paddingVertical ?? 0)
            .padding(.bottom, style.paddingBottom ?? style.paddingVertical ?? 0)
            .background(style.background?.color ?? .clear, in: RoundedRectangle(cornerRadius: style.cornerRadius ?? 0))
            .overlay {
                RoundedRectangle(cornerRadius: style.cornerRadius ?? 0)
                    .strokeBorder(style.borderColor?.color ?? .clear, lineWidth: style.borderWidth ?? 0)
            }
        }
    }
}

@MainActor
private func widgetPopup(_ widget: WidgetConfiguration, store: BarStore) -> PopupConfiguration? {
    if let popup = widget.popup { return popup }
    if let name = widget.popupName { return store.configuration!.popups[name]! }
    if let menu = store.scripts[widget.id]?.output.menu ?? widget.menu, !menu.isEmpty {
        return PopupConfiguration(
            style: WidgetStyle(fontSize: 12, paddingHorizontal: 12, paddingVertical: 12, spacing: 4),
            layout: PopupBlock(content: .menu)
        )
    }
    return nil
}

struct WidgetView: View {
    let widget: WidgetConfiguration
    let defaults: WidgetStyle
    let store: BarStore
    let monitor: Int
    let animationDuration: Double
    @State private var hovered = false
    @State private var popupAnchor = NSView()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var style: WidgetStyle {
        let output = store.scripts[widget.id]?.output
        var style = widget.style.inheriting(defaults)
        for source in store.configuration?.widgets ?? [] {
            if let override = store.scripts[source.id]?.output.widgetStyles?[widget.id] {
                style = override.inheriting(style)
            }
        }
        style = (output?.style ?? WidgetStyle()).inheriting(style)
        if let color = output?.color { style.foreground = color }
        return style
    }

    var body: some View {
        let output = store.scripts[widget.id]?.output
        let appearance = WidgetAppearance(style, defaults: WidgetStyle())
        let animation = output?.animation ?? widget.animation ?? WidgetAnimation(duration: animationDuration)
        Group {
            if let popup = widgetPopup(widget, store: store) {
                Button {
                    store.popup.toggle(popup, widget: widget, defaults: defaults, store: store, anchor: popupAnchor)
                } label: { content(appearance) }
                .buttonStyle(.plain)
            } else if let command = output?.onClick ?? widget.onClick {
                Button { runAction(command, sender: "mouse.clicked", button: "left") } label: { content(appearance) }
                    .buttonStyle(.plain)
            } else {
                content(appearance)
            }
        }
        .font(appearance.font)
        .foregroundStyle(hovered ? appearance.hoverForeground : appearance.foreground)
        .padding(.leading, style.paddingLeading ?? appearance.paddingHorizontal)
        .padding(.trailing, style.paddingTrailing ?? appearance.paddingHorizontal)
        .padding(.top, style.paddingTop ?? appearance.paddingVertical)
        .padding(.bottom, style.paddingBottom ?? appearance.paddingVertical)
        .frame(width: appearance.width, height: style.height.map { CGFloat($0) })
        .frame(minWidth: style.minWidth.map { CGFloat($0) }, maxWidth: style.maxWidth.map { CGFloat($0) })
        .background(hovered ? appearance.hoverBackground : appearance.background,
                    in: RoundedRectangle(cornerRadius: appearance.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: appearance.cornerRadius)
                .strokeBorder(appearance.borderColor, lineWidth: appearance.borderWidth)
        }
        .overlay(alignment: .topTrailing) {
            if let error = store.scripts[widget.id]?.error ?? store.actionErrors[widget.id] {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).font(.system(size: 8)).help(error)
            }
        }
        .shadow(color: appearance.shadowColor, radius: appearance.shadowRadius, y: 1)
        .overlay(alignment: .bottom) {
            if let overlay = widget.overlay {
                block(overlay, style: style, fillsWidth: true).allowsHitTesting(false)
            }
        }
        .overlay {
            if let actions = widget.actions {
                WidgetActionCapture(actions: actions, display: monitor) { command, context in
                    store.runAction(command, widget: widget,
                                    event: ScriptEvent(sender: context.sender, environment: context.environment))
                }
            }
        }
        .offset(x: style.offsetX ?? 0, y: style.offsetY ?? 0)
        .opacity(style.opacity ?? 1)
        .background(PopupAnchor(view: popupAnchor, popup: store.popup))
        .onHover { inside in
            hovered = inside
            if let command = inside ? widget.actions?.mouseEntered : widget.actions?.mouseExited {
                runAction(command, sender: inside ? "mouse.entered" : "mouse.exited")
            }
        }
        .animation(reduceMotion ? nil : animation.value, value: hovered)
        .animation(reduceMotion ? nil : animation.value, value: style)
        .accessibilityIdentifier(widget.id)
    }

    private func runAction(_ command: String, sender: String, button: String? = nil) {
        let context = WidgetActionContext(sender: sender, button: button, modifiers: NSEvent.modifierFlags, display: monitor)
        store.runAction(command, widget: widget, event: ScriptEvent(sender: sender, environment: context.environment))
    }

    @ViewBuilder
    private func content(_ appearance: WidgetAppearance) -> some View {
        if let layout = widget.layout {
            block(layout, style: style, fillsWidth: false)
                .help(store.scripts[widget.id]?.error ?? store.scripts[widget.id]?.output.tooltip ?? "")
        } else {
            switch widget.content {
            case .workspaces:
                WorkspaceView(workspaceStore: store.workspaceStore, monitor: monitor,
                              appearance: appearance, animationDuration: animationDuration,
                              configuration: widget.workspace, animation: widget.animation, defaults: widget.style.inheriting(defaults))
            case .activeApp:
                HStack(spacing: appearance.spacing) {
                    if let icon = store.activeApp?.icon {
                        Image(nsImage: icon).resizable().frame(width: appearance.iconSize, height: appearance.iconSize)
                    }
                    Text(store.activeApp?.localizedName ?? "Desktop").lineLimit(1)
                }
            case let .clock(format):
                TimelineView(.periodic(from: Calendar.current.startOfDay(for: .now), by: format.contains("s") ? 1 : 60)) { context in
                    let formatter = DateFormatter()
                    let _ = formatter.dateFormat = format
                    label(formatter.string(from: context.date), icon: widget.icon, appearance: appearance)
                        .monospacedDigit()
                }
            case let .text(text):
                label(text, icon: widget.icon, appearance: appearance)
            case .spacer:
                Spacer(minLength: style.minWidth ?? 0)
            case .script, .provider:
                if let script = store.scripts[widget.id] {
                    HStack(spacing: appearance.spacing) {
                        if script.output.value != nil {
                            Sparkline(samples: script.samples)
                                .stroke(appearance.accent, lineWidth: 1.2)
                                .frame(width: 40, height: 16)
                        }
                        label(script.output.text, icon: script.output.icon ?? widget.icon, appearance: appearance)
                    }
                        .foregroundStyle(hovered ? appearance.hoverForeground : appearance.foreground)
                        .help(script.error ?? script.output.tooltip ?? "")
                }
            }
        }
    }

    private func block(_ block: PopupBlock, style: WidgetStyle, fillsWidth: Bool) -> some View {
        let script = store.scripts[widget.id]
        var fields = script?.output.fields ?? [:]
        switch widget.content {
        case let .text(text): fields["text"] = text
        case .activeApp: fields["text"] = store.activeApp?.localizedName ?? "Desktop"
        case .script, .provider:
            fields["text"] = script?.output.text ?? "…"
            fields["icon"] = script?.output.icon ?? widget.icon ?? ""
        default: break
        }
        return PopupBlockView(block: block, inheritedStyle: style, fields: fields,
                              lists: script?.output.lists ?? [:], samples: script?.samples ?? [],
                              menu: script?.output.menu ?? widget.menu ?? [], values: script?.output.values ?? [:],
                              targets: script?.output.targets ?? [:], styles: script?.output.styles ?? [:],
                              series: script?.output.series ?? [:],
                              fillsWidth: fillsWidth) { command, environment in
            if environment.isEmpty {
                runAction(command, sender: "mouse.clicked", button: "left")
            } else {
                store.runAction(command, widget: widget,
                                event: ScriptEvent(sender: "control.changed", environment: environment.merging(["SID": String(monitor)]) { first, _ in first }))
            }
        }
    }

    private func label(_ text: String, icon: String?, appearance: WidgetAppearance) -> some View {
        HStack(spacing: appearance.spacing) {
            if let icon { Image(systemName: icon).font(.system(size: appearance.iconSize)) }
            if !text.isEmpty { Text(text).lineLimit(1) }
        }
    }
}

struct Sparkline: Shape {
    let samples: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for (index, value) in samples.enumerated() {
            let point = CGPoint(x: rect.width * Double(index) / 59,
                                y: rect.height * (1 - min(max(value, 0), 1)))
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}

struct WorkspaceView: View {
    let workspaceStore: WorkspaceStore
    let monitor: Int
    let appearance: WidgetAppearance
    let animationDuration: Double
    var configuration: WorkspaceConfiguration?
    var animation: WidgetAnimation?
    var defaults = WidgetStyle()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selection
    @State private var hoveredWorkspace: String?

    var body: some View {
        let workspaces = workspaceStore.workspaces(on: monitor, showEmpty: configuration?.showEmpty == true)
        let indicator = configuration?.indicator ?? .background
        let indicatorStyle = configuration?.indicatorStyle ?? WidgetStyle()
        HStack(spacing: appearance.spacing) {
            ForEach(workspaces) { workspace in
                let base = configuration?.style ?? WidgetStyle()
                let stateStyle = if workspace.isFocused { configuration?.focusedStyle }
                    else if workspace.isVisible { configuration?.visibleStyle }
                    else if workspace.apps.isEmpty { configuration?.emptyStyle }
                    else { nil as WidgetStyle? }
                let style = (stateStyle ?? WidgetStyle()).inheriting(base)
                let appStateStyle = workspace.isFocused ? configuration?.focusedAppStyle : workspace.isVisible ? configuration?.visibleAppStyle : nil
                let appStyle = (appStateStyle ?? WidgetStyle()).inheriting(configuration?.appStyle ?? WidgetStyle())
                Button { workspaceStore.select(workspace) } label: {
                    HStack(spacing: style.spacing ?? 4) {
                        Text(workspace.name)
                        if configuration?.showApps != false {
                            ForEach(workspace.apps) { app in
                                if let glyph = configuration?.appGlyphs?[app.bundleID] ?? configuration?.appGlyphs?[app.name] ?? configuration?.appGlyphs?["*"] {
                                    Text(glyph)
                                        .font(WidgetAppearance(appStyle, defaults: WidgetStyle()).font)
                                        .foregroundStyle((hoveredWorkspace == workspace.name ? appStyle.hoverForeground?.color : nil)
                                                         ?? appStyle.foreground?.color ?? appearance.foreground)
                                        .help(app.name)
                                } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                        .resizable().frame(width: appStyle.width ?? 14, height: appStyle.height ?? 14)
                                        .help(app.name)
                                }
                            }
                        }
                    }
                    .font(WidgetAppearance(style, defaults: defaults).font)
                    .foregroundStyle((hoveredWorkspace == workspace.name ? style.hoverForeground?.color : nil)
                                     ?? style.foreground?.color ?? (workspace.isFocused ? appearance.accentText : appearance.foreground))
                    .padding(.leading, style.paddingLeading ?? style.paddingHorizontal ?? 7)
                    .padding(.trailing, style.paddingTrailing ?? style.paddingHorizontal ?? 7)
                    .frame(width: style.width.map { CGFloat($0) }, height: style.height ?? 22)
                    .background {
                        if indicator == .background && workspace.isFocused {
                            RoundedRectangle(cornerRadius: style.cornerRadius ?? max(appearance.cornerRadius - 4, 0))
                                .fill(style.background?.color ?? appearance.accent)
                                .matchedGeometryEffect(id: "focused-workspace", in: selection)
                        } else if indicator == .background && workspace.isVisible {
                            RoundedRectangle(cornerRadius: style.cornerRadius ?? max(appearance.cornerRadius - 4, 0))
                                .strokeBorder(style.borderColor?.color ?? appearance.accent, lineWidth: style.borderWidth ?? 1)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if indicator == .underline && workspace.isVisible {
                            RoundedRectangle(cornerRadius: indicatorStyle.cornerRadius ?? 0)
                                .fill(indicatorStyle.background?.color ?? appearance.accent)
                                .frame(width: indicatorStyle.width.map { CGFloat($0) }, height: indicatorStyle.height ?? 2)
                                .matchedGeometryEffect(id: "workspace-underline", in: selection)
                                .offset(x: indicatorStyle.offsetX ?? 0, y: indicatorStyle.offsetY ?? 0)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hoveredWorkspace = $0 ? workspace.name : nil }
                .help("Switch to workspace \(workspace.name)")
                .accessibilityLabel("Workspace \(workspace.name)\(workspace.isFocused ? ", focused" : workspace.isVisible ? ", visible" : "")")
                .accessibilityAddTraits(workspace.isFocused ? .isSelected : [])
            }
            if let error = workspaceStore.error {
                Image(systemName: "exclamationmark.triangle").help(error)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .animation(reduceMotion ? nil : (animation?.value ?? .smooth(duration: animationDuration)), value: workspaces)
    }
}
