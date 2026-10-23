import AppKit
import SwiftUI

extension WidgetConfiguration {
    /// Whether `transition` changes anything: workspaces and spacers draw their own views, which
    /// have no text or symbols to transition, unless they have a `layout` or `overlay`.
    var drawsTransitions: Bool {
        !content.drawsOwnView || layout != nil || hoverLayout != nil || overlay != nil
    }
}

extension WidgetContent {
    var drawsOwnView: Bool {
        switch self {
        case .workspaces, .appMenu, .appleMenu, .spacer: true
        default: false
        }
    }

    var symbol: String {
        switch self {
        case .spacer: "arrow.left.and.right"
        case let .provider(name): DataSourceRegistry.builtIn[name]?.symbol ?? "gauge.with.dots.needle.33percent"
        case .workspaces: "rectangle.3.group"
        case .activeApp: "macwindow"
        case .appMenu: "menubar.rectangle"
        case .appleMenu: "apple.logo"
        case .clock: "clock"
        case .text: "textformat"
        case .script: "terminal"
        }
    }
}

struct WidgetsView: View {
    @Bindable var editor: ConfigurationEditor
    @State private var setup: WidgetSetup
    @State private var dragSession = WidgetDragSession()
    @State private var adding: WidgetAddPopoverModel?
    @State private var addingAt: WidgetPosition?
    @State private var sharing: ScreenSetup?
    @State private var scrollPositions: [String: String] = [:]

    init(editor: ConfigurationEditor) {
        self.editor = editor
        _setup = State(initialValue: WidgetSetup(store: editor.store))
    }

    private var store: BarStore { editor.store }
    private var widgets: [WidgetConfiguration] { store.configuration?.onScreen(screen).widgets ?? [] }
    private var kinds: [ScreenKind] { ScreenKind.allCases.filter { store.screenSetup?.kinds.contains($0) == true } }
    private var screen: ScreenKind { kinds.contains(editor.barScreen) ? editor.barScreen : kinds.first ?? editor.barScreen }
    private var selectedWidget: String? { editor.barItem == .widget ? editor.selectedID : nil }

    var body: some View {
        let names = WidgetDisplayName.names(for: widgets, packageNames: store.widgetPackageNames, providers: store.configuration?.providers ?? [:])
        VStack(spacing: 0) {
            ScreenBand(editor: editor, kinds: kinds, screen: screen) { sharing = $0 }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 8)
            BarPreview(store: store, kind: screen, names: names, selected: selectedWidget, select: { id in
                if let id { select(id) } else { select(.bar) }
            }, session: dragSession, move: { move($0, to: $1, before: $2) })
            .padding(.horizontal, 16)
            HStack(spacing: 0) {
                list(names)
                    .frame(width: 230)
                    .background(SettingsPalette.sidebar)
                Divider()
                BarInspector(editor: editor, screen: screen, kinds: kinds, names: names, source: source, useSharedBar: { sharing = $0 },
                             remove: remove, scrollPositions: $scrollPositions)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay(alignment: .top) { Divider() }
            .padding(.top, 10)
        }
        .task { await setup.load() }
        .onChange(of: editor.searchTarget, initial: true) { showSearchTarget() }
        .confirmationDialog("Use the shared bar for \(sharing?.title.lowercased() ?? "")?", isPresented: Binding(
            get: { sharing != nil }, set: { if !$0 { sharing = nil } }), presenting: sharing) { setup in
            Button("Use Shared Bar") {
                do { try store.useSharedBar(for: setup) }
                catch { editor.error = errorMessage(error) }
            }
        } message: { _ in
            Text("Its own bar moves to the Trash.")
        }
    }


