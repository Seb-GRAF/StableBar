import AppKit
import Testing
import XCTest
@testable import StableBar

final class ThemePreviewTests: XCTestCase {
    func testCatalogListsTheIncludedThemesInOrderThenInstalledVersionsAndARetiredOneOnlyWhileSelected() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let installed = try fixture.theme(#"{}"#)
        let included = ["clear", "glass", "tonal", "slim", "dot", "gloss", "sticker"]
        let choices = ThemeCatalog(packages: fixture.packages.directory, themesDirectory: fixture.themes).choices
        XCTAssertEqual(choices.map(\.key), included + [installed.key])
        XCTAssertEqual(choices.map(\.title), ["Clear", "Glass", "Tonal", "Slim", "Dot", "Gloss", "Sticker", "Test theme · 1"])
        XCTAssertEqual(choices.first?.edit.properties, ["id": .string("clear")])
        XCTAssertEqual(choices.last?.edit.properties, installed.selection)
        for retired in ["built-in", "nord", "slate"] {
            let selected = ThemeCatalog(packages: fixture.packages.directory, themesDirectory: fixture.themes, selectedKey: retired).choices
            XCTAssertEqual(selected.map(\.key), included + [retired, installed.key])
            XCTAssertEqual(selected[included.count].title, "Custom")
        }
        let builtIn = ThemeCatalog(packages: fixture.packages.directory, themesDirectory: fixture.themes, selectedKey: "built-in").choices
        XCTAssertNil(try XCTUnwrap(builtIn.first { $0.isBuiltIn }).edit.properties)
    }

    func testSamplesUseOnlyTheThemeAndDifferBetweenBuiltInGlassSlimAndGloss() throws {
        let fixture = try ThemeGalleryFixture(##"{"defaults":{"fontSize":99},"bar":{"margin":90},"widgets":[]}"##)
        defer { fixture.close() }
        let choices = ThemeCatalog(packages: fixture.packages.directory, themesDirectory: fixture.themes, selectedKey: "built-in").choices
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
        let glass = try XCTUnwrap(looks["glass"])
        XCTAssertNil(builtIn.bar.style.background)
        XCTAssertNotNil(builtIn.defaults.background)
        XCTAssertNotNil(glass.bar.style.background)
        XCTAssertNil(glass.defaults.background)
        let slim = try XCTUnwrap(looks["slim"])
        let gloss = try XCTUnwrap(looks["gloss"])
        XCTAssertNotEqual(slim.defaults.accent, gloss.defaults.accent)
        XCTAssertEqual(slim.defaults.fontName, "Menlo")
        XCTAssertEqual(gloss.defaults.fontName, "Lucida Grande")
    }

    func testLemanInsetsItsFocusedTintWithoutChangingPopupsAndCatppuccinDrawsAPill() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        func look(_ id: String) throws -> Configuration {
            let choices = ThemeCatalog(packages: fixture.packages.directory, themesDirectory: fixture.themes, selectedKey: id).choices
            return try ThemePreview(choice: XCTUnwrap(choices.first { $0.key == id }), themesDirectory: fixture.themes).light
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
    for version in ["1.2.0", "1.10", "1.10.0", "1.9.0"] { _ = try fixture.theme("{}", version: version) }
    let choices = themeChoices(packages: fixture.packages.directory, themesDirectory: nil)
    func versions(keeping selected: Set<String>) -> [String] {
        choices.onePerTheme(keeping: selected).map(\.manifest.version)
    }
    #expect(versions(keeping: []) == ["1.10.0"])
    #expect(versions(keeping: ["test-theme/1.2.0"]) == ["1.2.0"])
    #expect(versions(keeping: ["test-theme/1.2.0", "test-theme/1.9.0"]) == ["1.2.0", "1.9.0"])
}
