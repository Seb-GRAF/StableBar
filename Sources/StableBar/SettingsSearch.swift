import Foundation

enum SettingsSearchResult: String, CaseIterable, Identifiable {
    case widgetContent, widgetAppearance, widgetBehavior, widgetTechnical
    case theme, glass, colors, defaults, popups, roles, workspaceStyle, modeAliases, barStyle
    case login, placement, access, connections, configuration, help, updates
    case profiles, library, status

    var id: String { rawValue }
    var title: String { details.0 }
    var section: CustomizationSection { details.1 }

    private var details: (String, CustomizationSection, String) {
        switch self {
        case .widgetContent: ("Widget content", .widgets, "text icon clock date format package settings location units")
        case .widgetAppearance: ("Widget appearance", .widgets, "color font size padding corners border")
        case .widgetBehavior: ("Widget behavior and placement", .widgets, "click popup hover screens display position tooltip")
        case .widgetTechnical: ("Widget technical details", .widgets, "script command json id role transition")
        case .theme: ("Theme", .appearance, "light dark automatic browse")
        case .glass: ("Liquid Glass", .appearance, "transparency see-through")
        case .colors: ("Theme colors", .appearance, "tokens light dark accent text surface")
        case .defaults: ("Default widget appearance", .appearance, "all font size color padding corners shadow")
        case .popups: ("Popup appearance", .appearance, "background border shadow weight")
        case .roles: ("Presentation roles", .appearance, "advanced time status style")
        case .workspaceStyle: ("Workspace appearance", .appearance, "defaults indicator empty focused")
        case .modeAliases: ("AeroSpace mode aliases", .appearance, "advanced mapping")
        case .barStyle: ("Bar appearance", .appearance, "background border corners height spacing inset")
        case .login: ("Open at login", .general, "startup launch")
        case .placement: ("Displays and placement", .general, "offset margin scale monitor windows notifications clear accessibility")
        case .access: ("Access", .general, "permission calendar accessibility automation denied")
        case .connections: ("Workspace connection", .general, "aerospace yabai source reconnect")
        case .configuration: ("Configuration files", .general, "json path reload finder temporary command line")
        case .help: ("Getting started", .general, "onboarding setup guide help")
        case .updates: ("About and updates", .general, "version release beta stable automatic download")
        case .profiles: ("Profiles", .profiles, "automatic conditions app battery power external display overrides")
        case .library: ("Widget library", .packages, "store package install version update uninstall shared settings")
        case .status: ("Status and troubleshooting", .diagnostics, "diagnostics error failed refresh snapshot event")
        }
    }

    func matches(_ query: String) -> Bool {
        let text = "\(title) \(section.rawValue) \(details.2)"
        return query.split(whereSeparator: \.isWhitespace).allSatisfy { text.localizedStandardContains($0) }
    }
}
