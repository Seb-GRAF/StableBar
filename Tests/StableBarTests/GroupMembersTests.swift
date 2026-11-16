import Foundation
import Testing
@testable import StableBar

private func configuration(_ json: String) throws -> Configuration {
    try JSONDecoder().decode(Configuration.self, from: Data(json.utf8))
}

private func groups(_ members: String) throws -> [String: WidgetGroupConfiguration] {
    try configuration(#"{"groups":{"pill":{"members":\#(members)}},"widgets":[]}"#).groups
}

@Test func groupMembersDecodeTypeRoleAndID() throws {
    let members = try groups(#"[{"type":"aerospace"},{"type":"clock","role":"time"},{"id":"now-playing"}]"#)["pill"]?.members
    #expect(members == [WidgetGroupMember(type: "workspaces", role: nil, id: nil),
                        WidgetGroupMember(type: "clock", role: .time, id: nil),
                        WidgetGroupMember(type: nil, role: nil, id: "now-playing")])
    #expect(try groups("null")["pill"]?.members == [])
    #expect(try configuration(#"{"groups":{"pill":{}},"widgets":[]}"#).groups["pill"]?.members == [])
}

@Test(arguments: [#"[{}]"#, #"[{"type":"clock","widget":"date"}]"#, #"[{"type":"sundial"}]"#, #"[{"role":"hero"}]"#])
func groupMembersRejectAnEmptyOrUnknownSelector(members: String) {
    #expect(throws: (any Error).self) { try groups(members) }
}

@Test func aSelectorMatchesOnlyWidgetsWithEveryKeyItNames() throws {
    let widgets = try configuration(#"""
    {"widgets":[
      {"id":"time","type":"clock","role":"time","position":"right"},
      {"id":"date","type":"clock","position":"right"},
      {"id":"spaces","type":"aerospace","position":"left"}
    ]}
    """#).widgets
    func matched(_ member: WidgetGroupMember) -> [String] { widgets.filter(member.matches).map(\.id) }
    #expect(matched(WidgetGroupMember(type: "clock", role: nil, id: nil)) == ["time", "date"])
    #expect(matched(WidgetGroupMember(type: "clock", role: .time, id: nil)) == ["time"])
    #expect(matched(WidgetGroupMember(type: nil, role: .time, id: "date")) == [])
    #expect(matched(WidgetGroupMember(type: "workspaces", role: nil, id: nil)) == ["spaces"])
    #expect(matched(WidgetGroupMember(type: "clock", role: nil, id: "date")) == ["date"])
}

private func groupsByWidget(_ json: String) throws -> [String: String] {
    Dictionary(uniqueKeysWithValues: try configuration(json).widgets.map { ($0.id, $0.group ?? "-") })
}

@Test func aWidgetJoinsTheGroupItsTypeMatchesWhereTheFirstMemberAppears() throws {
    let config = try configuration(#"""
    {"groups":{"status":{"members":[{"type":"battery"},{"type":"network"}]}},"widgets":[
      {"id":"battery","type":"battery","position":"right"},
      {"id":"clock","type":"clock","position":"right"},
      {"id":"network","type":"network","position":"right"}
    ]}
    """#)
    let units = BarUnit.make(widgets: config.widgets, groups: config.groups)
    #expect(units.map(\.id) == ["group:status", "widget:clock"])
    #expect(units[0].widgets.map(\.id) == ["battery", "network"])
}

@Test func aWidgetsOwnGroupWins() throws {
    #expect(try groupsByWidget(#"""
    {"groups":{"status":{"members":[{"type":"battery"}]},"mine":{}},"widgets":[
      {"id":"battery","type":"battery","position":"right","group":"mine"},
      {"id":"spare","type":"battery","position":"right"}
    ]}
    """#) == ["battery": "mine", "spare": "status"])
}

@Test func aMatchInAnotherPositionStaysOut() throws {
    #expect(try groupsByWidget(#"""
    {"groups":{"status":{"members":[{"type":"battery"}]}},"widgets":[
      {"id":"main","type":"battery","position":"right"},
      {"id":"other","type":"battery","position":"left"}
    ]}
    """#) == ["main": "status", "other": "-"])
}

@Test func anExplicitMemberLaterInTheListDecidesThePosition() throws {
    #expect(try groupsByWidget(#"""
    {"groups":{"status":{"members":[{"type":"battery"}]}},"widgets":[
      {"id":"left","type":"battery","position":"left"},
      {"id":"pinned","type":"network","position":"right","group":"status"},
      {"id":"right","type":"battery","position":"right"}
    ]}
    """#) == ["left": "-", "pinned": "status", "right": "status"])
}

@Test func aDisabledMatchDoesNotClaimTheGroupsPosition() throws {
    #expect(try groupsByWidget(#"""
    {"groups":{"status":{"members":[{"type":"battery"}]}},"widgets":[
      {"id":"off","type":"battery","position":"left","enabled":false},
      {"id":"on","type":"battery","position":"right"}
    ]}
    """#) == ["off": "-", "on": "status"])
}

@Test func anIDBeatsMoreKeysWhichBeatFewerAndATieGoesToTheLowerGroupID() throws {
    #expect(try groupsByWidget(#"""
    {"groups":{"b":{"members":[{"type":"clock"}]},"a":{"members":[{"type":"clock"}]},
               "c":{"members":[{"type":"clock","role":"time"}]},"d":{"members":[{"id":"date"}]}},
     "widgets":[
      {"id":"date","type":"clock","role":"time","position":"right"},
      {"id":"time","type":"clock","role":"time","position":"right"},
      {"id":"other","type":"clock","position":"right"}
    ]}
    """#) == ["date": "d", "time": "c", "other": "a"])
}

@Test func aGroupWhoseSelectorsMatchNothingDrawsNothing() throws {
    let config = try configuration(#"""
    {"groups":{"media":{"members":[{"id":"now-playing"}]}},"widgets":[{"id":"clock","type":"clock","position":"right"}]}
    """#)
    #expect(BarUnit.make(widgets: config.widgets, groups: config.groups).map(\.id) == ["widget:clock"])
}

@Test func anIDSelectorPutsAPackageWidgetInTheGroup() throws {
    let fixture = try ThemeGalleryFixture(#"""
    {"packages":[{"id":"now-playing","version":"1"}],
     "groups":{"media":{"members":[{"id":"now-playing"}]}},
     "widgets":[{"id":"clock","type":"clock","position":"right"}]}
    """#)
    defer { fixture.close() }
    let source = fixture.directory.appending(path: "source")
    try fixture.write(#"{"id":"now-playing","name":"Now Playing","version":"1","kind":"widgets","entry":"config.json"}"#,
                      to: source.appending(path: "package.json"))
    try fixture.write(#"{"widgets":[{"id":"now-playing","type":"text","text":"Song","position":"right"}]}"#,
                      to: source.appending(path: "config.json"))
    _ = try fixture.packages.install(source)
    var loader = ConfigurationLoader()
    let config = try loader.load(fixture.url)
    #expect(config.widgets.map(\.id).sorted() == ["clock", "now-playing"])
    #expect(config.widgets.first { $0.id == "now-playing" }?.group == "media")
}

private let pillTheme = #"{"groups":{"pill":{"style":{"cornerRadius":12},"members":[{"type":"clock"}]}}}"#
private let clocks = #"""
"widgets":[{"id":"time","type":"clock","role":"time","position":"right"},
           {"id":"note","type":"text","text":"Note","position":"right"},
           {"id":"date","type":"clock","position":"right"}]
"""#

private func loaded(_ fixture: ThemeGalleryFixture) throws -> Configuration {
    var loader = ConfigurationLoader()
    loader.themesDirectory = fixture.themes
    return try loader.load(fixture.url)
}

private func inPill(_ configuration: Configuration?) -> [String] {
    configuration?.widgets.filter { $0.group == "pill" }.map(\.id) ?? []
}

@MainActor @Test func aThemesMembersJoinWhileItIsSelectedAndLeaveWithIt() throws {
    let fixture = try ThemeGalleryFixture()
    defer { fixture.close() }
    _ = try fixture.theme(pillTheme)
    let other = try fixture.theme(#"{"bar":{"margin":2}}"#, id: "other-theme")
    try fixture.write(#"{"theme":{"id":"test-theme","version":"1"},\#(clocks)}"#, to: fixture.url)
    let store = BarStore(configurationURL: fixture.url, themesDirectory: fixture.themes, customizationSaveDelay: .zero)
    defer { store.stop() }
    store.reloadConfiguration()
    #expect(store.configurationError == nil)
    #expect(inPill(store.configuration) == ["time", "date"])

    try store.tryTheme(other)
    #expect(store.configurationError == nil)
    #expect(inPill(store.configuration) == [])
    store.endThemeTrial()
    #expect(inPill(store.configuration) == ["time", "date"])

    try fixture.write(#"{"theme":{"id":"test-theme","version":"1","enabled":false},\#(clocks)}"#, to: fixture.url)
    #expect(inPill(try loaded(fixture)) == [])
}

@Test(arguments: [(#"[{"type":"clock","role":"time"}]"#, ["time"]), ("[]", []), ("null", [])])
func aThemeProfileNarrowsOrClearsTheThemesMembers(members: String, joined: [String]) throws {
    let fixture = try ThemeGalleryFixture()
    defer { fixture.close() }
    _ = try fixture.theme(pillTheme)
    try fixture.write(#"""
    {"theme":{"id":"test-theme","version":"1"},\#(clocks),
     "profiles":[{"name":"narrow","when":{"theme":"test-theme"},"configuration":{"groups":{"pill":{"members":\#(members)}}}}]}
    """#, to: fixture.url)
    #expect(inPill(try loaded(fixture)) == joined)
}

@Test func aScreensOwnThemeFillsItsGroupsOnlyOnThatScreen() throws {
    let fixture = try ThemeGalleryFixture()
    defer { fixture.close() }
    _ = try fixture.theme(pillTheme)
    try fixture.write(#"{"screens":{"laptop":{"theme":{"id":"test-theme","version":"1"}}},\#(clocks)}"#, to: fixture.url)
    let configuration = try loaded(fixture)
    #expect(inPill(configuration) == [])
    #expect(inPill(configuration.screenLooks["laptop"]) == ["time", "date"])
}

@Test func movingAWidgetAThemePlacedMovesItsGroupAndSavesNoGroup() throws {
    let fixture = try ThemeGalleryFixture()
    defer { fixture.close() }
    _ = try fixture.theme(pillTheme)
    try fixture.write(#"{"theme":{"id":"test-theme","version":"1"},\#(clocks)}"#, to: fixture.url)
    let edits = try WidgetPlacement.move("time", to: .left, widgets: try loaded(fixture).widgets)
    #expect(edits.filter { $0.action == .set }.compactMap(\.id) == ["time", "date"])
    #expect(edits.allSatisfy { $0.properties?["group"] == nil })
}

@Test func aMembersListInTheMainFileIsOneReadableOverride() throws {
    let main = try JSONDecoder().decode([String: ConfigurationValue].self, from: Data(#"""
    {"groups":{"pill":{"members":[{"type":"clock","role":"time"}]}}}
    """#.utf8))
    let theme = try JSONDecoder().decode([String: ConfigurationValue].self, from: Data(pillTheme.utf8))
    #expect(ThemeOverrides(main: main, theme: theme, widgets: []).values.map(\.title) == ["Pill group: members"])
}
