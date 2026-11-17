import Foundation
import Testing
@testable import StableBar

@Test(arguments: ["percent", "volume", "cpu", "memory", "disk"])
func labeledMetricColumnsRoundTripAndKeepTheExistingDefaults(source: String) throws {
    let choices = WidgetMetricDisplay.choices(for: source)
    let meter = try #require(choices.firstIndex(of: .meter))
    #expect(choices[meter + 1] == .labelValueMeter)
    let layout = try #require(WidgetMetricDisplay.labelValueMeter.layout(for: [source]))
    #expect(WidgetMetricDisplay.current(layout, sources: [source]) == .labelValueMeter)
    let block = try layout.decoded(PopupBlock.self)
    guard case let .column(children) = block.content else { Issue.record("Expected a metric column"); return }
    #expect(block.style.width == 73)
    guard case let .row(header) = children[0].content, case let .text(label) = header[0].content else {
        Issue.record("Expected a label and value header"); return
    }
    #expect(label == ["percent": "BAT", "volume": "VOL", "cpu": "CPU", "memory": "MEM", "disk": "DISK"][source])
    #expect(header[0].role == .key)
    #expect(header[1].alignment == .trailing)
    #expect(header[1].style.width == 37)
    guard case let .column(meter) = children[1].content,
          case let .progress(metric, height, _) = meter[0].content else { Issue.record("Expected a meter"); return }
    #expect(metric == source)
    #expect(height == 4)
    #expect(meter[0].role == .meter)
    #expect(children[1].style.paddingTop == 2)
    #expect(WidgetMetricDisplay.current(nil, sources: [source]) != .labelValueMeter)
}

@Test func labeledSystemMetricsKeepTheirOrderAndCustomSizingStaysCustom() throws {
    for metrics in WidgetSystemMetrics.allCases {
        let layout = try #require(WidgetMetricDisplay.labelValueMeter.layout(for: metrics.sources))
        #expect(WidgetSystemMetrics.current(layout) == metrics)
        #expect(WidgetMetricDisplay.current(layout, sources: metrics.sources) == .labelValueMeter)
        if metrics.sources.count == 2 {
            let block = try layout.decoded(PopupBlock.self)
            #expect(block.style.spacing == 14)
        }
        guard case var .object(changed) = layout else { continue }
        changed["style"] = .object(["spacing": .number(20)])
        #expect(WidgetMetricDisplay.current(.object(changed), sources: metrics.sources) == .custom)
    }
}

@Test @MainActor func aMetricDisplayEditStaysInItsProfileAndCanBeUndone() throws {
    let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"disk","type":"disk","position":"right","onClick":"open-disk"}],"profiles":[{"name":"fern","configuration":{}}]}"#)
    defer { fixture.close() }
    let store = try fixture.store()
    defer { store.stop() }
    let editor = ConfigurationEditor(store: store)
    editor.editBar(for: "fern")
    let before = try fixture.document()
    editor.set(["layout": try #require(WidgetMetricDisplay.labelValueMeter.layout(for: ["disk"]))], for: "disk")
    try editor.history.flush()
    #expect(editor.error == nil)
    #expect(store.configuration?.widgets.first?.position == .right)
    #expect(store.configuration?.widgets.first?.onClick == "open-disk")
    #expect(WidgetMetricDisplay.current(editor.properties(for: "disk")["layout"], sources: ["disk"]) == .labelValueMeter)
    let document = try fixture.document()
    let widgets = try #require(document["widgets"]).decoded([[String: ConfigurationValue]].self)
    #expect(widgets[0]["layout"] == nil)
    editor.undo()
    #expect(try fixture.document() == before)
}
