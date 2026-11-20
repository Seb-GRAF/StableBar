import SwiftUI

@MainActor
func widgetPopup(_ widget: WidgetConfiguration, store: BarStore) -> PopupConfiguration? {
    if widget.id == AppUpdate.widgetID { return AppUpdate.popup }
    if let popup = widget.popup { return popup }
    if let name = widget.popupName { return store.configuration?.popups[name] }
    if let menu = store.widgetScripts.scripts[widget.id]?.output.menu ?? widget.menu, !menu.isEmpty {
        return PopupConfiguration(
            style: WidgetStyle(fontSize: 12, spacing: 4),
            layout: PopupBlock(content: .menu)
        )
    }
    if widget.details, widget.onClick == nil, widget.open == nil, store.widgetScripts.scripts[widget.id]?.output.onClick == nil,
       let kind = EssentialsPopup.kind(for: widget, providerType: store.configuration?.providerType(of: widget)) {
        return kind.popup(timeZone: widget.timeZone)
    }
    return nil
}

/// A clock's refresh schedule: each second when its format shows seconds, otherwise each minute.
private func clockSchedule(_ format: String) -> PeriodicTimelineSchedule {
    .periodic(from: Calendar.current.startOfDay(for: .now), by: format.contains("s") ? 1 : 60)
}

