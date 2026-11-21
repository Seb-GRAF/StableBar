import Foundation
import os

/// A catalog of packages: the public StableBar Store, or a private index the user added.
struct PackageSource: Codable, Equatable, Hashable, Sendable, Identifiable {
    static let storeID = "stablebar", localID = "local"
    static let store = PackageSource(id: storeID, name: "StableBar Store", url: PackageIndex.url)

    let id: String
    var name: String
    var url: URL

    enum CodingKeys: String, CodingKey, CaseIterable { case id, name, url }

    /// Doesn't validate, so tests can use file URLs. Decoding and `validated(id:name:url:)` do.
    init(id: String, name: String, url: URL) {
        self.id = id
        self.name = name
        self.url = url
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let source = try Self.validated(id: values.decode(String.self, forKey: .id),
                                        name: values.decode(String.self, forKey: .name),
                                        url: values.decode(URL.self, forKey: .url))
        self.init(id: source.id, name: source.name, url: source.url)
    }

    static func validated(id: String, name: String, url: URL) throws -> PackageSource {
        try validatePackageComponent(id)
        guard id != storeID, id != localID else { throw PackageSourceError.reservedID(id) }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PackageSourceError.emptyName(id) }
        // Only the public Store carries its name, so a private source can't pass its packages off as the Store's.
        guard trimmed.caseInsensitiveCompare(store.name) != .orderedSame else { throw PackageSourceError.reservedName(id) }
        guard url.scheme == "https", url.host() != nil else { throw PackageSourceError.insecureURL(id) }
        guard url.query == nil, url.fragment == nil else { throw PackageSourceError.queryInURL(id) }
        guard url.user() == nil, url.password() == nil else { throw PackageSourceError.credentialsInURL(id) }
        return PackageSource(id: id, name: name, url: url)
    }

    var isStore: Bool { id == Self.storeID }
    var tokenAccount: String { Self.tokenAccount(id) }
    static func tokenAccount(_ id: String) -> String { "source:\(id)" }
    var host: String { url.host() ?? url.absoluteString }

    /// The StableBar Store followed by the sources of a composed configuration document.
    static func configured(in document: [String: ConfigurationValue]) throws -> [PackageSource] {
        let added = try document["packageSources"]?.decoded([PackageSource].self, at: "packageSources") ?? []
        return [store] + added
    }

    static func configured(at configuration: URL) throws -> [PackageSource] {
        var loader = ConfigurationLoader()
        return try configured(in: loader.compose(configuration))
    }
}

extension PackageSource {
    /// An id from a source's name: its slug, then "-2", "-3"… while it is reserved or taken.
    static func newID(for name: String, taken: Set<String>) -> String {
        let slug = packageSlug(name).isEmpty ? "source" : packageSlug(name)
        let unavailable = taken.union([storeID, localID])
        guard unavailable.contains(slug) else { return slug }
        return (2...).lazy.map { "\(slug)-\($0)" }.first { !unavailable.contains($0) }!
    }
}

/// A package or source id from a name: diacritics folded, lowercased, and runs of other characters joined with "-".
/// A name with no ASCII letters or digits gives "".
func packageSlug(_ name: String) -> String {
    name.folding(options: .diacriticInsensitive, locale: nil).lowercased()
        .split { !$0.isASCII || !($0.isLetter || $0.isNumber) }.joined(separator: "-")
}

enum PackageSourceError: LocalizedError, Equatable {
    case reservedID(String), duplicateID(String), insecureURL(String), queryInURL(String), emptyName(String)
    case credentialsInURL(String), idTaken(String), reservedName(String)
    case inPackage, inProfile(String), notConfigured(String)
    case claimed(package: String, installedFrom: String, requested: String)
    case differentFiles(package: String, version: String, requested: String)
    case ambiguous(id: String, sources: [PackageSource])
    case unknownSource(String, configured: [String])
    case unavailable(source: String, detail: String, id: String, listedIn: PackageSource)

    var errorDescription: String? {
        switch self {
        case let .reservedID(id): "\(id) is reserved for StableBar. Choose another source id."
        case let .duplicateID(id): "packageSources lists \(id) more than once."
        case let .insecureURL(id): "Use an https URL for package source \(id)."
        case let .queryInURL(id): "Package source \(id) needs an index URL without ?query or #fragment. Archives are read from the same folder."
        case let .credentialsInURL(id): "Package source \(id) needs an index URL without a user name or password. Enter a token in Settings instead."
        case let .idTaken(id): "A package source named \(id) already exists."
        case let .emptyName(id): "Package source \(id) needs a name."
        case let .reservedName(id): "Package source \(id) can’t be named \(PackageSource.store.name). Choose another name."
        case .inPackage: "A package cannot add package sources."
        case let .inProfile(name): "Profile \(name) cannot change packageSources. Sources apply to every profile."
        case let .notConfigured(id): "Package source \(id) is no longer in your configuration."
        case let .claimed(package, installedFrom, requested):
            "\(package) is installed from \(installedFrom). Uninstall it before getting it from \(requested)."
        case let .differentFiles(package, version, requested):
            "\(package) \(version) is already installed from a folder with different files. Uninstall it before getting it from \(requested)."
        case let .ambiguous(id, sources):
            "\(id) is listed in \(sources.map(\.name).joined(separator: " and ")). Add --source \(sources.map(\.id).joined(separator: " or --source "))."
        case let .unknownSource(id, configured):
            "No package source named \(id). Configured: \(configured.joined(separator: ", "))."
        case let .unavailable(source, detail, id, listedIn):
            "\(source) is unavailable: \(detail) It may also list \(id). Add --source \(listedIn.id) to install from \(listedIn.name)."
        }
    }
}

