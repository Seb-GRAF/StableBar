import Foundation
import Testing
@testable import StableBar

@MainActor
struct LinkedThemeCardTests {
    @Test func theOverrideNoticeFollowsALinkedTheme() async throws {
        let fixture = try ThemeGalleryFixture(#"{"bar":{"height":40},"widgets":[]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        store.reloadConfiguration()
        let gallery = ThemeGallery(store: store)
        await gallery.refresh()
        #expect(store.receive([try link().link]) == .appearance)

        gallery.contextChanged()

        #expect(!gallery.overrides.values.isEmpty)
        #expect(gallery.overrides.values.contains(ThemeOverride(path: ["bar", "height"], title: "Bar height")))
        #expect(gallery.overrides.summary.contains("Bar height"))
        let candidate = try #require(store.pendingLinks.theme)
        candidate.tryOnBar()
        gallery.contextChanged()
        #expect(candidate.state == .trying)
        #expect(gallery.overrides.values.contains(ThemeOverride(path: ["bar", "height"], title: "Bar height")))
    }

    @Test func useThemeFollowsTheGallerysScreenSetupChoice() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let setups = ["setup-laptop.json", "setup-monitor.json", "setup-laptop+monitor.json"]
        for name in setups {
            try fixture.write(#"{"widgets":[]}"#, to: fixture.directory.appending(path: name))
        }
        let store = try fixture.store()
        defer { store.stop() }
        store.reloadConfiguration()
        #expect(store.receive([try link().link]) == .appearance)
        let candidate = try #require(store.pendingLinks.theme)

        let gallery = ThemeGallery(store: store)
        let card = LinkedThemeCard(candidate: candidate, gallery: gallery, everyBar: true)
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
        store.reloadConfiguration()
        #expect(store.receive([try link().link]) == .appearance)
        let candidate = try #require(store.pendingLinks.theme)
        let card = LinkedThemeCard(candidate: candidate, gallery: ThemeGallery(store: store), screen: .monitor, everyBar: false)

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
        store.reloadConfiguration()
        #expect(store.receive([try link().link]) == .appearance)
        let candidate = try #require(store.pendingLinks.theme)
        let gallery = ThemeGallery(store: store)
        let card = LinkedThemeCard(candidate: candidate, gallery: gallery)
        candidate.tryOnBar()
        #expect(candidate.state == .trying)

        card.cancelTrial()

        #expect(candidate.state == .ready)
        #expect(store.themeTrialDirectory == nil)
        #expect(store.pendingLinks.theme === candidate)
        #expect(FileManager.default.fileExists(atPath: candidate.choice.directory.path))

        card.dismiss()

        #expect(store.pendingLinks.theme == nil)
        #expect(!FileManager.default.fileExists(atPath: candidate.choice.directory.path))
    }

    @Test func aFailedCandidateLeavesTheOverrideNoticeWithTheSelectedTheme() async throws {
        let fixture = try ThemeGalleryFixture(#"{"bar":{"height":40},"widgets":[]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        store.reloadConfiguration()
        let gallery = ThemeGallery(store: store)
        await gallery.refresh()
        #expect(store.receive([try link().link]) == .appearance)
        let candidate = try #require(store.pendingLinks.theme)
        gallery.contextChanged()
        #expect(!gallery.overrides.values.isEmpty)
        try fixture.write("not a directory", to: fixture.packages.directory)

        await LinkedThemeCard(candidate: candidate, gallery: gallery).useTheme()

        guard case .failed = candidate.state else { Issue.record("Expected an installation error"); return }
        #expect(store.pendingLinks.theme === candidate)
        #expect(gallery.overrides.values.isEmpty)
    }

    @Test func linkedPreviewsShowTheThemeAloneAndSurviveGalleryRefreshes() async throws {
        let fixture = try ThemeGalleryFixture(#"{"bar":{"height":40},"widgets":[]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        #expect(store.receive([try link().link]) == .appearance)
        let candidate = try #require(store.pendingLinks.theme)
        let gallery = ThemeGallery(store: store)

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
        let gallery = ThemeGallery(store: store)
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

    @Test func resettingLinkedOverridesKeepsOtherSettingsAndIsUndoable() async throws {
        let fixture = try ThemeGalleryFixture(#"{"bar":{"height":40,"margin":12},"widgets":[]}"#)
        defer { fixture.close() }
        let original = try Data(contentsOf: fixture.url)
        let store = try fixture.store()
        defer { store.stop() }
        store.reloadConfiguration()
        let gallery = ThemeGallery(store: store)
        await gallery.refresh()
        #expect(store.receive([try link().link]) == .appearance)
        gallery.contextChanged()

        gallery.resetOverrides(everyBar: false)

        #expect(try fixture.document()["bar"] == .object(["margin": .number(12)]))
        #expect(gallery.overrides.values.isEmpty)
        #expect(store.pendingLinks.theme?.state == .ready)
        #expect(store.customizationHistory.undoSteps.count == 1)
        try store.customizationHistory.undo()
        #expect(try Data(contentsOf: fixture.url) == original)
    }

    @Test func anOlderCardCannotDismissANewerLink() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        #expect(store.receive([try link().link]) == .appearance)
        let old = try #require(store.pendingLinks.theme)
        let card = LinkedThemeCard(candidate: old, gallery: ThemeGallery(store: store))
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
