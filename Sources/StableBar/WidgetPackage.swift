import CryptoKit
import Foundation

struct WidgetPackageSetting: Codable, Sendable {
    let type: String
    let title: String?
    let description: String?
    let choices: [String]?
    let `default`: ConfigurationValue?

    enum CodingKeys: String, CodingKey, CaseIterable { case type, title, description, choices, `default` }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = try values.decode(String.self, forKey: .type)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        description = try values.decodeIfPresent(String.self, forKey: .description)
        choices = try values.decodeIfPresent([String].self, forKey: .choices)
        `default` = try values.decodeIfPresent(ConfigurationValue.self, forKey: .default)
        if let choices, type != "string" || choices.isEmpty {
            throw DecodingError.dataCorruptedError(forKey: .choices, in: values, debugDescription: "Choices need a string setting and at least one value.")
        }
    }

    func accepts(_ value: ConfigurationValue?) -> Bool {
        switch (type, value) {
        case let ("string", .string(text)?): return choices?.contains(text) ?? true
        case ("number", .number?), ("bool", .bool?), ("secret", nil): return true
        default: return false
        }
    }
}

struct WidgetPackageManifest: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case theme, widgets }
    enum Permission: String, Codable, Sendable { case calendars, automation, accessibility, bluetooth, location }

    let id: String
    let name: String
    let version: String
    let kind: Kind?
    let entry: String
    let settings: [String: WidgetPackageSetting]
    let description: String?
    let author: String?
    let repository: URL?
    let screenshot: String?
    let minimumVersion: String?
    let requires: [String]
    let permissions: [Permission]
    let hosts: [String]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name, version, kind, entry, settings, description, author, repository, screenshot, minimumVersion, requires, permissions, hosts
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        version = try values.decode(String.self, forKey: .version)
        kind = try values.decodeIfPresent(Kind.self, forKey: .kind)
        entry = try values.decode(String.self, forKey: .entry)
        settings = try values.decodeIfPresent([String: WidgetPackageSetting].self, forKey: .settings) ?? [:]
        description = try values.decodeIfPresent(String.self, forKey: .description)
        author = try values.decodeIfPresent(String.self, forKey: .author)
        repository = try values.decodeIfPresent(URL.self, forKey: .repository)
        if let repository, repository.scheme != "https" {
            throw DecodingError.dataCorruptedError(forKey: .repository, in: values, debugDescription: "Use an https URL.")
        }
        screenshot = try values.decodeIfPresent(String.self, forKey: .screenshot)
        minimumVersion = try values.decodeIfPresent(String.self, forKey: .minimumVersion)
        requires = try values.decodeIfPresent([String].self, forKey: .requires) ?? []
        permissions = try values.decodeIfPresent([Permission].self, forKey: .permissions) ?? []
        hosts = try values.decodeIfPresent([String].self, forKey: .hosts) ?? []
        try validatePackageComponent(id)
        try validatePackageComponent(version)
        for (name, setting) in settings where !setting.accepts(setting.default) {
            throw WidgetPackageError.invalidSetting(name)
        }
    }

    func values(_ supplied: [String: ConfigurationValue]) throws -> [String: ConfigurationValue] {
        var values = settings.compactMapValues(\.default)
        for (name, value) in supplied {
            guard let setting = settings[name] else { throw WidgetPackageError.unknownSetting(name) }
            guard setting.accepts(value) else { throw WidgetPackageError.invalidSetting(name) }
            values[name] = value
        }
        return values
    }

    func missingTools(path: String) -> [String] {
        requires.filter { tool in
            !path.split(separator: ":").contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(tool)") }
        }
    }
}

struct WidgetPackageSelection: Decodable {
    let id: String
    var version: String?
    var enabled = true
    var settings: [String: ConfigurationValue] = [:]

    enum CodingKeys: String, CodingKey, CaseIterable { case id, version, enabled, settings }

    init(id: String) {
        self.id = id
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        version = try values.decodeIfPresent(String.self, forKey: .version)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        settings = try values.decodeIfPresent([String: ConfigurationValue].self, forKey: .settings) ?? [:]
        try validatePackageComponent(id)
        if let version { try validatePackageComponent(version) }
    }

