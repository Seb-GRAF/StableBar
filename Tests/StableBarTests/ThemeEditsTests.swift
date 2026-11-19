import Foundation
import Testing
@testable import StableBar

@MainActor
struct ThemeEditsTests {
    private func editor(_ json: String, theme: String = #"{"defaults":{"fontSize":12,"cornerRadius":10}}"#)
        async throws -> (ThemeGalleryFixture, BarStore, ConfigurationEditor) {
        let fixture = try ThemeGalleryFixture(json)
        _ = try fixture.theme(theme)
        let store = try fixture.store()
        store.configurationStore.reloadConfiguration()
        let editor = ConfigurationEditor(store: store)
        await editor.gallery.refresh()
        return (fixture, store, editor)
    }

    private func profiles(_ fixture: ThemeGalleryFixture) throws -> [[String: ConfigurationValue]] {
        try fixture.document()["profiles"]?.decoded([[String: ConfigurationValue]].self) ?? []
    }

    @Test func settingsSavesTheLookAsAnEditOfTheSelectedThemeAndTheRestInTheMainFile() async throws {
        let (fixture, store, editor) = try await editor(#"""
        {"theme":{"id":"test-theme","version":"1"},"widgets":[{"id":"clock","type":"clock","position":"right"}]}
        """#)
        defer { fixture.close(); store.stop() }

        editor.changeLook(ConfigurationEdit(action: .defaults, properties: ["fontSize": .number(14)]))
        editor.changeLook(ConfigurationEdit(action: .bar, properties: ["height": .number(30), "position": .string("bottom")]))
        editor.changeLook(ConfigurationEdit(action: .tokens, properties: ["accent": .string("#ff0000"), "header": .string("x")]))
        editor.set(["style": .object(["foreground": .string("#00ff00")]), "format": .string("HH:mm")], for: "clock")
        try editor.history.flush()

        let document = try fixture.document()
        #expect(try profiles(fixture) == [[
            "name": .string("Test theme edits"), "when": .object(["theme": .string("test-theme")]),
            "configuration": .object([
                "defaults": .object(["fontSize": .number(14)]), "bar": .object(["height": .number(30)]),
                "tokens": .object(["accent": .string("#ff0000")]),
                "widgetOverrides": .object(["clock": .object(["style": .object(["foreground": .string("#00ff00")])])])
            ])
        ]])
        #expect(document["bar"] == .object(["position": .string("bottom")]))
        #expect(document["tokens"] == .object(["header": .string("x")]))
        #expect(try document["widgets"]?.decoded([[String: ConfigurationValue]].self).first?["format"] == .string("HH:mm"))
        #expect(store.configuration?.defaults.fontSize == 14)
        #expect(store.configuration?.widgets.first?.style.foreground == HexColor(0x00ff00ff))
        editor.gallery.configurationChanged()
        #expect(editor.gallery.edits.changes.map(\.title) == ["Height", "Text size", "Accent", "Text color"])
        #expect(editor.gallery.edits.changes.last?.section == "clock")
        #expect(editor.error == nil)
    }

    @Test func editsOfOneScreenOrOfAProfileStayWhereTheyWere() async throws {
        let (fixture, store, editor) = try await editor(#"""
        {"theme":{"id":"test-theme","version":"1"},"widgets":[],"profiles":[{"name":"work","configuration":{}}]}
        """#)
        defer { fixture.close(); store.stop() }

        editor.changeLook(ConfigurationEdit(action: .screens, properties: ["laptop": .object(["defaults": .object(["fontSize": .number(9)])])]))
        editor.editBar(for: "work")
        editor.changeLook(ConfigurationEdit(action: .defaults, properties: ["fontSize": .number(16)]))
        try editor.history.flush()

        let document = try fixture.document()
        #expect(document["screens"] == .object(["laptop": .object(["defaults": .object(["fontSize": .number(9)])])]))
        #expect(try profiles(fixture).map { $0["name"] } == [.string("work")])
        #expect(try profiles(fixture).first?["configuration"] == .object(["defaults": .object(["fontSize": .number(16)])]))
    }

    @Test func aThemesEditsStayWithItWhenAnotherThemeIsChosenAndWhileAProfileIsPinned() async throws {
        let (fixture, store, editor) = try await editor(#"""
        {"theme":{"id":"test-theme","version":"1"},"widgets":[],"profiles":[{"name":"work","configuration":{"bar":{"spacing":3}}}],
         "profile":"work"}
        """#)
        defer { fixture.close(); store.stop() }
        editor.changeLook(ConfigurationEdit(action: .defaults, properties: ["fontSize": .number(14)]))
        try editor.history.flush()
        #expect(store.activeProfiles == ["work", "Test theme edits"])
        #expect(store.configuration?.defaults.fontSize == 14)

        let builtIn = try #require(editor.gallery.choices.first { $0.key == "built-in" })
        try store.configurationStore.applyTheme(builtIn)
        #expect(store.configuration?.defaults.fontSize == nil)
        let theme = try #require(editor.gallery.choices.first { $0.manifest.id == "test-theme" })
        try store.configurationStore.applyTheme(theme)
        #expect(store.configuration?.defaults.fontSize == 14)
    }

    @Test func aPairIsOneChangeAndOnlyTheLookOfTheMainFileAppliesToEveryTheme() throws {
        let main = try JSONDecoder().decode([String: ConfigurationValue].self, from: Data(#"""
        {"tokens":{"accent":{"light":"#111111","dark":"#222222"},"header":"Bearer x","brand":"#333333"},
         "defaults":{"foreground":{"light":"@token.text","dark":"#00ff00"},"background":{"gradient":{"colors":["#000000","#ffffff"]}}},
         "bar":{"height":30,"position":"bottom","appearance":"dark","style":{"cornerRadius":4}},
         "groups":{"pill":{},"chip":{"style":{"background":"@token.accent"}},"pair":{"members":[{"type":"clock"}]}},
         "widgets":[{"id":"clock","type":"clock","style":{"foreground":"#ff0000"}}],
         "widgetOverrides":{"battery":{"style":{"fontSize":9}}},
         "profiles":[{"name":"Mine","when":{"theme":"leman"},"configuration":{
           "defaults":{"cornerRadius":12},"widgetOverrides":{"clock":{"background":"#000000","format":"HH"}}}}]}
        """#.utf8))
        let theme = try JSONDecoder().decode([String: ConfigurationValue].self, from: Data(#"""
        {"tokens":{"brand":"#444444"},"defaults":{"cornerRadius":10}}
        """#.utf8))

        let edits = ThemeEdits(main: main, themeID: "leman", theme: theme, names: ["clock": "Clock"])

        #expect(edits.profile == "Mine")
        #expect(edits.changes.map(\.path) == [["defaults", "cornerRadius"], ["widgetOverrides", "clock", "background"]])
        #expect(edits.changes.first?.themeValue == .number(10))
        #expect(edits.everyTheme.map(\.title) == [
            "Height", "Corner radius", "Background", "Text color", "Chip group: background", "Pair group: members", "Accent", "Brand"
        ])
        #expect(ThemeEdits(main: main, themeID: "nord").changes.isEmpty)
        #expect(ThemeEdits.editedThemes(in: main) == ["leman"])
    }

    @Test func revertRemovesTheThemesEditsAndItsProfileOnceNothingElseIsLeft() async throws {
        let (fixture, store, editor) = try await editor(#"""
        {"theme":{"id":"test-theme","version":"1"},"widgets":[],"bar":{"margin":8},
         "profiles":[{"name":"Test theme edits","when":{"theme":"test-theme"},
                      "configuration":{"defaults":{"fontSize":14},"bar":{"height":30}}}]}
        """#)
        defer { fixture.close(); store.stop() }
        let edits = editor.gallery.edits
        #expect(edits.changes.count == 2)
        #expect(edits.everyTheme.map(\.path) == [["bar", "margin"]])

        editor.change(try #require(edits.removal(of: [edits.changes[0]])))
        #expect(try profiles(fixture).count == 1)
        let property = store.propertySources(path: "defaults", key: "fontSize", values: [:])
        try store.removePropertySource(try #require(property.saved))
        #expect(try profiles(fixture).isEmpty)
        #expect(try fixture.document()["bar"] == .object(["margin": .number(8)]))
        #expect(store.configuration?.defaults.fontSize == 12)

        editor.undo()
        editor.undo()
        editor.gallery.configurationChanged()
        editor.change(try #require(editor.gallery.edits.revertEdit))
        #expect(try profiles(fixture).isEmpty)
        #expect(editor.error == nil)
    }

    @Test func aValueMovesBetweenTheThemeAndEveryTheme() async throws {
        let (fixture, store, editor) = try await editor(#"""
        {"theme":{"id":"test-theme","version":"1"},"widgets":[],"defaults":{"fontSize":15}}
        """#)
        defer { fixture.close(); store.stop() }
        var edits = editor.gallery.edits
        editor.change(edits.keepingWithTheme(edits.everyTheme, theme: "Test theme"))
        #expect(try fixture.document()["defaults"] == nil)
        #expect(try profiles(fixture).first?["configuration"] == .object(["defaults": .object(["fontSize": .number(15)])]))
        #expect(store.configuration?.defaults.fontSize == 15)

        editor.gallery.configurationChanged()
        edits = editor.gallery.edits
        editor.change(edits.applyingToEveryTheme(try #require(edits.changes.first)))
        #expect(try fixture.document()["defaults"] == .object(["fontSize": .number(15)]))
        #expect(try profiles(fixture).isEmpty)
        #expect(store.customizationHistory.undoSteps.count == 2)
    }

    @Test func resettingAWidgetClearsItsEditsOfEveryTheme() async throws {
        let (fixture, store, editor) = try await editor(#"""
        {"theme":{"id":"test-theme","version":"1"},"widgets":[{"id":"clock","type":"clock","position":"right","style":{"fontSize":20}}],
         "profiles":[{"name":"A","when":{"theme":"test-theme"},"configuration":{"widgetOverrides":{"clock":{"style":{"fontSize":9}}}}},
                     {"name":"B","when":{"theme":"nord"},
                      "configuration":{"defaults":{"cornerRadius":3},"widgetOverrides":{"clock":{"background":"#000000"}}}}]}
        """#)
        defer { fixture.close(); store.stop() }
        let clock = try #require(store.configuration?.widgets.first)
        #expect(editor.ownStyle(of: clock) == (everyTheme: 1, onTheme: 1))

        editor.reset(clock)

        #expect(try profiles(fixture).map { $0["name"] } == [.string("B")])
        #expect(try profiles(fixture).first?["configuration"] == .object(["defaults": .object(["cornerRadius": .number(3)])]))
        #expect(try fixture.document()["widgets"]?.decoded([[String: ConfigurationValue]].self).first?["style"] == nil)
        #expect(store.customizationHistory.undoSteps.count == 1)
    }

    @Test func savingAThemeUnderItsOwnNameKeepsItsWidgetEdits() async throws {
        let (fixture, store, editor) = try await editor(#"""
        {"theme":{"id":"test-theme","version":"1"},"widgets":[{"id":"clock","type":"clock","position":"right"}],
         "profiles":[{"name":"Test theme edits","when":{"theme":"test-theme"},
                      "configuration":{"defaults":{"fontSize":14},"widgetOverrides":{"clock":{"background":"#000000"}}}}]}
        """#)
        defer { fixture.close(); store.stop() }

        await editor.gallery.save(try #require(editor.gallery.selectedChoice), as: "Test theme")

        #expect(editor.gallery.selectedKey == "test-theme/1.0.0")
        #expect(try profiles(fixture) == [[
            "name": .string("Test theme edits"), "when": .object(["theme": .string("test-theme")]),
            "configuration": .object(["widgetOverrides": .object(["clock": .object(["background": .string("#000000")])])])
        ]])
    }

    @Test func savingAThemeLeavesAnotherProfileWithItsEditsName() async throws {
        let (fixture, store, editor) = try await editor(#"""
        {"theme":{"id":"test-theme","version":"1"},"widgets":[{"id":"clock","type":"clock","position":"right"}],
         "profiles":[{"name":"Mine edits","when":{"appearance":"dark"},"configuration":{}},
                     {"name":"Test theme edits","when":{"theme":"test-theme"},
                      "configuration":{"widgetOverrides":{"clock":{"background":"#000000"}}}}]}
        """#)
        defer { fixture.close(); store.stop() }

        await editor.gallery.save(try #require(editor.gallery.selectedChoice), as: "Mine")

        #expect(try profiles(fixture) == [
            ["name": .string("Mine edits"), "when": .object(["appearance": .string("dark")]), "configuration": .object([:])],
            ["name": .string("Mine edits 2"), "when": .object(["theme": .string("mine")]),
             "configuration": .object(["widgetOverrides": .object(["clock": .object(["background": .string("#000000")])])])]
        ])
    }
}
