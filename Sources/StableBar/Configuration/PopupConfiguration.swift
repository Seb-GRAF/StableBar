import Foundation

struct PopupConfiguration: Decodable, Sendable {
    let height: Double?
    let style: WidgetStyle
    let layout: PopupBlock
    /// Layouts a block's `view` shows in place of `layout`, by name.
    var views: [String: PopupBlock] = [:]
    var alignment: PopupAlignment = .center
    /// The gap below the bar; `bar.popupOffset` when nil.
    var offset: Double?
    var openOnHover = false
    var dismissOnAction = true
    var dismissOnControl = false
    var pinnable = false
    var animation: WidgetAnimation?
    var onOpen: String?
    var onClose: String?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case height, style, layout, views, alignment, offset, openOnHover, dismissOnAction, dismissOnControl, pinnable, animation, onOpen, onClose
    }

    init(height: Double? = nil, style: WidgetStyle, layout: PopupBlock) {
        self.height = height
        self.style = style
        self.layout = layout
    }

    /// The padding of a popup that neither it nor `popupDefaults` sets.
    static let defaultPadding = WidgetStyle(paddingHorizontal: 16, paddingVertical: 16)
    /// The gap between the blocks of a popup's top-level column when nothing sets `spacing`. Everything else keeps 6.
    static let blockSpacing = 12.0

    /// `defaults` is `popupDefaults.popupStyle(over: defaults)`. A widget's explicit style reaches its popup, except its
    /// padding and spacing, which are the bar widget's; its bar role deliberately does not.
    func baseStyle(widget: WidgetConfiguration, defaults: WidgetStyle) -> WidgetStyle {
        resolveStyle([Self.defaultPadding, defaults, widget.style.withoutSpacing, style, WidgetStyle(background: widget.popupBackground)])
    }

    /// The gap below what the popup opens from: the bar, or with `inPopup` a row of another popup.
    func gap(below bar: BarSettings, inPopup: Bool = false) -> Double {
        offset ?? bar.popupGap(inPopup: inPopup)
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        height = try values.decodeIfPresent(Double.self, forKey: .height)
        style = try values.decode(WidgetStyle.self, forKey: .style)
        layout = try values.decode(PopupBlock.self, forKey: .layout)
        views = try values.decodeIfPresent([String: PopupBlock].self, forKey: .views) ?? views
        if let name = ([layout] + views.values).flatMap(\.openedViews).first(where: { views[$0] == nil }) {
            throw DecodingError.dataCorruptedError(forKey: .views, in: values, debugDescription: "Unknown view: \(name).")
        }
        alignment = try values.decodeIfPresent(PopupAlignment.self, forKey: .alignment) ?? alignment
        offset = try values.decodeIfPresent(Double.self, forKey: .offset)
        openOnHover = try values.decodeIfPresent(Bool.self, forKey: .openOnHover) ?? openOnHover
        dismissOnAction = try values.decodeIfPresent(Bool.self, forKey: .dismissOnAction) ?? dismissOnAction
        dismissOnControl = try values.decodeIfPresent(Bool.self, forKey: .dismissOnControl) ?? dismissOnControl
        pinnable = try values.decodeIfPresent(Bool.self, forKey: .pinnable) ?? pinnable
        animation = try values.decodeIfPresent(WidgetAnimation.self, forKey: .animation)
        onOpen = try values.decodeIfPresent(String.self, forKey: .onOpen)
        onClose = try values.decodeIfPresent(String.self, forKey: .onClose)
    }
}

extension WidgetStyle {
    /// This style without its padding, in its states too.
    var withoutPadding: WidgetStyle {
        var style = self
        style.paddingHorizontal = nil
        style.paddingVertical = nil
        style.paddingLeading = nil
        style.paddingTrailing = nil
        style.paddingTop = nil
        style.paddingBottom = nil
        style.states = states?.mapValues(\.withoutPadding)
        return style
    }

    /// This style without its padding and spacing, in its states too.
    var withoutSpacing: WidgetStyle {
        var style = withoutPadding
        style.spacing = nil
        style.states = style.states?.mapValues(\.withoutSpacing)
        return style
    }

    /// This popupDefaults style over the bar's `defaults`, whose padding and spacing are the bar widgets' and don't
    /// reach popups or tooltips.
    func popupStyle(over defaults: WidgetStyle) -> WidgetStyle {
        inheriting(defaults.withoutSpacing)
    }
}

