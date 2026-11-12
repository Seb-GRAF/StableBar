import Foundation

enum PackageStoreClientError: LocalizedError {
    case reviewRequired
    case kindMismatch

    var errorDescription: String? {
        switch self {
        case .reviewRequired: "Review this package’s commands, permissions, hosts, tools and secret settings in Packages before enabling it."
        case .kindMismatch: "The package’s kind does not match its Store listing."
        }
    }
}

/// Session cache shared by Customize's galleries: the index of every package source, and verified downloads.
/// File work and validation stay off the main actor.
actor PackageStoreClient {
    let packages: WidgetPackageStore
    let store: PackageSource
    private var privateSources: [PackageSource]
    private let tokens: PackageSourceTokens
    private let session: URLSession
    private var indexTasks: [String: Task<PackageIndex, Error>] = [:]
    private var downloads: [String: Task<WidgetPackageInspection, Error>] = [:]
    private var directories: [URL] = []

    init(packages: WidgetPackageStore, store: PackageSource = .store, sources: [PackageSource] = [],
         tokens: PackageSourceTokens = .keychain, session: URLSession = .packageSources) {
        self.packages = packages
        self.store = store
        self.privateSources = Self.privateSources(sources)
        self.tokens = tokens
        self.session = session
    }

    /// A client whose Store is read from `indexURL`, with tokens kept in memory.
    init(packages: WidgetPackageStore, indexURL: URL, tokens: PackageSourceTokens = .memory(),
         session: URLSession = .packageSources) {
        self.init(packages: packages, store: PackageSource(id: PackageSource.storeID, name: PackageSource.store.name, url: indexURL),
                  tokens: tokens, session: session)
    }

    deinit {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
    }

    /// The Store, then the private sources in configuration order.
    var sources: [PackageSource] { [store] + privateSources }

    func source(id: String) -> PackageSource? {
        sources.first { $0.id == id }
    }

    /// Drops the cached index and downloads of every source that was removed or now points to another URL.
    func setPrivateSources(_ sources: [PackageSource]) {
        let next = Self.privateSources(sources)
        for old in privateSources where !next.contains(where: { $0.id == old.id && $0.url == old.url }) {
            forget(old.id)
        }
        privateSources = next
    }

    /// Every source's entries in source order, and an error detail for each source that failed.
    func catalog(reload: Bool = false) async -> PackageCatalog {
        await load(reload: reload).catalog
    }

    /// The entries of every source. Throws the first source's error only when every source failed.
    func index() async throws -> PackageIndex {
        try await combined(reload: false)
    }

    func reloadIndex() async throws -> PackageIndex {
        try await combined(reload: true)
    }

    /// Loads a source's index without caching it, for the Add source form.
    func check(_ source: PackageSource, token: String?) async throws -> PackageIndex {
        try await PackageIndex.load(from: source, token: token, session: session)
    }

    /// Loads a source's index, uncached, with the token saved for its id when `source` is on the origin it was saved for.
    func checkWithSavedToken(_ source: PackageSource) async throws -> PackageIndex {
        try await check(source, token: token(for: source))
    }

    /// The token goes along only when the screenshot is on its source's origin.
    func screenshot(for entry: PackageIndex.Entry) async throws -> Data {
        guard let url = entry.screenshot else { throw URLError(.fileDoesNotExist) }
        guard let source = source(id: entry.sourceID) else { return try await fetch(URLRequest(url: url), session: session) }
        return try await fetch(sourceRequest(for: url, source: source, token: token(for: source)), session: session)
    }

    /// Whether the configured source has a token saved for its current origin, the only token it sends.
    func tokenIsSaved(for sourceID: String) -> Bool {
        source(id: sourceID).flatMap(token(for:)) != nil
    }

    /// Trims a pasted token and saves it for the origin of `source`'s URL; an empty one deletes it.
    /// The source's index reloads with the new token.
    func saveToken(_ token: String, for source: PackageSource) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        try tokens.save(trimmed.isEmpty ? "" : SavedSourceToken(token: trimmed, for: source.url).stored, source.tokenAccount)
        indexTasks[source.id] = nil
    }

    func deleteToken(for sourceID: String) throws {
        try tokens.save("", PackageSource.tokenAccount(sourceID))
        indexTasks[sourceID] = nil
    }

    private static func privateSources(_ sources: [PackageSource]) -> [PackageSource] {
        var seen: Set<String> = [PackageSource.storeID, PackageSource.localID]
        return sources.filter { seen.insert($0.id).inserted }
    }

    /// Only a token saved for the source's current origin; a legacy plain value or another origin's token is never sent.
    private func token(for source: PackageSource) -> String? {
        guard !source.isStore, let stored = tokens.read(source.tokenAccount) else { return nil }
        return SavedSourceToken(stored: stored)?.token(for: source.url)
    }

    private func forget(_ sourceID: String) {
        indexTasks[sourceID] = nil
        for key in downloads.keys where key.hasPrefix("\(sourceID):") { downloads[key] = nil }
    }

    private func indexTask(for source: PackageSource, reload: Bool) -> Task<PackageIndex, Error> {
        if !reload, let task = indexTasks[source.id] { return task }
        let token = token(for: source), session = session
        let task = Task { try await PackageIndex.load(from: source, token: token, session: session) }
        indexTasks[source.id] = task
        return task
    }

    /// Sources load concurrently. A failed index isn't cached, so the next call retries it.
    private func load(reload: Bool) async -> (catalog: PackageCatalog, errors: [Error]) {
        let pending = sources.map { ($0, indexTask(for: $0, reload: reload)) }
        var catalog = PackageCatalog(), errors: [Error] = []
        for (source, task) in pending {
            do {
                catalog.entries += try await task.value.packages
            } catch {
                if indexTasks[source.id] == task { indexTasks[source.id] = nil }
                catalog.errors[source.id] = sourceErrorDetail(error)
                errors.append(error)
            }
        }
        // A source removed or moved while its index loaded doesn't list anything.
        let current = sources
        let stale = Set(pending.map(\.0).filter { source in !current.contains { $0.id == source.id && $0.url == source.url } }.map(\.id))
        catalog.entries.removeAll { stale.contains($0.sourceID) }
        for id in stale { catalog.errors[id] = nil }
        return (catalog, errors.count == pending.count ? errors : [])
    }

    private func combined(reload: Bool) async throws -> PackageIndex {
        let (catalog, errors) = await load(reload: reload)
        if let error = errors.first { throw error }
        return PackageIndex(packages: catalog.entries)
    }

    func installed() throws -> [WidgetPackageManifest] {
        try packages.list()
    }

    func inspect(_ directory: URL, settings: [String: ConfigurationValue] = [:]) throws -> WidgetPackageInspection {
        try packages.inspect(directory, settings: settings)
    }

    /// Installs a package from `source`, or from a local folder when it's nil.
    /// Throws `.claimed`, before copying anything, when another source installed the package's ID.
    func install(_ directory: URL, from source: PackageSource?) throws -> WidgetPackageInspection {
        do {
            return try packages.install(directory, record: source.map(PackageInstallRecord.init) ?? .local,
                                        requestedName: source?.name ?? "a local folder")
        } catch {
            throw namingInstalledSource(error, id: try? packages.manifest(at: directory).id)
        }
    }

    /// Installs the package listed as `id`, from the source named `sourceID` or else the only source that lists it.
    /// Only the sources asked about are loaded. Without `sourceID`, a source that failed to load might also list the ID,
    /// so the install fails and names the source to choose instead of picking one that answered.
    func install(id: String, from sourceID: String?) async throws -> WidgetPackageInspection {
        var candidates = sources
        if let sourceID {
            guard let source = source(id: sourceID) else {
                throw PackageSourceError.unknownSource(sourceID, configured: sources.map(\.id))
            }
            candidates = [source]
        }
        var matches: [PackageIndex.Entry] = [], failure: (source: PackageSource, detail: String)?
        for (source, task) in candidates.map({ ($0, indexTask(for: $0, reload: false)) }) {
            do {
                matches += try await task.value.packages.filter { $0.id == id }
            } catch {
                if indexTasks[source.id] == task { indexTasks[source.id] = nil }
                failure = failure ?? (source, sourceErrorDetail(error))
            }
        }
        guard let entry = matches.first else {
            if let failure { throw CommandFailure(message: "\(failure.source.name) is unavailable: \(failure.detail)") }
            throw WidgetPackageError.notInStore(id)
        }
        guard matches.count == 1 else {
            throw PackageSourceError.ambiguous(id: id, sources: matches.compactMap { source(id: $0.sourceID) })
        }
        guard let source = source(id: entry.sourceID) else { throw PackageSourceError.notConfigured(entry.sourceID) }
        if sourceID == nil, let failure {
            throw PackageSourceError.unavailable(source: failure.source.name, detail: failure.detail, id: id, listedIn: source)
        }
        let downloaded = try await package(entry)
        return try install(downloaded.directory, from: source)
    }

    /// Package ID → the source that installed it.
    func records() throws -> [String: PackageInstallRecord] {
        try packages.records()
    }

    /// The configured source's name, else the name saved when it was installed, else its ID.
    func name(of record: PackageInstallRecord) -> String {
        source(id: record.source)?.name ?? record.name ?? record.source
    }

    /// A claim refusal names the installing source as the configuration names it now.
    private func namingInstalledSource(_ error: Error, id: String?) -> Error {
        guard case let PackageSourceError.claimed(package, _, requested) = error,
              let id, let record = try? packages.record(id: id) else { return error }
        return PackageSourceError.claimed(package: package, installedFrom: name(of: record), requested: requested)
    }

    func savedSecrets(for manifest: WidgetPackageManifest) throws -> Set<String> {
        var saved: Set<String> = []
        for (name, setting) in manifest.settings where setting.type == "secret" {
            if try packageSecretIsSaved("\(manifest.id)/\(name)") { saved.insert(name) }
        }
        return saved
    }

    func screenshotData(for inspection: WidgetPackageInspection) throws -> Data? {
        try inspection.screenshot.map { try Data(contentsOf: $0) }
    }

    func choiceImageData(for inspection: WidgetPackageInspection) throws -> [String: Data] {
        try inspection.choiceImages.mapValues { try Data(contentsOf: $0) }
    }

    func saveSecrets(_ values: [String: String], for manifest: WidgetPackageManifest) throws {
        for (name, value) in values {
            try savePackageSecret(value, account: "\(manifest.id)/\(name)")
        }
    }

    func package(_ entry: PackageIndex.Entry) async throws -> WidgetPackageInspection {
        let key = entry.key + "/" + entry.sha256
        if let task = downloads[key] { return try await task.value }
        guard let source = source(id: entry.sourceID) else { throw PackageSourceError.notConfigured(entry.sourceID) }
        let token = token(for: source), session = session
        let task = Task {
            let directory = try await packages.download(entry, from: source, token: token, session: session)
            directories.append(directory.deletingLastPathComponent())
            let inspection = try packages.inspect(directory)
            guard inspection.manifest.kind == entry.kind else { throw PackageStoreClientError.kindMismatch }
            return inspection
        }
        downloads[key] = task
        do { return try await task.value }
        catch { if downloads[key] == task { downloads[key] = nil }; throw error }
    }

    /// Review the files that will actually be enabled: the version this entry's source installed, else the entry's download.
    /// Another source's copy, or one from a folder (unclaimed, or a folder version under this source's ID), isn't known
    /// to be this entry's package, so the entry's own files are downloaded instead. Adding a folder's copy then checks
    /// that its files are the download's.
    func packageForAdding(_ entry: PackageIndex.Entry) async throws -> WidgetPackageInspection {
        let destination = try packages.directory(id: entry.id, version: entry.version)
        let record = try packages.record(id: entry.id)
        guard FileManager.default.fileExists(atPath: destination.path), let record, record.source == entry.sourceID,
              !record.isLocal(version: entry.version) else { return try await package(entry) }
        let inspection = try packages.inspect(destination)
        guard inspection.manifest.id == entry.id, inspection.manifest.version == entry.version else {
            throw WidgetPackageError.archiveMismatch(entry.id, entry.version)
        }
        guard inspection.manifest.kind == entry.kind else { throw PackageStoreClientError.kindMismatch }
        return inspection
    }

    /// Packages declaring commands, access, tools or secret settings must use the existing review screen.
    func installWithoutReview(_ entry: PackageIndex.Entry) async throws -> WidgetPackageInspection {
        let downloaded = try await package(entry)
        let inspection = try packages.inspect(downloaded.directory)
        guard inspection.manifest.id == entry.id, inspection.manifest.version == entry.version else {
            throw WidgetPackageError.archiveMismatch(entry.id, entry.version)
        }
        guard inspection.manifest.kind == entry.kind else { throw PackageStoreClientError.kindMismatch }
        guard !inspection.requiresReview else { throw PackageStoreClientError.reviewRequired }
        guard let source = source(id: entry.sourceID) else { throw PackageSourceError.notConfigured(entry.sourceID) }
        let destination = try packages.directory(id: entry.id, version: entry.version)
        if FileManager.default.fileExists(atPath: destination.path) {
            let installed = try packages.inspect(destination)
            guard installed.manifest.kind == entry.kind else { throw PackageStoreClientError.kindMismatch }
            guard !installed.requiresReview else { throw PackageStoreClientError.reviewRequired }
            try claim(installed.manifest, from: source, reviewed: downloaded.directory)
            return installed
        }
        return try install(inspection.directory, from: source)
    }

    /// Records an installed version as `source`'s, as installing it would. `reviewed` holds the files the user got from
    /// `source`: a copy from a folder (no record, a local folder, or a folder version under `source`'s ID) becomes the
    /// source's only when it has those same files, so a folder's files can't take on a source's name.
    /// Throws `.differentFiles` when they differ, and `.claimed` when another source installed the package's ID.
    func claim(_ manifest: WidgetPackageManifest, from source: PackageSource, reviewed: URL) throws {
        let installed = try packages.directory(id: manifest.id, version: manifest.version)
        let record = try packages.record(id: manifest.id)
        if record.map({ $0.isLocal || ($0.source == source.id && $0.isLocal(version: manifest.version)) }) ?? true {
            // The installed copy can't vouch for itself; only a download from the source can.
            let same = reviewed.standardizedFileURL.resolvingSymlinksInPath() == installed.standardizedFileURL.resolvingSymlinksInPath()
            guard !same, try packages.sameContents(reviewed, installed) else {
                throw PackageSourceError.differentFiles(package: manifest.name, version: manifest.version, requested: source.name)
            }
        }
        do {
            try packages.claim(id: manifest.id, version: manifest.version, packageName: manifest.name,
                               for: PackageInstallRecord(source), requestedName: source.name)
        } catch { throw namingInstalledSource(error, id: manifest.id) }
    }
}
