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
    let row = try layout.decoded(PopupBlock.self)
    guard case let .row(top) = row.content, top.count == 1, case let .column(children) = top[0].content else {
        Issue.record("Expected a metric column in a plain row"); return
    }
    #expect(row.style == WidgetStyle())
    let block = top[0]
    #expect(block.style.minWidth == 73)
    guard case let .row(header) = children[0].content, case let .text(label) = header[0].content else {
        Issue.record("Expected a label and value header"); return
    }
    #expect(label == ["percent": "BAT", "volume": "VOL", "cpu": "CPU", "memory": "MEM", "disk": "DISK"][source])
    #expect(header[0].role == .key)
    #expect(header[1].alignment == .trailing)
    #expect(header[1].style.minWidth == 37)
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
            guard case let .row(top) = block.content else { Issue.record("Expected a row"); continue }
            #expect(top.first?.style.spacing == 14)
        }
        guard case var .object(changed) = layout, case var .array(children) = changed["children"],
              case var .object(content) = children[0] else { continue }
        content["style"] = .object(["spacing": .number(20)])
        children[0] = .object(content)
        changed["children"] = .array(children)
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

@Test(arguments: [false, true]) @MainActor
func switchingAwayFromLabelValueAndMeterLeavesNothingBehind(inProfile: Bool) throws {
    let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"disk","type":"disk","position":"right"},{"id":"system","type":"system","position":"right"}],"profiles":[{"name":"fern","configuration":{}}]}"#)
    defer { fixture.close() }
    let store = try fixture.store()
    defer { store.stop() }
    let editor = ConfigurationEditor(store: store)
    if inProfile { editor.editBar(for: "fern") }
    for (id, sources) in [("disk", ["disk"]), ("system", ["memory", "cpu"])] {
        for choice in WidgetMetricDisplay.choices(for: sources[0]) where choice != .labelValueMeter && choice != .custom {
            editor.set(["layout": try #require(WidgetMetricDisplay.labelValueMeter.layout(for: sources))], for: id)
            editor.set(["layout": try #require(choice.layout(for: sources))], for: id)
            try editor.history.flush()
            #expect(editor.error == nil)
            let layout = editor.properties(for: id)["layout"]
            #expect(WidgetMetricDisplay.current(layout, sources: sources) == choice, "\(id) \(choice)")
            if case .object = choice.layout(for: sources) { #expect(layout == choice.layout(for: sources), "\(id) \(choice)") }
        }
    }
}

@Test func aStyledRowKeepsItsChoiceAcrossLabelValueAndMeter() throws {
    for sources in [["disk"], ["cpu", "memory"]] {
        for choice in [WidgetMetricDisplay.labelValueMeter, .meter] {
            guard case var .object(layout) = choice.layout(for: sources) else { Issue.record("Expected a layout"); continue }
            layout["style"] = .object(["paddingHorizontal": .number(4)])
            #expect(WidgetMetricDisplay.current(.object(layout), sources: sources) == choice)
        }
    }
}

@Test func labeledSystemColumnsWarnEachMetricApart() throws {
    for sources in [["cpu", "memory"], ["memory", "cpu"]] {
        let configuration = try ConfigurationValue.object([
            "providers": .object(["system": .object(["type": .string("system")])]),
            "widgets": .array([.object(["id": .string("system"), "type": .string("system"), "position": .string("right"),
                                        "details": .bool(true), "layout": try #require(WidgetMetricDisplay.labelValueMeter.layout(for: sources))])])
        ]).decoded(Configuration.self)
        let widget = configuration.widgets[0]
        guard case let .row(top)? = widget.layout?.content, case let .row(columns)? = top.first?.content else {
            Issue.record("Expected two columns in a row"); continue
        }
        #expect(columns.count == 2)
        for (cpu, memory) in [(0.95, 0.5), (0.5, 0.95)] {
            let output = ScriptOutput(text: "\(Int(cpu * 100))%", icon: "cpu", fields: ["pressure": "normal", "thermal": "nominal"],
                                      values: ["cpu": cpu, "memory": memory])
            let states = widgetDataStates(output, widget: widget, providers: configuration.providers)
            let expected = sources.map { ($0 == "cpu" ? cpu : memory) > 0.9 ? "warning" : nil }
            #expect(columns.map { StyleStates(data: states.widget, parts: states.parts).scoped(to: $0).data } == expected, "\(sources) cpu \(cpu)")
        }
    }
}