    var key: String { version.map { "\(id)/\($0)" } ?? id }
}

struct WidgetPackageInspection: Sendable {
    let manifest: WidgetPackageManifest
    let directory: URL
    let commands: [String]
    let screenshot: URL?
    let widgets: [WidgetConfiguration]

    var requiresReview: Bool {
        !commands.isEmpty || !manifest.permissions.isEmpty || !manifest.hosts.isEmpty || !manifest.requires.isEmpty
            || manifest.settings.values.contains { $0.type == "secret" }
    }

    func additions(since previous: WidgetPackageInspection) -> [String] {
        commands.filter { !previous.commands.contains($0) }.map { "Command: \($0)" }
            + manifest.hosts.filter { !previous.manifest.hosts.contains($0) }.map { "Host: \($0)" }
            + manifest.permissions.filter { !previous.manifest.permissions.contains($0) }.map { "Permission: \($0.rawValue.capitalized)" }
    }
}

enum WidgetPackageError: LocalizedError {
    case invalidComponent(String)
    case outsidePackage(String)
    case missingFile(String)
    case alreadyInstalled(String, String)
    case unknownSetting(String)
    case invalidSetting(String)
    case nestedPackages
    case manifestMismatch
    case notATheme(String)
    case themeInPackages(String)
    case themeProperty(String)
    case widgetsProperty(String)
    case widgetPresentationProperty(String)
    case widgetsCommand(String)
    case missingVersion(String)
    case unknownTheme(String)
    case newerVersionRequired(String, String)
    case notInStore(String)
    case downloadFailed(String, Int)
    case checksumMismatch(String)
    case archiveMismatch(String, String)
    case misplacedSecret(String)

    var errorDescription: String? {
        switch self {
        case let .invalidComponent(value): "Invalid package id or version: \(value). Use letters, numbers, dots, dashes, and underscores."
        case let .outsidePackage(path): "Package path escapes its directory: \(path)."
        case let .missingFile(path): "Package file does not exist: \(path)."
        case let .alreadyInstalled(id, version): "Package \(id) \(version) is already installed. Choose a new version to replace it."
        case let .unknownSetting(name): "Unknown package setting: \(name)."
        case let .invalidSetting(name): "Invalid type, choice or default for package setting: \(name)."
        case .nestedPackages: "A widget package cannot activate other packages."
        case .manifestMismatch: "The package manifest does not match its pinned id and version."
        case let .notATheme(id): "Package \(id) is not a theme. Enable it in packages instead."
        case let .themeInPackages(id): "Package \(id) is a theme. Select it with the theme key instead of packages."
        case let .themeProperty(key): "A theme can contain only tokens, defaults, popupDefaults, roles, workspaceDefaults, bar, groups and profiles, not \(key)."
        case let .widgetsProperty(key): "A widgets package can contain only tokens, defaults, bar, groups, profiles, widgets, templates, popups and providers, not \(key)."
        case let .widgetPresentationProperty(key): "Widget packages cannot define global \(key). Set it in your configuration instead."
        case let .widgetsCommand(key): "A widgets package cannot contain \(key)."
        case let .missingVersion(id): "Package \(id) needs a version."
        case let .unknownTheme(id): "No theme named \(id) ships with StableBar. Add a version to select an installed theme package."
        case let .newerVersionRequired(id, version): "Package \(id) needs StableBar \(version) or later."
        case let .notInStore(id): "The store has no package \(id)."
        case let .downloadFailed(url, status): "Downloading \(url) failed with HTTP status \(status)."
        case let .checksumMismatch(id): "The archive of package \(id) does not match the store's checksum."
        case let .archiveMismatch(id, version): "The archive of package \(id) \(version) contains a different id or version."
        case let .misplacedSecret(reference): "\(reference) can be used only as a whole environment value of a widget or provider that its own package defines."
        }
    }
}

func validatePackageComponent(_ value: String) throws {
    guard !value.isEmpty, value != ".", value != "..",
          value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0) }) else {
        throw WidgetPackageError.invalidComponent(value)
    }
}

