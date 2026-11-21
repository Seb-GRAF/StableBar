import SwiftUI

struct MenuBarItemsView: View {
    let widget: WidgetConfiguration
    let store: BarStore
    let display: Int
    let defaults: WidgetStyle
    let rightClickInMenuBar: Bool
    let appearance: WidgetAppearance
    let padding: EdgeInsets
    let symbol: String
    let toggleRow: (NSView) -> Void
    let hoverRow: (Bool, NSView) -> Void

    var body: some View {
        let shown = widget.shownMenuBarItems
        let openAnchor = store.barPresentation.presentations[widget.id]?.popupAnchor
        HStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.offset) { position, entry in
                switch entry {
                case .symbol:
                    MenuBarItemCell(appearance: appearance, padding: padding, openAnchor: openAnchor, click: toggleRow) { anchor, inside in
                        if inside, switches(to: anchor) { toggleRow(anchor) }
                        hoverRow(inside, anchor)
                    } label: {
                        Image(systemName: symbol).font(.system(size: appearance.iconSize))
                    }
                    .accessibilityLabel("Menu bar items")
                    .contextMenu { symbolCommands(position, count: shown.count) }
                case let .item(reference):
                    ForEach(Array(store.appMenu.menuBarItems.filter(reference.matches).enumerated()), id: \.offset) { _, item in
                        itemCell(item, icon: reference.icon, live: reference.display == .live ? store.appMenu.mirror.images[item.key] : nil,
                                 openAnchor: openAnchor)
                    }
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .onHover { if $0 { Task { await store.appMenu.readMenuBarItems(requestingAccess: false) } } }
    }

    private func itemCell(_ item: MenuBarItem, icon: String?, live: MenuBarItemImage?, openAnchor: ObjectIdentifier?) -> some View {
        MenuBarItemCell(appearance: appearance, padding: padding, openAnchor: openAnchor, actsOnMouseDown: !item.entry.hasSubmenu,
                        rightClick: { anchor in rightClick(item, anchor: anchor) }) { anchor in
            open(item, anchor: anchor)
        } hover: { anchor, inside in
            if inside, switches(to: anchor) {
                if item.entry.hasSubmenu { open(item, anchor: anchor) } else { store.popup.close() }
            }
            store.popup.hover(inside, store: store, anchor: anchor) {
                store.popup.showTooltip(item.entry.title, widget: widget, defaults: defaults, store: store, anchor: anchor)
            }
        } label: {
            if let live {
                // As tall as an icon to the layout, so the item's own height, the menu bar's, doesn't stretch the bar.
                Color.clear.frame(width: live.image.size.width, height: appearance.iconSize)
                    .overlay { Image(nsImage: live.image).fixedSize() }
            } else if let icon {
                Image(systemName: icon).font(.system(size: appearance.iconSize))
            } else {
                Image(nsImage: item.entry.icon!).resizable().scaledToFit().frame(height: appearance.iconSize)
                    .styledAppIcon(item.entry.icon!.isTemplate ? .color : appearance.appIcons, color: appearance.foreground)
            }
        }
        .accessibilityLabel(item.entry.title)
    }

    /// The grid symbol's menu takes the place of the widget's, so it ends with the widget's commands.
    @ViewBuilder private func symbolCommands(_ position: Int, count: Int) -> some View {
        MenuBarItemCommands(source: .shown(position), shownCount: count, isSymbol: true) { placement, index in
            store.widgetScripts.move(.shown(position), to: placement, before: index, in: widget)
        }
        WidgetContextMenu(widget: widget, store: store, display: display, dividerAbove: true)
    }

    private func switches(to anchor: NSView) -> Bool {
        let openAnchor = store.barPresentation.presentations[widget.id]?.popupAnchor
        return openAnchor != nil && openAnchor != ObjectIdentifier(anchor) && store.popup.pinned
    }

    private func open(_ item: MenuBarItem, anchor: NSView) {
        if item.entry.hasSubmenu {
            store.popup.toggle(store.appMenu.popup(forMenuBarItem: item.entry.element), widget: widget, defaults: defaults, store: store, anchor: anchor)
        } else if store.barEditing.allowsWidgetActions {
            store.popup.close()
            store.appMenu.pressUnlessOpen(item.entry)
        }
    }

    /// An item whose menu the bar draws opens it, as on a click. With `rightClickInMenuBar`, any other item gets the
    /// right-click itself, which some apps, such as MeetingBar, give an action of their own; without it, a click.
    private func rightClick(_ item: MenuBarItem, anchor: NSView) {
        if item.entry.hasSubmenu || !rightClickInMenuBar {
            open(item, anchor: anchor)
        } else if store.barEditing.allowsWidgetActions {
            store.popup.close()
            store.appMenu.rightClick(item.entry)
        }
    }
}

struct MenuBarItemCommands: View {
    let source: MenuBarItemSource
    let shownCount: Int
    let isSymbol: Bool
    let move: (MenuBarItemPlacement, Int?) -> Void

