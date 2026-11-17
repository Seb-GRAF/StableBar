import Foundation
import Testing
@testable import StableBar

@MainActor private struct GroupingFixture {
    let fixture: ThemeGalleryFixture
    let store: BarStore

    init(_ json: String, includes: String? = nil) throws {
        fixture = try ThemeGalleryFixture(json)
        if let includes { try fixture.write(includes, to: fixture.directory.appending(path: "included.json")) }
        store = BarStore(configurationURL: fixture.url, themesDirectory: fixture.themes, customizationSaveDelay: .zero)
        store.reloadConfiguration()
    }

    var grouping: WidgetGrouping { WidgetGrouping(store: store) }
    var widgets: [WidgetConfiguration] { store.configuration?.widgets ?? [] }

    func groups() -> [String: String] {
        Dictionary(uniqueKeysWithValues: widgets.map { ($0.id, $0.group ?? "-") })
    }

    func apply(_ edits: [ConfigurationEdit]) throws {
        try store.customizationHistory.change(edits)
        #expect(store.configurationError == nil)
    }

    func close() {
        store.stop()
        fixture.close()
    }
}

private let row = #"""
{"widgets":[
  {"id":"a","type":"text","text":"A","position":"right"},
  {"id":"b","type":"text","text":"B","position":"right"},
  {"id":"c","type":"text","text":"C","position":"right"},
  {"id":"gap","type":"spacer","position":"right"},
  {"id":"d","type":"text","text":"D","position":"right"},
  {"id":"e","type":"text","text":"E","position":"left"}
]}
"""#

@MainActor @Test func aWidgetOffersToGroupWithTheWidgetsBesideItButNotASpacer() throws {
    let bar = try GroupingFixture(row)
    defer { bar.close() }
    let grouping = bar.grouping
    #expect(grouping.choices(for: "a", among: bar.widgets) == [.groupWith("b")])
    #expect(grouping.choices(for: "b", among: bar.widgets) == [.groupWith("a"), .groupWith("c")])
    #expect(grouping.choices(for: "c", among: bar.widgets) == [.groupWith("b")])
    #expect(grouping.choices(for: "d", among: bar.widgets) == [])
    #expect(grouping.choices(for: "gap", among: bar.widgets) == [])
    #expect(grouping.choices(for: "e", among: bar.widgets) == [])
    #expect(grouping.choices(for: "b", among: bar.widgets.filter { $0.id != "a" }) == [.groupWith("c")])
}

@MainActor @Test func groupingWithTheWidgetBesideStartsAStyledGroupInOneUndoStep() throws {
    let bar = try GroupingFixture(row)
    defer { bar.close() }
    try bar.apply(bar.grouping.edits(.groupWith("c"), for: "b"))
    #expect(bar.groups() == ["a": "-", "b": "group", "c": "group", "gap": "-", "d": "-", "e": "-"])
    let style = try bar.fixture.document()["groups"]?.decoded([String: [String: [String: ConfigurationValue]]].self)["group"]?["style"]
    #expect(style == ["background": .string("#8080802e"), "cornerRadius": .number(14), "paddingHorizontal": .number(4)])

    let grouping = bar.grouping
    #expect(grouping.choices(for: "a", among: bar.widgets) == [.join("group")])
    #expect(grouping.choices(for: "b", among: bar.widgets) == [])
    #expect(grouping.group(of: .groupWith("a")) == "group-2")
    try bar.apply(grouping.edits(.join("group"), for: "a"))
    let units = BarUnit.make(widgets: bar.widgets.filter { $0.position == .right }, groups: bar.store.configuration!.groups)
    #expect(units.map(\.id) == ["group:group", "widget:gap", "widget:d"])
    #expect(units[0].widgets.map(\.id) == ["a", "b", "c"])

    try bar.store.customizationHistory.undo()
    try bar.store.customizationHistory.undo()
    #expect(bar.groups().values.allSatisfy { $0 == "-" })
    #expect(try bar.fixture.document()["groups"] == nil)
}

@MainActor @Test func aWidgetBesideAGroupOnAScreenLayoutTakesTheGroupsPositionToJoinIt() throws {
    let bar = try GroupingFixture(#"""
    {"groups":{"status":{}},"screens":{"laptop":{"layout":{"right":["e","a"]}}},"widgets":[
      {"id":"a","type":"text","text":"A","position":"right","group":"status"},
      {"id":"e","type":"text","text":"E","position":"left"}
    ]}
    """#)
    defer { bar.close() }
    let laptop = try #require(bar.store.configuration?.onScreen(.laptop).widgets)
    #expect(bar.grouping.choices(for: "e", among: laptop) == [.join("status")])
    try bar.apply(bar.grouping.edits(.join("status"), for: "e"))
    #expect(bar.groups()["e"] == "status")
    #expect(bar.widgets.first { $0.id == "e" }?.position == .right)
}

@MainActor @Test func leavingUnsetsAGroupTheMainFileSetsAndOverridesOneFromElsewhere() throws {
    let bar = try GroupingFixture(#"""
    {"includes":["included.json"],"groups":{"status":{}},"widgets":[
      {"id":"own","type":"text","text":"A","position":"right","group":"status"}
    ]}
    """#, includes: #"{"widgets":[{"id":"imported","type":"text","text":"B","position":"right","group":"status"}]}"#)
    defer { bar.close() }
    try bar.apply(try bar.grouping.leaving("own"))
    try bar.apply(try bar.grouping.leaving("imported"))
    #expect(bar.groups() == ["own": "-", "imported": "-"])
    let document = try bar.fixture.document()
    #expect(try document["widgets"]?.decoded([[String: ConfigurationValue]].self).first?["group"] == nil)
    #expect(document["widgetOverrides"] == .object(["imported": .object(["group": .null])]))
    #expect(try bar.grouping.leaving("own").isEmpty)
}

@MainActor @Test func leavingAGroupAProfileSetsChangesThatProfile() throws {
    let bar = try GroupingFixture(#"""
    {"groups":{"status":{}},"profile":"fern","profiles":[{"name":"fern","configuration":{"widgetOverrides":{"a":{"group":"status"}}}}],
     "widgets":[{"id":"a","type":"text","text":"A","position":"right"}]}
    """#)
    defer { bar.close() }
    #expect(bar.groups()["a"] == "status")
    try bar.apply(try bar.grouping.leaving("a"))
    #expect(bar.groups()["a"] == "-")
    let profiles = try bar.fixture.document()["profiles"]?.decoded([[String: ConfigurationValue]].self)
    #expect(profiles?.first?["configuration"] == .object(["widgetOverrides": .object(["a": .object(["group": .null])])]))
}

@MainActor @Test func aWidgetTakenInByMembersCanNotLeave() throws {
    let bar = try GroupingFixture(#"""
    {"groups":{"time":{"members":[{"type":"clock"}]},"status":{}},"widgets":[
      {"id":"clock","type":"clock","position":"right"},
      {"id":"date","type":"clock","position":"right","group":"status"},
      {"id":"text","type":"text","text":"A","position":"right","group":"status"}
    ]}
    """#)
    defer { bar.close() }
    #expect(bar.groups() == ["clock": "time", "date": "status", "text": "status"])
    #expect(!bar.grouping.canLeave("clock"))
    #expect(!bar.grouping.canLeave("date"))
    #expect(bar.grouping.canLeave("text"))
}

@MainActor @Test func ungroupingRemovesTheGroupOnlyTheMainFileNames() throws {
    let bar = try GroupingFixture(#"""
    {"groups":{"status":{"style":{"background":"#202027"}},"kept":{}},
     "profiles":[{"name":"night","when":{"app":"com.example.never"},"configuration":{"widgetOverrides":{"c":{"group":"kept"}}}}],
     "widgets":[
      {"id":"a","type":"text","text":"A","position":"right","group":"status"},
      {"id":"b","type":"text","text":"B","position":"right","group":"status"},
      {"id":"c","type":"text","text":"C","position":"right","group":"kept"}
    ]}
    """#)
    defer { bar.close() }
    try bar.apply(try bar.grouping.dissolving("status"))
    try bar.apply(try bar.grouping.dissolving("kept"))
    #expect(bar.groups().values.allSatisfy { $0 == "-" })
    #expect(try bar.fixture.document()["groups"] == .object(["kept": .object([:])]))
}

@MainActor @Test func ungroupingAThemesGroupEmptiesItsMembersInTheMainFile() throws {
    let bar = try GroupingFixture(#"{"widgets":[{"id":"clock","type":"clock","position":"right"}]}"#)
    defer { bar.close() }
    _ = try bar.fixture.theme(##"{"groups":{"time":{"style":{"background":"#000000"},"members":[{"type":"clock"}]}}}"##)
    try bar.fixture.write(#"{"theme":{"id":"test-theme","version":"1"},"widgets":[{"id":"clock","type":"clock","position":"right"}]}"#,
                          to: bar.fixture.url)
    bar.store.reloadConfiguration()
    #expect(bar.groups() == ["clock": "time"])
    try bar.apply(try bar.grouping.dissolving("time"))
    #expect(bar.groups() == ["clock": "-"])
    #expect(try bar.fixture.document()["groups"] == .object(["time": .object(["members": .array([])])]))
}

@Test func theGroupsEditMergesIntoTheGroupsOfTheFile() throws {
    var ids: [String] = []
    let document: [String: ConfigurationValue] = ["groups": .object(["status": .object(["style": .object(["background": .string("#000000")])])])]
    let edited = try ConfigurationEdit(action: .groups, properties: ["status": .object(["style": .object(["cornerRadius": .number(8)])])])
        .applying(to: document, widgetIDs: &ids)
    #expect(edited["groups"] == .object(["status": .object(["style": .object(["background": .string("#000000"), "cornerRadius": .number(8)])])]))
    let decoded = try JSONDecoder().decode(ConfigurationEdit.self, from: Data(#"{"action":"groups","properties":{"pill":{}}}"#.utf8))
    #expect(decoded.action == .groups)
}

@MainActor @Test func settingsShowsAGroupItStartsAndLeavesItOnceTheGroupIsGone() throws {
    let bar = try GroupingFixture(row)
    defer { bar.close() }
    let editor = ConfigurationEditor(store: bar.store)
    editor.group("a", .groupWith("b"))
    #expect(editor.error == nil)
    #expect(editor.barItem == .group)
    #expect(editor.selectedGroup == "group")
    #expect(editor.section == .widgets)

    editor.leaveGroup("a")
    #expect(bar.groups()["a"] == "-")
    #expect(editor.barItem == .group)
    editor.ungroup("group")
    #expect(bar.groups().values.allSatisfy { $0 == "-" })
    #expect(editor.barItem == .widget)
    editor.showGroup("group")
    #expect(editor.barItem == .widget)
}

@MainActor @Test func theEditBarGroupsLeavesAndOpensAGroupInSettings() async throws {
    let bar = try GroupingFixture(row)
    defer { bar.close() }
    var opened: [CustomizationTarget] = []
    bar.store.onCustomizeItem = { opened.append($0) }
    let editing = bar.store.barEditing
    editing.group("a", .groupWith("b"), on: 1)
    editing.editGroup("group")
    #expect(bar.groups()["a"] == "-")
    #expect(opened.isEmpty)

    editing.begin()
    defer { editing.end() }
    editing.group("a", .groupWith("b"), on: 1)
    await editing.editTask?.value
    #expect(editing.error == nil)
    #expect(bar.groups()["a"] == "group")
    #expect(bar.groups()["b"] == "group")
    editing.editGroup("group")
    editing.editGroup("missing")
    #expect(opened == [.group("group")])
    editing.leaveGroup("a", on: 1)
    await editing.editTask?.value
    #expect(bar.groups()["a"] == "-")
    #expect(bar.groups()["b"] == "group")
}

@MainActor @Test func groupingWhileEditingAProfileKeepsTheGroupInThatProfile() throws {
    let bar = try GroupingFixture(#"""
    {"profiles":[{"name":"work","when":{"app":"com.example.never"},"configuration":{}}],"widgets":[
      {"id":"a","type":"text","text":"A","position":"right"},
      {"id":"b","type":"text","text":"B","position":"right"}
    ]}
    """#)
    defer { bar.close() }
    let editor = ConfigurationEditor(store: bar.store)
    editor.editBar(for: "work")
    editor.group("a", .groupWith("b"))
    #expect(editor.error == nil)
    #expect(bar.groups() == ["a": "group", "b": "group"])
    let document = try bar.fixture.document()
    #expect(document["groups"] == nil)
    let configuration = try document["profiles"]?.decoded([[String: ConfigurationValue]].self).first?["configuration"]?
        .decoded([String: ConfigurationValue].self)
    #expect(configuration?["groups"] != nil)
    #expect(configuration?["widgetOverrides"] == .object(["a": .object(["group": .string("group")]), "b": .object(["group": .string("group")])]))
    editor.endProfileEditing()
    #expect(bar.groups() == ["a": "-", "b": "-"])
}

@MainActor @Test func resettingAGroupsLastStyleValueKeepsTheGroup() throws {
    let bar = try GroupingFixture(#"""
    {"groups":{"status":{"style":{"cornerRadius":8}}},"widgets":[
      {"id":"a","type":"text","text":"A","position":"right","group":"status"}
    ]}
    """#)
    defer { bar.close() }
    try bar.apply([ConfigurationEdit(action: .unset, properties: ["groups": .object(["status": .object(["style": .object(["cornerRadius": .null])])])])])
    #expect(bar.groups() == ["a": "status"])
    #expect(try bar.fixture.document()["groups"] == .object(["status": .object([:])]))
}

@MainActor @Test func leavingRemovesAGroupFromTheOverrideThatSetsIt() throws {
    let bar = try GroupingFixture(#"""
    {"groups":{"status":{}},"templates":{"pill":{"group":"status"}},
     "widgetOverrides":{"a":{"group":"status"}},
     "widgets":[
      {"id":"a","type":"text","text":"A","position":"right"},
      {"id":"b","type":"text","text":"B","position":"right","template":"pill"}
    ]}
    """#)
    defer { bar.close() }
    #expect(bar.groups() == ["a": "status", "b": "status"])
    try bar.apply(try bar.grouping.leaving("a"))
    try bar.apply(try bar.grouping.leaving("b"))
    #expect(bar.groups() == ["a": "-", "b": "-"])
    let document = try bar.fixture.document()
    #expect(document["widgetOverrides"] == nil)
    // The template still names the group, so the widget's own definition overrides it.
    #expect(try document["widgets"]?.decoded([[String: ConfigurationValue]].self).last?["group"] == .null)
}

@MainActor @Test func aWidgetCanLeaveWhenTheGroupItsMembersMatchSitsElsewhere() throws {
    let bar = try GroupingFixture(#"""
    {"groups":{"time":{"members":[{"type":"clock"}]},"status":{}},"widgets":[
      {"id":"left","type":"clock","position":"left","group":"time"},
      {"id":"date","type":"clock","position":"right","group":"status"}
    ]}
    """#)
    defer { bar.close() }
    #expect(bar.grouping.canLeave("date"))
    #expect(!bar.grouping.canLeave("left"))
}

@MainActor @Test func aNewGroupSkipsTheIDsProfilesDefine() throws {
    let bar = try GroupingFixture(#"""
    {"profiles":[{"name":"night","when":{"app":"com.example.never"},"configuration":{"groups":{"group":{}}}}],"widgets":[
      {"id":"a","type":"text","text":"A","position":"right"},
      {"id":"b","type":"text","text":"B","position":"right"}
    ]}
    """#)
    defer { bar.close() }
    #expect(bar.grouping.group(of: .groupWith("b")) == "group-2")
}

@MainActor @Test func leavingHidesAGroupAnIncludedFileSetsUnderAnOverride() throws {
    let bar = try GroupingFixture(#"""
    {"includes":["included.json"],"groups":{"status":{}},"widgetOverrides":{"imported":{"group":"status"}},"widgets":[]}
    """#, includes: #"{"widgets":[{"id":"imported","type":"text","text":"B","position":"right","group":"status"}]}"#)
    defer { bar.close() }
    try bar.apply(try bar.grouping.leaving("imported"))
    #expect(bar.groups() == ["imported": "-"])
    #expect(try bar.fixture.document()["widgetOverrides"] == .object(["imported": .object(["group": .null])]))
    try bar.store.customizationHistory.undo()
    #expect(bar.groups() == ["imported": "status"])

    // The included file still names the group under the `null`, so its definition stays.
    try bar.apply(try bar.grouping.dissolving("status"))
    #expect(bar.groups() == ["imported": "-"])
    #expect(try bar.fixture.document()["groups"] == .object(["status": .object([:])]))
}

@MainActor @Test func ungroupingKeepsAGroupAProfileFromAnIncludedFileNames() throws {
    let bar = try GroupingFixture(#"""
    {"includes":["included.json"],"groups":{"status":{}},"widgets":[
      {"id":"own","type":"text","text":"A","position":"right","group":"status"}
    ]}
    """#, includes: #"""
    {"profiles":[{"name":"night","when":{"app":"com.example.never"},"configuration":{"widgetOverrides":{"own":{"group":"status"}}}}]}
    """#)
    defer { bar.close() }
    try bar.apply(try bar.grouping.dissolving("status"))
    #expect(bar.groups() == ["own": "-"])
    #expect(try bar.fixture.document()["groups"] == .object(["status": .object([:])]))
}