func validatePackagePath(_ url: URL, inside directory: URL) throws {
    let root = directory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
    guard url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(root) else {
        throw WidgetPackageError.outsidePackage(url.path)
    }
}

func packageFile(_ path: String, inside directory: URL) throws -> URL {
    guard !(path as NSString).isAbsolutePath, !path.hasPrefix("~") else {
        throw WidgetPackageError.outsidePackage(path)
    }
    let url = URL(fileURLWithPath: path, relativeTo: directory.appending(path: "", directoryHint: .isDirectory)).standardizedFileURL
    try validatePackagePath(url, inside: directory)
    guard FileManager.default.fileExists(atPath: url.path) else { throw WidgetPackageError.missingFile(path) }
    return url
}

struct WidgetPackageStore: Sendable {
    let directory: URL
    var appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    func directory(id: String, version: String) throws -> URL {
        try validatePackageComponent(id)
        try validatePackageComponent(version)
        let url = directory.appending(path: id).appending(path: version)
        try validatePackagePath(url, inside: directory)
        return url
    }

    func manifest(at source: URL) throws -> WidgetPackageManifest {
        let file = try packageFile("package.json", inside: source)
        return try JSONDecoder().decode(WidgetPackageManifest.self, from: Data(contentsOf: file))
    }

    func validateContents(at source: URL) throws {
        let files = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isSymbolicLinkKey])!
        for case let file as URL in files {
            try validatePackagePath(file, inside: source)
        }
    }

    func requiresNewerApp(_ minimumVersion: String) -> Bool {
        guard let appVersion else { return false }
        return appVersion.compare(minimumVersion, options: .numeric) == .orderedAscending
    }

    func inspect(_ source: URL, settings: [String: ConfigurationValue] = [:]) throws -> WidgetPackageInspection {
        let manifest = try manifest(at: source)
        if let minimumVersion = manifest.minimumVersion, requiresNewerApp(minimumVersion) {
            throw WidgetPackageError.newerVersionRequired(manifest.id, minimumVersion)
        }
        try validateContents(at: source)
        let screenshot = try manifest.screenshot.map { try packageFile($0, inside: source) }
        var loader = ConfigurationLoader()
        let layer = try loader.readPackage(at: source, manifest: manifest, settings: settings)
        let profiles = try layer.values["profiles"]?.decoded([ConfigurationProfile].self) ?? []
        var documents = [try loader.finish(layer, context: ConfigurationContext())]
        var commands = Set(packageCommands(.object(loader.templates.mapValues(ConfigurationValue.object))))
        for profile in profiles {
            var selected = layer
            selected.values["profile"] = .string(profile.name)
            try selected.merge(ConfigurationLayer(values: ["profiles": .array([.object(["name": .string(profile.name), "enabled": .bool(true)])])], origins: [:]))
            documents.append(try loader.finish(selected, context: ConfigurationContext()))
            commands.formUnion(packageCommands(.object(loader.templates.mapValues(ConfigurationValue.object))))
        }
        var widgets: [WidgetConfiguration] = []
        for document in documents {
            let configuration = try ConfigurationValue.object(document).decoded(Configuration.self)
            widgets.append(contentsOf: configuration.widgets.filter { widget in !widgets.contains { $0.id == widget.id } })
            commands.formUnion(packageCommands(.object(document)))
        }
        return WidgetPackageInspection(manifest: manifest, directory: source, commands: commands.sorted(), screenshot: screenshot, widgets: widgets)
    }

    func install(_ source: URL) throws -> WidgetPackageInspection {
        let inspection = try inspect(source)
        let destination = try directory(id: inspection.manifest.id, version: inspection.manifest.version)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw WidgetPackageError.alreadyInstalled(inspection.manifest.id, inspection.manifest.version)
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = destination.deletingLastPathComponent().appending(path: ".install-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: source, to: staging)
        _ = try inspect(staging)
        try FileManager.default.moveItem(at: staging, to: destination)
        return try inspect(destination)
    }

    func download(_ entry: PackageIndex.Entry, from index: URL) async throws -> URL {
        let data = try await fetch(index.deletingLastPathComponent().appending(path: entry.archive))
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == entry.sha256 else {
            throw WidgetPackageError.checksumMismatch(entry.id)
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let package = directory.appending(path: "package")
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: directory) } }
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let archive = directory.appending(path: "package.tar.gz")
        try data.write(to: archive)
        _ = try await runCommand("/usr/bin/tar", arguments: ["-xzf", archive.path, "-C", package.path])
        let manifest = try manifest(at: package)
        guard manifest.id == entry.id, manifest.version == entry.version else {
            throw WidgetPackageError.archiveMismatch(entry.id, entry.version)
        }
        completed = true
        return package
    }

    func list() throws -> [WidgetPackageManifest] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        var manifests: [WidgetPackageManifest] = []
        for package in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            for version in try FileManager.default.contentsOfDirectory(at: package, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
                try validatePackagePath(version, inside: directory)
                manifests.append(try manifest(at: version))
            }
        }
        return manifests.sorted { ($0.id, $0.version) < ($1.id, $1.version) }
    }
}

