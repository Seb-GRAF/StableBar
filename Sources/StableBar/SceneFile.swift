import Foundation

/// One screen to draw offscreen: a configuration, the sample data its widgets show, and what to draw.
/// `StableBar --render-scenes` reads these from `scenes/`, and scene.schema.json describes them. A scene
/// runs nothing: commands, providers and window managers are replaced by the samples it gives.
struct SceneFile: Decodable {
    enum Draw: String, Decodable, CaseIterable { case bar, editBar, popup, settings, uninstall, update }
    enum Appearance: String, Decodable, CaseIterable { case dark, light }
    /// A Settings section, named as the toolbar names it.
    enum Section: String, Decodable, CaseIterable { case general, bar, theme, profiles, packages }
    enum Tab: String, Decodable, CaseIterable { case content, style, behavior }
    /// The Uninstall sheet's confirmation, or the steps that failed before StableBar quits.
    enum Uninstall: String, Decodable, CaseIterable { case confirm, failed }
    /// The configuration inline, or the path of a configuration file relative to the scene file.
    enum Configuration: Equatable { case inline([String: ConfigurationValue]), file(String) }

    var configuration: Configuration
    /// Script outputs keyed by widget id or provider name: an object as a script prints it, or plain text.
    var outputs: [String: ConfigurationValue] = [:]
    /// Graph samples keyed by widget id or provider name.
    var history: [String: [Double]] = [:]
    /// AeroSpace's `list-workspaces --json` objects.
    var workspaces: [ConfigurationValue]?
    /// AeroSpace's `list-windows --json` objects.
    var windows: [ConfigurationValue]?
    /// The bundle identifier of the active app, Finder by default.
    var activeApp: String?
    /// The menu a popup scene shows in place of the widget's popup, as an app menu widget opens one.
    var menu: [MenuItem]?
    var draw: Draw
    /// The widget whose popup or Settings page to draw.
    var widget: String?
    /// The Settings section to draw when no widget is named.
    var section: Section?
    /// The tab of the widget's Settings page.
    var tab: Tab?
    /// What the Uninstall sheet shows, for `uninstall`.
    var uninstall: Uninstall?
    var appearances: [Appearance] = Appearance.allCases
    var width: Double?
    var height: Double?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case configuration, outputs, history, workspaces, windows, activeApp, menu, draw, widget, section, tab, uninstall, appearances, width, height
    }

    /// An item of a sample menu, with the values Accessibility gives a menu item. An empty title is a separator.
    struct MenuItem: Equatable {
        var title: String
        /// `AXMenuItemCmdChar`: the shortcut's character.
        var key: String?
        /// `AXMenuItemCmdVirtualKey`: the virtual key code of a key without a character.
        var virtualKey: Int?
        /// `AXMenuItemCmdGlyph`: the menu glyph of a key without a character.
        var glyph: Int?
        /// `AXMenuItemCmdModifiers`: 0 is ⌘ alone, then 1 adds ⇧, 2 ⌥, 4 ⌃, 8 removes ⌘ and 16 adds fn.
        var modifiers = 0
        var enabled = true
        var checked = false
        var submenu = false
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self, allowing: ["$schema"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let path = try? values.decode(String.self, forKey: .configuration) {
            configuration = .file(path)
        } else {
            configuration = .inline(try values.decode([String: ConfigurationValue].self, forKey: .configuration))
        }
        outputs = try values.decodeIfPresent([String: ConfigurationValue].self, forKey: .outputs) ?? [:]
        history = try values.decodeIfPresent([String: [Double]].self, forKey: .history) ?? [:]
        workspaces = try values.decodeIfPresent([ConfigurationValue].self, forKey: .workspaces)
        windows = try values.decodeIfPresent([ConfigurationValue].self, forKey: .windows)
        activeApp = try values.decodeIfPresent(String.self, forKey: .activeApp)
        menu = try values.decodeIfPresent([MenuItem].self, forKey: .menu)
        draw = try values.decode(Draw.self, forKey: .draw)
        widget = try values.decodeIfPresent(String.self, forKey: .widget)
        section = try values.decodeIfPresent(Section.self, forKey: .section)
        tab = try values.decodeIfPresent(Tab.self, forKey: .tab)
        uninstall = try values.decodeIfPresent(Uninstall.self, forKey: .uninstall)
        appearances = try values.decodeIfPresent([Appearance].self, forKey: .appearances) ?? Appearance.allCases
        if appearances.isEmpty || Set(appearances).count != appearances.count {
            throw DecodingError.dataCorruptedError(forKey: .appearances, in: values,
                                                   debugDescription: "Appearances name dark, light or both, each once.")
        }
        width = try values.decodeIfPresent(Double.self, forKey: .width)
        height = try values.decodeIfPresent(Double.self, forKey: .height)
        if let width, !(100...4000).contains(width) {
            throw DecodingError.dataCorruptedError(forKey: .width, in: values, debugDescription: "A width is 100 to 4000 points.")
        }
        if let height, !(20...4000).contains(height) {
            throw DecodingError.dataCorruptedError(forKey: .height, in: values, debugDescription: "A height is 20 to 4000 points.")
        }
        if draw == .popup, widget == nil {
            throw DecodingError.dataCorruptedError(forKey: .widget, in: values, debugDescription: "A popup scene names its widget.")
        }
        if draw == .settings, widget == nil, section == nil {
            throw DecodingError.dataCorruptedError(forKey: .section, in: values,
                                                   debugDescription: "A settings scene names a widget or a section.")
        }
        if menu != nil, draw != .popup {
            throw DecodingError.dataCorruptedError(forKey: .menu, in: values, debugDescription: "A menu belongs to a popup scene.")
        }
        if uninstall != nil, draw != .uninstall {
            throw DecodingError.dataCorruptedError(forKey: .uninstall, in: values, debugDescription: "uninstall belongs to an uninstall scene.")
        }
        if tab != nil, widget == nil {
            throw DecodingError.dataCorruptedError(forKey: .tab, in: values, debugDescription: "A tab belongs to a widget's Settings page.")
        }
    }

    static func read(_ url: URL) throws -> SceneFile {
        try JSONDecoder().decode(SceneFile.self, from: Data(contentsOf: url))
    }
}

extension SceneFile.MenuItem: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable { case title, key, virtualKey, glyph, modifiers, enabled, checked, submenu }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        title = try values.decode(String.self, forKey: .title)
        key = try values.decodeIfPresent(String.self, forKey: .key)
        virtualKey = try values.decodeIfPresent(Int.self, forKey: .virtualKey)
        glyph = try values.decodeIfPresent(Int.self, forKey: .glyph)
        modifiers = try values.decodeIfPresent(Int.self, forKey: .modifiers) ?? 0
        if modifiers < 0 {
            throw DecodingError.dataCorruptedError(forKey: .modifiers, in: values,
                                                   debugDescription: "Modifiers are flags added up from 0.")
        }
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        checked = try values.decodeIfPresent(Bool.self, forKey: .checked) ?? false
        submenu = try values.decodeIfPresent(Bool.self, forKey: .submenu) ?? false
    }
}
