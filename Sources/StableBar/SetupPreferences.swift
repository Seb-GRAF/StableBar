import Foundation

struct SetupPreferences: Equatable {
    enum Appearance: String, CaseIterable {
        case current = "Keep current", automatic = "Automatic", light = "Light", dark = "Dark"
    }

    enum Placement: String, CaseIterable {
        case current = "Keep current", top = "Top edge", belowMenuBar = "Below menu bar"
    }

    enum Clock: String, CaseIterable {
        case current = "Keep current", twentyFourHour = "24-hour", twelveHour = "12-hour"
    }

    enum Theme: Hashable {
        case current, builtIn, package(id: String, version: String?)
    }

    var appearance = Appearance.current
    var placement = Placement.current
    var clock = Clock.current
    var theme = Theme.current

    func save(to url: URL, menuBarHeight: Double, context: ConfigurationContext) throws {
        let original = try Data(contentsOf: url)
        let data = try applying(to: original, menuBarHeight: menuBarHeight, configurationURL: url, context: context)
        try writeConfiguration(data, to: url)
    }

    func applying(to data: Data, menuBarHeight: Double, configurationURL: URL? = nil,
                  context: ConfigurationContext = ConfigurationContext()) throws -> Data {
        let configuration: Configuration
        if let configurationURL {
            var loader = ConfigurationLoader()
            configuration = try loader.load(configurationURL, data: data, context: context)
        } else {
            configuration = try JSONDecoder().decode(Configuration.self, from: data)
        }
        if self == SetupPreferences() { return data }
        var edits: [ConfigurationEdit] = []
        switch theme {
        case .current: break
        case .builtIn: edits.append(ConfigurationEdit(action: .theme))
        case let .package(id, version):
            var properties: [String: ConfigurationValue] = ["id": .string(id)]
            if let version { properties["version"] = .string(version) }
            edits.append(ConfigurationEdit(action: .theme, properties: properties))
        }
        if appearance != .current {
            let value: ConfigurationValue = switch appearance {
            case .light: .string("light")
            case .dark: .string("dark")
            default: .null
            }
            edits.append(ConfigurationEdit(action: .bar, properties: ["appearance": value]))
        }
        if placement != .current {
            edits.append(ConfigurationEdit(action: .bar, properties: ["offset": .number(placement == .top ? 0 : menuBarHeight)]))
        }
        if clock != .current {
            for widget in configuration.widgets {
                if case .clock = widget.content {
                    edits.append(ConfigurationEdit(action: .set, id: widget.id, properties: [
                        "format": .string(clock == .twentyFourHour ? "EEE d MMM  HH:mm" : "EEE d MMM  h:mm a")
                    ]))
                }
            }
        }
        var document = try JSONDecoder().decode([String: ConfigurationValue].self, from: data)
        var ids = configuration.widgets.map(\.id)
        for edit in edits { document = try edit.applying(to: document, widgetIDs: &ids) }
        return try configurationData(document, editing: data)
    }
}
