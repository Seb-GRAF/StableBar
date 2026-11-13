/// A menu item's keyboard shortcut as macOS menus show it, read from the item's Accessibility attributes.
struct MenuShortcut: Hashable, Sendable {
    /// Whether the shortcut holds fn, which macOS menus show as 🌐.
    var function = false
    /// ⌃, ⌥, ⇧ and ⌘, in the order macOS menus show them.
    let modifiers: String
    /// The key: its character, its symbol such as ↩ or ←, or its name such as F5 or Space.
    let key: String
    /// An SF Symbol drawn in place of `key`, for a key whose character isn't a menu glyph, such as dictation's 🎤.
    var keySymbol: String? = nil
}

extension MenuShortcut {
    /// The shortcut that `AXMenuItemCmdChar`, `AXMenuItemCmdVirtualKey`, `AXMenuItemCmdGlyph` and
    /// `AXMenuItemCmdModifiers` describe, or nil when they name no key that can be shown.
    ///
    /// A key without a character, such as ↑ or F5, comes with the glyph a menu draws for it and its virtual key code,
    /// and its character is a control or private-use character that can't be shown as is. Some items, such as
    /// Finder's Window → Move & Resize ones, give only the virtual key code.
    init?(character: String?, virtualKey: Int?, glyph: Int?, modifiers: Int) {
        if let symbol = glyph.flatMap({ Self.glyphSymbols[$0] }) {
            key = character ?? ""
            keySymbol = symbol
        } else if let key = glyph.flatMap({ Self.glyphKeys[$0] }) ?? virtualKey.flatMap({ Self.virtualKeys[$0] })
                    ?? character.flatMap(Self.shown) {
            self.key = key
        } else {
            return nil
        }
        function = modifiers & Modifier.function != 0
        var symbols = ""
        if modifiers & Modifier.control != 0 { symbols += "⌃" }
        if modifiers & Modifier.option != 0 { symbols += "⌥" }
        if modifiers & Modifier.shift != 0 { symbols += "⇧" }
        if modifiers & Modifier.noCommand == 0 { symbols += "⌘" }
        self.modifiers = symbols
    }

    /// The flags of `AXMenuItemCmdModifiers`, which hold ⌘ unless they say otherwise. The headers name the first four
    /// as `kAXMenuItemModifierShift` and so on, which Swift doesn't import. They don't name fn, but menus give 16
    /// with it: Finder's Window → Fill reads 28, which its menu shows as 🌐⌃F.
    private enum Modifier {
        static let shift = 1, option = 2, control = 4, noCommand = 8, function = 16
    }

    /// `character` when a menu can draw it: not empty, and neither a control character nor a private-use one,
    /// which AppKit uses for keys such as the arrows and F-keys.
    private static func shown(_ character: String) -> String? {
        if character == " " { return "Space" }
        let hidden = character.unicodeScalars.contains {
            [.control, .privateUse, .format, .surrogate, .unassigned].contains($0.properties.generalCategory)
        }
        return character.isEmpty || hidden ? nil : character
    }

    /// The menu glyph codes of keys without a character, as Carbon's Menus.h numbers them.
    private static let glyphKeys: [Int: String] = [
        2: "⇥", 3: "⇤", 4: "⌤", 9: "Space", 10: "⌦", 11: "↩", 12: "↪", 13: "↩", 23: "⌫", 27: "⎋", 28: "⌧",
        98: "⇞", 99: "⇪", 100: "←", 101: "→", 102: "↖", 104: "↑", 105: "↘", 106: "↓", 107: "⇟",
        111: "F1", 112: "F2", 113: "F3", 114: "F4", 115: "F5", 116: "F6", 117: "F7", 118: "F8", 119: "F9", 120: "F10",
        121: "F11", 122: "F12", 135: "F13", 136: "F14", 137: "F15", 140: "⏏", 143: "F16", 144: "F17", 145: "F18", 146: "F19",
    ]

    /// Glyphs a menu draws as a picture rather than a character: 149 is Emoji & Symbols' 🌐 and 150 dictation's microphone.
    private static let glyphSymbols: [Int: String] = [149: "globe", 150: "mic.fill"]

    /// Keys without a character by virtual key code, as Carbon's Events.h numbers them.
    private static let virtualKeys: [Int: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 71: "⌧", 76: "⌤", 117: "⌦",
        115: "↖", 116: "⇞", 119: "↘", 121: "⇟", 123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]
}
