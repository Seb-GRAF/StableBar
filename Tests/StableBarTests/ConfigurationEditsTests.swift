import XCTest
@testable import StableBar

final class ConfigurationEditsTests: XCTestCase {
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
}
