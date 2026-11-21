import Foundation
import Testing
@testable import StableBar

@MainActor @Suite(.serialized)
struct ThemeLinkCandidateTests {
    @Test(arguments: [false, true])
    func aThemeLinkOpensTheThemePageAndReplacesAnEarlierOne(tryFirst: Bool) throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        let a = try linkedTheme()
        var b = a
        b.configuration = Data(#"{"bar":{"height":42}}"#.utf8)

        #expect(store.receive([a.link]) == .appearance)
        let first = try #require(store.pendingLinks.theme)
        defer { first.discard() }
        #expect(first.link == a)
        #expect(exists(first.choice.directory))
        if tryFirst {
            first.tryOnBar()
            #expect(store.configurationStore.themeTrialDirectory == first.choice.directory)
        }

        #expect(store.receive([b.link]) == .appearance)
        let second = try #require(store.pendingLinks.theme)
        defer { second.discard() }
        #expect(second.link == b)
        #expect(second.state == .ready)
        #expect(store.pendingLinks.themeError == nil)
        #expect(!exists(first.choice.directory))
        #expect(exists(second.choice.directory))
        #expect(store.configurationStore.themeTrialDirectory == nil)
    }

    @Test func aDamagedThemeLinkShowsWhyOnTheThemePage() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        let damaged = URL(string: "stablebar://theme?v=1&package=!!")!

        #expect(store.receive([damaged]) == .appearance)
        #expect(store.pendingLinks.theme == nil)
        #expect(store.pendingLinks.themeError == ThemeLinkError.damaged.errorDescription)

        #expect(store.receive([try linkedTheme().link]) == .appearance)
        #expect(store.pendingLinks.themeError == nil)
        let candidate = try #require(store.pendingLinks.theme)
        defer { candidate.discard() }
        candidate.tryOnBar()
        #expect(store.configurationStore.themeTrialDirectory == candidate.choice.directory)

