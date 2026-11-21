import CryptoKit
import Foundation

/// A `stablebar://bar?v=1&d=…` link: a bar's look, built-in widgets and Store widgets, without anything that runs or
/// opens something. `d` is the payload's JSON, compressed with zlib's raw DEFLATE and base64url-encoded.
struct BarLink: Equatable, Sendable {
    struct Package: Equatable, Sendable {
        let id: String
        let version: String
        let settings: [String: ConfigurationValue]
    }

    /// The look, as the files a theme link carries.
    var theme: ThemeLink
    /// Built-in widgets, with only the properties `carried(_:)` keeps.
    var widgets: [[String: ConfigurationValue]] = []
    /// Store packages, from the Store source only.
    var packages: [Package] = []
    /// The position and own group, or `enabled: false`, of each widget of `packages`, by widget ID.
    var widgetOverrides: [String: [String: ConfigurationValue]] = [:]
    /// Every widget the link carries, in bar order.
    var widgetOrder: [String] = []

    static let maximumLength = 65_536
    static let maximumBytes = 131_072
    static let maximumDepth = 32
    static let maximumValues = 4_096

    private static let payloadKeys: Set<String> = ["package", "config", "widgets", "packages", "widgetOverrides", "widgetOrder"]
    /// How a built-in widget looks and where it sits. What it runs or opens, its screens and its named popup stay behind.
    private static let widgetProperties: Set<String> = [
        "id", "type", "role", "position", "icon", "tooltip", "style", "format", "text", "layout", "hoverLayout", "overlay",
        "popup", "animation", "workspace", "group", "priority", "overflow", "transition", "expandOnHover", "openOnHover",
        "shown", "hidden", "details", "hideWhenIdle", "timeZone", "background", "popupBackground", "tooltipBackground"
    ]
    private static let popupProperties: Set<String> = [
        "height", "style", "layout", "views", "alignment", "offset", "openOnHover", "dismissOnAction", "dismissOnControl",
        "pinnable", "animation"
    ]
    /// A popup block with one of these runs a command, opens something or changes a setting, so it stays behind.
    private static let blockActions: Set<String> = [
        "onClick", "onClickField", "open", "openField", "quitField", "openMenuBarItem", "selectInputSourceField",
        "selectOutputDeviceField", "selectInputDeviceField", "nowPlayingCommand", "onChange", "onSubmit", "onStop", "onStar", "set"
    ]

    init(theme: ThemeLink) {
        self.theme = theme
    }

    init?(url: URL) throws(BarLinkError) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "stablebar", components.host?.lowercased() == "bar" else { return nil }
        guard url.absoluteString.utf8.count <= Self.maximumLength else { throw .tooLarge }
        guard components.path.isEmpty, components.fragment == nil,
              components.user == nil, components.password == nil, components.port == nil else { throw .damaged }

