import XCTest
@testable import StableBar

final class ConfigurationEditorTests: XCTestCase {
    @MainActor func testProfileScreenPreviewIncludesDisabledProfileWidgetsWithoutActivatingIt() throws {
        let fixture = try ThemeGalleryFixture(#"""
        {"profile":"Other","widgets":[{"id":"clock","type":"clock","position":"right"}],
         "profiles":[
           {"name":"Main","enabled":false,"when":{"displayCount":2},"configuration":{
             "widgetOverrides":{"clock":{"display":"main"}},
             "widgets":[{"id":"extra","type":"text","position":"left","text":"Extra","display":"builtIn"}]}},
           {"name":"Other","configuration":{"widgetOverrides":{"clock":{"display":"external"}}}}]}
        """#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        store.reloadConfiguration()
        let original = try Data(contentsOf: fixture.url)
        let (configuration, loader) = try store.configurationForProfile("Main")
        XCTAssertEqual(configuration.widgets.map(\.id), ["clock", "extra"])
        XCTAssertEqual(configuration.widgets.map(\.display), [.main, .builtIn])
        XCTAssertEqual(loader.origins["widgets.clock.display"]?.profile, "Main")
        XCTAssertEqual(store.configuration?.widgets.map(\.display), [.external])
        XCTAssertEqual(store.activeProfiles, ["Other"])
        XCTAssertEqual(store.pinnedProfile, "Other")
        XCTAssertFalse(store.profiles[0].enabled)
        XCTAssertEqual(try Data(contentsOf: fixture.url), original)
        XCTAssertTrue(store.customizationEdits.isEmpty)
        XCTAssertTrue(store.sessionEdits.isEmpty)
    }

    @MainActor func testProfileScreenEditsSaveOnlyTheirOverrideAndResetToImportedSettings() throws {
        let fixture = try ThemeGalleryFixture(#"""
        {"includes":["included.json"],"profile":"Other",
         "profiles":[{"name":"Main","configuration":{"widgetOverrides":{"clock":{"style":{"fontSize":18}}}}}]}
        """#)
        defer { fixture.close() }
        let included = fixture.directory.appending(path: "included.json")
        let imported = #"""
        {"tokens":{"screen":"builtIn"},
         "templates":{"time":{"type":"clock","position":"right","display":"external"}},
         "widgets":[{"id":"clock","template":"time"}],
         "profiles":[
           {"name":"Main","configuration":{"widgetOverrides":{"clock":{"display":"@token.screen"}}}},
           {"name":"Other","configuration":{}}]}
        """#
        try fixture.write(imported, to: included)
        let store = try fixture.store()
        defer { store.stop() }
        store.reloadConfiguration()
        let editor = ConfigurationEditor(store: store)
        let original = try fixture.document()
        XCTAssertEqual(try store.configurationForProfile("Main").0.widgets[0].display, .builtIn)

        editor.setProfileWidgetDisplay(.string("main"), for: "clock", profile: store.profiles[0])
        XCTAssertNil(editor.error)
        XCTAssertEqual(store.configuration?.widgets[0].display, .external)
        let profiles = try XCTUnwrap(fixture.document()["profiles"]).decoded([[String: ConfigurationValue]].self)
        XCTAssertEqual(profiles, [["name": .string("Main"), "configuration": .object([
            "widgetOverrides": .object(["clock": .object(["display": .string("main"), "style": .object(["fontSize": .number(18)])])])
        ])]])
        XCTAssertEqual(try store.configurationForProfile("Main").0.widgets[0].display, .main)
        editor.setProfileWidgetDisplay(.string("main"), for: "clock", profile: store.profiles[0])
        XCTAssertEqual(editor.undoSteps.count, 1)

        editor.setProfileWidgetDisplay(nil, for: "clock", profile: store.profiles[0])
        try editor.history.flush()
        XCTAssertNil(editor.error)
        XCTAssertEqual(try fixture.document(), original)
        XCTAssertEqual(try store.configurationForProfile("Main").0.widgets[0].display, .builtIn)
        editor.undo()
        XCTAssertEqual(try store.configurationForProfile("Main").0.widgets[0].display, .main)
        editor.redo()
        XCTAssertEqual(try store.configurationForProfile("Main").0.widgets[0].display, .builtIn)
        XCTAssertEqual(try String(contentsOf: included, encoding: .utf8), imported)
        try fixture.write(imported.replacingOccurrences(of: "\"screen\":\"builtIn\"", with: "\"screen\":\"all\""), to: included)
        store.reloadConfiguration()
        XCTAssertEqual(try store.configurationForProfile("Main").0.widgets[0].display, .all)
    }

    @MainActor func testProfileScreensKeepMainWidgetsVisibleWhenTheMacBookBecomesSecondary() throws {
        let fixture = try ThemeGalleryFixture(#"""
        {"profile":"Main",
         "widgets":[{"id":"clock","type":"clock","position":"right"},{"id":"system","type":"system","position":"right"}],
         "profiles":[{"name":"Main","configuration":{}},{"name":"Other","configuration":{}}]}
        """#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        store.reloadConfiguration()
        let editor = ConfigurationEditor(store: store)
        editor.setProfileWidgetDisplay(.string("main"), for: "system", profile: store.profiles[0])
        XCTAssertNil(editor.error)
        let widgets = try XCTUnwrap(store.configuration).widgets
        let external = BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil)
        let secondary = BarDisplay(id: 2, isBuiltIn: true, isMain: false, notch: 650...870)
        let laptopOnly = BarDisplay(id: 1, isBuiltIn: true, isMain: true, notch: 650...870)
        for display in [external, laptopOnly] {
            XCTAssertEqual(widgets.filter { $0.display.includes(display, activeID: 1) }.map(\.id), ["clock", "system"])
        }
        XCTAssertEqual(widgets.filter { $0.display.includes(secondary, activeID: 1) }.map(\.id), ["clock"])
        XCTAssertEqual(try store.configurationForProfile("Other").0.widgets.map(\.display), [.all, .all])

        editor.setProfileWidgetDisplay(.array([.number(2)]), for: "system", profile: store.profiles[0])
        XCTAssertEqual(store.configuration?.widgets[1].display, .ids([2]))
        editor.undo()
        XCTAssertEqual(store.configuration?.widgets[1].display, .main)
        editor.redo()
        XCTAssertEqual(store.configuration?.widgets[1].display, .ids([2]))
    }

    @MainActor func testUnchangedProfileApplyKeepsAFailedPendingSaveVisible() throws {
        let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"a","type":"text","position":"left","text":"A"}],"profiles":[{"name":"work","configuration":{"bar":{"height":40}}}]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        store.reloadConfiguration()
        let editor = ConfigurationEditor(store: store)
        let profile = try XCTUnwrap(store.profiles.first)
        editor.set(["text": .string("Pending")], for: "a")
        XCTAssertTrue(editor.history.hasPendingChanges)
        XCTAssertNil(editor.error)
        let external = Data(#"{"widgets":[],"profiles":[{"name":"work","configuration":{"bar":{"height":40}}}]}"#.utf8)
        try external.write(to: fixture.url)

        editor.setProfileConfiguration(name: profile.name, configuration: profile.configuration)

        XCTAssertTrue(editor.error?.contains("could not be saved and was discarded") == true)
        XCTAssertFalse(editor.history.hasPendingChanges)
        XCTAssertTrue(editor.undoSteps.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.url), external)
        XCTAssertTrue(try XCTUnwrap(store.configuration).widgets.isEmpty)
    }

    @MainActor func testUnchangedProfileApplyClearsAnEarlierConfigurationError() throws {
        for wholeProfile in [false, true] {
            let fixture = try ThemeGalleryFixture(#"{"widgets":[],"profiles":[{"name":"work","configuration":{"bar":{"height":40}}}]}"#)
            defer { fixture.close() }
            let store = try fixture.store()
            defer { store.stop() }
            store.reloadConfiguration()
            let original = try Data(contentsOf: fixture.url)
            let profile = try XCTUnwrap(store.profiles.first)
            let editor = ConfigurationEditor(store: store)
            let invalid = try JSONDecoder().decode([String: ConfigurationValue].self, from: Data(#"{"bar":{"height":"invalid"}}"#.utf8))
            if wholeProfile {
                var edited = profile
                edited.configuration = invalid
                editor.setProfile(edited)
            } else {
                editor.setProfileConfiguration(name: profile.name, configuration: invalid)
            }
            XCTAssertNotNil(editor.error)
            XCTAssertEqual(try Data(contentsOf: fixture.url), original)
            if wholeProfile { editor.setProfile(profile) }
            else { editor.setProfileConfiguration(name: profile.name, configuration: profile.configuration) }
            XCTAssertNil(editor.error)
            XCTAssertEqual(try Data(contentsOf: fixture.url), original)
            XCTAssertTrue(editor.undoSteps.isEmpty)
            XCTAssertFalse(editor.history.hasPendingChanges)
        }
    }

    @MainActor func testProgrammaticSelectionCommitsPendingTextBeforeChangingItsWidget() async throws {
        let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"a","type":"clock","position":"right"},{"id":"b","type":"clock","position":"right"}]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        var editor: ConfigurationEditor!
        var pending: Double?
        var committedIDs: [String] = []
        editor = ConfigurationEditor(store: store, endEditing: {
            guard let value = pending, let id = editor.selectedID else { return }
            pending = nil
            committedIDs.append(id)
            editor.set(["style": .object(["fontSize": .number(value)])])
        })
        pending = 17
        editor.selectedID = "b"
        XCTAssertEqual(committedIDs, ["a"])
        XCTAssertEqual(editor.style(for: "a")["fontSize"], .number(17))
        XCTAssertNil(editor.properties(for: "b")["style"])
        pending = 19
        let added = await WidgetSetup(store: store).add(try XCTUnwrap(WidgetAddCatalog.builtIns.first { $0.id == "text" }), to: .left)
        editor.selectedID = try XCTUnwrap(added)
        XCTAssertEqual(committedIDs, ["a", "b"])
        XCTAssertEqual(editor.style(for: "b")["fontSize"], .number(19))
        XCTAssertNil(editor.selected["style"])
        pending = 21
        editor.showWidget("a")
        XCTAssertEqual(committedIDs, ["a", "b", added!])
        XCTAssertEqual(editor.section, .widgets)
        XCTAssertEqual(editor.selectedID, "a")
        XCTAssertEqual(editor.style(for: added!)["fontSize"], .number(21))
        XCTAssertEqual(editor.style(for: "a")["fontSize"], .number(17))
        editor.showWidget("missing")
        XCTAssertEqual(editor.selectedID, "a")
        XCTAssertNil(editor.error)
        try editor.history.flush()
    }

    @MainActor func testRemoveCommitsPendingTextBeforeRemovingTheWidgetAndKeepsUndoStepsInOrder() throws {
        let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"a","type":"clock","position":"right"},{"id":"b","type":"clock","position":"right"}]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        var editor: ConfigurationEditor!
        var pending = true
        var committedID: String?
        editor = ConfigurationEditor(store: store, endEditing: {
            guard pending else { return }
            pending = false
            committedID = editor.selectedID
            editor.set(["style": .object(["fontSize": .number(18)])])
        })
        editor.change(ConfigurationEdit(action: .remove, id: "a"))
        XCTAssertEqual(committedID, "a")
        XCTAssertEqual(editor.selectedID, "b")
        XCTAssertNil(editor.error)
        XCTAssertNil(editor.properties(for: "b")["style"])
        XCTAssertEqual(editor.history.undoSteps.count, 2)
        editor.undo()
        XCTAssertEqual(editor.style(for: "a")["fontSize"], .number(18))
        editor.undo()
        XCTAssertNil(editor.properties(for: "a")["style"])
    }

    @MainActor func testUndoRedoAndSelectionRepairEndEditingWhileTheOldWidgetIsStillSelected() async throws {
        let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"a","type":"clock","position":"right"}]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        var editor: ConfigurationEditor!
        var endedOn: [String?] = []
        editor = ConfigurationEditor(store: store, endEditing: { endedOn.append(editor.selectedID) })
        let added = await WidgetSetup(store: store).add(try XCTUnwrap(WidgetAddCatalog.builtIns.first { $0.id == "text" }), to: .left)
        editor.selectedID = try XCTUnwrap(added)
        endedOn = []
        editor.undo()
        XCTAssertEqual(endedOn.first!, added)
        XCTAssertEqual(editor.selectedID, "a")
        endedOn = []
        editor.redo()
        XCTAssertEqual(endedOn.first!, "a")
        editor.selectedID = added
        try WidgetSetup(store: store).remove(try XCTUnwrap(added))
        endedOn = []
        editor.keepSelection()
        XCTAssertEqual(endedOn, [added])
        XCTAssertEqual(editor.selectedID, "a")
    }

    @MainActor func testBarRemovalUsesTheSamePendingEditingBoundaryBeforeChangingTheConfiguration() throws {
        let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"a","type":"clock","position":"right"},{"id":"b","type":"clock","position":"right"}]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        var editor: ConfigurationEditor!
        var pending = false
        editor = ConfigurationEditor(store: store, endEditing: {
            guard pending else { return }
            pending = false
            editor.set(["style": .object(["fontSize": .number(22)])])
        })
        store.onEndCustomizationEditing = { editor.finishEditing() }
        store.barEditing.begin()
        pending = true
        store.barEditing.remove("a")
        editor.keepSelection()
        XCTAssertEqual(editor.selectedID, "b")
        XCTAssertNil(editor.error)
        XCTAssertNil(store.barEditing.error)
        XCTAssertNil(editor.properties(for: "b")["style"])
        editor.undo()
        XCTAssertEqual(editor.style(for: "a")["fontSize"], .number(22))
    }

    @MainActor func testPendingNumberBindingsCommitToTheirOriginalWidgetAfterSelectionChanges() throws {
        for key in ["fontSize", "paddingHorizontal", "paddingVertical", "cornerRadius", "borderWidth"] {
            let fixture = try ThemeGalleryFixture(#"{"defaults":{"\#(key)":12},"widgets":[{"id":"a","type":"clock","position":"right"},{"id":"b","type":"clock","position":"right","style":{"\#(key)":20}}]}"#)
            defer { fixture.close() }
            let store = try fixture.store()
            defer { store.stop() }
            let before = try Data(contentsOf: fixture.url)
            let editor = ConfigurationEditor(store: store)
            let id = try XCTUnwrap(editor.selectedID)
            let other = editor.properties(for: "b")
            let fields = StyleFields(store: store, path: "widgets.\(id).style", widgetID: id,
                                     values: editor.style(for: id),
                                     set: { editor.set(["style": .object($0)], for: id) }, unset: { _ in })
            let binding = fields.numberBinding(key, default: 0)
            XCTAssertEqual(binding.wrappedValue, 12)
            editor.selectedID = "b"
            binding.wrappedValue = 20
            XCTAssertNil(editor.error)
            XCTAssertEqual(editor.selectedID, "b")
            XCTAssertEqual(editor.style(for: "a")[key], .number(20), key)
            XCTAssertEqual(editor.properties(for: "b"), other, key)
            try editor.history.flush()
            XCTAssertEqual(editor.undoSteps.count, 1)
            editor.undo()
            XCTAssertEqual(try Data(contentsOf: fixture.url), before)
            XCTAssertEqual(editor.selectedID, "b")
        }
    }

    @MainActor func testTargetedUnchangedStyleUsesTheOriginalWidgetsInheritedValue() throws {
        let fixture = try ThemeGalleryFixture(#"{"defaults":{"fontSize":12},"widgets":[{"id":"a","type":"clock","position":"right"},{"id":"b","type":"clock","position":"right","style":{"fontSize":20}}]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let before = try Data(contentsOf: fixture.url)
        let editor = ConfigurationEditor(store: store)
        editor.selectedID = "b"
        editor.set(["style": .object(["fontSize": .number(12)])], for: "a")
        XCTAssertNil(editor.error)
        XCTAssertTrue(store.customizationEdits.isEmpty)
        XCTAssertTrue(editor.undoSteps.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
    }
}
