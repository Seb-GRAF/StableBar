import AppKit

/// What a widget shows: its text and icon, and the fields its layout blocks read, which add
/// `text` and `icon` to the output's own fields.
struct WidgetLabel: Equatable, Sendable {
    var text: String
    var icon: String?
    var fields: [String: String]
}

extension WidgetConfiguration {
    /// This widget's label: a text widget's text, a clock's time at `date`, the frontmost app's
    /// name (`activeApp`, else Desktop), or its script or provider output. The bar, the More widgets
    /// menu and Diagnostics all read it here. Workspaces and spacers have no text.
    func label(output: ScriptOutput?, activeApp: String?, date: Date) -> WidgetLabel {
        var icon = self.icon
        let text: String
        switch content {
        case let .text(value):
            text = value
        case let .clock(format):
            let formatter = DateFormatter()
            formatter.dateFormat = format
            formatter.timeZone = timeZone.flatMap(TimeZone.init(identifier:)) ?? .autoupdatingCurrent
            text = formatter.string(from: date)
        case .activeApp:
            text = activeApp ?? "Desktop"
        case .script, .provider:
            text = output?.text ?? "…"
            icon = output?.icon ?? icon
        case .workspaces, .appMenu, .appleMenu, .spacer:
            return WidgetLabel(text: "", icon: icon, fields: output?.fields ?? [:])
        }
        var fields = output?.fields ?? [:]
        fields["text"] = text
        fields["icon"] = icon ?? ""
        return WidgetLabel(text: text, icon: icon, fields: fields)
    }
}

extension BarStore {
    /// `widget`'s label from its current output. Only active-app widgets read the frontmost app, so
    /// switching apps redraws no other widget.
    func label(for widget: WidgetConfiguration, date: Date = .now) -> WidgetLabel {
        widget.label(output: scripts[widget.id]?.output,
                     activeApp: widget.content == .activeApp ? activeApp?.localizedName : nil, date: date)
    }
}

extension WidgetConfiguration {
    /// The blocks a widget without `layout` draws, matching the look built-in widgets had before
    /// they were drawn through blocks: its icon and text in a row at least a line of text tall, after
    /// a 40 × 16 graph for output with a `value`, or after the app's icon for the active app.
    /// `providerType` is the type of the widget's provider, else its name is. Battery draws only its
    /// battery, its percentage left to the tooltip, or its icon and text on a Mac without one; sound
    /// (`audio`) draws its icon, with the volume only while a change shows it. `appIcon` says whether
    /// the frontmost app has one. Workspaces, spacers and scripts without output have none.
    func defaultLayout(_ label: WidgetLabel, output: ScriptOutput?, appIcon: Bool, providerType: String? = nil) -> PopupBlock? {
        let icon = label.icon.map { _ in PopupBlock(content: .symbol(name: "", source: "icon")) }
        let text = PopupBlock(content: .field("text"), hideWhenEmpty: "text")
        switch content {
        case .text:
            return PopupBlock(content: .row([icon, text].compactMap { $0 }), keepsLineHeight: true)
        case .clock:
            return PopupBlock(content: .row([icon, PopupBlock(content: .field("text"), hideWhenEmpty: "text")].compactMap { $0 }),
                              keepsLineHeight: true)
        case .activeApp:
            let app = appIcon ? PopupBlock(content: .appIcon) : nil
            return PopupBlock(content: .row([app, PopupBlock(content: .field("text"), monospacedDigits: false)].compactMap { $0 }))
        case .provider where (providerType ?? providerName) == DataSourceType.audio.name:
            guard output != nil else { return nil }
            let field = AudioMonitor.changedVolumeField
            let volume = PopupBlock(content: .field(field), hideWhenEmpty: field, transition: transition == nil ? .numeric : nil)
            let speaker = label.icon.map { _ in PopupBlock(content: .symbol(name: "", source: "icon"), widestSymbol: AudioMonitor.widestIcon) }
            return PopupBlock(content: .row([speaker, volume].compactMap { $0 }), keepsLineHeight: true)
        case .provider where (providerType ?? providerName) == DataSourceType.battery.name && output?.fields?["present"] != "false":
            guard output != nil else { return nil }
            return PopupBlock(content: .row([PopupBlock(content: .battery(source: "percent"))]), keepsLineHeight: true)
        case .provider where (providerType ?? providerName) == "calendar" && details:
            return PopupBlock(content: .row([
                PopupBlock(content: .symbol(name: "calendar", source: nil)),
                PopupBlock(content: .field("text"), style: WidgetStyle(maxWidth: 180), monospacedDigits: false),
                PopupBlock(content: .field("minutes"), hideWhenEmpty: "minutes"),
                PopupBlock(content: .text("min"), hideWhenEmpty: "minutes")
            ]), keepsLineHeight: true)
        case .script, .provider:
            guard let output else { return nil }
            let type = providerType ?? providerName
            let graph = output.value == nil || type == "battery" ? nil
                : PopupBlock(content: .graph(height: 16, source: nil, lineWidth: 1.2), style: WidgetStyle(width: 40))
            let label = PopupBlock(content: .row([icon, text].compactMap { $0 }), keepsLineHeight: true)
            return PopupBlock(content: .row([graph, label].compactMap { $0 }))
        case .workspaces, .appMenu, .appleMenu, .spacer:
            return nil
        }
    }
}

extension WidgetLabel {
    /// This label with `fields` shown over its own. A `text` or `icon` field replaces the text or
    /// icon; an empty `icon` hides it.
    func overlaid(by fields: [String: String]?) -> WidgetLabel {
        guard let fields else { return self }
        var label = self
        label.fields.merge(fields) { $1 }
        if let text = fields["text"] { label.text = text }
        if let icon = fields["icon"] { label.icon = icon.isEmpty ? nil : icon }
        return label
    }
}