        let items = components.queryItems ?? []
        func item(_ name: String) throws(BarLinkError) -> String {
            let matches = items.filter { $0.name == name }
            guard matches.count == 1, let value = matches.first?.value else { throw .damaged }
            return value
        }
        let version = try item("v")
        guard version == "1" else {
            guard let number = Int(version), number > 1 else { throw .damaged }
            throw .unsupportedVersion
        }
        guard let compressed = ThemeLink.decoded(try item("d")), !compressed.isEmpty else { throw .damaged }
        let payload = ThemeLink.inflated(compressed, maximumBytes: Self.maximumBytes)
        guard !payload.isEmpty else { throw .damaged }
        guard payload.count <= Self.maximumBytes else { throw .tooLarge }
        try self.init(payload: payload)
    }

    /// Reads the link's JSON payload, keeping only what a bar link carries.
    init(payload data: Data) throws(BarLinkError) {
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) } catch { throw .damaged }
        var values = 0
        // ConfigurationValue's recursive decoding is expensive, so bound the parsed JSON first.
        try Self.checkSize(object, depth: 1, values: &values)
        do {
            let payload = try JSONDecoder().decode([String: ConfigurationValue].self, from: data)
            guard Set(payload.keys) == Self.payloadKeys else { throw BarLinkError.damaged }
            self.init(theme: ThemeLink(manifest: Data(try payload["package"]!.decoded(String.self).utf8),
                                       configuration: Data(try payload["config"]!.decoded(String.self).utf8)))
            let order = try payload["widgetOrder"]!.decoded([String].self)
            widgets = try payload["widgets"]!.decoded([[String: ConfigurationValue]].self).compactMap(Self.carried)
                .filter { widget in order.contains { widget["id"] == .string($0) } }
            packages = try payload["packages"]!.decoded([WidgetPackageSelection].self).map { selection in
                guard let version = selection.version else { throw BarLinkError.damaged }
                return Package(id: selection.id, version: version, settings: selection.settings)
            }
            widgetOverrides = try payload["widgetOverrides"]!.decoded([String: [String: ConfigurationValue]].self)
                .mapValues { $0.filter { ["position", "group", "enabled"].contains($0.key) } }
            widgetOrder = order
        } catch { throw .damaged }
    }

    func payload() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(ConfigurationValue.object([
            "package": .string(String(decoding: theme.manifest, as: UTF8.self)),
            "config": .string(String(decoding: theme.configuration, as: UTF8.self)),
            "widgets": .array(widgets.map(ConfigurationValue.object)),
            "packages": .array(packages.map { .object(["id": .string($0.id), "version": .string($0.version), "settings": .object($0.settings)]) }),
            "widgetOverrides": .object(widgetOverrides.mapValues(ConfigurationValue.object)),
            "widgetOrder": .array(widgetOrder.map(ConfigurationValue.string))
        ]))
    }

    func url() throws -> URL {
        let compressed = try (payload() as NSData).compressed(using: .zlib) as Data
        var components = URLComponents()
        components.scheme = "stablebar"
        components.host = "bar"
        components.queryItems = [URLQueryItem(name: "v", value: "1"), URLQueryItem(name: "d", value: ThemeLink.encoded(compressed))]
        return components.url!
    }

    /// What a bar link keeps of a widget definition: nil for a script or custom provider widget, else its look and place.
    static func carried(_ widget: [String: ConfigurationValue]) -> [String: ConfigurationValue]? {
        guard case let .string(type)? = widget["type"], let name = WidgetConfiguration.typeName(type),
              name != "script", name != "provider" else { return nil }
        var carried = widget.filter { widgetProperties.contains($0.key) }
        for key in ["layout", "hoverLayout", "overlay"] {
            carried[key] = carried[key].flatMap(carriedBlock)
        }
        if case let .object(popup)? = carried["popup"] {
            var kept = popup.filter { popupProperties.contains($0.key) }
            var views: [String: ConfigurationValue] = [:]
            if case let .object(all)? = kept["views"] {
                views = all.compactMapValues(carriedBlock)
                kept["views"] = .object(views.mapValues { opening(only: views.keys, in: $0) })
            }
            kept["layout"] = kept["layout"].flatMap(carriedBlock).map { opening(only: views.keys, in: $0) }
            carried["popup"] = kept["layout"] == nil ? nil : .object(kept)
        }
        return carried
    }

    /// The block without links to views other than `views`, which the link dropped with their blocks.
    private static func opening(only views: Dictionary<String, ConfigurationValue>.Keys, in block: ConfigurationValue) -> ConfigurationValue {
        guard case var .object(properties) = block else { return block }
        if case let .string(view)? = properties["view"], !views.contains(view) { properties["view"] = nil }
        if case let .array(children)? = properties["children"] {
            properties["children"] = .array(children.map { opening(only: views, in: $0) })
        }
        if let row = properties["row"] { properties["row"] = opening(only: views, in: row) }
        return .object(properties)
    }

    /// The block without the blocks inside it that run, open or show a file; nil when the block itself does.
    private static func carriedBlock(_ block: ConfigurationValue) -> ConfigurationValue? {
        guard case var .object(properties) = block, properties["type"] != .string("image"),
              !properties.keys.contains(where: blockActions.contains) else { return nil }
        if case let .array(children)? = properties["children"] {
            properties["children"] = .array(children.compactMap(carriedBlock))
        }
        if let row = properties["row"] {
            guard let row = carriedBlock(row) else { return nil }
            properties["row"] = row
        }
        return .object(properties)
    }

    /// Whether a link carries a package setting: a secret stays in the Keychain, and free text can name a person or place.
    static func carries(_ setting: WidgetPackageSetting) -> Bool {
        setting.type == "number" || setting.type == "bool" || setting.choices != nil
    }

    private static func checkSize(_ value: Any, depth: Int, values: inout Int) throws(BarLinkError) {
        values += 1
        guard values <= maximumValues else { throw .tooLarge }
        guard let children = (value as? [String: Any]).map({ Array($0.values) }) ?? value as? [Any] else { return }
        guard depth <= maximumDepth else { throw .tooDeep }
        for child in children { try checkSize(child, depth: depth + 1, values: &values) }
    }
}

