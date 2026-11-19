import SwiftUI

struct AppMenuList: View {
    let entries: [AppMenuEntry]
    let appearance: WidgetAppearance
    let openSubmenu: (AXUIElement?, NSView) -> Void
    let press: (AppMenuEntry) -> Void
    @State private var submenu: AXUIElement?
    @State private var keyWidth: CGFloat = 0
    @State private var optionHeld = false
    @State private var flagsMonitor: Any?

    var body: some View {
        let rows = rows
        let checks = rows.contains(where: \.isChecked)
        let iconColumns = iconColumns(rows)
        let iconWidth = rows.compactMap(\.icon).map(\.size.width).max() ?? 0
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, entry in
                if entry.title.isEmpty {
                    Rectangle().fill(appearance.foreground.opacity(0.12)).frame(height: 1).padding(.vertical, 4)
                } else {
                    AppMenuRow(entry: entry, checks: checks, iconColumn: iconColumns.contains(index), iconWidth: iconWidth, keyWidth: keyWidth,
                               appearance: appearance, open: submenu == entry.element) { row in
                        guard submenu != entry.element else { return }
                        let opens = entry.hasSubmenu && entry.isEnabled
                        submenu = opens ? entry.element : nil
                        openSubmenu(opens ? entry.element : nil, row)
                    } press: {
                        press(entry)
                    }
                }
            }
        }
        .onPreferenceChange(MenuKeyWidth.self) { keyWidth = $0 }
        .onAppear {
            optionHeld = NSEvent.modifierFlags.contains(.option)
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                optionHeld = event.modifierFlags.contains(.option)
                return event
            }
        }
        .onDisappear {
            if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        }
    }

    /// The entries the menu shows: each alternate takes the place of the entry before it while Option is held.
    private var rows: [AppMenuEntry] {
        var rows: [AppMenuEntry] = []
        for entry in entries {
            if !entry.isAlternate {
                rows.append(entry)
            } else if optionHeld {
                rows[rows.count - 1] = entry
            }
        }
        return rows
    }

    /// The entries whose titles line up after an icon column. As in macOS 27 menus, a section, the entries between two
    /// separators, gets the column when more than half of its entries have an icon; otherwise titles without one start
    /// where icons do.
    private func iconColumns(_ rows: [AppMenuEntry]) -> Set<Int> {
        var indices = Set<Int>()
        for section in rows.split(whereSeparator: { $0.title.isEmpty }) where section.filter({ $0.icon != nil }).count * 2 > section.count {
            indices.formUnion(section.indices)
        }
        return indices
    }
}

/// The width of a menu's widest shortcut key, which sets the width of the column the keys line up in.
private struct MenuKeyWidth: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct AppMenuRow: View {
    let entry: AppMenuEntry
    let checks: Bool
    let iconColumn: Bool
    let iconWidth: CGFloat
    let keyWidth: CGFloat
    let appearance: WidgetAppearance
    let open: Bool
    let rest: (NSView) -> Void
    let press: () -> Void
    @State private var hovered = false
    @FocusState private var focused: Bool
    @State private var anchor = NSView()

    var body: some View {
        Group {
            // Tab skips a disabled entry. `focusable(true)` would give an enabled one a second stop.
            if entry.isEnabled { button } else { button.focusable(false) }
        }
        .focused($focused)
        .opacity(entry.isEnabled ? 1 : 0.4)
        .onHover { hovered = $0 }
        .task(id: hovered) {
            guard hovered, (try? await Task.sleep(for: .milliseconds(200))) != nil else { return }
            rest(anchor)
        }
        .onChange(of: entry.element) { if hovered { rest(anchor) } }
    }

    private var button: some View {
        Button {
            if entry.hasSubmenu { rest(anchor) } else if entry.isEnabled { press() }
        } label: {
            HStack(spacing: 4) {
                if checks {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).frame(width: 15, alignment: .leading)
                        .opacity(entry.isChecked ? 1 : 0)
                }
                // As in macOS 27 menus: icons centered in a slot as wide as the menu's widest, which starts 2.5 points
                // before titles without an icon and ends 5 points before titles with one.
                if entry.icon != nil || iconColumn {
                    ZStack { if let icon = entry.icon { Image(nsImage: icon) } }
                        .frame(width: iconWidth)
                        .padding(.leading, -2.5)
                        .padding(.trailing, 1)
                }
                Text(entry.title).lineLimit(1)
                Spacer(minLength: 8)
                if let shortcut = entry.shortcut {
                    MenuShortcutLabel(shortcut: shortcut, keyWidth: keyWidth)
                        .foregroundStyle(appearance.foreground.opacity(0.5))
                        .fixedSize()
                        .layoutPriority(1)
                }
                if entry.hasSubmenu { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).frame(minWidth: keyWidth) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background((hovered || open) && entry.isEnabled ? appearance.hoverBackground : AnyShapeStyle(Color.clear),
                        in: RoundedRectangle(cornerRadius: max(appearance.cornerRadius - 4, 0)))
            .overlay { if focused { FocusRingShape(shape: RoundedRectangle(cornerRadius: max(appearance.cornerRadius - 4, 0)), outset: 0) } }
            .background(MenuAnchor(view: anchor))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A shortcut as macOS menus show it: 🌐 for fn and the modifiers, then the key centered in a column as wide as the
/// menu's widest key, so the modifiers end at the same place on every row. Submenu chevrons center in the same column.
private struct MenuShortcutLabel: View {
    let shortcut: MenuShortcut
    let keyWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            if shortcut.function { Image(systemName: "globe").imageScale(.small) }
            Text(shortcut.modifiers)
            key
                .background(GeometryReader { Color.clear.preference(key: MenuKeyWidth.self, value: $0.size.width) })
                .frame(minWidth: keyWidth)
        }
    }

    @ViewBuilder private var key: some View {
        if let symbol = shortcut.keySymbol { Image(systemName: symbol) } else { Text(shortcut.key) }
    }
}
