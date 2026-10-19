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

/// Session cache shared by Customize's galleries. File work and validation stay off the main actor.
actor PackageStoreClient {
    let packages: WidgetPackageStore
    let indexURL: URL
    private var indexTask: Task<PackageIndex, Error>?
    private var downloads: [String: Task<WidgetPackageInspection, Error>] = [:]
    private var directories: [URL] = []

    init(packages: WidgetPackageStore, indexURL: URL = PackageIndex.url) {
        self.packages = packages
        self.indexURL = indexURL
    }

    deinit {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
    }

    func index() async throws -> PackageIndex {
        if let indexTask { return try await indexTask.value }
        let task = Task { try await PackageIndex.load(from: indexURL) }
        indexTask = task
        do { return try await task.value }
        catch { indexTask = nil; throw error }
    }

    func package(_ entry: PackageIndex.Entry) async throws -> WidgetPackageInspection {
        let key = "\(entry.id)/\(entry.version)/\(entry.sha256)"
        if let task = downloads[key] { return try await task.value }
        let task = Task {
            let source = try await packages.download(entry, from: indexURL)
            directories.append(source.deletingLastPathComponent())
            let inspection = try packages.inspect(source)
            guard inspection.manifest.kind == entry.kind else { throw PackageStoreClientError.kindMismatch }
            return inspection
        }
        downloads[key] = task
        do { return try await task.value }
        catch { downloads[key] = nil; throw error }
    }

    /// Review the files that will actually be enabled, including an already installed version.
    func packageForAdding(_ entry: PackageIndex.Entry) async throws -> WidgetPackageInspection {
        let destination = try packages.directory(id: entry.id, version: entry.version)
        guard FileManager.default.fileExists(atPath: destination.path) else { return try await package(entry) }
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
        let destination = try packages.directory(id: entry.id, version: entry.version)
        if FileManager.default.fileExists(atPath: destination.path) {
            let installed = try packages.inspect(destination)
            guard installed.manifest.kind == entry.kind else { throw PackageStoreClientError.kindMismatch }
            guard !installed.requiresReview else { throw PackageStoreClientError.reviewRequired }
            return installed
        }
        return try packages.install(inspection.directory)
    }
}
