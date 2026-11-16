import Foundation
import Observation

@MainActor @Observable
final class ThemeLinkCandidate {
    enum State: Equatable { case ready, trying, used, failed(String) }

    let link: ThemeLink
    let choice: ThemeChoice
    let validationExpansionUnits: Int
    let validationOriginPathBytes: Int
    private var candidateState: State = .ready
    var state: State {
        if candidateState == .trying, store?.themeTrialDirectory != choice.directory { return .ready }
        return candidateState
    }
    private weak var store: BarStore?
    private var discarded = false
    private var using = false

    init(link: ThemeLink, store: BarStore) throws {
        try link.validateFiles()
        let directory = FileManager.default.temporaryDirectory.appending(path: "stablebar-theme-link-\(UUID().uuidString)")
        let packages = store.packageStoreClient.packages
        let budget = ConfigurationReferenceExpansionBudget(limit: 300_000, originPathByteLimit: 8_000_000)
        do {
            let manifest = try JSONDecoder().decode([String: ConfigurationValue].self, from: link.manifest)
            let document = try JSONDecoder().decode([String: ConfigurationValue].self, from: link.configuration)
            guard manifest["kind"] == .string("theme") else { throw ThemeLinkError.notATheme }
            if manifest["screenshot"] != nil { throw ThemeLinkError.extraFiles }
            var profileCount = 0
            let numericReferences = Self.numericReferences(in: document, manifest: manifest)
            try Self.checkDocument(document, profileCount: &profileCount,
                                   numericReferences: numericReferences)

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
            validationOriginPathBytes = budget.consumedOriginPathBytes
            self.store = store
        } catch {
            try? FileManager.default.removeItem(at: directory)
            if error is DecodingError { throw ThemeLinkError.damaged }
            throw budget.themeLinkError(error)
        }
    }

    func tryOnBar() {
        guard !discarded, !using, state != .used, let store else { return }
        store.barEditing.end()
        store.onEndThemeTrial?()
        do {
            try store.tryTheme(choice)
            candidateState = .trying
        } catch {
            store.endThemeTrial()
            candidateState = .failed(errorMessage(error))
        }
    }

