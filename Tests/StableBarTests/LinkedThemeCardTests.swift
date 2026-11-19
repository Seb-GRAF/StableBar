import Foundation
import SwiftUI
import Testing
import Vision
@testable import StableBar

@MainActor
struct LinkedThemeCardTests {
    @Test func useThemeFollowsTheGallerysScreenSetupChoice() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let setups = ["setup-laptop.json", "setup-monitor.json", "setup-laptop+monitor.json"]
        for name in setups {
            try fixture.write(#"{"widgets":[]}"#, to: fixture.directory.appending(path: name))
        }
        let store = try fixture.store()
        defer { store.stop() }
        store.configurationStore.reloadConfiguration()
        #expect(store.receive([try link().link]) == .appearance)
        let candidate = try #require(store.pendingLinks.theme)

        let editor = ConfigurationEditor(store: store)
        let card = LinkedThemeCard(candidate: candidate, editor: editor, everyBar: true)
        await card.useTheme()

        #expect(candidate.state == .used)
        #expect(store.pendingLinks.theme == nil)
        let selected = ConfigurationValue.object(["id": .string("harbour-test"), "version": .string("1.0.0")])
        #expect(try fixture.document()["theme"] == selected)
        for name in setups {
            let data = try Data(contentsOf: fixture.directory.appending(path: name))
            let document = try JSONDecoder().decode([String: ConfigurationValue].self, from: data)
            #expect(document["theme"] == selected)
        }
        #expect(store.customizationHistory.undoSteps.count == 1)
    }

    @Test func theCardPassesItsScreenAndSetupChoiceToUseTheme() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let ownBar = fixture.directory.appending(path: "setup-monitor.json")
        try fixture.write(#"{"widgets":[]}"#, to: ownBar)
        let original = try Data(contentsOf: ownBar)
        let store = try fixture.store()
        defer { store.stop() }
        store.configurationStore.reloadConfiguration()
        #expect(store.receive([try link().link]) == .appearance)
        let candidate = try #require(store.pendingLinks.theme)
        let card = LinkedThemeCard(candidate: candidate, editor: ConfigurationEditor(store: store), screen: .monitor, everyBar: false)

        await card.useTheme()

        #expect(candidate.state == .used)
        let screens = try #require(try fixture.document()["screens"]?.decoded([String: [String: ConfigurationValue]].self))
        #expect(screens["monitor"]?["theme"] == .object(["id": .string("harbour-test"), "version": .string("1.0.0")]))
        #expect(try fixture.document()["theme"] == nil)
        #expect(try Data(contentsOf: ownBar) == original)
    }

    @Test func cancelKeepsTheCardAndDismissRemovesTheCandidate() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        store.configurationStore.reloadConfiguration()
        #expect(store.receive([try link().link]) == .appearance)
        let candidate = try #require(store.pendingLinks.theme)
        let editor = ConfigurationEditor(store: store)
        let gallery = editor.gallery
        await gallery.refresh()
        let card = LinkedThemeCard(candidate: candidate, editor: editor)
        candidate.tryOnBar()
        #expect(candidate.state == .trying)

        card.cancelTrial()

        #expect(candidate.state == .ready)
        #expect(store.configurationStore.themeTrialDirectory == nil)
        #expect(store.pendingLinks.theme === candidate)
        #expect(FileManager.default.fileExists(atPath: candidate.choice.directory.path))

        card.dismiss()