struct WidgetView: View {
    let widget: WidgetConfiguration
    let defaults: WidgetStyle
    let popupDefaults: WidgetStyle
    let store: BarStore
    let monitor: Int
    let defaultAnimation: WidgetAnimation
    let defaultTransition: WidgetTransition
    @State private var hovered = false
    @State private var popupAnchor = NSView()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.measuringBarWidths) private var measuring
    @Environment(\.barUnitID) private var unitID
    @Environment(\.screenKind) private var screenKind
    @Environment(\.moreWidgetsAnchor) private var moreWidgetsAnchor
    @Environment(\.barExpansion) private var barExpansion
    @Environment(\.fixedDate) private var fixedDate
    @Environment(\.barFocus) private var barFocus
    @Environment(\.focusesWidgets) private var focusesWidgets
    @Environment(\.macOSVersion) private var macOSVersion

    private var resolution: ResolvedWidgetStyle {
        store.barPresentation.presentations[widget.id]?.style(on: screenKind) ?? ResolvedWidgetStyle(base: resolveStyle([defaults, widget.barStyle]))
    }

    private var clickAnchor: NSView { moreWidgetsAnchor ?? popupAnchor }

    /// Whether the widget's own command, link, popup or menu takes its click, before a built-in click such as the Apple logo's.
    /// A menu counts even when empty, as in Settings.
    private var hasOwnClick: Bool {
        let output = store.widgetScripts.scripts[widget.id]?.output
        return widgetPopup(widget, store: store) != nil || (output?.onClick ?? widget.onClick) != nil || widget.open != nil
            || (output?.menu ?? widget.menu) != nil
    }

    private var inlineHoverControls: Bool { store.configuration?.bar.inlineHoverControls == true }

    private var isSound: Bool { widget.layout == nil && store.configuration?.providerType(of: widget) == DataSourceType.audio.name }

    /// `tile` as a button for its click action, popup or link, or as it is while the bar is being
    /// edited, when it takes no clicks. `isOpen` tells whether the popup it opens is open.
    @ViewBuilder private func clickable(_ tile: some View, output: ScriptOutput?, isOpen: Bool) -> some View {
        if store.barEditing.isActive {
            tile
        } else if widget.id == PackageLibrary.updateWidgetID {
            let buttons = HStack(spacing: 0) {
                Button(action: store.packageLibrary.openUpdates) { tile }
                    .accessibilityLabel("Open package updates")
                Button(action: store.packageLibrary.dismissUpdates) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                        .padding(6)
                }
                .accessibilityLabel("Dismiss package update notification")
                .help("Dismiss package update notification")
            }
            .buttonStyle(.plain)
            pressable(buttons, click: store.packageLibrary.openUpdates)
        } else if widget.hoverLayout != nil, let command = output?.onClick ?? widget.onClick {
            let click = { runAction(.command(command), sender: "mouse.clicked", button: "left") }
            pressable(Button(action: click) { tile }.buttonStyle(.plain), click: click)
        } else if let popup = widgetPopup(widget, store: store) {
            let click = {
                guard store.barEditing.allowsWidgetActions else { return }
                store.popup.toggle(popup, widget: widget, defaults: popupDefaults.popupStyle(over: defaults), store: store, anchor: clickAnchor)
            }
            pressable(Button(action: click) { tile }.buttonStyle(.plain), click: click, popupOpen: isOpen)
        } else if let command = output?.onClick ?? widget.onClick {
            let click = { runAction(.command(command), sender: "mouse.clicked", button: "left") }
            pressable(Button(action: click) { tile }.buttonStyle(.plain), click: click)
        } else if let open = widget.open {
            let click = { if store.barEditing.allowsWidgetActions { OpenTarget(open)!.open() } }
            pressable(Button(action: click) { tile }.buttonStyle(.plain), click: click)
        } else if store.configuration?.providerType(of: widget) == DataSourceType.inputSource.name, !hasOwnClick {
            let click = { if store.barEditing.allowsWidgetActions { store.widgetScripts.selectInputSource(nil, widget: widget) } }
            pressable(Button(action: click) { tile }.buttonStyle(.plain), click: click)
        } else if case let .appleMenu(appleClick) = widget.content, widget.layout != nil, !hasOwnClick {
            let click = { clickAppleLogo(appleClick, anchor: clickAnchor) }
            let button = Button(action: click) { tile }
                .buttonStyle(.plain)
                .onHover { if $0, appleClick == .menu { store.appMenu.refresh() } }
            pressable(button, click: click, popupOpen: appleClick == .menu ? isOpen : nil)
        } else if widget.content == .controlCenter {
            let click = { if store.barEditing.allowsWidgetActions { store.appMenu.openControlCenter() } }
            pressable(Button(action: click) { tile }.buttonStyle(MouseDownButtonStyle()), click: click)
        } else if widget.content == .stableBar, !hasOwnClick {
            let click = { if store.barEditing.allowsWidgetActions { store.onWindowRequest?(.customize) } }
            pressable(Button(action: click) { tile }.buttonStyle(.plain), click: click)
        } else if case let .menuBarItems(_, _, _, hidden) = widget.content, !widget.drawsMenuBarItems {
            let click = { toggleMenuBarItems(leavingOut: hidden.references, anchor: clickAnchor) }
            pressable(Button(action: click) { tile }.buttonStyle(.plain), click: click, popupOpen: isOpen)
        } else {
            pressable(tile)
        }
    }

    /// `view`, the widget's tile or button, as the keyboard and VoiceOver press it. While the bar has keyboard focus, the
    /// arrow keys reach it and Return or Space does `click`. A click that opens a popup reads as a button that expands,
    /// with `popupOpen` as its state, which SwiftUI can't report.
    @ViewBuilder private func pressable(_ view: some View, click: (() -> Void)? = nil, popupOpen: Bool? = nil) -> some View {
        let element = Group {
            if let click, let popupOpen {
                view.accessibilityRepresentation {
                    PopupButtonAccessibility(label: accessibilityName, value: { accessibilityValue(date: .now) },
                                             expanded: popupOpen, press: click)
                }
            } else {
                view
            }
        }
        if let barFocus {
            element
                .focusable(focusesWidgets)
                .focused(barFocus, equals: widget.id)
                .onKeyPress(keys: [.return, .space]) { _ in
                    guard let click else { return .ignored }
                    click()
                    return .handled
                }
        } else {
            element
        }
    }

    /// What VoiceOver calls the widget: its name in Settings, or the offer of the update widget.
    private var accessibilityName: String {
        widget.id == AppUpdate.widgetID ? widget.tooltip!
            : WidgetDisplayName.name(for: widget, packageName: store.widgetPackageNames[widget.id], providers: store.configuration?.providers ?? [:])
    }

    /// What VoiceOver reads after the widget's name: the text it shows at `date`, or the latest value of a graph shown
    /// without text.
    private func accessibilityValue(date: Date) -> String {
        let text = store.label(for: widget, date: date).overlaid(by: store.barPresentation.presentations[widget.id]?.temporaryFields).text
        guard text.isEmpty, let value = store.widgetScripts.scripts[widget.id]?.output.value else { return text }
        return value.formatted(.percent.precision(.fractionLength(0)))
    }

    /// Opens the widget's hover popup, hover controls or tooltip when the pointer enters it, closes
    /// them when it leaves, and runs the widget's mouse actions.
    private func hoverChanged(_ inside: Bool, tooltip: String?, output: ScriptOutput?) {
        guard store.barEditing.allowsWidgetActions else { return }
        hovered = inside
        if !inside {
            store.popup.hover(false, store: store, anchor: popupAnchor) {}
        } else if let popup = widgetPopup(widget, store: store), popup.openOnHover {
            store.popup.hover(inside, store: store, anchor: popupAnchor) {
                store.popup.open(popup, widget: widget, defaults: popupDefaults.popupStyle(over: defaults),
                                 store: store, anchor: popupAnchor, onHover: true)
            }
        } else if case let .menuBarItems(openOnHover: true, _, _, hidden) = widget.content, !widget.drawsMenuBarItems,
                  widgetPopup(widget, store: store) == nil, widget.onClick == nil, widget.open == nil {
            hoverMenuBarItems(inside, leavingOut: hidden.references, anchor: popupAnchor)
        } else if !inlineHoverControls, widget.hoverLayout != nil || (isSound && output?.values?["volume"] != nil) {
            store.popup.hover(inside, store: store, anchor: popupAnchor) {
                store.popup.showControls(widget: widget, defaults: popupDefaults.popupStyle(over: defaults), store: store,
                                         anchor: popupAnchor) { style in hoverControls(style) }
            }
        } else if widget.hoverLayout == nil, let tooltip, !tooltip.isEmpty {
            store.popup.hover(inside, store: store, anchor: popupAnchor) {
                store.popup.showTooltip(tooltip, widget: widget, defaults: popupDefaults.popupStyle(over: defaults),
                                        store: store, anchor: popupAnchor)
            }
        }
        if let command = inside ? widget.actions?.mouseEntered : widget.actions?.mouseExited {
            runAction(.command(command), sender: inside ? "mouse.entered" : "mouse.exited")
        }
    }

    /// How the widget's text, field and symbol blocks show changes.
    private var motion: BlockMotion {
        BlockMotion(transition: widget.transition ?? defaultTransition,
                    animation: store.widgetScripts.scripts[widget.id]?.output.animation ?? widget.animation ?? defaultAnimation)
    }

    var body: some View {
        let output = store.widgetScripts.scripts[widget.id]?.output
        let tooltip = store.widgetScripts.scripts[widget.id]?.error ?? widget.tooltip ?? output?.tooltip
        let resolution = self.resolution
        let isOpen = store.barPresentation.presentations[widget.id]?.popupAnchor == ObjectIdentifier(popupAnchor)
        let style = resolution.style(hovered: hovered || barFocus?.wrappedValue == widget.id, open: isOpen)
        let appearance = WidgetAppearance(style, defaults: WidgetStyle())
        let animation = output?.animation ?? widget.animation ?? defaultAnimation
        let leading = style.paddingLeading ?? appearance.paddingHorizontal
        let trailing = style.paddingTrailing ?? appearance.paddingHorizontal
        // The Apple logo's button takes the side padding too, so the whole tile takes its click.
        let isAppleLogo = if case .appleMenu = widget.content { widget.layout == nil } else { false }
        let padding = EdgeInsets(top: style.paddingTop ?? appearance.paddingVertical, leading: isAppleLogo ? leading : 0,
                                 bottom: style.paddingBottom ?? appearance.paddingVertical, trailing: isAppleLogo ? trailing : 0)
        // Workspace and menu buttons include vertical padding so their selection fills the tile.
        let hasCells = switch widget.content {
        case .workspaces, .appMenu, .appleMenu: widget.layout == nil
        case .menuBarItems: widget.drawsMenuBarItems
        default: false
        }
        let tile = Group {
            if let layout = widget.hoverLayout, inlineHoverControls {
                HoverLayoutView(widget: widget, layout: layout, store: store, monitor: monitor,
                                style: resolution.layoutStyle(configured: true, hovered: hovered, open: isOpen),
                                hovered: hovered, motion: motion, runAction: blockAction) {
                    content(resolution, open: isOpen, padding: padding)
                }
            } else {
                content(resolution, open: isOpen, padding: padding)
            }
        }
            .overlay(alignment: .topTrailing) {
                if widget.id == AppUpdate.widgetID {
                    Circle()
                        .fill(appearance.accent)
                        .frame(width: appearance.iconSize / 2, height: appearance.iconSize / 2)
                        .overlay { Circle().strokeBorder(appearance.background, lineWidth: 1.5) }
                        .offset(x: 2, y: -2)
                        .accessibilityHidden(true)
                }
            }
            .padding(.leading, isAppleLogo ? 0 : leading)
            .padding(.trailing, isAppleLogo ? 0 : trailing)
            .padding(.top, hasCells ? 0 : padding.top)
            .padding(.bottom, hasCells ? 0 : padding.bottom)
            .frame(width: appearance.width, height: style.height.map { CGFloat($0) })
            .frame(minWidth: style.minWidth.map { CGFloat($0) }, maxWidth: style.maxWidth.map { CGFloat($0) })
            .contentShape(Rectangle())
        clickable(tile, output: output, isOpen: isOpen)
        .font(appearance.font)
        .foregroundStyle(appearance.foreground)
        .styledSymbolVariant(style.symbolVariant)
        .modifier(GlassBackground(fill: style.background, glass: store.configuration?.bar(on: screenKind).glass ?? GlassSettings(), surface: \.widgets,
                                  shape: RoundedRectangle(cornerRadius: appearance.cornerRadius)))
        .overlay {
            if contrast == .increased && style.background != nil {
                // SwiftUI draws a RoundedRectangle's border as a layer border, which drawing offscreen, as the scenes do, gives
                // stray marks at the ends of a pill.
                let radius = appearance.cornerRadius
                UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: radius, bottomTrailingRadius: radius, topTrailingRadius: radius)
                    .strokeBorder(appearance.foreground, lineWidth: max(appearance.borderWidth, 1))
            } else {
                RoundedRectangle(cornerRadius: appearance.cornerRadius)
                    .strokeBorder(appearance.borderColor, lineWidth: appearance.borderWidth)
            }
        }
        .overlay(alignment: .topTrailing) {
            if let error = store.widgetScripts.scripts[widget.id]?.error ?? store.widgetScripts.actionErrors[widget.id] {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).font(.system(size: 8)).help(error)
            }
        }
        .shadow(color: appearance.shadowColor, radius: appearance.shadowRadius, y: 1)
        .overlay(alignment: .bottom) {
            if let overlay = widget.overlay {
                timed { date in
                    WidgetBlocks(widget: widget, store: store, style: resolution.layoutStyle(configured: true, hovered: hovered, open: isOpen),
                                 block: overlay, date: date, fillsWidth: true, motion: motion, runAction: blockAction)
                }
                .allowsHitTesting(false)
            }
        }
        .overlay {
            if store.barEditing.allowsWidgetActions, let actions = widget.actions {
                WidgetActionCapture(actions: actions, display: monitor) { command, context in
                    store.widgetScripts.runAction(command, widget: widget,
                                                  event: ScriptEvent(sender: context.sender, environment: context.environment))
                }
            }
        }
        .background {
            if !measuring && store.barEditing.allowsWidgetActions { PopupAnchor(view: popupAnchor, popup: store.popup, id: widget.id) }
        }
        .transformAnchorPreference(key: BarAnchorPreference.self, value: .bounds) { anchors, bounds in
            if !measuring { anchors.widgets[widget.id] = BarWidgetAnchor(bounds: bounds, unit: unitID) }
        }
        .offset(x: style.offsetX ?? 0, y: style.offsetY ?? 0)
        .opacity(style.opacity ?? 1)
        .onHover { hoverChanged($0, tooltip: tooltip, output: output) }
        .animation(hoverAnimation(hovered, reduceMotion: reduceMotion), value: hovered)
        .animation(reduceMotion ? nil : animation.value, value: style)
        .animation(reduceMotion ? nil : animation.value, value: widget.content == .activeApp ? store.appWatcher.activeApp : nil)
        .accessibilityHint(tooltip ?? "")
        .accessibilityIdentifier(widget.id)
        .contextMenu { WidgetContextMenu(widget: widget, store: store, display: monitor) }
        // The Sound details list the apps as soon as they open.
        .onAppear { if isSound, widget.details { AudioMixer.shared.start() } }
    }

    private func showMenuRow(appearance: WidgetAppearance, padding: EdgeInsets) {
        // The tile's own side padding, so the row's titles line up with the widget's.
        let style = resolution.style(hovered: true, open: false)
        let side = style.paddingLeading ?? WidgetAppearance(style, defaults: WidgetStyle()).paddingHorizontal
        store.popup.hover(true, store: store, anchor: popupAnchor) {
            store.popup.showRow(widget: widget, defaults: popupDefaults.popupStyle(over: defaults), store: store, anchor: popupAnchor,
                                sidePadding: side) {
                AppMenuRow(widget: widget, store: store, defaults: popupDefaults.popupStyle(over: defaults), appearance: appearance, padding: padding)
            }
        }
    }

    private func toggleMenuBarItems(leavingOut references: [MenuBarItemReference], anchor: NSView) {
        guard store.barEditing.allowsWidgetActions, !store.popup.toggleIfOpen(widget.id, anchor: anchor) else { return }
        Task {
            guard let popup = await store.appMenu.menuBarItemsPopup(leavingOut: references) else { return }
            store.popup.toggle(popup, widget: widget, defaults: popupDefaults.popupStyle(over: defaults), store: store, anchor: anchor)
        }
    }

    private func hoverMenuBarItems(_ inside: Bool, leavingOut references: [MenuBarItemReference], anchor: NSView) {
        store.popup.hover(inside, store: store, anchor: anchor) {
            guard let popup = await store.appMenu.menuBarItemsPopup(leavingOut: references, requestingAccess: false), !Task.isCancelled else { return }
            store.popup.open(popup, widget: widget, defaults: popupDefaults.popupStyle(over: defaults),
                             store: store, anchor: anchor, onHover: true)
        }
    }

    /// The menus that don't fit beside the notch, each opening its own menu.
    private func openAppMenus(_ items: [AppMenuItem], anchor: NSView) {
        guard store.barEditing.allowsWidgetActions, let popup = store.appMenu.overflowPopup(for: items) else { return }
        store.popup.toggle(popup, widget: widget, defaults: popupDefaults.popupStyle(over: defaults), store: store, anchor: moreWidgetsAnchor ?? anchor)
    }

    private func openAppMenu(_ item: AppMenuItem, anchor: NSView) {
        guard let popup = store.appMenu.popup(for: item) else { return }
        store.popup.toggle(popup, widget: widget, defaults: popupDefaults.popupStyle(over: defaults), store: store, anchor: moreWidgetsAnchor ?? anchor)
    }

    /// Runs the Apple logo's click. Without Accessibility access, a menu click asks for it; with access but no menu read
    /// yet, such as just after access was allowed, it reads the menus so the next click opens it.
    private func clickAppleLogo(_ click: AppleMenuClick, anchor: NSView) {
        guard store.barEditing.allowsWidgetActions else { return }
        switch click {
        case .menu:
            if !AXIsProcessTrusted() { store.windowClearance.requestAccess() }
            else if store.appMenu.isTrusted, let item = store.appMenu.appleMenu { openAppMenu(item, anchor: anchor) }
            else { store.appMenu.refresh() }
        case .systemSettings: OpenTarget("com.apple.systempreferences")!.open()
        case .lockScreen:
            let error = lockScreen()
            if store.widgetScripts.actionErrors[widget.id] != error { store.widgetScripts.actionErrors[widget.id] = error }
        }
    }

    private func runAction(_ action: BlockAction, sender: String, button: String? = nil) {
        let context = WidgetActionContext(sender: sender, button: button, modifiers: NSEvent.modifierFlags, display: monitor)
        store.widgetScripts.runAction(action, widget: widget, event: ScriptEvent(sender: sender, environment: context.environment))
    }

    @ViewBuilder
    private func content(_ resolution: ResolvedWidgetStyle, open: Bool, padding: EdgeInsets) -> some View {
        switch widget.content {
        case .workspaces where widget.layout == nil:
            WorkspaceView(workspaceStore: store.workspaceStore, monitor: monitor,
                          appearance: WidgetAppearance(resolution.style(hovered: false, open: open), defaults: WidgetStyle()),
                          padding: padding, configuration: widget.workspace, animation: widget.animation ?? defaultAnimation,
                          defaults: resolution.base,
                          modeAliases: store.configuration?.look(on: screenKind).modeAliases ?? [:], widgetID: widget.id,
                          allowsWindowDragging: store.barEditing.allowsWidgetActions) { inside, name, anchor in
                store.popup.hover(inside, store: store, anchor: anchor) {
                    store.popup.showTooltip(name, widget: widget, defaults: popupDefaults.popupStyle(over: defaults), store: store, anchor: anchor)
                }
            }
        case let .appMenu(expandOnHover, displayMode) where widget.layout == nil:
            let expands = expandOnHover && moreWidgetsAnchor == nil
            let appearance = WidgetAppearance(resolution.style(hovered: false, open: open), defaults: WidgetStyle())
            AppMenuView(appMenu: store.appMenu, items: store.appMenu.items, expandOnHover: expands, hovering: hovered,
                        expanded: barExpansion.map { $0 == .granted } ?? (store.barPresentation.presentations[widget.id]?.expandedDisplays.contains(monitor) == true),
                        displayMode: displayMode, appIcon: store.appMenu.menuOwnerIcon,
                        appearance: appearance, padding: padding,
                        openAnchor: store.barPresentation.presentations[widget.id]?.popupAnchor, open: openAppMenu,
                        requestAccess: store.windowClearance.requestAccess, expansionChanged: { expanded in
                if !measuring && expands {
                    store.barPresentation.presentations[widget.id]?.setExpanded(expanded, on: monitor, animation: reduceMotion ? nil : motion.animation)
                }
            }, openOverflow: openAppMenus)
            .onChange(of: barExpansion == .cramped && hovered) { _, cramped in
                if cramped { showMenuRow(appearance: appearance, padding: padding) }
            }
        case let .appleMenu(click) where widget.layout == nil:
            let appearance = WidgetAppearance(resolution.style(hovered: false, open: open), defaults: WidgetStyle())
            let logo = widget.icon.flatMap { $0.isEmpty ? nil : $0 } ?? "apple.logo"
            if hasOwnClick {
                Image(systemName: logo).accessibilityLabel("Apple")
                    .foregroundStyle(appearance.foreground)
                    .padding(padding)
            } else if click == .menu, store.appMenu.isTrusted, let appleMenu = store.appMenu.appleMenu {
                AppMenuView(appMenu: store.appMenu, items: [appleMenu], isAppleMenu: true, appleLogo: logo,
                            appearance: appearance, padding: padding, openAnchor: store.barPresentation.presentations[widget.id]?.popupAnchor,
                            open: openAppMenu, requestAccess: store.windowClearance.requestAccess)
            } else {
                AppleLogoButton(logo: logo, appearance: appearance, padding: padding, label: click.title,
                                help: click == .menu && !store.appMenu.isTrusted ? "Allow StableBar in Privacy & Security → \(macOSVersion.accessibilityName) to open the Apple menu. Click to open System Settings and drag StableBar into the list." : nil) {
                    clickAppleLogo(click, anchor: clickAnchor)
                } hover: {
                    if click == .menu { store.appMenu.refresh() }
                }
            }
        case .stableBar where widget.layout == nil:
            if let image = NSImage(named: "StatusBarIconTemplate") {
                let appearance = WidgetAppearance(resolution.style(hovered: hovered || barFocus?.wrappedValue == widget.id, open: open),
                                                  defaults: WidgetStyle())
                ZStack {
                    Text(" ").hidden()
                    Image(nsImage: image).resizable().scaledToFit().frame(height: appearance.iconSize)
                        .accessibilityLabel(accessibilityName)
                        .foregroundStyle(appearance.foreground)
                }
            }
        case let .menuBarItems(openOnHover, rightClickInMenuBar, _, hidden) where widget.drawsMenuBarItems:
            let leftOut = widget.shownMenuBarItems.references + hidden.references
            MenuBarItemsView(widget: widget, store: store, display: monitor, defaults: popupDefaults.popupStyle(over: defaults),
                             rightClickInMenuBar: rightClickInMenuBar,
                             appearance: WidgetAppearance(resolution.style(hovered: false, open: open), defaults: WidgetStyle()),
                             padding: padding, symbol: store.label(for: widget).icon!) { anchor in
                toggleMenuBarItems(leavingOut: leftOut, anchor: anchor)
            } hoverRow: { inside, anchor in
                if openOnHover { hoverMenuBarItems(inside, leavingOut: leftOut, anchor: anchor) }
            }
        case .provider where isSound && inlineHoverControls:
            SoundWidgetView(widget: widget, store: store, monitor: monitor,
                            style: resolution.layoutStyle(configured: false, hovered: hovered, open: open),
                            sliderStates: resolution.blockStates(open: open),
                            hovered: hovered, motion: motion, runAction: blockAction)
        case .spacer where widget.layout == nil:
            Spacer(minLength: resolution.base.minWidth ?? 0)
        default:
            if store.widgetScripts.scripts[widget.id]?.error != nil && !store.barEditing.hasContent(widget) {
                Image(systemName: store.label(for: widget).icon ?? "exclamationmark.triangle")
                    .font(.system(size: WidgetAppearance(resolution.style(hovered: false, open: open), defaults: WidgetStyle()).iconSize))
            } else {
                timed { date in blocks(resolution, open: open, date: date) }
            }
        }
    }

    /// `content` drawn for the time the widget shows: the render's fixed date when it has one, a clock's
    /// redrawn on its schedule, otherwise now.
    @ViewBuilder
    private func timed<Content: View>(@ViewBuilder _ content: @escaping (Date) -> Content) -> some View {
        if let fixedDate {
            content(fixedDate)
        } else if case let .clock(format) = widget.content {
            TimelineView(clockSchedule(format)) { context in content(context.date) }
        } else {
            content(.now)
        }
    }

    private func hoverControls(_ style: WidgetStyle) -> some View {
        HoverControls(widget: widget, store: store,
                      style: LayoutStyle(inherited: style, states: resolution.blockStates(open: false), tracksHover: true),
                      motion: motion, runAction: blockAction)
    }

    private func blocks(_ resolution: ResolvedWidgetStyle, open: Bool, date: Date) -> some View {
        WidgetBlocks(widget: widget, store: store,
                     style: resolution.layoutStyle(configured: widget.layout != nil, hovered: hovered, open: open),
                     date: date, motion: motion, runAction: blockAction)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityName)
            .accessibilityValue(accessibilityValue(date: date))
    }

    private func blockAction(_ action: BlockAction, _ environment: [String: String]) {
        if environment.isEmpty {
            runAction(action, sender: "mouse.clicked", button: "left")
        } else {
            store.widgetScripts.runAction(action, widget: widget,
                                          event: ScriptEvent(sender: "control.changed", environment: environment.merging(["SID": String(monitor)]) { first, _ in first }))
        }
    }
}

