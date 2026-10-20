import XCTest
@testable import StableBar

final class WidgetDisplayNameTests: XCTestCase {
    func testEveryBuiltInUsesTheAddListNameInsteadOfItsGeneratedID() throws {
        for choice in WidgetAddCatalog.builtIns {
            let properties = try XCTUnwrap(choice.add(position: .right, id: "widget-1a2b3c4d")?.properties)
            let widget = try ConfigurationValue.object(properties).decoded(WidgetConfiguration.self)
            XCTAssertEqual(WidgetDisplayName.title(for: widget.content), choice.name)
            XCTAssertEqual(WidgetDisplayName.name(for: widget), choice.id == "text" ? "New widget" : choice.name)
            XCTAssertEqual(widget.id, "widget-1a2b3c4d")
        }
    }

    func testProviderAliasesUseTheirDataSourceAndCustomSourcesUseAPlainFallback() throws {
        let provider = try ConfigurationValue.object(["type": .string("system")]).decoded(ProviderConfiguration.self)
        XCTAssertEqual(WidgetDisplayName.title(for: .provider("usage"), providers: ["usage": provider]), "CPU")
        XCTAssertEqual(WidgetDisplayName.title(for: .provider("script-1234")), "Custom widget")
    }

    func testTextNamesUseShortReadableTextAndPackageNamesTakePrecedence() throws {
        for (text, expected) in [("  Hello  ", "Hello"), ("", "Text"), (" \n ", "Text"), ("Hello\nworld", "Text"), (String(repeating: "a", count: 61), "Text")] {
            let widget = try ConfigurationValue.object(["id": .string("widget-1a2b3c4d"), "type": .string("text"), "text": .string(text), "position": .string("right")]).decoded(WidgetConfiguration.self)
            XCTAssertEqual(WidgetDisplayName.name(for: widget), expected)
            XCTAssertEqual(WidgetDisplayName.name(for: widget, packageName: "Weather"), "Weather")
            XCTAssertEqual(WidgetDisplayName.name(for: widget, packageName: "  "), expected)
        }
    }

