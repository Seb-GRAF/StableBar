import SwiftUI

struct PopupView: View {
    let popup: PopupConfiguration
    let style: WidgetStyle
    let store: BarStore
    let widget: WidgetConfiguration
    var backgrounds: PopupBackgrounds?
    @Environment(\.screenKind) private var screenKind
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var mode: ModePresentation {
        let roles = store.configuration?.look(on: screenKind).roles ?? [:]
        guard style.usesModeStates || popup.layout.usesModeStates(roles: roles)
            || store.scripts[widget.id]?.output.styles?.values.contains(where: \.usesModeStates) == true else { return ModePresentation() }
        return store.modePresentation(on: screenKind)
    }

    var presentationStyle: WidgetStyle { style.resolved(for: StyleStates(mode: mode)) }

    var body: some View {
        let script = store.scripts[widget.id]
        let states = StyleStates(mode: mode)
        let appearance = WidgetAppearance(presentationStyle, defaults: WidgetStyle())
        let fields = script?.output.fields ?? [:]
        let lists = script?.output.lists ?? [:]
        let samples = script?.samples ?? []
        let menu = script?.output.menu ?? widget.menu ?? []
        let error = script?.error ?? store.actionErrors[widget.id]
        let fillsHeight = store.popup.pins.resized.contains(widget.id)
        let content = VStack(alignment: .leading, spacing: appearance.spacing) {
                PopupBlockView(block: popup.layout, inheritedStyle: style, fields: fields,
                               context: BlockContext(lists: lists, samples: samples, menu: menu,
                                                     values: script?.output.values ?? [:], targets: script?.output.targets ?? [:],
                                                     styles: script?.output.styles ?? [:], series: script?.output.series ?? [:],
                                                     roles: store.configuration?.look(on: screenKind).roles ?? [:], open: { target in
                    guard store.barEditing.allowsWidgetActions else { return }
                    if popup.dismissOnAction { store.popup.close() }
                    target.open()
                }, quit: { pid in
                    guard store.barEditing.allowsWidgetActions else { return }
                    if popup.dismissOnAction { store.popup.close() }
                    confirmQuit(pid)
                }, openSubmenu: { [screenKind] element, row in
                    store.appMenu.openSubmenu(element, beside: row) { submenu in
                        PopupView(popup: submenu, style: style, store: store, widget: widget).environment(\.screenKind, screenKind)
                    }
                }, pressMenuItem: { entry in
                    store.popup.close()
                    store.appMenu.press(entry)
                }, openMenuBarItem: { [screenKind] element, anchor in
                    guard let element else { return store.innerPopup.close() }
                    let look = store.configuration!.onScreen(screenKind)
                    store.innerPopup.toggle(store.appMenu.popup(forMenuBarItem: element), widget: widget,
                                            defaults: look.popupDefaults.inheriting(look.defaults), store: store, anchor: anchor)
                }, hoverMenuBarItem: { [screenKind] title, anchor, inside in
                    let look = store.configuration!.onScreen(screenKind)
                    store.innerPopup.hover(inside, store: store, anchor: anchor) {
                        store.innerPopup.showTooltip(title, widget: widget, defaults: look.popupDefaults.inheriting(look.defaults),
                                                     store: store, anchor: anchor)
                    }
                }, menuBarItemAnchor: store.presentations[widget.id]?.innerPopupAnchor, placeMenuBarItem: { item, placement in
                    store.popup.close()
                    store.move(.item(item), to: placement, before: nil, in: widget)
                }, states: states, update: store.update) { command, environment in
                    if environment.isEmpty ? popup.dismissOnAction : popup.dismissOnControl { store.popup.close() }
                    store.runAction(command, widget: widget,
                                    event: ScriptEvent(sender: environment.isEmpty ? "mouse.clicked" : "control.changed", environment: environment))
                })
                if let error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            .padding(.horizontal, appearance.paddingHorizontal)
            .padding(.vertical, appearance.paddingVertical)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: PopupHeightPreference.self, value: proxy.size.height)
                }
            }
            .environment(\.popupFillsHeight, fillsHeight)
            // With an animation of its own, a popup also animates what its data changes, as it animates its height.
            .animation(reduceMotion ? nil : popup.animation?.value, value: script?.outputNumber)
        Group {
            // A popup resized by hand gives its height to the fields that scroll instead of scrolling as a whole.
            if fillsHeight {
                content.frame(maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView { content }
            }
        }
        .overlay(alignment: .topTrailing) {
            if popup.pinnable {
                let pinned = store.popup.pins.ids.contains(widget.id)
                PinControls(pinned: pinned, foreground: appearance.foreground) {
                    if pinned { store.popup.unpin(widget.id) } else { store.popup.pin() }
                } close: {
                    store.popup.closePinned(widget.id)
                }
            }
        }
        .modifier(PopupBackground(style: presentationStyle, glass: store.configuration?.bar(on: screenKind).glass ?? GlassSettings(),
                                  backgrounds: backgrounds ?? store.popup.backgrounds))
        .accessibilityIdentifier("\(widget.id)-popup")
    }
}

