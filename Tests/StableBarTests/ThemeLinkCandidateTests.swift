import Foundation
import Testing
@testable import StableBar

@MainActor @Suite(.serialized)
struct ThemeLinkCandidateTests {
    @Test func aLinkedThemeIsTriedFromATemporaryFolderAndRemovedOnDiscard() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        let link = try linkedTheme()
        let candidate = try ThemeLinkCandidate(link: link, store: store)
        defer { candidate.discard() }
        let original = try Data(contentsOf: fixture.url)
        let selection = store.selectedThemeKey
        #expect(candidate.state == .ready)
        #expect(!candidate.choice.isBundled)
        #expect(candidate.choice.directory.lastPathComponent.hasPrefix("stablebar-theme-link-"))
        #expect(try Data(contentsOf: candidate.choice.directory.appending(path: "package.json")) == link.manifest)
        #expect(try Data(contentsOf: candidate.choice.directory.appending(path: "config.json")) == link.configuration)

        candidate.tryOnBar()
        #expect(candidate.state == .trying)
        #expect(store.themeTrialKey == candidate.choice.key)
        #expect(store.selectedThemeKey == selection)
        #expect(store.configuration?.bar.height == 30)
        #expect(try Data(contentsOf: fixture.url) == original)
        #expect(store.customizationHistory.undoSteps.isEmpty)

