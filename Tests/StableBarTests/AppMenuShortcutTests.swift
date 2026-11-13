import ApplicationServices
import Foundation
import Testing
@testable import StableBar

// The values below are what Accessibility returned for real menus on macOS 27.2: Finder, Terminal, Chrome,
// Spotify, Ghostty and PhpStorm.

@Test(arguments: [
    (0, MenuShortcut(modifiers: "⌘", key: "Q")),
    (1, MenuShortcut(modifiers: "⇧⌘", key: "Q")),
    (2, MenuShortcut(modifiers: "⌥⌘", key: "Q")),
    (3, MenuShortcut(modifiers: "⌥⇧⌘", key: "Q")),
    (4, MenuShortcut(modifiers: "⌃⌘", key: "Q")),
    (7, MenuShortcut(modifiers: "⌃⌥⇧⌘", key: "Q")),
    (8, MenuShortcut(modifiers: "", key: "Q")),
    (12, MenuShortcut(modifiers: "⌃", key: "Q")),
    (20, MenuShortcut(function: true, modifiers: "⌃⌘", key: "Q")),
    (24, MenuShortcut(function: true, modifiers: "", key: "Q")),
    (28, MenuShortcut(function: true, modifiers: "⌃", key: "Q")),
])
func menuShortcutShowsItsModifiersInTheOrderMacOSMenusDo(modifiers: Int, shortcut: MenuShortcut) {
    #expect(MenuShortcut(character: "Q", virtualKey: nil, glyph: nil, modifiers: modifiers) == shortcut)
}

@Test(arguments: [
    ("\u{F700}", 126, 104, "↑"),
    ("\u{F701}", 125, 106, "↓"),
    ("\u{F702}", 123, 100, "←"),
    ("\u{F703}", 124, 101, "→"),
    ("\u{8}", 51, 23, "⌫"),
    ("\u{7F}", 117, 10, "⌦"),
    ("\u{238B}", 53, 27, "⎋"),
    ("\u{2327}", 53, 28, "⌧"),
    ("\r", 36, 11, "↩"),
    // Return in a right-to-left script, as Carbon's kMenuReturnR2LGlyph.
    ("\r", 36, 12, "↪"),
    ("\t", 48, 2, "⇥"),
    (" ", 49, 9, "Space"),
    ("\u{F729}", 115, 102, "↖"),
    ("\u{F72B}", 119, 105, "↘"),
    ("\u{F72C}", 116, 98, "⇞"),
    ("\u{F72D}", 121, 107, "⇟"),
    ("\u{F704}", 122, 111, "F1"),
    ("\u{F708}", 96, 115, "F5"),
    ("\u{F70F}", 111, 122, "F12"),
] as [(String?, Int?, Int?, String)])
func menuShortcutNamesKeysWithoutACharacter(character: String?, virtualKey: Int?, glyph: Int?, key: String) {
    #expect(MenuShortcut(character: character, virtualKey: virtualKey, glyph: glyph, modifiers: 0)
        == MenuShortcut(modifiers: "⌘", key: key))
}

/// Finder's Window → Move & Resize items give only a virtual key code.
@Test(arguments: [(123, "←"), (124, "→"), (125, "↓"), (126, "↑"), (122, "F1"), (36, "↩")])
func menuShortcutNamesAKeyFromItsVirtualKeyAlone(virtualKey: Int, key: String) {
    #expect(MenuShortcut(character: nil, virtualKey: virtualKey, glyph: nil, modifiers: 28)
        == MenuShortcut(function: true, modifiers: "⌃", key: key))
}

@Test func menuShortcutKeepsTheCharacterOfTheKeyboardLayout() {
    #expect(MenuShortcut(character: "É", virtualKey: nil, glyph: nil, modifiers: 0) == MenuShortcut(modifiers: "⌘", key: "É"))
    #expect(MenuShortcut(character: ",", virtualKey: nil, glyph: nil, modifiers: 0) == MenuShortcut(modifiers: "⌘", key: ","))
}

@Test func menuShortcutShowsDictationAndEmojiKeysAsSymbols() {
    #expect(MenuShortcut(character: "🎤", virtualKey: 128, glyph: 150, modifiers: 8)
        == MenuShortcut(modifiers: "", key: "🎤", keySymbol: "mic.fill"))
    #expect(MenuShortcut(character: "🌐", virtualKey: 128, glyph: 149, modifiers: 8)
        == MenuShortcut(modifiers: "", key: "🌐", keySymbol: "globe"))
}

@Test(arguments: [
    (nil, nil, nil, 8),
    (nil, nil, nil, 0),
    ("", nil, nil, 0),
    ("\u{F7FF}", nil, nil, 0),
    ("\u{1}", nil, nil, 0),
] as [(String?, Int?, Int?, Int)])
func menuShortcutIsNilWithoutAKeyToShow(character: String?, virtualKey: Int?, glyph: Int?, modifiers: Int) {
    #expect(MenuShortcut(character: character, virtualKey: virtualKey, glyph: glyph, modifiers: modifiers) == nil)
}

