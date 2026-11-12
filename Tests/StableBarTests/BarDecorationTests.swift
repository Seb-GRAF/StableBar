import Foundation
import Testing
@testable import StableBar

@Test func barBorderEdgesAreOptInAndFollowStylePrecedence() throws {
    func style(_ json: String) throws -> WidgetStyle {
        try JSONDecoder().decode(WidgetStyle.self, from: Data(json.utf8))
    }
    #expect(try style("{}").borderEdges == nil)
    let outline = try style(#"{"borderEdges":"all","borderWidth":1,"states":{"mode.command":{"borderEdges":"bottom"}}}"#)
    #expect(resolveStyle([outline, try style(##"{"borderColor":"#123456"}"##)]).borderEdges == .all)
    #expect(resolveStyle([outline, try style(#"{"borderEdges":"bottom"}"#)]).borderEdges == .bottom)
    #expect(throws: (any Error).self) { try style(#"{"borderEdges":"top"}"#) }
    #expect(try style(#"{"borderEdges":null}"#).borderEdges == nil)
}

@Test func outlineLayersTokensProfilesAndScriptOverridesCompose() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data(#"{"tokens":{"edges":"all"},"bar":{"style":{"borderEdges":"@token.edges"}}}"#.utf8)
        .write(to: directory.appending(path: "theme.json"))
    let url = directory.appending(path: "config.json")
    var loader = ConfigurationLoader()
    for value in ["null", "\"bottom\""] {
        let json = "{\"includes\":[\"theme.json\"],\"bar\":{\"style\":{\"borderEdges\":\(value)}}}"
        let config = try loader.load(url, data: Data(json.utf8))
        #expect((config.bar.style.borderEdges ?? .bottom) == .bottom)
    }
    let profile = #"{"includes":["theme.json"],"profiles":[{"name":"plain","configuration":{"bar":{"style":{"borderEdges":"bottom"}}}}]}"#
    #expect(try loader.load(url, data: Data(profile.utf8)).bar.style.borderEdges == .bottom)
    let config = try loader.load(url, data: Data(#"{"includes":["theme.json"],"widgets":[{"id":"s","type":"text","position":"left","text":"S"}]}"#.utf8))
    #expect(config.bar.style.borderEdges == .all)
    let output = try ScriptOutput.read(Data(#"{"text":"S","barStyle":{"borderEdges":"bottom"}}"#.utf8))
    #expect(resolveStyle(barStyleLayers(config.bar.style, widgets: config.widgets) { _ in output }).borderEdges == .bottom)
}

@Test func fractionalDisplayScaleDoesNotAddClearanceForFloatingPointNoise() throws {
    let display = BarDisplay(id: 1, isBuiltIn: false, isMain: true, notch: nil)
    let config = try JSONDecoder().decode(Configuration.self, from: Data(#"{"bar":{"height":50,"displayScale":{"external":1.1}},"widgets":[]}"#.utf8))
    let geometry = config.barGeometry(for: display)
    #expect(abs(geometry.inputHeight - CGFloat(config.bar.height * config.bar.scale(for: display))) < 1e-9)
    #expect(geometry.panelHeight == geometry.layoutHeight)
    let decorated = BarGeometry(layoutHeight: 50 * 1.1, margin: 0, outsideExtent: 2, outsideHeight: 2)
    #expect(decorated.inputHeight == 55)
    #expect(decorated.panelHeight == 57)
    let rect = belowBarIndicatorRect(cell: CGRect(x: 12, y: 0, width: 36, height: 22),
        widget: CGRect(x: 12, y: 0, width: 36, height: 55), viewport: CGRect(x: 12, y: 0, width: 36, height: 55),
        visibleBar: CGRect(x: 0, y: 0, width: 100, height: 50 * 1.1), position: .top, style: WidgetStyle(height: 2), scale: 1, pixelsPerPoint: 2)
    #expect(rect?.minY == 55)
}
