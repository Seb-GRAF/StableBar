import SwiftUI

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
    /// The tallest a themed slider can be: in the bar, the widget's content area, and anywhere, the height of a block
    /// around it. Nil in popups and tooltips outside a block with a height.
    var inlineControlHeight: Double?
    /// In a hover tooltip, a line of its text: the tallest a themed slider can be there, whatever blocks hold it, since
    /// the role's height is meant for popups.
    var tooltipLineHeight: Double?
    var continuousSliders = false
    /// Popup layouts fill their width; bar layouts take their content's width.
    var fillsWidth = true
    /// Opens an `open` or `openField` block's target; a popup's also closes the popup when its actions dismiss it.
    let open: (OpenTarget) -> Void
    /// Shows the popup's view of this name in place of its layout.
    var openView: (String) -> Void = { _ in }
    /// Asks to quit a `quitField` block's process; a popup's also closes the popup when its actions dismiss it.
    var quit: (pid_t) -> Void = { _ in }
    /// Ejects a disk block's volume; unlike the other actions it leaves the popup open and reports a refusal.
    var eject: @MainActor (String, EjectScope) async throws -> Void = { _, _ in }
    /// The widget's accent in its `warning` and `critical` data states; a state its style doesn't set is missing.
    var stateAccents: [String: Color] = [:]
    /// The widget's data state, such as `warning`, for views that colour by it; popup blocks don't take its style.
    var dataState: String?
    var pressMenuBarItem: (MenuBarItemReference) -> Void = { _ in }
    /// Selects a `selectInputSourceField` block's keyboard input source.
    var selectInputSource: (String) -> Void = { _ in }
    /// Makes a `selectOutputDeviceField` block's audio device the default output, or with `true` a
    /// `selectInputDeviceField` block's the default input.
    var selectAudioDevice: (String, Bool) -> Void = { _, _ in }
    /// The latest output of another running provider, by its name, such as the microphone's for the Sound details.
    var providerOutput: (String) -> ScriptOutput? = { _ in nil }
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
    let runAction: (BlockAction, [String: String]) -> Void
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
    /// The popup's layout itself. As a column, it spaces its blocks `PopupConfiguration.blockSpacing` apart when nothing
    /// sets `spacing`; rows and lists keep 6 at every level.
    var topLevel = false
    /// Returns from a view whose title this block starts with, from a back arrow beside that title.
    var back: (() -> Void)?
    @State private var pointerInside: Bool
    @State private var query = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.popupFillsHeight) private var fillsHeight

    /// `pointerInside` starts the block with the pointer over it; tests use it, as drawing has no pointer.
    init(block: PopupBlock, inheritedStyle: WidgetStyle, fields: [String: String], context: BlockContext, pointerInside: Bool = false,
         topLevel: Bool = false, back: (() -> Void)? = nil) {
        self.block = block
        self.inheritedStyle = inheritedStyle
        self.fields = fields
        self.topLevel = topLevel
        self.back = back
        var context = context
        context.states = context.states.scoped(to: block)
        self.context = context
        _pointerInside = State(initialValue: pointerInside)
    }

    /// Whether the block shows its hover: only where it tracks hover, not in a default layout.
    private var hovered: Bool { pointerInside && context.tracksHover }

    @ViewBuilder
    var body: some View {
        if block.isHidden(fields: fields, values: context.values) {
            EmptyView()
        } else {
            styledContent
        }
    }

    private var handlesInteraction: Bool {
        switch block.content {
        case .button, .slider, .filledSlider, .toggle, .segmented, .chooser, .search, .input: true
        default: false
        }
    }

    private var styledContent: some View {
        let resting = resolvedStyle(states: context.states)
        var hovering = context.states
        hovering.hover = true
        let current = hovered ? resolvedStyle(states: hovering) : resting
        let stacksBlocks = if topLevel, case .column = block.content { true } else { false }
        var box = current.box
        var drawn = resting
        // A ring draws its hovered style too, and its background as its track, not behind its square.
        if case .ring = block.content {
            box.background = nil
            drawn = current
        }
        if block.automaticallyFillsSlider(roles: context.roles) { drawn = current }
        let appearance = WidgetAppearance(drawn.text, defaults: WidgetStyle(spacing: stacksBlocks ? PopupConfiguration.blockSpacing : nil))
        let alignment: Alignment = switch block.alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
        return Group {
            if handlesInteraction {
                boxed(content(drawn, appearance: appearance), box: box, alignment: alignment)
            } else if let command = block.onClickField.flatMap({ fields[$0] }) ?? block.onClick {
                Button { context.runAction(.command(command), [:]) } label: {
                    boxed(content(drawn, appearance: appearance), box: box, alignment: alignment)
                }
                    .buttonStyle(.plain)
                    .modifier(FocusRing(cornerRadius: appearance.cornerRadius))
            } else if let value = block.openField.flatMap({ fields[$0] }) ?? block.open {
                Button { if let target = OpenTarget(value) { context.open(target) } } label: {
                    boxed(content(drawn, appearance: appearance), box: box, alignment: alignment)
                }
                    .buttonStyle(.plain)
                    .modifier(FocusRing(cornerRadius: appearance.cornerRadius))
            } else if let pid = block.quitField.flatMap({ fields[$0] }).flatMap({ pid_t($0) }) {
                Button { context.quit(pid) } label: {
                    boxed(content(drawn, appearance: appearance), box: box, alignment: alignment)
                }
                    .buttonStyle(.plain)
                    .modifier(FocusRing(cornerRadius: appearance.cornerRadius))
            } else if let reference = block.openMenuBarItem {
                Button { context.pressMenuBarItem(reference) } label: {
                    boxed(content(drawn, appearance: appearance), box: box, alignment: alignment)
                }
                    .buttonStyle(.plain)
                    .modifier(FocusRing(cornerRadius: appearance.cornerRadius))
            } else if let id = block.selectInputSourceField.flatMap({ fields[$0] }) {
                Button { context.selectInputSource(id) } label: {
                    boxed(content(drawn, appearance: appearance), box: box, alignment: alignment)
                }
                    .buttonStyle(.plain)
                    .modifier(FocusRing(cornerRadius: appearance.cornerRadius))
            } else if let id = block.selectOutputDeviceField.flatMap({ fields[$0] }) {
                Button { context.selectAudioDevice(id, false) } label: {
                    boxed(content(drawn, appearance: appearance), box: box, alignment: alignment)
                }
                    .buttonStyle(.plain)
                    .modifier(FocusRing(cornerRadius: appearance.cornerRadius))
            } else if let id = block.selectInputDeviceField.flatMap({ fields[$0] }) {
                Button { context.selectAudioDevice(id, true) } label: {
                    boxed(content(drawn, appearance: appearance), box: box, alignment: alignment)
                }
                    .buttonStyle(.plain)
                    .modifier(FocusRing(cornerRadius: appearance.cornerRadius))
            } else if let command = block.nowPlayingCommand {
                Button { context.runAction(.nowPlaying(command), [:]) } label: {
                    boxed(content(drawn, appearance: appearance), box: box, alignment: alignment)
                }
                    .buttonStyle(.plain)
                    .modifier(FocusRing(cornerRadius: appearance.cornerRadius))
            } else if let view = block.view {
                Button { context.openView(view) } label: {
                    boxed(content(drawn, appearance: appearance), box: box, alignment: alignment)
                }
                    .buttonStyle(.plain)
                    .modifier(FocusRing(cornerRadius: appearance.cornerRadius))
            } else if block.keepsLineHeight {
                boxed(ZStack {
                    Text(" ").hidden()
                    content(drawn, appearance: appearance)
                }, box: box, alignment: alignment)
            } else {
                boxed(content(drawn, appearance: appearance), box: box, alignment: alignment)
            }
        }
            .font(appearance.font)
            .foregroundStyle(current.text.foreground?.color ?? appearance.foreground)
            .tint(appearance.accent)
            .styledSymbolVariant(current.text.symbolVariant)
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
            .frame(maxWidth: block.fitsWidth && context.fillsWidth ? .infinity : nil, alignment: alignment)
    }

    private func resolvedStyle(states: StyleStates) -> BlockStyle {
        let style = block.resolvedStyle(inherited: inheritedStyle, styles: context.styles, fields: fields, states: states, roles: context.roles)
        let limit = [context.inlineControlHeight, context.tooltipLineHeight].compactMap(\.self).min()
        return block.automaticallyFillsSlider(roles: context.roles) ? style.limitingSliderHeight(to: limit) : style
    }

    private func fieldText(_ text: String) -> Text {
        block.markdown ? MarkdownBlocks.inline(text) : Text(text)
    }

    /// A wrapping field's text, with Markdown's blocks when it shows Markdown.
    @ViewBuilder
    private func wrappingText(_ text: String) -> some View {
        if block.markdown {
            MarkdownBlocks(markdown: text)
        } else {
            Text(text)
        }
    }

    /// The block's content in the box its style gives it. A click anywhere in the box, including its
    /// padding and configured size, reaches the block's action, not only its glyph or text.
    @ViewBuilder
    private func boxed(_ content: some View, box: WidgetStyle, alignment: Alignment) -> some View {
        // A fixed width wins over the limits. Without either, a block in a popup fills the width.
        let minWidth: CGFloat? = box.width == nil ? box.minWidth.map { CGFloat($0) } : nil
        let maxWidth: CGFloat? = box.width == nil ? box.maxWidth.map { CGFloat($0) } ?? (context.fillsWidth ? .infinity : nil) : nil
        let padded = content
            .padding(.leading, box.paddingLeading ?? box.paddingHorizontal ?? 0)
            .padding(.trailing, box.paddingTrailing ?? box.paddingHorizontal ?? 0)
            .padding(.top, box.paddingTop ?? box.paddingVertical ?? 0)
            .padding(.bottom, box.paddingBottom ?? box.paddingVertical ?? 0)
            .frame(width: box.width.map { CGFloat($0) }, height: box.height.map { CGFloat($0) }, alignment: alignment)
        if block.fitsWidth {
            FitWidth(maximum: box.maxWidth.map { CGFloat($0) }) { padded }
                .contentShape(Rectangle())
        } else {
            padded
                .frame(minWidth: minWidth, maxWidth: maxWidth, alignment: alignment)
                .contentShape(Rectangle())
        }
    }

    /// A child block, built as a concrete view so SwiftUI diffs it without type erasure.
    private func child(_ block: PopupBlock, of style: BlockStyle, fields: [String: String]) -> PopupBlockView {
        var context = context
        if let limit = context.inlineControlHeight ?? style.box.height {
            // Negative padding lets a child overflow its box, but an inline control still stays within the widget.
            let inset = max(style.box.paddingTop ?? style.box.paddingVertical ?? 0, 0) + max(style.box.paddingBottom ?? style.box.paddingVertical ?? 0, 0)
            context.inlineControlHeight = max(min(limit, style.box.height ?? limit) - inset, 1)
        }
        return PopupBlockView(block: block, inheritedStyle: style.inherited, fields: fields, context: context)
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
                ForEach(Array(children.enumerated()), id: \.offset) { index, item in
                    if index == 0, let back, block.startsWithTitle(fields: fields, values: context.values) {
                        HStack(spacing: 4) {
                            CornerButton(symbol: "chevron.left", label: "Back", foreground: appearance.foreground, action: back)
                            child(item, of: style, fields: fields)
                        }
                    } else {
                        child(item, of: style, fields: fields)
                    }
                }
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
                            wrappingText(fields[name] ?? "—").textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .modifier(FollowsGrowth())
                        .frame(maxHeight: fillsHeight ? .infinity : maxHeight)
                        .fixedSize(horizontal: false, vertical: !fillsHeight)
                    } else if block.wraps {
                        wrappingText(fields[name] ?? "—").textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
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
        case let .list(source, row, orientation):
            if orientation == .horizontal {
                let entries = HStack(spacing: appearance.spacing) {
                    ForEach(Array((context.lists[source] ?? []).enumerated()), id: \.offset) { _, fields in
                        child(row, of: style, fields: fields)
                    }
                }
                if context.fillsWidth {
                    ScrollView(.horizontal) { entries }
                        .fixedSize(horizontal: false, vertical: !fillsHeight)
                } else {
                    entries
                }
            } else {
                let entries = VStack(spacing: appearance.spacing) {
                    ForEach(Array((context.lists[source] ?? []).enumerated()), id: \.offset) { _, fields in
                        child(row, of: style, fields: fields)
                    }
                }
                if let maxHeight = block.maxHeight {
                    ScrollView { entries }
                        .modifier(FollowsGrowth(entries: context.lists[source]?.count ?? 0))
                        .frame(maxHeight: fillsHeight ? .infinity : maxHeight)
                        .fixedSize(horizontal: false, vertical: !fillsHeight)
                } else {
                    entries
                }
            }
        case let .button(title, command):
            Button { context.runAction(.command(command), [:]) } label: {
                Text(title).frame(maxWidth: .infinity).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(FocusRing(cornerRadius: appearance.cornerRadius))
        case let .slider(title, source, minimum, maximum, step, endStop, action):
            let value = context.values[source] ?? Double(fields[source] ?? "") ?? minimum
            if block.automaticallyFillsSlider(roles: context.roles) {
                filledSlider(title: title, value: value, minimum: minimum, maximum: maximum, step: step,
                             endStop: endStop, icon: block.sliderIcon, action: action, style: style, appearance: appearance)
            } else if let endStop {
                EndStopSlider(title: title, value: value, minimum: minimum, maximum: maximum, step: step, endStop: endStop) {
                    context.runAction(action, ["VALUE": String($0)])
                }
            } else {
                PopupSlider(title: title, value: value, minimum: minimum, maximum: maximum, step: step) {
                    context.runAction(action, ["VALUE": String($0)])
                }
            }
        case let .filledSlider(title, source, minimum, maximum, step, endStop, icon, action):
            let value = context.values[source] ?? Double(fields[source] ?? "") ?? minimum
            filledSlider(title: title, value: value, minimum: minimum, maximum: maximum, step: step,
                         endStop: endStop, icon: icon, action: action, style: style, appearance: appearance)
        case let .toggle(title, source, action):
            PopupToggle(title: title, value: fields[source] == "true" || fields[source] == "1" || context.values[source] == 1) {
                context.runAction(action, ["VALUE": $0 ? "true" : "false"])
            }
        case let .segmented(title, source, options, command):
            PopupSegmented(title: title, value: fields[source] ?? options[0].value, options: options) {
                context.runAction(.command(command), ["VALUE": $0])
            }
        case let .chooser(title, source, groupsSource, optionsSource, levelsSource, stars, command):
            PopupChooser(title: title, chosen: fields[source] ?? "", groups: context.lists[groupsSource] ?? [],
                         options: context.lists[optionsSource] ?? [], levels: levelsSource.flatMap { context.lists[$0] } ?? [],
                         stars: stars.map { context.lists[$0.source] ?? [] }) {
                context.runAction(.command(command), ["VALUE": $0, "OPTION": $1, "LEVEL": $2])
            } onStar: {
                if let stars { context.runAction(.command(stars.command), ["VALUE": $0, "OPTION": $1, "LEVEL": $2, "STARRED": $3 ? "true" : "false"]) }
            }
        case let .search(title, source, searchFields, row):
            VStack(alignment: .leading, spacing: appearance.spacing) {
                TextField(title, text: $query).textFieldStyle(.roundedBorder).accessibilityLabel(title)
                    .modifier(FocusRing { FocusRingShape(shape: RoundedRectangle(cornerRadius: 10)) })
                ForEach(Array(searchPopupRows(context.lists[source] ?? [], query: query, fields: searchFields).enumerated()), id: \.offset) { _, fields in
                    child(row, of: style, fields: fields)
                }
            }
        case let .input(title, placeholder, autofocus, sendButton, stop, command):
            PopupInput(title: title, placeholder: placeholder, autofocus: autofocus, wraps: block.wraps, sendButton: sendButton,
                       busy: stop.map { !fields[$0.busy, default: ""].isEmpty } ?? false) {
                context.runAction(.command(command), ["VALUE": $0])
            } onStop: {
                if let stop { context.runAction(.command(stop.command), [:]) }
            }
            .modifier(FocusRing {
                if sendButton {
                    // The block's style draws the field's shape, so the ring goes around it.
                    let box = style.box
                    FocusRingShape(shape: RoundedRectangle(cornerRadius: appearance.cornerRadius + 4))
                        .padding(EdgeInsets(top: -(box.paddingTop ?? box.paddingVertical ?? 0),
                                            leading: -(box.paddingLeading ?? box.paddingHorizontal ?? 0),
                                            bottom: -(box.paddingBottom ?? box.paddingVertical ?? 0),
                                            trailing: -(box.paddingTrailing ?? box.paddingHorizontal ?? 0)))
                } else {
                    FocusRingShape(shape: RoundedRectangle(cornerRadius: 10))
                }
            })
        case .menu:
            VStack(spacing: appearance.spacing) {
                ForEach(Array(context.menu.enumerated()), id: \.offset) { _, item in
                    PopupMenuRow(item: item, appearance: appearance) { context.runAction(.command($0), [:]) }
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
        case let .image(path, source, fit, tinted):
            WidgetImage(path: source.flatMap { fields[$0] } ?? path, fit: fit, tinted: tinted)
                .frame(width: style.box.width ?? 52, height: style.box.height ?? 52)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: appearance.cornerRadius))
        case let .progress(source, height, segments?):
            ProgressSegments(value: context.values[source] ?? Double(fields[source] ?? "") ?? 0, count: segments, color: appearance.accent,
                             track: style.text.background?.shapeStyle ?? AnyShapeStyle(Color.clear), spacing: style.box.spacing ?? 2,
                             cornerRadius: appearance.cornerRadius)
                .frame(height: height)
        case let .progress(source, height, nil):
            ProgressRule(value: context.values[source] ?? Double(fields[source] ?? "") ?? 0, target: context.targets[source],
                         animation: block.animation ?? WidgetAnimation(), color: appearance.accent,
                         track: style.text.background?.shapeStyle ?? AnyShapeStyle(Color.clear), cornerRadius: appearance.cornerRadius)
                .frame(height: height)
        case let .ring(source, lineWidth, gap, children):
            ZStack {
                ProgressRing(value: context.values[source] ?? Double(fields[source] ?? "") ?? 0, animation: block.animation ?? WidgetAnimation(),
                             color: appearance.accent, track: style.text.background?.shapeStyle ?? AnyShapeStyle(Color.clear), lineWidth: lineWidth,
                             gap: gap)
                // Children take their content's width, as in the bar, so a popup centers them too.
                ForEach(Array(children.enumerated()), id: \.offset) { _, item in child(item, of: style, fields: fields).fixedSize() }
            }
            .frame(width: appearance.iconSize, height: appearance.iconSize)
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
            EssentialsDetails(kind: kind, timeZone: timeZone, style: inheritedStyle, fields: fields, context: context, appearance: appearance)
        }
    }
}

