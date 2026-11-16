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