indirect enum PopupContent: Sendable {
    case row([PopupBlock])
    case column([PopupBlock])
    case text(String)
    case field(String)
    case graph(height: Double, source: String?, lineWidth: Double)
    case list(source: String, row: PopupBlock, orientation: ListOrientation)
    case button(title: String, command: String)
    /// A slider over `minimum`…`maximum`, and past a notch the `endStop` when it has one.
    case slider(title: String, source: String, minimum: Double, maximum: Double, step: Double, endStop: SliderEndStop?, action: BlockAction)
    /// A slider drawn as a bar in the block's style, filled from the leading edge, with `icon` on the fill and past a
    /// notch the `endStop` when it has one.
    case filledSlider(title: String, source: String, minimum: Double, maximum: Double, step: Double, endStop: SliderEndStop?,
                      icon: String?, action: BlockAction)
    case toggle(title: String, source: String, action: BlockAction)
    case segmented(title: String, source: String, options: [PopupControlOption], command: String)
    /// A pill, or chips for the presets starred in `lists[stars.source]`, that opens a panel: the groups in
    /// `lists[groupsSource]` beside the chosen group's options and levels, rows of `lists[optionsSource]` and
    /// `lists[levelsSource]` that name it in `group`. `fields[source]` is the chosen group; starring runs `stars.command`.
    case chooser(title: String, source: String, groupsSource: String, optionsSource: String, levelsSource: String?,
                 stars: (source: String, command: String)?, command: String)
    case search(title: String, source: String, fields: [String]?, row: PopupBlock)
    /// A text field that runs `command` with its text. With `sendButton`, a round button in it sends the text, or runs
    /// `stop.command` instead while `fields[stop.busy]` isn't empty.
    case input(title: String, placeholder: String?, autofocus: Bool, sendButton: Bool, stop: (busy: String, command: String)?, command: String)
    case menu
    case divider
    case image(path: String, source: String?, fit: ImageFit, tinted: Bool)
    case symbol(name: String, source: String?)
    /// A rule filled to `values[source]` or `fields[source]`, or with `segments`, that many equal pieces lit up to it.
    case progress(source: String, height: Double, segments: Int?)
    /// A ring filled clockwise from the top to `values[source]` or `fields[source]`, with `children` centered in it. A
    /// `gap` leaves that many degrees open at the bottom, and the fill starts at the gap's left end.
    case ring(source: String, lineWidth: Double, gap: Double, children: [PopupBlock])
    /// Bars that bounce while `fields[source]` is on, or always without a source.
    case equalizer(source: String?, height: Double)
    /// A battery filled to `values[source]` or `fields[source]`, showing charging, the adapter and a
    /// battery that needs service from the `state` and `health` fields.
    case battery(source: String)
    /// The frontmost app's icon, drawn by an active-app widget's default layout. Configurations can't use it.
    case appIcon
    /// The update on offer and its download button, drawn by the update tile's popup. Configurations can't use it.
    case appUpdate
    /// An app's menu, drawn by an app menu widget's popup. Configurations can't use it.
    case appMenu([AppMenuEntry])
    case menuBarItems([MenuBarItem])
    case essentials(EssentialsPopup, timeZone: String?)
}

