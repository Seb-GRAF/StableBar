import AppKit
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
        await history.writeTask?.value
        XCTAssertFalse(history.hasPendingChanges)
        XCTAssertEqual(history.undoSteps.count, 1)
        XCTAssertEqual(try fixture.document()["widgets"]?.decoded([[String: ConfigurationValue]].self)[0]["text"], .string("Burst"))
        let saved = try Data(contentsOf: fixture.url)
        await Task.yield()
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
            XCTAssertTrue(history.notice?.contains("changed outside Settings") == true)
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
        let pending = history.writeTask
        try history.undo()
        await pending?.value
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
        XCTAssertNil(editor.history.notice)
        XCTAssertFalse(editor.history.canUndo)
        store.reloadConfiguration()
        XCTAssertNil(editor.history.notice)
        try editor.history.undo()
        XCTAssertEqual(store.configuration?.widgets[0].content, .text("Temporary"))
        XCTAssertEqual(store.configuration?.bar.height, 48)
    }

    @MainActor func testHistoryNoticeClearsAfterASuccessfulChangeOrPendingUndo() throws {
        for undoPending in [false, true] {
            let fixture = try Fixture()
            defer { fixture.close() }
            let history = fixture.store.customizationHistory
            try history.change(ConfigurationEdit(action: .bar, properties: ["height": .number(48)]))
            if !undoPending { try history.flush() }
            let external = Data(#"{"bar":{"height":55},"widgets":[]}"#.utf8)
            try external.write(to: fixture.url)
            fixture.store.reloadConfiguration()
            XCTAssertNotNil(history.notice)
            if undoPending {
                try history.undo()
                XCTAssertEqual(try Data(contentsOf: fixture.url), external)
            } else {
                try history.change(ConfigurationEdit(action: .defaults, properties: ["fontSize": .number(16)]))
                XCTAssertNil(history.notice)
                try history.flush()
                XCTAssertTrue(history.canUndo)
                try history.undo()
                XCTAssertNil(history.notice)
                try history.redo()
            }
            XCTAssertNil(history.notice)
        }
    }

    @MainActor func testClosingCustomizeClearsTheHistoryNotice() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let history = fixture.store.customizationHistory
        try history.change(ConfigurationEdit(action: .bar, properties: ["height": .number(48)]))
        try history.flush()
        try Data(#"{"widgets":[]}"#.utf8).write(to: fixture.url)
        fixture.store.reloadConfiguration()
        XCTAssertNotNil(history.notice)
        CustomizationWindow(store: fixture.store).windowWillClose(Notification(name: NSWindow.willCloseNotification))
        XCTAssertNil(history.notice)
    }

    func testConfigurationErrorBannerCoversEditableSectionsAndAvoidsDiagnosticDuplicates() {
        for section in CustomizationSection.allCases {
            let editingSection = [.appearance, .widgets, .profiles, .general].contains(section)
            XCTAssertEqual(section.bannerError(customization: nil, configuration: "File error"), editingSection ? "File error" : nil)
            XCTAssertEqual(section.bannerError(customization: "Save error", configuration: "File error"), "Save error")
            XCTAssertEqual(section.bannerError(customization: "File error", configuration: "File error"), editingSection ? "File error" : nil)
        }
    }

    @MainActor func testReorderingAndEditingSavedWidgetsKeepsCommandLineWidgetsTemporary() throws {
        let fixture = try Fixture(configuration: #"{"widgets":[{"id":"a","type":"text","position":"left","text":"A"},{"id":"b","type":"text","position":"left","text":"B"}]}"#)
        defer { fixture.close() }
        let store = fixture.store
        let temporary = ConfigurationEdit(action: .add, properties: ["id": .string("temporary"), "type": .string("text"),
                                                                      "position": .string("left"), "text": .string("Temporary")])
        try store.applyEdits([temporary], persist: false)
        let history = store.customizationHistory
        try history.change(ConfigurationEdit(action: .reorder, ids: ["b", "temporary", "a"]))
        XCTAssertEqual(try fixture.document()["widgets"]?.decoded([[String: ConfigurationValue]].self).compactMap { $0["id"] }, [.string("b"), .string("a")])
        XCTAssertNil(try fixture.document()["widgetOrder"])
        XCTAssertEqual(store.configuration?.widgets.map(\.id), ["b", "a", "temporary"])
        XCTAssertEqual(store.sessionEdits.count, 1)
        try history.undo()
        XCTAssertEqual(store.configuration?.widgets.map(\.id), ["a", "b", "temporary"])
        try history.redo()
        XCTAssertEqual(store.configuration?.widgets.map(\.id), ["b", "a", "temporary"])
        try history.change(ConfigurationEdit(action: .set, id: "a", properties: ["text": .string("Saved")]))
        try history.flush()
        XCTAssertEqual(store.configuration?.widgets.first(where: { $0.id == "a" })?.content, .text("Saved"))
        XCTAssertEqual(try fixture.document()["widgets"]?.decoded([[String: ConfigurationValue]].self).count, 2)
        XCTAssertEqual(store.configuration?.widgets.last?.content, .text("Temporary"))
        XCTAssertEqual(store.sessionEdits.count, 1)
        store.reloadConfiguration()
        XCTAssertNil(store.configurationError)
        XCTAssertEqual(store.configuration?.widgets.map(\.id), ["b", "a", "temporary"])
    }

    @MainActor func testEditingCommandLineOnlyWidgetsExplainsHowToProceed() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let store = fixture.store
        try store.applyEdits([ConfigurationEdit(action: .add, properties: ["id": .string("temporary"), "type": .string("text"),
                                                                          "position": .string("left"), "text": .string("Temporary")])], persist: false)
        let original = try Data(contentsOf: fixture.url)
        let editor = ConfigurationEditor(store: store)
        editor.selectedID = "temporary"
        for action in [ConfigurationEdit.Action.set, .remove, .unset] {
            editor.change(ConfigurationEdit(action: action, id: "temporary", properties: ["text": .string("Saved")]))
            XCTAssertEqual(editor.error, "Save or discard command-line changes before editing this widget.")
            XCTAssertFalse(editor.history.hasPendingChanges)
            XCTAssertEqual(try Data(contentsOf: fixture.url), original)
            XCTAssertEqual(store.sessionEdits.count, 1)
            XCTAssertEqual(store.configuration?.widgets.last?.content, .text("Temporary"))
        }
        editor.saveCommandLineChanges()
        XCTAssertNil(editor.error)
        editor.set(["text": .string("Saved")])
        try editor.history.flush()
        XCTAssertNil(editor.error)
        XCTAssertEqual(store.configuration?.widgets.last?.content, .text("Saved"))
        XCTAssertTrue(store.sessionEdits.isEmpty)
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

    @MainActor func testRemovedPendingTargetsDoNotBlockUndoChangesCloseQuitOrCommands() throws {
        try assertRecovery(from: .removedProfile)
        try assertRecovery(from: .removedWidget)
    }

    @MainActor func testDeletedFileDoesNotLeaveABlockingPendingChange() throws {
        try assertRecovery(from: .deletedFile)
    }

    @MainActor func testUnreadableFileDoesNotLeaveABlockingPendingChange() throws {
        try assertRecovery(from: .unreadableFile)
    }

    @MainActor func testTimerDiscardsFailedPendingChangesWithoutWritingThemLater() async throws {
        for failure in PendingFailure.allCases {
            let fixture = try recoveryFixture()
            defer { fixture.close() }
            let history = fixture.store.customizationHistory
            try beginPendingChange(failure, in: fixture)
            let repair = try breakFile(failure, in: fixture)
            fixture.store.reloadConfiguration()
            await history.writeTask?.value
            XCTAssertFalse(history.hasPendingChanges, "\(failure)")
            XCTAssertTrue(history.error?.contains("could not be saved and was discarded") == true)
            XCTAssertTrue(history.undoSteps.isEmpty)
            try history.undo()
            try repair()
            fixture.store.reloadConfiguration()
            XCTAssertNil(fixture.store.configurationError)
            XCTAssertFalse(history.hasPendingChanges)
            XCTAssertFalse(history.canUndo)
            XCTAssertNotEqual(fixture.store.configuration?.widgets.first?.content, .text("Pending"))
            XCTAssertNil(fixture.store.profiles.first?.when?.app)
        }
    }

    @MainActor func testUndoDiscardsPendingChangesWithoutSavingAndKeepsSafeRedo() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let history = fixture.store.customizationHistory
        try history.change(ConfigurationEdit(action: .bar, properties: ["height": .number(48)]))
        let original = try Data(contentsOf: fixture.url)
        try history.undo()
        XCTAssertEqual(try Data(contentsOf: fixture.url), original)
        XCTAssertEqual(fixture.store.configuration?.bar.height, 40)
        XCTAssertFalse(history.hasPendingChanges)
        XCTAssertFalse(history.canUndo)
        XCTAssertTrue(history.canRedo)
        try history.redo()
        XCTAssertEqual(fixture.store.configuration?.bar.height, 48)
        XCTAssertEqual(try fixture.document()["bar"], .object(["height": .number(48)]))
    }

    @MainActor private func assertRecovery(from failure: PendingFailure) throws {
        for action in ["undo", "change", "close", "quit", "command"] {
            let fixture = try recoveryFixture()
            defer { fixture.close() }
            let store = fixture.store
            let history = store.customizationHistory
            try beginPendingChange(failure, in: fixture)
            let repair = try breakFile(failure, in: fixture)
            defer { try? repair() }
            store.reloadConfiguration()
            XCTAssertNotNil(store.configurationError)
            let unavailable = failure == .deletedFile || failure == .unreadableFile
            switch action {
            case "undo": try history.undo()
            case "change":
                let edit = ConfigurationEdit(action: .bar, properties: ["height": .number(48)])
                if unavailable { XCTAssertThrowsError(try history.change(edit)) }
                else { try history.change(edit); try history.flush() }
            case "close":
                CustomizationWindow(store: store).windowWillClose(Notification(name: NSWindow.willCloseNotification))
            case "quit":
                XCTAssertEqual(AppDelegate(store: store).applicationShouldTerminate(NSApplication.shared), .terminateNow)
            default:
                for request in [RuntimeRequest(action: .reload), RuntimeRequest(action: .reset),
                                RuntimeRequest(action: .batch, edits: [ConfigurationEdit(action: .bar, properties: ["height": .number(52)])])] {
                    if unavailable { XCTAssertThrowsError(try store.handle(request)) }
                    else { _ = try store.handle(request) }
                }
            }
            XCTAssertFalse(history.hasPendingChanges, "\(failure), \(action)")
            if unavailable {
                XCTAssertNotEqual(store.configuration?.widgets.first?.content, .text("Pending"))
                XCTAssertNil(store.profiles.first?.when?.app)
            }
            try repair()
            store.reloadConfiguration()
            XCTAssertNil(store.configurationError)
            XCTAssertFalse(history.hasPendingChanges)
            try history.undo()
            try history.change(ConfigurationEdit(action: .bar, properties: ["height": .number(49)]))
            try history.flush()
            XCTAssertEqual(try fixture.document()["bar"], .object(["height": .number(49)]))
            for request in [RuntimeRequest(action: .reload), RuntimeRequest(action: .reset),
                            RuntimeRequest(action: .batch, edits: [ConfigurationEdit(action: .bar, properties: ["height": .number(53)])])] {
                XCTAssertNoThrow(try store.handle(request))
            }
            CustomizationWindow(store: store).windowWillClose(Notification(name: NSWindow.willCloseNotification))
            XCTAssertEqual(AppDelegate(store: store).applicationShouldTerminate(NSApplication.shared), .terminateNow)
            XCTAssertFalse(history.hasPendingChanges)
        }
    }

    private enum PendingFailure: CaseIterable {
        case removedProfile, removedWidget, deletedFile, unreadableFile
    }

    @MainActor private func recoveryFixture() throws -> Fixture {
        try Fixture(configuration: #"{"bar":{"height":40},"widgets":[{"id":"a","type":"text","position":"left","text":"A"}],"profiles":[{"name":"work","configuration":{}}]}"#)
    }

    @MainActor private func beginPendingChange(_ failure: PendingFailure, in fixture: Fixture) throws {
        let history = fixture.store.customizationHistory
        if failure == .removedProfile {
            try history.setProfileCondition("work", \.app, value: "com.pending", control: "app")
        } else {
            try history.change(ConfigurationEdit(action: .set, id: "a", properties: ["text": .string("Pending")]))
        }
    }

    @MainActor private func breakFile(_ failure: PendingFailure, in fixture: Fixture) throws -> () throws -> Void {
        let original = try Data(contentsOf: fixture.url)
        switch failure {
        case .removedProfile, .removedWidget:
            var document = try fixture.document()
            if failure == .removedProfile { document["profiles"] = nil }
            else { document["widgets"] = .array([]) }
            try configurationData(document).write(to: fixture.url)
            return {}
        case .deletedFile:
            try FileManager.default.removeItem(at: fixture.url)
            return { if !FileManager.default.fileExists(atPath: fixture.url.path) { try original.write(to: fixture.url) } }
        case .unreadableFile:
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: fixture.url.path)
            XCTAssertThrowsError(try Data(contentsOf: fixture.url))
            return { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.url.path) }
        }
    }

    @MainActor func testAChangeKeepsThePreviousPendingDiscardExplanationUntilAnotherAction() async throws {
        for immediate in [false, true] {
            let fixture = try Fixture()
            defer { fixture.close() }
            let history = fixture.store.customizationHistory
            try history.change(.init(action: .set, id: "a", properties: ["text": .string("Lost")]))
            try Data(#"{"bar":{"height":40},"widgets":[]}"#.utf8).write(to: fixture.url)
            let edit = ConfigurationEdit(action: .bar, properties: ["height": .number(52)])
            if immediate { try history.change([edit]) }
            else { try history.change(edit); await history.writeTask?.value }
            XCTAssertEqual(fixture.store.configuration?.bar.height, 52)
            XCTAssertFalse(history.hasPendingChanges)
            XCTAssertTrue(history.error?.contains("could not be saved and was discarded") == true)
            try history.change(.init(action: .bar, properties: ["height": .number(54)]))
            XCTAssertNil(history.error)
            try history.flush()
            try history.undo()
            XCTAssertNil(history.error)
        }
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

    @MainActor func testSettingAndClearingAnAbsentProfileConditionInOneBurstDoesNotSave() throws {
        for inherited in [false, true] {
            let profile = #"{"widgets":[],"profiles":[{"name":"work","configuration":{}}]}"#
            let fixture = try Fixture(configuration: inherited ? #"{"widgets":[]}"# : profile)
            defer { fixture.close() }
            let included = fixture.url.deletingLastPathComponent().appending(path: "profiles.json")
            if inherited {
                try Data(profile.utf8).write(to: included)
                try Data(#"{"widgets":[],"includes":["profiles.json"]}"#.utf8).write(to: fixture.url)
                fixture.store.reloadConfiguration()
            }
            let original = try Data(contentsOf: fixture.url)
            let editor = ConfigurationEditor(store: fixture.store)
            editor.setProfileCondition("work", \.app, value: "com.example", control: "app")
            editor.setProfileCondition("work", \.app, value: nil, control: "app")
            try editor.history.flush()
            XCTAssertNil(editor.error)
            XCTAssertNil(fixture.store.profiles.first?.when)
            XCTAssertEqual(try Data(contentsOf: fixture.url), original)
            XCTAssertTrue(editor.undoSteps.isEmpty)
            XCTAssertFalse(editor.history.hasPendingChanges)
            XCTAssertFalse(editor.history.canUndo)
            if inherited { XCTAssertEqual(try Data(contentsOf: included), Data(profile.utf8)) }
        }
    }

    @MainActor func testEnabledRefusesCommandLineOnlyProfilesAndStillAllowsAddingProfiles() throws {
        let fixture = try Fixture(configuration: #"{"widgets":[]}"#)
        defer { fixture.close() }
        let store = fixture.store
        let original = try Data(contentsOf: fixture.url)
        try store.applyEdits([ConfigurationEdit(action: .profiles, profiles: [
            ["name": .string("temporary"), "configuration": .object([:])]
        ])], persist: false)
        let editor = ConfigurationEditor(store: store)
        var profile = try XCTUnwrap(store.profiles.first)
        profile.enabled = false
        editor.setProfile(profile)
        XCTAssertEqual(editor.error, "Save command-line changes before editing this profile.")
        XCTAssertEqual(try Data(contentsOf: fixture.url), original)
        XCTAssertTrue(editor.undoSteps.isEmpty)
        XCTAssertFalse(editor.history.hasPendingChanges)
        XCTAssertEqual(store.sessionEdits.count, 1)
        editor.discardCommandLineChanges()
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.url), original)
        editor.addProfile(name: "new")
        XCTAssertNil(editor.error)
        XCTAssertEqual(store.profiles.map(\.name), ["new"])
        XCTAssertEqual(editor.undoSteps.count, 1)
        XCTAssertEqual(try fixture.document()["profiles"]?.decoded([ConfigurationProfile].self).map(\.name), ["new"])
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
        try store.applyEdits([ConfigurationEdit(action: .profiles, profiles: [
            ["name": .string("work"), "when": .object(["app": .string("com.temporary")]),
             "configuration": .object(["bar": .object(["margin": .number(10)])])]
        ])], persist: false)
        let editor = ConfigurationEditor(store: store)
        editor.setProfileCondition("work", \.onBattery, value: true, control: "onBattery")
        try editor.history.flush()
        var saved = try XCTUnwrap(fixture.document()["profiles"]).decoded([ConfigurationProfile].self)
        XCTAssertNil(saved[0].when?.app)
        XCTAssertEqual(saved[0].when?.onBattery, true)
        editor.setProfileConfiguration(name: "work", configuration: ["bar": .object(["height": .number(48), "margin": .number(10)])])
        editor.addProfile(name: "extra")
        saved = try XCTUnwrap(fixture.document()["profiles"]).decoded([ConfigurationProfile].self)
        XCTAssertNil(saved[0].when?.app)
        XCTAssertEqual(saved.map(\.name), ["work", "extra"])
        XCTAssertEqual(saved[0].configuration["bar"], .object(["height": .number(48)]))
        XCTAssertEqual(store.sessionEdits.count, 1)
        XCTAssertEqual(store.profiles[0].when?.app, "com.temporary")
        XCTAssertEqual(store.profiles[0].configuration["bar"], .object(["height": .number(48), "margin": .number(10)]))
    }

    @MainActor func testProfileControlsSaveOnlyChangedPropertiesAcrossPackageAndIncludeLayers() throws {
        let fixture = try Fixture(configuration: #"{"widgets":[]}"#)
        defer { fixture.close() }
        try fixture.installPackage(kind: "widgets", version: "1")
        let package = fixture.packageURL("1").appending(path: "config.json")
        let packageData = Data(#"{"profiles":[{"name":"work","when":{"appearance":"light"},"configuration":{"bar":{"height":36,"spacing":7}}},{"name":"package-only"}]}"#.utf8)
        try packageData.write(to: package)
        let included = fixture.url.deletingLastPathComponent().appending(path: "included.json")
        let imported = Data(#"{"profiles":[{"name":"work","when":{"app":"com.inherited"},"configuration":{"bar":{"height":38}}},{"name":"include-only"}]}"#.utf8)
        try imported.write(to: included)
        let original = Data(#"{"widgets":[],"packages":[{"id":"sample","version":"1"}],"includes":["included.json"],"profiles":[{"name":"work","configuration":{"bar":{"offset":2}}}]}"#.utf8)
        try original.write(to: fixture.url)
        let store = fixture.store
        store.reloadConfiguration()
        XCTAssertNil(store.configurationError)
        _ = try XCTUnwrap(store.profiles.first)
        let editor = ConfigurationEditor(store: store)
        for app in ["c", "co", "com.edited"] {
            editor.setProfileCondition("work", \.app, value: app, control: "app")
        }
        try editor.history.flush()
        XCTAssertEqual(editor.undoSteps.count, 1)
        let initialOverride: [String: ConfigurationValue] = [
            "name": .string("work"), "when": .object(["app": .string("com.edited")]),
            "configuration": .object(["bar": .object(["offset": .number(2)])])
        ]
        XCTAssertEqual(try fixture.document()["profiles"]?.decoded([[String: ConfigurationValue]].self), [initialOverride])
        editor.undo()
        XCTAssertEqual(try Data(contentsOf: fixture.url), original)
        editor.redo()
        XCTAssertEqual(store.profiles.map(\.name), ["work", "package-only", "include-only"])

        editor.setProfileCondition("work", \.appearance, value: nil, control: "appearance")
        try editor.history.flush()
        XCTAssertNil(try XCTUnwrap(store.profiles.first).when?.appearance)
        var configuration = try XCTUnwrap(store.profiles.first).configuration
        configuration["bar"] = .object(["height": .number(44), "spacing": .number(7)])
        editor.setProfileConfiguration(name: "work", configuration: configuration)
        var edited = try XCTUnwrap(store.profiles.first)
        edited.enabled = false
        editor.setProfile(edited)
        editor.addProfile(name: "extra")
        XCTAssertNil(editor.error)
        let saved = try XCTUnwrap(fixture.document()["profiles"]).decoded([[String: ConfigurationValue]].self)
        XCTAssertEqual(saved.map { $0["name"] }, [.string("work"), .string("extra")])
        XCTAssertEqual(saved[0], [
            "name": .string("work"), "enabled": .bool(false),
            "when": .object(["app": .string("com.edited"), "appearance": .null]),
            "configuration": .object(["bar": .object(["height": .number(44), "offset": .null])])
        ])
        XCTAssertEqual(try Data(contentsOf: included), imported)
        XCTAssertEqual(try Data(contentsOf: package), packageData)

        try Data(String(decoding: packageData, as: UTF8.self).replacingOccurrences(of: "7", with: "9").utf8).write(to: package)
        store.reloadConfiguration()
        XCTAssertEqual(store.profiles[0].configuration["bar"], .object(["height": .number(44), "spacing": .number(9), "offset": .null]))
    }

    @MainActor func testLiquidGlassControlsSaveAndUndoWithoutCopyingInheritedSettings() throws {
        let fixture = try Fixture(configuration: #"{"widgets":[]}"#)
        defer { fixture.close() }
        let included = fixture.url.deletingLastPathComponent().appending(path: "included.json")
        let imported = Data(#"{"bar":{"glass":{"transparency":0.6,"popups":false}}}"#.utf8)
        try imported.write(to: included)
        try Data(#"{"widgets":[],"includes":["included.json"]}"#.utf8).write(to: fixture.url)
        fixture.store.reloadConfiguration()
        let original = try Data(contentsOf: fixture.url)
        let editor = ConfigurationEditor(store: fixture.store)
        editor.change(ConfigurationEdit(action: .bar, properties: ["glass": .object(["enabled": .bool(true)])]))
        try editor.history.flush()
        XCTAssertEqual(fixture.store.configuration?.bar.glass.enabled, true)
        XCTAssertEqual(fixture.store.configuration?.bar.glass.transparency, 0.6)
        XCTAssertEqual(fixture.store.configuration?.bar.glass.popups, false)
        XCTAssertEqual(try fixture.document()["bar"], .object(["glass": .object(["enabled": .bool(true)])]))
        editor.undo()
        XCTAssertEqual(try Data(contentsOf: fixture.url), original)
        editor.redo()
        XCTAssertEqual(fixture.store.configuration?.bar.glass.enabled, true)
        XCTAssertEqual(try Data(contentsOf: included), imported)
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
        store = BarStore(configurationURL: url, themesDirectory: nil, customizationSaveDelay: .zero)
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
