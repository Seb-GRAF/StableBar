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
    let nativeBundle: String?
    let settings: [String: WidgetPackageSetting]
    /// The names of `settings` in the order package.json lists them, which `WidgetPackageStore.manifest(at:)` reads.
    var settingNames: [String] = []
    let description: String?
    let author: String?
    let repository: URL?
    let screenshot: String?
    let minimumVersion: String?
    let requires: [String]
    let permissions: [Permission]
    let hosts: [String]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name, version, kind, entry, nativeBundle, settings, description, author, repository, screenshot, minimumVersion, requires, permissions, hosts
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        version = try values.decode(String.self, forKey: .version)
        kind = try values.decodeIfPresent(Kind.self, forKey: .kind)
        entry = try values.decode(String.self, forKey: .entry)
        nativeBundle = try values.decodeIfPresent(String.self, forKey: .nativeBundle)
        if nativeBundle != nil, kind != .widgets {
            throw DecodingError.dataCorruptedError(forKey: .nativeBundle, in: values, debugDescription: "Native bundles need a widgets package.")
        }
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

struct NativePluginBundle: Equatable, Sendable {
    let packageID: String
    let version: String
    let path: String
    let url: URL
    let bundleID: String
    let apiMajor: Int
    let signature: NativePluginSignature

    var review: NativePluginReview {
        NativePluginReview(packageID: packageID, version: version, path: path, bundleID: bundleID, apiMajor: apiMajor, signature: signature)
    }
}

struct NativePluginReview: Equatable, Sendable {
    let packageID: String
    let version: String
    let path: String
    let bundleID: String
    let apiMajor: Int
    let signature: NativePluginSignature

    var description: String {
        "Package \(packageID) \(version) runs arbitrary native code inside StableBar with the app’s permissions under your macOS user account. Bundle \(path), signed as \(bundleID), Team ID \(signature.teamIdentifier), cdhash \(signature.cdhash), API \(apiMajor)."
    }
}

struct WidgetPackageInspection: Sendable {
    let manifest: WidgetPackageManifest
    let directory: URL
    let commands: [String]
    let screenshot: URL?
    let widgets: [WidgetConfiguration]
    let nativePluginBundle: NativePluginBundle?

    var requiresReview: Bool {
        !commands.isEmpty || !manifest.permissions.isEmpty || !manifest.hosts.isEmpty || !manifest.requires.isEmpty
            || manifest.settings.values.contains { $0.type == "secret" } || nativePluginBundle != nil
    }

    var storeReviewStatus: String {
        if nativePluginBundle != nil { return "The Store package includes native code" }
        return commands.isEmpty ? "The Store checked that it runs no commands" : "A maintainer read this version"
    }

    var storeReviewHint: String? {
        nativePluginBundle == nil ? nil : "Store review does not restrict what this code can do inside StableBar."
    }