// Unlike manifests, the index ignores unknown keys and entries of unknown kinds, because older apps read the same index.
struct PackageIndex: Decodable, Sendable {
    struct Entry: Decodable, Sendable {
        let id: String
        let name: String
        let version: String
        let kind: WidgetPackageManifest.Kind?
        let description: String?
        let minimumVersion: String?
        let archive: String
        let sha256: String
        let source: URL
    }

    static let url = URL(string: "https://github.com/Seb-GRAF/stablebar-packages/releases/download/store/index.json")!

    let packages: [Entry]

    init(from decoder: Decoder) throws {
        var entries = try decoder.container(keyedBy: ConfigurationKey.self).nestedUnkeyedContainer(forKey: ConfigurationKey(stringValue: "packages"))
        var packages: [Entry] = []
        while !entries.isAtEnd {
            let entry = try entries.superDecoder()
            if let kind = try entry.container(keyedBy: ConfigurationKey.self).decodeIfPresent(String.self, forKey: ConfigurationKey(stringValue: "kind")),
               WidgetPackageManifest.Kind(rawValue: kind) == nil { continue }
            packages.append(try Entry(from: entry))
        }
        self.packages = packages
    }

    static func load(from url: URL) async throws -> PackageIndex {
        try JSONDecoder().decode(PackageIndex.self, from: await fetch(url))
    }
}

private func fetch(_ url: URL) async throws -> Data {
    let (data, response) = try await URLSession.shared.data(from: url)
    if let response = response as? HTTPURLResponse, response.statusCode != 200 {
        throw WidgetPackageError.downloadFailed(url.absoluteString, response.statusCode)
    }
    return data
}

func preparePackageDocument(_ document: [String: ConfigurationValue], directory: URL) throws -> [String: ConfigurationValue] {
    var result = document
    if let widgets = result["widgets"] {
        result["widgets"] = .array(try widgets.decoded([[String: ConfigurationValue]].self).map {
            .object(packageEnvironment($0, directory: directory))
        })
    }
    for key in ["templates", "providers"] {
        if let definitions = result[key] {
            result[key] = .object(try definitions.decoded([String: [String: ConfigurationValue]].self).mapValues {
                .object(packageEnvironment($0, directory: directory))
            })
        }
    }
    if let profiles = result["profiles"] {
        result["profiles"] = .array(try profiles.decoded([[String: ConfigurationValue]].self).map { profile in
            var profile = profile
            let configuration = try (profile["configuration"] ?? .object([:])).decoded([String: ConfigurationValue].self)
            profile["configuration"] = .object(try preparePackageDocument(configuration, directory: directory))
            return .object(profile)
        })
    }
    return result
}

func validateThemeDocument(_ document: [String: ConfigurationValue]) throws {
    for key in document.keys.sorted() where !["tokens", "defaults", "popupDefaults", "roles", "workspaceDefaults", "bar", "groups", "profiles"].contains(key) {
        guard key == "widgets", document[key] == .array([]) else { throw WidgetPackageError.themeProperty(key) }
    }
    for profile in try document["profiles"]?.decoded([ConfigurationProfile].self) ?? [] {
        try validateThemeDocument(profile.configuration)
    }
}

