import AppKit
import SwiftUI

/// The icons in StableBar's own menus, the menu-bar icon's menu and the bar's right-click menu, matching the symbols
/// of the same places in Settings.
enum MenuIcon: String {
    case editBar = "pencil"
    case finishEditing = "checkmark.circle"
    case themes = "paintpalette"
    case setup = "sparkles"
    case help = "questionmark.circle"
    case feedback = "text.bubble"
    case updates = "arrow.down.circle"
    case problem = "exclamationmark.triangle.fill"
    case settings = "gearshape"
    case quit = "power"

    var image: NSImage? {
        guard let image = NSImage(systemSymbolName: rawValue, accessibilityDescription: nil) else { return nil }
        guard self == .problem else { return image }
        // A menu draws a template image in its text colour; the warning keeps its own.
        let colored = image.withSymbolConfiguration(.init(paletteColors: [.systemOrange]))
        colored?.isTemplate = false
        return colored
    }

    /// SwiftUI menus draw a symbol in their text colour too, so the warning goes through its `NSImage`.
    var menuImage: Image {
        guard self == .problem, let image else { return Image(systemName: rawValue) }
        return Image(nsImage: image)
    }

    /// The lighthouse from the menu bar, beside the menus' StableBar heading.
    static var heading: NSImage? {
        guard let image = NSImage(named: "StatusBarIconTemplate")?.copy() as? NSImage else { return nil }
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}
