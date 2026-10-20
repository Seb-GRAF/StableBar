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
        XCTAssertEqual(bundled.count, 5)
        XCTAssertEqual(choices.last?.key, installed.key)
        XCTAssertEqual(choices.last?.edit.properties, installed.selection)
        XCTAssertEqual(themeChoices(packages: fixture.packages.directory, themesDirectory: fixture.themes).map(\.key), Array(choices.dropFirst()).map(\.key))
    }

    func testSamplesUseOnlyTheThemeAndDifferBetweenBuiltInEverforestRosePineAndBlueprint() throws {
        let fixture = try ThemeGalleryFixture(##"{"defaults":{"fontSize":99},"bar":{"margin":90},"widgets":[]}"##)
        defer { fixture.close() }
        let choices = ThemeCatalog(packages: fixture.packages.directory, themesDirectory: fixture.themes).choices
        var looks: [String: Configuration] = [:]
        for choice in choices {
            let preview = try ThemePreview(choice: choice, themesDirectory: fixture.themes)
            looks[choice.key] = preview.light
            XCTAssertTrue(preview.light.widgets.isEmpty)
            XCTAssertTrue(preview.dark.widgets.isEmpty)
            XCTAssertTrue(preview.light.providers.isEmpty)
            XCTAssertNotEqual(preview.light.defaults.fontSize, 99)
            XCTAssertNotEqual(preview.light.bar.margin, 90)
        }
        let builtIn = try XCTUnwrap(looks["built-in"])
        let everforest = try XCTUnwrap(looks["everforest"])
        XCTAssertNil(builtIn.bar.style.background)
        XCTAssertNotNil(builtIn.defaults.background)
        XCTAssertNotNil(everforest.bar.style.background)
        XCTAssertNil(everforest.defaults.background)
        let rosePine = try XCTUnwrap(looks["rose-pine"])
        let blueprint = try XCTUnwrap(looks["blueprint"])
        XCTAssertEqual(rosePine.defaults.cornerRadius, 13)
        XCTAssertEqual(blueprint.defaults.cornerRadius, 2)
        XCTAssertNotEqual(rosePine.defaults.accent, blueprint.defaults.accent)
        XCTAssertEqual(blueprint.defaults.fontName, "Menlo")
    }

    func testDownloadedThemeUsesItsConfigurationOverBuiltInWithoutUserLayers() throws {
        let fixture = try ThemeGalleryFixture(##"{"includes":["missing.json"],"defaults":{"fontSize":99},"widgets":[]}"##)
        defer { fixture.close() }
        let choice = try fixture.theme(##"{"tokens":{"text":"#123456"},"bar":{"height":29,"style":{"cornerRadius":7}},"defaults":{"foreground":"@token.text","fontSize":14}}"##, install: false)
        let preview = try ThemePreview(choice: choice, themesDirectory: fixture.themes)
        for look in [preview.light, preview.dark] {
            XCTAssertEqual(look.defaults.foreground, HexColor(0x123456ff))
            XCTAssertEqual(look.defaults.fontSize, 14)
            XCTAssertEqual(look.bar.height, 29)
            XCTAssertEqual(look.bar.style.cornerRadius, 7)
            XCTAssertNotNil(look.defaults.background, "Unspecified styling inherits Built-in")
            XCTAssertTrue(look.widgets.isEmpty)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.packages.directory.path))
    }

    func testSampleCachesLightAndDarkThemeProfilesAndRoleAndWorkspaceStyles() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let choice = try fixture.theme(##"{"roles":{"time":{"fontSize":18}},"workspaceDefaults":{"indicator":"underline","indicatorStyle":{"height":3,"placement":"belowBar"}},"profiles":[{"name":"night","when":{"appearance":"dark"},"configuration":{"bar":{"height":30}}}]}"##, install: false)
        let preview = try ThemePreview(choice: choice, themesDirectory: fixture.themes)
        XCTAssertEqual(preview.configuration(for: .light).bar.height, 40)
        XCTAssertEqual(preview.configuration(for: .dark).bar.height, 30)
        XCTAssertEqual(preview.light.roleStyle(.time).fontSize, 18)
        let workspace = try XCTUnwrap(preview.light.workspaceDefaults.merging(nil))
        XCTAssertEqual(workspace.indicator, .underline)
        XCTAssertEqual(workspace.cellStyle(.focused).underline.height, 3)
        XCTAssertEqual(workspace.cellStyle(.focused).underline.placement, .belowBar)
    }
}
