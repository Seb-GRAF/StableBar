import XCTest
@testable import StableBar

final class WidgetPlacementTests: XCTestCase {
    func testEmptyGroupsAndNotchGroupsRemainAvailableAsNeeded() throws {
        XCTAssertEqual(WidgetPlacement.positions(widgets: [], hasNotchedDisplay: false), [.left, .center, .right])
        XCTAssertEqual(WidgetPlacement.positions(widgets: try decode(#"[{"id":"clock","type":"clock","position":"right"}]"#), hasNotchedDisplay: false),
                       [.left, .center, .right])
        XCTAssertEqual(WidgetPlacement.positions(widgets: [], hasNotchedDisplay: true), WidgetPosition.allCases)
        let widgets = try decode(#"[{"id":"notch","type":"clock","position":"notchLeft"}]"#)
        XCTAssertEqual(WidgetPlacement.positions(widgets: widgets, hasNotchedDisplay: false), WidgetPosition.allCases)
        XCTAssertEqual(WidgetPlacement.destination(selectedID: nil, widgets: widgets), .right)
        XCTAssertEqual(WidgetPlacement.destination(selectedID: "notch", widgets: widgets), .notchLeft)
    }

    func testMovesWithinAndBetweenEveryPositionUseOriginalInsertionAnchor() throws {
        let widgets = try decode(#"[{"id":"a","type":"clock","position":"left"},{"id":"b","type":"clock","position":"left"},{"id":"c","type":"clock","position":"right"}]"#)
        XCTAssertEqual(try moved("a", to: .left, before: nil, widgets: widgets).map(\.id), ["b", "a", "c"])
        XCTAssertEqual(try moved("b", to: .left, before: "a", widgets: widgets).map(\.id), ["b", "a", "c"])
        for position in WidgetPosition.allCases {
            let result = try moved("a", to: position, before: "c", widgets: widgets)
            XCTAssertEqual(result.first { $0.id == "a" }?.position, position)
            XCTAssertEqual(result.filter { $0.position == .left && $0.id != "a" }.map(\.id), ["b"])
            XCTAssertEqual(Set(result.map(\.id)), ["a", "b", "c"])
        }
        XCTAssertTrue(try WidgetPlacement.move("a", to: .left, before: "a", widgets: widgets).isEmpty)
        XCTAssertThrowsError(try WidgetPlacement.move("missing", to: .left, widgets: widgets))
    }

    func testMovingAnyGroupMemberMovesWholeGroupAndDoesNotSplitDestinationGroup() throws {
        let widgets = try decode(#"[{"id":"a","type":"clock","position":"left","group":"one"},{"id":"b","type":"clock","position":"left","group":"one"},{"id":"c","type":"clock","position":"right","group":"two"},{"id":"d","type":"clock","position":"right","group":"two"}]"#)
        let result = try moved("b", to: .right, before: "d", widgets: widgets)
        XCTAssertEqual(result.map(\.id), ["a", "b", "c", "d"])
        XCTAssertEqual(result.map(\.position), [.right, .right, .right, .right])
        let notch = try moved("a", to: .notchRight, before: nil, widgets: widgets)
        XCTAssertEqual(notch.filter { $0.group == "one" }.map(\.position), [.notchRight, .notchRight])
    }

    func testKeyboardMovesSkipWholeGroupsAndStopAtTheEnds() throws {
        let widgets = try decode(#"[{"id":"a","type":"clock","position":"left","group":"one"},{"id":"b","type":"clock","position":"left","group":"one"},{"id":"c","type":"clock","position":"left","group":"two"},{"id":"d","type":"clock","position":"left","group":"two"}]"#)
        XCTAssertTrue(try WidgetPlacement.move("b", by: -1, widgets: widgets).isEmpty)
        XCTAssertTrue(try WidgetPlacement.move("c", by: 1, widgets: widgets).isEmpty)
        for (id, offset) in [("a", 1), ("d", -1)] {
            let edits = try WidgetPlacement.move(id, by: offset, widgets: widgets)
            XCTAssertEqual(edits.count, 1)
            XCTAssertEqual(edits.first?.ids, ["c", "d", "a", "b"])
        }
        let interleaved = try decode(#"[{"id":"b1","type":"clock","position":"left","group":"b"},{"id":"a1","type":"clock","position":"left","group":"a"},{"id":"b2","type":"clock","position":"left","group":"b"},{"id":"a2","type":"clock","position":"left","group":"a"}]"#)
        XCTAssertTrue(try WidgetPlacement.move("a1", by: 1, widgets: interleaved).isEmpty)
    }

    @MainActor func testSelectedGroupMemberMovesUpAndDownWithOneUndoStepPerAction() throws {
        let fixture = try ThemeGalleryFixture(#"{"groups":{"pair":{}},"widgets":[{"id":"first","type":"clock","position":"left"},{"id":"a","type":"clock","position":"left","group":"pair"},{"id":"b","type":"clock","position":"left","group":"pair"},{"id":"last","type":"clock","position":"left"}]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let editor = ConfigurationEditor(store: store)
        editor.selectedID = "b"
        let setup = WidgetSetup(store: store)
        try setup.move(try XCTUnwrap(editor.selectedID), by: -1)
        XCTAssertEqual(store.configuration?.widgets.map(\.id), ["a", "b", "first", "last"])
        XCTAssertEqual(store.customizationHistory.undoSteps.count, 1)
        try setup.move(try XCTUnwrap(editor.selectedID), by: 1)
        XCTAssertEqual(store.configuration?.widgets.map(\.id), ["first", "a", "b", "last"])
        XCTAssertEqual(store.customizationHistory.undoSteps.count, 2)
        XCTAssertEqual(editor.selectedID, "b")
        try store.customizationHistory.undo()
        XCTAssertEqual(store.configuration?.widgets.map(\.id), ["a", "b", "first", "last"])
    }

    @MainActor func testInvalidBatchIsRejectedWithoutSavingPartOfAGroupedMove() throws {
        let fixture = try ThemeGalleryFixture(#"{"groups":{"pair":{}},"widgets":[{"id":"a","type":"clock","position":"left","group":"pair"},{"id":"b","type":"clock","position":"left","group":"pair"}]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let before = try Data(contentsOf: fixture.url)
        XCTAssertThrowsError(try store.customizationHistory.change([
            ConfigurationEdit(action: .set, id: "a", properties: ["position": .string("right")]),
            ConfigurationEdit(action: .set, id: "b", properties: ["position": .string("unknown")])
        ]))
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
        XCTAssertEqual(store.configuration?.widgets.map(\.position), [.left, .left])
        XCTAssertFalse(store.customizationHistory.hasPendingChanges)
        XCTAssertTrue(store.customizationHistory.undoSteps.isEmpty)
    }

    @MainActor func testGroupedMoveIsOneUndoStepAndRetainsPendingCommandLineChanges() throws {
        let fixture = try ThemeGalleryFixture(#"{"groups":{"pair":{}},"widgets":[{"id":"a","type":"clock","position":"left","group":"pair"},{"id":"b","type":"clock","position":"left","group":"pair"},{"id":"c","type":"clock","position":"right"}]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        try store.configurationStore.setSessionEdits([.init(action: .bar, properties: ["height": .number(55)])])
        let before = try Data(contentsOf: fixture.url)
        let setup = WidgetSetup(store: store)
        try setup.move("b", to: .right)
        XCTAssertEqual(store.configuration?.widgets.map(\.id), ["c", "a", "b"])
        XCTAssertEqual(store.configuration?.widgets.map(\.position), [.right, .right, .right])
        XCTAssertEqual(store.customizationHistory.undoSteps.count, 1)
        XCTAssertNil(try fixture.document()["bar"])
        XCTAssertEqual(store.configuration?.bar.height, 55)
        try store.customizationHistory.undo()
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
        try store.customizationHistory.redo()
        XCTAssertEqual(store.configuration?.widgets.map(\.id), ["c", "a", "b"])
        XCTAssertEqual(store.configurationStore.sessionEdits.count, 1)
    }

    @MainActor func testIncludedTemplateAndProfileWidgetsMoveThroughOverridesAndWidgetOrder() throws {
        let fixture = try ThemeGalleryFixture(#"{"includes":["included.json"],"profile":"special","widgets":[{"id":"root","type":"clock","position":"right"}],"profiles":[{"name":"special","configuration":{"widgets":[{"id":"profile","type":"clock","position":"left"}]}}]}"#)
        defer { fixture.close() }
        let include = fixture.directory.appending(path: "included.json")
        try fixture.write(#"{"templates":{"time":{"type":"clock","position":"left"}},"widgets":[{"id":"included","template":"time"}]}"#, to: include)
        let original = try Data(contentsOf: include)
        let store = try fixture.store()
        defer { store.stop() }
        let setup = WidgetSetup(store: store)
        try setup.move("included", to: .notchLeft)
        XCTAssertEqual(store.configuration?.widgets.first { $0.id == "included" }?.position, .notchLeft)
        XCTAssertNotNil(try fixture.document()["widgetOrder"])
        let overrides = try XCTUnwrap(fixture.document()["widgetOverrides"]?.decoded([String: [String: ConfigurationValue]].self))
        XCTAssertEqual(overrides["included"]?["position"], .string("notchLeft"))
        XCTAssertEqual(try Data(contentsOf: include), original)
        try setup.move("profile", to: .notchRight)
        XCTAssertEqual(store.configuration?.widgets.first { $0.id == "profile" }?.position, .notchRight)
        XCTAssertEqual(store.customizationHistory.undoSteps.count, 2)
    }

    @MainActor func testMovesOnAScreenWithItsOwnLayoutChangeOnlyThatLayout() throws {
        let fixture = try ThemeGalleryFixture(#"{"screens":{"monitor":{"layout":{"right":["c","a","missing"]}}},"widgets":[{"id":"a","type":"clock","position":"left"},{"id":"b","type":"clock","position":"left"},{"id":"c","type":"clock","position":"right"}]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let monitor = try XCTUnwrap(store.configuration?.onScreen(.monitor).widgets)
        XCTAssertEqual(monitor.map(\.id), ["c", "a", "b"])
        XCTAssertEqual(monitor.map(\.position), [.right, .right, .left])
        XCTAssertEqual(store.configuration?.onScreen(.laptop).widgets.map(\.id), ["a", "b", "c"])
        let setup = WidgetSetup(store: store)
        try setup.move("b", to: .right, before: "a", on: .monitor)
        XCTAssertEqual(try layout(fixture, .monitor)["right"], ["c", "b", "a"])
        XCTAssertEqual(try layout(fixture, .monitor)["left"], [])
        XCTAssertEqual(store.configuration?.widgets.map(\.position), [.left, .left, .right])
        try setup.remove("b")
        XCTAssertEqual(try layout(fixture, .monitor)["right"], ["c", "a"])
    }

    @MainActor func testScreenBarSettingsOverrideTheSharedBarAndCopyAndJoinBetweenScreens() throws {
        let fixture = try ThemeGalleryFixture(#"{"bar":{"height":40,"inset":12,"style":{"cornerRadius":8,"borderWidth":1}},"screens":{"laptop":{"bar":{"height":30,"style":{"cornerRadius":2}},"layout":{"right":["b","a"]}}},"widgets":[{"id":"a","type":"clock","position":"left"},{"id":"b","type":"clock","position":"left","display":"builtIn"}]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let laptop = try XCTUnwrap(store.configuration?.onScreen(.laptop).bar)
        XCTAssertEqual([laptop.height, laptop.inset, laptop.style.cornerRadius, laptop.style.borderWidth], [30, 12, 2, 1])
        XCTAssertEqual(store.configuration?.onScreen(.monitor).bar.height, 40)
        let setup = WidgetSetup(store: store)
        try setup.copyScreen(.laptop, to: .monitor)
        XCTAssertEqual(store.configuration?.onScreen(.monitor).widgets.map(\.id), ["b", "a"])
        XCTAssertEqual(store.configuration?.onScreen(.monitor).bar.height, 30)
        XCTAssertEqual(try layout(fixture, .monitor)["right"], ["b", "a"])
        XCTAssertEqual(store.customizationHistory.undoSteps.count, 1)
        try setup.joinScreen(.monitor)
        XCTAssertEqual(store.configuration?.onScreen(.monitor).bar.height, 40)
        XCTAssertEqual(store.configuration?.onScreen(.monitor).widgets.map(\.position), [.left, .left])
        XCTAssertNotNil(store.configuration?.screenLooks["laptop"])
    }

    @MainActor func testAScreenWithItsOwnLookResolvesItsThemeTokensAndStyles() throws {
        let fixture = try ThemeGalleryFixture(##"{"tokens":{"text":"#111111ff"},"defaults":{"fontSize":12,"foreground":"@token.text"},"screens":{"laptop":{"tokens":{"text":"#222222ff"},"defaults":{"fontSize":16},"roles":{"time":{"fontSize":20}},"modeAliases":{"tailing":"command"}},"monitor":{"theme":{"id":"nord"}},"vertical":{"bar":{"appearance":"dark","height":30}}},"widgets":[{"id":"clock","type":"clock","position":"right"}]}"##)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let configuration = try XCTUnwrap(store.configuration)
        XCTAssertEqual(configuration.defaults.fontSize, 12)
        XCTAssertEqual(configuration.defaults.foreground, HexColor(0x111111ff))
        XCTAssertEqual(configuration.onScreen(.laptop).defaults.fontSize, 16)
        XCTAssertEqual(configuration.onScreen(.laptop).defaults.foreground, HexColor(0x222222ff))
        XCTAssertEqual(configuration.look(on: .laptop).roles["time"]?.fontSize, 20)
        XCTAssertEqual(configuration.look(on: .laptop).modeAliases, ["tailing": "command"])
        XCTAssertEqual(configuration.bar(on: .vertical).appearance, .dark)
        XCTAssertEqual(configuration.bar(on: .vertical).height, 30)
        XCTAssertEqual(configuration.onScreen(.vertical).defaults.fontSize, 12)
        XCTAssertNotEqual(store.screenDocuments["monitor"]?["tokens"], store.effectiveDocument["tokens"])
        let clock = try XCTUnwrap(store.barPresentation.presentations["clock"])
        XCTAssertEqual(clock.style(on: .laptop).base.fontSize, 16)
        XCTAssertEqual(clock.style(on: .vertical).base.fontSize, 12)
    }

    @MainActor func testPendingCommandLineWidgetCannotBeMovedEvenWhenOnlyReordering() throws {
        let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"root","type":"clock","position":"right"}]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        try store.configurationStore.setSessionEdits([.init(action: .add, properties: ["id": .string("temporary"), "type": .string("clock"), "position": .string("right")])])
        let before = try Data(contentsOf: fixture.url)
        XCTAssertThrowsError(try WidgetSetup(store: store).move("temporary", to: .right, before: "root"))
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
        XCTAssertTrue(store.customizationHistory.undoSteps.isEmpty)
    }

    private func layout(_ fixture: ThemeGalleryFixture, _ kind: ScreenKind) throws -> [String: [String]] {
        let screens = try XCTUnwrap(fixture.document()["screens"]?.decoded([String: ScreenConfiguration].self))
        return try XCTUnwrap(screens[kind.rawValue]?.layout)
    }

    private func decode(_ json: String) throws -> [WidgetConfiguration] {
        try JSONDecoder().decode([WidgetConfiguration].self, from: Data(json.utf8))
    }

    private func moved(_ id: String, to position: WidgetPosition, before anchor: String?, widgets: [WidgetConfiguration]) throws -> [WidgetConfiguration] {
        var root: [String: ConfigurationValue] = ["widgets": .array(widgets.map {
            .object(["id": .string($0.id), "type": .string("clock"), "position": .string($0.position.rawValue), "group": $0.group.map(ConfigurationValue.string) ?? .null])
        }), "groups": .object(["one": .object([:]), "two": .object([:])])]
        var ids = widgets.map(\.id)
        for edit in try WidgetPlacement.move(id, to: position, before: anchor, widgets: widgets) {
            try edit.validateTargets(in: ids)
            root = try edit.applying(to: root, widgetIDs: &ids)
        }
        return try ConfigurationValue.object(root).decoded(Configuration.self).widgets
    }
}