    var body: some View {
        if case let .shown(position) = source {
            Button("Move Left") { move(.bar, position - 1) }.disabled(position == 0)
            Button("Move Right") { move(.bar, position + 2) }.disabled(position == shownCount - 1)
            Divider()
        }
        if source.placement != .bar { Button("Show on Bar") { move(.bar, nil) } }
        if source.placement != .row && !isSymbol { Button("Move to Row") { move(.row, nil) } }
        if source.placement != .hidden { Button("Hide") { move(.hidden, nil) } }
    }
}

private struct MenuBarItemCell<Label: View>: View {
    let appearance: WidgetAppearance
    let padding: EdgeInsets
    let openAnchor: ObjectIdentifier?
    var actsOnMouseDown = false
    /// Runs on a right-click instead of opening the menu around the cell.
    var rightClick: ((NSView) -> Void)?
    let click: (NSView) -> Void
    let hover: (NSView, Bool) -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovered = false
    @State private var anchor = NSView()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let highlighted = openAnchor.map { $0 == ObjectIdentifier(anchor) } ?? hovered
        let button = Button { click(anchor) } label: {
            ZStack {
                Text(" ").hidden()
                label()
            }
            .padding(.horizontal, 7)
            .padding(padding)
            .background {
                if highlighted { RoundedRectangle(cornerRadius: max(appearance.cornerRadius - 4, 0)).fill(appearance.hoverBackground) }
            }
            .background(MenuAnchor(view: anchor))
            .contentShape(Rectangle())
        }
        Group {
            if actsOnMouseDown { button.buttonStyle(MouseDownButtonStyle()) } else { button.buttonStyle(.plain) }
        }
        .overlay { if let rightClick { RightClickCapture { rightClick(anchor) } } }
        .animation(hoverAnimation(highlighted, reduceMotion: reduceMotion), value: highlighted)
        .onHover { inside in
            hovered = inside
            hover(anchor, inside)
        }
    }
}

struct MouseDownButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: PrimitiveButtonStyleConfiguration) -> some View {
        configuration.label.onLongPressGesture(minimumDuration: 0, perform: {}) { pressing in
            if pressing { configuration.trigger() }
        }
    }
}

/// Runs `action` on a right-click over the view, in place of the menu around it.
private struct RightClickCapture: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> RightClickView { RightClickView(action: action) }
    func updateNSView(_ nsView: RightClickView, context: Context) { nsView.action = action }
}

final class RightClickView: NSView {
    var action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("RightClickView is created programmatically.") }

    // Only a right-click stops here; every other event goes on to the SwiftUI view beneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        NSApp?.currentEvent?.type == .rightMouseDown ? super.hitTest(point) : nil
    }

    override func rightMouseDown(with event: NSEvent) { action() }
}
