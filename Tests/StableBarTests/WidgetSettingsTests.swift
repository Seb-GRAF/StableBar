import XCTest
@testable import StableBar

final class WidgetSettingsTests: XCTestCase {
    @MainActor func testProviderSettingsStayInTheEditedProfileAndPreserveTheIncludedSource() throws {
        let fixture = try ThemeGalleryFixture(#"{"includes":["source.json"],"profiles":[{"name":"work","configuration":{}}]}"#)
        defer { fixture.close() }
        let module = fixture.directory.appending(path: "source.json")
        let source = Data(#"{"providers":{"machine":{"type":"system","interval":9,"processes":3}},"widgets":[{"id":"cpu","type":"provider","provider":"machine","details":true,"position":"left"},{"id":"cpu-copy","type":"provider","provider":"machine","position":"right"}]}"#.utf8)
        try source.write(to: module)
        let store = try fixture.store()
        defer { store.stop() }
        let editor = ConfigurationEditor(store: store)
        editor.editBar(for: "work")
        let before = try fixture.document()
        editor.setProvider(["sortBy": .string("cpu"), "cpuWarning": .number(0.7)], for: store.configuration!.widgets[0])
        try editor.history.flush()
        XCTAssertNil(editor.error)
        XCTAssertEqual(store.configuration?.providers["machine"]?.sortBy, .cpu)
        XCTAssertEqual(store.configuration?.providers["machine"]?.interval, 9)
        XCTAssertEqual(store.configuration?.providers["machine"]?.processes, 3)
        XCTAssertNil(try fixture.document()["providers"])
        XCTAssertEqual(try Data(contentsOf: module), source)
        editor.undo()
        XCTAssertEqual(try fixture.document(), before)
        XCTAssertEqual(store.configuration?.providers["machine"]?.sortBy, .memory)
    }

    @MainActor func testEditingAnImplicitEssentialsProviderKeepsItsSamplingDefaults() throws {
        let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"cpu","type":"system","details":true,"position":"right"}]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let editor = ConfigurationEditor(store: store)
        editor.setProvider(["sortBy": .string("cpu")], for: store.configuration!.widgets[0])
        try editor.history.flush()
        XCTAssertNil(editor.error)
        XCTAssertEqual(store.configuration?.providers["system"]?.processes, 5)
        XCTAssertEqual(store.configuration?.providers["system"]?.interval, 2)
        XCTAssertEqual(store.configuration?.providers["system"]?.sortBy, .cpu)
        editor.undo()
        XCTAssertNil(try fixture.document()["providers"])
    }

