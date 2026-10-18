import XCTest
@testable import StableBar

final class ConfigurationHistoryTests: XCTestCase {
    @MainActor func testBurstUpdatesLiveAndWritesOnceAfterPausing() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let history = fixture.store.customizationHistory
        let original = try Data(contentsOf: fixture.url)
        for text in ["B", "Bu", "Burst"] {
            try history.change(ConfigurationEdit(action: .set, id: "a", properties: ["text": .string(text)]))
            XCTAssertEqual(fixture.store.configuration?.widgets[0].content, .text(text))
            XCTAssertEqual(try Data(contentsOf: fixture.url), original)
            XCTAssertTrue(history.undoSteps.isEmpty)
            XCTAssertTrue(fixture.store.sessionEdits.isEmpty)
        }
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertFalse(history.hasPendingChanges)
        XCTAssertEqual(history.undoSteps.count, 1)
        XCTAssertEqual(try fixture.document()["widgets"]?.decoded([[String: ConfigurationValue]].self)[0]["text"], .string("Burst"))
        let saved = try Data(contentsOf: fixture.url)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(try Data(contentsOf: fixture.url), saved)
        XCTAssertEqual(history.undoSteps.count, 1)
        try history.change(ConfigurationEdit(action: .set, id: "a", properties: ["text": .string("Next burst")]))
        try history.flush()
        XCTAssertEqual(history.undoSteps.count, 2)
        try history.undo()
        XCTAssertEqual(try Data(contentsOf: fixture.url), saved)
        try history.undo()
        XCTAssertEqual(try Data(contentsOf: fixture.url), original)
    }

    @MainActor func testChangingControlsFlushesThePreviousBurstAndSeparatesUndo() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let history = fixture.store.customizationHistory
        try history.change(ConfigurationEdit(action: .set, id: "a", properties: ["text": .string("Saved first")]))
        try history.change(ConfigurationEdit(action: .set, id: "a", properties: ["icon": .string("star")]))
        let widget = try XCTUnwrap(fixture.document()["widgets"]).decoded([[String: ConfigurationValue]].self)[0]
        XCTAssertEqual(widget["text"], .string("Saved first"))
        XCTAssertNil(widget["icon"])
        XCTAssertEqual(history.undoSteps.count, 1)
        try history.undo()
        XCTAssertEqual(fixture.store.configuration?.widgets[0].content, .text("Saved first"))
        XCTAssertNil(fixture.store.configuration?.widgets[0].icon)
        try history.undo()
        XCTAssertEqual(fixture.store.configuration?.widgets[0].content, .text("A"))
    }

    @MainActor func testUndoAndRedoRestoreTheFileBytesAndKeepEchoReloadHistory() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let history = fixture.store.customizationHistory
        let before = try Data(contentsOf: fixture.url)
        try history.change(ConfigurationEdit(action: .bar, properties: ["height": .number(48)]))
        try history.flush()
        let after = try Data(contentsOf: fixture.url)
        fixture.store.reloadConfiguration()
        XCTAssertEqual(history.undoSteps.count, 1)
        try history.undo()
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
        XCTAssertEqual(fixture.store.configuration?.bar.height, 40)
        try history.redo()
        XCTAssertEqual(try Data(contentsOf: fixture.url), after)
        XCTAssertEqual(fixture.store.configuration?.bar.height, 48)
    }

    @MainActor func testOutsideChangesInvalidateUndoAndRedoWithoutWriting() throws {
        for redo in [false, true] {
            let fixture = try Fixture()
            defer { fixture.close() }
            let history = fixture.store.customizationHistory
            try history.change(ConfigurationEdit(action: .bar, properties: ["height": .number(48)]))
            try history.flush()
            if redo { try history.undo() }
            var external = try fixture.document()
            external["bar"] = .object(["height": .number(55)])
            let externalData = try configurationData(external)
            try externalData.write(to: fixture.url)
            if redo { try history.redo() } else { try history.undo() }
            XCTAssertEqual(try Data(contentsOf: fixture.url), externalData)
            XCTAssertTrue(history.undoSteps.isEmpty)
            XCTAssertTrue(history.redoSteps.isEmpty)
            XCTAssertTrue(history.notice?.contains("changed outside Customize") == true)
        }
    }

    @MainActor func testNewChangeAfterOutsideEditCanUndoOnlyItsOwnState() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let history = fixture.store.customizationHistory
        try history.change(ConfigurationEdit(action: .bar, properties: ["height": .number(48)]))
        try history.flush()
        let external = Data(#"{"bar":{"height":55},"widgets":[]}"#.utf8)
        try external.write(to: fixture.url)
        fixture.store.reloadConfiguration()
        XCTAssertFalse(history.canUndo)
        try history.change(ConfigurationEdit(action: .defaults, properties: ["fontSize": .number(16)]))
        try history.flush()
        try history.undo()
        XCTAssertEqual(try Data(contentsOf: fixture.url), external)
        XCTAssertFalse(history.canUndo)
    }

    @MainActor func testOutsideChangeDuringPendingUndoIsNeverWrittenOver() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let history = fixture.store.customizationHistory
        try history.change(ConfigurationEdit(action: .bar, properties: ["height": .number(48)]))
        let external = Data(#"{"bar":{"height":55},"widgets":[]}"#.utf8)
        try external.write(to: fixture.url)
        try history.undo()
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(try Data(contentsOf: fixture.url), external)
        XCTAssertFalse(history.hasPendingChanges)
        XCTAssertFalse(history.canUndo)
    }

    @MainActor func testPendingChangeRebasesOverUnrelatedOutsideChanges() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let history = fixture.store.customizationHistory
        try history.change(ConfigurationEdit(action: .set, id: "a", properties: ["text": .string("Customized")]))
        var external = try fixture.document()
        external["bar"] = .object(["height": .number(55)])
        let before = try configurationData(external)
        try before.write(to: fixture.url)
        try history.flush()
        XCTAssertEqual(fixture.store.configuration?.bar.height, 55)
        XCTAssertEqual(fixture.store.configuration?.widgets[0].content, .text("Customized"))
        try history.undo()
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
    }

    @MainActor func testCustomizeKeepsCommandLineEditsUnsavedAndAppliedAboveItsChanges() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let store = fixture.store
        let history = store.customizationHistory
        try store.applyEdits([
            ConfigurationEdit(action: .set, id: "a", properties: ["text": .string("Temporary")]),
            ConfigurationEdit(action: .bar, properties: ["height": .number(60)])
        ], persist: false)
        try history.change(ConfigurationEdit(action: .bar, properties: ["height": .number(48)]))
        try history.flush()
        XCTAssertEqual(try fixture.document()["bar"], .object(["height": .number(48)]))
        XCTAssertEqual(store.configuration?.bar.height, 60)
        XCTAssertEqual(store.sessionEdits.count, 2)
        XCTAssertEqual(store.configuration?.widgets[0].content, .text("Temporary"))
        try history.undo()
        XCTAssertEqual(store.configuration?.bar.height, 60)
        XCTAssertEqual(store.sessionEdits.count, 2)
        try history.redo()
        store.reloadConfiguration()
        XCTAssertEqual(store.configuration?.bar.height, 60)
        try history.discardCommandLineChanges()
        XCTAssertTrue(store.sessionEdits.isEmpty)
        XCTAssertEqual(store.configuration?.bar.height, 48)
        XCTAssertEqual(store.configuration?.widgets[0].content, .text("A"))
        XCTAssertEqual(history.undoSteps.count, 1)
        try history.undo()
        XCTAssertEqual(store.configuration?.bar.height, 40)
    }

    @MainActor func testCommandLineNoticeSaveFlushesCustomizeAndSavesOnlyTemporaryChanges() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let store = fixture.store
        let editor = ConfigurationEditor(store: store)
        try store.applyEdits([ConfigurationEdit(action: .set, id: "a", properties: ["text": .string("Temporary")])], persist: false)
        editor.change(ConfigurationEdit(action: .bar, properties: ["height": .number(48)]))
        editor.saveCommandLineChanges()
        XCTAssertNil(editor.error)
        XCTAssertFalse(editor.history.hasPendingChanges)
        XCTAssertTrue(store.sessionEdits.isEmpty)
        XCTAssertEqual(try fixture.document()["bar"], .object(["height": .number(48)]))
        XCTAssertEqual(store.configuration?.widgets[0].content, .text("Temporary"))
        try editor.history.undo()
        XCTAssertEqual(store.configuration?.widgets[0].content, .text("Temporary"))
        XCTAssertEqual(store.configuration?.bar.height, 48)
    }

    @MainActor func testCommandLineNoticeDiscardLeavesSavedCustomizeHistory() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let store = fixture.store
        let editor = ConfigurationEditor(store: store)
        try store.applyEdits([ConfigurationEdit(action: .set, id: "a", properties: ["text": .string("Temporary")])], persist: false)
        editor.change(ConfigurationEdit(action: .bar, properties: ["height": .number(48)]))
        editor.discardCommandLineChanges()
        XCTAssertNil(editor.error)
        XCTAssertEqual(store.configuration?.widgets[0].content, .text("A"))
        XCTAssertEqual(store.configuration?.bar.height, 48)
        XCTAssertEqual(editor.history.undoSteps.count, 1)
        editor.undo()
        XCTAssertEqual(store.configuration?.bar.height, 40)
    }

    @MainActor func testCloseAndQuitFlushHooksSavePendingChanges() throws {
        for stopping in [false, true] {
            let fixture = try Fixture()
            defer { fixture.close() }
            let history = fixture.store.customizationHistory
            try history.change(ConfigurationEdit(action: .bar, properties: ["height": .number(48)]))
            if stopping { fixture.store.stop() }
            else { XCTAssertTrue(fixture.store.flushCustomization()) }
            XCTAssertFalse(history.hasPendingChanges)
            XCTAssertEqual(try fixture.document()["bar"], .object(["height": .number(48)]))
        }
    }

    @MainActor func testFailedFlushKeepsPendingChangeAndCanRetry() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let original = try Data(contentsOf: fixture.url)
        let history = fixture.store.customizationHistory
        try history.change(ConfigurationEdit(action: .bar, properties: ["height": .number(48)]))
        try FileManager.default.removeItem(at: fixture.url)
        XCTAssertFalse(fixture.store.flushCustomization())
        XCTAssertNotNil(history.error)
        XCTAssertTrue(history.hasPendingChanges)
        XCTAssertTrue(history.undoSteps.isEmpty)
        try original.write(to: fixture.url)
        XCTAssertTrue(fixture.store.flushCustomization())
        XCTAssertNil(history.error)
        XCTAssertEqual(try fixture.document()["bar"], .object(["height": .number(48)]))
    }

    @MainActor func testInvalidChangeLeavesFileAndHistoryIntact() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let before = try Data(contentsOf: fixture.url)
        let history = fixture.store.customizationHistory
        XCTAssertThrowsError(try history.change(ConfigurationEdit(action: .bar, properties: ["height": .string("invalid")])))
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
        XCTAssertFalse(history.hasPendingChanges)
        XCTAssertFalse(history.canUndo)
        XCTAssertEqual(fixture.store.configuration?.bar.height, 40)
    }

    @MainActor func testHistoryIsSharedWithCallersOutsideTheWindow() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let first = ConfigurationEditor(store: fixture.store)
        first.set(["text": .string("From Customize")])
        try first.history.flush()
        try fixture.store.customizationHistory.change(ConfigurationEdit(action: .profile))
        let reopened = ConfigurationEditor(store: fixture.store)
        XCTAssertTrue(first.history === reopened.history)
        reopened.undo()
        reopened.undo()
        XCTAssertEqual(fixture.store.configuration?.widgets[0].content, .text("A"))
        XCTAssertFalse(first.history.canUndo)
    }

    @MainActor func testFocusedAppUsesOneStepPerBurstAndSeparatesOtherConditions() throws {
        let fixture = try Fixture(configuration: #"{"widgets":[],"profiles":[{"name":"work","configuration":{}}]}"#)
        defer { fixture.close() }
        let editor = ConfigurationEditor(store: fixture.store)
        for app in ["c", "co", "com.example"] {
            editor.setProfileCondition("work", \.app, value: app, control: "app")
            XCTAssertNil(editor.error)
            XCTAssertTrue(editor.history.undoSteps.isEmpty)
        }
        editor.setProfileCondition("work", \.onBattery, value: true, control: "onBattery")
        XCTAssertEqual(editor.history.undoSteps.count, 1)
        XCTAssertEqual(try fixture.document()["profiles"]?.decoded([ConfigurationProfile].self)[0].when?.app, "com.example")
        editor.undo()
        XCTAssertEqual(fixture.store.profiles[0].when?.app, "com.example")
        XCTAssertNil(fixture.store.profiles[0].when?.onBattery)
        editor.undo()
        XCTAssertNil(fixture.store.profiles[0].when?.app)
    }

    @MainActor func testPendingProfileConditionPreservesOutsideEditsToOtherConditions() throws {
        let fixture = try Fixture(configuration: #"{"widgets":[],"profiles":[{"name":"work","configuration":{}}]}"#)
        defer { fixture.close() }
        let editor = ConfigurationEditor(store: fixture.store)
        editor.setProfileCondition("work", \.app, value: "com.example", control: "app")
        let external = Data(#"{"widgets":[],"profiles":[{"name":"work","when":{"onBattery":true},"configuration":{}}]}"#.utf8)
        try external.write(to: fixture.url)
        fixture.store.reloadConfiguration()
        XCTAssertEqual(fixture.store.profiles[0].when?.app, "com.example")
        XCTAssertEqual(fixture.store.profiles[0].when?.onBattery, true)
        try editor.history.flush()
        let saved = try XCTUnwrap(fixture.document()["profiles"]).decoded([ConfigurationProfile].self)
        XCTAssertEqual(saved[0].when?.app, "com.example")
        XCTAssertEqual(saved[0].when?.onBattery, true)
        editor.undo()
        XCTAssertEqual(try Data(contentsOf: fixture.url), external)
    }

    @MainActor func testProfileConditionKeepsTheWidgetSelectionValid() throws {
        let fixture = try Fixture(configuration: #"{"widgets":[],"profiles":[{"name":"work","configuration":{"widgets":[{"id":"a","type":"text","position":"left","text":"A"}]}}]}"#)
        defer { fixture.close() }
        let editor = ConfigurationEditor(store: fixture.store)
        XCTAssertEqual(editor.selectedID, "a")
        editor.setProfileCondition("work", \.app, value: "com.unfocused", control: "app")
        XCTAssertNil(editor.error)
        XCTAssertNil(editor.selectedID)
        try editor.history.flush()
        editor.undo()
        XCTAssertEqual(editor.selectedID, "a")
    }

    @MainActor func testProfileControlsDoNotCopyTemporaryCommandLineConditions() throws {
        let fixture = try Fixture(configuration: #"{"widgets":[],"profiles":[{"name":"work","configuration":{}}]}"#)
        defer { fixture.close() }
        let store = fixture.store
        var temporary = store.profiles
        temporary[0].when = ProfileConditions()
        temporary[0].when?.app = "com.temporary"
        try store.applyEdits([ConfigurationEdit(action: .profiles, profiles: temporary)], persist: false)
        let editor = ConfigurationEditor(store: store)
        editor.setProfileCondition("work", \.onBattery, value: true, control: "onBattery")
        try editor.history.flush()
        var saved = try XCTUnwrap(fixture.document()["profiles"]).decoded([ConfigurationProfile].self)
        XCTAssertNil(saved[0].when?.app)
        XCTAssertEqual(saved[0].when?.onBattery, true)
        editor.setProfileConfiguration(name: "work", configuration: ["bar": .object(["height": .number(48)])])
        editor.addProfile(name: "extra")
        saved = try XCTUnwrap(fixture.document()["profiles"]).decoded([ConfigurationProfile].self)
        XCTAssertNil(saved[0].when?.app)
        XCTAssertEqual(saved.map(\.name), ["work", "extra"])
        XCTAssertEqual(store.sessionEdits.count, 1)
        XCTAssertEqual(store.profiles[0].when?.app, "com.temporary")
    }

    @MainActor func testInheritedWidgetAndStylesSaveOnlyInTheMainFile() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let module = fixture.url.deletingLastPathComponent().appending(path: "module.json")
        let included = Data(#"{"templates":{"label":{"type":"text","position":"left","text":"Inherited"}},"widgets":[{"id":"inherited","template":"label"}]}"#.utf8)
        try included.write(to: module)
        try Data(#"{"includes":["module.json"]}"#.utf8).write(to: fixture.url)
        fixture.store.reloadConfiguration()
        let history = fixture.store.customizationHistory
        try history.change(ConfigurationEdit(action: .set, id: "inherited", properties: ["text": .string("Customized")]))
        try history.flush()
        XCTAssertNotNil(try fixture.document()["widgetOverrides"])
        XCTAssertEqual(try Data(contentsOf: module), included)
        try history.undo()
        XCTAssertEqual(fixture.store.configuration?.widgets[0].content, .text("Inherited"))
        XCTAssertEqual(try Data(contentsOf: module), included)
    }

    @MainActor func testAllAppearanceEditKindsAreSavedAndUndoable() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let history = fixture.store.customizationHistory
        let edits: [ConfigurationEdit] = [
            .init(action: .defaults, properties: ["fontSize": .number(14)]),
            .init(action: .popupDefaults, properties: ["fontSize": .number(15)]),
            .init(action: .roles, properties: ["time": .object(["fontSize": .number(16)])]),
            .init(action: .workspaceDefaults, properties: ["indicator": .string("underline")]),
            .init(action: .tokens, properties: ["custom": .string("#112233")]),
            .init(action: .modeAliases, properties: ["main": .string("default")])
        ]
        for edit in edits {
            let before = try Data(contentsOf: fixture.url)
            try history.change(edit)
            try history.flush()
            XCTAssertEqual(try fixture.document()[edit.action.rawValue], .object(try XCTUnwrap(edit.properties)))
            try history.undo()
            XCTAssertEqual(try Data(contentsOf: fixture.url), before)
            try history.redo()
        }
    }

    @MainActor func testPackageAndThemeActivationWriteOnlyTheirOwnChange() throws {
        for kind in ["widgets", "theme"] {
            let key = kind == "theme" ? "theme" : "packages"
            let fixture = try Fixture()
            defer { fixture.close() }
            try fixture.installPackage(kind: kind, version: "1")
            try fixture.installPackage(kind: kind, version: "2")
            let store = fixture.store
            try store.applyEdits([ConfigurationEdit(action: .bar, properties: ["height": .number(60)])], persist: false)
            let history = store.customizationHistory
            let edit = ConfigurationEdit(action: kind == "theme" ? .theme : .package, properties: ["id": .string("sample"), "version": .string("2")])
            try history.change(edit)
            XCTAssertNotNil(try fixture.document()[key])
            XCTAssertEqual(try fixture.document()["bar"], .object(["height": .number(40)]))
            XCTAssertEqual(store.configuration?.bar.height, 60)
            XCTAssertEqual(store.sessionEdits.count, 1)
            try history.undo()
            XCTAssertNil(try fixture.document()[key])
            XCTAssertEqual(store.configuration?.bar.height, 60)
            try history.redo()
            XCTAssertNotNil(try fixture.document()[key])
        }
    }

    @MainActor func testCustomizeUninstallKeepsCommandLineEditsAndIncludedSelectionUnsaved() throws {
        for kind in ["widgets", "theme"] {
            let fixture = try Fixture()
            defer { fixture.close() }
            try fixture.installPackage(kind: kind, version: "1")
            try fixture.installPackage(kind: kind, version: "2")
            let module = fixture.url.deletingLastPathComponent().appending(path: "module.json")
            let key = kind == "theme" ? "theme" : "packages"
            let selection = #"{"id":"sample","version":"1","settings":{}}"#
            let included = Data((kind == "theme" ? #"{"theme":\#(selection)}"# : #"{"packages":[\#(selection)]}"#).utf8)
            try included.write(to: module)
            try Data(#"{"includes":["module.json"],"widgets":[]}"#.utf8).write(to: fixture.url)
            let store = fixture.store
            store.reloadConfiguration()
            try store.applyEdits([ConfigurationEdit(action: .bar, properties: ["height": .number(60)])], persist: false)
            try store.uninstallPackage(id: "sample", version: "1", fromCustomization: true)
            XCTAssertEqual(store.sessionEdits.count, 1)
            XCTAssertNil(try fixture.document()["bar"])
            XCTAssertNotNil(try fixture.document()[key])
            XCTAssertEqual(store.configuration?.bar.height, 60)
            XCTAssertEqual(try Data(contentsOf: module), included)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.packageURL("1").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.packageURL("2").path))
            store.reloadConfiguration()
            XCTAssertNil(store.configurationError)
            XCTAssertFalse(store.customizationHistory.canUndo)
            XCTAssertTrue(store.customizationHistory.notice?.contains("uninstalled package") == true)
        }
    }

    @MainActor func testCustomizeUninstallRejectsAStillTemporaryPackageSelection() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try fixture.installPackage(kind: "widgets", version: "1")
        let store = fixture.store
        try store.applyEdits([ConfigurationEdit(action: .package, properties: ["id": .string("sample"), "version": .string("1")])], persist: false)
        let before = try Data(contentsOf: fixture.url)
        XCTAssertThrowsError(try store.uninstallPackage(id: "sample", version: "1", fromCustomization: true))
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
        XCTAssertEqual(store.sessionEdits.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.packageURL("1").path))
    }
}

@MainActor
private final class Fixture {
    let url: URL
    let store: BarStore

    init(configuration: String = #"{"bar":{"height":40},"widgets":[{"id":"a","type":"text","position":"left","text":"A"}]}"#) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appending(path: "config.json")
        try Data(configuration.utf8).write(to: url)
        store = BarStore(configurationURL: url, themesDirectory: nil)
        store.reloadConfiguration()
        XCTAssertNil(store.configurationError)
    }

    func document() throws -> [String: ConfigurationValue] {
        try JSONDecoder().decode([String: ConfigurationValue].self, from: Data(contentsOf: url))
    }

    func packageURL(_ version: String) -> URL {
        url.deletingLastPathComponent().appending(path: "packages/sample/\(version)")
    }

    func installPackage(kind: String, version: String) throws {
        let directory = packageURL(version)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"id":"sample","name":"Sample","version":"\#(version)","kind":"\#(kind)","entry":"config.json"}"#.utf8)
            .write(to: directory.appending(path: "package.json"))
        try Data(#"{"bar":{"height":48}}"#.utf8).write(to: directory.appending(path: "config.json"))
    }

    func close() {
        store.stop()
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