struct PopupBackground: ViewModifier {
    let style: WidgetStyle
    let glass: GlassSettings
    let backgrounds: PopupBackgrounds

    func body(content: Content) -> some View {
        let appearance = WidgetAppearance(style, defaults: WidgetStyle())
        let hidden = backgrounds.hidden
        content
            .clipShape(RoundedRectangle(cornerRadius: appearance.cornerRadius))
            .modifier(GlassBackground(fill: hidden ? .color(HexColor(0)) : style.background, glass: glass, surface: \.popups,
                                      shape: RoundedRectangle(cornerRadius: appearance.cornerRadius)))
            .overlay {
                RoundedRectangle(cornerRadius: appearance.cornerRadius)
                    .strokeBorder(hidden ? .clear : appearance.borderColor, lineWidth: appearance.borderWidth)
            }
    }
}

struct PopupHeightPreference: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// What every block of one layout shares: the widget's data, the states it applies and the action
/// its controls run.
struct BlockContext {
    var lists: [String: [[String: String]]] = [:]
    var samples: [Double] = []
    var menu: [WidgetMenuItem] = []
    var values: [String: Double] = [:]
    var targets: [String: Double] = [:]
    var styles: [String: WidgetStyle] = [:]
    var series: [String: [Double]] = [:]
    var roles: [String: WidgetStyle] = [:]
    /// Popup layouts fill their width; bar layouts take their content's width.
    var fillsWidth = true
    /// Opens an `open` or `openField` block's target; a popup's also closes the popup when its actions dismiss it.
    let open: (OpenTarget) -> Void
    /// Asks to quit a `quitField` block's process; a popup's also closes the popup when its actions dismiss it.
    var quit: (pid_t) -> Void = { _ in }
    /// Opens the submenu of an app menu block's item beside the item's row, or without an item, closes the one open
    /// beside the block.
    var openSubmenu: (AXUIElement?, NSView) -> Void = { _, _ in }
    /// Presses an app menu block's item.
    var pressMenuItem: (AppMenuEntry) -> Void = { _ in }
    var openMenuBarItem: (AXUIElement?, NSView) -> Void = { _, _ in }
    var hoverMenuBarItem: (String, NSView, Bool) -> Void = { _, _, _ in }
    var menuBarItemAnchor: ObjectIdentifier?
    var placeMenuBarItem: (MenuBarItem, MenuBarItemPlacement) -> Void = { _, _ in }
    /// The widget's states, such as `open`; each block adds its own hover.
    var states = StyleStates()
    /// False when the inherited style already has the widget's hover and open states, as in default
    /// layouts, so blocks don't add their own hover.
    var tracksHover = true
    /// The frontmost app's icon, for an active-app widget's default layout.
    var appIcon: NSImage?
    /// The update on offer, for the update tile's popup.
    var update: AppUpdate?
    /// How text, field and symbol blocks without a transition of their own show changes.
    var motion = BlockMotion()
    let runAction: (String, [String: String]) -> Void
}

/// The transition and animation a widget gives its text, field and symbol blocks.
struct BlockMotion: Equatable, Sendable {
    var transition = WidgetTransition.none
    var animation = WidgetAnimation()

    /// The block's own transition, else this one; none while `still`, as with Reduce Motion or in
    /// the bar's measuring copy.
    func transition(for block: PopupBlock, still: Bool) -> WidgetTransition {
        still ? WidgetTransition.none : block.transition ?? transition
    }

    func animation(for block: PopupBlock) -> WidgetAnimation { block.animation ?? animation }
}

/// Shows a change of `value` in a text or symbol: `fade` cross-fades, `roll` pushes the new value
/// up from below, and `numeric` rolls the changed digits (symbols fade instead).
struct TransitioningContent<Value: Hashable>: ViewModifier {
    let value: Value
    let transition: WidgetTransition
    let animation: WidgetAnimation
    var numeric = true

    @ViewBuilder
    func body(content: Content) -> some View {
        switch transition {
        case .none:
            content
        case .fade:
            content.contentTransition(.opacity).animation(animation.value, value: value)
        case .numeric:
            content.contentTransition(numeric ? .numericText() : .opacity).animation(animation.value, value: value)
        case .roll:
            ZStack { content.id(value).transition(.push(from: .bottom)) }
                .clipped()
                .animation(animation.value, value: value)
        }
    }
}

/// Hands the content of a text, field or symbol block the transition and animation it shows: the
/// block's own, else the widget's, and no transition under Reduce Motion or in the bar's measuring
/// copy, which never moves.
struct ResolvedBlockMotion<Content: View>: View {
    let motion: BlockMotion
    let block: PopupBlock
    @ViewBuilder let content: (WidgetTransition, WidgetAnimation) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.measuringBarWidths) private var measuring

    var body: some View {
        content(motion.transition(for: block, still: reduceMotion || measuring), motion.animation(for: block))
    }
}