        #expect(store.receive([damaged]) == .appearance)
        #expect(store.pendingLinks.theme == nil)
        #expect(store.pendingLinks.themeError == ThemeLinkError.damaged.errorDescription)
        #expect(!exists(candidate.choice.directory))
        #expect(store.configurationStore.themeTrialDirectory == nil)
    }

    @Test(arguments: [false, true])
    func stoppingTheStoreRemovesALinkedThemesFolder(tryFirst: Bool) throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        #expect(store.receive([try linkedTheme().link]) == .appearance)
        let candidate = try #require(store.pendingLinks.theme)
        defer { candidate.discard() }
        #expect(exists(candidate.choice.directory))
        if tryFirst {
            candidate.tryOnBar()
            #expect(store.configurationStore.themeTrialDirectory == candidate.choice.directory)
        }

        store.stop()
        #expect(!exists(candidate.choice.directory))
        #expect(store.configurationStore.themeTrialDirectory == nil)
        #expect(store.pendingLinks.theme == nil)
    }

    @Test(arguments: [false, true])
    func theLastRecognizedLinkInABatchChoosesItsPage(themeLast: Bool) throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        let theme = try linkedTheme().link
        let package = PackageLink(id: "clock", sourceID: nil)
        let links = themeLast ? [package.link, theme] : [theme, package.link]

        #expect(store.receive(links + [URL(string: "https://example.com")!]) == (themeLast ? .appearance : .packages))
        #expect((store.pendingLinks.theme != nil) == themeLast)
        #expect(store.pendingLinks.package == (themeLast ? nil : package))
    }

    @Test func anotherLinkCanArriveWhileThePreviousThemeIsBeingUsed() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        #expect(store.receive([try linkedTheme().link]) == .appearance)
        let previous = try #require(store.pendingLinks.theme)
        var replacement = try linkedTheme()
        replacement.configuration = Data(#"{"bar":{"height":42}}"#.utf8)
        let receive = Task { @MainActor in
            #expect(previous.state != .used)
            #expect(store.receive([replacement.link]) == .appearance)
        }

        await previous.use()
        await receive.value

        let current = try #require(store.pendingLinks.theme)
        #expect(current !== previous)
        #expect(current.link == replacement)
        #expect(current.state == .ready)
        #expect(exists(current.choice.directory))
        #expect(!exists(previous.choice.directory))
        #expect(store.configurationStore.selectedThemeKey == "built-in")
        #expect(store.customizationHistory.undoSteps.isEmpty)
    }

    @Test func aLinkedThemeIsTriedFromATemporaryFolderAndRemovedOnDiscard() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        let link = try linkedTheme()
        let candidate = try ThemeLinkCandidate(link: link, store: store)
        defer { candidate.discard() }
        let original = try Data(contentsOf: fixture.url)
        let selection = store.configurationStore.selectedThemeKey
        #expect(candidate.state == .ready)
        #expect(!candidate.choice.isBundled)
        #expect(candidate.choice.directory.lastPathComponent.hasPrefix("stablebar-theme-link-"))
        #expect(try Data(contentsOf: candidate.choice.directory.appending(path: "package.json")) == link.manifest)
        #expect(try Data(contentsOf: candidate.choice.directory.appending(path: "config.json")) == link.configuration)

        candidate.tryOnBar()
        #expect(candidate.state == .trying)
        #expect(store.configurationStore.themeTrialDirectory == candidate.choice.directory)
        #expect(store.configurationStore.selectedThemeKey == selection)
        #expect(store.configuration?.bar.height == 30)
        #expect(try Data(contentsOf: fixture.url) == original)
        #expect(store.customizationHistory.undoSteps.isEmpty)

        candidate.discard()
        candidate.discard()
        #expect(!exists(candidate.choice.directory))
        #expect(store.configurationStore.themeTrialDirectory == nil)
        candidate.tryOnBar()
        #expect(store.configurationStore.themeTrialDirectory == nil)
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
        #expect(store.configurationStore.themeTrialDirectory == nil)
        #expect(exists(candidate.choice.directory))
        candidate.tryOnBar()
        #expect(candidate.state == .trying)
        #expect(store.configurationStore.themeTrialDirectory == candidate.choice.directory)
    }

    @Test(arguments: [false, true])
    func endingOneCandidatesTrialKeepsAnotherCopyOfTheSameTheme(discard: Bool) throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        let first = try ThemeLinkCandidate(link: linkedTheme(), store: store)
        defer { first.discard() }
        let second = try ThemeLinkCandidate(link: linkedTheme(), store: store)
        defer { second.discard() }
        first.tryOnBar()
        second.tryOnBar()
        if discard { first.discard() } else { first.cancelTrial() }
        #expect(store.configurationStore.themeTrialDirectory == second.choice.directory)
        #expect(store.configuration?.bar.height == 30)
        #expect(exists(second.choice.directory))
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
        store.configurationStore.reloadConfiguration()
        #expect(store.configurationError == nil)
        #expect(candidate.state == .trying)
        #expect(store.configurationStore.themeTrialDirectory == candidate.choice.directory)
        #expect(store.configuration?.bar.height == 30)
        #expect(store.configuration?.bar.margin == 17)
        #expect(exists(candidate.choice.directory))
        candidate.cancelTrial()
        #expect(store.configuration?.bar.margin == 17)
        #expect(store.configurationStore.themeTrialDirectory == nil)
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
        store.onWindowRequest = { if case .endThemeTrial = $0 { trial.cancel() } }
        let candidate = try ThemeLinkCandidate(link: linkedTheme(), store: store)
        defer { candidate.discard() }
        candidate.tryOnBar()
        #expect(!trial.isActive)
        #expect(candidate.state == .trying)
        #expect(store.configurationStore.themeTrialDirectory == candidate.choice.directory)
    }

    @Test(arguments: [false, true])
    func usingALinkedThemeEndsTheOpenTryThemesPanel(installationFails: Bool) async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        let candidate = try ThemeLinkCandidate(link: linkedTheme(), store: store)
        defer { candidate.discard() }
        let trial = ThemeTrial(store: store)
        trial.next()
        store.onWindowRequest = { if case .endThemeTrial = $0 { trial.cancel() } }
        if installationFails { try fixture.write("not a directory", to: fixture.packages.directory) }
        await candidate.use()
        #expect(!trial.isActive)
        #expect(store.configurationStore.themeTrialDirectory == nil)
        if installationFails {
            guard case .failed = candidate.state else {
                Issue.record("Expected installation to fail")
                return
            }
        } else {
            #expect(candidate.state == .used)
            #expect(store.configurationStore.selectedThemeKey == "harbour-test/1.0.0")
        }
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
        #expect(store.configurationStore.selectedThemeKey == "built-in")
        #expect(store.configurationStore.themeTrialDirectory == nil)
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
        await candidate.use()
        let installed = try fixture.packages.directory(id: "harbour-test", version: "1.0.0")
        #expect(try Data(contentsOf: installed.appending(path: "config.json")) == candidate.link.configuration)
        #expect(try Data(contentsOf: installed.appending(path: "package.json")) == candidate.link.manifest)
        #expect(store.configurationStore.selectedThemeKey == "harbour-test/1.0.0")
        #expect(store.configurationError == nil)
        #expect(store.configurationStore.themeTrialDirectory == nil)
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
        await candidate.use()
        #expect(candidate.state == .used)
        #expect(store.configurationStore.selectedThemeKey == "harbour-test/1.0.0")
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
        let selection = store.configurationStore.selectedThemeKey
        let candidate = try ThemeLinkCandidate(link: linkedTheme(), store: store)
        defer { candidate.discard() }
        candidate.tryOnBar()
        await candidate.use()
        #expect(candidate.state == .failed(ThemeLinkError.versionTaken(id: "harbour-test", version: "1.0.0").errorDescription!))
        #expect(store.configurationStore.selectedThemeKey == selection)
        #expect(store.configurationStore.themeTrialDirectory == nil)
        #expect(store.customizationHistory.undoSteps.isEmpty)
    }

    @Test(arguments: ["1.0.0", "2", ".2", ".install-12345678-1234-1234-1234-123456789ABC"])
    func aWidgetInstalledAfterValidationIsRefusedAtUse(version: String) async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        let candidate = try ThemeLinkCandidate(link: linkedTheme(), store: store)
        defer { candidate.discard() }
        candidate.tryOnBar()
        let source = fixture.directory.appending(path: "widget")
        try fixture.write(#"{"id":"harbour-test","name":"Widget","version":"\#(version)","kind":"widgets","entry":"config.json"}"#,
                          to: source.appending(path: "package.json"))
        try fixture.write(#"{"widgets":[]}"#, to: source.appending(path: "config.json"))
        let installed = try fixture.packages.install(source)
        let manifest = try Data(contentsOf: installed.directory.appending(path: "package.json"))
        let configuration = try Data(contentsOf: installed.directory.appending(path: "config.json"))

        await candidate.use()
        #expect(candidate.state == .failed(ThemeLinkError.idTaken("harbour-test").errorDescription!))
        #expect(store.configurationStore.selectedThemeKey == "built-in")
        #expect(store.configurationStore.themeTrialDirectory == nil)
        #expect(store.customizationHistory.undoSteps.isEmpty)
        #expect(exists(candidate.choice.directory))
        #expect(try Data(contentsOf: installed.directory.appending(path: "package.json")) == manifest)
        #expect(try Data(contentsOf: installed.directory.appending(path: "config.json")) == configuration)
        if version != "1.0.0" {
            #expect(!exists(try fixture.packages.directory(id: "harbour-test", version: "1.0.0")))
        }
    }

    @Test func anInstalledVersionChangedAfterValidationIsRefused() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let installed = try fixture.packages.install(linkedThemeDirectory)
        let store = try loadedStore(fixture)
        defer { store.stop() }
        let candidate = try ThemeLinkCandidate(link: linkedTheme(), store: store)
        defer { candidate.discard() }
        candidate.tryOnBar()
        try fixture.write(#"{"bar":{"height":42}}"#, to: installed.directory.appending(path: "config.json"))

        await candidate.use()
        #expect(candidate.state == .failed(ThemeLinkError.versionTaken(id: "harbour-test", version: "1.0.0").errorDescription!))
        #expect(store.configurationStore.selectedThemeKey == "built-in")
        #expect(store.configurationStore.themeTrialDirectory == nil)
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
        await candidate.use(on: .monitor, everyBar: true)
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
        await candidate.use()
        guard case .failed = candidate.state else {
            Issue.record("Expected installation to fail")
            return
        }
        #expect(store.configurationStore.themeTrialDirectory == nil)
        #expect(store.configurationStore.selectedThemeKey == "built-in")
        #expect(store.customizationHistory.undoSteps.isEmpty)
    }

    @Test(arguments: [false, true], [false, true])
    func anInstallationErrorKeepsANewerTrial(tryFirst: Bool, linkedTrial: Bool) async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        let candidate = try ThemeLinkCandidate(link: linkedTheme(), store: store)
        defer { candidate.discard() }
        let newerCandidate = try ThemeLinkCandidate(link: linkedTheme(), store: store)
        defer { newerCandidate.discard() }
        let trial = ThemeTrial(store: store)
        defer { trial.cancel() }
        if tryFirst { candidate.tryOnBar() }
        try fixture.write("not a directory", to: fixture.packages.directory)
        let replacement = Task { @MainActor in
            #expect(candidate.state == (tryFirst ? .trying : .ready))
            if linkedTrial { newerCandidate.tryOnBar() } else { trial.next() }
            store.onWindowRequest = { if case .endThemeTrial = $0 { trial.cancel() } }
        }

        await candidate.use()
        await replacement.value

        guard case .failed = candidate.state else {
            Issue.record("Expected installation to fail")
            return
        }
        let directory = linkedTrial ? newerCandidate.choice.directory : trial.choice?.directory
        #expect(store.configurationStore.themeTrialDirectory == directory)
        #expect(trial.isActive)
        if linkedTrial { #expect(newerCandidate.state == .trying) }
        #expect(store.configurationStore.selectedThemeKey == "built-in")
        #expect(store.customizationHistory.undoSteps.isEmpty)
    }

    @Test func selectingAGalleryThemeEndsALinkedThemeTrial() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let selected = try fixture.theme(#"{"bar":{"height":42}}"#)
        let store = try loadedStore(fixture)
        defer { store.stop() }
        let gallery = ThemeGallery(store: store)
        let candidate = try ThemeLinkCandidate(link: linkedTheme(), store: store)
        defer { candidate.discard() }
        candidate.tryOnBar()
        #expect(candidate.state == .trying)
        #expect(store.configuration?.bar.height == 30)

        gallery.select(selected)

        #expect(gallery.errors[selected.key] == nil)
        #expect(store.configurationStore.selectedThemeKey == selected.key)
        #expect(try fixture.document()["theme"] == .object(selected.selection))
        #expect(store.configurationStore.themeTrialDirectory == nil)
        #expect(candidate.state == .ready)
        #expect(store.configuration?.bar.height == 42)
        #expect(store.customizationHistory.undoSteps.count == 1)
    }

    @Test(arguments: ["2", ".2"], ["theme", "widgets"])
    func aPackageIDWithDifferentCaseFollowsTheFilesystem(version: String, kind: String) throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        let source = fixture.directory.appending(path: "widget")
        try fixture.write(#"{"id":"harbour-test","name":"Package","version":"\#(version)","kind":"\#(kind)","entry":"config.json"}"#,
                          to: source.appending(path: "package.json"))
        try fixture.write("{}", to: source.appending(path: "config.json"))
        _ = try fixture.packages.install(source)
        let staging = fixture.packages.directory.appending(path: "harbour-test/.install-\(UUID().uuidString)")
        try fixture.write("partial configuration", to: staging.appending(path: "config.json"))
        var link = try linkedTheme()
        var manifest = try JSONDecoder().decode([String: ConfigurationValue].self, from: link.manifest)
        manifest["id"] = .string("Harbour-Test")
        link.manifest = try configurationData(manifest)
        let before = try temporaryFolders()
        if exists(fixture.packages.directory.appending(path: "Harbour-Test")) {
            let error = #expect(throws: ThemeLinkError.idTaken("Harbour-Test")) {
                let candidate = try ThemeLinkCandidate(link: link, store: store)
                candidate.discard()
            }
            #expect(error?.errorDescription == "Another package already uses the ID Harbour-Test. Rename the theme on the page.")
        } else {
            let candidate = try ThemeLinkCandidate(link: link, store: store)
            candidate.discard()
        }
        #expect(try temporaryFolders() == before)
    }

    @Test(arguments: [false, true])
    func anUnfinishedInstallIsNotAnInstalledVersion(installedTheme: Bool) async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        if installedTheme { _ = try fixture.packages.install(linkedThemeDirectory) }
        let staging = fixture.packages.directory.appending(path: "harbour-test/.install-\(UUID().uuidString)")
        try fixture.write("partial configuration", to: staging.appending(path: "config.json"))
        let candidate = try ThemeLinkCandidate(link: linkedTheme(), store: store)
        defer { candidate.discard() }
        #expect(candidate.state == .ready)

        await candidate.use()
        #expect(candidate.state == .used)
        #expect(store.configurationStore.selectedThemeKey == "harbour-test/1.0.0")
        #expect(exists(staging))
        #expect(!exists(candidate.choice.directory))
    }

    @Test(arguments: [false, true], ["2", ".2", ".install-not-a-uuid", ".install-12345678-1234-1234-1234-123456789ABC"])
    func everyVersionUnderTheIDMustBeAThemeWithThatID(brokenManifest: Bool, version: String) throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        _ = try fixture.packages.install(linkedThemeDirectory)
        let directory = try fixture.packages.directory(id: "harbour-test", version: version)
        let manifest = brokenManifest ? "broken" : #"{"id":"other-theme","name":"Theme","version":"\#(version)","kind":"theme","entry":"config.json"}"#
        try fixture.write(manifest, to: directory.appending(path: "package.json"))
        #expect(throws: ThemeLinkError.idTaken("harbour-test")) {
            let candidate = try ThemeLinkCandidate(link: linkedTheme(), store: store)
            candidate.discard()
        }
    }

    @Test func anUnrelatedBrokenPackageDoesNotBlockALinkedTheme() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        try fixture.write("broken", to: fixture.packages.directory.appending(path: "unrelated/1/package.json"))
        let candidate = try ThemeLinkCandidate(link: linkedTheme(), store: store)
        defer { candidate.discard() }
        #expect(candidate.state == .ready)
    }

    @Test func packageChecksAndInstallationUseTheStoresClient() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        let packages = WidgetPackageStore(directory: fixture.directory.appending(path: "client-packages"))
        store.packageStoreClient = PackageStoreClient(packages: packages, indexURL: fixture.directory.appending(path: "index.json"))
        let version = try packages.directory(id: "harbour-test", version: "1.0.0")
        try fixture.write(#"{"id":"harbour-test","name":"Widget","version":"1.0.0","kind":"widgets","entry":"config.json"}"#,
                          to: version.appending(path: "package.json"))
        #expect(throws: ThemeLinkError.idTaken("harbour-test")) {
            let candidate = try ThemeLinkCandidate(link: linkedTheme(), store: store)
            candidate.discard()
        }
        try linkedTheme().manifest.write(to: version.appending(path: "package.json"))
        try fixture.write(#"{"bar":{"height":42}}"#, to: version.appending(path: "config.json"))
        let candidate = try ThemeLinkCandidate(link: linkedTheme(), store: store)
        defer { candidate.discard() }
        await candidate.use()
        #expect(candidate.state == .failed(ThemeLinkError.versionTaken(id: "harbour-test", version: "1.0.0").errorDescription!))
        #expect(store.configurationStore.selectedThemeKey == "built-in")
        #expect(!exists(fixture.packages.directory))

        try FileManager.default.removeItem(at: version)
        await candidate.use()
        #expect(!exists(fixture.packages.directory))
        try #require(exists(version.appending(path: "config.json")))
        #expect(try Data(contentsOf: version.appending(path: "config.json")) == candidate.link.configuration)
        #expect(try Data(contentsOf: version.appending(path: "package.json")) == candidate.link.manifest)
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
            configuration["bar"] = .object(["hideMenuBar": .bool(true)])
        case .missingKind: manifest["kind"] = nil
        case .bundledID: manifest["id"] = .string("nord")
        case .legacyID: manifest["id"] = .string("slate")
        case .classicID: manifest["id"] = .string("classic")
        case .widgetID:
            let source = fixture.directory.appending(path: "widget")
            try fixture.write(#"{"id":"harbour-test","name":"Widget","version":"2","kind":"widgets","entry":"config.json"}"#,
                              to: source.appending(path: "package.json"))
            try fixture.write(#"{"widgets":[]}"#, to: source.appending(path: "config.json"))
            _ = try fixture.packages.install(source)
        case .doublingTokens:
            configuration["tokens"] = .object(doublingTokens(levels: 17, value: .string("#123456")))
            configuration["bar"] = .object(["style": .object(["background": .string("@token.t17")])])
        case .profileExpansion, .nestedProfileExpansion:
            let colors = ConfigurationValue.array(Array(repeating: .string("#123456"), count: 100))
            let row = ConfigurationValue.array(Array(repeating: .string("@token.colors"), count: 10))
            configuration["tokens"] = .object(["colors": colors, "row": row])
            let rows = Array(repeating: ConfigurationValue.string("@token.row"), count: 100)
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
        case .combinedProfileBar:
            configuration["tokens"] = .object(["b": .object(["height": .number(30)])])
            let dark: ConfigurationValue = .object([
                "name": .string("Dark"), "when": .object(["appearance": .string("dark")]),
                "configuration": .object(["tokens": .object(["b": .object(["hideMenuBar": .bool(true)])])])
            ])
            configuration["profiles"] = .array([dark, profile(["bar": .string("@token.b")])])
        case .settingChoiceBar:
            manifest["settings"] = .object(["look": .object([
                "type": .string("string"), "default": .string("@token.safe"),
                "choices": .array([.string("@token.safe"), .string("@token.evil")])
            ])])
            configuration["tokens"] = .object([
                "safe": .object(["height": .number(30)]), "evil": .object(["hideMenuBar": .bool(true)])
            ])
            configuration["bar"] = .string("@setting.look")
        case .nestedProfileBar:
            configuration["tokens"] = .object(["safe": .object(["height": .number(30)])])
            let nested = profile(["bar": .string("@token.safe")], name: "Nested")
            configuration["profiles"] = .array([profile(["profiles": .array([nested])])])
        case .nullBar: configuration["bar"] = .null
        case .arrayBar: configuration["bar"] = .array([])
        case .malformedProfiles: configuration["profiles"] = .array([.object(["name": .number(1)])])
        case .outOfRangeNumber:
            configuration["profiles"] = .array([.object([
                "name": .string("Count"), "when": .object(["displayCount": .number(1e100)])
            ])])
        case .malformedManifest: manifest["id"] = .number(1)
        case .referenceDepth:
            var tokens: [String: ConfigurationValue] = ["t0": .number(1)]
            for level in 1...66 { tokens["t\(level)"] = .string("@token.t\(level - 1)") }
            configuration["tokens"] = .object(tokens)
        case .referenceOrigins:
            var tokens: [String: ConfigurationValue] = ["t0": .string("#123456")]
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
        case .tooLarge, .tooDeep, .tooManyProfiles, .tooManyNestedProfiles, .notUTF8, .notAnObject: break
        }
        link.manifest = try configurationData(manifest)
        link.configuration = try configurationData(configuration)
        switch rejection {
        case .tooLarge: link.configuration = Data((#"{"tokens":{"large":""# + String(repeating: "x", count: ThemeLink.maximumFileBytes) + #""}}"#).utf8)
        case .tooDeep: link.configuration = Data((#"{"tokens":{"deep":"# + String(repeating: "[", count: 500) + "0" + String(repeating: "]", count: 500) + "}}").utf8)
        case .tooManyProfiles: link.configuration = try configurationData(["profiles": .array((0..<17).map { profile([:], name: "p\($0)") })])
        case .tooManyNestedProfiles:
            let first = (0..<7).map { profile([:], name: "a\($0)") }
            let second = (0..<8).map { profile([:], name: "b\($0)") }
            link.configuration = try configurationData(["profiles": .array([
                profile(["profiles": .array(first)], name: "First"), profile(["profiles": .array(second)], name: "Second")
            ])])
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
        case .bar: #expect(error as? ThemeLinkError == .barProperty("hideMenuBar"))
        case .tokenBar, .overriddenTokenBar, .settingBar, .combinedProfileBar, .settingChoiceBar, .nestedProfileBar, .nullBar, .arrayBar:
            #expect(error as? ThemeLinkError == .indirectBar)
        case .profileBar: #expect(error as? ThemeLinkError == .barProperty("position"))
        case .hosts, .permissions, .tools, .secrets: #expect(error as? ThemeLinkError == .needsReview)
        case .screenshot, .includes, .profileIncludes: #expect(error as? ThemeLinkError == .extraFiles)
        case .widgets, .missingKind: #expect(error as? ThemeLinkError == .notATheme)
        case .bundledID: #expect(error as? ThemeLinkError == .reservedID("nord"))
        case .legacyID: #expect(error as? ThemeLinkError == .reservedID("slate"))
        case .classicID: #expect(error as? ThemeLinkError == .reservedID("classic"))
        case .widgetID: #expect(error as? ThemeLinkError == .idTaken("harbour-test"))
        case .tooLarge: #expect(error as? ThemeLinkError == .tooLarge)
        case .tooDeep: #expect(error as? ThemeLinkError == .tooDeep)
        case .tooManyProfiles, .tooManyNestedProfiles: #expect(error as? ThemeLinkError == .tooManyProfiles)
        case .notUTF8, .notAnObject, .malformedProfiles, .outOfRangeNumber, .malformedManifest:
            #expect(error as? ThemeLinkError == .damaged)
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
            guard case .referenceExpansionTooLarge? = error as? ThemeConfigurationError else {
                Issue.record("Expected long-key expansion limit, got \(String(describing: error))")
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
        {"tokens":{"base":"#123456"},"defaults":{"fontSize":"@setting.size"},
         "bar":{"height":19,"style":{"background":"@token.base"}},"profiles":[
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
        #expect(store.configuration?.bar.height == 19)
        await candidate.use()
        #expect(candidate.state == .used)
    }

    @Test func individuallyBoundedProfilesShareOneCandidatesExpansionBudget() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        var link = try linkedTheme()
        let tokens: [String: ConfigurationValue] = [
            "c": .array(Array(repeating: .number(1), count: 100)),
            "r": .array(Array(repeating: .string("@token.c"), count: 100))
        ]
        let profiles = (0..<16).map { index in
            profile(["tokens": .object(["p": .string("@token.r")])], name: "p\(index)", enabled: false)
        }
        link.configuration = try configurationData(["tokens": .object(tokens), "profiles": .array(profiles)])
        let source = fixture.directory.appending(path: "source")
        try fixture.write(String(decoding: link.manifest, as: UTF8.self), to: source.appending(path: "package.json"))
        try fixture.write(String(decoding: link.configuration, as: UTF8.self), to: source.appending(path: "config.json"))
        var loader = ConfigurationLoader()
        let layer = try loader.readPackage(at: source, manifest: fixture.packages.manifest(at: source), settings: [:])
        loader.previewProfile = "p0"
        let expanded = try loader.finish(layer, context: ConfigurationContext())
        let expandedTokens = try expanded["tokens"]?.decoded([String: ConfigurationValue].self)
        let row = ConfigurationValue.array(Array(repeating: .number(1), count: 100))
        #expect(expandedTokens?["p"] == .array(Array(repeating: row, count: 100)))

        let before = try temporaryFolders()
        let error = #expect(throws: (any Error).self) {
            let candidate = try ThemeLinkCandidate(link: link, store: store)
            candidate.discard()
        }
        #expect(error as? ThemeLinkError == .tooManyReferences)
        #expect(try temporaryFolders() == before)
    }

    @Test func bundledThemesAndTheSharedFixtureFitALinkCandidatesBudget() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        let bundled = try FileManager.default.contentsOfDirectory(at: fixture.themes, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var largestConfiguration = 0
        for directory in [linkedThemeDirectory] + bundled {
            var manifest = try JSONDecoder().decode([String: ConfigurationValue].self,
                                                   from: Data(contentsOf: directory.appending(path: "package.json")))
            manifest["id"] = .string("linked-\(directory.lastPathComponent)")
            let link = ThemeLink(manifest: try configurationData(manifest),
                                 configuration: try Data(contentsOf: directory.appending(path: "config.json")))
            largestConfiguration = max(largestConfiguration, try valueCount(link.configuration))
            #expect(try ThemeLink(url: link.link) == link)
            let candidate = try ThemeLinkCandidate(link: link, store: store)
            defer { candidate.discard() }
            #expect(candidate.state == .ready, "\(directory.lastPathComponent)")
            #expect(candidate.validationExpansionUnits < 300_000)
            #expect(candidate.validationOriginPathBytes < 8_000_000)
        }
        #expect(ThemeLink.maximumValues >= 2 * largestConfiguration)
    }

    @Test func longKeyOriginsShareOneAllowanceAcrossDisabledProfiles() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        let link = try longKeyLink(profileCount: 16)
        #expect(link.manifest.count + link.configuration.count == ThemeLink.maximumFileBytes - 16)
        let before = try temporaryFolders()
        let error = #expect(throws: (any Error).self) {
            let candidate = try ThemeLinkCandidate(link: link, store: store)
            candidate.discard()
        }
        #expect(error as? ThemeLinkError == .tooManyReferences)
        #expect(try temporaryFolders() == before)
    }

    @Test(arguments: [0, 24])
    func literalValuesAtTheLinkCapCanBeTriedAndUsed(nesting: Int) async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        var link = try linkedTheme()
        func configuration(numbers: Int) throws -> Data {
            var values = ConfigurationValue.array(Array(repeating: .number(1), count: numbers))
            for _ in 0..<nesting { values = .array([values]) }
            let first = profile(["tokens": .object(["x": values])], name: "p0", enabled: false)
            let empty = (1..<16).map { ConfigurationValue.object(["name": .string("p\($0)"), "enabled": .bool(false)]) }
            return try JSONEncoder().encode(ConfigurationValue.object(["profiles": .array([first] + empty)]))
        }
        let overhead = try valueCount(link.manifest) + valueCount(configuration(numbers: 0))
        let numbers = ThemeLink.maximumValues - overhead
        #expect(numbers > 0)
        link.configuration = try configuration(numbers: numbers)
        #expect(try valueCount(link.manifest) + valueCount(link.configuration) == ThemeLink.maximumValues)
        let candidate = try ThemeLinkCandidate(link: link, store: store)
        defer { candidate.discard() }
        candidate.tryOnBar()
        #expect(candidate.state == .trying)
        await candidate.use()
        #expect(candidate.state == .used)

        link.configuration = try configuration(numbers: numbers + 1)
        let before = try temporaryFolders()
        #expect(throws: ThemeLinkError.tooManySettings) { try ThemeLinkCandidate(link: link, store: store) }
        #expect(try temporaryFolders() == before)
    }

    @Test(arguments: [false, true])
    func trialAndInstallationHaveTheirOwnOriginAllowances(install: Bool) async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        let candidate = try ThemeLinkCandidate(link: longKeyLink(profileCount: 0), store: store)
        defer { candidate.discard() }
        #expect(candidate.validationOriginPathBytes > 4_000_000)
        let initial = candidate.validationOriginPathBytes
        if install { await candidate.use() } else { candidate.tryOnBar() }
        #expect(candidate.validationOriginPathBytes == initial)
        #expect(candidate.state == (install ? .used : .trying))
        #expect(store.configurationStore.selectedThemeKey == (install ? candidate.choice.key : "built-in"))
        #expect(store.configurationStore.themeTrialDirectory == (install ? nil : candidate.choice.directory))
        #expect(store.customizationHistory.undoSteps.count == (install ? 1 : 0))
        #expect(exists(try fixture.packages.directory(id: "harbour-test", version: "1.0.0")) == install)
    }

    @Test func nestedProfilesShareTheBudgetWithInspectionAndOtherReferenceChecks() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        var link = try linkedTheme()
        let tokens: [String: ConfigurationValue] = [
            "seed": .array(Array(repeating: .number(1), count: 90)),
            "c": .array(Array(repeating: .string("@token.seed"), count: 3)),
            "r": .array(Array(repeating: .string("@token.c"), count: 10))
        ]
        let references = ConfigurationValue.array(Array(repeating: .string("@token.r"), count: 10))
        let nested = (0..<15).map { index in
            profile(["tokens": .object(["p": references])], name: "p\(index)", enabled: false)
        }
        link.configuration = try JSONEncoder().encode(ConfigurationValue.object([
            "tokens": .object(tokens),
            "profiles": .array([profile(["profiles": .array(nested)], enabled: false)])
        ]))
        #expect(link.manifest.count + link.configuration.count <= ThemeLink.maximumFileBytes)
        let before = try temporaryFolders()
        let error = #expect(throws: (any Error).self) {
            let candidate = try ThemeLinkCandidate(link: link, store: store)
            candidate.discard()
        }
        #expect(error as? ThemeLinkError == .tooManyReferences)
        #expect(try temporaryFolders() == before)
    }

    @Test(arguments: [194, 195])
    func aCandidatesBudgetSpansInspectionAndItsFinalReferenceCheck(referenceCount: Int) async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        var link = try linkedTheme()
        link.configuration = try configurationData(["tokens": .object([
            "seed": .array(Array(repeating: .number(1), count: 100)),
            "c": .array(Array(repeating: .string("@token.seed"), count: 3)),
            "r": .array(Array(repeating: .string("@token.c"), count: referenceCount))
        ])])
        let before = try temporaryFolders()
        if referenceCount == 194 {
            let candidate = try ThemeLinkCandidate(link: link, store: store)
            #expect(candidate.state == .ready)
            #expect(candidate.validationExpansionUnits == 299_305)
            candidate.tryOnBar()
            #expect(candidate.state == .trying)
            await candidate.use()
            #expect(candidate.state == .used)
            candidate.discard()
            #expect(!exists(candidate.choice.directory))
        } else {
            let error = #expect(throws: (any Error).self) {
                let candidate = try ThemeLinkCandidate(link: link, store: store)
                candidate.discard()
            }
            #expect(error as? ThemeLinkError == .tooManyReferences)
            #expect(try temporaryFolders() == before)
        }
    }

    @Test(arguments: [
        ("height", 16.0, 100.0), ("inset", 0, 100), ("spacing", 0, 50), ("margin", 0, 40),
        ("style.borderWidth", 0, 6), ("style.cornerRadius", 0, 40), ("style.fontSize", 6, 40),
        ("style.paddingHorizontal", 0, 40), ("style.paddingVertical", 0, 40),
        ("notchWidth", 0, 1_000), ("notchSpacing", 0, 100),
        ("style.states.hover.borderWidth", 0, 6), ("style.offsetY", -1_000, 1_000),
        ("style.height", 0, 1_000), ("style.spacing", 0, 1_000),
        ("style.paddingLeading", 0, 1_000), ("style.paddingTrailing", 0, 1_000),
        ("style.paddingTop", 0, 1_000), ("style.paddingBottom", 0, 1_000),
        ("style.states.hover.height", 0, 1_000), ("style.states.height.spacing", 0, 1_000),
        ("style.states.hover.states.active.fontSize", 6, 40), ("style.opacity", 0, 1),
        ("glass.transparency", 0, 1), ("divider.width", 0, 6), ("divider.height", 0, 100),
        ("divider.cornerRadius", 0, 40), ("divider.opacity", 0, 1)
    ], [false, true])
    func barNumbersStayWithinTheirSettingsRanges(
        range: (String, Double, Double), inProfile: Bool
    ) throws {
        let (path, lower, upper) = range
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        for number in [lower - 1, lower, upper, upper + 1] {
            let value = barValue(.number(number), at: path)
            var document: [String: ConfigurationValue] = ["bar": value]
            if inProfile { document = ["profiles": .array([profile(document, enabled: false)])] }
            var link = try linkedTheme()
            link.configuration = try configurationData(document)
            if (lower...upper).contains(number) {
                let candidate = try ThemeLinkCandidate(link: link, store: store)
                candidate.discard()
            } else {
                let error = #expect(throws: (any Error).self) {
                    let candidate = try ThemeLinkCandidate(link: link, store: store)
                    candidate.discard()
                }
                #expect(error as? ThemeLinkError == .barValue(path))
            }
        }
    }

    @Test(arguments: ["NaN", "Infinity", "-Infinity", "1e400", "-1e400"], [false, true])
    func nonFiniteBarNumbersAreRefused(number: String, inProfile: Bool) throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        var link = try linkedTheme()
        var document = #"{"bar":{"height":\#(number)}}"#
        if inProfile { document = #"{"profiles":[{"name":"Unsafe","configuration":\#(document)}]}"# }
        link.configuration = Data(document.utf8)
        #expect(throws: (any Error).self) {
            let candidate = try ThemeLinkCandidate(link: link, store: store)
            candidate.discard()
        }
    }

    @Test(arguments: [false, true])
    func numericBarSettingsMustBeLiterals(inProfile: Bool) throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        for height in [30.0, 4_000] {
            var link = try linkedTheme()
            var manifest = try JSONDecoder().decode([String: ConfigurationValue].self, from: link.manifest)
            manifest["settings"] = .object(["size": .object(["type": .string("number"), "default": .number(height)])])
            link.manifest = try configurationData(manifest)
            var document: [String: ConfigurationValue] = ["bar": .object(["height": .string("@setting.size")])]
            if inProfile { document = ["profiles": .array([profile(document, enabled: false)])] }
            link.configuration = try configurationData(document)
            #expect(throws: ThemeLinkError.indirectBar) {
                let candidate = try ThemeLinkCandidate(link: link, store: store)
                candidate.discard()
            }
        }
    }

    @Test(arguments: [
        "height", "style.fontSize", "style.states.hover.height", "style",
        "style.states", "style.states.hover", "background", "style.background",
        "style.states.hover.background.gradient.angle",
        "style.states.hover.background.gradient.locations"
    ], [false, true])
    func numericBarTokensMustBeLiterals(path: String, inProfile: Bool) throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        let value: ConfigurationValue
        switch path {
        case "style": value = .object(["fontSize": .number(12)])
        case "style.states": value = .object(["hover": .object(["fontSize": .number(12)])])
        case "style.states.hover": value = .object(["fontSize": .number(12)])
        case "background", "style.background": value = barValue(.number(90), at: "gradient.angle")
        case "style.states.hover.background.gradient.locations":
            value = .array([.number(0), .number(1)])
        default: value = .number(path == "height" ? 30 : 12)
        }
        let bar = barValue(.string("@token.value"), at: path)
        var document: [String: ConfigurationValue] = ["bar": bar]
        if inProfile { document = ["profiles": .array([profile(document, enabled: false)])] }
        document["tokens"] = .object(["value": value])
        var link = try linkedTheme()
        link.configuration = try configurationData(document)
        #expect(throws: ThemeLinkError.indirectBar) {
            let candidate = try ThemeLinkCandidate(link: link, store: store)
            candidate.discard()
        }
    }

    @Test(arguments: [false, true])
    func combinedProfilesCannotSupplyNumericBarValues(firstIsUnconditional: Bool) throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        let firstWhen = firstIsUnconditional ? "" : #","when":{"appearance":"dark"}"#
        var link = try linkedTheme()
        link.configuration = Data(#"""
        {"tokens":{"h":30},"profiles":[
          {"name":"A"\#(firstWhen),"configuration":{"bar":{"height":"@token.h"}}},
          {"name":"B","when":{"appearance":"dark"},"configuration":{"tokens":{"h":4000}}}
        ]}
        """#.utf8)
        #expect(throws: ThemeLinkError.indirectBar) {
            let candidate = try ThemeLinkCandidate(link: link, store: store)
            candidate.discard()
        }
    }

    @Test(arguments: ["height", "style", "style.background"], [
        (false, false), (false, true), (true, false), (true, true)
    ])
    func settingChoicesCannotSupplyNumericBarValues(
        path: String, placement: (Bool, Bool)
    ) throws {
        let (inProfile, freeString) = placement
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        var link = try linkedTheme()
        var manifest = try JSONDecoder().decode(
            [String: ConfigurationValue].self, from: link.manifest)
        var setting: [String: ConfigurationValue] = [
            "type": .string("string"), "default": .string("@token.small")
        ]
        if !freeString {
            setting["choices"] = .array([.string("@token.small"), .string("@token.big")])
        }
        manifest["settings"] = .object(["size": .object(setting)])
        link.manifest = try configurationData(manifest)
        let small: ConfigurationValue
        let big: ConfigurationValue
        switch path {
        case "height":
            small = .number(30)
            big = .number(4_000)
        case "style":
            small = .object(["foreground": .string("#123456")])
            big = .object(["height": .number(4_000)])
        default:
            small = .string("#123456")
            big = barValue(.number(4_000), at: "gradient.angle")
        }
        var document: [String: ConfigurationValue] = [
            "bar": barValue(.string("@setting.size"), at: path)
        ]
        if inProfile { document = ["profiles": .array([profile(document, enabled: false)])] }
        document["tokens"] = .object(["small": small, "big": big])
        link.configuration = try configurationData(document)
        #expect(throws: ThemeLinkError.indirectBar) {
            let candidate = try ThemeLinkCandidate(link: link, store: store)
            candidate.discard()
        }
    }

    @Test func legacyCustomizationCannotUseSettingChoicesForBarNumbers() throws {
        var link = try linkedTheme()
        var manifest = try JSONDecoder().decode(
            [String: ConfigurationValue].self, from: link.manifest)
        manifest["settings"] = .object(["size": .object([
            "type": .string("string"), "default": .string("@token.small"),
            "choices": .array([.string("@token.small"), .string("@token.big")])
        ])])
        link.manifest = try configurationData(manifest)
        link.configuration = Data(#"""
        {"customization":{"bar":{"height":"@setting.size"}},"tokens":{"small":30,"big":4000}}
        """#.utf8)
        try expectThemeKeyRefusal("customization", in: link)
    }

    @Test func legacyCustomizationCannotUseNumberSettingsForBarNumbers() throws {
        var link = try linkedTheme()
        var manifest = try JSONDecoder().decode(
            [String: ConfigurationValue].self, from: link.manifest)
        manifest["settings"] = .object(["size": .object([
            "type": .string("number"), "default": .number(30)
        ])])
        link.manifest = try configurationData(manifest)
        link.configuration = Data(#"{"customization":{"bar":{"height":"@setting.size"}}}"#.utf8)
        try expectThemeKeyRefusal("customization", in: link)
    }

    @Test func legacyCustomizationCannotUseCombinedProfilesForBarNumbers() throws {
        var link = try linkedTheme()
        link.configuration = Data(#"""
        {"customization":{"bar":{"height":"@token.h"}},"tokens":{"h":"@token.x","x":30},
         "profiles":[
          {"name":"A","when":{"appearance":"dark"},"configuration":{
            "tokens":{"h":"@token.y","y":30}}},
          {"name":"B","when":{"appearance":"dark"},"configuration":{"tokens":{"y":4000}}}
        ]}
        """#.utf8)
        try expectThemeKeyRefusal("customization", in: link)
    }

    @Test(arguments: ["customization", "removedWidgets"], [false, true])
    func legacyRootKeysAreRefusedBeforeProfileDecoding(
        key: String, malformedProfiles: Bool
    ) throws {
        var link = try linkedTheme()
        var document: [String: ConfigurationValue] = [
            key: key == "customization" ? .object([:]) : .array([])
        ]
        if malformedProfiles {
            document["profiles"] = .array([.object(["name": .number(1)])])
        }
        link.configuration = try configurationData(document)
        try expectThemeKeyRefusal(key, in: link)
    }

    @Test(arguments: ["@setting.color", "@token.alias"], [
        (false, false), (false, true), (true, false), (true, true)
    ])
    func barColorsCannotUseFreeTextSettings(reference: String, placement: (Bool, Bool)) throws {
        let (inProfile, hasNumericToken) = placement
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        var link = try linkedTheme()
        var manifest = try JSONDecoder().decode(
            [String: ConfigurationValue].self, from: link.manifest)
        manifest["settings"] = .object(["color": .object([
            "type": .string("string"), "default": .string("#123456")
        ])])
        link.manifest = try configurationData(manifest)
        var document: [String: ConfigurationValue] = [
            "bar": barValue(.string(reference), at: "style.background")
        ]
        if inProfile { document = ["profiles": .array([profile(document, enabled: false)])] }
        var tokens: [String: ConfigurationValue] = ["alias": .string("@setting.color")]
        if hasNumericToken { tokens["size"] = .number(30) }
        document["tokens"] = .object(tokens)
        link.configuration = try configurationData(document)
        #expect(throws: ThemeLinkError.indirectBar) {
            let candidate = try ThemeLinkCandidate(link: link, store: store)
            candidate.discard()
        }
    }

    @Test(arguments: [false, true], [false, true])
    func barStyleColorsMayStillUseReferences(inProfile: Bool, settingChoices: Bool) throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        var link = try linkedTheme()
        if settingChoices {
            var manifest = try JSONDecoder().decode(
                [String: ConfigurationValue].self, from: link.manifest)
            manifest["settings"] = .object(["color": .object([
                "type": .string("string"), "default": .string("@token.color"),
                "choices": .array([.string("@token.color"), .string("#654321")])
            ])])
            link.manifest = try configurationData(manifest)
        }
        let reference = settingChoices ? "@setting.color" : "@token.color"
        var document: [String: ConfigurationValue] = [
            "bar": barValue(.string(reference), at: "style.states.hover.foreground")
        ]
        if inProfile { document = ["profiles": .array([profile(document)])] }
        document["tokens"] = .object(["color": .string("#123456"), "size": .number(30)])
        link.configuration = try configurationData(document)
        let candidate = try ThemeLinkCandidate(link: link, store: store)
        defer { candidate.discard() }
        candidate.tryOnBar()
        #expect(candidate.state == .trying)
        #expect(store.configuration?.bar.style.states?["hover"]?.foreground == HexColor(0x123456ff))
    }

    @Test func combinedProfilesCannotHideNumbersInsideColorReferences() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        var link = try linkedTheme()
        link.configuration = Data(##"""
        {"tokens":{"color":"#123456","alias":"@token.color"},"profiles":[
          {"name":"A","when":{"appearance":"dark"},"configuration":{
            "bar":{"style":{"background":"@token.alias"}}}},
          {"name":"B","when":{"appearance":"dark"},"configuration":{"tokens":{
            "color":{"gradient":{"colors":["#000000","#ffffff"],"angle":4000}}}}}
        ]}
        """##.utf8)
        #expect(throws: ThemeLinkError.indirectBar) {
            let candidate = try ThemeLinkCandidate(link: link, store: store)
            candidate.discard()
        }
    }

    @Test(arguments: [false, true])
    func aProfileCannotHideAnOversizedBarValue(token: Bool) throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        var link = try linkedTheme()
        link.configuration = try configurationData([
            "tokens": .object(["size": .number(4_000)]),
            "bar": .object(["height": token ? .string("@token.size") : .number(4_000)]),
            "profiles": .array([profile(["bar": .object(["height": .number(30)])])])
        ])
        #expect(throws: token ? ThemeLinkError.indirectBar : .barValue("height")) {
            let candidate = try ThemeLinkCandidate(link: link, store: store)
            candidate.discard()
        }
    }

    @Test(arguments: [false, true], [
        "background", "style.background", "style.hoverBackground", "style.states.hover.background"
    ])
    func gradientNumbersAreBoundedInsideBarValues(inProfile: Bool, path: String) throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        for key in ["angle", "locations"] {
            for invalid in [false, true] {
                var gradient: [String: ConfigurationValue] = [
                    "colors": .array([.string("#000000"), .string("#ffffff")]),
                    "angle": .number(360), "locations": .array([.number(0), .number(1)])
                ]
                if invalid { gradient[key] = key == "angle" ? .number(361) : .array([.number(0), .number(1.1)]) }
                let bar = barValue(.object(["gradient": .object(gradient)]), at: path)
                var document: [String: ConfigurationValue] = ["bar": bar]
                if inProfile { document = ["profiles": .array([profile(document, enabled: false)])] }
                var link = try linkedTheme()
                link.configuration = try configurationData(document)
                if invalid {
                    #expect(throws: ThemeLinkError.barValue("\(path).gradient.\(key)")) {
                        let candidate = try ThemeLinkCandidate(link: link, store: store)
                        candidate.discard()
                    }
                } else {
                    let candidate = try ThemeLinkCandidate(link: link, store: store)
                    candidate.discard()
                }
            }
        }
    }

    @Test func sharingABarCarriesItsResolvedLookAndBuiltInAndStoreWidgetsOnly() throws {
        let fixture = try ThemeGalleryFixture(#"""
            {"theme":{"id":"catppuccin"},
             "tokens":{"accent":"#ff0000","barTint":"#123456","myBlue":"#0000ff","apiKey":"secret"},
             "bar":{"height":30,"background":"@token.barTint","position":"bottom"},
             "profiles":[{"name":"Work","configuration":{"defaults":{"cornerRadius":4}}}],
             "packages":[{"id":"weather","version":"1.0.0","settings":{"units":"imperial","interval":300,"city":"Bern"}},
                         {"id":"notes","version":"1.0.0"},{"id":"team","version":"1.0.0"}],
             "groups":{"status":{}},"widgetOverrides":{"weather":{"group":"status"}},
             "providers":{"speakers":{"type":"audio"}},
             "widgets":[
               {"id":"clock","type":"clock","position":"right","onClick":"open -a Calendar","style":{"foreground":"@token.myBlue"}},
               {"id":"note","type":"script","position":"left","command":"echo hi"},
               {"id":"volume","type":"provider","provider":"speakers","position":"right"},
               {"id":"laptop","type":"text","text":"x","position":"left","display":"builtIn"}
             ]}
            """#)
        defer { fixture.close() }
        let settings = #"""
            {"units":{"type":"string","title":"Units","choices":["metric","imperial"],"default":"metric"},
             "interval":{"type":"number","title":"Refresh every (seconds)","default":900},
             "city":{"type":"string","title":"City","default":"Zurich"},"apiKey":{"type":"secret","title":"API key"}}
            """#
        for (id, record) in [("weather", PackageInstallRecord(.store)), ("notes", .local),
                             ("team", PackageInstallRecord(source: "team", name: "Team", url: URL(string: "https://team.example/index.json")))] {
            let source = fixture.directory.appending(path: "sources/\(id)")
            try fixture.write(#"{"id":"\#(id)","name":"\#(id.capitalized)","version":"1.0.0","kind":"widgets","entry":"config.json","settings":\#(id == "weather" ? settings : "{}")}"#,
                              to: source.appending(path: "package.json"))
            try fixture.write(#"{"widgets":[{"id":"\#(id)","type":"text","text":"x","position":"right"}]}"#, to: source.appending(path: "config.json"))
            _ = try fixture.packages.install(source, record: record)
        }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        let shared = try BarLink.sharing(store, on: BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil))
        #expect(shared.look == "Catppuccin (shared)")
        #expect(shared.widgets == [
            BarLink.Sharing.Widget(name: "Weather", symbol: "textformat", store: true, settings: ["Units: imperial", "Refresh every (seconds): 300"],
                                   settingsLeftOut: ["City: free text", "API key: secret"]),
            BarLink.Sharing.Widget(name: "Notes", symbol: "textformat", leftOut: "Local folder"),
            BarLink.Sharing.Widget(name: "Team", symbol: "textformat", leftOut: "Private source"),
            BarLink.Sharing.Widget(name: "clock", symbol: "clock"),
            BarLink.Sharing.Widget(name: "note", symbol: "terminal", leftOut: "Script widget"),
            BarLink.Sharing.Widget(name: "volume", symbol: "gauge.with.dots.needle.33percent", leftOut: "Custom provider")
        ])
        let page = "https://stablebar.app/bar.html#"
        #expect(shared.link.absoluteString.hasPrefix(page + "v=1&d="))
        let link = try #require(try BarLink(url: URL(string: "stablebar://bar?" + shared.link.absoluteString.dropFirst(page.count))!))
        #expect(link.widgets == [["id": .string("clock"), "type": .string("clock"), "position": .string("right"),
                                  "style": .object(["foreground": .string("#0000ff")])]])
        #expect(link.packages == [BarLink.Package(id: "weather", version: "1.0.0", settings: ["units": .string("imperial"), "interval": .number(300)])])
        #expect(link.widgetOverrides == ["weather": ["position": .string("right"), "group": .string("status")]])
        #expect(link.widgetOrder == ["weather", "clock"])
        let manifest = try JSONDecoder().decode([String: ConfigurationValue].self, from: link.theme.manifest)
        #expect(manifest["name"] == .string("Catppuccin (shared)"))
        #expect(try manifest["id"]?.decoded(String.self).hasPrefix("shared-") == true)
        let look = try JSONDecoder().decode([String: ConfigurationValue].self, from: link.theme.configuration)
        #expect(look["profiles"] == nil)
        #expect(try look["defaults"]?.decoded([String: ConfigurationValue].self)["cornerRadius"] == .number(4))
        let bar = try #require(try look["bar"]?.decoded([String: ConfigurationValue].self))
        #expect(bar["height"] == .number(30))
        #expect(bar["position"] == nil)
        let tokens = try #require(try look["tokens"]?.decoded([String: ConfigurationValue].self))
        #expect(tokens["accent"] == .string("#ff0000"))
        #expect(tokens["barTint"] == .string("#123456"))
        #expect(tokens["myBlue"] == nil)
        #expect(tokens["apiKey"] == nil)
    }

    @Test func tryingABarLinkShowsItsWidgetsUntilCancelled() async throws {
        let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"mine","type":"text","text":"Mine","position":"left"}]}"#)
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        try DocsImages.offline(store, in: fixture.directory)
        let original = try Data(contentsOf: fixture.url)
        let candidate = try BarLinkCandidate(link: linkedBar(), store: store)
        defer { candidate.discard() }
        await candidate.loadStore()
        await candidate.tryOnBar()
        #expect(candidate.state == .trying)
        #expect(store.configurationStore.themeTrialDirectory == candidate.look.choice.directory)
        #expect(store.configuration?.widgets.map(\.id) == ["workspaces", "app", "sound", "battery", "clock"])
        #expect(try Data(contentsOf: fixture.url) == original)
        candidate.cancelTrial()
        #expect(candidate.state == .ready)
        #expect(store.configuration?.widgets.map(\.id) == ["mine"])
    }

    @Test(arguments: [(false, "top"), (true, "top"), (true, "bottom")])
    func usingABarLinkReplacesTheWidgetsAndLookInOneUndoStep(notched: Bool, position: String) async throws {
        let fixture = try ThemeGalleryFixture(#"""
            {"defaults":{"cornerRadius":2},"bar":{"height":40,"position":"\#(position)"},
             "screens":{"laptop":{"layout":{"left":["mine"]}}},
             "profiles":[{"name":"Work","enabled":false,"configuration":{"widgetOverrides":{"mine":{"text":"Work"}}}}],
             "widgets":[{"id":"mine","type":"text","text":"Mine","position":"left"},
                        {"id":"clock","type":"clock","position":"right"}]}
            """#)
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        try DocsImages.offline(store, in: fixture.directory)
        let original = try Data(contentsOf: fixture.url)
        var link = try linkedBar()
        link.widgets[4]["position"] = .string("center")
        link.widgets[3]["group"] = .string("status")
        var look = try JSONDecoder().decode([String: ConfigurationValue].self, from: link.theme.configuration)
        look["groups"] = .object(["status": .object(["style": .object(["cornerRadius": .number(8)])])])
        link.theme = ThemeLink(manifest: link.theme.manifest, configuration: try configurationData(look))
        let candidate = try BarLinkCandidate(link: link, store: store)
        defer { candidate.discard() }
        candidate.hasNotchedDisplay = { notched }
        await candidate.loadStore()
        #expect(candidate.widgets.filter { $0.source == .unlisted }.map(\.id) == ["weather", "uptime"])
        await candidate.use()
        #expect(candidate.state == .used)
        #expect(store.configurationError == nil)
        #expect(store.configurationStore.selectedThemeKey == "shared-5c1e0b7a/1.0.0")
        #expect(store.configuration?.widgets.map(\.id) == ["workspaces", "app", "sound", "battery", "clock"])
        let document = try fixture.document()
        #expect(document["defaults"] == nil)
        #expect(document["bar"] == .object(["position": .string(position)]))
        #expect(document["screens"] == (notched && position == "top" ? .object(["laptop": .object(["layout": .object([
            "left": .array([.string("workspaces"), .string("app")]), "notchLeft": .array([.string("clock")]),
            "notchRight": .array([]), "right": .array([.string("sound"), .string("battery")])
        ])])]) : nil))
        #expect(document["groups"] == .object(["status": .object([:])]))
        let gallery = ThemeGallery(store: store)
        await gallery.refresh()
        gallery.select(try #require(gallery.choices.first { $0.key == "clear" }))
        #expect(gallery.errors["clear"] == nil)
        #expect(store.configurationError == nil)
        #expect(store.configuration?.widgets.first { $0.id == "battery" }?.group == "status")
        try store.customizationHistory.undo()
        #expect(document["profiles"] == .array([.object(["name": .string("Work"), "enabled": .bool(false), "configuration": .object([:])])]))
        #expect(store.customizationHistory.undoSteps.count == 1)
        try store.customizationHistory.undo()
        #expect(try Data(contentsOf: fixture.url) == original)
    }

    @Test func untickedWidgetsAndTheirStorePackagesAreLeftOutOfTryAndUse() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        let index = LocalPackageIndex(fixture: fixture)
        _ = try await index.add(id: "weather", kind: "widgets", configuration: #"{"widgets":[{"id":"weather","type":"text","text":"21°","position":"right"}]}"#,
                                name: "Weather")
        store.packageStoreClient = PackageStoreClient(packages: fixture.packages, indexURL: index.url)
        let candidate = try BarLinkCandidate(link: linkedBar(), store: store)
        defer { candidate.discard() }
        await candidate.loadStore()
        #expect(candidate.widgets.first { $0.id == "weather" }
            == BarLinkCandidate.Widget(id: "weather", name: "Weather", source: .store(summary: "Runs nothing, stays offline")))
        // The Store doesn't list uptime, so it has nothing to preview.
        #expect(candidate.previewWidgets.map(\.id) == ["workspaces", "app", "weather", "sound", "battery", "clock"])
        #expect(candidate.previewWidgets[2].content == .text("Weather"))
        #expect(candidate.previewWidgets[2].position == .right)
        candidate.unticked = ["weather", "battery"]
        #expect(candidate.previewWidgets.map(\.id) == ["workspaces", "app", "sound", "clock"])
        await candidate.tryOnBar()
        #expect(candidate.state == .trying)
        #expect(store.configuration?.widgets.map(\.id) == ["workspaces", "app", "sound", "clock"])
        candidate.cancelTrial()
        await candidate.use()
        #expect(candidate.state == .used)
        #expect(store.configuration?.widgets.map(\.id) == ["workspaces", "app", "sound", "clock"])
        #expect(try fixture.document()["packages"] == nil)
        #expect(try !fixture.packages.list().contains { $0.id == "weather" })
    }

    @Test func storePackagesThatNeedAReviewShareOneReview() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        let index = LocalPackageIndex(fixture: fixture)
        let entries = [
            try await index.add(id: "weather", kind: "widgets", configuration: #"""
                {"widgets":[{"id":"weather","type":"text","text":"21°","position":"right"},{"id":"forecast","type":"text","text":"Sun","position":"right"}]}
                """#, hosts: #"["api.open-meteo.com"]"#, name: "Weather"),
            try await index.add(id: "uptime", kind: "widgets", configuration: #"{"widgets":[{"id":"uptime","type":"text","text":"3 days","position":"right"}]}"#,
                                settings: #"{"interval":{"type":"number","default":60}}"#, hosts: #"["example.com"]"#, name: "Uptime"),
            try await index.add(id: "moon", kind: "widgets", configuration: #"{"widgets":[{"id":"moon","type":"text","text":"Moon","position":"right"}]}"#,
                                name: "Moon"),
            try await index.add(id: "ticker", kind: nil, configuration: #"""
                {"widgets":[{"id":"ticker","type":"script","command":"date","position":"right"},
                            {"id":"tock","type":"script","command":"date +%s","position":"right"}]}
                """#, permissions: #"["accessibility"]"#, name: "Ticker")
        ]
        try JSONEncoder().encode(ConfigurationValue.object(["packages": .array(entries.map { entry in
            .object(["id": .string(entry.id), "name": .string(entry.name), "version": .string(entry.version),
                     "kind": entry.kind.map { .string($0.rawValue) } ?? .null,
                     "archive": .string(entry.archive), "sha256": .string(entry.sha256)])
        })])).write(to: index.url)
        store.packageStoreClient = PackageStoreClient(packages: fixture.packages, indexURL: index.url)
        var link = try linkedBar()
        link.packages += [BarLink.Package(id: "moon", version: "1", settings: [:]), BarLink.Package(id: "ticker", version: "1", settings: [:])]
        for id in ["forecast", "moon", "ticker"] { link.widgetOverrides[id] = ["position": .string("right")] }
        link.widgetOrder += ["forecast", "moon", "ticker"]
        let candidate = try BarLinkCandidate(link: link, store: store)
        defer { candidate.discard() }
        await candidate.loadStore()
        #expect(candidate.widgets.filter { $0.source != .builtIn }.map(\.source) == [
            .store(summary: "Connects to api.open-meteo.com"), .store(summary: "Connects to example.com"),
            .store(summary: "Connects to api.open-meteo.com"), .store(summary: "Runs nothing, stays offline"),
            .store(summary: "Runs 2 commands · Needs Accessibility access")
        ])
        candidate.unticked = ["forecast", "ticker"]
        await candidate.use()
        #expect(candidate.state == .ready)
        #expect(candidate.reviews.map(\.manifest.id) == ["weather", "uptime"])
        #expect(try fixture.packages.list().map(\.id) == ["moon"])

        // As the review's Add to bar does.
        let library = PackageLibrary(store: store, reviewing: true)
        await library.loadInstalled()
        for inspection in candidate.reviews {
            await library.select(inspection.directory, sourceID: PackageSource.storeID, settings: candidate.settings(for: inspection.manifest))
            let draft = try #require(library.draft)
            await library.add(draft, onEnable: { candidate.reviewed($0, settings: $1) })
            #expect(draft.error == nil)
        }
        await candidate.resume()
        #expect(candidate.state == .used)
        #expect(candidate.reviews.isEmpty)
        #expect(store.configuration?.widgets.filter(\.enabled).map(\.id) == ["workspaces", "app", "weather", "uptime", "sound", "battery", "clock", "moon"])
        #expect(store.configuration?.widgets.first { $0.id == "forecast" }?.enabled == false)
        let packages = try #require(try fixture.document()["packages"]?.decoded([WidgetPackageSelection].self))
        #expect(packages.map(\.id) == ["weather", "uptime", "moon"])
        #expect(packages[1].settings == ["interval": .number(300)])
        #expect(store.customizationHistory.undoSteps.count == 1)
    }

    @Test(arguments: [true, false])
    func aStoreVersionOnTheBarSkipsTheReviewAndTakesTheLinksSettingsAndGroup(onBar: Bool) async throws {
        let fixture = try ThemeGalleryFixture(onBar ? #"{"packages":[{"id":"weather","version":"1","settings":{"units":"imperial","city":"Bern"}}]}"# : "{}")
        defer { fixture.close() }
        let index = LocalPackageIndex(fixture: fixture)
        _ = try await index.add(id: "weather", kind: "widgets", configuration: #"{"widgets":[{"id":"weather","type":"text","text":"21°","position":"right"}]}"#,
                                settings: #"{"units":{"type":"string","choices":["metric","imperial"],"default":"metric"},"city":{"type":"string","default":"Zurich"}}"#,
                                hosts: #"["api.open-meteo.com"]"#, name: "Weather")
        let client = PackageStoreClient(packages: fixture.packages, indexURL: index.url)
        _ = try await client.install(id: "weather", from: PackageSource.storeID)
        let store = try loadedStore(fixture)
        defer { store.stop() }
        store.packageStoreClient = client
        var link = try linkedBar()
        var look = try JSONDecoder().decode([String: ConfigurationValue].self, from: link.theme.configuration)
        look["groups"] = .object(["status": .object([:])])
        link.theme = ThemeLink(manifest: link.theme.manifest, configuration: try configurationData(look))
        link.widgetOverrides["weather"] = ["position": .string("right"), "group": .string("status")]
        let candidate = try BarLinkCandidate(link: link, store: store)
        defer { candidate.discard() }
        await candidate.loadStore()
        await candidate.use()
        guard onBar else {
            #expect(candidate.reviews.map(\.manifest.id) == ["weather"])
            return
        }
        #expect(candidate.state == .used)
        let packages = try #require(try fixture.document()["packages"]?.decoded([WidgetPackageSelection].self))
        #expect(packages.map(\.settings) == [["units": .string("metric"), "city": .string("Bern")]])
        #expect(store.configuration?.widgets.first { $0.id == "weather" }?.ownGroup == "status")
    }

    @Test func anUntickedLookKeepsTheBarsLookAndAppliesOnlyTheWidgets() async throws {
        let fixture = try ThemeGalleryFixture(#"""
            {"theme":{"id":"gruvbox"},"defaults":{"cornerRadius":2},"groups":{"mine":{}},
             "widgets":[{"id":"mine","type":"text","text":"Mine","position":"left"}]}
            """#)
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        try DocsImages.offline(store, in: fixture.directory)
        var link = try linkedBar()
        link.widgets[0]["group"] = .string("theirs")
        link.widgets[1]["group"] = .string("mine")
        let candidate = try BarLinkCandidate(link: link, store: store)
        defer { candidate.discard() }
        await candidate.loadStore()
        candidate.appliesLook = false
        await candidate.tryOnBar()
        #expect(candidate.state == .trying)
        #expect(store.configurationStore.themeTrialDirectory?.lastPathComponent == "gruvbox")
        #expect(store.configuration?.defaults.cornerRadius == 2)
        #expect(store.configuration?.widgets.map(\.id) == ["workspaces", "app", "sound", "battery", "clock"])
        candidate.cancelTrial()
        #expect(store.configuration?.widgets.map(\.id) == ["mine"])
        await candidate.use()
        #expect(candidate.state == .used)
        #expect(store.configurationStore.selectedThemeKey == "gruvbox")
        #expect(store.configuration?.defaults.cornerRadius == 2)
        #expect(store.configuration?.widgets.map(\.id) == ["workspaces", "app", "sound", "battery", "clock"])
        #expect(store.configuration?.widgets.map(\.ownGroup) == [nil, "mine", nil, nil, nil])
        #expect(try fixture.document()["defaults"] == .object(["cornerRadius": .number(2)]))
    }

    enum Rejection: CaseIterable, Sendable {
        case bar, profileBar, hosts, permissions, tools, secrets, screenshot, includes, profileIncludes
        case widgets, missingKind, bundledID, legacyID, classicID, widgetID, doublingTokens, profileExpansion, nestedProfileExpansion
        case tokenBar, overriddenTokenBar, settingBar, referenceDepth, referenceOrigins, invalidEntry, unknownProperty
        case combinedProfileBar, settingChoiceBar, nestedProfileBar, nullBar, arrayBar
        case tooLarge, tooDeep, tooManyProfiles, tooManyNestedProfiles, notUTF8, notAnObject
        case malformedProfiles, outOfRangeNumber, malformedManifest
    }

    private var linkedThemeDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/linked-theme")
    }

    private func linkedBar() throws -> BarLink {
        try BarLink(payload: Data(contentsOf: linkedThemeDirectory.deletingLastPathComponent().appending(path: "linked-bar.json")))
    }

    private func linkedTheme() throws -> ThemeLink {
        ThemeLink(manifest: try Data(contentsOf: linkedThemeDirectory.appending(path: "package.json")),
                  configuration: try Data(contentsOf: linkedThemeDirectory.appending(path: "config.json")))
    }

    private func expectThemeKeyRefusal(_ key: String, in link: ThemeLink) throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try loadedStore(fixture)
        defer { store.stop() }
        let before = try temporaryFolders()
        let error = #expect(throws: WidgetPackageError.self) {
            let candidate = try ThemeLinkCandidate(link: link, store: store)
            candidate.discard()
        }
        #expect(error?.errorDescription == WidgetPackageError.themeProperty(key).errorDescription)
        #expect(try temporaryFolders() == before)
    }

    private func barValue(_ value: ConfigurationValue, at path: String) -> ConfigurationValue {
        path.split(separator: ".").reversed().reduce(value) { value, key in
            if key == "gradient", case var .object(gradient) = value {
                gradient["colors"] = .array([.string("#000000"), .string("#ffffff")])
                return .object([String(key): .object(gradient)])
            }
            return .object([String(key): value])
        }
    }

    private func valueCount(_ data: Data) throws -> Int {
        func count(_ value: Any) -> Int {
            if let object = value as? [String: Any] { return 1 + object.values.reduce(0) { $0 + count($1) } }
            if let array = value as? [Any] { return 1 + array.reduce(0) { $0 + count($1) } }
            return 1
        }
        return count(try JSONSerialization.jsonObject(with: data))
    }

    private func longKeyLink(profileCount: Int, groups: Int = 2) throws -> ThemeLink {
        var link = try linkedTheme()
        func configuration(keyBytes: Int) throws -> Data {
            let tokens: [String: ConfigurationValue] = [
                "s": .object([String(repeating: "k", count: keyBytes): .number(1)]),
                "t1": .array(Array(repeating: .string("@token.s"), count: 10)),
                "t2": .array(Array(repeating: .string("@token.t1"), count: groups))
            ]
            let profiles = (0..<profileCount).map { profile([:], name: "p\($0)", enabled: false) }
            return try JSONEncoder().encode(ConfigurationValue.object([
                "tokens": .object(tokens), "profiles": .array(profiles)
            ]))
        }
        let overhead = try configuration(keyBytes: 0).count
        link.configuration = try configuration(keyBytes: ThemeLink.maximumFileBytes - link.manifest.count - overhead - 16)
        return link
    }

    private func loadedStore(_ fixture: ThemeGalleryFixture) throws -> BarStore {
        let store = try fixture.store()
        store.configurationStore.reloadConfiguration()
        #expect(store.configurationError == nil)
        _ = try #require(store.configuration)
        return store
    }

    private func exists(_ directory: URL) -> Bool { FileManager.default.fileExists(atPath: directory.path) }

    private func temporaryFolders() throws -> Set<URL> {
        Set(try FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("stablebar-theme-link-") })
    }

    private func profile(_ configuration: [String: ConfigurationValue], name: String = "Test", enabled: Bool = true) -> ConfigurationValue {
        .object(["name": .string(name), "enabled": .bool(enabled), "configuration": .object(configuration)])
    }

    private func doublingTokens(
        levels: Int, value: ConfigurationValue = .number(1)
    ) -> [String: ConfigurationValue] {
        var tokens: [String: ConfigurationValue] = ["t0": .array([value, value])]
        for level in 1...levels {
            let reference = ConfigurationValue.string("@token.t\(level - 1)")
            tokens["t\(level)"] = .array([reference, reference])
        }
        return tokens
    }
}
