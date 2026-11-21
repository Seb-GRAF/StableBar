import SwiftUI

/// The Sound widget without a `layout` of its own, while hover controls open inline: its icon, with the volume for a
/// moment after a change, as its default layout draws them. Hovering it opens a volume slider beside the icon that
/// sets the volume as it moves. On the right of the bar the widget grows to the left, so the slider opens there and the
/// icon stays under the pointer; elsewhere it opens to the right.
struct SoundWidgetView: View {
    let widget: WidgetConfiguration
    let store: BarStore
    let monitor: Int
    let style: LayoutStyle
    /// The widget's block states, so a themed slider follows its role's hover and mode states.
    var sliderStates = StyleStates()
    let hovered: Bool
    let motion: BlockMotion
    let runAction: (BlockAction, [String: String]) -> Void
    @State private var dragging = false
    @Environment(\.measuringBarWidths) private var measuring
    @Environment(\.moreWidgetsAnchor) private var moreWidgetsAnchor
    @Environment(\.barExpansion) private var barExpansion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The icon alone, drawn like the default layout's, while the slider shows the volume.
    private static let icon = PopupBlock(content: .row([PopupBlock(content: .symbol(name: "", source: "icon"), widestSymbol: AudioMonitor.widestIcon)]),
                                         keepsLineHeight: true)

    /// Whether the slider opens before the icon: on the right of the bar, which grows to the left.
    static func opensBeforeIcon(_ position: WidgetPosition) -> Bool { position == .right }

    var body: some View {
        let volume = store.widgetScripts.scripts[widget.id]?.output.values?["volume"]
        let expanded = volume != nil && (barExpansion.map { $0 == .granted } ?? (store.barPresentation.presentations[widget.id]?.expandedDisplays.contains(monitor) == true))
        let appearance = WidgetAppearance(style.inherited, defaults: WidgetStyle())
        Group {
            if volume != nil {
                HoverExpansionLayout(expansion: expanded ? 1 : 0, spacing: appearance.spacing, controlsBefore: Self.opensBeforeIcon(widget.position)) {
                    VolumeSlider(widget: widget, store: store,
                                 style: LayoutStyle(inherited: style.inherited, states: sliderStates, tracksHover: true),
                                 width: 72, inline: true)
                        .controlSize(.mini)
                        .allowsHitTesting(expanded)
                        .accessibilityHidden(!expanded)
                    WidgetBlocks(widget: widget, store: store, style: style, block: expanded ? Self.icon : nil, motion: motion, runAction: runAction)
                }
                .clipped()
            } else {
                WidgetBlocks(widget: widget, store: store, style: style, motion: motion, runAction: runAction)
            }
        }
        .onPreferenceChange(ControlEditingPreference.self) { dragging = $0 }
        .onChange(of: hovered || dragging) { _, open in expand(open) }
        .onDisappear { expand(false) }
    }

    private func expand(_ open: Bool) {
        guard !measuring, moreWidgetsAnchor == nil else { return }
        store.barPresentation.presentations[widget.id]?.setExpanded(open, on: monitor, animation: reduceMotion ? nil : motion.animation)
    }
}

/// The Sound widget's volume slider, which sets the volume as it moves, with the volume beside it.
struct VolumeSlider: View {
    let widget: WidgetConfiguration
    let store: BarStore
    let style: LayoutStyle
    let width: CGFloat
    /// Beside the icon on the bar; otherwise in a tooltip under the widget.
    var inline = false
    /// The slider's value while it is dragged, ahead of the volume the source reads back.
    @State private var level: Double?
    @State private var dragging = false
    @Environment(\.screenKind) private var screenKind

    private static let slider = PopupBlock(content: .slider(title: "Volume", source: "volume", minimum: 0, maximum: 1,
                                                          step: 0.01, endStop: nil, action: .set(.volume)))

    var body: some View {
        if let volume = store.widgetScripts.scripts[widget.id]?.output.values?["volume"] {
            let shown = level ?? volume
            let appearance = WidgetAppearance(style.inherited, defaults: WidgetStyle())
            let roles = store.configuration?.look(on: screenKind).roles ?? [:]
            HStack(spacing: appearance.spacing) {
                if Self.slider.automaticallyFillsSlider(roles: roles) {
                    PopupBlockView(block: Self.slider, inheritedStyle: style.inherited, fields: [:],
                                   context: BlockContext(values: ["volume": shown], roles: roles,
                                                         inlineControlHeight: inline ? style.inherited.inlineControlHeight : nil,
                                                         tooltipLineHeight: inline ? nil : style.inherited.lineHeight,
                                                         continuousSliders: true, fillsWidth: false, open: { _ in },
                                                         states: style.states, tracksHover: style.tracksHover,
                                                         runAction: { _, values in
                                                             if let value = values["VALUE"].flatMap(Double.init) { set(value) }
                                                         }))
                        .frame(width: width)
                        // The HStack's own preference below replaces the slider's, so pass the drag on through it.
                        .onPreferenceChange(ControlEditingPreference.self) { editing in
                            dragging = editing
                            if !editing { level = nil }
                        }
                } else {
                    // A line of text tall, so opening the slider doesn't make the widget taller.
                    Text(" ").hidden().frame(width: width).overlay {
                        Slider(value: Binding(get: { shown }, set: { set($0) }), in: 0...1) { editing in
                            dragging = editing
                            if !editing { level = nil }
                        }
                        .tint(appearance.accent)
                        .accessibilityLabel("Volume")
                    }
                }
                // As wide as 100% at any volume, so dragging doesn't move the bar.
                ZStack(alignment: .trailing) {
                    Text("100%").hidden()
                    Text("\(Int((shown * 100).rounded()))%")
                }
                .monospacedDigit()
                .accessibilityHidden(true)
            }
            .font(appearance.font)
            .foregroundStyle(appearance.foreground)
            // Keyboard and VoiceOver changes set the volume without a drag, so only a drag keeps its value over the source's.
            .onChange(of: volume) { if !dragging { level = nil } }
            .preference(key: ControlEditingPreference.self, value: dragging)
        }
    }

    private func set(_ volume: Double) {
        level = volume
        do {
            try AudioMonitor.setVolume(volume)
            if store.widgetScripts.actionErrors[widget.id] != nil { store.widgetScripts.actionErrors[widget.id] = nil }
        } catch {
            store.widgetScripts.actionErrors[widget.id] = error.localizedDescription
        }
    }
}
