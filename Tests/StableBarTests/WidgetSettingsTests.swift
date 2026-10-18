import XCTest
@testable import StableBar

final class WidgetSettingsTests: XCTestCase {
    func testWorkspacesKeepTheirOwnClicksAndSpacerHasNoClickControl() throws {
        for properties: [String: ConfigurationValue] in [[:], ["open": .string("com.apple.iCal")], ["onClick": .string("echo keep")]] {
            let workspaces = try widget(properties.merging(["type": .string("workspaces")]) { $1 })
            let spacer = try widget(properties.merging(["type": .string("spacer")]) { $1 })
            XCTAssertEqual(WidgetClickChoice.control(for: workspaces), .explanation("Clicking a workspace switches to it."))
            XCTAssertEqual(WidgetClickChoice.control(for: spacer), .hidden)
            for widget in [workspaces, spacer] {
                XCTAssertEqual(WidgetClickChoice.current(for: widget), .advanced)
                for choice in WidgetClickChoice.allCases {
                    XCTAssertThrowsError(try choice.properties(for: widget, value: "com.apple.iCal"))
                }
            }
        }
        XCTAssertEqual(WidgetClickChoice.control(for: try widget()), .choices)
    }

    func testClickChoicesMapOnlyTheOpenPropertyAndRoundTrip() throws {
        let widget = try widget()
        XCTAssertEqual(WidgetClickChoice.current(for: widget), .nothing)
        for (choice, value) in [(WidgetClickChoice.application, "com.apple.iCal"), (.webPage, "https://example.com/events")] {
            let properties = try choice.properties(for: widget, value: value)
            XCTAssertEqual(properties, ["open": .string(value)])
            XCTAssertEqual(WidgetClickChoice.current(for: try self.widget(properties)), choice)
        }
        XCTAssertEqual(try WidgetClickChoice.nothing.properties(for: widget), ["open": .null])
        XCTAssertThrowsError(try WidgetClickChoice.application.properties(for: widget, value: "/Applications/Calendar.app"))
        for value in ["example.com", "file:///tmp", "https://", "mailto:user@example.com"] {
            XCTAssertThrowsError(try WidgetClickChoice.webPage.properties(for: widget, value: value))
        }
        let link = try self.widget(["open": .string("mailto:user@example.com")])
        XCTAssertEqual(WidgetClickChoice.current(for: link), .advanced)
        XCTAssertThrowsError(try WidgetClickChoice.nothing.properties(for: link))
    }

    func testCommandsPopupsAndMenusCanNeverBeSilentlyRemovedByAnyChoice() throws {
        for existing: [String: ConfigurationValue] in [
            ["onClick": .string("echo keep")],
            ["popup": .object(["style": .object([:]), "layout": .object(["type": .string("text"), "text": .string("Details")])])],
            ["popupName": .string("details")],
            ["menu": .array([])]
        ] {
            let widget = try widget(existing)
            XCTAssertEqual(WidgetClickChoice.current(for: widget), .advanced)
            XCTAssertNotNil(WidgetClickChoice.explanation(for: widget))
            for choice in WidgetClickChoice.allCases {
                XCTAssertThrowsError(try choice.properties(for: widget, value: "https://example.com"))
            }
        }
    }

    func testClickCommandsAndMenusFromLiveOutputAlsoStayUnderAdvanced() throws {
        let widget = try widget()
        for json in [#"{"text":"Live","onClick":"echo live"}"#, #"{"text":"Live","menu":[{"title":"Keep","onClick":"echo keep"}]}"#] {
            let output = try JSONDecoder().decode(ScriptOutput.self, from: Data(json.utf8))
            XCTAssertEqual(WidgetClickChoice.current(for: widget, output: output), .advanced)
            XCTAssertNotNil(WidgetClickChoice.explanation(for: widget, output: output))
            XCTAssertThrowsError(try WidgetClickChoice.nothing.properties(for: widget, output: output))
            XCTAssertThrowsError(try WidgetClickChoice.application.properties(for: widget, value: "com.apple.iCal", output: output))
            XCTAssertThrowsError(try WidgetClickChoice.webPage.properties(for: widget, value: "https://example.com", output: output))
        }
    }

    func testAllScreenChoicesRoundTripAndSpecificScreensStayAdvanced() throws {
        for choice in WidgetScreenChoice.allCases where choice != .specific {
            let properties = try XCTUnwrap(choice.properties)
            let widget = try widget(properties)
            XCTAssertEqual(WidgetScreenChoice(widget.display), choice)
            XCTAssertEqual(properties.keys.sorted(), ["display"])
        }
        let widget = try widget(["display": .array([.number(1), .number(3)])])
        XCTAssertEqual(WidgetScreenChoice(widget.display), .specific)
        XCTAssertNil(WidgetScreenChoice.specific.properties)
        XCTAssertEqual(widget.display, .ids([1, 3]))
    }

    func testCommonClockFormatsRemainValidAndCustomFormatsAreAccepted() throws {
        XCTAssertEqual(Set(WidgetClockFormat.common.map(\.value)).count, WidgetClockFormat.common.count)
        for format in WidgetClockFormat.common.map(\.value) + ["yyyy-MM-dd 'at' HH:mm"] {
            let clock = try widget(["type": .string("clock"), "format": .string(format)])
            XCTAssertEqual(clock.content, .clock(format: format))
            XCTAssertFalse(clock.label(output: nil, activeApp: nil, date: .now).text.isEmpty)
        }
    }

    private func widget(_ properties: [String: ConfigurationValue] = [:]) throws -> WidgetConfiguration {
        try ConfigurationValue.object(["id": .string("test"), "type": .string("text"), "text": .string("Test"), "position": .string("left")].merging(properties) { $1 }).decoded(WidgetConfiguration.self)
    }
}