/// Which source an installed package ID belongs to, kept in `packages/<id>/.source.json`.
/// Only that source can install other versions of the ID, so another source can't substitute the package.
/// Versions an author installed from a folder under a source's ID are listed apart: they're the folder's files, not the source's.
struct PackageInstallRecord: Codable, Equatable, Sendable {
    /// Why a package was installed from no source: Save as Theme, a theme link, the look of a bar link, or a retired theme
    /// that an update kept.
    enum Origin: String, Codable, Sendable { case saved, themeLink, barLink, retired }

    static let fileName = ".source.json"
    /// Opened from a folder: the ID is unclaimed, and the first source to install it claims it.
    static let local = PackageInstallRecord(source: PackageSource.localID, name: nil, url: nil)

    let source: String
    /// The source's name and URL when it was installed, shown once the source is gone from the configuration.
    var name: String?
    var url: URL?
    /// Versions installed from a folder while the ID belongs to `source`. They update from `source`, but are labelled
    /// as a local folder, and become the source's only when their files are the source's. Nil rather than empty, so
    /// records without any read and write as before.
    var localVersions: [String]?
    /// Why a local package came from no source. Nil for a folder, so records without it read and write as before.
    var origin: Origin?

    init(source: String, name: String?, url: URL?) {
        self.source = source
        self.name = name
        self.url = url
    }

    init(_ source: PackageSource) {
        self.init(source: source.id, name: source.name, url: source.url)
    }

    var isLocal: Bool { source == PackageSource.localID }

    /// Whether `version` was installed from a folder: the whole ID was, or this version was under a source's ID.
    func isLocal(version: String) -> Bool {
        isLocal || localVersions?.contains(version) == true
    }

    /// The record with `version` added to, or removed from, its local versions.
    func settingLocal(_ version: String, _ local: Bool) -> PackageInstallRecord {
        var record = self
        var versions = (localVersions ?? []).filter { $0 != version }
        if local { versions.append(version) }
        record.localVersions = versions.isEmpty ? nil : versions.sorted { $0.compare($1, options: .numeric) == .orderedAscending }
        return record
    }
}

/// Where source tokens live: the Keychain in the app, a dictionary in tests.
struct PackageSourceTokens: Sendable {
    let read: @Sendable (String) -> String?
    let save: @Sendable (_ value: String, _ account: String) throws -> Void

    static let keychain = PackageSourceTokens(
        read: { account in Optional(packageSecret(account)).flatMap { $0.isEmpty ? nil : $0 } },
        save: { value, account in try savePackageSecret(value, account: account) })

    static func memory(_ initial: [String: String] = [:]) -> PackageSourceTokens {
        let store = OSAllocatedUnfairLock(initialState: initial)
        return PackageSourceTokens(
            read: { account in store.withLock { $0[account] } },
            save: { value, account in store.withLock { $0[account] = value.isEmpty ? nil : value } })
    }
}

/// A source token and the origin it was saved for, kept in the Keychain as JSON.
/// It is sent only to that origin, so a source moved to another host by any configuration change doesn't send it there.
struct SavedSourceToken: Codable, Equatable, Sendable {
    let origin: String
    let token: String

    init(token: String, for url: URL) {
        var components = URLComponents()
        components.scheme = url.scheme?.lowercased()
        components.host = url.host()?.lowercased()
        components.port = url.port
        origin = components.string ?? ""
        self.token = token
    }

    /// A plain value, as builds before origins saved, or anything else that isn't this JSON gives nil: it's never sent.
    init?(stored: String) {
        guard let saved = try? JSONDecoder().decode(Self.self, from: Data(stored.utf8)), !saved.token.isEmpty else { return nil }
        self = saved
    }

    var stored: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(self)) ?? Data(), as: UTF8.self)
    }

    /// The token, when `url` is on the origin it was saved for.
    func token(for url: URL) -> String? {
        guard let saved = URL(string: origin), saved.host() != nil, sameOrigin(saved, url) else { return nil }
        return token
    }
}

/// The entries of every source that loaded, in source order, and the error of each source that didn't.
struct PackageCatalog: Sendable {
    var entries: [PackageIndex.Entry] = []
    var suggestions: [PackageIndex.Suggestion] = []
    /// Source ID → `sourceErrorDetail` of its failure.
    var errors: [String: String] = [:]

    var widgets: [PackageIndex.Entry] { entries.filter { $0.kind != .theme } }
}

/// What went wrong with a source, worded to follow its name: "Acme is unavailable: <detail>".
func sourceErrorDetail(_ error: Error) -> String {
    switch error {
    case let WidgetPackageError.downloadFailed(_, status) where status == 401 || status == 403:
        "the token was refused (HTTP \(status))."
    case WidgetPackageError.downloadFailed(_, 404):
        "the index wasn’t found (HTTP 404). GitHub also answers 404 when the token is missing or can’t read the repository."
    case is DecodingError:
        "the index isn’t a StableBar package index."
    default:
        errorMessage(error)
    }
}
