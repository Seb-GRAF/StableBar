import SwiftUI

/// The Sound widget without a `layout` of its own: its icon, with the volume for a moment after a
/// change, as its default layout draws them. Hovering it opens a volume slider beside the icon that
/// sets the volume as it moves. On the right of the bar the widget grows to the left, so the slider
/// opens there and the icon stays under the pointer; elsewhere it opens to the right.
struct SoundWidgetView: View {
    let widget: WidgetConfiguration
    let store: BarStore
    let monitor: Int
    let style: LayoutStyle
    let hovered: Bool
    let motion: BlockMotion
    let runAction: (String, [String: String]) -> Void
    /// The slider's value while it is dragged, ahead of the volume the source reads back.
    @State private var level: Double?
    @State private var dragging = false
    @Environment(\.measuringBarWidths) private var measuring
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The icon alone, drawn like the default layout's, while the slider shows the volume.
    private static let icon = PopupBlock(content: .row([PopupBlock(content: .symbol(name: "", source: "icon"), widestSymbol: AudioMonitor.widestIcon)]),
                                         keepsLineHeight: true)

    /// Whether the slider opens before the icon: on the right of the bar, which grows to the left.
    static func opensBeforeIcon(_ position: WidgetPosition) -> Bool { position == .right }

    var body: some View {
        let volume = store.scripts[widget.id]?.output.values?["volume"]
        let expanded = volume != nil && store.presentations[widget.id]?.expandedDisplays.contains(monitor) == true
        let appearance = WidgetAppearance(style.inherited, defaults: WidgetStyle())
        Group {
            if let volume {
                HoverExpansionLayout(expansion: expanded ? 1 : 0, spacing: appearance.spacing, controlsBefore: Self.opensBeforeIcon(widget.position)) {
                    slider(volume, appearance: appearance)
                        .allowsHitTesting(expanded)
                        .accessibilityHidden(!expanded)
                    WidgetBlocks(widget: widget, store: store, style: style, block: expanded ? Self.icon : nil, motion: motion, runAction: runAction)
                }
                .clipped()
            } else {
                WidgetBlocks(widget: widget, store: store, style: style, motion: motion, runAction: runAction)
            }
        }
        .onChange(of: hovered || dragging) { _, open in expand(open) }
        .onDisappear { expand(false) }
    }

    private func expand(_ open: Bool) {
        guard !measuring else { return }
        store.presentations[widget.id]?.setExpanded(open, on: monitor, animation: reduceMotion ? nil : motion.animation)
    }

    private func slider(_ volume: Double, appearance: WidgetAppearance) -> some View {
        let shown = level ?? volume
        return HStack(spacing: appearance.spacing) {
            // A line of text tall, so opening the slider doesn't make the widget taller.
            Text(" ").hidden().frame(width: 72).overlay {
                Slider(value: Binding(get: { shown }, set: { set($0) }), in: 0...1) { editing in
                    dragging = editing
                    if !editing { level = nil }
                }
                .controlSize(.mini)
                .tint(appearance.accent)
                .accessibilityLabel("Volume")
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
    }

    private func set(_ volume: Double) {
        level = volume
        do {
            try AudioMonitor.setVolume(volume)
            if store.actionErrors[widget.id] != nil { store.actionErrors[widget.id] = nil }
        } catch {
            store.actionErrors[widget.id] = error.localizedDescription
        }
    }
}