    private func list(_ names: [String: String]) -> some View {
        let displays = NSScreen.screens.map(BarDisplay.init)
        let shown = widgets.filter { $0.enabled && screen.shows($0.display, among: displays, activeID: store.activeDisplayID) }
        let hidden = widgets.filter { widget in !shown.contains { $0.id == widget.id } }
        let positions = WidgetPlacement.positions(widgets: widgets, hasNotchedDisplay: NSScreen.screens.contains { $0.auxiliaryTopLeftArea != nil })
        let changed = profileWidgets
        return VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ListRow(selected: editor.barItem == .bar) { _ in
                            WidgetRowLabel(symbol: "menubar.rectangle", name: "Bar", subtitle: "Size, background, placement", selected: editor.barItem == .bar)
                        }
                        .onTapGesture { select(.bar) }
                        .accessibilityAddTraits(.isButton)
                        ListRow(selected: editor.barItem == .everyWidget) { _ in
                            WidgetRowLabel(text: "Aa", name: "Every widget", subtitle: "The shared look", selected: editor.barItem == .everyWidget)
                        }
                        .onTapGesture { select(.everyWidget) }
                        .accessibilityAddTraits(.isButton)
                        ForEach(positions, id: \.self) { position in
                            let section = shown.filter { $0.position == position }
                            HStack(alignment: .bottom, spacing: 0) {
                                groupTitle(position.title)
                                Spacer(minLength: 0)
                                Button { openAdd(at: position) } label: {
                                    Image(systemName: "plus").font(.system(size: 11, weight: .medium)).frame(width: 20, height: 20).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help("Add a widget to \(position.title)")
                                .accessibilityLabel("Add a widget to \(position.title)")
                                .popover(isPresented: addPopover(shown: addingAt == position), arrowEdge: .trailing) { addPopoverContent }
                            }
                            ForEach(section) { widget in
                                widgetRow(widget, name: names[widget.id] ?? widget.id, position: position, listed: shown, changed: changed.contains(widget.id))
                            }
                            WidgetDragRow(session: dragSession, widgetID: nil, name: "", insertionKey: dropKey(position),
                                          select: { if section.isEmpty { openAdd(at: position) } }, move: { move($0, to: position) }) {
                                Text(section.isEmpty ? "Add or drop widgets here" : "")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 8)
                                    .frame(maxWidth: .infinity, minHeight: section.isEmpty ? 26 : 6, alignment: .leading)
                                    .overlay {
                                        if section.isEmpty {
                                            RoundedRectangle(cornerRadius: 7).strokeBorder(SettingsPalette.groupBorder, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                        }
                                    }
                                    .padding(.vertical, section.isEmpty ? 2 : 0)
                            }
                            .overlay(alignment: .top) { insertionLine(dropKey(position)) }
                            .accessibilityHidden(!section.isEmpty)
                        }
                        if !hidden.isEmpty {
                            groupTitle("Not on this screen · \(hidden.count)")
                            ForEach(hidden) { widget in
                                let selected = selectedWidget == widget.id
                                ListRow(selected: selected, dimmed: true,
                                        eye: ("eye.slash", "Show on this screen", { editor.setWidget(widget, shown: true, on: screen) })) { _ in
                                    WidgetRowLabel(symbol: widget.content.symbol, name: names[widget.id] ?? widget.id, subtitle: store.screensTitle(for: widget),
                                                   selected: selected, dimmed: true, changed: changed.contains(widget.id))
                                }
                                .onTapGesture { select(widget.id) }
                                .contextMenu { screensAndRemove(widget) }
                                .accessibilityElement(children: .combine)
                                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                    .padding(.bottom, 10)
                }
                .onChange(of: selectedWidget, initial: true) {
                    if let selectedWidget { proxy.scrollTo(selectedWidget) }
                }
            }
            Divider()
            HStack {
                Button { openAdd() } label: { Label("Add widget", systemImage: "plus") }
                    .popover(isPresented: addPopover(shown: addingAt == nil), arrowEdge: .top) { addPopoverContent }
                Spacer()
                let removing = widgets.first { $0.id == selectedWidget }
                Button { if let removing { remove(removing.id) } } label: { Label("Remove", systemImage: "minus") }
                    .disabled(removing.map { !editor.canRemove($0) } ?? true)
                    .help(removing.map(removeHelp) ?? "Select a widget to remove it")
            }
            .padding(8)
            .background {
                Button("Move up") { if let selectedWidget { moveBy(-1, id: selectedWidget, listed: shown) } }
                    .keyboardShortcut(.upArrow, modifiers: [.option, .command])
                    .hidden()
                Button("Move down") { if let selectedWidget { moveBy(1, id: selectedWidget, listed: shown) } }
                    .keyboardShortcut(.downArrow, modifiers: [.option, .command])
                    .hidden()
            }
        }
    }

