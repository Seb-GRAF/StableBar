import AppKit
import SwiftUI
import XCTest
@testable import StableBar

final class BarEditingTests: XCTestCase {
    private let laptop = BarDisplay(id: 1, isBuiltIn: true, isMain: true, notch: 661...851)
    private let external = BarDisplay(id: 2, isBuiltIn: false, isMain: false, notch: nil)

    @MainActor func testEveryDisplayRevealsOutputHiddenAndExcludedWidgetsButLeavesTurnedOffOnesOff() throws {
        let fixture = try ThemeGalleryFixture(#"""
        {"widgets":[{"id":"off","type":"text","text":"Off","position":"left","enabled":false},
                    {"id":"output","type":"script","command":"true","position":"center"},
                    {"id":"screen","type":"clock","position":"notchRight","display":"external"},
                    {"id":"spaces","type":"workspaces","position":"notchLeft"},
                    {"id":"visible","type":"clock","position":"right"}]}
        """#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let script = ScriptWidget()
        script.output = ScriptOutput(text: "", hidden: true)
        store.scripts["output"] = script
        store.updatePresentations()
        let before = try Data(contentsOf: fixture.url)
        let document = store.effectiveDocument
        let editing = store.barEditing
        XCTAssertEqual(editing.widgets(on: laptop).map(\.id), ["visible"])
        XCTAssertEqual(editing.widgets(on: external).map(\.id), ["screen", "visible"])
        XCTAssertEqual(editing.menuTitle, "Edit Bar in Place")
        editing.begin()
        XCTAssertEqual(editing.menuTitle, "Finish Editing Bar")
        for display in [laptop, external] {
            let entries = editing.entries(on: display)
            XCTAssertEqual(entries.map(\.id), ["output", "screen", "spaces", "visible"], "Turned-off widgets aren't on the bar")
            XCTAssertTrue(entries[0].visibility.reasons.contains(.output))
            XCTAssertEqual(entries[1].visibility.isHidden, display.isBuiltIn)
            XCTAssertTrue(entries[2].visibility.reasons.contains(.workspaces))
            XCTAssertTrue(entries.filter { $0.visibility.isHidden }.allSatisfy(\.usesPlaceholder))
            XCTAssertTrue(entries.allSatisfy { !$0.name.isEmpty })
        }
        XCTAssertEqual(store.effectiveDocument, document)
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
        XCTAssertTrue(store.customizationHistory.undoSteps.isEmpty)
        XCTAssertFalse(script.diagnostics.running)
        XCTAssertNil(store.scripts["off"])
        editing.end()
        XCTAssertEqual(editing.widgets(on: laptop).map(\.id), ["visible"])
        XCTAssertEqual(editing.widgets(on: external).map(\.id), ["screen", "visible"])
        XCTAssertEqual(store.presentations["output"]?.hidden, true)
        XCTAssertEqual(store.configuration?.widgets[0].enabled, false)
    }

    @MainActor func testEmptyWidgetsHaveDistinctNamedPlaceholdersAndOutputDisplaySelectionWins() throws {
        let fixture = try ThemeGalleryFixture(#"""
        {"widgets":[{"id":"widget-00000001","type":"text","text":"","position":"left"},
                    {"id":"widget-00000002","type":"text","text":"","position":"left"},
                    {"id":"spacer","type":"spacer","position":"center"},
                    {"id":"script","type":"script","command":"true","display":"external","position":"right"}]}
        """#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        store.barEditing.begin()
        XCTAssertTrue(store.barEditing.entries(on: laptop).allSatisfy(\.usesPlaceholder))
        XCTAssertEqual(store.barEditing.entries(on: laptop).prefix(2).map(\.name), ["Text 1", "Text 2"])
        let script = ScriptWidget()
        script.output = ScriptOutput(text: "Hello", display: .builtIn)
        store.scripts["script"] = script
        store.updatePresentations()
        XCTAssertFalse(try XCTUnwrap(store.barEditing.entries(on: laptop).last).usesPlaceholder)
        XCTAssertTrue(try XCTUnwrap(store.barEditing.entries(on: external).last).visibility.isHidden)
        store.barEditing.end()
        XCTAssertTrue(store.barEditing.widgets(on: laptop).contains { $0.id == "script" })
        XCTAssertFalse(store.barEditing.widgets(on: external).contains { $0.id == "script" })
    }

    func testAllFiveSectionsIncludeEmptyPositionsAndMatchEachDisplaysPhysicalOrder() throws {
        let bar = try JSONDecoder().decode(BarSettings.self, from: Data(#"{"inset":8}"#.utf8))
        let widths: [WidgetPosition: CGFloat] = [.left: 180, .notchLeft: 140, .center: 150, .notchRight: 130, .right: 170]
        for display in [laptop, external] {
            let layout = BarEditLayout(width: 1512, display: display, bar: bar, preferredWidths: widths)
            XCTAssertEqual(Set(layout.sections.keys), Set(WidgetPosition.allCases))
            let ordered = layout.sections.sorted { $0.value.x < $1.value.x }
            XCTAssertEqual(ordered.map(\.key), display.notch == nil
                           ? [.left, .notchLeft, .center, .notchRight, .right] : [.left, .notchLeft, .notchRight, .center, .right])
            for (index, item) in ordered.enumerated() {
                XCTAssertGreaterThan(item.value.width, 0)
                XCTAssertGreaterThanOrEqual(item.value.x, 0)
                XCTAssertLessThanOrEqual(item.value.x + item.value.width, 1512 - 8)
                if index > 0 { XCTAssertGreaterThan(item.value.x, ordered[index - 1].value.x + ordered[index - 1].value.width) }
                if let notch = display.notch {
                    XCTAssertTrue(item.value.x + item.value.width <= notch.lowerBound || item.value.x >= notch.upperBound)
                }
            }
            if display.notch == nil {
                let first = try XCTUnwrap(layout.sections[.notchLeft])
                let last = try XCTUnwrap(layout.sections[.notchRight])
                XCTAssertEqual((first.x + last.x + last.width) / 2, 1512 / 2, accuracy: 0.01)
            }
        }
    }

    func testCrowdedSectionsStayAvailableWithoutOverflowAndRespectScaledNotchOverrides() throws {
        let bar = try JSONDecoder().decode(BarSettings.self, from: Data(#"{"margin":4,"notchWidth":200,"displayScale":{"builtIn":1.2}}"#.utf8))
        let layout = BarEditLayout(width: 1504, display: laptop, bar: bar,
                                   preferredWidths: Dictionary(uniqueKeysWithValues: WidgetPosition.allCases.map { ($0, 2000) }))
        XCTAssertEqual(layout.sections.count, 5)
        for (position, frame) in layout.sections {
            XCTAssertGreaterThan(frame.width, 0)
            if [.left, .notchLeft].contains(position) { XCTAssertLessThanOrEqual(frame.x + frame.width, 632) }
            else { XCTAssertGreaterThanOrEqual(frame.x, 872) }
        }
    }

    func testCompactMeasuredSectionsFitABusyNotchedBarWithoutScrolling() throws {
        let widths: [WidgetPosition: CGFloat] = [.left: 50, .notchLeft: 86, .center: 50, .notchRight: 86, .right: 350]
        let layout = BarEditLayout(width: 1512, display: laptop, bar: BarSettings(), preferredWidths: widths)
        for position in WidgetPosition.allCases {
            let frame = try XCTUnwrap(layout.sections[position])
            XCTAssertEqual(frame.width, try XCTUnwrap(widths[position]), accuracy: 0.01,
                           "Measured sections that fit must retain their content width")
            XCTAssertLessThanOrEqual(frame.x + frame.width, 1512 - 12)
        }
        XCTAssertTrue(layout.scrolling.isEmpty)
    }

    func testRightSectionUsesTheSpacePreviouslyReservedForControlsWithoutScrolling() throws {
        let widths: [WidgetPosition: CGFloat] = [.left: 50, .notchLeft: 86, .center: 50, .notchRight: 86, .right: 450]
        let layout = BarEditLayout(width: 1512, display: laptop, bar: BarSettings(), preferredWidths: widths)
        XCTAssertTrue(layout.scrolling.isEmpty)
        for position in WidgetPosition.allCases {
            let frame = try XCTUnwrap(layout.sections[position])
            XCTAssertEqual(frame.width, try XCTUnwrap(widths[position]), accuracy: 0.01)
            XCTAssertLessThanOrEqual(frame.x + frame.width, 1512 - 12)
            XCTAssertTrue(frame.x + frame.width <= 661 || frame.x >= 851)
        }
        let right = try XCTUnwrap(layout.sections[.right])
        XCTAssertEqual(right.x + right.width, 1512 - 12, accuracy: 0.01)
    }

    func testOnlyTheSectionThatCannotFitScrollsAndSectionsReachTheRightInset() throws {
        let widths: [WidgetPosition: CGFloat] = [.left: 50, .notchLeft: 86, .center: 50, .notchRight: 86, .right: 2000]
        for (width, display) in [(CGFloat(800), external), (1512, laptop)] {
            let layout = BarEditLayout(width: width, display: display, bar: BarSettings(), preferredWidths: widths)
            XCTAssertEqual(layout.scrolling, [.right])
            let right = try XCTUnwrap(layout.sections[.right])
            XCTAssertEqual(right.x + right.width, width - 12, accuracy: 0.01)
            let ordered = layout.sections.values.sorted { $0.x < $1.x }
            for (index, frame) in ordered.enumerated() {
                XCTAssertGreaterThan(frame.width, 0)
                XCTAssertLessThanOrEqual(frame.x + frame.width, width - 12 + 0.01)
                if index > 0 { XCTAssertGreaterThanOrEqual(frame.x, ordered[index - 1].x + ordered[index - 1].width + 5.99) }
            }
            for position in WidgetPosition.allCases where position != .right {
                XCTAssertEqual(try XCTUnwrap(layout.sections[position]).width, try XCTUnwrap(widths[position]), accuracy: 0.01)
            }
        }
    }

    func testEmptyTraysContainOnlyTheSlotAndPadding() throws {
        let layout = BarEditLayout(width: 1512, display: laptop, bar: BarSettings())
        for position in WidgetPosition.allCases {
            XCTAssertEqual(try XCTUnwrap(layout.sections[position]).width, max(36, BarEditTrayMetrics.chipWidth(for: position)))
        }
    }

    func testDragChipsFitEmptyTraysWithoutOverlappingOtherTraysOrTheNotch() throws {
        for display in [laptop, external] {
            let layout = BarEditLayout(width: 1512, display: display, bar: BarSettings())
            XCTAssertTrue(layout.scrolling.isEmpty)
            let ordered = layout.sections.sorted { $0.value.x < $1.value.x }
            for (index, entry) in ordered.enumerated() {
                XCTAssertGreaterThanOrEqual(entry.value.width, BarEditTrayMetrics.chipWidth(for: entry.key))
                if index > 0 {
                    XCTAssertGreaterThan(entry.value.x, ordered[index - 1].value.x + ordered[index - 1].value.width)
                }
                if let notch = display.notch {
                    XCTAssertTrue(entry.value.x + entry.value.width <= notch.lowerBound || entry.value.x >= notch.upperBound)
                }
            }
        }
    }

    func testDragLabelsYieldSpaceBeforeFittingWidgetsHaveToScroll() throws {
        let widths: [WidgetPosition: CGFloat] = [.left: 50, .notchLeft: 36, .notchRight: 36, .center: 36, .right: 530]
        let layout = BarEditLayout(width: 1512, display: laptop, bar: BarSettings(), preferredWidths: widths)
        XCTAssertTrue(layout.scrolling.isEmpty)
        XCTAssertEqual(try XCTUnwrap(layout.sections[.right]).width, 530, accuracy: 0.01)
    }

    @MainActor func testMeasuredRowsIncludeOnlyWidgetsSlotSpacingAndTrayPadding() throws {
        let fixture = try ThemeGalleryFixture(##"{"bar":{"height":38,"spacing":8},"defaults":{"height":34},"groups":{"pair":{"style":{"paddingHorizontal":10,"paddingVertical":2,"spacing":12,"borderWidth":2,"background":"#123456"}}},"widgets":[{"id":"a","type":"text","text":"One","position":"left","group":"pair"},{"id":"b","type":"text","text":"Two","position":"left","group":"pair"}]}"##)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        store.barEditing.begin()
        let config = try XCTUnwrap(store.configuration)
        let units = BarUnit.make(widgets: config.widgets, groups: config.groups)
        let unit = NSHostingView(rootView: BarUnitView(unit: units[0], config: config, store: store, display: laptop.id)
            .fixedSize().modifier(MeasuringCopy()))
        let row = NSHostingView(rootView: BarEditSectionRow(store: store, display: laptop, position: .left,
            entries: store.barEditing.entries(on: laptop), config: config, adding: false).modifier(MeasuringCopy()))
        XCTAssertEqual(row.fittingSize.width, unit.fittingSize.width + 22 + 8 + 14, accuracy: 0.5)
        XCTAssertEqual(row.fittingSize.height, 50, accuracy: 0.5)
        store.barEditing.measure(height: row.fittingSize.height, on: laptop.id)
        XCTAssertEqual(store.barEditing.geometry(for: laptop)?.layoutHeight, 50)
        let empty = NSHostingView(rootView: BarEditSectionRow(store: store, display: laptop, position: .right,
            entries: [], config: config, adding: false).modifier(MeasuringCopy()))
        XCTAssertEqual(empty.fittingSize.width, 36, accuracy: 0.01)
        XCTAssertEqual(empty.fittingSize.height, 34, accuracy: 0.01)
    }

    @MainActor func testTrayNamesTargetsBadgesAndGroupedSourceOpacityFollowTheDragSession() throws {
        let fixture = try ThemeGalleryFixture(#"{"groups":{"pair":{}},"widgets":[{"id":"a","type":"clock","position":"left","group":"pair"},{"id":"b","type":"clock","position":"left","group":"pair"}]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let editing = store.barEditing
        editing.begin()
        XCTAssertFalse(editing.trayState(on: 1, position: .left).showsName)
        XCTAssertTrue(editing.trayState(on: 1, position: .left).showsBadges)
        XCTAssertTrue(editing.trayState(on: 1, position: .left).showsAddSlot)
        let payload = editing.dragSession.begin("a")
        editing.insertion = editing.dropTarget("a", on: 2, position: .right, x: 100, frames: [:])
        for position in WidgetPosition.allCases {
            XCTAssertTrue(editing.trayState(on: 1, position: position).showsName)
            XCTAssertFalse(editing.trayState(on: 1, position: position).showsBadges)
            XCTAssertFalse(editing.trayState(on: 1, position: position).isTarget)
            XCTAssertEqual(editing.trayState(on: 2, position: position).isTarget, position == .right)
            XCTAssertTrue(editing.trayState(on: 1, position: position).showsAddSlot)
            XCTAssertEqual(editing.trayState(on: 2, position: position).showsAddSlot, position != .right)
        }
        XCTAssertEqual(editing.opacity(for: "a"), 0)
        XCTAssertEqual(editing.opacity(for: "b"), 0)
        editing.dragSession.end(payload)
        XCTAssertFalse(editing.trayState(on: 2, position: .right).isTarget)
        XCTAssertTrue(editing.trayState(on: 2, position: .right).showsAddSlot)
        XCTAssertTrue(editing.trayState(on: 1, position: .left).showsBadges)
        XCTAssertEqual(editing.opacity(for: "b"), 1)
    }

    func testOverflowEdgesAndMouseWheelOffsetsFollowTheVisibleContent() {
        XCTAssertEqual(BarEditOverflow(bounds: CGRect(x: 6, y: 0, width: 188, height: 22), viewportWidth: 200),
                       BarEditOverflow(bounds: .null, viewportWidth: 200))
        let start = BarEditOverflow(bounds: CGRect(x: 6, y: 0, width: 500, height: 22), viewportWidth: 200)
        XCTAssertFalse(start.leading)
        XCTAssertTrue(start.trailing)
        let middle = BarEditOverflow(bounds: CGRect(x: -114, y: 0, width: 500, height: 22), viewportWidth: 200)
        XCTAssertTrue(middle.leading)
        XCTAssertTrue(middle.trailing)
        let end = BarEditOverflow(bounds: CGRect(x: -306, y: 0, width: 500, height: 22), viewportWidth: 200)
        XCTAssertTrue(end.leading)
        XCTAssertFalse(end.trailing)
        XCTAssertEqual(BarEditOverflow.offset(from: 0, deltaX: 0, deltaY: -3, precise: false, contentWidth: 500, viewportWidth: 200), 30)
        XCTAssertEqual(BarEditOverflow.offset(from: 30, deltaX: -12, deltaY: 0, precise: true, contentWidth: 500, viewportWidth: 200), 42)
        XCTAssertEqual(BarEditOverflow.offset(from: 30, deltaX: 0, deltaY: 100, precise: true, contentWidth: 500, viewportWidth: 200), 0)
        XCTAssertEqual(BarEditOverflow.offset(from: 290, deltaX: 0, deltaY: -100, precise: true, contentWidth: 500, viewportWidth: 200), 300)
        XCTAssertEqual(BarEditOverflow.offset(from: 0, deltaX: 0, deltaY: -10, precise: false, contentWidth: 100, viewportWidth: 200), 0)
    }

    @MainActor func testEditHeightFollowsMeasuredContentPerDisplayAndClearsOnExit() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        store.barEditing.begin()
        store.barEditing.measure(height: 63.2, on: laptop.id)
        store.barEditing.measure(height: 92, on: external.id)
        XCTAssertEqual(store.barEditing.geometry(for: laptop)?.layoutHeight, 64)
        XCTAssertEqual(store.barEditing.geometry(for: external)?.layoutHeight, 92)
        store.barEditing.end()
        XCTAssertEqual(store.barEditing.geometry(for: external)?.layoutHeight, CGFloat(try XCTUnwrap(store.configuration).bar.height))
        store.barEditing.begin()
        XCTAssertEqual(store.barEditing.geometry(for: external)?.layoutHeight, 52)
    }

    @MainActor func testDropIndexUsesFrameMidpointsAndNeverSplitsOrTargetsTheMovingGroup() throws {
        let fixture = try ThemeGalleryFixture(#"""
        {"groups":{"pair":{}},"widgets":[{"id":"a","type":"clock","position":"left","group":"pair"},
        {"id":"b","type":"clock","position":"left","group":"pair"},{"id":"c","type":"clock","position":"left"},
        {"id":"d","type":"clock","position":"right"}]}
        """#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let editing = store.barEditing
        let frames = ["a": CGRect(x: -40, y: 0, width: 40, height: 30), "b": CGRect(x: 4, y: 0, width: 40, height: 30),
                      "c": CGRect(x: 60, y: 0, width: 40, height: 30)]
        XCTAssertNil(editing.dropTarget("d", on: 2, position: .left, x: 0, frames: frames))
        editing.begin()
        let beforeGroup = try XCTUnwrap(editing.dropTarget("d", on: 2, position: .left, x: 1, frames: frames))
        XCTAssertEqual(beforeGroup.before, "a")
        XCTAssertEqual(beforeGroup.index, 0)
        XCTAssertEqual(beforeGroup.x, -43)
        let afterGroup = try XCTUnwrap(editing.dropTarget("d", on: 2, position: .left, x: 3, frames: frames))
        XCTAssertEqual(afterGroup.before, "c")
        XCTAssertEqual(afterGroup.index, 2)
        XCTAssertEqual(afterGroup.x, 57)
        let end = try XCTUnwrap(editing.dropTarget("d", on: 2, position: .left, x: 80, frames: frames))
        XCTAssertNil(end.before)
        XCTAssertEqual(end.index, 3)
        XCTAssertEqual(end.x, 103)
        XCTAssertEqual(editing.dropTarget("b", on: 1, position: .left, x: 0, frames: frames)?.before, "c")
        XCTAssertEqual(editing.dropTarget("b", on: 1, position: .left, x: 0, frames: frames)?.index, 0)
        XCTAssertEqual(editing.dropTarget("d", on: 2, position: .center, x: 500, frames: [:])?.index, 0)
        XCTAssertNil(editing.dropTarget("missing", on: 2, position: .left, x: 0, frames: frames))
    }

    @MainActor func testDropMovesTheWholeGroupOnceAcrossDisplaysAndPositionsAndUndoKeepsEditing() async throws {
        let fixture = try ThemeGalleryFixture(#"{"groups":{"pair":{}},"widgets":[{"id":"a","type":"clock","position":"left","group":"pair"},{"id":"b","type":"clock","position":"left","group":"pair"},{"id":"c","type":"clock","position":"right"}]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        try store.setSessionEdits([.init(action: .bar, properties: ["height": .number(50)])])
        let before = try Data(contentsOf: fixture.url)
        let editing = store.barEditing
        editing.begin()
        let payload = editing.dragSession.begin("b")
        let entries = editing.entries(on: external)
        XCTAssertEqual(editing.arranged(entries, on: 2, position: .left).map(\.id), ["a", "b"])
        XCTAssertFalse(editing.isCollapsed("a", on: 2, position: .left))
        let target = try XCTUnwrap(editing.dropTarget("b", on: 2, position: .notchRight, x: 0, frames: [:]))
        editing.insertion = target
        XCTAssertEqual(editing.arranged(entries, on: 2, position: .notchRight).map(\.id), ["a", "b"])
        XCTAssertTrue(editing.isCollapsed("a", on: 2, position: .left))
        XCTAssertTrue(editing.isCollapsed("b", on: 1, position: .left))
        XCTAssertFalse(editing.isCollapsed("c", on: 2, position: .right))
        editing.insertion = try XCTUnwrap(editing.dropTarget("b", on: 2, position: .right, x: 0,
                                                             frames: ["c": CGRect(x: 10, y: 0, width: 40, height: 30)]))
        XCTAssertEqual(editing.arranged(entries, on: 2, position: .right).map(\.id), ["a", "b", "c"])
        XCTAssertTrue(editing.drop(payload, at: target))
        XCTAssertFalse(editing.drop(payload, at: target))
        XCTAssertEqual(editing.insertion, target)
        XCTAssertNil(editing.dragSession.active)
        XCTAssertEqual(editing.opacity(for: "a"), 1)
        XCTAssertEqual(editing.arranged(entries, on: 2, position: .notchRight).map(\.id), ["a", "b"])
        XCTAssertEqual(store.configuration?.widgets.filter { $0.group == "pair" }.map(\.position), [.left, .left])
        editing.finishDrop()
        editing.finishDrop()
        XCTAssertNil(editing.insertion)
        XCTAssertFalse(editing.isMoving("a"))
        XCTAssertEqual(store.configuration?.widgets.filter { $0.group == "pair" }.map(\.position), [.notchRight, .notchRight])
        XCTAssertEqual(store.customizationHistory.undoSteps.count, 1)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(editing.isActive, "An edit's own file notification must not leave edit mode")
        try store.customizationHistory.undo()
        XCTAssertTrue(editing.isActive)
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
        XCTAssertEqual(store.sessionEdits.count, 1)
        XCTAssertEqual(store.configuration?.bar.height, 50)
    }

    @MainActor func testAddAndRemoveUseSharedSetupAndSavedUndoHistoryWithoutSavingCommandLineChanges() async throws {
        let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"clock","type":"clock","position":"right"}]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        try store.setSessionEdits([.init(action: .bar, properties: ["height": .number(50)])])
        store.barEditing.begin()
        let before = try Data(contentsOf: fixture.url)
        let added = await WidgetSetup(store: store).add(try XCTUnwrap(WidgetAddCatalog.builtIns.first { $0.id == "text" }), to: .notchLeft)
        let id = try XCTUnwrap(added)
        XCTAssertTrue(store.barEditing.entries(on: external).contains { $0.id == id && $0.widget.position == .notchLeft })
        XCTAssertEqual(store.customizationHistory.undoSteps.count, 1)
        store.barEditing.remove(id)
        XCTAssertFalse(store.barEditing.widgets(on: laptop).contains { $0.id == id })
        XCTAssertNil(store.barEditing.error)
        XCTAssertEqual(store.customizationHistory.undoSteps.count, 2)
        try store.customizationHistory.undo()
        XCTAssertTrue(store.barEditing.widgets(on: laptop).contains { $0.id == id })
        try store.customizationHistory.undo()
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
        XCTAssertNil(try fixture.document()["bar"])
        XCTAssertEqual(store.sessionEdits.count, 1)
    }

    @MainActor func testRemovingAPackageWidgetTurnsItOffTakesItOffTheEditBarAndAddingItBackRestoresIt() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let source = fixture.directory.appending(path: "source")
        try fixture.write(#"{"id":"note","name":"Note","version":"1","kind":"widgets","entry":"config.json"}"#,
                          to: source.appending(path: "package.json"))
        try fixture.write(#"{"widgets":[{"id":"note","type":"text","text":"Note","position":"right"}]}"#,
                          to: source.appending(path: "config.json"))
        let installed = try fixture.packages.install(source)
        let store = try fixture.store()
        defer { store.stop() }
        let setup = WidgetSetup(store: store)
        _ = try setup.enable(installed, settings: [:], position: .left)
        let packageFile = installed.directory.appending(path: "config.json")
        let before = try Data(contentsOf: packageFile)
        store.barEditing.begin()
        store.barEditing.remove("note")
        XCTAssertNil(store.barEditing.error)
        XCTAssertEqual(store.configuration?.widgets.map(\.enabled), [false])
        for display in [laptop, external] {
            XCTAssertTrue(store.barEditing.entries(on: display).isEmpty, "A removed widget must leave the edit bar")
        }
        XCTAssertEqual(try Data(contentsOf: packageFile), before)
        try store.customizationHistory.undo()
        XCTAssertEqual(store.barEditing.entries(on: laptop).map(\.id), ["note"])
        store.barEditing.remove("note")
        _ = try setup.enable(installed, settings: [:], position: .right)
        let entry = try XCTUnwrap(store.barEditing.entries(on: laptop).first)
        XCTAssertEqual(entry.id, "note")
        XCTAssertEqual(entry.widget.position, .right)
        store.barEditing.end()
        XCTAssertEqual(store.barEditing.widgets(on: laptop).map(\.id), ["note"])
    }

    @MainActor func testMoveLeftAndRightStepOverTurnedOffWidgetsThatTheEditBarLeavesOut() throws {
        let fixture = try ThemeGalleryFixture(#"""
        {"widgets":[{"id":"a","type":"clock","position":"right"},{"id":"off","type":"clock","position":"right","enabled":false},
                    {"id":"b","type":"clock","position":"right"}]}
        """#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let editing = store.barEditing
        editing.begin()
        XCTAssertEqual(editing.entries(on: laptop).map(\.id), ["a", "b"])
        editing.move("b", by: -1)
        XCTAssertNil(editing.error)
        XCTAssertEqual(editing.entries(on: laptop).map(\.id), ["b", "a"])
        try store.customizationHistory.undo()
        editing.move("a", by: 1)
        XCTAssertNil(editing.error)
        XCTAssertEqual(editing.entries(on: laptop).map(\.id), ["b", "a"])
        try store.customizationHistory.undo()
        // Settings lists turned-off widgets, so its moves still step over them.
        try WidgetSetup(store: store).move("b", by: -1)
        XCTAssertEqual(store.configuration?.widgets.map(\.id), ["a", "b", "off"])
    }

    @MainActor func testClicksSelectCustomizeInsteadOfActionsAndAllMouseActionsResumeAfterDone() async throws {
        let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"a","type":"clock","position":"right","onClick":"true","popup":{"style":{},"layout":{"type":"text","text":"Popup"}},"actions":{"rightClick":"true","middleClick":"true","scrollUp":"true","scrollDown":"true","mouseEntered":"true","mouseExited":"true"}},{"id":"open","type":"text","text":"Open","position":"left","open":"com.apple.finder"}]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let widget = try XCTUnwrap(store.configuration?.widgets.first)
        let marker = fixture.directory.appending(path: "actions")
        let command = "printf x >> '\(marker.path)'"
        var selected: String?
        store.onCustomizeWidget = { selected = $0 }
        store.barEditing.begin()
        store.barEditing.select("a")
        XCTAssertEqual(selected, "a")
        selected = nil
        store.barEditing.select("missing")
        XCTAssertNil(selected)
        XCTAssertFalse(store.barEditing.allowsWidgetActions)
        store.popup.toggle(try XCTUnwrap(widget.popup), widget: widget, defaults: WidgetStyle(), store: store, anchor: NSView())
        XCTAssertFalse(store.popup.isOpen)
        for sender in ["mouse.clicked", "mouse.scrolled", "mouse.entered", "mouse.exited", "control.changed"] {
            await store.runAction(command, widget: widget, event: ScriptEvent(sender: sender)).value
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        store.barEditing.end()
        XCTAssertTrue(store.barEditing.allowsWidgetActions)
        store.barEditing.select("a")
        XCTAssertNil(selected)
        for sender in ["mouse.clicked", "mouse.scrolled", "mouse.entered", "mouse.exited", "control.changed"] {
            await store.runAction(command, widget: widget, event: ScriptEvent(sender: sender)).value
        }
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "xxxxx")
        XCTAssertEqual(store.configuration?.widgets.first?.onClick, widget.onClick)
        XCTAssertNotNil(store.configuration?.widgets.first?.popup)
        XCTAssertEqual(store.configuration?.widgets.first?.actions?.rightClick, "true")
    }

    @MainActor func testEscapeDoneReloadInvalidReloadAndStopAlwaysRestoreNormalVisibilityAndGeometry() throws {
        for exit in ["escape", "done", "reload", "runtime reload", "invalid reload", "stop"] {
            let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"hidden","type":"clock","position":"right","display":"builtIn"}]}"#)
            defer { fixture.close() }
            let store = try fixture.store()
            defer { store.stop() }
            let normal = try XCTUnwrap(store.barEditing.geometry(for: laptop))
            store.barEditing.begin()
            XCTAssertEqual(store.barEditing.widgets(on: external).count, 1)
            XCTAssertGreaterThan(try XCTUnwrap(store.barEditing.geometry(for: laptop)).layoutHeight, normal.layoutHeight)
            let payload = store.barEditing.dragSession.begin("hidden")
            store.barEditing.insertion = store.barEditing.dropTarget("hidden", on: 1, position: .left, x: 0, frames: [:])
            XCTAssertFalse(store.barEditing.handleKey(36))
            switch exit {
            case "escape": XCTAssertTrue(store.barEditing.handleKey(53))
            case "done": store.barEditing.end()
            case "reload": store.reloadConfiguration()
            case "runtime reload": _ = try store.handle(RuntimeRequest(action: .reload))
            case "invalid reload": try fixture.write("{", to: fixture.url); store.reloadConfiguration()
            default: store.stop()
            }
            XCTAssertFalse(store.barEditing.isActive, exit)
            XCTAssertTrue(store.barEditing.allowsWidgetActions, exit)
            XCTAssertTrue(store.barEditing.widgets(on: external).isEmpty, exit)
            XCTAssertNil(store.barEditing.insertion, exit)
            XCTAssertFalse(store.barEditing.dragSession.accepts(payload), exit)
            XCTAssertEqual(store.barEditing.geometry(for: laptop), normal, exit)
            XCTAssertFalse(store.barEditing.handleKey(53))
        }
    }

    @MainActor func testAutomaticProfileRefreshKeepsEditingAndRevealsTheNewComposition() throws {
        let fixture = try ThemeGalleryFixture(#"""
        {"widgets":[{"id":"clock","type":"clock","position":"right"}],"profiles":[
        {"name":"App","when":{"app":"com.stablebar"},"configuration":{"widgets":[{"id":"app","type":"clock","position":"left","display":"external"}]}},
        {"name":"Dark","when":{"appearance":"dark"},"configuration":{"widgets":[{"id":"dark","type":"clock","position":"left"}]}},
        {"name":"Battery","when":{"onBattery":true},"configuration":{"widgets":[{"id":"battery","type":"clock","position":"left"}]}},
        {"name":"Displays","when":{"displayCount":2},"configuration":{"widgets":[{"id":"displays","type":"clock","position":"left"}]}},
        {"name":"External","when":{"externalDisplay":true},"configuration":{"widgets":[{"id":"external","type":"clock","position":"left"}]}}]}
        """#)
        defer { fixture.close() }
        let store = BarStore(configurationURL: fixture.url, themesDirectory: fixture.themes)
        store.reloadConfiguration()
        defer { store.stop() }
        let before = try Data(contentsOf: fixture.url)
        store.barEditing.begin()
        // Opening Settings activates StableBar and refreshes the frontmost-app context.
        store.onCustomizeWidget = { [weak store] _ in store?.refreshContext(ConfigurationContext(app: "com.stablebar")) }
        store.barEditing.select("clock")
        XCTAssertTrue(store.barEditing.isActive)
        XCTAssertEqual(store.activeProfiles, ["App"])
        XCTAssertEqual(store.barEditing.entries(on: laptop).map(\.id), ["clock", "app"])
        XCTAssertTrue(try XCTUnwrap(store.barEditing.entries(on: laptop).last).visibility.isHidden)
        for (context, name) in [(ConfigurationContext(appearance: "dark"), "dark"),
                                (ConfigurationContext(onBattery: true), "battery"),
                                (ConfigurationContext(displayCount: 2), "displays"),
                                (ConfigurationContext(externalDisplay: true), "external")] {
            store.refreshContext(context)
            XCTAssertNil(store.configurationError)
            XCTAssertTrue(store.barEditing.isActive)
            XCTAssertEqual(store.configuration?.widgets.map(\.id), ["clock", name])
            XCTAssertEqual(store.barEditing.entries(on: external).map(\.id), ["clock", name])
        }
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
        XCTAssertTrue(store.customizationHistory.undoSteps.isEmpty)
        store.reloadConfiguration()
        XCTAssertFalse(store.barEditing.isActive)
    }

    @MainActor func testWindowClearanceKeepsTheNormalFrameWhenEditingStartsAndEnds() throws {
        let fixture = try ThemeGalleryFixture(#"{"bar":{"height":32,"margin":4,"offset":20,"keepWindowsClear":true},"widgets":[]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        for (display, frame) in [(laptop, CGRect(x: 0, y: 0, width: 1512, height: 982)),
                                 (external, CGRect(x: -1920, y: 982, width: 1920, height: 1080))] {
            let config = try XCTUnwrap(store.configuration)
            let normal = config.barGeometry(for: display)
            let app = AppDelegate(store: store)
            let clearance = { app.clearanceDisplay(frame: frame, visibleFrame: frame, display: display, desktopTop: 2062) }
            let before = try XCTUnwrap(clearance())
            store.barEditing.begin()
            XCTAssertGreaterThan(try XCTUnwrap(store.barEditing.geometry(for: display)).panelHeight, normal.panelHeight)
            let during = try XCTUnwrap(clearance())
            XCTAssertEqual(during, before)
            XCTAssertEqual(during.barFrame.height, normal.panelHeight)
            XCTAssertEqual(during.barFrame.minY, 2062 - frame.maxY + config.bar.offset)
            // A window below the normal bar must not be moved by the taller editing controls.
            let window = CGRect(x: frame.minX + 10, y: during.barFrame.maxY + 1, width: 300, height: 200)
            XCTAssertNil(frameBelowBar(window, displays: [during]))
            store.barEditing.end()
            XCTAssertEqual(clearance(), before)
        }
    }

    @MainActor func testThemeTrialsAndEditingEndEachOtherWithoutSaving() throws {
        let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"clock","type":"clock","position":"right"}]}"#)
        defer { fixture.close() }
        let store = BarStore(configurationURL: fixture.url, themesDirectory: fixture.themes)
        store.reloadConfiguration()
        defer { store.stop() }
        let before = try Data(contentsOf: fixture.url)
        let normal = store.effectiveDocument
        let trial = ThemeTrial(store: store)
        trial.previous()
        XCTAssertNotEqual(store.effectiveDocument, normal)
        store.onEndThemeTrial = { trial.cancel() }
        store.barEditing.begin()
        XCTAssertFalse(trial.isActive)
        XCTAssertEqual(store.effectiveDocument, normal)
        XCTAssertTrue(store.barEditing.isActive)
        let next = ThemeTrial(store: store)
        XCTAssertFalse(store.barEditing.isActive)
        next.cancel()
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
        XCTAssertTrue(store.customizationHistory.undoSteps.isEmpty)
    }

    @MainActor func testBarPanelOnlyAcceptsKeyboardFocusWhileEditingAndRuntimeCanOpenOneWidget() throws {
        _ = NSApplication.shared
        let panel = BarPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        defer { panel.close() }
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        panel.isEditingBar = true
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        panel.isEditingBar = false
        XCTAssertFalse(panel.canBecomeKey)
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        var id: String?
        var generic = false
        store.onCustomizeWidget = { id = $0 }
        store.onCustomize = { generic = true }
        _ = try store.handle(RuntimeRequest(action: .customize, id: "clock"))
        XCTAssertEqual(id, "clock")
        XCTAssertFalse(generic)
        _ = try store.handle(RuntimeRequest(action: .customize))
        XCTAssertTrue(generic)
    }

    @MainActor func testMenuBarEntryStartsAndFinishesEditingAndIsAbsentWithoutABar() throws {
        let fixture = try ThemeGalleryFixture(#"{"widgets":[]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let panel = BarPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        defer { panel.close() }
        let menu = NSMenu()
        AppDelegate(store: store).menuWillOpen(menu)
        XCTAssertFalse(menu.items.contains { $0.title == "Edit Bar in Place" })
        let delegate = AppDelegate(store: store, panels: [1: panel])
        delegate.menuWillOpen(menu)
        let item = try XCTUnwrap(menu.items.first { $0.title == "Edit Bar in Place" })
        XCTAssertEqual(menu.items.firstIndex { $0 === item }, 2)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertTrue(store.barEditing.isActive)
        delegate.menuWillOpen(menu)
        let done = try XCTUnwrap(menu.items.first { $0.title == "Finish Editing Bar" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(done.action), to: done.target, from: done))
        XCTAssertFalse(store.barEditing.isActive)
        XCTAssertFalse(panel.isVisible)
    }

    @MainActor func testMenuBarMenuOrdersEditingFirstAndSettingsLastWithoutEmptyGroups() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = BarStore(configurationURL: fixture.url, themesDirectory: fixture.themes)
        store.reloadConfiguration()
        defer { store.stop() }
        XCTAssertNil(store.configurationError)
        let panel = BarPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        defer { panel.close() }
        let menu = NSMenu()
        for hasBar in [true, false] {
            let delegate = AppDelegate(store: store, panels: hasBar ? [1: panel] : [:])
            for error in [nil, "Configuration needs attention"] as [String?] {
                store.configurationError = error
                delegate.menuWillOpen(menu)
                var expected = ["StableBar", "separator"]
                if hasBar { expected += ["Edit Bar in Place", "Try Themes…", "separator"] }
                expected += ["Getting Started…", "User Guide"]
                if let error { expected += ["separator", error] }
                expected += ["separator", "Settings…", "Quit StableBar"]
                XCTAssertEqual(menu.items.map { $0.isSeparatorItem ? "separator" : $0.title }, expected)
            }
        }
    }

    @MainActor func testEditBarIsUnavailableWithoutConfiguration() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = BarStore(configurationURL: fixture.url)
        defer { store.stop() }
        let panel = BarPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        defer { panel.close() }
        let menu = NSMenu()
        let delegate = AppDelegate(store: store, panels: [1: panel])
        delegate.menuWillOpen(menu)
        XCTAssertFalse(store.barEditing.isAvailable)
        XCTAssertFalse(menu.items.contains { $0.title == "Edit Bar in Place" })
        store.barEditing.begin()
        XCTAssertFalse(store.barEditing.isActive)
        store.reloadConfiguration()
        XCTAssertTrue(store.barEditing.isAvailable)
        delegate.menuWillOpen(menu)
        XCTAssertTrue(menu.items.contains { $0.title == "Edit Bar in Place" })
    }

    @MainActor func testLeavingEditModeReleasesOnlyTheKeyBarAndKeepsItsVisibility() {
        _ = NSApplication.shared
        for (key, visible) in [(true, true), (true, false), (false, true), (false, false)] {
            let panel = UnorderedEditingPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                               backing: .buffered, defer: false)
            defer { panel.close() }
            panel.isEditingBar = true
            panel.simulatedKey = key
            panel.simulatedVisible = visible
            panel.isEditingBar = false
            XCTAssertEqual(panel.ordering, key ? (visible ? ["out", "front"] : ["out"]) : [])
            XCTAssertFalse(panel.isKeyWindow)
            XCTAssertEqual(panel.isVisible, visible)
            panel.isEditingBar = false
            XCTAssertEqual(panel.ordering.count, key ? (visible ? 2 : 1) : 0)
        }
    }

    @MainActor func testEscapeHandlingAcceptsAnUnmodifiedKeyAndLeavesOtherShortcutsAlone() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        store.barEditing.begin()
        let panel = BarPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        defer { panel.close() }
        panel.isEditingBar = true
        for (code, modifiers) in [(UInt16(53), NSEvent.ModifierFlags.command), (53, .control), (53, .option), (53, .shift), (36, [])] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                                     windowNumber: panel.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                                                     isARepeat: false, keyCode: code))
            XCTAssertFalse(BarEditingKeyboard.handle(event, store: store, keyWindow: panel))
            XCTAssertTrue(store.barEditing.isActive)
        }
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: panel.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                                                  isARepeat: false, keyCode: 53))
        XCTAssertTrue(BarEditingKeyboard.handle(escape, store: store, keyWindow: panel))
        XCTAssertFalse(BarEditingKeyboard.handle(escape, store: store, keyWindow: panel))
    }

    @MainActor func testEscapeLeavesOtherWindowsSheetsAndFieldEditorsAlone() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        store.barEditing.begin()
        let panel = UnorderedEditingPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                           backing: .buffered, defer: false)
        defer { panel.close() }
        panel.isEditingBar = true
        let other = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: panel.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                                                  isARepeat: false, keyCode: 53))
        XCTAssertFalse(BarEditingKeyboard.handle(escape, store: store, keyWindow: other))
        XCTAssertTrue(store.barEditing.isActive)
        XCTAssertFalse(BarEditingKeyboard.handle(escape, store: store, keyWindow: nil))
        panel.simulatedSheet = other
        XCTAssertFalse(BarEditingKeyboard.handle(escape, store: store, keyWindow: panel))
        XCTAssertTrue(store.barEditing.isActive)
        panel.simulatedSheet = nil
        let fieldEditor = NSTextView()
        fieldEditor.isFieldEditor = true
        panel.contentView = fieldEditor
        XCTAssertTrue(panel.makeFirstResponder(fieldEditor))
        XCTAssertFalse(BarEditingKeyboard.handle(escape, store: store, keyWindow: panel))
        XCTAssertTrue(store.barEditing.isActive)
    }


    @MainActor func testBarUndoAndRedoFinishCustomizeEditingAndFollowSharedHistoryState() throws {
        let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"a","type":"clock","position":"left"}]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let editing = store.barEditing
        editing.begin()
        XCTAssertFalse(editing.canUndo)
        editing.remove("a")
        XCTAssertTrue(editing.canUndo)
        let panel = BarPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        defer { panel.close() }
        panel.isEditingBar = true
        var finished = 0
        store.onEndCustomizationEditing = { finished += 1 }
        for redo in [false, true] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: redo ? [.command, .shift] : .command, timestamp: 0, windowNumber: panel.windowNumber,
                context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))
            XCTAssertTrue(BarEditingKeyboard.handle(event, store: store, keyWindow: panel))
            XCTAssertEqual(store.configuration?.widgets.count, redo ? 0 : 1)
            XCTAssertEqual(editing.canUndo, redo)
        }
        XCTAssertEqual(finished, 2)
        editing.undo()
        XCTAssertFalse(editing.canUndo)
        XCTAssertEqual(store.configuration?.widgets.map(\.id), ["a"])
        try store.customizationHistory.change(.init(action: .bar, properties: ["height": .number(56)]))
        XCTAssertTrue(editing.canUndo)
        editing.undo()
        XCTAssertFalse(editing.canUndo)
        XCTAssertFalse(store.customizationHistory.hasPendingChanges)
        editing.end()
        XCTAssertFalse(editing.canUndo)
    }

    @MainActor func testUndoAndRedoUseTheTypedCharacterInsteadOfTheUSKeyPosition() throws {
        let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"a","type":"clock","position":"left"}]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        store.barEditing.begin()
        store.barEditing.remove("a")
        let panel = BarPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        defer { panel.close() }
        panel.isEditingBar = true
        func event(_ code: UInt16, _ character: String, _ modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: character,
                charactersIgnoringModifiers: character, isARepeat: false, keyCode: code))
        }
        XCTAssertFalse(BarEditingKeyboard.handle(try event(6, "y", .command), store: store, keyWindow: panel))
        XCTAssertEqual(store.configuration?.widgets.count, 0)
        XCTAssertTrue(BarEditingKeyboard.handle(try event(16, "z", .command), store: store, keyWindow: panel))
        XCTAssertEqual(store.configuration?.widgets.count, 1)
        XCTAssertTrue(BarEditingKeyboard.handle(try event(16, "Z", [.command, .shift]), store: store, keyWindow: panel))
        XCTAssertEqual(store.configuration?.widgets.count, 0)
        XCTAssertFalse(panel.isVisible)
    }

    @MainActor func testUndoAndRedoPreserveCommandLayoutsAndNonLatinKeyFallback() throws {
        let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"a","type":"clock","position":"left"}]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        store.barEditing.begin()
        store.barEditing.remove("a")
        let panel = UnorderedEditingPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                           backing: .buffered, defer: false)
        defer { panel.close() }
        panel.isEditingBar = true
        let layouts: [(UInt16, String, String, Bool)] = [
            (6, "z", ";", true), (6, "z", "я", true), (6, "я", "я", true),
            (6, ";", ";", true), (16, "z", "z", true), (6, "y", "y", false),
            (6, "y", ";", false), (6, ";", "y", false), (16, "я", "я", false)
        ]
        for (code, characters, unmodified, handles) in layouts {
            for redo in [false, true] {
                let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: redo ? [.command, .shift] : .command, timestamp: 0, windowNumber: panel.windowNumber,
                    context: nil, characters: redo ? characters.uppercased() : characters,
                    charactersIgnoringModifiers: redo ? unmodified.uppercased() : unmodified, isARepeat: false, keyCode: code))
                XCTAssertEqual(BarEditingKeyboard.handle(event, store: store, keyWindow: panel), handles,
                               "key \(code), characters \(characters), unmodified \(unmodified), redo \(redo)")
                XCTAssertEqual(store.configuration?.widgets.count, handles && !redo ? 1 : 0)
            }
        }
    }

    @MainActor func testUndoShortcutsLeaveOtherWindowsSheetsAndTextInputAlone() throws {
        let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"a","type":"clock","position":"left"}]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        store.barEditing.begin()
        store.barEditing.remove("a")
        let panel = UnorderedEditingPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        defer { panel.close() }
        panel.isEditingBar = true
        let other = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        for modifiers: NSEvent.ModifierFlags in [.command, [.command, .shift]] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))
            XCTAssertFalse(BarEditingKeyboard.handle(event, store: store, keyWindow: other))
            XCTAssertFalse(BarEditingKeyboard.handle(event, store: store, keyWindow: nil))
            panel.simulatedSheet = other
            XCTAssertFalse(BarEditingKeyboard.handle(event, store: store, keyWindow: panel))
            panel.simulatedSheet = nil
            let text = NSTextView()
            text.isFieldEditor = true
            panel.contentView = text
            XCTAssertTrue(panel.makeFirstResponder(text))
            XCTAssertFalse(BarEditingKeyboard.handle(event, store: store, keyWindow: panel))
            panel.makeFirstResponder(nil)
            panel.contentView = NSView()
            panel.isEditingBar = false
            XCTAssertFalse(BarEditingKeyboard.handle(event, store: store, keyWindow: panel))
            panel.isEditingBar = true
        }
        for modifiers: NSEvent.ModifierFlags in [[], .shift, [.command, .option], [.command, .control]] {
            XCTAssertFalse(store.barEditing.handleKey(6, charactersIgnoringModifiers: "z", modifiers: modifiers))
        }
        XCTAssertEqual(store.configuration?.widgets.count, 0)
        XCTAssertEqual(store.customizationHistory.undoSteps.count, 1)
        store.barEditing.end()
        XCTAssertFalse(store.barEditing.handleKey(6, charactersIgnoringModifiers: "z", modifiers: .command))
    }

    func testPositionMenusUseMacOSTitleCase() {
        XCTAssertEqual(WidgetPosition.allCases.map(\.menuTitle), ["Left", "Left of Notch", "Center", "Right of Notch", "Right"])
        XCTAssertEqual(WidgetPosition.notchLeft.title, "Left of notch")
    }

    @MainActor func testEmptyCustomLayoutsAndTransparentWidgetsUsePlaceholdersUntilTheirContentReturns() throws {
        let fixture = try ThemeGalleryFixture(#"""
        {"widgets":[{"id":"empty","type":"text","text":"","position":"left","layout":{"type":"row","children":[{"type":"field","field":"text","hideWhenEmpty":"text"}]}},
        {"id":"transparent","type":"text","text":"Hello","position":"right","style":{"opacity":0}}]}
        """#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        store.barEditing.begin()
        XCTAssertTrue(store.barEditing.entries(on: laptop).allSatisfy(\.usesPlaceholder))
        try store.customizationHistory.change([
            ConfigurationEdit(action: .set, id: "empty", properties: ["text": .string("Here")]),
            ConfigurationEdit(action: .set, id: "transparent", properties: ["style": .object(["opacity": .number(1)])])
        ])
        XCTAssertTrue(store.barEditing.entries(on: external).allSatisfy { !$0.usesPlaceholder })
    }

    @MainActor func testMovesWithinASectionAndKeyboardMovesShareTheSameUndoableGroupLogic() throws {
        let fixture = try ThemeGalleryFixture(#"{"groups":{"pair":{}},"widgets":[{"id":"a","type":"clock","position":"left","group":"pair"},{"id":"b","type":"clock","position":"left","group":"pair"},{"id":"c","type":"clock","position":"left"}]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let before = try Data(contentsOf: fixture.url)
        store.barEditing.begin()
        store.barEditing.move("b", to: .left)
        XCTAssertNil(store.barEditing.error)
        XCTAssertEqual(store.configuration?.widgets.map(\.id), ["c", "a", "b"])
        XCTAssertEqual(store.customizationHistory.undoSteps.count, 1)
        store.barEditing.move("b", by: -1)
        XCTAssertNil(store.barEditing.error)
        XCTAssertEqual(store.configuration?.widgets.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(store.customizationHistory.undoSteps.count, 2)
        try store.customizationHistory.undo()
        try store.customizationHistory.undo()
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
    }

    @MainActor func testExternalFileWatcherEndsEditingAndSessionOnlyWidgetsCannotBeSavedByMovingThem() async throws {
        let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"clock","type":"clock","position":"right","display":"external"}]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        try store.setSessionEdits([ConfigurationEdit(action: .add, properties: ["id": .string("temporary"), "type": .string("text"),
                                                                             "position": .string("right"), "text": .string("Temporary")])])
        let before = try Data(contentsOf: fixture.url)
        store.barEditing.begin()
        store.barEditing.move("temporary", to: .left, on: 2)
        XCTAssertNotNil(store.barEditing.error)
        XCTAssertEqual(store.barEditing.errorDisplayID, 2)
        XCTAssertTrue(store.barEditing.isActive)
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
        XCTAssertEqual(store.sessionEdits.count, 1)
        try fixture.write(#"{"widgets":[{"id":"clock","type":"clock","position":"left","display":"external"}]}"#, to: fixture.url)
        for _ in 0..<100 {
            if !store.barEditing.isActive { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(store.barEditing.isActive)
        XCTAssertEqual(store.configuration?.widgets.first?.position, .left)
        XCTAssertFalse(store.barEditing.widgets(on: laptop).contains { $0.id == "clock" })
        XCTAssertTrue(store.barEditing.allowsWidgetActions)
        XCTAssertEqual(store.sessionEdits.count, 1)
    }

    @MainActor func testTurnedOffCommandsStayOffTheEditBarAndMovingThemNeverStartsOrEnablesThem() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let marker = fixture.directory.appending(path: "must-not-run")
        try fixture.write("""
        {"widgets":[{"id":"off","type":"script","command":"touch '\(marker.path)'","enabled":false,"position":"right"}]}
        """, to: fixture.url)
        let store = BarStore(configurationURL: fixture.url, themesDirectory: nil)
        defer { store.stop() }
        store.reloadConfiguration()
        store.barEditing.begin()
        XCTAssertTrue(store.barEditing.entries(on: laptop).isEmpty)
        store.setVisibleWidgets(ids: ["off"], displayID: 1)
        store.barEditing.move("off", to: .left)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(store.barEditing.isActive)
        XCTAssertEqual(store.configuration?.widgets.first?.enabled, false)
        XCTAssertTrue(store.scripts.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        store.barEditing.end()
        XCTAssertTrue(store.barEditing.widgets(on: laptop).isEmpty)
    }

    @MainActor func testSavingAnEditInvalidatesAnAlreadyScheduledDirectoryNotification() async throws {
        let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"clock","type":"clock","position":"right"}]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        try store.setSessionEdits([])
        store.barEditing.begin()
        store.scheduleReload()
        let reload = try XCTUnwrap(store.reloadTask)
        store.barEditing.move("clock", to: .left)
        await reload.value
        XCTAssertTrue(store.barEditing.isActive)
        XCTAssertNil(store.barEditing.error)
        XCTAssertEqual(store.configuration?.widgets.first?.position, .left)
    }
}

/// Simulates native focus/sheet state without ordering a test window onto the screen.
@MainActor private final class UnorderedEditingPanel: BarPanel {
    var simulatedKey = false
    var simulatedVisible = false
    var simulatedSheet: NSWindow?
    var ordering: [String] = []
    override var isKeyWindow: Bool { simulatedKey }
    override var isVisible: Bool { simulatedVisible }
    override var attachedSheet: NSWindow? { simulatedSheet }
    override func orderOut(_ sender: Any?) {
        ordering.append("out")
        simulatedKey = false
        simulatedVisible = false
    }
    override func orderFrontRegardless() {
        ordering.append("front")
        simulatedVisible = true
    }
}
