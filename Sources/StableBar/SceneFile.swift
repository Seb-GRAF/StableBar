import Foundation

/// One screen to draw offscreen: a configuration, the sample data its widgets show, and what to draw.
/// `StableBar --render-scenes` reads these from `scenes/`, and scene.schema.json describes them. A scene
/// runs nothing: commands, providers and window managers are replaced by the samples it gives.
struct SceneFile: Decodable {
    enum Draw: String, Decodable, CaseIterable { case bar, editBar, popup, settings, uninstall, update, setup, accessibilityGuide }
    enum Appearance: String, Decodable, CaseIterable { case dark, light }
    /// A Settings section, named as the toolbar names it, `feedback` for Send feedback in Help, or `crashes` for Crashes in Status.
    enum Section: String, Decodable, CaseIterable { case general, bar, theme, profiles, packages, help, feedback, crashes }
    /// A tab of a widget's Settings page (content, style, behavior), or of the bar's in the Bar section (size, look, placement).
    enum Tab: String, Decodable, CaseIterable {
        case content, style, behavior, size, look, placement

        var isBarTab: Bool { [.size, .look, .placement].contains(self) }
    }
    /// The Uninstall sheet's confirmation, or the steps that failed before StableBar quits.
    enum Uninstall: String, Decodable, CaseIterable { case confirm, failed }
    enum StarRequestLine: String, Decodable, CaseIterable {
        case repository, gitHubCLI, thanked

        var state: StarRequest.State {
            switch self {
            case .repository: .repository
            case .gitHubCLI: .gitHubCLI(account: "octocat")
            case .thanked: .thanked(account: "octocat")
            }
        }
    }
    /// A setting in System Settings → Accessibility → Display.
    enum AccessibilityDisplay: String, Decodable, CaseIterable { case increaseContrast, reduceTransparency }
    /// The configuration inline, or the path of a configuration file relative to the scene file.
    enum Configuration: Equatable { case inline([String: ConfigurationValue]), file(String) }