    @MainActor func testBuiltInDetailsKeepCustomPopupAndClickActions() throws {
        let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"clock","type":"clock","details":true,"position":"left"},{"id":"open","type":"clock","details":true,"position":"left","open":"com.apple.iCal"},{"id":"command","type":"clock","details":true,"position":"left","onClick":"echo keep"},{"id":"custom","type":"clock","details":true,"position":"left","popup":{"style":{"width":220},"layout":{"type":"text","text":"Keep"}}},{"id":"plain","type":"clock","position":"left"}]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let widgets = store.configuration!.widgets
        XCTAssertNotNil(widgetPopup(widgets[0], store: store))
        XCTAssertNil(widgetPopup(widgets[1], store: store))
        XCTAssertNil(widgetPopup(widgets[2], store: store))
        XCTAssertEqual(widgetPopup(widgets[3], store: store)?.style.width, 220)
        XCTAssertNil(widgetPopup(widgets[4], store: store))
    }

    @MainActor func testMetricDisplayChoicesReplaceContentAndUndoWithoutChangingPlacementOrActions() throws {
        let fixture = try ThemeGalleryFixture(#"{"providers":{"power":{"type":"battery"}},"widgets":[{"id":"power","type":"provider","provider":"power","position":"left","open":"com.apple.systempreferences","layout":{"type":"row","style":{"spacing":8},"children":[{"type":"text","text":"Custom"}]}}]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let editor = ConfigurationEditor(store: store)
        let before = try fixture.document()
        XCTAssertEqual(WidgetMetricDisplay.current(editor.properties(for: "power")["layout"], source: "percent"), .custom)
        for choice in [WidgetMetricDisplay.graph, .icon, .meter, .value, .standard] {
            editor.set(["layout": try XCTUnwrap(choice.layout(for: "percent"))], for: "power")
            try editor.history.flush()
            XCTAssertNil(editor.error)
            XCTAssertEqual(WidgetMetricDisplay.current(editor.properties(for: "power")["layout"], source: "percent"), choice)
            XCTAssertEqual(store.configuration?.widgets.first?.position, .left)
            XCTAssertEqual(store.configuration?.widgets.first?.open, "com.apple.systempreferences")
        }
        for _ in 0..<5 { editor.undo() }
        XCTAssertEqual(try fixture.document(), before)
    }

    func testSystemStartsWithItsGraphAndKeepsIconAndValueAsAChoice() {
        XCTAssertEqual(WidgetMetricDisplay.current(nil, source: "cpu"), .graph)
        for choice in WidgetMetricDisplay.choices(for: "cpu") where choice != .custom {
            XCTAssertEqual(WidgetMetricDisplay.current(choice.layout(for: "cpu"), source: "cpu"), choice)
        }
    }

    @MainActor func testSoundStartsWithItsValueOnChangeAndKeepsIconAndValueAsAChoice() throws {
        let fixture = try ThemeGalleryFixture(#"{"providers":{"speakers":{"type":"audio"}},"widgets":[{"id":"sound","type":"provider","provider":"speakers","position":"right"}]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let editor = ConfigurationEditor(store: store)
        let before = try fixture.document()
        XCTAssertEqual(WidgetMetricDisplay.choices(for: "volume").first, .changes)
        XCTAssertFalse(WidgetMetricDisplay.choices(for: "percent").contains(.changes), "Battery has no value on change")
        XCTAssertEqual(WidgetMetricDisplay.current(editor.properties(for: "sound")["layout"], source: "volume"), .changes)
        for choice in [WidgetMetricDisplay.standard, .graph, .icon, .meter, .value, .changes] {
            editor.set(["layout": try XCTUnwrap(choice.layout(for: "volume"))], for: "sound")
            try editor.history.flush()
            XCTAssertNil(editor.error)
            XCTAssertEqual(WidgetMetricDisplay.current(editor.properties(for: "sound")["layout"], source: "volume"), choice)
        }
        XCTAssertNil(store.configuration?.widgets.first?.layout, "Value on change is the default layout")
        for _ in 0..<6 { editor.undo() }
        XCTAssertEqual(try fixture.document(), before)
    }

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

    func testCommandsPopupsAndMenusFromConfigurationOrLiveOutputCanNeverBeSilentlyRemovedByAnyChoice() throws {
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
        let plain = try widget()
        for json in [#"{"text":"Live","onClick":"echo live"}"#, #"{"text":"Live","menu":[{"title":"Keep","onClick":"echo keep"}]}"#] {
            let output = try JSONDecoder().decode(ScriptOutput.self, from: Data(json.utf8))
            XCTAssertEqual(WidgetClickChoice.current(for: plain, output: output), .advanced)
            XCTAssertNotNil(WidgetClickChoice.explanation(for: plain, output: output))
            XCTAssertThrowsError(try WidgetClickChoice.nothing.properties(for: plain, output: output))
            XCTAssertThrowsError(try WidgetClickChoice.application.properties(for: plain, value: "com.apple.iCal", output: output))
            XCTAssertThrowsError(try WidgetClickChoice.webPage.properties(for: plain, value: "https://example.com", output: output))
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

    private func widget(_ properties: [String: ConfigurationValue] = [:]) throws -> WidgetConfiguration {
        try ConfigurationValue.object(["id": .string("test"), "type": .string("text"), "text": .string("Test"), "position": .string("left")].merging(properties) { $1 }).decoded(WidgetConfiguration.self)
    }
}
