import XCTest
@testable import StableBar

final class ConfigurationEditsTests: XCTestCase {
    func testTheEarlierStarterAppleLogoBecomesAnAppleMenuThatStillOpensSystemSettings() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let logo = #""type": "text", "text": "", "icon": "apple.logo", "onClick": "open -a 'System Settings'""#
        try Data(#"""
        {
          "bar": { "height": 40, "inset": 12 },
          "widgets": [
            {
              "id": "system",
              "type": "text",
              "position": "left",
              "text": "",
              "icon": "apple.logo",
              "onClick": "open -a 'System Settings'"
            },
            { "id": "styled", "position": "right", \#(logo), "style": { "foreground": "#ff8800" }, "enabled": false, "tooltip": "Settings" },
            { "id": "timed", "position": "left", \#(logo), "timeout": 5 },
            { "id": "finder", "position": "left", "type": "text", "text": "", "icon": "apple.logo", "onClick": "open -a Finder" },
            { "id": "clock", "type": "clock", "position": "right" }
          ]
        }
        """#.utf8).write(to: url)
        try migrateStarterAppleLogo(url)
        let migrated = try Data(contentsOf: url)
        let configuration = try JSONDecoder().decode(Configuration.self, from: migrated)
        XCTAssertEqual(configuration.widgets.map(\.id), ["system", "styled", "timed", "finder", "clock"])
        for widget in configuration.widgets.prefix(2) {
            XCTAssertEqual(widget.content, .appleMenu(click: .systemSettings))
            XCTAssertNil(widget.icon)
            XCTAssertNil(widget.onClick)
        }
        XCTAssertEqual(configuration.widgets[0].position, .left)
        XCTAssertEqual(configuration.widgets[1].position, .right)
        XCTAssertEqual(configuration.widgets[1].style.foreground, HexColor(0xff8800ff))
        XCTAssertFalse(configuration.widgets[1].enabled)
        XCTAssertEqual(configuration.widgets[1].tooltip, "Settings")
        XCTAssertEqual(configuration.widgets[2].content, .text(""), "A command timeout is more than the starter had")
        XCTAssertEqual(configuration.widgets[3].onClick, "open -a Finder")
        let text = String(decoding: migrated, as: UTF8.self)
        XCTAssertTrue(text.contains(#""bar": { "height": 40, "inset": 12 }"#), text)
        XCTAssertTrue(text.contains(#"{ "id": "clock", "type": "clock", "position": "right" }"#), text)

        try migrateStarterAppleLogo(url)
        XCTAssertEqual(try Data(contentsOf: url), migrated, "A converted file isn't written again")
    }

    func testAGradientEditReplacesASavedColorPairInsteadOfMergingWithIt() throws {
        let gradient: ConfigurationValue = .object(["gradient": .object(["colors": .array([.string("#111111"), .string("#222222")])])])
        let main: [String: ConfigurationValue] = [
            "defaults": .object(["background": .object(["light": .string("#444444"), "dark": .string("#555555")]), "fontSize": .number(12)])
        ]
        var ids: [String] = []
        let result = try ConfigurationEdit(action: .defaults, properties: ["background": gradient]).applying(to: main, widgetIDs: &ids)
        XCTAssertEqual(result["defaults"], .object(["background": gradient, "fontSize": .number(12)]))
    }

    func testRootUnsetAddressesWidgetsAndProfilesByNameAndKeepsRequiredProfileConfiguration() throws {
        let main: [String: ConfigurationValue] = [
            "widgets": .array([.object(["id": .string("clock"), "style": .object(["foreground": .string("#ffffff")])])]),
            "profiles": .array([.object(["name": .string("night"), "configuration": .object(["bar": .object(["height": .number(40)])])])])
        ]
        let edit = ConfigurationEdit(action: .unset, properties: [
            "widgets": .object(["clock": .object(["style": .object(["foreground": .null])])]),
            "profiles": .object(["night": .object(["configuration": .object(["bar": .object(["height": .null])])])])
        ])
        var ids = ["clock"]
        let result = try edit.applying(to: main, widgetIDs: &ids)
        XCTAssertEqual(result["widgets"], .array([.object(["id": .string("clock")])]))
        XCTAssertEqual(result["profiles"], .array([.object(["name": .string("night"), "configuration": .object([:])])]))
        XCTAssertEqual(try result["profiles"]?.decoded([ConfigurationProfile].self).first?.configuration, [:])
    }

    func testUnsetRemovesEmptyUnrelatedConfigurationKeysAndLeavesOtherValues() throws {
        let nested: ConfigurationValue = .object(["configuration": .object(["height": .number(40)]), "keep": .bool(true)])
        let main: [String: ConfigurationValue] = [
            "tokens": .object(["custom": nested]),
            "widgets": .array([.object(["id": .string("clock"), "custom": nested])]),
            "profiles": .array([.object(["name": .string("night"), "configuration": .object(["tokens": .object(["custom": nested])])])])
        ]
        let mask: ConfigurationValue = .object(["configuration": .object(["height": .null])])
        var ids = ["clock"]
        let result = try ConfigurationEdit(action: .unset, properties: [
            "tokens": .object(["custom": mask]), "widgets": .object(["clock": .object(["custom": mask])]),
            "profiles": .object(["night": .object(["configuration": .object(["tokens": .object(["custom": mask])])])])
        ]).applying(to: main, widgetIDs: &ids)
        XCTAssertEqual(try result["tokens"]?.decoded([String: ConfigurationValue].self)["custom"], .object(["keep": .bool(true)]))
        let widget = try XCTUnwrap(result["widgets"]?.decoded([[String: ConfigurationValue]].self).first)
        XCTAssertEqual(widget["custom"], .object(["keep": .bool(true)]))
        let profile = try XCTUnwrap(result["profiles"]?.decoded([ConfigurationProfile].self).first)
        XCTAssertEqual(profile.configuration["tokens"], .object(["custom": .object(["keep": .bool(true)])]))
        let byID = try ConfigurationEdit(action: .unset, id: "clock", properties: ["custom": mask]).applying(to: main, widgetIDs: &ids)
        XCTAssertEqual(try byID["widgets"]?.decoded([[String: ConfigurationValue]].self).first?["custom"], .object(["keep": .bool(true)]))
    }

    func testUnsetDoesNotAddressUnrelatedNestedArraysByName() throws {
        let main: [String: ConfigurationValue] = ["tokens": .object([
            "custom": .object(["profiles": .array([.object(["name": .string("nested"), "configuration": .object(["height": .number(40)])])])])
        ])]
        let edit = ConfigurationEdit(action: .unset, properties: ["tokens": .object([
            "custom": .object(["profiles": .object(["nested": .object(["configuration": .object(["height": .null])])])])
        ])])
        var ids: [String] = []
        XCTAssertEqual(try edit.applying(to: main, widgetIDs: &ids), main)
    }

    func testPackageSourceEditsUpsertAndRemoveByID() throws {
        var ids: [String] = []
        let acme: [String: ConfigurationValue] = ["id": .string("acme"), "name": .string("Acme"), "url": .string("https://a.example/index.json")]
        var root = try ConfigurationEdit(action: .packageSource, properties: acme).applying(to: [:], widgetIDs: &ids)
        root = try ConfigurationEdit(action: .packageSource, properties: acme.merging(["name": .string("Acme Inc")]) { $1 }).applying(to: root, widgetIDs: &ids)
        XCTAssertEqual(root["packageSources"], .array([.object(acme.merging(["name": .string("Acme Inc")]) { $1 })]))
        root = try ConfigurationEdit(action: .packageSource, id: "acme").applying(to: root, widgetIDs: &ids)
        XCTAssertNil(root["packageSources"])
    }
}
