import CryptoKit
import Foundation

/// What a build produced: the package IDs in the index, and the new files written next to it.
struct PackageSourceBuild: Equatable {
    let ids: [String]
    let written: [String]
}

/// Builds a private package source from a folder of packages: one archive for each new package version, and the `index.json`
/// that lists them in the same format as the StableBar Store's.
struct PackageSourceBuilder {
    /// A folder whose direct subfolders are packages.
    let packages: URL
    /// Where the archives, screenshots and `index.json` go.
    let output: URL
    /// An earlier `index.json`. A package version it lists keeps its entry, and no archive is written for it.
    var previous: URL? = nil

    private struct Pending {
        let folder: URL
        let manifest: WidgetPackageManifest
        let screenshot: URL?
    }

    func build() async throws -> PackageSourceBuild {
        let kept = try previousEntries()
        let fileManager = FileManager.default
        let folders = try fileManager.contentsOfDirectory(at: packages, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { fileManager.fileExists(atPath: $0.appending(path: "package.json").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        // Validate everything before a file is written.
        let store = WidgetPackageStore(directory: fileManager.temporaryDirectory.appending(path: UUID().uuidString))
        var found: [String: Pending] = [:]
        var folderNames: [String: String] = [:]
        for folder in folders {
            let inspection: WidgetPackageInspection
            do {
                inspection = try store.inspect(folder)
            } catch {
                throw CommandFailure(message: "\(folder.lastPathComponent): \(errorMessage(error))")
            }
            let id = inspection.manifest.id
            if let other = folderNames[id] {
                throw CommandFailure(message: "Two folders contain package \(id): \(other), \(folder.lastPathComponent).")
            }
            folderNames[id] = folder.lastPathComponent
            found[id] = Pending(folder: folder, manifest: inspection.manifest, screenshot: inspection.screenshot)
        }
        guard !found.isEmpty else {
            throw CommandFailure(message: "No package folders in \(packages.path). A package folder holds a package.json.")
        }
        let ids = found.keys.sorted()
        var entries: [[String: ConfigurationValue]] = []
        var work: [(Pending, String, String?)] = []
        for id in ids {
            let pending = found[id]!
            let manifest = pending.manifest
            if let entry = kept["\(id)/\(manifest.version)"] {
                entries.append(entry)
                continue
            }
            let archive = "\(id)-\(manifest.version).tar.gz"
            let screenshot = pending.screenshot.map { "\(id)-\(manifest.version)-\($0.lastPathComponent)" }
            for name in [archive] + [screenshot].compactMap({ $0 }) where fileManager.fileExists(atPath: output.appending(path: name).path) {
                throw CommandFailure(message: "\(name) already exists in \(output.path). Published files never change: give the package a new version, or pass the earlier index with --previous.")
            }
            work.append((pending, archive, screenshot))
        }
        try fileManager.createDirectory(at: output, withIntermediateDirectories: true)
        var written: [String] = []
        for (pending, archive, screenshot) in work {
            let manifest = pending.manifest
            let archiveURL = output.appending(path: archive)
            _ = try await runCommand("/usr/bin/tar", arguments: ["-czf", archiveURL.path, "-C", pending.folder.path, "."],
                                     timeout: 120, environment: ["COPYFILE_DISABLE": "1"])
            written.append(archive)
            var entry: [String: ConfigurationValue] = [
                "id": .string(manifest.id), "name": .string(manifest.name), "version": .string(manifest.version),
                "archive": .string(archive),
                "sha256": .string(SHA256.hash(data: try Data(contentsOf: archiveURL)).map { String(format: "%02x", $0) }.joined()),
            ]
            if let kind = manifest.kind { entry["kind"] = .string(kind.rawValue) }
            if let description = manifest.description { entry["description"] = .string(description) }
            if let author = manifest.author { entry["author"] = .string(author) }
            if let minimumVersion = manifest.minimumVersion { entry["minimumVersion"] = .string(minimumVersion) }
            if let repository = manifest.repository { entry["source"] = .string(repository.absoluteString) }
            if let screenshot, let source = pending.screenshot {
                try fileManager.copyItem(at: source, to: output.appending(path: screenshot))
                written.append(screenshot)
                entry["screenshot"] = .string(screenshot)
            }
            entries.append(entry)
        }
        entries.sort { $0.stringValue("id") < $1.stringValue("id") }
        try configurationData(["packages": .array(entries.map(ConfigurationValue.object))])
            .write(to: output.appending(path: "index.json"), options: .atomic)
        return PackageSourceBuild(ids: ids, written: written)
    }

    /// The earlier index's entries by "id/version", as the JSON they were published with.
    private func previousEntries() throws -> [String: [String: ConfigurationValue]] {
        guard let previous else { return [:] }
        let data: Data
        do {
            data = try Data(contentsOf: previous)
        } catch {
            throw CommandFailure(message: "Could not read \(previous.path): \(error.localizedDescription)")
        }
        guard case let .object(document)? = try? JSONDecoder().decode(ConfigurationValue.self, from: data),
              case let .array(listed)? = document["packages"] else {
            throw CommandFailure(message: "\(previous.path) isn’t a StableBar package index.")
        }
        var entries: [String: [String: ConfigurationValue]] = [:]
        for case let .object(entry) in listed {
            let key = "\(entry.stringValue("id"))/\(entry.stringValue("version"))"
            if entries[key] == nil { entries[key] = entry }
        }
        return entries
    }
}

private extension Dictionary where Key == String, Value == ConfigurationValue {
    func stringValue(_ key: String) -> String {
        if case let .string(text)? = self[key] { return text }
        return ""
    }
}