    func testUserChosenIDsStayAsWrittenAndPackageWidgetsUseTheirPackageName() throws {
        for id in ["music", "My clock", "widget-1234567", "widget-123456789", "widget-1234567g", "prefix-widget-12345678", "widget-12345678\n"] {
            let widget = try ConfigurationValue.object(["id": .string(id), "type": .string("text"), "text": .string("Other name"), "position": .string("right")]).decoded(WidgetConfiguration.self)
            XCTAssertEqual(WidgetDisplayName.name(for: widget), id)
            XCTAssertEqual(WidgetDisplayName.name(for: widget, packageName: "Weather"), "Weather")
        }
        let generated = try widgets(#"[{"id":"widget-ABCDEF12","type":"clock","position":"right"}]"#)
        XCTAssertEqual(WidgetDisplayName.names(for: generated), ["widget-ABCDEF12": "Clock"])
    }

    func testMatchingGeneratedNamesAreUniqueAcrossPositionsAndAvoidChosenNames() throws {
        let widgets = try widgets(#"""
        [{"id":"widget-00000001","type":"clock","position":"left"},
         {"id":"widget-00000002","type":"clock","position":"right"},
         {"id":"Clock","type":"clock","position":"right"},
         {"id":"Clock 1","type":"clock","position":"right"},
         {"id":"widget-00000003","type":"text","text":"Clock 2","position":"right"},
         {"id":"widget-00000004","type":"text","text":"Hello","position":"left"},
         {"id":"widget-00000005","type":"text","text":"Hello","position":"right"}]
        """#)
        let names = WidgetDisplayName.names(for: widgets)
        XCTAssertEqual(names, ["widget-00000001": "Clock 3", "widget-00000002": "Clock 4", "Clock": "Clock", "Clock 1": "Clock 1",
                               "widget-00000003": "Clock 2", "widget-00000004": "Hello 1", "widget-00000005": "Hello 2"])
        XCTAssertEqual(Set(names.values).count, widgets.count)
        for widget in widgets where widget.id.hasPrefix("widget-") { XCTAssertFalse(try XCTUnwrap(names[widget.id]).contains(widget.id)) }
    }

    func testGeneratedScriptProviderAndPackageWidgetsHaveDistinctNames() throws {
        let widgets = try widgets(#"""
        [{"id":"widget-00000001","type":"script","command":"echo first","position":"left"},
         {"id":"widget-00000002","type":"script","command":"echo second","position":"right"},
         {"id":"widget-00000003","type":"provider","provider":"sample","position":"left"},
         {"id":"widget-00000004","type":"provider","provider":"live","position":"right"},
         {"id":"widget-00000005","type":"text","text":"Today","position":"left"},
         {"id":"widget-00000006","type":"text","text":"Tomorrow","position":"right"}]
        """#)
        let providers = ["sample": ProviderConfiguration(type: "command"), "live": ProviderConfiguration(type: "stream")]
        let names = WidgetDisplayName.names(for: widgets, packageNames: ["widget-00000005": "Weather", "widget-00000006": "Weather"], providers: providers)
        XCTAssertEqual(names, ["widget-00000001": "Script 1", "widget-00000002": "Script 2", "widget-00000003": "Custom widget 1",
                               "widget-00000004": "Custom widget 2", "widget-00000005": "Weather 1", "widget-00000006": "Weather 2"])
        XCTAssertEqual(Set(names.values).count, widgets.count)
        XCTAssertTrue(Set(names.keys).isDisjoint(with: Set(names.values)))
    }

    func testPresentationExamplesElevenSampleWidgetsKeepTheirDistinctChosenNames() throws {
        let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let configuration = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: repository.appending(path: "examples/presentation/config.json")))
        let names = WidgetDisplayName.names(for: configuration.widgets, providers: configuration.providers)
        let sample = configuration.widgets.filter { $0.providerName == "sample" }
        XCTAssertEqual(sample.map(\.id), ["music", "meeting", "cpu", "memory", "network", "status", "mail", "focus", "weather", "volume", "battery"])
        XCTAssertEqual(sample.compactMap { names[$0.id] }, sample.map(\.id))
        XCTAssertEqual(Set(names.values).count, configuration.widgets.count)
    }

    func testInspectorSubtitlesNeverRepeatWidgetForCommandStreamOrUnknownProviders() {
        let providers = ["sample": ProviderConfiguration(type: "command"), "live": ProviderConfiguration(type: "stream")]
        for name in ["sample", "live", "unknown"] {
            XCTAssertEqual(WidgetDisplayName.subtitle(for: .provider(name), providers: providers), "Custom widget")
        }
        XCTAssertEqual(WidgetDisplayName.subtitle(for: .clock(format: "HH:mm")), "Clock widget")
        XCTAssertEqual(WidgetDisplayName.subtitle(for: .script(command: "echo test", interval: nil)), "Script widget")
    }

    @MainActor func testPackageNamesSurviveIncludesProfilesOverridesAndReloadsWithoutConfigurationChanges() throws {
        let fixture = try ThemeGalleryFixture(#"{"packages":[{"id":"weather","version":"1"}],"profile":"extra","widgetOverrides":{"current":{"position":"right"}},"widgets":[{"id":"widget-1a2b3c4d","type":"clock","position":"left"}]}"#)
        defer { fixture.close() }
        let package = fixture.packages.directory.appending(path: "weather/1")
        try fixture.write(#"{"id":"weather","name":"Weather","version":"1","entry":"config.json"}"#, to: package.appending(path: "package.json"))
        try fixture.write(#"{"includes":["widgets.json"],"profiles":[{"name":"extra","configuration":{"widgets":[{"id":"forecast","type":"text","text":"Tomorrow","position":"left"}]}}]}"#, to: package.appending(path: "config.json"))
        try fixture.write(#"{"widgets":[{"id":"current","type":"text","text":"Today","position":"left"},{"id":"widget-00000001","type":"text","text":"Weather now","position":"right"}]}"#, to: package.appending(path: "widgets.json"))
        let before = try Data(contentsOf: fixture.url)
        let store = try fixture.store()
        defer { store.stop() }
        XCTAssertEqual(store.widgetPackageNames, ["current": "Weather", "forecast": "Weather", "widget-00000001": "Weather"])
        for widget in try XCTUnwrap(store.configuration?.widgets) {
            let expected = widget.id == "widget-1a2b3c4d" ? "Clock" : "Weather"
            XCTAssertEqual(WidgetDisplayName.name(for: widget, packageName: store.widgetPackageNames[widget.id]), expected)
        }
        store.reloadConfiguration()
        XCTAssertEqual(store.widgetPackageNames, ["current": "Weather", "forecast": "Weather", "widget-00000001": "Weather"])
        try fixture.write(#"{"id":"weather","name":"Forecast","version":"1","entry":"config.json"}"#, to: package.appending(path: "package.json"))
        store.reloadConfiguration()
        XCTAssertEqual(store.widgetPackageNames, ["current": "Forecast", "forecast": "Forecast", "widget-00000001": "Forecast"])
        XCTAssertEqual(WidgetDisplayName.names(for: try XCTUnwrap(store.configuration?.widgets), packageNames: store.widgetPackageNames)["widget-00000001"], "Forecast 2")
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
        XCTAssertTrue(store.customizationHistory.undoSteps.isEmpty)
    }

    private func widgets(_ json: String) throws -> [WidgetConfiguration] {
        try JSONDecoder().decode([WidgetConfiguration].self, from: Data(json.utf8))
    }
}