struct PopupBlockView: View {
    let block: PopupBlock
    let inheritedStyle: WidgetStyle
    let fields: [String: String]
    let context: BlockContext
    @State private var pointerInside: Bool
    @State private var query = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.popupFillsHeight) private var fillsHeight

    /// `pointerInside` starts the block with the pointer over it; tests use it, as drawing has no pointer.
    init(block: PopupBlock, inheritedStyle: WidgetStyle, fields: [String: String], context: BlockContext, pointerInside: Bool = false) {
        self.block = block
        self.inheritedStyle = inheritedStyle
        self.fields = fields
        self.context = context
        _pointerInside = State(initialValue: pointerInside)
    }

    /// Whether the block shows its hover: only where it tracks hover, not in a default layout.
    private var hovered: Bool { pointerInside && context.tracksHover }

    @ViewBuilder
    var body: some View {
        if let field = block.hideWhenEmpty, fields[field, default: ""].isEmpty {
            EmptyView()
        } else {
            styledContent
        }
    }

    private var handlesInteraction: Bool {
        switch block.content {
        case .button, .slider, .toggle, .segmented, .chooser, .search, .input: true
        default: false
        }
    }

    private var styledContent: some View {
        let resting = block.resolvedStyle(inherited: inheritedStyle, styles: context.styles, fields: fields, states: context.states, roles: context.roles)
        var hovering = context.states
        hovering.hover = true
        let current = hovered ? block.resolvedStyle(inherited: inheritedStyle, styles: context.styles, fields: fields, states: hovering, roles: context.roles) : resting
        let appearance = WidgetAppearance(resting.text, defaults: WidgetStyle())
        let box = current.box
        let alignment: Alignment = switch block.alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
        return Group {
            if handlesInteraction {
                boxed(content(resting, appearance: appearance), box: box, alignment: alignment)
            } else if let command = block.onClickField.flatMap({ fields[$0] }) ?? block.onClick {
                Button { context.runAction(command, [:]) } label: {
                    boxed(content(resting, appearance: appearance), box: box, alignment: alignment)
                }
                    .buttonStyle(.plain)
            } else if let value = block.openField.flatMap({ fields[$0] }) ?? block.open {
                Button { if let target = OpenTarget(value) { context.open(target) } } label: {
                    boxed(content(resting, appearance: appearance), box: box, alignment: alignment)
                }
                    .buttonStyle(.plain)
            } else if let pid = block.quitField.flatMap({ fields[$0] }).flatMap({ pid_t($0) }) {
                Button { context.quit(pid) } label: {
                    boxed(content(resting, appearance: appearance), box: box, alignment: alignment)
                }
                    .buttonStyle(.plain)
            } else if block.keepsLineHeight {
                boxed(ZStack {
                    Text(" ").hidden()
                    content(resting, appearance: appearance)
                }, box: box, alignment: alignment)
            } else {
                boxed(content(resting, appearance: appearance), box: box, alignment: alignment)
            }
        }
            .font(appearance.font)
            .foregroundStyle(current.text.foreground?.color ?? appearance.foreground)
            .tint(appearance.accent)
            .background(box.background?.shapeStyle ?? AnyShapeStyle(Color.clear), in: RoundedRectangle(cornerRadius: appearance.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: appearance.cornerRadius)
                    .strokeBorder(box.borderColor?.color ?? .clear, lineWidth: box.borderWidth ?? 0)
            }
            .offset(x: box.offsetX ?? 0, y: box.offsetY ?? 0)
            .opacity(box.opacity ?? 1)
            .onHover { pointerInside = $0 }
            .animation(reduceMotion ? nil : block.animation?.value, value: box)
            .animation(reduceMotion ? nil : block.animation?.value, value: hovered)
    }

    private func fieldText(_ text: String) -> Text {
        guard block.markdown else { return Text(text) }
        return Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
    }

    /// The block's content in the box its style gives it. A click anywhere in the box, including its
    /// padding and configured size, reaches the block's action, not only its glyph or text.
    private func boxed(_ content: some View, box: WidgetStyle, alignment: Alignment) -> some View {
        // A fixed width wins over the limits. Without either, a block in a popup fills the width.
        let minWidth: CGFloat? = box.width == nil ? box.minWidth.map { CGFloat($0) } : nil
        let maxWidth: CGFloat? = box.width == nil ? box.maxWidth.map { CGFloat($0) } ?? (context.fillsWidth ? .infinity : nil) : nil
        return content
            .padding(.leading, box.paddingLeading ?? box.paddingHorizontal ?? 0)
            .padding(.trailing, box.paddingTrailing ?? box.paddingHorizontal ?? 0)
            .padding(.top, box.paddingTop ?? box.paddingVertical ?? 0)
            .padding(.bottom, box.paddingBottom ?? box.paddingVertical ?? 0)
            .frame(width: box.width.map { CGFloat($0) }, height: box.height.map { CGFloat($0) }, alignment: alignment)
            .frame(minWidth: minWidth, maxWidth: maxWidth, alignment: alignment)
            .contentShape(Rectangle())
    }

    /// A child block, built as a concrete view so SwiftUI diffs it without type erasure.
    private func child(_ block: PopupBlock, of style: BlockStyle, fields: [String: String]) -> PopupBlockView {
        PopupBlockView(block: block, inheritedStyle: style.inherited, fields: fields, context: context)
    }

    @ViewBuilder
    private func content(_ style: BlockStyle, appearance: WidgetAppearance) -> some View {
        switch block.content {
        case let .row(children):
            HStack(spacing: appearance.spacing) {
                ForEach(Array(children.enumerated()), id: \.offset) { _, item in child(item, of: style, fields: fields) }
            }
        case let .column(children):
            VStack(alignment: .leading, spacing: appearance.spacing) {
                ForEach(Array(children.enumerated()), id: \.offset) { _, item in child(item, of: style, fields: fields) }
            }
        case let .text(text):
            ResolvedBlockMotion(motion: context.motion, block: block) { transition, animation in
                Group {
                    if let speed = block.scrollSpeed {
                        ScrollingText(text: text, font: appearance.font, fontSize: style.text.fontSize ?? 13, speed: speed)
                    } else {
                        Text(text)
                    }
                }
                .modifier(Shimmer(active: block.shimmer))
                .modifier(TransitioningContent(value: text, transition: transition, animation: animation))
            }
        case let .field(name):
            ResolvedBlockMotion(motion: context.motion, block: block) { transition, animation in
                Group {
                    if let speed = block.scrollSpeed {
                        ScrollingText(text: fields[name] ?? "", font: appearance.font, fontSize: style.text.fontSize ?? 13, speed: speed)
                    } else if let maxHeight = block.maxHeight {
                        ScrollView {
                            fieldText(fields[name] ?? "—").textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .modifier(FollowsGrowth())
                        .frame(maxHeight: fillsHeight ? .infinity : maxHeight)
                        .fixedSize(horizontal: false, vertical: !fillsHeight)
                    } else if block.wraps {
                        fieldText(fields[name] ?? "—").textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    } else if block.monospacedDigits {
                        fieldText(fields[name] ?? "—").lineLimit(1).monospacedDigit()
                    } else {
                        fieldText(fields[name] ?? "—").lineLimit(1)
                    }
                }
                .modifier(Shimmer(active: block.shimmer))
                .modifier(TransitioningContent(value: fields[name] ?? "", transition: transition, animation: animation))
            }
        case let .graph(height, source, lineWidth):
            Sparkline(samples: source.flatMap { context.series[$0] } ?? context.samples)
                .stroke(appearance.accent, lineWidth: lineWidth)
                .frame(height: height)
                .accessibilityLabel("History graph")
        case let .list(source, row):
            VStack(spacing: appearance.spacing) {
                ForEach(Array((context.lists[source] ?? []).enumerated()), id: \.offset) { _, fields in
                    child(row, of: style, fields: fields)
                }
            }
        case let .button(title, command):
            Button { context.runAction(command, [:]) } label: {
                Text(title).frame(maxWidth: .infinity).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        case let .slider(title, source, minimum, maximum, step, command):
            PopupSlider(title: title, value: context.values[source] ?? Double(fields[source] ?? "") ?? minimum,
                        minimum: minimum, maximum: maximum, step: step) { context.runAction(command, ["VALUE": String($0)]) }
        case let .toggle(title, source, command):
            PopupToggle(title: title, value: fields[source] == "true" || fields[source] == "1" || context.values[source] == 1) {
                context.runAction(command, ["VALUE": $0 ? "true" : "false"])
            }
        case let .segmented(title, source, options, command):
            PopupSegmented(title: title, value: fields[source] ?? options[0].value, options: options) {
                context.runAction(command, ["VALUE": $0])
            }
        case let .chooser(title, source, groupsSource, optionsSource, levelsSource, command):
            PopupChooser(title: title, chosen: fields[source] ?? "", groups: context.lists[groupsSource] ?? [],
                         options: context.lists[optionsSource] ?? [], levels: levelsSource.flatMap { context.lists[$0] } ?? []) {
                context.runAction(command, ["VALUE": $0, "OPTION": $1, "LEVEL": $2])
            }
        case let .search(title, source, searchFields, row):
            VStack(alignment: .leading, spacing: appearance.spacing) {
                TextField(title, text: $query).textFieldStyle(.roundedBorder).accessibilityLabel(title)
                ForEach(Array(searchPopupRows(context.lists[source] ?? [], query: query, fields: searchFields).enumerated()), id: \.offset) { _, fields in
                    child(row, of: style, fields: fields)
                }
            }
        case let .input(title, placeholder, autofocus, command):
            PopupInput(title: title, placeholder: placeholder, autofocus: autofocus) { context.runAction(command, ["VALUE": $0]) }
        case .menu:
            VStack(spacing: appearance.spacing) {
                ForEach(Array(context.menu.enumerated()), id: \.offset) { _, item in
                    PopupMenuRow(item: item, appearance: appearance) { context.runAction($0, [:]) }
                }
            }
        case .divider:
            Rectangle().fill(appearance.foreground.opacity(0.12)).frame(height: 1)
        case let .symbol(name, source):
            let symbol = source.flatMap { fields[$0] } ?? name
            ZStack {
                if let widest = block.widestSymbol { Image(systemName: widest).font(.system(size: appearance.iconSize)).hidden() }
                ResolvedBlockMotion(motion: context.motion, block: block) { transition, animation in
                    Image(systemName: symbol)
                        .font(.system(size: appearance.iconSize))
                        .modifier(TransitioningContent(value: symbol, transition: transition, animation: animation, numeric: false))
                }
            }
        case let .image(path, source, fit):
            WidgetImage(path: source.flatMap { fields[$0] } ?? path, fit: fit)
                .frame(width: style.box.width ?? 52, height: style.box.height ?? 52)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: appearance.cornerRadius))
        case let .progress(source, height):
            ProgressRule(value: context.values[source] ?? Double(fields[source] ?? "") ?? 0, target: context.targets[source],
                         animation: block.animation ?? WidgetAnimation(), color: appearance.accent,
                         track: style.text.background?.shapeStyle ?? AnyShapeStyle(Color.clear), cornerRadius: appearance.cornerRadius)
                .frame(height: height)
        case let .equalizer(source, height):
            Equalizer(playing: source.map { fields[$0] == "true" || fields[$0] == "1" || context.values[$0] == 1 } ?? true, height: height)
        case let .battery(source):
            BatteryGlyph(level: context.values[source] ?? Double(fields[source] ?? "") ?? 0, fields: fields, iconSize: appearance.iconSize)
        case .appIcon:
            if let icon = context.appIcon {
                Image(nsImage: icon).resizable().frame(width: appearance.iconSize, height: appearance.iconSize)
            }
        case .appUpdate:
            if let update = context.update, let version = update.version {
                UpdateDetails(update: update, version: version, appearance: appearance)
            }
        case let .appMenu(entries):
            AppMenuList(entries: entries, appearance: appearance, openSubmenu: context.openSubmenu, press: context.pressMenuItem)
        case let .menuBarItems(items):
            MenuBarItemsRow(items: items, appearance: appearance, openAnchor: context.menuBarItemAnchor, open: context.openMenuBarItem,
                            hover: context.hoverMenuBarItem, press: context.pressMenuItem, place: context.placeMenuBarItem)
        case let .essentials(kind, timeZone):
            EssentialsDetails(kind: kind, timeZone: timeZone, fields: fields, context: context, appearance: appearance)
        }
    }
}