    var configuration: Configuration
    /// Package folders, relative to the scene file, installed as `--install-package` installs them. Packages are read
    /// from beside the configuration, so a scene with packages gives its configuration inline, and it's written to the
    /// scene's work folder.
    var packages: [String] = []
    /// Script outputs keyed by widget id or provider name: an object as a script prints it, or plain text.
    var outputs: [String: ConfigurationValue] = [:]
    /// Graph samples keyed by widget id or provider name.
    var history: [String: [Double]] = [:]
    /// AeroSpace's `list-workspaces --json` objects.
    var workspaces: [ConfigurationValue]?
    /// AeroSpace's `list-windows --json` objects.
    var windows: [ConfigurationValue]?
    /// Switch to Desktop shortcuts enabled on the stand-in Mac, for setup and Settings. All are off by default.
    var desktopShortcuts: [Int] = []
    /// The bundle identifier of the active app, Finder by default.
    var activeApp: String?
    /// The menu a popup scene shows in place of the widget's popup, as an app menu widget opens one.
    var menu: [MenuItem]?
    var draw: Draw
    /// The widget whose popup or Settings page to draw.
    var widget: String?
    /// The Settings section to draw when no widget is named.
    var section: Section?
    /// The tab of the widget's Settings page, or of the bar's when the scene opens the Bar section without a widget.
    var tab: Tab?
    /// The installed package whose settings the Packages section shows.
    var package: String?
    /// What the Uninstall sheet shows, for `uninstall`.
    var uninstall: Uninstall?
    /// The star request the update popup shows, for `update`.
    var starRequest: StarRequestLine?
    /// The step setup shows and the Mac it shows it on, for `setup`.
    var setup: Setup?
    /// A move row outside Applications, for setup or Settings → General.
    var applicationMove: ApplicationMove?
    enum ApplicationMove: String, Decodable, CaseIterable { case ready, replace, useExisting, failed, moving, setupOpen }
    /// The macOS version for feature availability in setup and Settings, pinned independently of the render host.
    var macOSMajorVersion = 26
    var appearances: [Appearance] = Appearance.allCases
    /// The Accessibility display settings a bar or popup scene draws with, all off by default, whatever the Mac that draws has.
    var accessibilityDisplay: [AccessibilityDisplay] = []
    var width: Double?
    var height: Double?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case configuration, packages, outputs, history, workspaces, windows, desktopShortcuts, activeApp, menu, draw, widget, section, tab, package, uninstall,
             starRequest, setup, applicationMove, macOSMajorVersion, appearances,
             accessibilityDisplay, width, height
    }

    /// A step of setup's tour, the choices made before it, and what setup reads from the Mac, pinned so a drawing
    /// doesn't depend on the Mac that draws it.
    struct Setup: Equatable {
        var step = SetupSession.Step.placement
        /// The first step's choice, made before drawing; none leaves both choices unpicked.
        var placement: SetupPreferences.Placement?
        /// The preset picked on the second step.
        var preset: SetupPreferences.Preset?
        /// Whether macOS hides its menu bar automatically.
        var menuBarHides = false
        /// Whether macOS allows StableBar Accessibility, control of System Events and full Calendar access.
        var accessibility = true
        var automation = true
        var calendars = true
        /// Whether the Mac has an internal battery, which presets add Battery for.
        var battery = true
        /// Whether any connected display has a notch, which the Notch preset needs.
        var notch = true
        /// Whether StableBar runs from an Applications folder, which Open at login needs.
        var inApplications = true
        /// A canned connection result; drawing setup never queries a window manager or reads its config.
        var workspaceCheck: WorkspaceCheck?

        enum WorkspaceCheck: String, Decodable, CaseIterable {
            case connected, signalsMissing, reloadYabai, ipcOff, couldntCheck

            var result: SetupWorkspaceResult {
                switch self {
                case .connected: .connected
                case .signalsMissing: .signalsMissing(configuration: "~/.yabairc")
                case .reloadYabai: .reloadYabai(configuration: "~/.yabairc")
                case .ipcOff: .ipcOff
                case .couldntCheck: .couldntCheck("Couldn’t check just now. Check that your window manager is running, then try again.")
                }
            }
        }
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
        packages = try values.decodeIfPresent([String].self, forKey: .packages) ?? []
        if !packages.isEmpty, case .file = configuration {
            throw DecodingError.dataCorruptedError(forKey: .packages, in: values, debugDescription: "A scene with packages gives its configuration inline.")
        }
        outputs = try values.decodeIfPresent([String: ConfigurationValue].self, forKey: .outputs) ?? [:]
        history = try values.decodeIfPresent([String: [Double]].self, forKey: .history) ?? [:]
        workspaces = try values.decodeIfPresent([ConfigurationValue].self, forKey: .workspaces)
        windows = try values.decodeIfPresent([ConfigurationValue].self, forKey: .windows)
        desktopShortcuts = try values.decodeIfPresent([Int].self, forKey: .desktopShortcuts) ?? []
        if desktopShortcuts.contains(where: { !DesktopShortcuts.desktops.contains($0) }) || Set(desktopShortcuts).count != desktopShortcuts.count {
            throw DecodingError.dataCorruptedError(forKey: .desktopShortcuts, in: values,
                                                   debugDescription: "Desktop shortcuts name desktops 1 to 16, each once.")
        }
        activeApp = try values.decodeIfPresent(String.self, forKey: .activeApp)
        menu = try values.decodeIfPresent([MenuItem].self, forKey: .menu)
        draw = try values.decode(Draw.self, forKey: .draw)
        widget = try values.decodeIfPresent(String.self, forKey: .widget)
        section = try values.decodeIfPresent(Section.self, forKey: .section)
        tab = try values.decodeIfPresent(Tab.self, forKey: .tab)
        package = try values.decodeIfPresent(String.self, forKey: .package)
        uninstall = try values.decodeIfPresent(Uninstall.self, forKey: .uninstall)
        starRequest = try values.decodeIfPresent(StarRequestLine.self, forKey: .starRequest)
        setup = try values.decodeIfPresent(Setup.self, forKey: .setup)
        applicationMove = try values.decodeIfPresent(ApplicationMove.self, forKey: .applicationMove)
        if applicationMove != nil, draw != .setup && !(draw == .settings && section == .general) {
            throw DecodingError.dataCorruptedError(forKey: .applicationMove, in: values,
                debugDescription: "applicationMove draws a setup row or Settings General.")
        }
        // Setup shows the move row only outside Applications, and a setup scene is in Applications by default.
        if applicationMove != nil, draw == .setup, setup?.inApplications != false {
            throw DecodingError.dataCorruptedError(forKey: .applicationMove, in: values,
                debugDescription: "A setup scene draws applicationMove only with setup.inApplications false.")
        }
        macOSMajorVersion = try values.decodeIfPresent(Int.self, forKey: .macOSMajorVersion) ?? 26
        if macOSMajorVersion < 14 {
            throw DecodingError.dataCorruptedError(forKey: .macOSMajorVersion, in: values,
                                                   debugDescription: "A macOS major version is 14 or later.")
        }
        appearances = try values.decodeIfPresent([Appearance].self, forKey: .appearances) ?? Appearance.allCases
        if appearances.isEmpty || Set(appearances).count != appearances.count {
            throw DecodingError.dataCorruptedError(forKey: .appearances, in: values,
                                                   debugDescription: "Appearances name dark, light or both, each once.")
        }
        accessibilityDisplay = try values.decodeIfPresent([AccessibilityDisplay].self, forKey: .accessibilityDisplay) ?? []
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
        if package != nil, draw != .settings || widget != nil || section != .packages {
            throw DecodingError.dataCorruptedError(forKey: .package, in: values, debugDescription: "package belongs to the packages section of Settings.")
        }
        if menu != nil, draw != .popup {
            throw DecodingError.dataCorruptedError(forKey: .menu, in: values, debugDescription: "A menu belongs to a popup scene.")
        }
        if uninstall != nil, draw != .uninstall {
            throw DecodingError.dataCorruptedError(forKey: .uninstall, in: values, debugDescription: "uninstall belongs to an uninstall scene.")
        }
        if starRequest != nil, draw != .update, !(draw == .settings && widget == nil && section == .help) {
            throw DecodingError.dataCorruptedError(forKey: .starRequest, in: values,
                                                   debugDescription: "starRequest belongs to an update scene or to Help in Settings.")
        }
        if setup != nil, draw != .setup {
            throw DecodingError.dataCorruptedError(forKey: .setup, in: values, debugDescription: "setup belongs to a setup scene.")
        }
        if !accessibilityDisplay.isEmpty, draw != .bar, draw != .popup {
            throw DecodingError.dataCorruptedError(forKey: .accessibilityDisplay, in: values,
                                                   debugDescription: "accessibilityDisplay belongs to a bar or popup scene.")
        }
        if let tab, tab.isBarTab, widget != nil || section != .bar {
            throw DecodingError.dataCorruptedError(forKey: .tab, in: values,
                                                   debugDescription: "\(tab.rawValue) is a tab of the bar's settings, in the bar section without a widget.")
        }
        if let tab, !tab.isBarTab, widget == nil {
            throw DecodingError.dataCorruptedError(forKey: .tab, in: values, debugDescription: "\(tab.rawValue) is a tab of a widget's Settings page.")
        }
    }

    static func read(_ url: URL) throws -> SceneFile {
        try JSONDecoder().decode(SceneFile.self, from: Data(contentsOf: url))
    }
}

