import Foundation

struct PopupConfiguration: Decodable, Sendable {
    let height: Double?
    let style: WidgetStyle
    let layout: PopupBlock
    var alignment: PopupAlignment = .center
    var offset = 6.0
    var openOnHover = false
    var dismissOnAction = true
    var dismissOnControl = false
    var pinnable = false
    var animation: WidgetAnimation?

    enum CodingKeys: String, CodingKey, CaseIterable { case height, style, layout, alignment, offset, openOnHover, dismissOnAction, dismissOnControl, pinnable, animation }

    init(height: Double? = nil, style: WidgetStyle, layout: PopupBlock) {
        self.height = height
        self.style = style
        self.layout = layout
    }

    /// `defaults` already includes popupDefaults. A widget's explicit style reaches its popup;
    /// its bar role deliberately does not.
    func baseStyle(widget: WidgetConfiguration, defaults: WidgetStyle) -> WidgetStyle {
        resolveStyle([defaults, widget.style, style])
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        height = try values.decodeIfPresent(Double.self, forKey: .height)
        style = try values.decode(WidgetStyle.self, forKey: .style)
        layout = try values.decode(PopupBlock.self, forKey: .layout)
        alignment = try values.decodeIfPresent(PopupAlignment.self, forKey: .alignment) ?? alignment
        offset = try values.decodeIfPresent(Double.self, forKey: .offset) ?? offset
        openOnHover = try values.decodeIfPresent(Bool.self, forKey: .openOnHover) ?? openOnHover
        dismissOnAction = try values.decodeIfPresent(Bool.self, forKey: .dismissOnAction) ?? dismissOnAction
        dismissOnControl = try values.decodeIfPresent(Bool.self, forKey: .dismissOnControl) ?? dismissOnControl
        pinnable = try values.decodeIfPresent(Bool.self, forKey: .pinnable) ?? pinnable
        animation = try values.decodeIfPresent(WidgetAnimation.self, forKey: .animation)
    }
}

indirect enum PopupContent: Sendable {
    case row([PopupBlock])
    case column([PopupBlock])
    case text(String)
    case field(String)
    case graph(height: Double, source: String?, lineWidth: Double)
    case list(source: String, row: PopupBlock)
    case button(title: String, command: String)
    case slider(title: String, source: String, minimum: Double, maximum: Double, step: Double, command: String)
    case toggle(title: String, source: String, command: String)
    case segmented(title: String, source: String, options: [PopupControlOption], command: String)
    /// A pill that opens a panel: the groups in `lists[groupsSource]` beside the chosen group's options and levels, rows of
    /// `lists[optionsSource]` and `lists[levelsSource]` that name it in `group`. `fields[source]` is the chosen group.
    case chooser(title: String, source: String, groupsSource: String, optionsSource: String, levelsSource: String?, command: String)
    case search(title: String, source: String, fields: [String]?, row: PopupBlock)
    case input(title: String, placeholder: String?, autofocus: Bool, command: String)
    case menu
    case divider
    case image(path: String, source: String?, fit: ImageFit)
    case symbol(name: String, source: String?)
    case progress(source: String, height: Double)
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
    let hideWhenEmpty: String?
    let scrollSpeed: Double?
    /// Whether a field block shows all of its text over as many lines as it needs, selectable.
    let wraps: Bool
    /// The height past which a wrapping field block scrolls.
    let maxHeight: Double?
    /// Whether a field block shows inline Markdown: bold, italics, code and links.
    let markdown: Bool
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
        case type, role, style, alignment, children, text, field, height, source, row, title, onClick
        case path, fit, name, animation, styleSource, styleField, onClickField, lineWidth
        case hideWhenEmpty, scrollSpeed, min, max, step, onChange, options, searchFields, open, openField, quitField, transition
        case placeholder, onSubmit, autofocus, wrap, maxHeight, markdown, shimmer, groupsSource, optionsSource, levelsSource
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
        self.hideWhenEmpty = hideWhenEmpty
        scrollSpeed = nil
        wraps = false
        maxHeight = nil
        markdown = false
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
        hideWhenEmpty = try values.decodeIfPresent(String.self, forKey: .hideWhenEmpty)
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
        shimmer = try values.decodeIfPresent(Bool.self, forKey: .shimmer) ?? false
        monospacedDigits = true
        keepsLineHeight = false
        widestSymbol = nil
        transition = try values.decodeIfPresent(WidgetTransition.self, forKey: .transition)
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
                            row: try values.decode(PopupBlock.self, forKey: .row))
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
            content = .slider(title: try values.decode(String.self, forKey: .title),
                              source: try values.decode(String.self, forKey: .source), minimum: minimum, maximum: maximum,
                              step: step, command: try values.decode(String.self, forKey: .onChange))
        case "toggle":
            content = .toggle(title: try values.decode(String.self, forKey: .title),
                              source: try values.decode(String.self, forKey: .source),
                              command: try values.decode(String.self, forKey: .onChange))
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
                             command: try values.decode(String.self, forKey: .onSubmit))
        case "menu": content = .menu
        case "divider": content = .divider
        case "image":
            let source = try values.decodeIfPresent(String.self, forKey: .source)
            content = .image(path: source == nil ? try values.decode(String.self, forKey: .path) : "",
                             source: source, fit: try values.decodeIfPresent(ImageFit.self, forKey: .fit) ?? .fit)
        case "symbol":
            let source = try values.decodeIfPresent(String.self, forKey: .source)
            content = .symbol(name: source == nil ? try values.decode(String.self, forKey: .name) : "", source: source)
        case "progress":
            content = .progress(source: try values.decode(String.self, forKey: .source),
                                height: try values.decode(Double.self, forKey: .height))
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
        if wraps || markdown || maxHeight != nil {
            guard case .field = content, wraps || maxHeight == nil else {
                throw DecodingError.dataCorruptedError(forKey: .wrap, in: values,
                                                       debugDescription: "wrap and markdown apply to field blocks, and maxHeight to field blocks that wrap.")
            }
        }
        if shimmer {
            switch content {
            case .text, .field: break
            default:
                throw DecodingError.dataCorruptedError(forKey: .shimmer, in: values, debugDescription: "shimmer applies to text and field blocks.")
            }
        }
    }
}

enum ImageFit: String, Decodable, Sendable {
    case fit, fill
}

enum PopupAlignment: String, Decodable, Sendable {
    case leading, center, trailing
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