extension PopupBlockView {
    private func filledSlider(title: String, value: Double, minimum: Double, maximum: Double, step: Double,
                              endStop: SliderEndStop?, icon: String?, action: BlockAction, style: BlockStyle,
                              appearance: WidgetAppearance) -> some View {
        let inset = (style.box.paddingTop ?? style.box.paddingVertical ?? 0) + (style.box.paddingBottom ?? style.box.paddingVertical ?? 0)
        return FilledSlider(title: title, value: value, minimum: minimum, maximum: maximum, step: step, endStop: endStop, icon: icon,
                            height: max((style.box.height ?? 28) - inset, 1), drawsTrack: style.box.background == nil,
                            appearance: appearance, continuous: context.continuousSliders) {
            context.runAction(action, ["VALUE": String($0)])
        }
    }
}

/// Offers its content at most `maximum` points of width and takes the width the content uses, so text wraps at that
/// width yet a short line keeps its own width.
private struct FitWidth: Layout {
    let maximum: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews[0].sizeThatFits(offer(proposal))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }

    private func offer(_ proposal: ProposedViewSize) -> ProposedViewSize {
        guard let maximum else { return proposal }
        return ProposedViewSize(width: min(proposal.width ?? maximum, maximum), height: proposal.height)
    }
}

/// Keeps the newest lines of content that grows, such as an answer as it arrives, in view while it's scrolled to the end,
/// and brings a new entry of a list, such as a question just asked, into view.
private struct FollowsGrowth: ViewModifier {
    var entries = 0