        #expect(store.pendingLinks.theme == nil)
        #expect(!FileManager.default.fileExists(atPath: candidate.choice.directory.path))
    }

    @Test(arguments: [false, true], [false, true])
    func aGallerySelectionSurvivesALinkedThemeInstallation(tryFirst: Bool, onScreen: Bool) async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let selected = try fixture.theme(#"{"bar":{"height":42}}"#)
        let store = try fixture.store()
        defer { store.stop() }
        store.configurationStore.reloadConfiguration()
        let client = store.packageStoreClient
        let started = AsyncStream.makeStream(of: Void.self)
        let release = AsyncStream.makeStream(of: Void.self)
        defer { started.continuation.finish(); release.continuation.finish() }
        let candidate = try ThemeLinkCandidate(link: link(), store: store) { directory in
            started.continuation.yield(())
            for await _ in release.stream { break }
            return try await client.install(directory, from: nil)
        }
        store.pendingLinks.theme = candidate
        let editor = ConfigurationEditor(store: store)
        let screen: ScreenKind? = onScreen ? .monitor : nil
        let card = LinkedThemeCard(candidate: candidate, editor: editor, screen: screen)
        if tryFirst { candidate.tryOnBar() }

        let use = Task { await card.useTheme() }
        for await _ in started.stream { break }
        editor.gallery.select(selected, on: screen)
        #expect(editor.gallery.errors[selected.key] == nil)
        let chosenDocument = try fixture.document()
        let undoCount = store.customizationHistory.undoSteps.count
        #expect(undoCount == 1)
        release.continuation.yield(())
        await use.value

        #expect(try fixture.document() == chosenDocument)
        #expect(store.configurationStore.selectedThemeKey == (onScreen ? "built-in" : selected.key))
        #expect(store.configurationStore.themeTrialDirectory == nil)
        #expect(store.customizationHistory.undoSteps.count == undoCount)
        #expect(candidate.state == .ready)
        #expect(store.pendingLinks.theme === candidate)
        #expect(FileManager.default.fileExists(atPath: candidate.choice.directory.path))
        let installed = try fixture.packages.directory(id: candidate.choice.manifest.id,
                                                      version: candidate.choice.manifest.version)
        #expect(try Data(contentsOf: installed.appending(path: "config.json")) == candidate.link.configuration)
        #expect(try Data(contentsOf: installed.appending(path: "package.json")) == candidate.link.manifest)

        await card.useTheme()

        #expect(candidate.state == .used)
        #expect(store.pendingLinks.theme == nil)
        #expect(store.customizationHistory.undoSteps.count == undoCount + 1)
        #expect(!FileManager.default.fileExists(atPath: candidate.choice.directory.path))
    }

    enum TrialChange: CaseIterable { case tryAnother, cancel, saveAnother }

    @Test(arguments: TrialChange.allCases)
    func aChangedTrialSurvivesALinkedThemeInstallation(change: TrialChange) async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let selected = try fixture.theme(#"{"bar":{"height":42}}"#)
        let store = try fixture.store()
        defer { store.stop() }
        store.configurationStore.reloadConfiguration()
        let client = store.packageStoreClient
        let started = AsyncStream.makeStream(of: Void.self)
        let release = AsyncStream.makeStream(of: Void.self)
        defer { started.continuation.finish(); release.continuation.finish() }
        let candidate = try ThemeLinkCandidate(link: link(), store: store) { directory in
            started.continuation.yield(())
            for await _ in release.stream { break }
            return try await client.install(directory, from: nil)
        }
        store.pendingLinks.theme = candidate
        let card = LinkedThemeCard(candidate: candidate, editor: ConfigurationEditor(store: store))
        candidate.tryOnBar()
        var endedTrial = false
        store.onWindowRequest = { if case .endThemeTrial = $0 { endedTrial = true } }

        let use = Task { await card.useTheme() }
        for await _ in started.stream { break }
        switch change {
        case .tryAnother: try store.configurationStore.tryTheme(selected)
        case .cancel: candidate.cancelTrial()
        case .saveAnother: try store.configurationStore.applyTheme(selected)
        }
        let chosenDocument = try fixture.document()
        let selectedKey = store.configurationStore.selectedThemeKey
        let undoCount = store.customizationHistory.undoSteps.count
        let trialDirectory = store.configurationStore.themeTrialDirectory
        let height = store.configuration?.bar.height
        release.continuation.yield(())
        await use.value

        #expect(try fixture.document() == chosenDocument)
        #expect(store.configurationStore.selectedThemeKey == selectedKey)
        #expect(store.configurationStore.themeTrialDirectory == trialDirectory)
        #expect(store.configuration?.bar.height == height)
        #expect(!endedTrial)
        #expect(store.customizationHistory.undoSteps.count == undoCount)
        #expect(candidate.state == (change == .saveAnother ? .trying : .ready))
        #expect(store.pendingLinks.theme === candidate)
        let installed = try fixture.packages.directory(id: candidate.choice.manifest.id,
                                                      version: candidate.choice.manifest.version)
        #expect(FileManager.default.fileExists(atPath: installed.path))

        card.dismiss()

        #expect(store.configurationStore.themeTrialDirectory == (change == .tryAnother ? selected.directory : nil))
        #expect(store.pendingLinks.theme == nil)
        #expect(!FileManager.default.fileExists(atPath: candidate.choice.directory.path))
    }

    enum Detour: CaseIterable { case chooseAnother, tryAnother }

    @Test(arguments: Detour.allCases)
    func aSelectionThatChangesBackSurvivesALinkedThemeInstallation(detour: Detour) async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let first = try fixture.theme(#"{"bar":{"height":42}}"#, id: "first-theme")
        let second = try fixture.theme(#"{"bar":{"height":44}}"#, id: "second-theme")
        let store = try fixture.store()
        defer { store.stop() }
        store.configurationStore.reloadConfiguration()
        let editor = ConfigurationEditor(store: store)
        editor.gallery.select(first)
        let client = store.packageStoreClient
        let started = AsyncStream.makeStream(of: Void.self)
        let release = AsyncStream.makeStream(of: Void.self)
        defer { started.continuation.finish(); release.continuation.finish() }
        let candidate = try ThemeLinkCandidate(link: link(), store: store) { directory in
            started.continuation.yield(())
            for await _ in release.stream { break }
            return try await client.install(directory, from: nil)
        }
        store.pendingLinks.theme = candidate
        let card = LinkedThemeCard(candidate: candidate, editor: editor)

        let use = Task { await card.useTheme() }
        for await _ in started.stream { break }
        switch detour {
        case .chooseAnother:
            editor.gallery.select(second)
            editor.gallery.select(first)
        case .tryAnother:
            try store.configurationStore.tryTheme(second)
            store.configurationStore.endThemeTrial()
        }
        #expect(store.configurationStore.selectedThemeKey == first.key)
        #expect(store.configurationStore.themeTrialDirectory == nil)
        let chosenDocument = try fixture.document()
        let undoCount = store.customizationHistory.undoSteps.count
        release.continuation.yield(())
        await use.value

        #expect(try fixture.document() == chosenDocument)
        #expect(store.configurationStore.selectedThemeKey == first.key)
        #expect(store.customizationHistory.undoSteps.count == undoCount)
        #expect(candidate.state == .ready)
        #expect(store.pendingLinks.theme === candidate)

        await card.useTheme()

        #expect(candidate.state == .used)
        #expect(store.configurationStore.selectedThemeKey == candidate.choice.key)
    }

    @Test(arguments: [false, true])
    func theCardTracksTrialsEndedElsewhere(tryThemes: Bool) async throws {
        let fixture = try ThemeGalleryFixture(#"{"bar":{"height":40},"widgets":[]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        store.configurationStore.reloadConfiguration()
        #expect(store.receive([try link().link]) == .appearance)
        let candidate = try #require(store.pendingLinks.theme)
        let editor = ConfigurationEditor(store: store)
        let gallery = editor.gallery
        await gallery.refresh()
        candidate.tryOnBar()
        #expect(candidate.state == .trying)
        if tryThemes {
            let trial = ThemeTrial(store: store)
            trial.next()
            #expect(store.configurationStore.themeTrialDirectory != candidate.choice.directory)
            #expect(candidate.state == .ready)
            candidate.cancelTrial()
            #expect(store.configurationStore.themeTrialDirectory == trial.choice?.directory)
            trial.cancel()
        } else {
            store.barEditing.begin()
            #expect(store.configurationStore.themeTrialDirectory == nil)
            #expect(candidate.state == .ready)
        }
        gallery.contextChanged()
        #expect(gallery.linkedThemeIsActive)
        #expect(store.pendingLinks.theme === candidate)
    }

    @Test func theErrorCardShowsItsMessage() async throws {
        let message = "This theme link needs a newer version of StableBar."
        let host = NSHostingView(rootView: LinkedThemeErrorCard(message: message, dismiss: {}).frame(width: 600))
        host.frame = CGRect(x: 0, y: 0, width: 600, height: 100)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 200,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = host.bounds.size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = try #require(bitmap.cgImage)
        let text = try await BlockingWork.run {
            let request = VNRecognizeTextRequest()
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: image).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        }
        #expect(text.contains(message))
    }

    @Test func aFailedCandidateStaysOnItsCard() async throws {
        let fixture = try ThemeGalleryFixture(#"{"bar":{"height":40},"widgets":[]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        store.configurationStore.reloadConfiguration()
        let editor = ConfigurationEditor(store: store)
        let gallery = editor.gallery
        await gallery.refresh()
        #expect(store.receive([try link().link]) == .appearance)
        let candidate = try #require(store.pendingLinks.theme)
        try fixture.write("not a directory", to: fixture.packages.directory)

        await LinkedThemeCard(candidate: candidate, editor: editor).useTheme()

        guard case .failed = candidate.state else { Issue.record("Expected an installation error"); return }
        #expect(store.pendingLinks.theme === candidate)
    }

    @Test func linkedPreviewsShowTheThemeAloneAndSurviveGalleryRefreshes() async throws {
        let fixture = try ThemeGalleryFixture(#"{"bar":{"height":40},"widgets":[]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        #expect(store.receive([try link().link]) == .appearance)
        let candidate = try #require(store.pendingLinks.theme)
        let editor = ConfigurationEditor(store: store)
        let gallery = editor.gallery

        await gallery.linkedPreview(for: candidate.choice)
        await gallery.refresh()

        let preview = try #require(gallery.previews[candidate.choice.linkedPreviewKey])
        #expect(preview.light.bar.height == 30)
        #expect(preview.dark.bar.height == 30)
        #expect(preview.light.widgets.isEmpty)
        #expect(store.configuration?.bar.height == 40)
        #expect(!gallery.choices.contains { $0.key == candidate.choice.key })
        #expect(try fixture.packages.list().isEmpty)
    }

    @Test func aLinkedPreviewDoesNotReplaceAnInstalledVersionsPreview() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let source = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/linked-theme")
        _ = try fixture.packages.install(source)
        let store = try fixture.store()
        defer { store.stop() }
        let editor = ConfigurationEditor(store: store)
        let gallery = editor.gallery
        await gallery.refresh()
        var changed = try link()
        changed.configuration = Data(#"{"bar":{"height":32}}"#.utf8)
        #expect(store.receive([changed.link]) == .appearance)
        let candidate = try #require(store.pendingLinks.theme)

        await gallery.linkedPreview(for: candidate.choice)
        await gallery.refresh()

        #expect(gallery.previews[candidate.choice.linkedPreviewKey]?.light.bar.height == 32)
        #expect(gallery.previews[candidate.choice.key]?.light.bar.height == 30)
    }

    @Test(arguments: [false, true])
    func linkedPreviewErrorsBelongOnlyToThatCopy(linkedFails: Bool) async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let source = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/linked-theme")
        _ = try fixture.packages.install(source)
        let store = try fixture.store()
        defer { store.stop() }
        #expect(store.receive([try link().link]) == .appearance)
        let candidate = try #require(store.pendingLinks.theme)
        let directory = candidate.choice.directory
        let gallery = ThemeGallery(store: store, loadPreview: { choice, themes in
            if choice.key == "harbour-test/1.0.0", (choice.directory == directory) == linkedFails {
                throw CommandFailure(message: "This copy's preview failed.")
            }
            return try ThemePreview(choice: choice, themesDirectory: themes)
        })

        await gallery.refresh()

        #expect(gallery.error(for: candidate.choice.linkedPreviewKey) == (linkedFails ? "This copy's preview failed." : nil))
        #expect(gallery.error(for: candidate.choice.key) == (linkedFails ? nil : "This copy's preview failed."))
    }

    @Test func anOlderCardCannotDismissANewerLink() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        #expect(store.receive([try link().link]) == .appearance)
        let old = try #require(store.pendingLinks.theme)
        let card = LinkedThemeCard(candidate: old, editor: ConfigurationEditor(store: store))
        #expect(store.receive([try link().link]) == .appearance)
        let current = try #require(store.pendingLinks.theme)

        card.dismiss()

        #expect(store.pendingLinks.theme === current)
        #expect(FileManager.default.fileExists(atPath: current.choice.directory.path))
    }

    private func link() throws -> ThemeLink {
        let directory = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/linked-theme")
        return ThemeLink(manifest: try Data(contentsOf: directory.appending(path: "package.json")),
                         configuration: try Data(contentsOf: directory.appending(path: "config.json")))
    }
}
