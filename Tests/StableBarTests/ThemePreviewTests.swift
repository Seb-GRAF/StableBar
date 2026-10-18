import AppKit
import XCTest
@testable import StableBar

final class ThemePreviewTests: XCTestCase {
    func testCatalogHasBuiltInThenBundledNamesThenInstalledVersionsWithInjectableResources() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let installed = try fixture.theme(#"{}"#)
        let catalog = ThemeCatalog(packages: fixture.packages.directory, themesDirectory: fixture.themes)
        let choices = catalog.choices
        XCTAssertEqual(choices.first?.key, "built-in")
        XCTAssertTrue(choices.first?.isBuiltIn == true)
        XCTAssertNil(choices.first?.edit.properties)
        let bundled = choices.filter { $0.isBundled && !$0.isBuiltIn }
        XCTAssertEqual(bundled.map(\.title), bundled.map(\.title).sorted())
        XCTAssertEqual(bundled.count, 7)
        XCTAssertEqual(choices.last?.key, installed.key)
        XCTAssertEqual(choices.last?.edit.properties, installed.selection)
        XCTAssertEqual(themeChoices(packages: fixture.packages.directory, themesDirectory: fixture.themes).map(\.key), Array(choices.dropFirst()).map(\.key))
    }

    @MainActor func testEachPreviewUsesTheUserLayersAndLatestOutputWithoutStartingAnything() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let marker = fixture.directory.appending(path: "must-not-exist")
        try fixture.write(#"{"widgets":[{"id":"included","type":"text","position":"left","text":"My included label","icon":"star"}]}"#,
                          to: fixture.directory.appending(path: "included.json"))
        try fixture.write("""
        {"includes":["included.json"],"bar":{"appearance":"dark"},
         "templates":{"note":{"type":"text","position":"left","text":"My template"}},
         "widgets":[{"id":"note","template":"note"},{"id":"clock","type":"clock","position":"right","role":"time"},
                    {"id":"script","type":"script","command":"touch '\(marker.path)'","position":"right"},
                    {"id":"native","type":"battery","position":"right"}],
         "widgetOverrides":{"included":{"text":"My current label"}},
         "profiles":[{"name":"dark","when":{"appearance":"dark"},"configuration":{"defaults":{"fontSize":17}}}]}
        """, to: fixture.url)
        let store = try fixture.store()
        let script = ScriptWidget()
        script.output = ScriptOutput(text: "My current output", icon: "bolt", value: 0.4)
        script.samples = [0.2, 0.4]
        var updates = 0
        script.onUpdate = { updates += 1 }
        store.scripts["script"] = script
        store.scripts["native"] = ScriptWidget()
        store.scripts["native"]?.output = ScriptOutput(text: "72%", icon: "battery.75percent")
        store.preparePresentations()
        store.presentations["script"]?.show(try ConfigurationValue.object(["fields": .object(["text": .string("Current overlay")]), "duration": .number(60)]).decoded(TemporaryOutput.self), output: 1)
        store.workspaceStore.acceptMode("command")
        store.workspaceStore.workspaces = [Workspace(name: "1", isFocused: true, isVisible: true, monitor: 1)]
        let model = ThemePreview(configurationURL: fixture.url, themesDirectory: fixture.themes)
        for choice in ThemeCatalog(packages: fixture.packages.directory, themesDirectory: fixture.themes).choices {
            let configuration = try model.configuration(for: choice, document: fixture.document(), context: store.context)
            XCTAssertEqual(configuration.widgets.map(\.id), ["included", "note", "clock", "script", "native"])
            XCTAssertEqual(configuration.defaults.fontSize, 17)
            XCTAssertEqual(configuration.widgets[0].content, .text("My current label"))
            let preview = ThemePreview.snapshot(configuration, from: store)
            XCTAssertEqual(preview.label(for: configuration.widgets[3]).text, "My current output")
            XCTAssertEqual(preview.label(for: configuration.widgets[3]).icon, "bolt")
            XCTAssertEqual(preview.label(for: configuration.widgets[4]).text, "72%")
            XCTAssertEqual(preview.scripts["script"]?.samples, [0.2, 0.4])
            XCTAssertFalse(preview.scripts["script"] === script)
            XCTAssertEqual(preview.workspaceStore.workspaces, store.workspaceStore.workspaces)
            XCTAssertEqual(preview.workspaceStore.mode, "command")
            XCTAssertFalse(preview.workspaceStore.isRunning)
            XCTAssertTrue(ThemePreview.usesDarkAppearance(configuration, context: store.context))
            XCTAssertEqual(preview.presentations.count, 5)
            XCTAssertEqual(preview.presentations["script"]?.temporaryFields, ["text": "Current overlay"])
            XCTAssertNil(preview.presentations["script"]?.expiry)
            XCTAssertEqual(preview.presentations["script"]?.style.base.foreground, configuration.defaults.foreground)
        }
        script.onUpdate?()
        XCTAssertEqual(updates, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(store.scripts.count, 2)
    }