/// A widget's hover controls in their tooltip: its `hoverLayout`, or else Sound's volume slider.
struct HoverControls: View {
    let widget: WidgetConfiguration
    let store: BarStore
    /// The tooltip's style, with the widget's block states.
    let style: LayoutStyle
    var motion = BlockMotion()
    let runAction: (BlockAction, [String: String]) -> Void

    var body: some View {
        Group {
            if let layout = widget.hoverLayout {
                WidgetBlocks(widget: widget, store: store, style: style, block: layout, inline: false, motion: motion, runAction: runAction)
            } else {
                VolumeSlider(widget: widget, store: store, style: style, width: 120)
            }
        }
        .controlSize(.small)
        .labelsHidden()
    }
}

/// One of a widget's block trees drawn with its data: `block` when given, such as its overlay,
/// otherwise its `layout`, otherwise the default layout of its type.
struct WidgetBlocks: View {
    let widget: WidgetConfiguration
    let store: BarStore
    let style: LayoutStyle
    var block: PopupBlock?
    /// On the bar; otherwise in a hover tooltip under the widget.
    var inline = true
    var date = Date.now
    var fillsWidth = false
    var motion = BlockMotion()
    let runAction: (BlockAction, [String: String]) -> Void
    @Environment(\.screenKind) private var screenKind