    func cancelTrial() {
        guard state == .trying else { return }
        if store?.themeTrialDirectory == choice.directory { store?.endThemeTrial() }
        candidateState = .ready
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
            candidateState = .used
            try? FileManager.default.removeItem(at: choice.directory)
        } catch {
            guard !discarded else { return }
            store.onEndThemeTrial?()
            store.endThemeTrial()
            candidateState = .failed(errorMessage(error))
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
    private static let barNumberRanges: [String: ClosedRange<Double>] = {
        var ranges: [String: ClosedRange<Double>] = [
            "bar.height": 16...100, "bar.inset": 0...100, "bar.spacing": 0...50,
            "bar.margin": 0...40, "bar.style.borderWidth": 0...6, "bar.style.cornerRadius": 0...40,
            "bar.style.fontSize": 6...40,
            "bar.style.paddingHorizontal": 0...40, "bar.style.paddingVertical": 0...40,
            "bar.style.opacity": 0...1, "bar.popupOffset": 0...40,
            // Notch dimensions and other style numbers have no Settings control.
            "bar.notchWidth": 0...1_000, "bar.notchSpacing": 0...100,
            "bar.style.offsetX": -1_000...1_000, "bar.style.offsetY": -1_000...1_000
        ]
        for fill in ["bar.background", "bar.style.background", "bar.style.hoverBackground"] {
            ranges["\(fill).gradient.angle"] = 0...360
            ranges["\(fill).gradient.locations"] = 0...1
        }
        return ranges
    }()

    private static func barNumberRange(at path: [String]) -> ClosedRange<Double> {
        var path = path
        if path.starts(with: ["bar", "style"]) {
            while path.count > 3, path[2] == "states" { path.removeSubrange(2...3) }
        }
        return barNumberRanges[path.joined(separator: ".")] ?? 0...1_000
    }

    private static func checkBarNumbers(
        _ value: ConfigurationValue, path: [String], numericReferences: Set<String>
    ) throws {
        switch value {
        case let .number(number):
            guard number.isFinite, barNumberRange(at: path).contains(number) else {
                throw ThemeLinkError.barValue(path.dropFirst().joined(separator: "."))
            }
        case let .string(reference) where numericReferences.contains(reference):
            throw ThemeLinkError.indirectBar
        case let .object(values):
            for (key, value) in values.sorted(by: { $0.key < $1.key }) {
                try checkBarNumbers(value, path: path + [key], numericReferences: numericReferences)
            }
        case let .array(values):
            for value in values {
                try checkBarNumbers(value, path: path, numericReferences: numericReferences)
            }
        default: break
        }
    }

    private static func numericReferences(
        in document: [String: ConfigurationValue], manifest: [String: ConfigurationValue]
    ) -> Set<String> {
        var sources: [String: [ConfigurationValue]] = [:]
        func collect(_ document: [String: ConfigurationValue]) {
            if case let .object(tokens)? = document["tokens"] {
                for (name, value) in tokens { sources["@token.\(name)", default: []].append(value) }
            }
            if case let .array(profiles)? = document["profiles"] {
                for case let .object(profile) in profiles {
                    if case let .object(configuration)? = profile["configuration"] {
                        collect(configuration)
                    }
                }
            }
        }
        collect(document)
        var numeric: Set<String> = []
        var freeStrings: Set<String> = []
        if case let .object(settings)? = manifest["settings"] {
            for (name, value) in settings {
                guard case let .object(setting) = value else { continue }
                let reference = "@setting.\(name)"
                if setting["type"] == .string("number") { numeric.insert(reference) }
                if let value = setting["default"] { sources[reference, default: []].append(value) }
                if case let .array(choices)? = setting["choices"] {
                    sources[reference, default: []] += choices
                } else if setting["type"] == .string("string") {
                    freeStrings.insert(reference)
                }
            }
        }
        func containsNumber(_ value: ConfigurationValue) -> Bool {
            switch value {
            case .number: true
            case let .string(reference): numeric.contains(reference)
            case let .object(values): values.values.contains(where: containsNumber)
            case let .array(values): values.contains(where: containsNumber)
            default: false
            }
        }
        // Profiles combine and choices change later; follow every source without expanding it.
        var previous: Set<String>
        repeat {
            previous = numeric
            for (reference, values) in sources where values.contains(where: containsNumber) {
                numeric.insert(reference)
            }
            if !numeric.isEmpty { numeric.formUnion(freeStrings) }
        } while numeric != previous
        return numeric
    }

    private static func checkInstalledID(_ id: String, packages: WidgetPackageStore) throws {
        let directory = packages.directory.appending(path: id)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try validatePackagePath(directory, inside: packages.directory)
        let versions = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
        let stagingPrefix = ".install-"
        for version in versions {
            guard try version.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
            try validatePackagePath(version, inside: packages.directory)
            if version.lastPathComponent.hasPrefix(stagingPrefix),
               UUID(uuidString: String(version.lastPathComponent.dropFirst(stagingPrefix.count))) != nil,
               !FileManager.default.fileExists(atPath: version.appending(path: "package.json").path) { continue }
            guard let manifest = try? packages.manifest(at: version), manifest.kind == .theme, manifest.id == id else {
                throw ThemeLinkError.idTaken(id)
            }
        }
    }

    private static func checkDocument(
        _ document: [String: ConfigurationValue], profileCount: inout Int,
        numericReferences: Set<String> = []
    ) throws {
        if document["includes"] != nil { throw ThemeLinkError.extraFiles }
        if let value = document["bar"] {
            // Profiles and setting choices must never supply the bar's keys or numbers.
            guard case let .object(bar) = value else { throw ThemeLinkError.indirectBar }
            for key in bar.keys.sorted() where !barProperties.contains(key) { throw ThemeLinkError.barProperty(key) }
            try checkBarNumbers(value, path: ["bar"], numericReferences: numericReferences)
        }
        let profiles = try document["profiles"]?.decoded([ConfigurationProfile].self) ?? []
        profileCount += profiles.count
        guard profileCount <= ThemeLink.maximumProfiles else { throw ThemeLinkError.tooManyProfiles }
        for profile in profiles {
            try checkDocument(profile.configuration, profileCount: &profileCount,
                              numericReferences: numericReferences)
        }
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

extension ConfigurationReferenceExpansionBudget {
    func themeLinkError(_ error: any Error) -> any Error {
        switch error as? ThemeConfigurationError {
        case .referenceExpansionTooLarge where consumed == limit:
            return ThemeLinkError.tooManyReferences
        case .referenceOriginsTooLarge where consumedOriginPathBytes == originPathByteLimit:
            return ThemeLinkError.tooManyReferences
        default: return error
        }
    }
}
