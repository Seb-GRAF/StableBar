import Foundation
import Testing
@testable import StableBar

@Test func workspaceGroupDividersFollowOriginalNameKinds() throws {
    #expect(Workspace.needsGroupDivider(between: "10", and: "A"))
    #expect(Workspace.needsGroupDivider(between: "Z", and: "2"))
    for pair in [("1", "2"), ("A", "B"), ("", "A"), ("1", "A1"), ("1", "-")] {
        #expect(!Workspace.needsGroupDivider(between: pair.0, and: pair.1))
    }
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data(#"{"workspaceDefaults":{"groupDivider":true},"widgets":[{"id":"spaces","type":"workspaces","position":"left"},{"id":"other","type":"workspaces","position":"left","workspace":{"groupDivider":false}}]}"#.utf8))
    #expect(configuration.widgets[0].workspace?.groupDivider == true)
    #expect(configuration.widgets[1].workspace?.groupDivider == false)
}