struct ControlEditingPreference: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

private struct PopupSlider: View {
    let title: String
    let value: Double
    let minimum: Double
    let maximum: Double
    let step: Double
    let onChange: (Double) -> Void
    @State private var localValue: Double?
    @State private var editing = false

    var body: some View {
        Slider(value: Binding(get: { localValue ?? min(max(value, minimum), maximum) }, set: { localValue = $0 }),
               in: minimum...maximum, step: step) {
            Text(title)
        } onEditingChanged: { editing in
            self.editing = editing
            if !editing, let localValue { onChange(localValue) }
        }
        .accessibilityLabel(title)
        .onChange(of: value) { if !editing { localValue = nil } }
        .preference(key: ControlEditingPreference.self, value: editing)
    }
}

private struct PopupToggle: View {
    let title: String
    let value: Bool
    let onChange: (Bool) -> Void
    @State private var localValue: Bool?

    var body: some View {
        Toggle(title, isOn: Binding(get: { localValue ?? value }, set: {
            localValue = $0
            onChange($0)
        }))
        .onChange(of: value) { localValue = nil }
    }
}

private struct PopupInput: View {
    let title: String
    let placeholder: String?
    let autofocus: Bool
    let onSubmit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text, prompt: placeholder.map { Text($0) })
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel(title)
            .focused($focused)
            .onAppear { focused = autofocus }
            .onSubmit {
                onSubmit(text)
                text = ""
            }
    }
}