/// A menu bar title, its menu and the menu's items, answering Accessibility reads by process ID, as
/// `AXUIElementCreateApplication` elements carry one.
private final class MenuTree: @unchecked Sendable {
    static let title: pid_t = 40
    static let menu: pid_t = 41
    private let lock = NSLock()
    private var attributes: [pid_t: [String: CFTypeRef]] = [:]
    private var singleReads: [pid_t] = []
    private var batchReads: [pid_t] = []

    init(items: [[String: CFTypeRef]]) {
        let rows = items.indices.map { pid_t(50 + $0) }
        attributes[Self.title] = [kAXChildrenAttribute: [AXUIElementCreateApplication(Self.menu)] as CFArray]
        attributes[Self.menu] = [kAXRoleAttribute: kAXMenuRole as CFString,
                                 kAXChildrenAttribute: rows.map(AXUIElementCreateApplication) as CFArray]
        for (row, item) in zip(rows, items) { attributes[row] = item }
    }

    var rowsReadOneAttributeAtATime: [pid_t] { lock.withLock { singleReads.filter { $0 >= 50 } } }
    var rowsReadTogether: [pid_t] { lock.withLock { batchReads } }

    func read(_ name: String, _ element: AXUIElement) -> CFTypeRef? {
        let pid = pid(of: element)
        return lock.withLock {
            singleReads.append(pid)
            return attributes[pid]?[name]
        }
    }

    func readAll(_ names: [String], _ element: AXUIElement) -> [CFTypeRef?] {
        let pid = pid(of: element)
        return lock.withLock {
            batchReads.append(pid)
            return names.map { attributes[pid]?[$0] }
        }
    }

    private func pid(of element: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return pid
    }
}

private func item(_ title: String, key: String? = nil, virtualKey: Int? = nil, glyph: Int? = nil, modifiers: Int = 0,
                  enabled: Bool = true) -> [String: CFTypeRef] {
    var item: [String: CFTypeRef] = [kAXTitleAttribute: title as CFString, kAXEnabledAttribute: enabled as CFBoolean,
                                     kAXMenuItemCmdModifiersAttribute: modifiers as CFNumber]
    if let key { item[kAXMenuItemCmdCharAttribute] = key as CFString }
    if let virtualKey { item[kAXMenuItemCmdVirtualKeyAttribute] = virtualKey as CFNumber }
    if let glyph { item[kAXMenuItemCmdGlyphAttribute] = glyph as CFNumber }
    return item
}

@MainActor private func entries(_ tree: MenuTree) throws -> [AppMenuEntry] {
    let menu = AppMenu(checkAccess: { true }, readAttribute: tree.read, readAttributes: tree.readAll)
    guard case let .appMenu(entries) = menu.popup(forMenuBarItem: AXUIElementCreateApplication(MenuTree.title)).layout.content else {
        Issue.record("The popup isn't an app menu")
        return []
    }
    return entries
}

@Test @MainActor func appMenuEntriesShowEachItemsShortcut() throws {
    let tree = MenuTree(items: [
        item("New Folder", key: "N", modifiers: 1),
        item("Enclosing Folder", key: "\u{F700}", virtualKey: 126, glyph: 104),
        item("Fill", key: "F", modifiers: 28),
        item("Left", virtualKey: 123, modifiers: 28),
        item("Get Info"),
        item("Print", key: "P", enabled: false),
    ])
    let entries = try entries(tree)
    #expect(entries.map(\.title) == ["New Folder", "Enclosing Folder", "Fill", "Left", "Get Info", "Print"])
    #expect(entries.map(\.shortcut) == [
        MenuShortcut(modifiers: "⇧⌘", key: "N"),
        MenuShortcut(modifiers: "⌘", key: "↑"),
        MenuShortcut(function: true, modifiers: "⌃", key: "F"),
        MenuShortcut(function: true, modifiers: "⌃", key: "←"),
        nil,
        MenuShortcut(modifiers: "⌘", key: "P"),
    ])
    #expect(entries.map(\.isEnabled) == [true, true, true, true, true, false])
}

// Each Accessibility call is a round trip to the app, and Chromium apps answer slowly: Chrome's File menu took
// 16 ms with four reads per item, 37 ms with the shortcut's four more, and 13 ms with all eight in one call.
@Test @MainActor func appMenuReadsEachItemInOneCall() throws {
    let tree = MenuTree(items: [item("New Window", key: "N"), item("Close Window", key: "W"), item("Get Info")])
    let entries = try entries(tree)
    #expect(entries.count == 3)
    #expect(tree.rowsReadTogether == [50, 51, 52])
    #expect(tree.rowsReadOneAttributeAtATime.isEmpty)
}
