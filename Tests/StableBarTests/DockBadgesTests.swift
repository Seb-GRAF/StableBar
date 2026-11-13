import AppKit
import Testing
@testable import StableBar

@Test(arguments: [("3", "3"), ("99", "99"), ("128", "99+"), ("•", "•"), ("new", "new"), ("Beta", "Be…")])
func aCountBadgeShowsTheDockLabelCutToFit(label: String, shown: String) {
    #expect(DockBadgeStyle.count.text(for: label) == shown)
    #expect(DockBadgeStyle.dot.text(for: label) == nil)
}

@Test func workspaceBadgesDecodeAsDotOrCount() throws {
    let decode = { (json: String) in try JSONDecoder().decode(WorkspaceConfiguration.self, from: Data(json.utf8)) }
    #expect(try decode(#"{"badges":"dot"}"#).badges == .dot)
    #expect(try decode(#"{"badges":"count"}"#).badges == .count)
    #expect(try decode(#"{"badges":null}"#).badges == nil)
    #expect(try decode("{}").badges == nil)
    #expect(throws: DecodingError.self) { try decode(#"{"badges":"number"}"#) }
}

@Test func aScreensOwnLookCanTurnBadgesOnByItself() throws {
    let decode = { (workspace: String) in
        try JSONDecoder().decode(Configuration.self, from: Data("""
        {"widgets":[{"id":"spaces","type":"workspaces","position":"left","workspace":\(workspace)}]}
        """.utf8))
    }
    var configuration = try decode("{}")
    #expect(!configuration.showsDockBadges)
    configuration.screenLooks[ScreenKind.laptop.rawValue] = try decode(#"{"badges":"dot"}"#)
    #expect(configuration.showsDockBadges)
    configuration.screenLooks[ScreenKind.laptop.rawValue] = try decode(#"{"badges":"dot","showApps":false}"#)
    #expect(!configuration.showsDockBadges)
    #expect(try decode(#"{"badges":"count"}"#).showsDockBadges)
}

@Test(arguments: [DockBadgeStyle.dot, .count]) @MainActor
func aBadgeLeavesTheWorkspaceWidgetItsSize(style: DockBadgeStyle) async throws {
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data("""
    {"widgets":[
      {"id":"plain","type":"workspaces","position":"left"},
      {"id":"badged","type":"workspaces","position":"left","workspace":{"badges":"\(style.rawValue)"}}
    ]}
    """.utf8))
    let fixture = OffscreenBar(configuration: configuration,
        display: BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil), width: 600, workspaces: [
            Workspace(name: "1", isFocused: true, isVisible: true, monitor: 1, apps: [
                WorkspaceApp(workspace: "1", name: "Finder", bundleID: "com.apple.finder"),
                WorkspaceApp(workspace: "1", name: "Mail", bundleID: "com.apple.mail"),
            ])
        ])
    defer { fixture.close() }
    fixture.store.workspaceStore.dockBadges.labels = ["com.apple.finder": "128", "com.apple.mail": "3"]
    await fixture.settle()
    let plain = try #require(fixture.anchors("plain").first)
    let badged = try #require(fixture.anchors("badged").first)
    #expect(plain.bounds.width > 0)
    #expect(badged.bounds.size == plain.bounds.size)
}