func validateWidgetsDocument(_ document: [String: ConfigurationValue]) throws {
    for key in document.keys.sorted() where !["tokens", "defaults", "bar", "groups", "profiles", "widgets", "templates", "popups", "providers"].contains(key) {
        throw WidgetPackageError.widgetsProperty(key)
    }
    for profile in try document["profiles"]?.decoded([ConfigurationProfile].self) ?? [] {
        try validateWidgetsDocument(profile.configuration)
    }
    try rejectCommandKeys(.object(document))
}

/// Command-capable legacy packages keep their existing powers, but the new shared presentation
/// maps are owned by users/themes, never by a widget package (including its profiles).
func validateCommandPackagePresentation(_ document: [String: ConfigurationValue]) throws {
    for key in ["roles", "workspaceDefaults", "modeAliases"] where document[key] != nil {
        throw WidgetPackageError.widgetPresentationProperty(key)
    }
    for profile in try document["profiles"]?.decoded([ConfigurationProfile].self) ?? [] {
        try validateCommandPackagePresentation(profile.configuration)
    }
}

private func rejectCommandKeys(_ value: ConfigurationValue) throws {
    switch value {
    case let .object(object):
        for key in object.keys.sorted() {
            guard !(commandKeys + ["onClickField", "environment"]).contains(key) else { throw WidgetPackageError.widgetsCommand(key) }
            try rejectCommandKeys(object[key]!)
        }
    case let .array(array): try array.forEach(rejectCommandKeys)
    default: break
    }
}

func validateSecretReferences(_ value: ConfigurationValue, package id: String, path: [String] = []) throws {
    switch value {
    case let .string(string) where string.hasPrefix("@secret."):
        guard string.hasPrefix("@secret.\(id)/"), path.count == 4, ["widgets", "providers"].contains(path[0]), path[2] == "environment" else {
            throw WidgetPackageError.misplacedSecret(string)
        }
    case let .object(object):
        for (key, child) in object { try validateSecretReferences(child, package: id, path: path + [key]) }
    case let .array(array):
        for (index, child) in array.enumerated() { try validateSecretReferences(child, package: id, path: path + [String(index)]) }
    default: break
    }
}

private func packageEnvironment(_ definition: [String: ConfigurationValue], directory: URL) -> [String: ConfigurationValue] {
    var result = definition
    result["environment"] = .object(["PACKAGE_DIR": .string(directory.path)]).overriding(result["environment"] ?? .object([:]))
    return result
}

func preparePackageAssets(_ value: ConfigurationValue, path: String = "", origins: [String: ConfigurationOrigin],
                          sources: [String: URL]) throws -> ConfigurationValue {
    switch value {
    case let .object(object):
        var result: [String: ConfigurationValue] = [:]
        for (key, child) in object {
            result[key] = try preparePackageAssets(child, path: path.isEmpty ? key : "\(path).\(key)",
                                                  origins: origins, sources: sources)
        }
        if object["type"] == .string("image"), case let .string(file) = object["path"],
           let source = origins["\(path).path"]?.file, let directory = sources[source] {
            result["path"] = .string(try packageFile(file, inside: directory).path)
        }
        return .object(result)
    case let .array(array):
        return .array(try array.enumerated().map { index, child in
            var key = String(index)
            if path == "widgets", case let .object(widget) = child, case let .string(id) = widget["id"] { key = id }
            return try preparePackageAssets(child, path: "\(path).\(key)", origins: origins, sources: sources)
        })
    default: return value
    }
}

private let commandKeys = ["command", "onClick", "rightClick", "middleClick", "scrollUp", "scrollDown", "mouseEntered", "mouseExited", "onChange"]

private func packageCommands(_ value: ConfigurationValue) -> [String] {
    switch value {
    case let .object(object):
        return object.keys.sorted().flatMap { key in
            let value = object[key]!
            if commandKeys.contains(key),
               case let .string(command) = value { return [command] }
            if key == "onClickField", case let .string(field) = value { return ["Command from field \"\(field)\""] }
            return packageCommands(value)
        }
    case let .array(array): return array.flatMap(packageCommands)
    default: return []
    }
}
