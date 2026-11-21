import Foundation
import os

indirect enum ConfigurationValue: Codable, Sendable, Equatable {
    case object([String: ConfigurationValue])
    case array([ConfigurationValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let object = try? value.decode([String: ConfigurationValue].self) { self = .object(object) }
        else if let array = try? value.decode([ConfigurationValue].self) { self = .array(array) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else { self = .number(try value.decode(Double.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case let .object(object): try value.encode(object)
        case let .array(array): try value.encode(array)
        case let .string(string): try value.encode(string)
        case let .number(number): try value.encode(number)
        case let .bool(bool): try value.encode(bool)
        case .null: try value.encodeNil()
        }
    }

    func decoded<T: Decodable>(_ type: T.Type) throws -> T {
        if case let .object(object) = self, let object = object as? T { return object }
        if case let .array(array) = self, let array = array as? T { return array }
        return try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }

    func decoded<T: Decodable>(_ type: T.Type, at key: String) throws -> T {
        try ConfigurationValue.object([key: self]).decoded([String: T].self)[key]!
    }

    func overriding(_ earlier: ConfigurationValue) -> ConfigurationValue {
        if case let .object(base) = earlier, case let .object(next) = self, !earlier.isGradient, !isGradient {
            return .object(base.merging(next) { $1.overriding($0) })
        }
        return self
    }

    var isGradient: Bool {
        if case let .object(object) = self, case let .object(gradient)? = object["gradient"] { return gradient["colors"] != nil }
        return false
    }
}

struct ConfigurationKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

extension Decoder {
    /// Throws for a property this release doesn't know, unless a file of the configuration was written for a newer
    /// release, and returns the properties it skipped.
    @discardableResult
    func rejectUnknownKeys<Key: CodingKey & CaseIterable>(_: Key.Type, allowing extra: [String] = []) throws -> [String] {
        let container = try container(keyedBy: ConfigurationKey.self)
        let known = Set(Key.allCases.map(\.stringValue) + extra)
        let unknown = container.allKeys.filter { !known.contains($0.stringValue) }
        for key in unknown where NewerConfiguration.current?.skip(codingPath + [key]) != true {
            throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "Unknown property.")
        }
        return unknown.map(\.stringValue)
    }
}

/// StableBar's schema, which saving pins to the tag of the release that saved a file. Every release accepts any
/// `$schema`, so the stamp never stops an older one from reading the file.
enum ConfigurationSchema {
    private static let prefix = "https://raw.githubusercontent.com/Seb-GRAF/StableBar/"
    private static let file = "/stablebar.schema.json"

    static func url(release: String) -> String { "\(prefix)v\(release)\(file)" }

    /// The release a `$schema` pinned to a tag names; nil for `main`, a branch or a schema of one's own.
    static func release(_ schema: ConfigurationValue?) -> String? {
        guard let reference = reference(schema), reference.hasPrefix("v"), reference.dropFirst().first?.isNumber == true else { return nil }
        return String(reference.dropFirst())
    }

    /// The `$schema` of a file `release` saves: the schema at its tag, unless the file already names a newer release
    /// or a schema of its own.
    static func stamped(_ schema: ConfigurationValue?, savedBy release: String) -> ConfigurationValue {
        if let schema, reference(schema) == nil { return schema }
        if let schema, let pinned = self.release(schema), compareReleases(pinned, release) != .orderedAscending { return schema }
        return .string(url(release: release))
    }

    private static func reference(_ schema: ConfigurationValue?) -> String? {
        guard case let .string(url)? = schema, url.hasPrefix(prefix), url.hasSuffix(file), url.count > prefix.count + file.count else { return nil }
        let reference = url.dropFirst(prefix.count).dropLast(file.count)
        return reference.contains("/") ? nil : String(reference)
    }
}

/// While a configuration loads: the newest release its files were written for, when it's newer than this one, and
/// the properties skipped because this release doesn't know them. Nested decodes see it too.
final class NewerConfiguration: Sendable {
    @TaskLocal static var current: NewerConfiguration?
    /// Where a nested decode sits in the configuration, so a skipped property keeps its full path.
    @TaskLocal static var path: [String] = []

    let appVersion: String
    private let state = OSAllocatedUnfairLock<(version: String?, skipped: Set<String>)>(initialState: (nil, []))

    init(appVersion: String) {
        self.appVersion = appVersion
    }

    var version: String? { state.withLock { $0.version } }
    var skipped: [String] { state.withLock { $0.skipped.sorted() } }

    func written(for release: String) {
        guard compareReleases(release, appVersion) == .orderedDescending else { return }
        state.withLock { state in
            if state.version.map({ compareReleases(release, $0) == .orderedDescending }) ?? true { state.version = release }
        }
    }

    /// Skips an unknown property once a file written for a newer release has been read; until then it's an error.
    func skip(_ codingPath: [CodingKey]) -> Bool {
        let path = (Self.path + codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }).joined(separator: ".")
        return state.withLock { state in
            guard state.version != nil else { return false }
            state.skipped.insert(path)
            return true
        }
    }
}

func errorMessage(_ error: Error) -> String {
    let context: DecodingError.Context
    var message: String
    switch error as? DecodingError {
    case let .keyNotFound(key, keyContext)?:
        context = keyContext
        message = "Missing property \(key.stringValue)."
    case let .dataCorrupted(errorContext)?, let .typeMismatch(_, errorContext)?, let .valueNotFound(_, errorContext)?:
        context = errorContext
        message = errorContext.debugDescription
        if let detail = (errorContext.underlyingError as? NSError)?.userInfo[NSDebugDescriptionErrorKey] as? String {
            message += " \(detail)"
        }
    default:
        return error.localizedDescription
    }
    let path = context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
    return path.isEmpty ? message : "\(path): \(message)"
}

enum ConfigurationCompositionError: LocalizedError {
    case includeCycle([URL])
    case unknownTemplate(String)
    case templateCycle([String])
    case unknownWidgetOverride(String)
    case widgetOverrideID(String)
    case duplicateWidgetOrder(String)

    var errorDescription: String? {
        switch self {
        case let .includeCycle(urls): "Configuration include cycle: \(urls.map(\.path).joined(separator: " → "))."
        case let .unknownTemplate(name): "Unknown widget template: \(name)."
        case let .templateCycle(names): "Widget template cycle: \(names.joined(separator: " → "))."
        case let .unknownWidgetOverride(id): "Unknown widget override target: \(id)."
        case let .widgetOverrideID(id): "Widget override \(id) cannot contain an id field."
        case let .duplicateWidgetOrder(id): "Duplicate widget order target: \(id)."
        }
    }
}

func expandWidgetTemplate(_ definition: [String: ConfigurationValue],
                          templates: [String: [String: ConfigurationValue]],
                          path: [String] = []) throws -> [String: ConfigurationValue] {
    guard let reference = definition["template"] else { return definition }
    let name = try reference.decoded(String.self)
    guard !path.contains(name) else {
        throw ConfigurationCompositionError.templateCycle(path + [name])
    }
    guard let template = templates[name] else {
        throw ConfigurationCompositionError.unknownTemplate(name)
    }
    var expanded = try expandWidgetTemplate(template, templates: templates, path: path + [name]).merging(definition) { $1.overriding($0) }
    expanded["template"] = nil
    return expanded
}

struct ConfigurationOrigin: Equatable, Sendable, CustomStringConvertible {
    let file: String
    var detail = ""
    var token: String?
    var tokenSource = ""
    var profile: String?

    var description: String {
        [file, detail, token.map { "→ token \($0) (\(tokenSource))" } ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
    }

    func appending(_ text: String) -> ConfigurationOrigin {
        var origin = self
        origin.detail = detail.isEmpty ? text : "\(detail) \(text)"
        return origin
    }

    func inProfile(_ name: String) -> ConfigurationOrigin {
        var origin = appending("(profile \(name))")
        origin.profile = name
        return origin
    }
}

/// A theme shown in place of the selected one, such as one being tried.
struct PreviewTheme {
    let id: String
    let layer: ConfigurationLayer
}

struct ConfigurationLayer {
    var values: [String: ConfigurationValue]
    var origins: [String: ConfigurationOrigin]
    var contributions: [String: [ConfigurationContribution]]

    init(values: [String: ConfigurationValue], origins: [String: ConfigurationOrigin]) {
        self.values = values
        self.origins = origins
        contributions = [:]
        visitConfigurationValues(.object(values)) { path, value in
            if let origin = origins[path] {
                contributions[path] = [ConfigurationContribution(value: value, origin: origin)]
            }
        }
    }

    mutating func merge(_ next: ConfigurationLayer) throws {
        let widgets = try (values["widgets"]?.decoded([ConfigurationValue].self) ?? [])
            + (next.values["widgets"]?.decoded([ConfigurationValue].self) ?? [])
        let previous = values
        let previousProfiles = values["profiles"]
        values.merge(next.values) { $1.overriding($0) }
        if let profiles = next.values["profiles"] {
            values["profiles"] = .array(try mergeProfiles(previousProfiles, with: profiles).map(ConfigurationValue.object))
        }
        for key in ["packages", "packageSources"] {
            if let entries = next.values[key] {
                values[key] = try mergeByID(previous[key], with: entries)
            }
        }
        values["widgets"] = .array(widgets)
        origins.merge(next.origins) { $1 }
        contributions.merge(next.contributions) { $0 + $1 }
    }
}

/// Merges two arrays of objects that have an `id`: a later entry changes the earlier one with the same id, and new ids are appended.
private func mergeByID(_ previous: ConfigurationValue?, with next: ConfigurationValue) throws -> ConfigurationValue {
    var entries = try previous?.decoded([[String: ConfigurationValue]].self) ?? []
    for entry in try next.decoded([[String: ConfigurationValue]].self) {
        let id = try (entry["id"] ?? .null).decoded(String.self)
        if let index = entries.firstIndex(where: { $0["id"] == .string(id) }) {
            entries[index].merge(entry) { $1.overriding($0) }
        } else {
            entries.append(entry)
        }
    }
    return .array(entries.map(ConfigurationValue.object))
}

struct ConfigurationContribution: Equatable, Sendable {
    let value: ConfigurationValue
    var origin: ConfigurationOrigin
    var settingValue: ConfigurationValue?
}

func mergeProfiles(_ earlier: ConfigurationValue?, with next: ConfigurationValue) throws -> [[String: ConfigurationValue]] {
    var profiles = try earlier?.decoded([[String: ConfigurationValue]].self) ?? []
    var names = Set<String>()
    for profile in try next.decoded([[String: ConfigurationValue]].self) {
        let name = try (profile["name"] ?? .null).decoded(String.self)
        guard names.insert(name).inserted else { throw ThemeConfigurationError.duplicateProfile(name) }
        if let index = profiles.firstIndex(where: { $0["name"] == .string(name) }) {
            profiles[index].merge(profile) { $1.overriding($0) }
        } else {
            profiles.append(profile)
        }
    }
    return profiles
}

func configurationOrigins(_ value: ConfigurationValue, source: ConfigurationOrigin, path: String = "") -> [String: ConfigurationOrigin] {
    var origins: [String: ConfigurationOrigin] = [:]
    visitConfigurationValues(value, path: path) { path, _ in origins[path] = source }
    return origins
}

func configurationValues(_ value: ConfigurationValue, path: String = "") -> [String: ConfigurationValue] {
    var values: [String: ConfigurationValue] = [:]
    visitConfigurationValues(value, path: path) { path, value in values[path] = value }
    return values
}

private func visitConfigurationValues(_ value: ConfigurationValue, path: String = "",
                                      visit: (String, ConfigurationValue) throws -> Void) rethrows {
    if !path.isEmpty { try visit(path, value) }
    switch value {
    case let .object(object):
        for (key, value) in object {
            let child = path.isEmpty ? key : "\(path).\(key)"
            try visitConfigurationValues(value, path: child, visit: visit)
        }
    case let .array(array):
        for (index, value) in array.enumerated() {
            var key = String(index)
            // Sources merge by id across files, so their paths use the id too, and origins name the file that defined each one.
            if (path == "widgets" || path.hasSuffix(".configuration.widgets") || path == "packageSources"),
               case let .object(widget) = value, case let .string(id) = widget["id"] {
                key = id
            } else if path == "profiles", case let .object(profile) = value, case let .string(name) = profile["name"] {
                key = name
            }
            try visitConfigurationValues(value, path: "\(path).\(key)", visit: visit)
        }
    default: break
    }
}

// Flat paths repeat ancestor keys; count bytes when token origins are stored or copied.
private struct ConfigurationOriginPathBudget {
    private static let maximumProcessedPathBytes = 4_000_000
    private var remaining = Self.maximumProcessedPathBytes
    private let shared: ConfigurationReferenceExpansionBudget?

    init(shared: ConfigurationReferenceExpansionBudget? = nil) {
        self.shared = shared
    }

    mutating func record(_ path: String, token: String) throws {
        try shared?.recordOriginPath(path, token: token)
        remaining -= path.utf8.count
        guard remaining >= 0 else { throw ThemeConfigurationError.referenceOriginsTooLarge(token) }
    }
}

struct ConfigurationPathIndex<Value> {
    private struct Node {
        var children: [Substring: Int] = [:]
        var isPrefix = false
        var entry: (path: String, value: Value)?
    }

    private var nodes = [Node()]

    var storedPathCount: Int { nodes.reduce(0) { $0 + ($1.entry == nil ? 0 : 1) } }

    init(_ entries: some Sequence<(key: String, value: Value)>, prefixes: Set<String>) {
        for prefix in prefixes {
            var node = 0
            for part in prefix.split(separator: ".", omittingEmptySubsequences: false) {
                node = child(part, under: node)
            }
            nodes[node].isPrefix = true
        }
        for (path, value) in entries { insert(value, at: path) }
    }

    subscript(prefix: String) -> [String: Value] {
        var node = 0
        for part in prefix.split(separator: ".", omittingEmptySubsequences: false) {
            guard let child = nodes[node].children[part] else { return [:] }
            node = child
        }
        guard nodes[node].isPrefix else { return [:] }
        var result: [String: Value] = [:]
        var pending = Array(nodes[node].children.values)
        let offset = prefix.count + 1
        while let descendant = pending.popLast() {
            if let entry = nodes[descendant].entry {
                result[String(entry.path.dropFirst(offset))] = entry.value
            }
            pending.append(contentsOf: nodes[descendant].children.values)
        }
        return result
    }

    mutating func insert(_ value: Value, at path: String) {
        var node = 0
        var withinPrefix = false
        for part in path.split(separator: ".", omittingEmptySubsequences: false) {
            withinPrefix = withinPrefix || nodes[node].isPrefix
            if let child = nodes[node].children[part] {
                node = child
            } else {
                guard withinPrefix else { return }
                node = child(part, under: node)
            }
        }
        // Overlapping dotted ids share this entry; suffixes exist only while a prefix is queried.
        if withinPrefix { nodes[node].entry = (path, value) }
    }

    private mutating func child(_ part: Substring, under parent: Int) -> Int {
        if let child = nodes[parent].children[part] { return child }
        let child = nodes.count
        nodes.append(Node())
        nodes[parent].children[part] = child
        return child
    }
}

let bundledThemesDirectory = Bundle.main.url(forResource: "themes", withExtension: nil)
/// The Store's packages of the themes that moved to the Store, which an update installs without the network.
let storeThemesDirectory = Bundle.main.url(forResource: "store-themes", withExtension: nil)

struct ConfigurationLoader: Sendable {
    var themesDirectory = bundledThemesDirectory
    var referenceExpansionBudget: ConfigurationReferenceExpansionBudget?
    /// The release that reads the configuration; without one, as in development builds, every file is read strictly.
    var appVersion = AppVersion.release
    /// The newest release a file of the configuration was written for, when it's newer than `appVersion`.
    private(set) var newerVersion: String?
    /// The properties skipped because a file was written for a newer release and this one doesn't know them.
    private(set) var skippedProperties: [String] = []
    private(set) var dependencies: Set<URL> = []
    private(set) var document: [String: ConfigurationValue] = [:]
    private(set) var origins: [String: ConfigurationOrigin] = [:]
    private(set) var contributions: [String: [ConfigurationContribution]] = [:]
    private(set) var widgetPackageNames: [String: String] = [:]
    private(set) var widgetPackageIDs: [String: String] = [:]
    private(set) var builtInWidgetIDs: Set<String> = []
    private(set) var activeProfiles: [String] = []
    private(set) var profiles: [ConfigurationProfile] = []
    /// The files that define each profile, by name: the main file, includes, packages and the theme.
    private(set) var profileFiles: [String: Set<String>] = [:]
    private(set) var pinnedProfile: String?
    var previewProfile: String?
    /// What profiles were matched against: the Mac's state, with the bar's fixed appearance and its theme.
    private(set) var profileContext = ConfigurationContext()
    private(set) var matchesApps = false
    private(set) var matchesDisplays = false
    private(set) var templates: [String: [String: ConfigurationValue]] = [:]
    private(set) var screenDocuments: [String: [String: ConfigurationValue]] = [:]
    private var packageBoundaries: [String: URL] = [:]
    private(set) var packageNames: [String: String] = [:]
    private(set) var packageIDs: [String: String] = [:]
    private var packageHosts: [String: [String]] = [:]
    private var essentialsPopupNames: [String: String] = [:]

    /// What the bar warns about when it skipped properties of a configuration written for a newer release.
    var newerVersionWarning: String? {
        guard let newerVersion, let appVersion, !skippedProperties.isEmpty else { return nil }
        let listed = skippedProperties.prefix(5).joined(separator: ", ")
            + (skippedProperties.count > 5 ? " and \(skippedProperties.count - 5) more" : "")
        return "This configuration was written for StableBar \(newerVersion), so \(appVersion) skips \(listed). Update StableBar to use them."
    }

    mutating func load(_ url: URL, data: Data? = nil,
                       context: ConfigurationContext = ConfigurationContext(),
                       previewTheme: PreviewTheme? = nil) throws -> Configuration {
        try readingNewerFiles { loader in
            var configuration = try ConfigurationValue.object(loader.compose(url, data: data, context: context, previewTheme: previewTheme))
                .decoded(Configuration.self)
            for name in configuration.providers.keys {
                configuration.providers[name]!.hosts = loader.origins["providers.\(name).url"].flatMap { loader.packageHosts[$0.file] }
            }
            loader.screenDocuments = [:]
            for kind in configuration.screensWithOwnLook {
                var screenLoader = loader
                let document = try screenLoader.compose(url, data: data, context: context, previewTheme: previewTheme, screen: kind)
                do { configuration.screenLooks[kind.rawValue] = try ConfigurationValue.object(document).decoded(Configuration.self) }
                catch { throw CommandFailure(message: "screens.\(kind.rawValue): \(errorMessage(error))") }
                loader.screenDocuments[kind.rawValue] = document
                loader.dependencies.formUnion(screenLoader.dependencies)
            }
            return configuration
        }
    }

    mutating func compose(_ url: URL, data: Data? = nil,
                          context: ConfigurationContext = ConfigurationContext(),
                          previewTheme: PreviewTheme? = nil, screen: ScreenKind? = nil) throws -> [String: ConfigurationValue] {
        try readingNewerFiles { try $0.composeFiles(url, data: data, context: context, previewTheme: previewTheme, screen: screen) }
    }

    /// Reads a file written for a newer release, a configuration file pinned to its tag or a package that needs it,
    /// leniently: from then on, the properties this release doesn't know are skipped instead of rejected.
    private mutating func readingNewerFiles<T>(_ body: (inout ConfigurationLoader) throws -> T) throws -> T {
        if NewerConfiguration.current != nil { return try body(&self) }
        guard let appVersion else {
            (newerVersion, skippedProperties) = (nil, [])
            return try body(&self)
        }
        let newer = NewerConfiguration(appVersion: appVersion)
        defer { (newerVersion, skippedProperties) = (newer.version, newer.skipped) }
        do {
            return try NewerConfiguration.$current.withValue(newer) { try body(&self) }
        } catch {
            guard let version = newer.version else { throw error }
            throw CommandFailure(message: "\(errorMessage(error)) This configuration was written for StableBar \(version), "
                                 + "and this is \(appVersion). Update StableBar to load it.")
        }
    }

    private mutating func composeFiles(_ url: URL, data: Data?, context: ConfigurationContext,
                                       previewTheme: PreviewTheme?, screen: ScreenKind?) throws -> [String: ConfigurationValue] {
        dependencies = []
        activeProfiles = []
        packageBoundaries = [:]
        packageNames = [:]
        packageIDs = [:]
        packageHosts = [:]
        widgetPackageNames = [:]
        widgetPackageIDs = [:]
        builtInWidgetIDs = []
        essentialsPopupNames = [:]
        var base = try read(url.standardizedFileURL, data: data, path: [])
        var theme = base.values["theme"]
        if let screen, let look = try base.values["screens"]?.decoded([String: [String: ConfigurationValue]].self)[screen.rawValue] {
            theme = look["theme"] ?? theme
            for key in ["bar", "tokens", "defaults", "popupDefaults", "groupDefaults", "roles", "workspaceDefaults", "modeAliases"] {
                guard let value = look[key] else { continue }
                base.values[key] = value.overriding(base.values[key] ?? .object([:]))
                let prefix = "screens.\(screen.rawValue).\(key)"
                for (path, origin) in base.origins where path.hasPrefix(prefix) { base.origins[key + path.dropFirst(prefix.count)] = origin }
                for (path, entries) in base.contributions where path.hasPrefix(prefix) { base.contributions[key + path.dropFirst(prefix.count)] = entries }
            }
        }
        let packageStore = WidgetPackageStore(directory: url.deletingLastPathComponent().appending(path: "packages"))
        var layer = ConfigurationLayer(values: ["widgets": .array([])], origins: [:])
        for selection in try base.values["packages"]?.decoded([WidgetPackageSelection].self, at: "packages") ?? [] where selection.enabled {
            try layer.merge(readSelectedPackage(selection, from: packageStore, theme: false))
        }
        if themesDirectory != nil {
            try layer.merge(readBundledTheme(WidgetPackageSelection(id: "built-in")))
        }
        var context = context
        context.theme = "built-in"
        if let previewTheme {
            try layer.merge(previewTheme.layer)
            context.theme = previewTheme.id
        } else if let theme = try theme?.decoded(WidgetPackageSelection.self, at: "theme"), theme.enabled {
            try layer.merge(theme.version == nil ? readBundledTheme(theme) : readSelectedPackage(theme, from: packageStore, theme: true))
            context.theme = theme.id
        }
        try layer.merge(base)
        try validatePackageURLs(layer, packageIDs: packageIDs)
        return try finish(layer, context: context)
    }

    private mutating func readSelectedPackage(_ selection: WidgetPackageSelection, from packageStore: WidgetPackageStore,
                                              theme: Bool) throws -> ConfigurationLayer {
        guard let version = selection.version else { throw WidgetPackageError.missingVersion(selection.id) }
        let directory = try packageStore.directory(id: selection.id, version: version)
        dependencies.insert(directory.appending(path: "package.json"))
        let manifest = try packageStore.manifest(at: directory)
        guard manifest.id == selection.id, manifest.version == version else {
            throw WidgetPackageError.manifestMismatch
        }
        guard (manifest.kind == .theme) == theme else {
            throw theme ? WidgetPackageError.notATheme(selection.id) : WidgetPackageError.themeInPackages(selection.id)
        }
        try packageStore.validateContents(at: directory)
        let layer = try readPackage(at: directory, manifest: manifest, settings: selection.settings)
        guard !theme, WidgetAddCatalog.builtIns.contains(where: { $0.replacesPackage == manifest.id }) else { return layer }
        guard WidgetAddCatalog.includes(manifest, record: try packageStore.record(id: manifest.id)) else { return layer }
        builtInWidgetIDs.insert(manifest.id)
        let widget = try layer.values["widgets"]!.decoded([[String: ConfigurationValue]].self)[0]
        essentialsPopupNames[manifest.id] = try widget["popupName"]?.decoded(String.self)
        return try upgradedEssentialsPackage(layer, manifest: manifest, settings: selection.settings)
    }

    private mutating func readBundledTheme(_ selection: WidgetPackageSelection) throws -> ConfigurationLayer {
        guard let themesDirectory, FileManager.default.fileExists(atPath: themesDirectory.appending(path: "\(selection.id)/package.json").path) else {
            throw WidgetPackageError.unknownTheme(selection.id)
        }
        let directory = themesDirectory.appending(path: selection.id)
        let manifest = try WidgetPackageStore(directory: themesDirectory).manifest(at: directory)
        return try readPackage(at: directory, manifest: manifest, settings: selection.settings)
    }

    mutating func finish(_ input: ConfigurationLayer, context: ConfigurationContext) throws -> [String: ConfigurationValue] {
        var layer = input
        var context = context
        if case let .object(bar) = layer.values["bar"], let appearance = bar["appearance"],
           case let .string(name) = try substituteConfigurationReferences(appearance, prefix: "@token.",
                                                                          values: layer.values["tokens"]?.decoded([String: ConfigurationValue].self) ?? [:],
                                                                          budget: referenceExpansionBudget) {
            context.appearance = name
        }
        profileContext = context
        activeProfiles = []
        profiles = try layer.values["profiles"]?.decoded([ConfigurationProfile].self, at: "profiles") ?? []
        profileFiles = Dictionary(profiles.map { profile in
            (profile.name, Set(layer.contributions["profiles.\(profile.name).name"]?.map(\.origin.file) ?? []))
        }) { $0.union($1) }
        matchesApps = profiles.contains { $0.enabled && $0.when?.appList != nil }
        matchesDisplays = profiles.contains { $0.enabled && $0.when?.display != nil }
        let selected = try previewProfile ?? layer.values["profile"].flatMap { try $0.decoded(String?.self) }
        pinnedProfile = selected
        var names = Set<String>()
        for profile in profiles {
            guard names.insert(profile.name).inserted else { throw ThemeConfigurationError.duplicateProfile(profile.name) }
            if profile.configuration["packageSources"] != nil { throw PackageSourceError.inProfile(profile.name) }
        }
        if let selected, !names.contains(selected) { throw ThemeConfigurationError.unknownProfile(selected) }
        for profile in profiles where profile.enabled || profile.name == previewProfile {
            // A theme's edits belong to its look, so they still apply while another profile is pinned.
            let matches = selected.map { $0 == profile.name || profile.when?.onlyTheme != nil && profile.when!.matches(context) }
                ?? (profile.when?.matches(context) ?? true)
            if matches {
                let source = layer.origins["profiles.\(profile.name).name"]!.inProfile(profile.name)
                var origins = configurationOrigins(.object(profile.configuration), source: source)
                let prefix = "profiles.\(profile.name).configuration."
                for (path, origin) in layer.origins where path.hasPrefix(prefix) {
                    origins[String(path.dropFirst(prefix.count))] = origin.inProfile(profile.name)
                }
                var profileLayer = ConfigurationLayer(values: profile.configuration, origins: origins)
                for (path, entries) in layer.contributions where path.hasPrefix(prefix) {
                    profileLayer.contributions[String(path.dropFirst(prefix.count))] = entries.map {
                        var entry = $0
                        entry.origin = entry.origin.inProfile(profile.name)
                        return entry
                    }
                }
                try layer.merge(profileLayer)
                activeProfiles.append(profile.name)
            }
        }
        for key in ["profiles", "profile"] { layer.values.removeValue(forKey: key) }
        let tokens = try layer.values["tokens"]?.decoded([String: ConfigurationValue].self) ?? [:]
        let beforeTokens = layer.values
        layer.values = try substituteConfigurationReferences(.object(layer.values), prefix: "@token.", values: tokens,
                                                            budget: referenceExpansionBudget)
            .decoded([String: ConfigurationValue].self)
        var originBudget = ConfigurationOriginPathBudget(shared: referenceExpansionBudget)
        let tokenSources = layer.origins
        try tokenOrigins(.object(beforeTokens), origins: tokenSources, tokens: tokens, into: &layer.origins, budget: &originBudget)
        templates = try layer.values["templates"]?.decoded([String: [String: ConfigurationValue]].self) ?? [:]
        let overrides = try layer.values["widgetOverrides"]?.decoded([String: [String: ConfigurationValue]].self) ?? [:]
        let definitions = try layer.values["widgets"]!.decoded([[String: ConfigurationValue]].self)
        // A widget can inherit its id from a template.
        let sourceIDs = (definitions + Array(templates.values)).compactMap { definition -> String? in
            guard case let .string(id)? = definition["id"] else { return nil }
            return id
        }
        let prefixes = Set(sourceIDs.flatMap { ["widgets.\($0)", "widgetOverrides.\($0)"] }
            + templates.keys.map { "templates.\($0)" } + essentialsPopupNames.values.map { "popups.\($0)" })
        var originIndex = ConfigurationPathIndex(layer.origins, prefixes: prefixes)
        var contributionIndex = ConfigurationPathIndex(layer.contributions, prefixes: prefixes)
        var widgets: [[String: ConfigurationValue]] = []
        for definition in definitions {
            var expanded = try expandWidgetTemplate(definition, templates: templates)
            let id = try (expanded["id"] ?? .null).decoded(String.self)
            if let popup = essentialsPopupNames[id],
               originIndex["popups.\(popup)"].values.contains(where: { source in
                   source.file != layer.origins["widgets.\(id).id"]!.file
               }) {
                expanded["popupName"] = .string(popup)
            }
            if let properties = overrides[id] {
                guard properties["id"] == nil else { throw ConfigurationCompositionError.widgetOverrideID(id) }
                expanded.merge(properties) { $1.overriding($0) }
            }
            var propertyOrigins = try templateOrigins(definition, templates: templates, origins: originIndex)
            var propertyContributions = try templateContributions(definition, templates: templates, contributions: contributionIndex)
            let widgetPrefix = "widgets.\(id)"
            propertyOrigins.merge(originIndex[widgetPrefix]) { $1 }
            let overridePrefix = "widgetOverrides.\(id)"
            for (path, entries) in contributionIndex[widgetPrefix] {
                propertyContributions[path, default: []] += entries
            }
            for (path, source) in originIndex[overridePrefix] {
                propertyOrigins[path] = source.appending("(widget override)")
            }
            for (path, entries) in contributionIndex[overridePrefix] {
                propertyContributions[path, default: []] += entries.map {
                    var entry = $0
                    entry.origin = entry.origin.appending("(widget override)")
                    return entry
                }
            }
            for (path, source) in propertyOrigins {
                let destination = "\(widgetPrefix).\(path)"
                if let token = source.token { try originBudget.record(destination, token: token) }
                layer.origins[destination] = source
                originIndex.insert(source, at: destination)
            }
            for (path, entries) in propertyContributions {
                let destination = "\(widgetPrefix).\(path)"
                layer.contributions[destination] = entries
                contributionIndex.insert(entries, at: destination)
            }
            widgets.append(expanded)
        }
        let ids = try widgets.map { try $0["id"]!.decoded(String.self) }
        var uniqueIDs = Set<String>()
        for id in ids where !uniqueIDs.insert(id).inserted {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Duplicate widget id: \(id). Each widget needs a stable, unique id."))
        }
        for id in overrides.keys where !ids.contains(id) {
            throw ConfigurationCompositionError.unknownWidgetOverride(id)
        }
        let order = try (layer.values["widgetOrder"]?.decoded([String].self) ?? []).filter(ids.contains)
        var orderedIDs = Set<String>()
        for id in order where !orderedIDs.insert(id).inserted {
            throw ConfigurationCompositionError.duplicateWidgetOrder(id)
        }
        let ordered = order.compactMap { id in widgets.first { $0["id"] == .string(id) } }
            + zip(ids, widgets).filter { !orderedIDs.contains($0.0) }.map(\.1)
        layer.values["widgets"] = .array(ordered.map { .object($0) })
        for key in ["templates", "widgetOverrides", "includes", "widgetOrder"] {
            layer.values.removeValue(forKey: key)
        }
        var finalPaths = Set<String>()
        visitConfigurationValues(.object(layer.values)) { path, _ in
            finalPaths.insert(path)
        }
        document = try preparePackageAssets(.object(layer.values), origins: layer.origins, boundaries: packageBoundaries)
            .decoded([String: ConfigurationValue].self)
        origins = layer.origins.filter { finalPaths.contains($0.key) }
        // Profile paths stay so Settings can tell which files set a profile's conditions.
        contributions = layer.contributions.filter { finalPaths.contains($0.key) || $0.key.hasPrefix("profiles.") }
        widgetPackageNames = Dictionary(uniqueKeysWithValues: ids.compactMap { id in
            guard let source = origins["widgets.\(id).id"], let name = packageNames[source.file] else { return nil }
            return (id, name)
        })
        widgetPackageIDs = Dictionary(uniqueKeysWithValues: ids.compactMap { id in
            guard let source = origins["widgets.\(id).id"], let package = packageIDs[source.file] else { return nil }
            return (id, package)
        })
        return document
    }

    private func tokenOrigins(_ value: ConfigurationValue, path: String = "", inheritedSource: ConfigurationOrigin = ConfigurationOrigin(file: ""),
                              origins: [String: ConfigurationOrigin], tokens: [String: ConfigurationValue],
                              into result: inout [String: ConfigurationOrigin], budget: inout ConfigurationOriginPathBudget) throws {
        let source = origins[path] ?? inheritedSource
        switch value {
        case let .string(reference) where reference.hasPrefix("@token."):
            let name = String(reference.dropFirst(7))
            let resolved = try substituteConfigurationReferences(value, prefix: "@token.", values: tokens,
                                                                budget: referenceExpansionBudget)
            var origin = source
            origin.token = name
            origin.tokenSource = origins["tokens.\(name)"]!.description
            try visitConfigurationValues(resolved, path: path) { path, _ in
                try budget.record(path, token: name)
                result[path] = origin
            }
        case let .object(object):
            for (key, child) in object {
                try tokenOrigins(child, path: path.isEmpty ? key : "\(path).\(key)",
                                 inheritedSource: source, origins: origins, tokens: tokens, into: &result, budget: &budget)
            }
        case let .array(array):
            for (index, child) in array.enumerated() {
                var key = String(index)
                if path == "widgets", case let .object(widget) = child, case let .string(id) = widget["id"] { key = id }
                try tokenOrigins(child, path: "\(path).\(key)", inheritedSource: source, origins: origins, tokens: tokens,
                                 into: &result, budget: &budget)
            }
        default: break
        }
    }

    private func templateOrigins(_ definition: [String: ConfigurationValue],
                                 templates: [String: [String: ConfigurationValue]],
                                 origins: ConfigurationPathIndex<ConfigurationOrigin>) throws -> [String: ConfigurationOrigin] {
        guard let reference = definition["template"] else { return [:] }
        let name = try reference.decoded(String.self)
        var inherited = try templateOrigins(templates[name]!, templates: templates, origins: origins)
        for (path, source) in origins["templates.\(name)"] {
            inherited[path] = source.appending("(template \(name))")
        }
        return inherited
    }

    private func templateContributions(_ definition: [String: ConfigurationValue],
                                       templates: [String: [String: ConfigurationValue]],
                                       contributions: ConfigurationPathIndex<[ConfigurationContribution]>) throws -> [String: [ConfigurationContribution]] {
        guard let reference = definition["template"] else { return [:] }
        let name = try reference.decoded(String.self)
        var inherited = try templateContributions(templates[name]!, templates: templates, contributions: contributions)
        for (path, entries) in contributions["templates.\(name)"] {
            inherited[path, default: []] += entries.map {
                var entry = $0
                entry.origin = entry.origin.appending("(template \(name))")
                return entry
            }
        }
        return inherited
    }

    private mutating func read(_ url: URL, data: Data? = nil, path: [URL], boundary: URL? = nil) throws -> ConfigurationLayer {
        dependencies.insert(url)
        let canonical = url.resolvingSymlinksInPath()
        if let boundary {
            try validatePackagePath(url, inside: boundary)
            packageBoundaries[url.path] = boundary
        }
        guard !path.contains(canonical) else {
            throw ConfigurationCompositionError.includeCycle(path + [canonical])
        }
        var values = try JSONDecoder().decode([String: ConfigurationValue].self, from: data ?? Data(contentsOf: url))
        do { values = try movingCustomization(values) }
        catch { throw CommandFailure(message: "\(url.lastPathComponent): \(errorMessage(error))") }
        if let release = ConfigurationSchema.release(values["$schema"]) { NewerConfiguration.current?.written(for: release) }
        let includes = try values.removeValue(forKey: "includes")?.decoded([String].self) ?? []
        var merged = ConfigurationLayer(values: ["widgets": .array([])], origins: [:])
        if boundary != nil, values["packages"] != nil { throw WidgetPackageError.nestedPackages }
        if boundary != nil, values["packageSources"] != nil { throw PackageSourceError.inPackage }
        if let sources = try values["packageSources"]?.decoded([[String: ConfigurationValue]].self) {
            var ids = Set<String>()
            for case let .string(id)? in sources.map({ $0["id"] }) {
                guard ids.insert(id).inserted else { throw PackageSourceError.duplicateID(id) }
            }
        }
        for include in includes {
            let file = URL(fileURLWithPath: (include as NSString).expandingTildeInPath,
                           relativeTo: url.deletingLastPathComponent()).standardizedFileURL
            try merged.merge(read(file, path: path + [canonical], boundary: boundary))
        }
        try merged.merge(ConfigurationLayer(values: values, origins: configurationOrigins(.object(values), source: ConfigurationOrigin(file: url.path))))
        return merged
    }

    mutating func readPackage(at directory: URL, manifest: WidgetPackageManifest,
                                      settings: [String: ConfigurationValue]) throws -> ConfigurationLayer {
        dependencies.insert(directory.appending(path: "package.json"))
        if let minimumVersion = manifest.minimumVersion { NewerConfiguration.current?.written(for: minimumVersion) }
        let entry = try packageFile(manifest.entry, inside: directory)
        var layer = try read(entry, path: [], boundary: directory)
        switch manifest.kind {
        case .theme?: try validateThemeDocument(layer.values)
        case .widgets?: try validateWidgetsDocument(layer.values)
        case nil: try validateCommandPackagePresentation(layer.values)
        }
        var values = try manifest.values(settings)
        for (name, setting) in manifest.settings where setting.type == "secret" {
            values[name] = .string("@secret.\(manifest.id)/\(name)")
        }
        layer.values = try substituteConfigurationReferences(.object(layer.values), prefix: "@setting.", values: values,
                                                            budget: referenceExpansionBudget)
            .decoded([String: ConfigurationValue].self)
        layer.contributions = try layer.contributions.mapValues { entries in
            try entries.map {
                var entry = $0
                do {
                    entry.settingValue = try substituteConfigurationReferences(entry.value, prefix: "@setting.", values: values,
                                                                              budget: referenceExpansionBudget)
                } catch {
                    entry.settingValue = nil
                    if referenceExpansionBudget != nil,
                       case .referenceExpansionTooLarge? = error as? ThemeConfigurationError {
                        throw error
                    }
                }
                return entry
            }
        }
        try validateSecretReferences(.object(layer.values), package: manifest.id)
        try validatePackageHosts(layer.values, manifest: manifest)
        layer.values = try preparePackageDocument(layer.values, directory: directory)
        for source in layer.origins.values {
            packageNames[source.file] = manifest.name
            packageIDs[source.file] = manifest.id
            packageHosts[source.file] = manifest.hosts
        }
        return layer
    }
}

@MainActor
final class ConfigurationWatcher {
    var onChange: (() -> Void)?
    private var sources: [DispatchSourceFileSystemObject] = []
    private(set) var generation = 0

    func watch(_ urls: Set<URL>) {
        stop()
        let generation = generation
        var targets = urls
        for url in urls {
            var directory = url.deletingLastPathComponent()
            while !FileManager.default.fileExists(atPath: directory.path) {
                directory.deleteLastPathComponent()
            }
            targets.insert(directory)
        }
        for url in targets {
            let descriptor = open(url.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in
                Task { @MainActor in
                    guard let self, self.generation == generation else { return }
                    self.onChange?()
                }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            sources.append(source)
        }
    }

    func stop() {
        generation += 1
        for source in sources { source.cancel() }
        sources.removeAll()
    }
}