        candidate.discard()
        candidate.discard()
        #expect(!exists(candidate.choice.directory))
        #expect(store.themeTrialKey == nil)
        candidate.tryOnBar()
        #expect(store.themeTrialKey == nil)
    }

    @Test func cancellingATrialKeepsTheCandidateReadyToTryAgain() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        let candidate = try ThemeLinkCandidate(link: linkedTheme(), store: store)
        defer { candidate.discard() }
        candidate.tryOnBar()
        candidate.cancelTrial()
        #expect(candidate.state == .ready)
        #expect(store.themeTrialKey == nil)
        #expect(exists(candidate.choice.directory))
        candidate.tryOnBar()
        #expect(candidate.state == .trying)
        #expect(store.themeTrialKey == candidate.choice.key)
    }

    @Test func aTrialSurvivesAReloadOfTheConfiguration() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        let candidate = try ThemeLinkCandidate(link: linkedTheme(), store: store)
        defer { candidate.discard() }
        candidate.tryOnBar()
        try fixture.write(#"{"widgets":[],"bar":{"margin":17}}"#, to: fixture.url)
        store.reloadConfiguration()
        #expect(store.configurationError == nil)
        #expect(candidate.state == .trying)
        #expect(store.themeTrialKey == candidate.choice.key)
        #expect(store.configuration?.bar.height == 30)
        #expect(store.configuration?.bar.margin == 17)
        #expect(exists(candidate.choice.directory))
        candidate.cancelTrial()
        #expect(store.configuration?.bar.margin == 17)
        #expect(store.themeTrialKey == nil)
    }

    @Test func tryingALinkedThemeEndsEditingTheBar() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        let candidate = try ThemeLinkCandidate(link: linkedTheme(), store: store)
        defer { candidate.discard() }
        store.barEditing.begin()
        #expect(store.barEditing.isActive)
        candidate.tryOnBar()
        #expect(!store.barEditing.isActive)
        #expect(candidate.state == .trying)
    }

    @Test func tryingALinkedThemeEndsTheOpenTryThemesPanel() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        let trial = ThemeTrial(store: store)
        trial.next()
        store.onEndThemeTrial = { trial.cancel() }
        let candidate = try ThemeLinkCandidate(link: linkedTheme(), store: store)
        defer { candidate.discard() }
        candidate.tryOnBar()
        #expect(!trial.isActive)
        #expect(candidate.state == .trying)
        #expect(store.themeTrialKey == candidate.choice.key)
    }

    @Test func aFailedTrialReportsTheLoaderErrorWithoutSelectingTheTheme() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let candidate = try ThemeLinkCandidate(link: linkedTheme(), store: store)
        defer { candidate.discard() }
        candidate.tryOnBar()
        #expect(candidate.state == .failed("Load a bar before trying themes."))
        #expect(store.selectedThemeKey == "built-in")
        #expect(store.themeTrialKey == nil)
        #expect(exists(candidate.choice.directory))
    }

    @Test func usingALinkedThemeInstallsItBeforeSelectingIt() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        let original = try Data(contentsOf: fixture.url)
        let candidate = try ThemeLinkCandidate(link: linkedTheme(), store: store)
        defer { candidate.discard() }
        candidate.tryOnBar()
        await candidate.use(with: client(fixture))
        let installed = try fixture.packages.directory(id: "harbour-test", version: "1.0.0")
        #expect(try Data(contentsOf: installed.appending(path: "config.json")) == candidate.link.configuration)
        #expect(try Data(contentsOf: installed.appending(path: "package.json")) == candidate.link.manifest)
        #expect(store.selectedThemeKey == "harbour-test/1.0.0")
        #expect(store.configurationError == nil)
        #expect(store.themeTrialKey == nil)
        #expect(candidate.state == .used)
        #expect(!exists(candidate.choice.directory))
        #expect(store.customizationHistory.undoSteps.count == 1)
        try store.customizationHistory.undo()
        #expect(try Data(contentsOf: fixture.url) == original)
        #expect(exists(installed))
    }

    @Test func theSameThemeAgainIsSelectedWithoutInstalling() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let installed = try fixture.packages.install(linkedThemeDirectory)
        let originalDate = Date(timeIntervalSince1970: 123_456)
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: installed.directory.path)
        let store = try loadedStore(fixture)
        defer { store.stop() }
        let candidate = try ThemeLinkCandidate(link: linkedTheme(), store: store)
        defer { candidate.discard() }
        await candidate.use(with: client(fixture))
        #expect(candidate.state == .used)
        #expect(store.selectedThemeKey == "harbour-test/1.0.0")
        #expect(!exists(candidate.choice.directory))
        let attributes = try FileManager.default.attributesOfItem(atPath: installed.directory.path)
        #expect(attributes[.modificationDate] as? Date == originalDate)
    }

    @Test(arguments: [false, true])
    func aDifferentThemeUnderAnInstalledVersionIsRefused(extraFile: Bool) async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let source = fixture.directory.appending(path: "different-theme")
        try FileManager.default.copyItem(at: linkedThemeDirectory, to: source)
        if extraFile {
            try fixture.write("extra", to: source.appending(path: ".hidden"))
        } else {
            try fixture.write(#"{"bar":{"height":42}}"#, to: source.appending(path: "config.json"))
        }
        _ = try fixture.packages.install(source)
        let store = try loadedStore(fixture)
        defer { store.stop() }
        let selection = store.selectedThemeKey
        let candidate = try ThemeLinkCandidate(link: linkedTheme(), store: store)
        defer { candidate.discard() }
        candidate.tryOnBar()
        await candidate.use(with: client(fixture))
        #expect(candidate.state == .failed(ThemeLinkError.versionTaken(id: "harbour-test", version: "1.0.0").errorDescription!))
        #expect(store.selectedThemeKey == selection)
        #expect(store.themeTrialKey == nil)
        #expect(store.customizationHistory.undoSteps.isEmpty)
    }

    @Test func usingALinkedThemeSharesTheGallerysScreenSelectionAndEveryBarChoice() async throws {
        let fixture = try ThemeGalleryFixture(#"{"widgets":[],"screens":{"monitor":{"theme":{"id":"nord"}}}}"#)
        defer { fixture.close() }
        let ownBar = fixture.directory.appending(path: "setup-monitor.json")
        try fixture.write(#"{"widgets":[]}"#, to: ownBar)
        let store = try loadedStore(fixture)
        defer { store.stop() }
        let candidate = try ThemeLinkCandidate(link: linkedTheme(), store: store)
        defer { candidate.discard() }
        await candidate.use(with: client(fixture), on: .monitor, everyBar: true)
        #expect(candidate.state == .used)
        let selected = ConfigurationValue.object(["id": .string("harbour-test"), "version": .string("1.0.0")])
        let screens = try #require(try fixture.document()["screens"]?.decoded([String: [String: ConfigurationValue]].self))
        #expect(screens["monitor"]?["theme"] == selected)
        let other = try JSONDecoder().decode([String: ConfigurationValue].self, from: Data(contentsOf: ownBar))
        let otherScreens = try #require(try other["screens"]?.decoded([String: [String: ConfigurationValue]].self))
        #expect(otherScreens["monitor"]?["theme"] == selected)
        #expect(store.customizationHistory.undoSteps.count == 1)
    }

    @Test func anInstallationErrorEndsTheTrialAndKeepsTheSelection() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        let candidate = try ThemeLinkCandidate(link: linkedTheme(), store: store)
        defer { candidate.discard() }
        candidate.tryOnBar()
        try fixture.write("not a directory", to: fixture.packages.directory)
        await candidate.use(with: client(fixture))
        guard case .failed = candidate.state else {
            Issue.record("Expected installation to fail")
            return
        }
        #expect(store.themeTrialKey == nil)
        #expect(store.selectedThemeKey == "built-in")
        #expect(store.customizationHistory.undoSteps.isEmpty)
    }

    @Test(arguments: Rejection.allCases)
    func linksMayNotCarryWhatAThemeLinkCantHold(rejection: Rejection) throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        var link = try linkedTheme()
        var manifest = try JSONDecoder().decode([String: ConfigurationValue].self, from: link.manifest)
        var configuration: [String: ConfigurationValue] = [:]
        switch rejection {
        case .bar: configuration["bar"] = .object(["hideMenuBar": .bool(true)])
        case .profileBar:
            configuration["profiles"] = .array([profile(["bar": .object(["position": .string("bottom")])])])
        case .hosts: manifest["hosts"] = .array([.string("example.com")])
        case .permissions: manifest["permissions"] = .array([.string("location")])
        case .tools: manifest["requires"] = .array([.string("sh")])
        case .secrets: manifest["settings"] = .object(["key": .object(["type": .string("secret")])])
        case .screenshot: manifest["screenshot"] = .string("screenshot.png")
        case .includes: configuration["includes"] = .array([.string("theme.json")])
        case .profileIncludes:
            configuration["profiles"] = .array([profile(["includes": .array([.string("theme.json")])])])
        case .widgets:
            manifest["kind"] = .string("widgets")
            configuration = try JSONDecoder().decode([String: ConfigurationValue].self, from: link.configuration)
        case .missingKind: manifest["kind"] = nil
        case .bundledID: manifest["id"] = .string("nord")
        case .legacyID: manifest["id"] = .string("slate")
        case .widgetID:
            let source = fixture.directory.appending(path: "widget")
            try fixture.write(#"{"id":"harbour-test","name":"Widget","version":"2","kind":"widgets","entry":"config.json"}"#,
                              to: source.appending(path: "package.json"))
            try fixture.write(#"{"widgets":[]}"#, to: source.appending(path: "config.json"))
            _ = try fixture.packages.install(source)
        case .doublingTokens:
            configuration["tokens"] = .object(doublingTokens(levels: 17))
            configuration["bar"] = .object(["style": .object(["background": .string("@token.t17")])])
        case .profileExpansion, .nestedProfileExpansion:
            let colors = ConfigurationValue.array(Array(repeating: .string("#123456"), count: 250))
            configuration["tokens"] = .object(["colors": colors])
            let rows = Array(repeating: ConfigurationValue.string("@token.colors"), count: 400)
            let gradient: ConfigurationValue = .object(["gradient": .object(["colors": .array(rows)])])
            var content: [String: ConfigurationValue] = ["defaults": .object(["background": gradient])]
            if rejection == .nestedProfileExpansion { content = ["profiles": .array([profile(content, name: "Nested")])] }
            configuration["profiles"] = .array([profile(content, enabled: false)])
        case .tokenBar, .overriddenTokenBar:
            configuration["tokens"] = .object(["bar": .object(["hideMenuBar": .bool(true)])])
            configuration["bar"] = .string("@token.bar")
            if rejection == .overriddenTokenBar {
                configuration["profiles"] = .array([profile(["bar": .object(["height": .number(30)])])])
            }
        case .settingBar:
            manifest["settings"] = .object(["property": .object(["type": .string("string"), "default": .string("@token.bar")])])
            configuration["tokens"] = .object(["bar": .object(["hideMenuBar": .bool(true)])])
            configuration["bar"] = .string("@setting.property")
        case .referenceDepth:
            var tokens: [String: ConfigurationValue] = ["t0": .number(1)]
            for level in 1...66 { tokens["t\(level)"] = .string("@token.t\(level - 1)") }
            configuration["tokens"] = .object(tokens)
        case .referenceOrigins:
            var tokens: [String: ConfigurationValue] = ["t0": .number(1)]
            for level in 1...12 {
                tokens["t\(level)"] = .object([
                    String(repeating: "A", count: 1_300) + String(level): .string("@token.t\(level - 1)"),
                    String(repeating: "B", count: 1_300) + String(level): .string("@token.t\(level - 1)")
                ])
            }
            configuration["tokens"] = .object(tokens)
            configuration["bar"] = .object(["style": .object(["background": .string("@token.t12")])])
        case .invalidEntry: manifest["entry"] = .string("missing.json")
        case .unknownProperty: configuration["notAThemeProperty"] = .bool(true)
        case .tooLarge, .tooDeep, .tooManyProfiles, .notUTF8, .notAnObject: break
        }
        link.manifest = try configurationData(manifest)
        link.configuration = try configurationData(configuration)
        switch rejection {
        case .tooLarge: link.configuration = Data((#"{"tokens":{"large":""# + String(repeating: "x", count: 32_768) + #""}}"#).utf8)
        case .tooDeep: link.configuration = Data((#"{"tokens":{"deep":"# + String(repeating: "[", count: 500) + "0" + String(repeating: "]", count: 500) + "}}").utf8)
        case .tooManyProfiles: link.configuration = try configurationData(["profiles": .array((0..<17).map { profile([:], name: "p\($0)") })])
        case .notUTF8: link.configuration = try #require("{}".data(using: .utf16))
        case .notAnObject: link.configuration = Data("[]".utf8)
        default: break
        }
        let before = try temporaryFolders()
        let error = #expect(throws: (any Error).self) {
            let candidate = try ThemeLinkCandidate(link: link, store: store)
            candidate.discard()
        }
        #expect(try temporaryFolders() == before)
        switch rejection {
        case .bar, .tokenBar, .overriddenTokenBar, .settingBar: #expect(error as? ThemeLinkError == .barProperty("hideMenuBar"))
        case .profileBar: #expect(error as? ThemeLinkError == .barProperty("position"))
        case .hosts, .permissions, .tools, .secrets: #expect(error as? ThemeLinkError == .needsReview)
        case .screenshot, .includes, .profileIncludes: #expect(error as? ThemeLinkError == .extraFiles)
        case .widgets, .missingKind: #expect(error as? ThemeLinkError == .notATheme)
        case .bundledID: #expect(error as? ThemeLinkError == .reservedID("nord"))
        case .legacyID: #expect(error as? ThemeLinkError == .reservedID("slate"))
        case .widgetID: #expect(error as? ThemeLinkError == .idTaken("harbour-test"))
        case .tooLarge: #expect(error as? ThemeLinkError == .tooLarge)
        case .tooDeep: #expect(error as? ThemeLinkError == .tooDeep)
        case .tooManyProfiles: #expect(error as? ThemeLinkError == .tooManyProfiles)
        case .notUTF8, .notAnObject: #expect(error as? ThemeLinkError == .damaged)
        case .doublingTokens, .profileExpansion, .nestedProfileExpansion:
            guard case .referenceExpansionTooLarge? = error as? ThemeConfigurationError else {
                Issue.record("Expected reference expansion limit, got \(String(describing: error))")
                return
            }
        case .referenceDepth:
            guard case .referenceNestingTooDeep? = error as? ThemeConfigurationError else {
                Issue.record("Expected reference depth limit, got \(String(describing: error))")
                return
            }
        case .referenceOrigins:
            guard case .referenceOriginsTooLarge? = error as? ThemeConfigurationError else {
                Issue.record("Expected reference origins limit, got \(String(describing: error))")
                return
            }
        case .invalidEntry, .unknownProperty: #expect(error is WidgetPackageError)
        }
    }

    @Test(arguments: [false, true])
    func profileTokensAndNonSecretSettingsCanBeUsed(rootUsesProfileToken: Bool) async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        var link = try linkedTheme()
        var manifest = try JSONDecoder().decode([String: ConfigurationValue].self, from: link.manifest)
        manifest["settings"] = .object(["size": .object(["type": .string("number"), "default": .number(19)])])
        link.manifest = try configurationData(manifest)
        link.configuration = Data(##"""
        {"tokens":{"base":"#123456"},"defaults":{"fontSize":"@setting.size"},"profiles":[
          {"name":"Local tokens","configuration":{"tokens":{"color":"@token.base"},"defaults":{"foreground":"@token.color"}}}
        ]}
        """##.utf8)
        if rootUsesProfileToken {
            var document = try JSONDecoder().decode([String: ConfigurationValue].self, from: link.configuration)
            document["defaults"] = .object(["fontSize": .string("@setting.size"), "foreground": .string("@token.color")])
            link.configuration = try configurationData(document)
        }
        let candidate = try ThemeLinkCandidate(link: link, store: store)
        defer { candidate.discard() }
        candidate.tryOnBar()
        #expect(candidate.state == .trying)
        #expect(store.configuration?.defaults.fontSize == 19)
        await candidate.use(with: client(fixture))
        #expect(candidate.state == .used)
    }

    enum Rejection: CaseIterable, Sendable {
        case bar, profileBar, hosts, permissions, tools, secrets, screenshot, includes, profileIncludes
        case widgets, missingKind, bundledID, legacyID, widgetID, doublingTokens, profileExpansion, nestedProfileExpansion
        case tokenBar, overriddenTokenBar, settingBar, referenceDepth, referenceOrigins, invalidEntry, unknownProperty
        case tooLarge, tooDeep, tooManyProfiles, notUTF8, notAnObject
    }

    private var linkedThemeDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/linked-theme")
    }

    private func linkedTheme() throws -> ThemeLink {
        ThemeLink(manifest: try Data(contentsOf: linkedThemeDirectory.appending(path: "package.json")),
                  configuration: try Data(contentsOf: linkedThemeDirectory.appending(path: "config.json")))
    }

    private func loadedStore(_ fixture: ThemeGalleryFixture) throws -> BarStore {
        let store = try fixture.store()
        store.reloadConfiguration()
        #expect(store.configurationError == nil)
        _ = try #require(store.configuration)
        return store
    }

    private func client(_ fixture: ThemeGalleryFixture) -> PackageStoreClient {
        PackageStoreClient(packages: fixture.packages, indexURL: fixture.directory.appending(path: "index.json"))
    }

    private func exists(_ directory: URL) -> Bool { FileManager.default.fileExists(atPath: directory.path) }

    private func temporaryFolders() throws -> Set<URL> {
        Set(try FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("stablebar-theme-link-") })
    }

    private func profile(_ configuration: [String: ConfigurationValue], name: String = "Test", enabled: Bool = true) -> ConfigurationValue {
        .object(["name": .string(name), "enabled": .bool(enabled), "configuration": .object(configuration)])
    }

    private func doublingTokens(levels: Int) -> [String: ConfigurationValue] {
        var tokens: [String: ConfigurationValue] = ["t0": .array([.number(1), .number(1)])]
        for level in 1...levels {
            let reference = ConfigurationValue.string("@token.t\(level - 1)")
            tokens["t\(level)"] = .array([reference, reference])
        }
        return tokens
    }
}