extension BarLink {
    /// A bar link as Share My Bar shows it: the link, and what it carries and leaves out.
    struct Sharing {
        /// A widget of the bar, in bar order.
        struct Widget: Equatable {
            let name: String
            let symbol: String
            /// Why the link leaves the widget out, such as "Script widget"; nil when it carries it.
            var leftOut: String?
            var store = false
            /// On the first widget of a Store package, the package's settings the link carries, as "Title: value", and
            /// those that stay on this Mac, as "Title: secret" or "Title: free text".
            var settings: [String] = []
            var settingsLeftOut: [String] = []
        }

        /// The website's page that opens the link, as social sites don't open `stablebar://` links.
        let link: URL
        /// The name the look installs under.
        let look: String
        let widgets: [Widget]
    }

    /// The bar `store` shows on `display` as a bar link.
    @MainActor static func sharing(_ store: BarStore, on display: BarDisplay) throws -> Sharing {
        let kind = ScreenKind(display)
        let configuration = store.configuration!
        let document = store.screenDocuments[kind.rawValue] ?? store.effectiveDocument
        let definitions = try document["widgets"]!.decoded([[String: ConfigurationValue]].self)
        let selections = try document["packages"]?.decoded([WidgetPackageSelection].self) ?? []
        let packages = store.packageStoreClient.packages
        let onScreen = configuration.onScreen(kind).widgets
        let names = WidgetDisplayName.names(for: onScreen, packageNames: store.widgetPackageNames, providers: configuration.providers)
        var link = BarLink(theme: try look(of: store, on: kind))
        var widgets: [Sharing.Widget] = []
        for widget in onScreen where widget.enabled && !store.barEditing.visibility(of: widget, on: display).reasons.contains(.display) {
            var shared = Sharing.Widget(name: names[widget.id]!, symbol: widget.content.symbol)
            if let id = store.widgetPackageIDs[widget.id] {
                let record = try packages.record(id: id)
                guard let selection = selections.first(where: { $0.id == id }), let version = selection.version, let record,
                      record.source == PackageSource.storeID, !record.isLocal(version: version) else {
                    shared.leftOut = if let record {
                        !record.isLocal && record.source != PackageSource.storeID ? "Private source" : "Local folder"
                    } else {
                        "Unknown source"
                    }
                    widgets.append(shared)
                    continue
                }
                shared.store = true
                if !link.packages.contains(where: { $0.id == id }) {
                    let manifest = try packages.manifest(at: packages.directory(id: id, version: version))
                    let settings = selection.settings.filter { manifest.settings[$0.key].map(carries) == true }
                    link.packages.append(Package(id: id, version: version, settings: settings))
                    for name in manifest.settingNames {
                        let setting = manifest.settings[name]!
                        if !carries(setting) {
                            shared.settingsLeftOut.append("\(setting.title ?? name): \(setting.type == "secret" ? "secret" : "free text")")
                        } else if let value = settings[name] {
                            let text = switch value {
                            case let .number(number): number.formatted()
                            case let .bool(on): on ? "On" : "Off"
                            case let .string(choice): choice
                            default: ""
                            }
                            shared.settings.append("\(setting.title ?? name): \(text)")
                        }
                    }
                    for other in configuration.widgets where store.widgetPackageIDs[other.id] == id {
                        link.widgetOverrides[other.id] = ["enabled": .bool(false)]
                    }
                }
                link.widgetOverrides[widget.id] = [
                    "position": .string(widget.position.rawValue), "group": widget.ownGroup.map(ConfigurationValue.string) ?? .null
                ]
            } else {
                var definition = definitions.first { $0["id"] == .string(widget.id) }!
                definition["position"] = .string(widget.position.rawValue)
                guard let kept = carried(definition) else {
                    shared.leftOut = if case .script = widget.content { "Script widget" } else { "Custom provider" }
                    widgets.append(shared)
                    continue
                }
                link.widgets.append(kept)
            }
            widgets.append(shared)
            link.widgetOrder.append(widget.id)
        }
        // Refuse here what a recipient would: a look outside the theme link rules, or a link past its limits.
        let look = try ThemeLinkCandidate(link: link.theme, store: store)
        look.discard()
        let url = try link.url()
        _ = try BarLink(url: url)
        return Sharing(link: URL(string: "https://stablebar.app/bar.html#\(url.query!)")!, look: look.choice.manifest.name, widgets: widgets)
    }