    var body: some View {
        let script = store.widgetScripts.scripts[widget.id]
        let label = store.label(for: widget, date: date).overlaid(by: store.barPresentation.presentations[widget.id]?.temporaryFields)
        let appIcon = widget.content == .activeApp ? store.appWatcher.activeApp?.icon : nil
        let providerType = store.configuration?.providerType(of: widget)
        if let layout = block ?? widget.layout ?? widget.defaultLayout(label, output: script?.output, appIcon: appIcon != nil, providerType: providerType) {
            PopupBlockView(block: layout, inheritedStyle: style.inherited, fields: label.fields,
                           context: BlockContext(lists: script?.output.lists ?? [:], samples: script?.samples ?? [],
                                                 menu: script?.output.menu ?? widget.menu ?? [], values: script?.output.values ?? [:],
                                                 targets: script?.output.targets ?? [:], styles: script?.output.styles ?? [:],
                                                 series: script?.output.series ?? [:], roles: store.configuration?.look(on: screenKind).roles ?? [:],
                                                 inlineControlHeight: inline ? style.inherited.inlineControlHeight : nil,
                                                 tooltipLineHeight: inline ? nil : style.inherited.lineHeight,
                                                 fillsWidth: fillsWidth, open: { if store.barEditing.allowsWidgetActions { $0.open() } },
                                                 quit: { if store.barEditing.allowsWidgetActions { confirmQuit($0) } },
                                                 pressMenuBarItem: { if store.barEditing.allowsWidgetActions { store.appMenu.press($0) } },
                                                 selectInputSource: { if store.barEditing.allowsWidgetActions { store.widgetScripts.selectInputSource($0, widget: widget) } },
                                                 selectAudioDevice: { if store.barEditing.allowsWidgetActions { store.widgetScripts.selectAudioDevice($0, input: $1, widget: widget) } },
                                                 states: style.states, tracksHover: style.tracksHover, appIcon: appIcon, motion: motion,
                                                 runAction: runAction))
        }
    }
}