extension SceneFile.Setup: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case step, placement, preset, menuBarHides, accessibility, automation, calendars, battery, notch, inApplications, workspaceCheck
    }

    /// Steps, placements and presets go by the names the app gives them, such as `tryIt` or `belowMenuBar`.
    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func named<Value>(_ key: CodingKeys, among choices: [Value]) throws -> Value? {
            guard let name = try values.decodeIfPresent(String.self, forKey: key) else { return nil }
            guard let value = choices.first(where: { "\($0)" == name }) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: values, debugDescription:
                    "\(key.stringValue) is one of \(choices.map { "\($0)" }.joined(separator: ", ")).")
            }
            return value
        }
        step = try named(.step, among: SetupSession.Step.allCases) ?? .placement
        placement = try named(.placement, among: [SetupPreferences.Placement.top, .belowMenuBar])
        preset = try named(.preset, among: SetupPreferences.Preset.allCases)
        menuBarHides = try values.decodeIfPresent(Bool.self, forKey: .menuBarHides) ?? false
        accessibility = try values.decodeIfPresent(Bool.self, forKey: .accessibility) ?? true
        automation = try values.decodeIfPresent(Bool.self, forKey: .automation) ?? true
        calendars = try values.decodeIfPresent(Bool.self, forKey: .calendars) ?? true
        battery = try values.decodeIfPresent(Bool.self, forKey: .battery) ?? true
        notch = try values.decodeIfPresent(Bool.self, forKey: .notch) ?? true
        inApplications = try values.decodeIfPresent(Bool.self, forKey: .inApplications) ?? true
        workspaceCheck = try values.decodeIfPresent(WorkspaceCheck.self, forKey: .workspaceCheck)
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
