import Foundation
import Observation

@MainActor @Observable
final class ThemeLinkCandidate {
    enum State: Equatable { case ready, trying, used, failed(String) }

    let link: ThemeLink
    let choice: ThemeChoice
    let validationExpansionUnits: Int
    private(set) var state: State = .ready
    private weak var store: BarStore?
    private var discarded = false
    private var using = false

    init(link: ThemeLink, store: BarStore) throws {
        try link.validateFiles()
        let directory = FileManager.default.temporaryDirectory.appending(path: "stablebar-theme-link-\(UUID().uuidString)")
        let packages = store.packageStoreClient.packages
        let budget = ConfigurationReferenceExpansionBudget(limit: 300_000)
        do {
            let manifest = try JSONDecoder().decode([String: ConfigurationValue].self, from: link.manifest)
            let document = try JSONDecoder().decode([String: ConfigurationValue].self, from: link.configuration)
            if manifest["screenshot"] != nil { throw ThemeLinkError.extraFiles }
            var profileCount = 0
            try Self.checkDocument(document, profileCount: &profileCount)
            guard manifest["kind"] == .string("theme") else { throw ThemeLinkError.notATheme }

            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try link.manifest.write(to: directory.appending(path: "package.json"))
            try link.configuration.write(to: directory.appending(path: "config.json"))
            let inspection = try packages.inspect(directory, referenceExpansionBudget: budget)
            guard inspection.manifest.kind == .theme else { throw ThemeLinkError.notATheme }
            guard !inspection.requiresReview else { throw ThemeLinkError.needsReview }
            let id = inspection.manifest.id
            let bundled = store.themesDirectory?.appending(path: id)
            if legacyThemeIDs.contains(id) || bundled.map({ FileManager.default.fileExists(atPath: $0.path) }) == true {
                throw ThemeLinkError.reservedID(id)
            }
            try Self.checkInstalledID(id, packages: packages)
            var loader = ConfigurationLoader()
            loader.referenceExpansionBudget = budget
            let layer = try loader.readPackage(at: directory, manifest: inspection.manifest, settings: [:])
            try Self.checkReferences(layer, budget: budget)
            self.link = link
            choice = ThemeChoice(manifest: inspection.manifest, directory: directory, isBundled: false)
            validationExpansionUnits = budget.consumed
            self.store = store
        } catch {
            try? FileManager.default.removeItem(at: directory)
            if error is DecodingError { throw ThemeLinkError.damaged }
            if case .referenceExpansionTooLarge? = error as? ThemeConfigurationError, budget.consumed == budget.limit {
                throw ThemeLinkError.tooManyReferences
            }
            throw error
        }
    }

    func tryOnBar() {
        guard !discarded, !using, state != .used, let store else { return }
        store.barEditing.end()
        store.onEndThemeTrial?()
        do {
            try store.tryTheme(choice)
            state = .trying
        } catch {
            store.endThemeTrial()
            state = .failed(errorMessage(error))
        }
    }

    func cancelTrial() {
        guard state == .trying else { return }
        if store?.themeTrialDirectory == choice.directory { store?.endThemeTrial() }
        state = .ready
    }

    func use(on kind: ScreenKind? = nil, everyBar: Bool = false) async {
        guard !discarded, !using, state != .used, let store else { return }
        using = true
        defer { using = false }
        do {
            let client = store.packageStoreClient
            let packages = client.packages
            try Self.checkInstalledID(choice.manifest.id, packages: packages)
            let directory = try packages.directory(id: choice.manifest.id, version: choice.manifest.version)
            let installed: ThemeChoice
            if FileManager.default.fileExists(atPath: directory.path) {
                guard try sameFiles(at: directory) else {
                    throw ThemeLinkError.versionTaken(id: choice.manifest.id, version: choice.manifest.version)
                }
                installed = ThemeChoice(manifest: choice.manifest, directory: directory, isBundled: false)
            } else {
                let inspection = try await client.install(choice.directory, from: nil)
                installed = ThemeChoice(manifest: inspection.manifest, directory: inspection.directory, isBundled: false)
            }
            guard !discarded else { return }
            try store.applyTheme(installed, on: kind, everyBar: everyBar)
            store.onEndThemeTrial?()
            store.endThemeTrial()
            state = .used
            try? FileManager.default.removeItem(at: choice.directory)
        } catch {
            guard !discarded else { return }
            store.onEndThemeTrial?()
            store.endThemeTrial()
            state = .failed(errorMessage(error))
        }
    }