struct Sparkline: Shape {
    let samples: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for (index, value) in samples.enumerated() {
            let point = CGPoint(x: rect.width * Double(60 - samples.count + index) / 59,
                                y: rect.height * (1 - min(max(value, 0), 1)))
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}

private struct AppMenuRow: View {
    let widget: WidgetConfiguration
    let store: BarStore
    let defaults: WidgetStyle
    let appearance: WidgetAppearance
    let padding: EdgeInsets

    var body: some View {
        AppMenuView(appMenu: store.appMenu, items: store.appMenu.items,
                    displayMode: widget.appMenuDisplayMode, appIcon: store.appMenu.menuOwnerIcon,
                    appearance: appearance, padding: padding,
                    openAnchor: store.barPresentation.presentations[widget.id]?.innerPopupAnchor, open: { item, anchor in
            guard let popup = store.appMenu.popup(for: item) else { return }
            store.innerPopup.toggle(popup, widget: widget, defaults: defaults, store: store, anchor: anchor)
        }, requestAccess: store.windowClearance.requestAccess)
    }
}

/// The Apple logo as a button, drawn like the Apple menu's logo, for clicks that don't open the menu and until the menu is read.
private struct AppleLogoButton: View {
    let logo: String
    let appearance: WidgetAppearance
    let padding: EdgeInsets
    let label: String
    let help: String?
    let action: () -> Void
    let hover: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: logo).accessibilityLabel(label)
                .foregroundStyle(appearance.foreground)
                .padding(padding)
                .background {
                    if hovered { RoundedRectangle(cornerRadius: max(appearance.cornerRadius - 4, 0)).fill(appearance.hoverBackground) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help ?? "")
        .animation(hoverAnimation(hovered, reduceMotion: reduceMotion), value: hovered)
        .onHover { inside in
            hovered = inside
            if inside { hover() }
        }
    }
}