    private func groupTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 6)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    private func widgetRow(_ widget: WidgetConfiguration, name: String, position: WidgetPosition, listed: [WidgetConfiguration], changed: Bool) -> some View {
        let selected = selectedWidget == widget.id
        let subtitle = store.screensTitle(for: widget)
        return ListRow(selected: selected, eye: ("eye", "Hide on this screen", { editor.setWidget(widget, shown: false, on: screen) })) { hovering in
            WidgetDragRow(session: dragSession, widgetID: widget.id, name: name, insertionKey: dropKey(position, before: widget.id),
                          select: { select(widget.id) }, move: { move($0, to: position, before: widget.id) }) {
                WidgetRowLabel(symbol: widget.content.symbol, name: name, subtitle: subtitle, selected: selected,
                               showsGrip: hovering, changed: changed)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(name)
            .accessibilityValue(subtitle)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { select(widget.id) }
            .accessibilityAction(named: Text("Move up")) { moveBy(-1, id: widget.id, listed: listed) }
            .accessibilityAction(named: Text("Move down")) { moveBy(1, id: widget.id, listed: listed) }
        }
        .overlay(alignment: .top) { insertionLine(position.rawValue + "/" + widget.id) }
        .contextMenu {
            Button("Move up") { moveBy(-1, id: widget.id, listed: listed) }
            Button("Move down") { moveBy(1, id: widget.id, listed: listed) }
            Menu("Move to") {
                ForEach(WidgetPlacement.destinations, id: \.self) { target in
                    Button(target.title) { move(widget.id, to: target) }
                }
            }
            Divider()
            screensAndRemove(widget)
        }
    }

    private func insertionLine(_ key: String) -> some View {
        Rectangle().fill(Color.accentColor).frame(height: 2).opacity(dragSession.insertion == key ? 1 : 0).allowsHitTesting(false)
    }

    @ViewBuilder private func screensAndRemove(_ widget: WidgetConfiguration) -> some View {
        Menu("Shows on") {
            WidgetScreensMenu(store: store, widget: widget, screen: screen) { editor.set($0, for: widget.id) }
        }
        Divider()
        Button("Remove from bar", role: .destructive) { remove(widget.id) }
            .disabled(!editor.canRemove(widget))
    }

    private func removeHelp(_ widget: WidgetConfiguration) -> String {
        guard !editor.canRemove(widget), let origin = store.origins["widgets.\(widget.id).id"] else { return "Remove the selected widget from this bar" }
        return "Defined in \(store.sourceText(origin)). Remove it there, or choose Hidden everywhere."
    }

    private var addPopoverContent: some View {
        adding.map { WidgetAddPopoverView(model: $0, store: store, showsTitle: false) }
    }

    private func addPopover(shown: Bool) -> Binding<Bool> {
        Binding(get: { adding != nil && shown }, set: { if !$0 { adding?.cancel(); adding = nil } })
    }

    private var profileWidgets: Set<String> {
        guard let name = editor.editingProfile, let profile = store.profiles.first(where: { $0.name == name }),
              case let .object(overrides)? = profile.configuration["widgetOverrides"] else { return [] }
        return Set(overrides.keys)
    }

    private func source(_ widget: WidgetConfiguration) -> PackageOrigin {
        if store.builtInWidgetIDs.contains(widget.id) { return .builtIn }
        guard let id = store.widgetPackageIDs[widget.id] else { return .builtIn }
        return setup.choices.contains { $0.package?.id == id && $0.package?.sourceID == PackageSource.storeID } ? .listed : .installed
    }


    private func select(_ item: BarItem) {
        editor.finishEditing()
        editor.barItem = item
    }

    private func select(_ id: String) {
        editor.showWidget(id)
    }

    private func openAdd(at group: WidgetPosition? = nil) {
        let position = group ?? WidgetPlacement.destination(selectedID: selectedWidget, widgets: widgets)
        addingAt = group
        let existingIDs = Set(widgets.map(\.id))
        adding = WidgetAddPopoverModel(setup: setup, position: position, before: nil, kinds: kinds) { id in
            for widget in widgets where !existingIDs.contains(widget.id) {
                editor.set(["display": adding!.display], for: widget.id)
            }
            select(id)
            adding = nil
        }
    }

    private func remove(_ id: String) {
        editor.finishEditing()
        do { try setup.remove(id) }
        catch { editor.error = errorMessage(error) }
    }

    private func move(_ id: String, to position: WidgetPosition, before anchor: String? = nil) {
        do { try setup.move(id, to: position, before: anchor, on: screen) }
        catch { editor.error = errorMessage(error) }
    }

    private func moveBy(_ offset: Int, id: String, listed: [WidgetConfiguration]) {
        do { try setup.move(id, by: offset, on: screen) { widget in listed.contains { $0.id == widget.id } } }
        catch { editor.error = errorMessage(error) }
    }

    private func dropKey(_ position: WidgetPosition, before anchor: String? = nil) -> String {
        let target = widgets.first { $0.id == anchor }
        let first = target.flatMap { target in
            widgets.first { $0.id == target.id || (target.group != nil && $0.group == target.group) }?.id
        }
        return position.rawValue + "/" + (first ?? "")
    }

    private func showSearchTarget() {
        guard let target = editor.searchTarget.flatMap(SettingsSearchResult.init(rawValue:)) else { return }
        var scroll = "top"
        switch target {
        case .barSize: editor.barTab = .size; select(.bar)
        case .barLook: editor.barTab = .look; select(.bar)
        case .barPlacement: editor.barTab = .placement; select(.bar)
        case .screenSetups:
            editor.barTab = .placement
            select(.bar)
            scroll = "These screens"
        case .everyWidget: select(.everyWidget)
        case .widgetContent, .widgetStyle, .widgetBehavior:
            editor.widgetTab = target == .widgetContent ? .content : target == .widgetStyle ? .style : .behavior
            if let id = editor.selectedID ?? widgets.first?.id { select(id) }
        case .addWidget: openAdd()
        default: return
        }
        switch editor.barItem {
        case .bar: scrollPositions["bar/\(editor.barTab)"] = scroll
        case .everyWidget: scrollPositions["everyWidget"] = scroll
        case .widget:
            if let id = editor.selectedID { scrollPositions["widget/\(id)/\(editor.widgetTab)"] = scroll }
        }
        editor.searchTarget = nil
    }
}