/// A pill naming the chosen group, option and level, that opens a panel to change them: groups on the left, and on the
/// right the chosen group's options and a bar of its levels. Choices show at once and run `onChange` with all three.
private struct PopupChooser: View {
    let title: String
    let chosen: String
    let groups: [[String: String]]
    let options: [[String: String]]
    let levels: [[String: String]]
    let onChange: (_ group: String, _ option: String, _ level: String) -> Void
    @State private var group: String?
    @State private var chosenOptions: [String: String] = [:]
    @State private var chosenLevels: [String: String] = [:]
    @State private var showsPanel = false
    @Namespace private var highlight

    private var current: String { group ?? chosen }
    private func row(_ group: String) -> [String: String] { groups.first { $0["value"] == group } ?? [:] }
    private func options(of group: String) -> [[String: String]] { options.filter { $0["group"] == group } }
    private func levels(of group: String) -> [[String: String]] { levels.filter { $0["group"] == group } }
    private func option(of group: String) -> String { chosenOptions[group] ?? row(group)["option"] ?? options(of: group).first?["value"] ?? "" }
    private func level(of group: String) -> String { chosenLevels[group] ?? row(group)["level"] ?? levels(of: group).first?["value"] ?? "" }
    private func title(_ value: String, in rows: [[String: String]]) -> String { rows.first { $0["value"] == value }?["title"] ?? value }

    private func choose(_ group: String) {
        self.group = group
        onChange(group, option(of: group), level(of: group))
    }

