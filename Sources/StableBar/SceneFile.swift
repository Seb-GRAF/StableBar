import Foundation

/// One screen to draw offscreen: a configuration, the sample data its widgets show, and what to draw.
/// `StableBar --render-scenes` reads these from `scenes/`, and scene.schema.json describes them. A scene
/// runs nothing: commands, providers and window managers are replaced by the samples it gives.
struct SceneFile: Decodable {
    enum Draw: String, Decodable, CaseIterable { case bar, editBar, popup, settings }
    enum Appearance: String, Decodable, CaseIterable { case dark, light }
    /// A Settings section, named as the toolbar names it.
    enum Section: String, Decodable, CaseIterable { case general, bar, theme, profiles, packages }
    enum Tab: String, Decodable, CaseIterable { case content, style, behavior }
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
    var draw: Draw
    /// The widget whose popup or Settings page to draw.
    var widget: String?
    /// The Settings section to draw when no widget is named.
    var section: Section?
    /// The tab of the widget's Settings page.
    var tab: Tab?
    var appearances: [Appearance] = Appearance.allCases
    var width: Double?
    var height: Double?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case configuration, outputs, history, workspaces, windows, activeApp, draw, widget, section, tab, appearances, width, height
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
        draw = try values.decode(Draw.self, forKey: .draw)
        widget = try values.decodeIfPresent(String.self, forKey: .widget)
        section = try values.decodeIfPresent(Section.self, forKey: .section)
        tab = try values.decodeIfPresent(Tab.self, forKey: .tab)
        appearances = try values.decodeIfPresent([Appearance].self, forKey: .appearances) ?? Appearance.allCases
        width = try values.decodeIfPresent(Double.self, forKey: .width)
        height = try values.decodeIfPresent(Double.self, forKey: .height)
        if draw == .popup, widget == nil {
            throw DecodingError.dataCorruptedError(forKey: .widget, in: values, debugDescription: "A popup scene names its widget.")
        }
        if draw == .settings, widget == nil, section == nil {
            throw DecodingError.dataCorruptedError(forKey: .section, in: values,
                                                   debugDescription: "A settings scene names a widget or a section.")
        }
        if tab != nil, widget == nil {
            throw DecodingError.dataCorruptedError(forKey: .tab, in: values, debugDescription: "A tab belongs to a widget's Settings page.")
        }
    }

    static func read(_ url: URL) throws -> SceneFile {
        try JSONDecoder().decode(SceneFile.self, from: Data(contentsOf: url))
    }
}