struct PopupBlock: Decodable, Sendable {
    let content: PopupContent
    /// An omitted choice lets the slider role decide; explicit false keeps the native control.
    private(set) var sliderFilled: Bool?
    private(set) var sliderIcon: String?
    let role: PresentationRole?
    let style: WidgetStyle
    let alignment: PopupAlignment
    let animation: WidgetAnimation?
    let styleSource: String?
    let styleField: String?
    let onClick: String?
    let onClickField: String?
    let open: String?
    let openField: String?
    let quitField: String?
    let openMenuBarItem: MenuBarItemReference?
    let selectInputSourceField: String?
    let selectOutputDeviceField: String?
    let selectInputDeviceField: String?
    let nowPlayingCommand: NowPlaying.Command?
    /// The name of one of its popup's `views`, which a click shows in place of the popup's layout.
    let view: String?
    let hideWhenEmpty: String?
    /// Conditions of which one must match for the block to show; nil shows it whatever the output.
    let showWhen: [RuleCondition]?
    /// Conditions any of which hides the block.
    let hideWhen: [RuleCondition]?
    let scrollSpeed: Double?
    /// Whether a field block shows all of its text over as many lines as it needs, selectable, and an input block
    /// runs its text onto more lines as it grows.
    let wraps: Bool
    /// The height past which a wrapping field block or a vertical list scrolls.
    let maxHeight: Double?
    /// Whether a field block shows Markdown: bold, italics, code and links, and when it wraps also headings, lists,
    /// code blocks and tables.
    let markdown: Bool
    /// Whether a block in a popup is as wide as its content, up to its `maxWidth`, and placed by its alignment.
    let fitsWidth: Bool
    /// Whether light sweeps across a text or field block, as while something works.
    let shimmer: Bool
    /// Whether a field block draws tabular digits. Configured field blocks do; the default layouts of
    /// widgets whose built-in look used proportional digits don't.
    let monospacedDigits: Bool
    /// Whether the block is at least a line of its text tall, as built-in widgets that show only an
    /// icon are. Default layouts set it; configured blocks can't.
    let keepsLineHeight: Bool
    /// A symbol a symbol block keeps the width of, its own centered in it, so changing
    /// between narrower symbols doesn't resize it. Default layouts set it; configured blocks can't.
    let widestSymbol: String?
    /// How a text, field or symbol block shows changed content; nil uses its widget's.
    let transition: WidgetTransition?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case type, role, style, alignment, children, text, field, height, source, row, orientation, title, onClick
        case path, fit, tinted, name, animation, styleSource, styleField, onClickField, lineWidth
        case hideWhenEmpty, showWhen, hideWhen, scrollSpeed, min, max, step, onChange, options, searchFields, open, openField, quitField
        case openMenuBarItem, selectInputSourceField, selectOutputDeviceField, selectInputDeviceField, nowPlayingCommand, view, transition
        case placeholder, onSubmit, autofocus, wrap, maxHeight, markdown, shimmer, groupsSource, optionsSource, levelsSource, endStop
        case fitWidth, sendButton, busy, onStop, starsSource, onStar, filled, icon, gap, segments, set
    }

    init(content: PopupContent, role: PresentationRole? = nil, style: WidgetStyle = WidgetStyle(), hideWhenEmpty: String? = nil, monospacedDigits: Bool = true,
         keepsLineHeight: Bool = false, widestSymbol: String? = nil, transition: WidgetTransition? = nil) {
        self.content = content
        self.role = role
        self.style = style
        alignment = .leading
        animation = nil
        styleSource = nil
        styleField = nil
        onClick = nil
        onClickField = nil
        open = nil
        openField = nil
        quitField = nil
        openMenuBarItem = nil
        selectInputSourceField = nil
        selectOutputDeviceField = nil
        selectInputDeviceField = nil
        nowPlayingCommand = nil
        view = nil
        self.hideWhenEmpty = hideWhenEmpty
        showWhen = nil
        hideWhen = nil
        scrollSpeed = nil
        wraps = false
        maxHeight = nil
        markdown = false
        fitsWidth = false
        shimmer = false
        self.monospacedDigits = monospacedDigits
        self.keepsLineHeight = keepsLineHeight
        self.widestSymbol = widestSymbol
        self.transition = transition
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        role = try values.decodeIfPresent(PresentationRole.self, forKey: .role)
        style = try values.decodeIfPresent(WidgetStyle.self, forKey: .style) ?? WidgetStyle()
        alignment = try values.decodeIfPresent(PopupAlignment.self, forKey: .alignment) ?? .leading
        animation = try values.decodeIfPresent(WidgetAnimation.self, forKey: .animation)
        styleSource = try values.decodeIfPresent(String.self, forKey: .styleSource)
        styleField = try values.decodeIfPresent(String.self, forKey: .styleField)
        onClick = try values.decodeIfPresent(String.self, forKey: .onClick)
        onClickField = try values.decodeIfPresent(String.self, forKey: .onClickField)
        open = try values.decodeIfPresent(String.self, forKey: .open)
        openField = try values.decodeIfPresent(String.self, forKey: .openField)
        if let open, OpenTarget(open) == nil {
            throw DecodingError.dataCorruptedError(forKey: .open, in: values, debugDescription: "Use an http, https, mailto or x-apple.systempreferences URL, or an application bundle identifier such as com.apple.iCal.")
        }
        if onClick != nil || onClickField != nil, open != nil || openField != nil {
            throw DecodingError.dataCorruptedError(forKey: .open, in: values, debugDescription: "A block cannot combine onClick or onClickField with open or openField.")
        }
        quitField = try values.decodeIfPresent(String.self, forKey: .quitField)
        if quitField != nil, onClick != nil || onClickField != nil || open != nil || openField != nil {
            throw DecodingError.dataCorruptedError(forKey: .quitField, in: values, debugDescription: "A block cannot combine quitField with onClick, onClickField, open or openField.")
        }
        openMenuBarItem = try values.decodeIfPresent(MenuBarItemReference.self, forKey: .openMenuBarItem)
        if openMenuBarItem != nil, onClick != nil || onClickField != nil || open != nil || openField != nil || quitField != nil {
            throw DecodingError.dataCorruptedError(forKey: .openMenuBarItem, in: values, debugDescription: "A block cannot combine openMenuBarItem with onClick, onClickField, open, openField or quitField.")
        }
        selectInputSourceField = try values.decodeIfPresent(String.self, forKey: .selectInputSourceField)
        if selectInputSourceField != nil, onClick != nil || onClickField != nil || open != nil || openField != nil || quitField != nil || openMenuBarItem != nil {
            throw DecodingError.dataCorruptedError(forKey: .selectInputSourceField, in: values, debugDescription: "A block cannot combine selectInputSourceField with onClick, onClickField, open, openField, quitField or openMenuBarItem.")
        }
        selectOutputDeviceField = try values.decodeIfPresent(String.self, forKey: .selectOutputDeviceField)
        if selectOutputDeviceField != nil, onClick != nil || onClickField != nil || open != nil || openField != nil || quitField != nil || openMenuBarItem != nil
            || selectInputSourceField != nil {
            throw DecodingError.dataCorruptedError(forKey: .selectOutputDeviceField, in: values, debugDescription: "A block cannot combine selectOutputDeviceField with onClick, onClickField, open, openField, quitField, openMenuBarItem or selectInputSourceField.")
        }
        selectInputDeviceField = try values.decodeIfPresent(String.self, forKey: .selectInputDeviceField)
        if selectInputDeviceField != nil, onClick != nil || onClickField != nil || open != nil || openField != nil || quitField != nil || openMenuBarItem != nil
            || selectInputSourceField != nil || selectOutputDeviceField != nil {
            throw DecodingError.dataCorruptedError(forKey: .selectInputDeviceField, in: values, debugDescription: "A block cannot combine selectInputDeviceField with onClick, onClickField, open, openField, quitField, openMenuBarItem, selectInputSourceField or selectOutputDeviceField.")
        }
        nowPlayingCommand = try values.decodeIfPresent(NowPlaying.Command.self, forKey: .nowPlayingCommand)
        if nowPlayingCommand != nil, onClick != nil || onClickField != nil || open != nil || openField != nil || quitField != nil || openMenuBarItem != nil
            || selectInputSourceField != nil || selectOutputDeviceField != nil || selectInputDeviceField != nil {
            throw DecodingError.dataCorruptedError(forKey: .nowPlayingCommand, in: values, debugDescription: "A block cannot combine nowPlayingCommand with onClick, onClickField, open, openField, quitField, openMenuBarItem, selectInputSourceField, selectOutputDeviceField or selectInputDeviceField.")
        }
        view = try values.decodeIfPresent(String.self, forKey: .view)
        if view != nil, onClick != nil || onClickField != nil || open != nil || openField != nil || quitField != nil || openMenuBarItem != nil
            || selectInputSourceField != nil || selectOutputDeviceField != nil || selectInputDeviceField != nil || nowPlayingCommand != nil {
            throw DecodingError.dataCorruptedError(forKey: .view, in: values, debugDescription: "A block cannot combine view with onClick, onClickField, open, openField, quitField, openMenuBarItem, selectInputSourceField, selectOutputDeviceField, selectInputDeviceField or nowPlayingCommand.")
        }
        hideWhenEmpty = try values.decodeIfPresent(String.self, forKey: .hideWhenEmpty)
        showWhen = try Self.conditions(in: values, forKey: .showWhen)
        hideWhen = try Self.conditions(in: values, forKey: .hideWhen)
        scrollSpeed = try values.decodeIfPresent(Double.self, forKey: .scrollSpeed)
        if let scrollSpeed, scrollSpeed <= 0 {
            throw DecodingError.dataCorruptedError(forKey: .scrollSpeed, in: values, debugDescription: "Scroll speed must be greater than zero.")
        }
        wraps = try values.decodeIfPresent(Bool.self, forKey: .wrap) ?? false
        maxHeight = try values.decodeIfPresent(Double.self, forKey: .maxHeight)
        if let maxHeight, maxHeight <= 0 {
            throw DecodingError.dataCorruptedError(forKey: .maxHeight, in: values, debugDescription: "maxHeight must be greater than zero.")
        }
        markdown = try values.decodeIfPresent(Bool.self, forKey: .markdown) ?? false
        fitsWidth = try values.decodeIfPresent(Bool.self, forKey: .fitWidth) ?? false
        shimmer = try values.decodeIfPresent(Bool.self, forKey: .shimmer) ?? false
        monospacedDigits = true
        keepsLineHeight = false
        widestSymbol = nil
        transition = try values.decodeIfPresent(WidgetTransition.self, forKey: .transition)
        func controlAction(_ settings: [NativeSetting]) throws -> BlockAction {
            guard let setting = try values.decodeIfPresent(NativeSetting.self, forKey: .set) else {
                return .command(try values.decode(String.self, forKey: .onChange))
            }
            if values.contains(.onChange) {
                throw DecodingError.dataCorruptedError(forKey: .set, in: values, debugDescription: "A control cannot combine set with onChange.")
            }
            guard settings.contains(setting) else {
                throw DecodingError.dataCorruptedError(forKey: .set, in: values, debugDescription: "A slider can set volume or inputVolume, and a toggle muted, inputMuted or wifiPower.")
            }
            return .set(setting)
        }
        switch try values.decode(String.self, forKey: .type) {
        case "row": content = .row(try values.decode([PopupBlock].self, forKey: .children))
        case "column": content = .column(try values.decode([PopupBlock].self, forKey: .children))
        case "text": content = .text(try values.decode(String.self, forKey: .text))
        case "field": content = .field(try values.decode(String.self, forKey: .field))
        case "graph":
            content = .graph(height: try values.decode(Double.self, forKey: .height),
                             source: try values.decodeIfPresent(String.self, forKey: .source),
                             lineWidth: try values.decodeIfPresent(Double.self, forKey: .lineWidth) ?? 1.5)
        case "list":
            content = .list(source: try values.decode(String.self, forKey: .source),
                            row: try values.decode(PopupBlock.self, forKey: .row),
                            orientation: try values.decodeIfPresent(ListOrientation.self, forKey: .orientation) ?? .vertical)
        case "button":
            content = .button(title: try values.decode(String.self, forKey: .title),
                              command: try values.decode(String.self, forKey: .onClick))
        case "slider":
            let minimum = try values.decodeIfPresent(Double.self, forKey: .min) ?? 0
            let maximum = try values.decodeIfPresent(Double.self, forKey: .max) ?? 1
            let step = try values.decodeIfPresent(Double.self, forKey: .step) ?? 0.01
            guard minimum < maximum, step > 0, minimum.isFinite, maximum.isFinite, step.isFinite else {
                throw DecodingError.dataCorruptedError(forKey: .min, in: values, debugDescription: "A slider needs finite min < max and a positive finite step.")
            }
            let endStop = try values.decodeIfPresent(SliderEndStop.self, forKey: .endStop)
            if let endStop, (minimum...maximum).contains(endStop.value) {
                throw DecodingError.dataCorruptedError(forKey: .endStop, in: values, debugDescription: "An end stop's value must be outside min…max, so the slider can tell it from a step.")
            }
            let filled = try values.decodeIfPresent(Bool.self, forKey: .filled)
            let icon = try values.decodeIfPresent(String.self, forKey: .icon)
            if icon != nil, filled == false {
                throw DecodingError.dataCorruptedError(forKey: .icon, in: values, debugDescription: "Only a filled slider shows an icon; remove \"filled\": false to follow the slider role, or set it to true.")
            }
            sliderFilled = filled
            sliderIcon = icon
            let title = try values.decode(String.self, forKey: .title)
            let source = try values.decode(String.self, forKey: .source)
            let action = try controlAction([.volume, .inputVolume])
            content = filled == true
                ? .filledSlider(title: title, source: source, minimum: minimum, maximum: maximum, step: step, endStop: endStop,
                                icon: icon, action: action)
                : .slider(title: title, source: source, minimum: minimum, maximum: maximum, step: step, endStop: endStop, action: action)
        case "toggle":
            content = .toggle(title: try values.decode(String.self, forKey: .title),
                              source: try values.decode(String.self, forKey: .source),
                              action: try controlAction([.muted, .inputMuted, .wifiPower]))
        case "segmented":
            let options = try values.decode([PopupControlOption].self, forKey: .options)
            guard !options.isEmpty, Set(options.map(\.value)).count == options.count else {
                throw DecodingError.dataCorruptedError(forKey: .options, in: values, debugDescription: "A segmented control needs options with unique values.")
            }
            content = .segmented(title: try values.decode(String.self, forKey: .title),
                                 source: try values.decode(String.self, forKey: .source), options: options,
                                 command: try values.decode(String.self, forKey: .onChange))
        case "chooser":
            content = .chooser(title: try values.decode(String.self, forKey: .title), source: try values.decode(String.self, forKey: .source),
                               groupsSource: try values.decode(String.self, forKey: .groupsSource),
                               optionsSource: try values.decode(String.self, forKey: .optionsSource),
                               levelsSource: try values.decodeIfPresent(String.self, forKey: .levelsSource),
                               stars: try values.decodeIfPresent(String.self, forKey: .starsSource).map {
                                   (source: $0, command: try values.decode(String.self, forKey: .onStar))
                               },
                               command: try values.decode(String.self, forKey: .onChange))
        case "search":
            content = .search(title: try values.decode(String.self, forKey: .title),
                              source: try values.decode(String.self, forKey: .source),
                              fields: try values.decodeIfPresent([String].self, forKey: .searchFields),
                              row: try values.decode(PopupBlock.self, forKey: .row))
        case "input":
            content = .input(title: try values.decode(String.self, forKey: .title),
                             placeholder: try values.decodeIfPresent(String.self, forKey: .placeholder),
                             autofocus: try values.decodeIfPresent(Bool.self, forKey: .autofocus) ?? false,
                             sendButton: try values.decodeIfPresent(Bool.self, forKey: .sendButton) ?? false,
                             stop: try values.decodeIfPresent(String.self, forKey: .busy).map {
                                 (busy: $0, command: try values.decode(String.self, forKey: .onStop))
                             },
                             command: try values.decode(String.self, forKey: .onSubmit))
        case "menu": content = .menu
        case "divider": content = .divider
        case "image":
            let source = try values.decodeIfPresent(String.self, forKey: .source)
            content = .image(path: source == nil ? try values.decode(String.self, forKey: .path) : "",
                             source: source, fit: try values.decodeIfPresent(ImageFit.self, forKey: .fit) ?? .fit,
                             tinted: try values.decodeIfPresent(Bool.self, forKey: .tinted) ?? false)
        case "symbol":
            let source = try values.decodeIfPresent(String.self, forKey: .source)
            content = .symbol(name: source == nil ? try values.decode(String.self, forKey: .name) : "", source: source)
        case "progress":
            let segments = try values.decodeIfPresent(Int.self, forKey: .segments)
            if let segments, segments < 1 {
                throw DecodingError.dataCorruptedError(forKey: .segments, in: values, debugDescription: "A progress block needs at least one segment.")
            }
            content = .progress(source: try values.decode(String.self, forKey: .source),
                                height: try values.decode(Double.self, forKey: .height), segments: segments)
        case "ring":
            content = .ring(source: try values.decode(String.self, forKey: .source),
                            lineWidth: try values.decodeIfPresent(Double.self, forKey: .lineWidth) ?? 2,
                            gap: try values.decodeIfPresent(Double.self, forKey: .gap) ?? 0,
                            children: try values.decodeIfPresent([PopupBlock].self, forKey: .children) ?? [])
        case "equalizer":
            let height = try values.decodeIfPresent(Double.self, forKey: .height) ?? 12
            guard height > 0, height.isFinite else {
                throw DecodingError.dataCorruptedError(forKey: .height, in: values, debugDescription: "An equalizer's height must be greater than zero.")
            }
            content = .equalizer(source: try values.decodeIfPresent(String.self, forKey: .source), height: height)
        case "battery":
            content = .battery(source: try values.decodeIfPresent(String.self, forKey: .source) ?? "percent")
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: values, debugDescription: "Unknown popup block type.")
        }
        if transition != nil {
            switch content {
            case .text, .field, .symbol: break
            default:
                throw DecodingError.dataCorruptedError(forKey: .transition, in: values,
                                                       debugDescription: "Transitions apply to text, field and symbol blocks.")
            }
        }
        let optionsApply = switch content {
        case .field: wraps || maxHeight == nil
        case .input: !markdown && maxHeight == nil
        case .list(_, _, .vertical): !wraps && !markdown
        default: !wraps && !markdown && maxHeight == nil
        }
        guard optionsApply else {
            throw DecodingError.dataCorruptedError(forKey: .wrap, in: values, debugDescription:
                "wrap applies to field and input blocks, markdown to field blocks, and maxHeight to field blocks that wrap and to vertical lists.")
        }
        if shimmer {
            switch content {
            case .text, .field: break
            default:
                throw DecodingError.dataCorruptedError(forKey: .shimmer, in: values, debugDescription: "shimmer applies to text and field blocks.")
            }
        }
    }

    /// One condition, or a list of them.
    private static func conditions(in values: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) throws -> [RuleCondition]? {
        guard values.contains(key), try !values.decodeNil(forKey: key) else { return nil }
        guard (try? values.nestedUnkeyedContainer(forKey: key)) != nil else { return [try values.decode(RuleCondition.self, forKey: key)] }
        let conditions = try values.decode([RuleCondition].self, forKey: key)
        guard !conditions.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: key, in: values, debugDescription: "List at least one condition, or leave \(key.stringValue) out.")
        }
        return conditions
    }

    /// Whether the block shows nothing and takes no space for these fields: its `hideWhenEmpty` field is empty,
    /// none of its `showWhen` conditions match, or one of its `hideWhen` conditions does.
    func isHidden(fields: [String: String], values: [String: Double]) -> Bool {
        if let field = hideWhenEmpty, fields[field, default: ""].isEmpty { return true }
        if let showWhen, !showWhen.contains(where: { $0.matches(fields: fields, values: values) }) { return true }
        return hideWhen?.contains { $0.matches(fields: fields, values: values) } == true
    }
}

