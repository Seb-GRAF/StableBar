import AppKit
import Testing
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
        XCTAssertEqual(bundled.count, 6)
        XCTAssertEqual(choices.last?.key, installed.key)
        XCTAssertEqual(choices.last?.edit.properties, installed.selection)
        XCTAssertEqual(themeChoices(packages: fixture.packages.directory, themesDirectory: fixture.themes).map(\.key), Array(choices.dropFirst()).map(\.key))
    }

    func testSamplesUseOnlyTheThemeAndDifferBetweenBuiltInNordCatppuccinAndPhosphor() throws {
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
        let nord = try XCTUnwrap(looks["nord"])
        XCTAssertNil(builtIn.bar.style.background)
        XCTAssertNotNil(builtIn.defaults.background)
        XCTAssertNotNil(nord.bar.style.background)
        XCTAssertNil(nord.defaults.background)
        let catppuccin = try XCTUnwrap(looks["catppuccin"])
        let phosphor = try XCTUnwrap(looks["phosphor"])
        XCTAssertEqual(catppuccin.defaults.cornerRadius, 14)
        XCTAssertEqual(phosphor.defaults.cornerRadius, 0)
        XCTAssertNotEqual(catppuccin.defaults.accent, phosphor.defaults.accent)
        XCTAssertEqual(phosphor.defaults.fontName, "Monaco")
    }

    func testLemanInsetsItsFocusedTintWithoutChangingPopupsAndCatppuccinDrawsAPill() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let choices = ThemeCatalog(packages: fixture.packages.directory, themesDirectory: fixture.themes).choices
        func look(_ id: String) throws -> Configuration {
            try ThemePreview(choice: XCTUnwrap(choices.first { $0.key == id }), themesDirectory: fixture.themes).light
        }
        func workspaceCornerRadius(_ look: Configuration) -> ConfigurationValue? {
            guard case .object(let style)? = look.workspaceDefaults.properties["style"] else { return nil }
            return style["cornerRadius"]
        }
        let leman = try look("leman")
        XCTAssertEqual(leman.defaults.paddingVertical, 3)
        let popupDefaults = leman.popupDefaults.popupStyle(over: leman.defaults)
        XCTAssertNil(popupDefaults.paddingVertical)
        XCTAssertEqual(tooltipStyle(defaults: popupDefaults, widget: WidgetStyle()).paddingVertical, 6)
        XCTAssertEqual(workspaceCornerRadius(leman), .number(7))
        XCTAssertEqual(workspaceCornerRadius(try look("catppuccin")), .number(14))
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

@Test func eachInstalledThemeShowsOnceAtItsSelectedOrNewestVersion() throws {
    let fixture = try ThemeGalleryFixture()
    defer { fixture.close() }
    for version in ["1.2.0", "1.10.0", "1.9.0"] { _ = try fixture.theme("{}", version: version) }
    let choices = themeChoices(packages: fixture.packages.directory, themesDirectory: nil)
    func versions(keeping selected: Set<String>) -> [String] {
        choices.onePerTheme(keeping: selected).map(\.manifest.version)
    }
    #expect(versions(keeping: []) == ["1.10.0"])
    #expect(versions(keeping: ["test-theme/1.2.0"]) == ["1.2.0"])
    #expect(versions(keeping: ["test-theme/1.2.0", "test-theme/1.9.0"]) == ["1.2.0", "1.9.0"])
}