    var body: some View {
        Button { showsPanel.toggle() } label: {
            HStack(spacing: 6) {
                if let icon = row(current)["icon"] { Image(systemName: icon).contentTransition(.symbolEffect(.replace)) }
                (Text(row(current)["title"] ?? current).fontWeight(.semibold)
                    + Text("  ·  \(title(option(of: current), in: options(of: current)))"
                           + (levels(of: current).isEmpty ? "" : "  ·  \(title(level(of: current), in: levels(of: current)))"))
                    .foregroundStyle(.secondary))
                    .lineLimit(1)
                    .contentTransition(.interpolate)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(showsPanel ? 180 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .animation(.snappy(duration: 0.3), value: [current, option(of: current), level(of: current)])
        .animation(.snappy(duration: 0.25), value: showsPanel)
        // The label's width changes with the choice; the panel stays put under a fixed stretch of it.
        .overlay(alignment: .leading) {
            Color.clear.frame(width: 200).allowsHitTesting(false).popover(isPresented: $showsPanel, arrowEdge: .bottom) { panel }
        }
        .onChange(of: chosen) { group = nil }
        .onChange(of: groups) {
            chosenOptions = [:]
            chosenLevels = [:]
        }
    }

    private var panel: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, row in
                    let value = row["value"] ?? ""
                    ChooserRow(selected: value == current, highlight: highlight) {
                        HStack(spacing: 9) {
                            if let icon = row["icon"] { Image(systemName: icon).frame(width: 18) }
                            Text(row["title"] ?? value)
                            Spacer(minLength: 0)
                        }
                    } choose: {
                        choose(value)
                    }
                }
            }
            .padding(8)
            .frame(width: 168, alignment: .topLeading)
            Divider()
            details(current)
                .id(current)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 14)), removal: .opacity))
                .frame(width: 300, alignment: .topLeading)
        }
        // A fixed size keeps the panel still as groups with more or fewer options take turns in it.
        .frame(height: 420, alignment: .top)
        .animation(.snappy(duration: 0.32), value: current)
    }

    private func details(_ group: String) -> some View {
        let row = row(group)
        let levels = levels(of: group)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if let icon = row["icon"] {
                    Image(systemName: icon)
                        .font(.system(size: 15))
                        .frame(width: 32, height: 32)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(row["title"] ?? group).font(.headline)
                    if let detail = row["detail"] { Text(detail).font(.callout).foregroundStyle(.secondary) }
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(options(of: group).enumerated()), id: \.offset) { _, option in
                        let value = option["value"] ?? ""
                        let selected = value == self.option(of: group)
                        ChooserRow(selected: false, highlight: highlight) {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(option["title"] ?? value)
                                    if let detail = option["detail"] { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.tint)
                                    .scaleEffect(selected ? 1 : 0.4)
                                    .opacity(selected ? 1 : 0)
                            }
                        } choose: {
                            chosenOptions[group] = value
                            choose(group)
                        }
                        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: selected)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            if !levels.isEmpty {
                let level = self.level(of: group)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(row["levelsTitle"] ?? "Level").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(title(level, in: levels)).font(.caption.weight(.semibold)).foregroundStyle(.tint).contentTransition(.interpolate)
                    }
                    LevelBar(title: row["levelsTitle"] ?? "Level", levels: levels, chosen: level) {
                        chosenLevels[group] = $0
                        choose(group)
                    }
                }
                .animation(.snappy(duration: 0.25), value: level)
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// A row in the chooser's panel that highlights on hover, and when `selected`, with a highlight that slides between rows.
private struct ChooserRow<Label: View>: View {
    let selected: Bool
    let highlight: Namespace.ID
    @ViewBuilder let label: Label
    let choose: () -> Void
    @State private var hovered = false

    var body: some View {
        label
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary).matchedGeometryEffect(id: "selection", in: highlight)
                } else if hovered {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quinary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: choose)
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

/// Levels side by side in a bar that fills up to the chosen one. Click or drag along it to choose; the pointer previews
/// the level under it.
private struct LevelBar: View {
    let title: String
    let levels: [[String: String]]
    let chosen: String
    let choose: (String) -> Void
    @State private var dragged: Int?
    @State private var hovered: Int?

    var body: some View {
        let index = dragged ?? levels.firstIndex { $0["value"] == chosen } ?? 0
        GeometryReader { proxy in
            let segment = proxy.size.width / CGFloat(levels.count)
            let position = { (x: CGFloat) in min(max(Int(x / segment), 0), levels.count - 1) }
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.quaternary)
                if let hovered, hovered > index {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.tint.opacity(0.22)).frame(width: segment * CGFloat(hovered + 1))
                }
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.tint).frame(width: segment * CGFloat(index + 1))
                ForEach(1..<levels.count, id: \.self) { tick in
                    Capsule()
                        .fill(tick <= index ? Color.white.opacity(0.45) : Color.primary.opacity(0.18))
                        .frame(width: 2, height: 8)
                        .offset(x: segment * CGFloat(tick) - 1)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { dragged = position($0.location.x) }
                .onEnded {
                    choose(levels[position($0.location.x)]["value"] ?? "")
                    dragged = nil
                })
            .onContinuousHover { phase in
                if case let .active(point) = phase { hovered = position(point.x) } else { hovered = nil }
            }
        }
        .frame(height: 22)
        .animation(.spring(response: 0.32, dampingFraction: 0.68), value: index)
        .animation(.easeOut(duration: 0.15), value: hovered)
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityValue(levels[index]["title"] ?? "")
        .accessibilityAdjustableAction { direction in
            let next = direction == .increment ? min(index + 1, levels.count - 1) : max(index - 1, 0)
            choose(levels[next]["value"] ?? "")
        }
    }
}