    func discard() {
        guard !discarded else { return }
        discarded = true
        cancelTrial()
        try? FileManager.default.removeItem(at: choice.directory)
    }

    private func sameFiles(at directory: URL) throws -> Bool {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard Set(files.map(\.lastPathComponent)) == ["package.json", "config.json"] else { return false }
        for file in files {
            let properties = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard properties.isRegularFile == true, properties.isSymbolicLink != true else { return false }
            let expected = file.lastPathComponent == "package.json" ? link.manifest : link.configuration
            guard try Data(contentsOf: file) == expected else { return false }
        }
        return true
    }

    private static let barProperties = savedThemeBarProperties.union(["popupOffset"])

    private static func checkInstalledID(_ id: String, packages: WidgetPackageStore) throws {
        let directory = packages.directory.appending(path: id)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try validatePackagePath(directory, inside: packages.directory)
        let versions = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
        let stagingPrefix = ".install-"
        for version in versions {
            if version.lastPathComponent.hasPrefix(stagingPrefix),
               UUID(uuidString: String(version.lastPathComponent.dropFirst(stagingPrefix.count))) != nil { continue }
            guard try version.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
            try validatePackagePath(version, inside: packages.directory)
            guard let manifest = try? packages.manifest(at: version), manifest.kind == .theme, manifest.id == id else {
                throw ThemeLinkError.idTaken(id)
            }
        }
    }

    private static func checkDocument(_ document: [String: ConfigurationValue], profileCount: inout Int) throws {
        if document["includes"] != nil { throw ThemeLinkError.extraFiles }
        if let value = document["bar"] {
            // References may supply allowed values, but profile and setting choices must never supply the bar's keys.
            guard case let .object(bar) = value else { throw ThemeLinkError.indirectBar }
            for key in bar.keys.sorted() where !barProperties.contains(key) { throw ThemeLinkError.barProperty(key) }
        }
        let profiles = try document["profiles"]?.decoded([ConfigurationProfile].self) ?? []
        profileCount += profiles.count
        guard profileCount <= ThemeLink.maximumProfiles else { throw ThemeLinkError.tooManyProfiles }
        for profile in profiles { try checkDocument(profile.configuration, profileCount: &profileCount) }
    }

    private static func checkReferences(_ layer: ConfigurationLayer, budget: ConfigurationReferenceExpansionBudget) throws {
        var loader = ConfigurationLoader()
        loader.referenceExpansionBudget = budget
        let resolved = try loader.finish(layer, context: ConfigurationContext())
        var profileCount = 0
        try checkDocument(resolved, profileCount: &profileCount)
        let originalTokens = layer.values["tokens"] ?? .object([:])
        let inheritedTokens = resolved["tokens"] ?? .object([:])
        let tokens = try originalTokens.overriding(inheritedTokens).decoded([String: ConfigurationValue].self)
        // Merging can hide raw references, and the loader strips profiles before substitution; Settings reads both.
        try checkDocumentReferences(layer.values, tokens: tokens, budget: budget)
        let profiles = try layer.values["profiles"]?.decoded([ConfigurationProfile].self) ?? []
        for profile in profiles {
            loader.previewProfile = profile.name
            let selected = try loader.finish(layer, context: ConfigurationContext())
            try checkDocument(selected, profileCount: &profileCount)
        }
    }

    private static func checkDocumentReferences(_ document: [String: ConfigurationValue], tokens: [String: ConfigurationValue],
                                                budget: ConfigurationReferenceExpansionBudget) throws {
        var base = document
        let profiles = try base.removeValue(forKey: "profiles")?.decoded([ConfigurationProfile].self) ?? []
        let resolved = try substituteConfigurationReferences(.object(base), prefix: "@token.", values: tokens, budget: budget)
            .decoded([String: ConfigurationValue].self)
        var profileCount = 0
        try checkDocument(resolved, profileCount: &profileCount)
        for profile in profiles {
            let localTokens = profile.configuration["tokens"] ?? .object([:])
            let inherited = try localTokens.overriding(.object(tokens))
                .decoded([String: ConfigurationValue].self)
            try checkDocumentReferences(profile.configuration, tokens: inherited, budget: budget)
        }
    }
}
