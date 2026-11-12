import AppKit

/// StableBar shows no menu bar, but AppKit still sends ⌘X, ⌘C, ⌘V and ⌘A to text fields, and ⌘W to the key
/// window, through the main menu's key equivalents. ⌘Z stays with the Undo and Redo buttons in Settings.
enum EditMenu {
    @MainActor static func make() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        item.submenu = edit
        let menu = NSMenu()
        menu.addItem(item)
        return menu
    }
}