/// A pinnable popup's pin button, and its close button while it's pinned.
private struct PinControls: View {
    let pinned: Bool
    let foreground: Color
    let togglePin: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            if pinned {
                CornerButton(symbol: "xmark", label: "Close", foreground: foreground, action: close)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
            CornerButton(symbol: pinned ? "pin.fill" : "pin", label: pinned ? "Unpin" : "Pin", foreground: foreground, action: togglePin)
                .symbolEffect(.bounce, value: pinned)
        }
        .padding(4)
        .animation(.snappy(duration: 0.3), value: pinned)
    }
}

private struct CornerButton: View {
    let symbol: String
    let label: String
    let foreground: Color
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .contentTransition(.symbolEffect(.replace))
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(foreground.opacity(hovered ? 0.12 : 0), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(foreground.opacity(hovered ? 0.9 : 0.55))
        .help(label)
        .accessibilityLabel(label)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

/// Keeps the newest lines of text that grows, such as an answer as it arrives, in view.
private struct FollowsGrowth: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) { content.defaultScrollAnchor(.bottom, for: .sizeChanges) } else { content }
    }
}

/// Light that sweeps across text again and again; still under Reduce Motion and in the bar's measuring copy.
struct Shimmer: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.measuringBarWidths) private var measuring

    func body(content: Content) -> some View {
        if active && !reduceMotion && !measuring {
            content.overlay {
                TimelineView(.animation) { timeline in
                    let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
                    GeometryReader { proxy in
                        LinearGradient(colors: [.clear, .white.opacity(0.85), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: proxy.size.width * 0.4)
                            .offset(x: proxy.size.width * (1.8 * phase - 0.4))
                    }
                }
                .mask(content)
                .allowsHitTesting(false)
            }
        } else {
            content
        }
    }
}

extension EnvironmentValues {
    /// Whether the popup was resized by hand, so fields that scroll take its height instead of their own `maxHeight`.
    @Entry var popupFillsHeight = false
}

private struct PopupSegmented: View {
    let title: String
    let value: String
    let options: [PopupControlOption]
    let onChange: (String) -> Void
    @State private var localValue: String?

    var body: some View {
        Picker(title, selection: Binding(get: { localValue ?? value }, set: {
            localValue = $0
            onChange($0)
        })) {
            ForEach(options, id: \.value) { option in Text(option.title).tag(option.value) }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel(title)
        .onChange(of: value) { localValue = nil }
    }
}

struct ProgressRule: View {
    let value: Double
    let target: Double?
    let animation: WidgetAnimation
    let color: Color
    let track: AnyShapeStyle
    let cornerRadius: Double
    @State private var fraction = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.measuringBarWidths) private var measuring

    var body: some View {
        let still = reduceMotion || measuring
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: cornerRadius).fill(track)
                RoundedRectangle(cornerRadius: cornerRadius).fill(color)
                    .frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
        }
        .task(id: ProgressUpdate(value: value, target: target, animation: animation, reduceMotion: still)) {
            if let target, !still {
                withAnimation(nil) { fraction = progressFraction(value) }
                await Task.yield()
                if !Task.isCancelled { withAnimation(animation.value) { fraction = progressFraction(target) } }
            } else {
                withAnimation(still ? nil : animation.value) { fraction = progressFraction(value) }
            }
        }
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int(progressFraction(value) * 100)) percent")
    }
}

func progressFraction(_ value: Double) -> Double {
    value.isFinite ? min(max(value, 0), 1) : 0
}

private struct ProgressUpdate: Equatable {
    let value: Double
    let target: Double?
    let animation: WidgetAnimation
    let reduceMotion: Bool
}