extension PopupBlock {
    /// The views this block and the blocks inside it open.
    var openedViews: [String] {
        let inside: [PopupBlock] = switch content {
        case let .row(children), let .column(children), let .ring(_, _, _, children): children
        case let .list(_, row, _), let .search(_, _, _, row): [row]
        default: []
        }
        return (view.map { [$0] } ?? []) + inside.flatMap(\.openedViews)
    }

    /// Whether a view starts with its title: a shown column whose first block is a text block, which then sits beside the
    /// back arrow. A hidden view keeps the back arrow above it, so it can still be left.
    func startsWithTitle(fields: [String: String], values: [String: Double]) -> Bool {
        guard !isHidden(fields: fields, values: values), case let .column(children) = content, case .text? = children.first?.content else { return false }
        return true
    }
}

enum ListOrientation: String, Decodable, Sendable {
    case horizontal, vertical
}

enum ImageFit: String, Decodable, Sendable {
    case fit, fill
}

enum PopupAlignment: String, Decodable, Sendable {
    case leading, center, trailing
}

/// What a block runs: a shell command, or for a slider or toggle with `set`, a setting StableBar changes itself.
enum BlockAction: Sendable {
    case command(String)
    case set(NativeSetting)
    case nowPlaying(NowPlaying.Command)
}

struct PopupControlOption: Decodable, Sendable {
    let title: String
    let value: String

    enum CodingKeys: String, CodingKey, CaseIterable { case title, value }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        title = try values.decode(String.self, forKey: .title)
        value = try values.decode(String.self, forKey: .value)
    }
}

func searchPopupRows(_ rows: [[String: String]], query: String, fields: [String]?) -> [[String: String]] {
    if query.isEmpty { return rows }
    return rows.filter { row in
        let text = fields.map { $0.compactMap { row[$0] } } ?? Array(row.values)
        return text.contains { $0.localizedStandardContains(query) }
    }
}