    func testPreviewReplacesAnIncludedThemeAndComposesDownloadedThemeBeforeUserOverrides() throws {
        let fixture = try ThemeGalleryFixture(##"{"includes":["included.json"],"defaults":{"fontSize":22},"widgets":[{"id":"clock","type":"clock","position":"right"}]}"##)
        defer { fixture.close() }
        try fixture.write(#"{"theme":{"id":"terminal"}}"#, to: fixture.directory.appending(path: "included.json"))
        let downloaded = try fixture.theme(##"{"tokens":{"text":"#123456"},"bar":{"height":29,"style":{"cornerRadius":7}},"defaults":{"foreground":"@token.text","fontSize":14}}"##, install: false)
        let model = ThemePreview(configurationURL: fixture.url, themesDirectory: fixture.themes)
        let configuration = try model.configuration(for: downloaded, document: fixture.document(), context: ConfigurationContext())
        XCTAssertEqual(configuration.defaults.foreground, HexColor(0x123456ff))
        XCTAssertEqual(configuration.defaults.fontSize, 22)
        XCTAssertEqual(configuration.bar.height, 29)
        XCTAssertEqual(configuration.bar.style.cornerRadius, 7)
        XCTAssertNil(configuration.defaults.fontName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.packages.directory.path))
        let builtIn = ThemeCatalog(packages: fixture.packages.directory, themesDirectory: fixture.themes).choices[0]
        let original = try model.configuration(for: builtIn, document: fixture.document(), context: ConfigurationContext())
        XCTAssertNil(original.defaults.fontName)
        XCTAssertEqual(original.defaults.foreground, HexColor(light: 0x1d1d1fff, dark: 0xf5f5f7ff))
    }

    func testThemeLayerUsesOnlyItsOwnPropertiesAndActiveProfilesWithoutRequiringBuiltInTokens() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let theme = try fixture.theme(##"""
        {"defaults":{"foreground":"@token.text"},
         "profiles":[{"name":"night","when":{"appearance":"dark"},"configuration":{"bar":{"height":30}}}]}
        """##, install: false)
        let model = ThemePreview(configurationURL: fixture.url, themesDirectory: fixture.themes)
        let light = try model.layer(for: theme, context: ConfigurationContext())
        XCTAssertNil(light.values["tokens"])
        XCTAssertNil(light.values["bar"])
        let dark = try model.layer(for: theme, context: ConfigurationContext(appearance: "dark"))
        XCTAssertEqual(dark.values["bar"], .object(["height": .number(30)]))
        XCTAssertNil(dark.values["profiles"])
    }

    func testPreviewAppearanceFollowsTheBarChoiceThenTheSystem() throws {
        let configuration = try ConfigurationValue.object(["widgets": .array([])]).decoded(Configuration.self)
        XCTAssertFalse(ThemePreview.usesDarkAppearance(configuration, context: ConfigurationContext()))
        XCTAssertTrue(ThemePreview.usesDarkAppearance(configuration, context: ConfigurationContext(appearance: "dark")))
        let light = try ConfigurationValue.object(["widgets": .array([]), "bar": .object(["appearance": .string("light")])]).decoded(Configuration.self)
        let dark = try ConfigurationValue.object(["widgets": .array([]), "bar": .object(["appearance": .string("dark")])]).decoded(Configuration.self)
        XCTAssertFalse(ThemePreview.usesDarkAppearance(light, context: ConfigurationContext(appearance: "dark")))
        XCTAssertTrue(ThemePreview.usesDarkAppearance(dark, context: ConfigurationContext()))
    }
    @MainActor func testCompactPreviewKeepsVisibleWidgetsInPositionOrderAndPreservesGroups() throws {
        let fixture = try ThemeGalleryFixture(#"""
        {"groups":{"status":{"style":{"spacing":3}}},"widgets":[
         {"id":"clock","type":"clock","position":"right"},
         {"id":"first","type":"text","text":"First","position":"left","group":"status"},
         {"id":"second","type":"text","text":"Second","position":"left","group":"status"},
         {"id":"center","type":"text","text":"Center","position":"center"},
         {"id":"space","type":"spacer","position":"left"},
         {"id":"disabled","type":"text","text":"Disabled","position":"left","enabled":false},
         {"id":"hidden","type":"script","command":"echo must-not-run","position":"left"},
         {"id":"external","type":"text","text":"External","position":"right","display":"external"},
         {"id":"workspaces","type":"workspaces","position":"notchLeft"}]}
        """#)
        defer { fixture.close() }
        let store = try fixture.store()
        store.activeDisplayID = 2
        store.workspaceStore.workspaces = [Workspace(name: "Work", isFocused: true, isVisible: true, monitor: 2)]
        store.scripts["hidden"] = ScriptWidget()
        store.scripts["hidden"]?.output = ScriptOutput(text: "Hidden", hidden: true)
        let preview = ThemePreview.snapshot(try XCTUnwrap(store.configuration), from: store)
        let display = BarDisplay(id: 2, isBuiltIn: false, isMain: true, notch: nil)
        let units = ThemePreview.units(in: preview, display: display)
        XCTAssertEqual(units.map(\.id), ["group:status", "widget:workspaces", "widget:center", "widget:clock", "widget:external"])
        XCTAssertEqual(units[0].widgets.map(\.id), ["first", "second"])
        XCTAssertEqual(units[0].style?.spacing, 3)
        let builtIn = BarDisplay(id: 1, isBuiltIn: true, isMain: false, notch: nil)
        XCTAssertEqual(ThemePreview.units(in: preview, display: builtIn).map(\.id), ["group:status", "widget:center", "widget:clock"])
        XCTAssertFalse(preview.workspaceStore.isRunning)
        store.scripts["hidden"]?.output.text = "Newest output"
        XCTAssertEqual(preview.scripts["hidden"]?.output.text, "Hidden")
        let latest = ThemePreview.snapshot(try XCTUnwrap(store.configuration), from: store)
        XCTAssertEqual(latest.scripts["hidden"]?.output.text, "Newest output")
    }

}