struct WidgetImage: View {
    let path: String
    let fit: ImageFit
    @State private var image: NSImage?
    @State private var error = ""

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: fit == .fill ? .fill : .fit)
            } else {
                Color.clear
            }
        }
        .help(error)
        .task(id: path) {
            image = nil
            error = ""
            if path.isEmpty { return }
            do {
                let url: URL
                if path.hasPrefix("https://") || path.hasPrefix("http://") || path.hasPrefix("file://") {
                    guard let source = URL(string: path) else { throw URLError(.badURL) }
                    url = source
                } else {
                    url = URL(filePath: NSString(string: path).expandingTildeInPath)
                }
                if url.isFileURL {
                    let file = try url.resourceValues(forKeys: [.isApplicationKey, .isExecutableKey, .isRegularFileKey, .contentTypeKey])
                    if file.isApplication == true || file.isExecutable == true && file.isRegularFile == true && file.contentType?.conforms(to: .image) != true {
                        image = NSWorkspace.shared.icon(forFile: url.path)
                        return
                    }
                }
                let data: Data
                if url.isFileURL {
                    data = try await Task.detached { try Data(contentsOf: url) }.value
                } else {
                    data = try await URLSession.shared.data(from: url).0
                }
                try Task.checkCancellation()
                image = NSImage(data: data)
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
}

struct AppMenuList: View {
    let entries: [AppMenuEntry]
    let appearance: WidgetAppearance
    let openSubmenu: (AXUIElement?, NSView) -> Void
    let press: (AppMenuEntry) -> Void
    @State private var submenu: Int?

    var body: some View {
        let checks = entries.contains(where: \.isChecked)
        VStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                if entry.title.isEmpty {
                    Rectangle().fill(appearance.foreground.opacity(0.12)).frame(height: 1).padding(.vertical, 4)
                } else {
                    AppMenuRow(entry: entry, checks: checks, appearance: appearance, open: submenu == index) { row in
                        guard submenu != index else { return }
                        let opens = entry.hasSubmenu && entry.isEnabled
                        submenu = opens ? index : nil
                        openSubmenu(opens ? entry.element : nil, row)
                    } press: {
                        press(entry)
                    }
                }
            }
        }
    }
}

private struct AppMenuRow: View {
    let entry: AppMenuEntry
    let checks: Bool
    let appearance: WidgetAppearance
    let open: Bool
    let rest: (NSView) -> Void
    let press: () -> Void
    @State private var hovered = false
    @State private var anchor = NSView()

    var body: some View {
        Button {
            if entry.hasSubmenu { rest(anchor) } else if entry.isEnabled { press() }
        } label: {
            HStack(spacing: 4) {
                if checks {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).frame(width: 14).opacity(entry.isChecked ? 1 : 0)
                }
                Text(entry.title).lineLimit(1)
                Spacer(minLength: 8)
                if entry.hasSubmenu { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background((hovered || open) && entry.isEnabled ? appearance.hoverBackground : AnyShapeStyle(Color.clear),
                        in: RoundedRectangle(cornerRadius: max(appearance.cornerRadius - 4, 0)))
            .background(MenuAnchor(view: anchor))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(entry.isEnabled ? 1 : 0.4)
        .onHover { hovered = $0 }
        .task(id: hovered) {
            guard hovered, (try? await Task.sleep(for: .milliseconds(200))) != nil else { return }
            rest(anchor)
        }
    }
}

struct MenuBarItemsRow: View {
    let items: [MenuBarItem]
    let appearance: WidgetAppearance
    let openAnchor: ObjectIdentifier?
    let open: (AXUIElement?, NSView) -> Void
    let hover: (String, NSView, Bool) -> Void
    let press: (AppMenuEntry) -> Void
    let place: (MenuBarItem, MenuBarItemPlacement) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                let entry = item.entry
                MenuBarItemButton(entry: entry, appearance: appearance, openAnchor: openAnchor) { anchor in
                    if entry.hasSubmenu { open(entry.element, anchor) } else { press(entry) }
                } hover: { anchor, inside in
                    if inside, openAnchor != nil, openAnchor != ObjectIdentifier(anchor) {
                        open(entry.hasSubmenu ? entry.element : nil, anchor)
                    }
                    hover(entry.title, anchor, inside)
                }
                .contextMenu {
                    MenuBarItemCommands(source: .item(item), shownCount: 0, isSymbol: false) { placement, _ in place(item, placement) }
                }
            }
        }
    }
}

private struct MenuBarItemButton: View {
    let entry: AppMenuEntry
    let appearance: WidgetAppearance
    let openAnchor: ObjectIdentifier?
    let click: (NSView) -> Void
    let hover: (NSView, Bool) -> Void
    @State private var hovered = false
    @State private var anchor = NSView()

    var body: some View {
        Button { click(anchor) } label: {
            Image(nsImage: entry.icon!).resizable().scaledToFit().frame(width: 18, height: 18)
                .padding(5)
                .background(hovered || openAnchor == ObjectIdentifier(anchor) ? appearance.hoverBackground : AnyShapeStyle(Color.clear),
                            in: RoundedRectangle(cornerRadius: max(appearance.cornerRadius - 4, 0)))
                .background(MenuAnchor(view: anchor))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(entry.title)
        .onHover { inside in
            hovered = inside
            hover(anchor, inside)
        }
    }
}

struct PopupMenuRow: View {
    let item: WidgetMenuItem
    let appearance: WidgetAppearance
    let runAction: (String) -> Void
    @State private var hovered = false

    var body: some View {
        Group {
            if let command = item.onClick {
                Button { runAction(command) } label: { label }
                    .buttonStyle(.plain)
            } else {
                label
            }
        }
        .background(hovered && item.onClick != nil ? appearance.hoverBackground : AnyShapeStyle(Color.clear),
                    in: RoundedRectangle(cornerRadius: appearance.cornerRadius))
        .onHover { hovered = $0 }
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title)
                .font(item.onClick == nil ? appearance.font.weight(.semibold) : appearance.font)
            if let detail = item.detail {
                Text(detail).foregroundStyle(appearance.foreground.opacity(0.7))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .contentShape(Rectangle())
    }
}
