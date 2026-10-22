import SwiftUI

struct HoverLayoutView<Content: View>: View {
    let widget: WidgetConfiguration
    let layout: PopupBlock
    let store: BarStore
    let monitor: Int
    let style: LayoutStyle
    let hovered: Bool
    let motion: BlockMotion
    let runAction: (String, [String: String]) -> Void
    @ViewBuilder let content: () -> Content
    @State private var editing = false
    @Environment(\.measuringBarWidths) private var measuring
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let expanded = store.presentations[widget.id]?.expandedDisplays.contains(monitor) == true
        let appearance = WidgetAppearance(style.inherited, defaults: WidgetStyle())
        HoverExpansionLayout(expansion: expanded ? 1 : 0, spacing: appearance.spacing, controlsBefore: widget.position == .right) {
            controls
                .allowsHitTesting(expanded)
                .accessibilityHidden(!expanded)
            content()
        }
        .clipped()
        .onPreferenceChange(ControlEditingPreference.self) { editing = $0 }
        .onChange(of: hovered || editing) { _, open in expand(open) }
        .onDisappear { expand(false) }
    }

    private var controls: some View {
        WidgetBlocks(widget: widget, store: store, style: style, block: layout, motion: motion, runAction: runAction)
            .controlSize(.mini)
            .labelsHidden()
    }

    private func expand(_ open: Bool) {
        guard !measuring else { return }
        store.presentations[widget.id]?.setExpanded(open, on: monitor, animation: reduceMotion ? nil : motion.animation)
    }
}
