import AppKit
import Testing
@testable import StableBar

@Test(arguments: [12, 24]) @MainActor
func workspaceWidgetsMatchOtherWidgetHeights(fontSize: Int) async throws {
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data("""
    {"bar":{"height":64},"defaults":{"fontSize":\(fontSize),"paddingVertical":6},
     "workspaceDefaults":{"style":{"cornerRadius":0,"states":{"focused":{"background":"#ff00ff"}}}},"widgets":[
      {"id":"label","type":"text","text":"1","position":"left"},
      {"id":"clock","type":"clock","format":"HH:mm","position":"left"},
      {"id":"spaces","type":"workspaces","position":"left"},
      {"id":"spaces-label","type":"workspaces","position":"left","workspace":{"showApps":false}},
      {"id":"spaces-layout","type":"workspaces","position":"left","layout":{"type":"text","text":"1"}}
    ]}
    """.utf8))
    let fixture = OffscreenBar(configuration: configuration,
        display: BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil), width: 600, workspaces: [
            Workspace(name: "1", isFocused: true, isVisible: true, monitor: 1,
                apps: [WorkspaceApp(workspace: "1", name: "Finder", bundleID: "com.apple.finder")])
        ])
    defer { fixture.close() }
    await fixture.settle()
    let label = try #require(fixture.anchors("label").first)
    let reference = label.convert(label.bounds, to: fixture.host)
    for id in ["clock", "spaces", "spaces-label", "spaces-layout"] {
        let anchor = try #require(fixture.anchors(id).first)
        let bounds = anchor.convert(anchor.bounds, to: fixture.host)
        #expect(abs(bounds.height - reference.height) < 0.01, "\(id) should match the label's height")
        #expect(abs(bounds.midY - reference.midY) < 0.01)
    }
    let bitmap = try fixture.bitmap()
    let workspace = try #require(fixture.anchors("spaces-label").first)
    let bounds = workspace.convert(workspace.bounds, to: fixture.host)
    let scale = fixture.backingScale
    var selectionRows = Set<Int>()
    for y in 0..<bitmap.pixelsHigh {
        for x in Int((bounds.minX * scale).rounded(.up))..<Int((bounds.maxX * scale).rounded(.down)) {
            if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
               color.redComponent > 0.9 && color.blueComponent > 0.9 && color.greenComponent < 0.1 {
                selectionRows.insert(y)
                break
            }
        }
    }
    #expect(selectionRows.count == Int((bounds.height * scale).rounded()), "The selection should fill the widget's height")
}

@Test @MainActor func workspaceWidgetsKeepConfiguredCellAndTileHeights() async throws {
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data(#"""
    {"bar":{"height":64},"defaults":{"paddingVertical":6},
     "workspaceDefaults":{"style":{"height":24}},"widgets":[
      {"id":"inherited","type":"workspaces","position":"left"},
      {"id":"custom","type":"workspaces","position":"left","workspace":{"style":{"height":30}}},
      {"id":"focused","type":"workspaces","position":"left",
       "workspace":{"style":{"states":{"focused":{"height":36}}}}},
      {"id":"tile","type":"workspaces","position":"left","style":{"height":44}}
    ]}
    """#.utf8))
    let fixture = OffscreenBar(configuration: configuration,
        display: BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil), width: 600,
        workspaces: [Workspace(name: "1", isFocused: true, isVisible: true, monitor: 1)])
    defer { fixture.close() }
    await fixture.settle()
    for (id, height) in [("inherited", 36.0), ("custom", 42.0), ("focused", 48.0), ("tile", 44.0)] {
        let anchor = try #require(fixture.anchors(id).first)
        let bounds = anchor.convert(anchor.bounds, to: fixture.host)
        #expect(abs(bounds.height - height) < 0.01, "\(id) should keep its configured height")
    }
}