    func additions(since previous: WidgetPackageInspection) -> [String] {
        var additions = commands.filter { !previous.commands.contains($0) }.map { "Command: \($0)" }
            + manifest.hosts.filter { !previous.manifest.hosts.contains($0) }.map { "Host: \($0)" }
            + manifest.permissions.filter { !previous.manifest.permissions.contains($0) }.map { "Permission: \($0.rawValue.capitalized)" }
        if let review = nativePluginBundle?.review,
           manifest.version != previous.manifest.version || review != previous.nativePluginBundle?.review {
            additions.append(review.description)
        }
        return additions
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
    case nativePluginNotActive(String)
    case nativePluginReviewRequired(String)
    case nativePluginChanged(String)

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
        case let .nativePluginNotActive(id): "Native widget package \(id) is not active on this bar."
        case let .nativePluginReviewRequired(id): "Review the native code in package \(id) before adding it to the bar."
        case let .nativePluginChanged(id): "The native code in package \(id) changed after review. Review it again before adding it to the bar."
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
    let root = resolvingSymlinks(directory).path + "/"
    guard resolvingSymlinks(url).path.hasPrefix(root) else {
        throw WidgetPackageError.outsidePackage(url.path)
    }
}

/// `resolvingSymlinksInPath()` for a path that may not exist yet, which Foundation leaves unresolved:
/// resolves the nearest existing ancestor and appends the missing components.
private func resolvingSymlinks(_ url: URL) -> URL {
    var existing = url.standardizedFileURL
    var missing: [String] = []
    while existing.path != "/", (try? FileManager.default.attributesOfItem(atPath: existing.path)) == nil {
        missing.insert(existing.lastPathComponent, at: 0)
        existing.deleteLastPathComponent()
    }
    return missing.reduce(existing.resolvingSymlinksInPath()) { $0.appending(path: $1) }
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
    var nativePluginTrustURL: URL { directory.deletingLastPathComponent().appending(path: "native-plugin-trust.json") }
    var appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    func directory(id: String, version: String) throws -> URL {
        try validatePackageComponent(id)
        try validatePackageComponent(version)
        let url = directory.appending(path: id).appending(path: version)
        try validatePackagePath(url, inside: directory)
        return url
    }

    func manifest(at source: URL) throws -> WidgetPackageManifest {
        let data = try Data(contentsOf: packageFile("package.json", inside: source))
        // A manifest is what installing reviewed, such as permissions, so it stays strict even in a configuration
        // written for a newer release: skipping a property could drop a restriction.
        var manifest = try NewerConfiguration.$current.withValue(nil) {
            try JSONDecoder().decode(WidgetPackageManifest.self, from: data)
        }
        // The scan reads UTF-8, so it misses the names in a manifest in UTF-16 or UTF-32, which JSONDecoder reads too, and
        // it finds the names of a repeated key whose later values JSONDecoder drops. The decoded settings decide what shows.
        for name in settingNames(in: data) + manifest.settings.keys.sorted()
        where manifest.settings[name] != nil && !manifest.settingNames.contains(name) {
            manifest.settingNames.append(name)
        }
        return manifest
    }

    /// The keys of the top-level `settings` objects of `data`, a manifest that decoded, in the file's order, which
    /// decoding into a dictionary loses. A string followed by a colon is a key.
    private func settingNames(in data: Data) -> [String] {
        let bytes = [UInt8](data)
        var names: [String] = [], key = "", depth = 0, inSettings = false, index = 0
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            switch byte {
            case UInt8(ascii: "\""):
                let start = index - 1
                while index < bytes.count && bytes[index] != UInt8(ascii: "\"") { index += bytes[index] == UInt8(ascii: "\\") ? 2 : 1 }
                index += 1
                var next = index
                while next < bytes.count && [0x20, 0x09, 0x0A, 0x0D].contains(bytes[next]) { next += 1 }
                guard next < bytes.count, bytes[next] == UInt8(ascii: ":"),
                      let name = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) else { continue }
                if depth == 1 { key = name } else if depth == 2 && inSettings { names.append(name) }
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                depth += 1
                if depth == 2 { inSettings = key == "settings" }
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth -= 1
            default:
                break
            }
        }
        return names
    }

    func validateContents(at source: URL) throws {
        let files = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isSymbolicLinkKey])!
        for case let file as URL in files {
            try validatePackagePath(file, inside: source)
        }
    }

    /// Whether two package folders hold the same files: the same relative paths, directories, bytes and symbolic links.
    /// Finder's litter, a regular file named `.DS_Store` or starting with `._` (AppleDouble), is ignored only when one
    /// side lacks it, as when Finder browsed one copy. A package can ship and run such a file, so when both sides have it
    /// its bytes are compared like any file's; a directory or link with such a name is always compared.
    /// Throws, as inspecting would, when a file or link in either folder leads out of it.
    func sameContents(_ a: URL, _ b: URL) throws -> Bool {
        try validateContents(at: a)
        try validateContents(at: b)
        let first = try packageItems(in: a), second = try packageItems(in: b)
        for path in Set(first.keys).union(second.keys) {
            switch (first[path], second[path]) {
            case let (one?, other?): guard one == other else { return false }
            case let (one?, nil), let (nil, one?): guard one.isFinderLitter(at: path) else { return false }
            case (nil, nil): break
            }
        }
        return true
    }

    private enum PackageItem: Equatable {
        /// `other`: a socket, pipe or device, which no package needs; two of them at the same path compare equal.
        case directory, file(Data), link(String), other

        func isFinderLitter(at path: String) -> Bool {
            let name = (path as NSString).lastPathComponent
            guard case .file = self else { return false }
            return name == ".DS_Store" || name.hasPrefix("._")
        }
    }

    /// Every entry under `folder`, by relative path. It reads the directories itself because FileManager's listings
    /// hide regular files starting with `._` on macOS, and a package can ship and run one.
    private func packageItems(in folder: URL) throws -> [String: PackageItem] {
        var items: [String: PackageItem] = [:]
        func visit(_ relative: String) throws {
            let directory = relative.isEmpty ? folder : folder.appending(path: relative)
            guard let handle = opendir(directory.path) else { throw WidgetPackageError.missingFile(directory.path) }
            defer { closedir(handle) }
            var names: [String] = []
            while let entry = readdir(handle) {
                let name = withUnsafePointer(to: entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
                }
                if name != "." && name != ".." { names.append(name) }
            }
            for name in names {
                let path = relative.isEmpty ? name : "\(relative)/\(name)"
                let file = folder.appending(path: path)
                var info = stat()
                guard lstat(file.path, &info) == 0 else { throw WidgetPackageError.missingFile(file.path) }
                switch info.st_mode & S_IFMT {
                case S_IFLNK: items[path] = .link(try FileManager.default.destinationOfSymbolicLink(atPath: file.path))
                case S_IFDIR:
                    items[path] = .directory
                    try visit(path)
                case S_IFREG: items[path] = .file(try Data(contentsOf: file))
                default: items[path] = .other
                }
            }
        }
        try visit("")
        return items
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
        let nativePluginBundle = try manifest.nativeBundle.map { path -> NativePluginBundle in
            let url = try packageFile(path, inside: source)
            let metadata = try NativeWidgetPluginMetadata.read(at: url)
            guard metadata.bundleID == manifest.id else { throw NativeWidgetPluginLoaderError.pluginIDMismatch }
            guard metadata.version == manifest.version else { throw NativeWidgetPluginLoaderError.versionMismatch }
            guard metadata.apiMajor == NativeWidgetPluginLoader.supportedAPIMajor else {
                throw NativeWidgetPluginLoaderError.unsupportedAPI(metadata.apiMajor)
            }
            let signature = try NativePluginSignature.verify(at: url)
            guard signature.identifier == metadata.bundleID else { throw NativeWidgetPluginLoaderError.signatureIdentifierMismatch }
            return NativePluginBundle(packageID: manifest.id, version: manifest.version, path: path, url: url,
                                      bundleID: metadata.bundleID, apiMajor: metadata.apiMajor, signature: signature)
        }
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
        return WidgetPackageInspection(manifest: manifest, directory: source, commands: commands.sorted(), screenshot: screenshot,
                                       widgets: widgets, nativePluginBundle: nativePluginBundle)
    }

    /// `record` is the source the package comes from, `.local` for a folder; `requestedName` names it in a refusal.
    func install(_ source: URL, record: PackageInstallRecord = .local,
                 requestedName: String = "a local folder") throws -> WidgetPackageInspection {
        let inspection = try inspect(source)
        let id = inspection.manifest.id
        let destination = try directory(id: id, version: inspection.manifest.version)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw WidgetPackageError.alreadyInstalled(id, inspection.manifest.version)
        }
        // Refused before any file is copied.
        let claimed = try claimedRecord(id: id, version: inspection.manifest.version, packageName: inspection.manifest.name,
                                        for: record, requestedName: requestedName)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = destination.deletingLastPathComponent().appending(path: ".install-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: source, to: staging)
        _ = try inspect(staging)
        try FileManager.default.moveItem(at: staging, to: destination)
        do { try write(claimed, id: id) } catch {
            // A version without its record would leave the ID open to any source.
            try? FileManager.default.removeItem(at: destination)
            try? releaseIfEmpty(id: id)
            throw error
        }
        return try inspect(destination)
    }

    private func recordURL(id: String) throws -> URL {
        try validatePackageComponent(id)
        let url = directory.appending(path: id).appending(path: PackageInstallRecord.fileName)
        try validatePackagePath(url, inside: directory)
        return url
    }

    /// The source that installed `id`, or nil when no version is installed or it predates install records.
    func record(id: String) throws -> PackageInstallRecord? {
        let url = try recordURL(id: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(PackageInstallRecord.self, from: Data(contentsOf: url))
    }

    /// Package ID → its install record, for every installed ID that has one.
    func records() throws -> [String: PackageInstallRecord] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [:] }
        var records: [String: PackageInstallRecord] = [:]
        for package in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            let id = package.lastPathComponent
            records[id] = try record(id: id)
        }
        return records
    }

    /// Records that `record`'s source installed `version` of `id`, or throws `.claimed` when another source did.
    func claim(id: String, version: String, packageName: String, for record: PackageInstallRecord, requestedName: String) throws {
        try write(claimedRecord(id: id, version: version, packageName: packageName, for: record, requestedName: requestedName), id: id)
    }

    /// The record to keep after installing `version` of `id` from `record`'s source:
    /// - unclaimed (no record, or `local`): the requested record. A source claiming the ID takes only `version`, whose
    ///   files it installs or that were checked against its own: every other installed version came from a folder or
    ///   from before records existed, so it's listed among the local versions;
    /// - the same source: the requested record, which refreshes its name and URL, without `version` among the local versions;
    /// - another source: when a local folder is installed, so authors can test a version, the existing record with
    ///   `version` among its local versions; otherwise the install is refused.
    private func claimedRecord(id: String, version: String, packageName: String, for requested: PackageInstallRecord,
                               requestedName: String) throws -> PackageInstallRecord {
        guard let existing = try record(id: id), !existing.isLocal else {
            guard !requested.isLocal else { return requested }
            return try installedVersions(id: id).filter { $0 != version }.reduce(requested) { $0.settingLocal($1, true) }
        }
        if existing.source == requested.source {
            var refreshed = requested
            refreshed.localVersions = existing.localVersions
            return refreshed.settingLocal(version, false)
        }
        if requested.isLocal { return existing.settingLocal(version, true) }
        throw PackageSourceError.claimed(package: packageName, installedFrom: existing.name ?? existing.source, requested: requestedName)
    }

    private func write(_ record: PackageInstallRecord, id: String) throws {
        let url = try recordURL(id: id)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(record).write(to: url, options: .atomic)
    }

    /// The version folders installed for `id`.
    private func installedVersions(id: String) throws -> [String] {
        let folder = directory.appending(path: id)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        try validatePackagePath(folder, inside: directory)
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            .map(\.lastPathComponent)
    }

    /// After `version` of `id` is uninstalled: forgets that it came from a folder, and releases the ID once no version is left.
    func releaseVersion(id: String, version: String) throws {
        if let record = try record(id: id), record.localVersions?.contains(version) == true {
            try write(record.settingLocal(version, false), id: id)
        }
        try releaseIfEmpty(id: id)
    }

    /// Removes `packages/<id>`, and its install record, once no version of it is left.
    func releaseIfEmpty(id: String) throws {
        try validatePackageComponent(id)
        let folder = directory.appending(path: id)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try validatePackagePath(folder, inside: directory)
        let versions = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        if versions.isEmpty { try FileManager.default.removeItem(at: folder) }
    }

    /// `appending(path:)` keeps the archive on the index's host, even for an `archive` with `../` or a scheme in it.
    func download(_ entry: PackageIndex.Entry, from source: PackageSource, token: String?,
                  session: URLSession = .packageSources) async throws -> URL {
        let url = source.url.deletingLastPathComponent().appending(path: entry.archive)
        let data = try await fetch(sourceRequest(for: url, source: source, token: token), session: session)
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

/// `--packages`: every installed manifest, with `source` naming the source that installed it when it has a record,
/// and `local` for a version installed from a folder.
func packageListing(_ packages: WidgetPackageStore) throws -> Data {
    struct Listed: Encodable {
        enum CodingKeys: String, CodingKey { case source }
        let manifest: WidgetPackageManifest
        let source: String?

        func encode(to encoder: Encoder) throws {
            try manifest.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(source, forKey: .source)
        }
    }
    let records = try packages.records()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(packages.list().map { manifest in
        let record = records[manifest.id]
        return Listed(manifest: manifest, source: record.map { $0.isLocal(version: manifest.version) ? PackageSource.localID : $0.source })
    })
}

// Unlike manifests, the index ignores unknown keys and entries of unknown kinds, because older apps read the same index.
struct PackageIndex: Decodable, Sendable {
    struct Entry: Decodable, Sendable {
        let id: String
        let name: String
        let version: String
        let kind: WidgetPackageManifest.Kind?
        let description: String?
        let author: String?
        let minimumVersion: String?
        /// Resolved against the index URL when the index lists a relative path.
        var screenshot: URL?
        let archive: String
        let sha256: String
        /// The package's code repository. The JSON key stays `source`; private indexes may leave it out.
        let repository: URL?
        /// The package source that listed this entry. Not part of the index.
        var sourceID = PackageSource.storeID

        enum CodingKeys: String, CodingKey {
            case id, name, version, kind, description, author, minimumVersion, screenshot, archive, sha256
            case repository = "source"
        }

        /// Identifies an entry across sources, for caches and SwiftUI.
        var key: String { "\(sourceID):\(id)/\(version)" }
    }

    static let url = URL(string: "https://github.com/Seb-GRAF/stablebar-packages/releases/download/store/index.json")!

    let packages: [Entry]

    init(packages: [Entry]) {
        self.packages = packages
    }

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

    /// Tags every entry with the source, resolves relative screenshots and keeps the first entry for each ID.
    static func load(from source: PackageSource, token: String?, session: URLSession) async throws -> PackageIndex {
        let data = try await fetch(sourceRequest(for: source.url, source: source, token: token), session: session)
        var seen: Set<String> = []
        var packages: [Entry] = []
        for var entry in try JSONDecoder().decode(PackageIndex.self, from: data).packages where seen.insert(entry.id).inserted {
            entry.sourceID = source.id
            if let screenshot = entry.screenshot, screenshot.scheme == nil {
                entry.screenshot = URL(string: screenshot.relativeString, relativeTo: source.url)?.absoluteURL
            }
            packages.append(entry)
        }
        return PackageIndex(packages: packages)
    }

    static func load(from url: URL) async throws -> PackageIndex {
        try await load(from: PackageSource(id: PackageSource.storeID, name: PackageSource.store.name, url: url), token: nil,
                       session: .packageSources)
    }
}

func fetch(_ url: URL) async throws -> Data {
    try await fetch(URLRequest(url: url), session: .shared)
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
                          boundaries: [String: URL]) throws -> ConfigurationValue {
    switch value {
    case let .object(object):
        var result: [String: ConfigurationValue] = [:]
        for (key, child) in object {
            result[key] = try preparePackageAssets(child, path: path.isEmpty ? key : "\(path).\(key)",
                                                  origins: origins, boundaries: boundaries)
        }
        if object["type"] == .string("image"), case let .string(file) = object["path"],
           let source = origins["\(path).path"]?.file, let directory = boundaries[source] {
            result["path"] = .string(try packageFile(file, inside: directory).path)
        }
        return .object(result)
    case let .array(array):
        return .array(try array.enumerated().map { index, child in
            var key = String(index)
            if path == "widgets", case let .object(widget) = child, case let .string(id) = widget["id"] { key = id }
            return try preparePackageAssets(child, path: "\(path).\(key)", origins: origins, boundaries: boundaries)
        })
    default: return value
    }
}

private let commandKeys = ["command", "onClick", "rightClick", "middleClick", "scrollUp", "scrollDown", "mouseEntered", "mouseExited", "onChange", "onSubmit", "onStop", "onStar", "onOpen", "onClose"]

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