private struct ListRow<Content: View>: View {
    let selected: Bool
    var dimmed = false
    var eye: (symbol: String, help: String, action: () -> Void)?
    @ViewBuilder let content: (Bool) -> Content
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            content(hovering)
            if let eye {
                Button(action: eye.action) {
                    Image(systemName: eye.symbol)
                        .font(.system(size: 13))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selected ? .white : .primary)
                .opacity(hovering || dimmed ? 0.8 : 0)
                .help(eye.help)
                .accessibilityLabel(eye.help)
            }
        }
        .padding(.trailing, 6)
        .background(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(hovering ? SettingsPalette.control : .clear),
                    in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: selected)
    }
}

private struct WidgetRowLabel: View {
    var symbol: String?
    var text: String?
    let name: String
    let subtitle: String
    let selected: Bool
    var dimmed = false
    var showsGrip = false
    var changed = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.7)) : AnyShapeStyle(.tertiary))
                .frame(width: 8)
                .opacity(showsGrip ? 1 : 0)
            Group {
                if let symbol { Image(systemName: symbol).font(.system(size: 12)) } else { Text(text ?? "").font(.system(size: 11.5, weight: .semibold)) }
            }
            .frame(width: 24, height: 24)
            .background(selected ? AnyShapeStyle(.white.opacity(0.2)) : AnyShapeStyle(SettingsPalette.control), in: RoundedRectangle(cornerRadius: 6))
            .opacity(dimmed ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 0) {
                Text(name).fontWeight(.medium).lineLimit(1).opacity(dimmed ? 0.5 : 1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.88)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if changed {
                Circle().fill(SettingsPalette.profile).frame(width: 6, height: 6).help("Changed by this profile")
            }
        }
        .foregroundStyle(selected ? .white : .primary)
        .padding(.leading, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        .contentShape(Rectangle())
    }
}
