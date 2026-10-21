import Foundation

enum SettingsSearchResult: String, CaseIterable, Identifiable {
    case login, windows, workspaces, access, configuration, updates, help
    case barSize, barLook, barPlacement, screenSetups, everyWidget, widgetContent, widgetStyle, widgetBehavior, addWidget
    case theme, colors, glass, popups, roles, workspaceStyle, modeAliases
    case profiles, library, store, status

    var id: String { rawValue }
    var title: String { details.0 }
    var section: CustomizationSection { details.1 }
    var path: String { details.2 }

    private var details: (String, CustomizationSection, String, String) {
        switch self {
        case .login: ("Open at login", .general, "General", "startup launch")
        case .windows: ("Keep windows clear of the bar", .general, "General", "windows notifications overlap clearance accessibility")
        case .workspaces: ("Workspace manager", .general, "General", "aerospace yabai source reconnect connection")
        case .access: ("Permissions", .general, "General", "access accessibility calendar location automation denied")
        case .configuration: ("Configuration file", .general, "General", "json path reload finder temporary command line")
        case .updates: ("Updates", .general, "General", "version release beta stable automatic download about package notification")
        case .help: ("Set up StableBar again", .general, "General", "onboarding setup guide help")
        case .barSize: ("Bar height and corners", .widgets, "Bar › Bar › Size", "tall size px pt radius rounded inset spacing")
        case .barLook: ("Bar background and border", .widgets, "Bar › Bar › Look", "color fill gradient edges line")
        case .barPlacement: ("Offset, margin and size on each screen", .widgets, "Bar › Bar › Placement", "position floating scale laptop monitor display")
        case .screenSetups: ("Own bar for these screens", .widgets, "Bar › Screens", "screen setup monitor laptop vertical shared external")
        case .everyWidget: ("Look of every widget", .widgets, "Bar › Every widget", "defaults font size color padding corners shadow px pt")
        case .widgetContent: ("Widget content", .widgets, "Bar › Widget › Content", "text icon clock date format package settings location units")
        case .widgetStyle: ("Widget style", .widgets, "Bar › Widget › Style", "color gradient font size padding corners border px pt")
        case .widgetBehavior: ("Widget clicks, screens and position", .widgets, "Bar › Widget › Behavior", "click popup hover screens display position tooltip hide")
        case .addWidget: ("Add a widget", .widgets, "Bar › Add widget", "new widget clock battery calendar store package")
        case .theme: ("Theme", .appearance, "Theme", "light dark automatic appearance browse look save copy duplicate")
        case .colors: ("Theme colors", .appearance, "Theme › Theme colors", "tokens accent text surface palette")
        case .glass: ("Liquid Glass", .appearance, "Theme › Liquid Glass", "transparency see-through blur")
        case .popups: ("Popup colors", .appearance, "Theme › Popups", "popover background border shadow weight")
        case .roles: ("Presentation roles", .appearance, "Theme › Advanced", "role time status style")
        case .workspaceStyle: ("Workspace look", .appearance, "Theme › Advanced", "defaults indicator empty focused")
        case .modeAliases: ("AeroSpace mode names", .appearance, "Theme › Advanced", "mode aliases mapping")
        case .profiles: ("Profiles", .profiles, "Profiles", "automatic conditions app battery power dark external display pinned")
        case .library: ("Installed packages", .packages, "Packages › Installed", "package version update uninstall settings credentials local folder built-in")
        case .store: ("Get widgets and themes from the Store", .packages, "Packages › Store", "store install download")
        case .status: ("Status and troubleshooting", .diagnostics, "Status", "diagnostics error failed refresh snapshot event")
        }
    }

    func matches(_ query: String) -> Bool {
        let text = "\(title) \(path) \(details.3)"
        return query.split(whereSeparator: \.isWhitespace).allSatisfy { text.localizedStandardContains($0) }
    }
}
