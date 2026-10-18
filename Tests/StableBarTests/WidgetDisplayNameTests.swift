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

    @MainActor func testPackageNamesSurviveIncludesProfilesOverridesAndReloadsWithoutConfigurationChanges() throws {
        let fixture = try ThemeGalleryFixture(#"{"packages":[{"id":"weather","version":"1"}],"profile":"extra","widgetOverrides":{"current":{"position":"right"}},"widgets":[{"id":"widget-1a2b3c4d","type":"clock","position":"left"}]}"#)
        defer { fixture.close() }
        let package = fixture.packages.directory.appending(path: "weather/1")
        try fixture.write(#"{"id":"weather","name":"Weather","version":"1","entry":"config.json"}"#, to: package.appending(path: "package.json"))
        try fixture.write(#"{"includes":["widgets.json"],"profiles":[{"name":"extra","configuration":{"widgets":[{"id":"forecast","type":"text","text":"Tomorrow","position":"left"}]}}]}"#, to: package.appending(path: "config.json"))
        try fixture.write(#"{"widgets":[{"id":"current","type":"text","text":"Today","position":"left"}]}"#, to: package.appending(path: "widgets.json"))
        let before = try Data(contentsOf: fixture.url)
        let store = try fixture.store()
        defer { store.stop() }
        XCTAssertEqual(store.widgetPackageNames, ["current": "Weather", "forecast": "Weather"])
        for widget in try XCTUnwrap(store.configuration?.widgets) {
            XCTAssertEqual(WidgetDisplayName.name(for: widget, packageName: store.widgetPackageNames[widget.id]), widget.id == "widget-1a2b3c4d" ? "Clock" : "Weather")
        }
        store.reloadConfiguration()
        XCTAssertEqual(store.widgetPackageNames, ["current": "Weather", "forecast": "Weather"])
        try fixture.write(#"{"id":"weather","name":"Forecast","version":"1","entry":"config.json"}"#, to: package.appending(path: "package.json"))
        store.reloadConfiguration()
        XCTAssertEqual(store.widgetPackageNames, ["current": "Forecast", "forecast": "Forecast"])
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
        XCTAssertTrue(store.customizationHistory.undoSteps.isEmpty)
    }
}