    /// The theme the screens of `kind` use, with the main file's look merged in as Save as Theme merges it, resolved
    /// for the active profiles.
    @MainActor private static func look(of store: BarStore, on kind: ScreenKind) throws -> ThemeLink {
        var main = try store.configurationStore.editedMainDocument(replaying: store.configurationStore.customizationEdits)
        let screen = try main["screens"]?.decoded([String: [String: ConfigurationValue]].self)[kind.rawValue] ?? [:]
        for key in ["bar", "tokens", "defaults", "popupDefaults", "groupDefaults", "roles", "workspaceDefaults"] {
            if let value = screen[key] { main[key] = value.overriding(main[key] ?? .object([:])) }
        }
        let screens = try store.effectiveDocument["screens"]?.decoded([String: [String: ConfigurationValue]].self) ?? [:]
        let selection = try (screens[kind.rawValue]?["theme"] ?? store.effectiveDocument["theme"])?.decoded(WidgetPackageSelection.self)
        let enabled = selection?.enabled == true ? selection : nil
        let key = enabled?.key ?? "built-in"
        guard let current = ThemeCatalog(packages: store.packageStoreClient.packages.directory, themesDirectory: store.configurationStore.themesDirectory,
                                         selectedKey: key).choices.first(where: { $0.key == key }) else {
            throw CommandFailure(message: "The theme \(key) isn’t installed.")
        }
        var loader = ConfigurationLoader()
        let theme = try applyingProfiles(store.activeProfiles, to: loader.readPackage(
            at: current.directory, manifest: current.manifest, settings: enabled?.settings ?? [:]).values)
        var look = try savingLook(of: applyingProfiles(store.activeProfiles, to: main), into: theme).theme
        look["tokens"] = try sharedTokens(of: look, theme: theme)
        let configuration = try configurationData(look)
        let name = "\(current.manifest.name) (shared)"
        let hash = SHA256.hash(data: configuration + Data(name.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        let manifest = try configurationData(["id": .string("shared-\(hash)"), "name": .string(name), "version": .string("1.0.0"),
                                              "kind": .string("theme"), "entry": .string("config.json")])
        return ThemeLink(manifest: manifest, configuration: configuration)
    }

    private static func applyingProfiles(_ names: [String], to document: [String: ConfigurationValue]) throws -> [String: ConfigurationValue] {
        var document = document
        let profiles = try document.removeValue(forKey: "profiles")?.decoded([ConfigurationProfile].self) ?? []
        for profile in profiles where names.contains(profile.name) {
            document.merge(profile.configuration) { $1.overriding($0) }
        }
        return document
    }

    /// The theme's tokens and those the look refers to. Save as Theme keeps every token, but a token can hold something
    /// else, such as a provider's header, which must stay on this Mac.
    private static func sharedTokens(of look: [String: ConfigurationValue], theme: [String: ConfigurationValue]) throws -> ConfigurationValue? {
        guard let tokens = try look["tokens"]?.decoded([String: ConfigurationValue].self) else { return nil }
        let themed = try theme["tokens"]?.decoded([String: ConfigurationValue].self) ?? [:]
        func references(in value: ConfigurationValue) -> [String] {
            switch value {
            case let .string(text) where text.hasPrefix("@token."): [String(text.dropFirst(7))]
            case let .object(values): values.values.flatMap(references)
            case let .array(values): values.flatMap(references)
            default: []
            }
        }
        var pending = tokens.keys.filter { name in themed[name] != nil || themeTokens.contains { $0.name == name } }
            + references(in: .object(look.filter { $0.key != "tokens" }))
        var kept: Set<String> = []
        while let name = pending.popLast() {
            guard let value = tokens[name], kept.insert(name).inserted else { continue }
            pending += references(in: value)
        }
        return .object(tokens.filter { kept.contains($0.key) })
    }
}

enum BarLinkError: LocalizedError, Equatable {
    case unsupportedVersion, damaged, tooLarge, tooDeep

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "This bar link needs a newer version of StableBar."
        case .damaged: "This bar link is damaged. Copy it again."
        case .tooLarge: "This bar is larger than a bar link can carry."
        case .tooDeep: "This bar nests its settings more than 32 levels deep, which a bar link can't carry."
        }
    }
}
