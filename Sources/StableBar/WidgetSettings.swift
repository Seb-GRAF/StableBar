import Foundation

enum WidgetClickControl: Equatable {
    case hidden, choices, explanation(String)
}

enum WidgetClickChoice: String, CaseIterable {
    case nothing, application, webPage, advanced

    var title: String {
        switch self {
        case .nothing: "Nothing"
        case .application: "Open an app…"
        case .webPage: "Open a web page…"
        case .advanced: "Custom action"
        }
    }

    static func explanation(for widget: WidgetConfiguration, output: ScriptOutput? = nil) -> String? {
        if widget.content == .workspaces { return "Clicking a workspace switches to it." }
        if case .appMenu = widget.content { return "Clicking a menu opens it." }
        if widget.content == .appleMenu { return "Clicking it opens the Apple menu." }
        var actions: [String] = []
        if widget.onClick != nil || output?.onClick != nil { actions.append("runs a command") }
        if widget.popup != nil || widget.popupName != nil { actions.append("opens a popup") }
        if widget.menu != nil || output?.menu != nil { actions.append("opens a menu") }
        if !actions.isEmpty { return "This widget \(actions.joined(separator: " and ")). Change it under Technical details." }
        if let open = widget.open, case .url(let url) = OpenTarget(open), !["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            return "This widget opens a link. Change it under Technical details."
        }
        return nil
    }

    static func control(for widget: WidgetConfiguration, output: ScriptOutput? = nil) -> WidgetClickControl {
        if widget.content == .spacer { return .hidden }
        if let explanation = explanation(for: widget, output: output) { return .explanation(explanation) }
        return .choices
    }

    static func current(for widget: WidgetConfiguration, output: ScriptOutput? = nil) -> Self {
        if control(for: widget, output: output) != .choices { return .advanced }
        guard let open = widget.open, let target = OpenTarget(open) else { return .nothing }
        switch target {
        case .application: return .application
        case .url: return .webPage
        }
    }

    func properties(for widget: WidgetConfiguration, value: String? = nil, output: ScriptOutput? = nil) throws -> [String: ConfigurationValue] {
        guard Self.control(for: widget, output: output) == .choices else {
            throw CommandFailure(message: "Change this widget’s click action under Technical details.")
        }
        switch self {
        case .nothing: return ["open": .null]
        case .application:
            guard let value, case .application = OpenTarget(value) else {
                throw CommandFailure(message: "Choose an application with a bundle identifier.")
            }
            return ["open": .string(value)]
        case .webPage:
            guard let value, let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host, !host.isEmpty else {
                throw CommandFailure(message: "Enter a web address beginning with https:// or http://.")
            }
            return ["open": .string(value)]
        case .advanced: throw CommandFailure(message: "Change this widget’s click action under Technical details.")
        }
    }
}

enum WidgetScreenChoice: String, CaseIterable {
    case all, active, main, builtIn, external, notched, unnotched, specific

    var title: String {
        switch self {
        case .all: "All screens"
        case .active: "The active screen"
        case .main: "The main screen"
        case .builtIn: "The built-in screen"
        case .external: "External screens"
        case .notched: "Screens with a notch"
        case .unnotched: "Screens without a notch"
        case .specific: "Specific screens"
        }
    }

    init(_ selection: DisplaySelection) {
        switch selection {
        case .all: self = .all
        case .active: self = .active
        case .main: self = .main
        case .builtIn: self = .builtIn
        case .external: self = .external
        case .notched: self = .notched
        case .unnotched: self = .unnotched
        case .ids: self = .specific
        }
    }

    var properties: [String: ConfigurationValue]? {
        self == .specific ? nil : ["display": .string(rawValue)]
    }
}

struct WidgetClockFormat {
    let title: String
    let value: String

    static let common = [
        Self(title: "24-hour time", value: "HH:mm"),
        Self(title: "12-hour time", value: "h:mm a"),
        Self(title: "Time with seconds", value: "HH:mm:ss"),
        Self(title: "Date and time", value: "EEE d MMM  HH:mm")
    ]
}
