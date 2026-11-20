import SwiftUI

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
    @FocusState private var focused: Bool
    @State private var anchor = NSView()

    var body: some View {
        Button { click(anchor) } label: {
            Image(nsImage: entry.icon!).resizable().scaledToFit().frame(width: 18, height: 18)
                .styledAppIcon(entry.icon!.isTemplate ? .color : appearance.appIcons, color: appearance.foreground)
                .padding(5)
                .background(hovered || openAnchor == ObjectIdentifier(anchor) ? appearance.hoverBackground : AnyShapeStyle(Color.clear),
                            in: RoundedRectangle(cornerRadius: max(appearance.cornerRadius - 4, 0)))
                .overlay { if focused { FocusRingShape(shape: RoundedRectangle(cornerRadius: max(appearance.cornerRadius - 4, 0)), outset: 0) } }
                .background(MenuAnchor(view: anchor))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .accessibilityLabel(entry.title)
        .onHover { inside in
            hovered = inside
            hover(anchor, inside)
        }
    }
}
