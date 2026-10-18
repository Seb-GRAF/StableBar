import XCTest
@testable import StableBar

final class ThemeOverridesTests: XCTestCase {
    func testStarterDimensionsCountOnlyWhenTheSelectedThemeSetsThem() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let starter = fixture.themes.deletingLastPathComponent().appending(path: "config.json")
        let main = try JSONDecoder().decode([String: ConfigurationValue].self, from: Data(contentsOf: starter))
        let result = ThemeOverrides(main: main, theme: ["bar": .object([
            "height": .number(40), "inset": .number(0), "spacing": .number(4), "appearance": .string("dark")
        ])], widgets: [])
        XCTAssertEqual(result.values.map(\.path), [["bar", "height"], ["bar", "inset"], ["bar", "spacing"]])
        XCTAssertEqual(result.values.map(\.title), ["Bar height", "Bar: Side inset", "Bar: Spacing"])
        XCTAssertTrue(ThemeOverrides(main: main, theme: [:], widgets: []).values.isEmpty)
    }

    @MainActor func testOwnWidgetStylesMatchDefaultsAndTheirRoleAndIgnoreIncludesAndTemplates() throws {
        let fixture = try ThemeGalleryFixture(##"""
        {"includes":["included.json"],"bar":{"appearance":"dark"},
         "templates":{"custom":{"style":{"foreground":"#ffffff"}}},
         "widgets":[{"id":"clock","type":"clock","position":"right","role":"time","template":"custom",
          "style":{"foreground":"#ffffff","fontSize":19,"cornerRadius":3}},
          {"id":"note","type":"text","text":"Note","position":"left","role":"secondary","style":{"fontSize":15}}],
         "widgetOverrides":{"included":{"style":{"foreground":"#cccccc"}}}}
        """##)
        defer { fixture.close() }
        try fixture.write(##"{"defaults":{"background":"#ffffff"},"bar":{"height":55},"widgets":[{"id":"included","type":"text","text":"Included","position":"left","style":{"fontSize":20}}]}"##,
                          to: fixture.directory.appending(path: "included.json"))
        let store = try fixture.store()
        let theme: [String: ConfigurationValue] = [
            "defaults": .object(["foreground": .null, "background": .null]),
            "roles": .object(["time": .object(["fontSize": .number(12)])]),
            "bar": .object(["height": .number(40), "appearance": .string("light")])
        ]
        let result = ThemeOverrides(main: try fixture.document(), theme: theme, widgets: store.configuration!.widgets)
        XCTAssertEqual(Set(result.values.map { $0.path.joined(separator: ".") }), [
            "widgets.clock.style.foreground", "widgets.clock.style.fontSize", "widgetOverrides.included.style.foreground"
        ])
        XCTAssertTrue(result.values.contains { $0.title == "Clock: Text color" })
        XCTAssertFalse(result.values.contains { $0.path.contains("templates") || $0.path.contains("appearance") })
    }

    func testColorsNullsAndNestedPresentationPropertiesAreNamedAndResetPrecisely() throws {
        let fixture = try ThemeGalleryFixture(##"""
        {"bar":{"appearance":"dark","style":{"cornerRadius":9}},"tokens":{"text":{"light":"#111111","dark":"#222222"},"custom":"#333333"},
         "defaults":{"background":null,"fontSize":18},"popupDefaults":{"fontWeight":"bold"},
         "roles":{"time":{"foreground":"#ffffff"}},"workspaceDefaults":{"indicator":"underline"},
         "groups":{"status":{"style":{"spacing":9}}},
         "widgets":[{"id":"clock","type":"clock","position":"right","role":"time","style":{"foreground":"#ffffff","iconSize":12}},
                    {"id":"note","type":"text","position":"left","text":"Keep","style":{"background":"#111111","width":90}}]}
        """##)
        defer { fixture.close() }
        let main = try fixture.document()
        let theme: [String: ConfigurationValue] = [
            "tokens": .object(["text": .string("#444444")]),
            "bar": .object(["appearance": .string("light"), "style": .object(["cornerRadius": .number(0)])]),
            "defaults": .object(["background": .string("#ffffff")]),
            "popupDefaults": .object(["fontWeight": .string("regular")]),
            "roles": .object(["time": .object(["foreground": .string("#000000")])]),
            "workspaceDefaults": .object(["indicator": .string("background")]),
            "groups": .object(["status": .object(["style": .object(["spacing": .number(4)])])])
        ]
        var loader = ConfigurationLoader()
        let configuration = try loader.load(fixture.url)
        let overrides = ThemeOverrides(main: main, theme: theme, widgets: configuration.widgets)
        XCTAssertEqual(overrides.values.count, 10)
        XCTAssertTrue(overrides.values.contains { $0.title == "Text: Light color" })
        XCTAssertTrue(overrides.values.contains { $0.title == "Workspaces: Indicator" })
        var ids = configuration.widgets.map(\.id)
        let reset = try overrides.resetEdit.applying(to: main, widgetIDs: &ids)
        XCTAssertEqual(overrides.resetEdit.action, .unset)
        XCTAssertEqual(reset["bar"], .object(["appearance": .string("dark")]))
        XCTAssertEqual(reset["tokens"], .object(["custom": .string("#333333")]))
        XCTAssertEqual(reset["defaults"], .object(["fontSize": .number(18)]))
        XCTAssertNil(reset["roles"])
        let widgets = try reset["widgets"]!.decoded([[String: ConfigurationValue]].self)
        XCTAssertEqual(widgets[0]["style"], .object(["iconSize": .number(12)]))
        XCTAssertEqual(widgets[1]["style"], .object(["width": .number(90)]))
        XCTAssertEqual(widgets[1]["text"], .string("Keep"))
        XCTAssertEqual(try fixture.document(), main)
    }

    @MainActor func testResetIsOneSavedUndoableChangeAndLeavesIncludedFilesAndCommandLineEditsAlone() throws {
        let fixture = try ThemeGalleryFixture(##"""
        {"includes":["included.json"],"theme":{"id":"test-theme","version":"1"},"bar":{"height":48,"appearance":"dark"},
         "tokens":{"text":"#112233"},"widgets":[{"id":"clock","type":"clock","position":"right","style":{"foreground":"#ffffff"}}],
         "widgetOverrides":{"included":{"style":{"foreground":"#ffffff"}}},
         "profiles":[{"name":"active","configuration":{"bar":{"spacing":17}}}]}
        """##)
        defer { fixture.close() }
        _ = try fixture.theme(##"{"bar":{"height":32,"spacing":4},"tokens":{"text":"#334455"},"defaults":{"foreground":"@token.text"}}"##)
        let includedURL = fixture.directory.appending(path: "included.json")
        try fixture.write(#"{"widgets":[{"id":"included","type":"text","position":"left","text":"Included"}]}"#, to: includedURL)
        let included = try Data(contentsOf: includedURL)
        let original = try Data(contentsOf: fixture.url)
        let store = try fixture.store()
        defer { store.stop() }
        try store.setSessionEdits([ConfigurationEdit(action: .bar, properties: ["margin": .number(11)])])
        let gallery = ThemeGallery(store: store)
        gallery.refresh()
        XCTAssertEqual(gallery.overrides.values.count, 5)
        try store.customizationHistory.change(gallery.overrides.resetEdit)
        XCTAssertEqual(store.customizationHistory.undoSteps.count, 1)
        XCTAssertFalse(store.customizationHistory.hasPendingChanges)
        XCTAssertEqual(store.configuration?.bar.height, 32)
        XCTAssertEqual(store.configuration?.bar.spacing, 4)
        XCTAssertEqual(store.configuration?.bar.margin, 11)
        XCTAssertNil(try fixture.document()["bar"]?.decoded([String: ConfigurationValue].self)["margin"])
        gallery.refresh()
        XCTAssertTrue(gallery.overrides.values.isEmpty)
        XCTAssertEqual(try Data(contentsOf: includedURL), included)
        try store.customizationHistory.undo()
        XCTAssertEqual(try Data(contentsOf: fixture.url), original)
        XCTAssertEqual(store.sessionEdits.count, 1)
    }
}
