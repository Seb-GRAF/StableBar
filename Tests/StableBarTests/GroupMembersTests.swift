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