    func body(content: Content) -> some View {
        if #available(macOS 15, *) { content.modifier(StaysAtEnd(entries: entries)) } else { content }
    }
}

@available(macOS 15, *)
private struct StaysAtEnd: ViewModifier {
    let entries: Int
    @State private var position = ScrollPosition()
    /// Whether growing content keeps the end in view: until the user scrolls away from it, and again once they scroll
    /// back to it or a new entry arrives.
    @State private var following = true

    func body(content: Content) -> some View {
        content
            // A popup can animate its data changes; growth that animates leaves the scroll short of the end it chases.
            .transaction { $0.animation = nil }
            .scrollPosition($position)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onScrollGeometryChange(for: ScrollEnd.self, of: ScrollEnd.init) { old, new in
                if new.height == old.height {
                    following = new.reached
                } else if following {
                    position.scrollTo(y: new.end)
                }
            }
            .onChange(of: entries) { old, new in
                guard new > old else { return }
                following = true
                position.scrollTo(edge: .bottom)
            }
    }
}

/// How tall a scroll view's content is, the offset that shows its end, and whether it's scrolled there, give or take a few
/// points.
@available(macOS 15, *)
private struct ScrollEnd: Equatable {
    let height: CGFloat
    let end: CGFloat
    let reached: Bool

    init(_ geometry: ScrollGeometry) {
        height = geometry.contentSize.height
        end = max(geometry.contentSize.height - geometry.containerSize.height, 0)
        reached = geometry.visibleRect.maxY >= geometry.contentSize.height - 8
    }
}

/// Light that sweeps across text again and again; still under Reduce Motion and in the bar's measuring copy.
struct Shimmer: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.measuringBarWidths) private var measuring
    @Environment(\.fixedDate) private var fixedDate

    func body(content: Content) -> some View {
        if active && !reduceMotion && !measuring {
            content.overlay {
                TimelineView(.animation) { timeline in
                    let phase = (fixedDate ?? timeline.date).timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
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
