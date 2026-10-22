import Foundation
import Observation
import SwiftUI
import Testing
@testable import StableBar

private func block(_ json: String) throws -> PopupBlock {
    try JSONDecoder().decode(PopupBlock.self, from: Data(json.utf8))
}

@Test func widgetsAndTextFieldAndSymbolBlocksTakeATransition() throws {
    let widget = try JSONDecoder().decode(WidgetConfiguration.self, from: Data(#"""
    {"id":"time","type":"clock","position":"right","transition":"numeric",
     "layout":{"type":"row","children":[{"type":"symbol","name":"clock","transition":"fade"},
                                        {"type":"field","field":"text"},{"type":"text","text":"UTC","transition":"none"}]}}
    """#.utf8))
    #expect(widget.transition == .numeric)
    guard case let .row(children)? = widget.layout?.content else {
        Issue.record("Expected a row layout")
        return
    }
    #expect(children.map(\.transition) == [.fade, nil, WidgetTransition.none])
    #expect(try block(#"{"type":"field","field":"text","transition":"roll"}"#).transition == .roll)
}

@Test func transitionMistakesNameTheirProblem() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "transitions.json")
    var loader = ConfigurationLoader()
    for (json, message) in [
        (#"{"widgets":[{"id":"note","type":"text","text":"A","position":"left","transition":"spin"}]}"#,
         "widgets.note: transition: Use none, fade, roll or numeric."),
        (#"{"widgets":[{"id":"note","type":"text","text":"A","position":"left","layout":{"type":"row","transition":"fade","children":[]}}]}"#,
         "widgets.note: layout.transition: Transitions apply to text, field and symbol blocks."),
        (#"{"widgets":[{"id":"note","type":"text","text":"A","position":"left","layout":{"type":"progress","source":"x","height":2,"transition":"roll"}}]}"#,
         "widgets.note: layout.transition: Transitions apply to text, field and symbol blocks.")
    ] {
        let error = #expect(throws: (any Error).self) { try loader.load(url, data: Data(json.utf8)) }
        #expect(error.map(errorMessage) == message)
    }
}

@Test func transitionsComeFromTemplatesProfilesAndOverrides() throws {
    var loader = ConfigurationLoader()
    let configuration = try loader.load(FileManager.default.temporaryDirectory.appending(path: "transitions.json"), data: Data(#"""
    {"templates":{"metric":{"type":"script","command":"true","position":"right","transition":"fade",
                            "layout":{"type":"field","field":"text","transition":"roll"}}},
     "widgets":[{"id":"cpu","template":"metric"},{"id":"memory","template":"metric"}],
     "widgetOverrides":{"memory":{"transition":"numeric","layout":{"transition":null}}},
     "profiles":[{"name":"calm","configuration":{"widgetOverrides":{"cpu":{"transition":"none"}}}}]}
    """#.utf8))
    #expect(configuration.widgets[0].transition == WidgetTransition.none)
    #expect(configuration.widgets[0].layout?.transition == .roll)
    #expect(configuration.widgets[1].transition == .numeric)
    #expect(configuration.widgets[1].layout?.transition == nil)
}

@Test func blocksUseTheirOwnTransitionElseTheWidgetsAndNoneWhileStill() throws {
    let own = try block(#"{"type":"field","field":"text","transition":"roll","animation":{"duration":0.5}}"#)
    let plain = try block(#"{"type":"symbol","name":"bolt"}"#)
    let motion = BlockMotion(transition: .fade, animation: WidgetAnimation(duration: 0.3))
    #expect(motion.transition(for: own, still: false) == .roll)
    #expect(motion.transition(for: plain, still: false) == .fade)
    #expect(motion.transition(for: own, still: true) == WidgetTransition.none)
    #expect(motion.animation(for: own).duration == 0.5)
    #expect(motion.animation(for: plain).duration == 0.3)
    #expect(BlockMotion().transition(for: plain, still: false) == WidgetTransition.none)
}

@Test func theEditorOffersATransitionOnlyWhereTheWidgetDrawsOne() throws {
    let widgets = try JSONDecoder().decode(Configuration.self, from: Data(#"""
    {"widgets":[
      {"id":"note","type":"text","text":"A","position":"left"},
      {"id":"app","type":"activeApp","position":"left"},
      {"id":"spaces","type":"workspaces","position":"left"},
      {"id":"gap","type":"spacer","position":"left"},
      {"id":"drawnSpaces","type":"workspaces","position":"left","layout":{"type":"text","text":"1"}},
      {"id":"marked","type":"spacer","position":"left","overlay":{"type":"text","text":"·"}}]}
    """#.utf8)).widgets
    #expect(widgets.filter(\.drawsTransitions).map(\.id) == ["note", "app", "drawnSpaces", "marked"])
}

@Test @MainActor func theEditorAndCommandLineSetTransitions() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.appending(path: "config.json")
    try Data(#"{"widgets":[{"id":"note","type":"text","text":"A","position":"left"}]}"#.utf8).write(to: root)
    let store = BarStore(configurationURL: root)
    defer { store.stop() }
    store.reloadConfiguration()
    let editor = ConfigurationEditor(store: store)
    editor.set(["transition": .string("fade")])
    #expect(editor.error == nil)
    #expect(store.configuration?.widgets[0].transition == .fade)
    try store.applyEdits([ConfigurationEdit(action: .set, id: "note", properties: [
        "layout": .object(["type": .string("field"), "field": .string("text"), "transition": .string("roll")])
    ])], persist: true)
    #expect(store.configuration?.widgets[0].layout?.transition == .roll)
    let saved = try JSONDecoder().decode([String: ConfigurationValue].self, from: Data(contentsOf: root))
    guard case let .array(widgets)? = saved["widgets"], case let .object(note)? = widgets.first else {
        Issue.record("Expected the saved widget")
        return
    }
    #expect(note["transition"] == .string("fade"))
    editor.set(["transition": .string("spin")])
    #expect(editor.error == "widgets.note: transition: Use none, fade, roll or numeric.")
    #expect(store.configuration?.widgets[0].transition == .fade)
}

@Test func widgetsShowAndHideWithTheirTransitionUnlessMotionIsReduced() throws {
    let animation = WidgetAnimation(curve: .smooth, duration: 0.4)
    #expect(visibilityAnimation(.fade, animation: animation, reduceMotion: false) == animation)
    #expect(visibilityAnimation(.roll, animation: animation, reduceMotion: false) == animation)
    #expect(visibilityAnimation(WidgetTransition.none, animation: animation, reduceMotion: false) == nil)
    #expect(visibilityAnimation(nil, animation: animation, reduceMotion: false) == nil)
    #expect(visibilityAnimation(.fade, animation: animation, reduceMotion: true) == nil)
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data(#"""
    {"groups":{"pair":{}},"widgets":[
      {"id":"a","type":"text","text":"A","position":"left","group":"pair"},
      {"id":"b","type":"text","text":"B","position":"left","group":"pair","transition":"roll"},
      {"id":"c","type":"text","text":"C","position":"right","transition":"fade"},
      {"id":"d","type":"text","text":"D","position":"right"}]}
    """#.utf8))
    let units = BarUnit.make(widgets: configuration.widgets, groups: configuration.groups)
    #expect(units.map(\.transition) == [.roll, .fade, nil])
}

@Test(arguments: [#""type":"activeApp""#, #""type":"appMenu","expandOnHover":true"#,
                  #""type":"text","text":"Timer","hoverLayout":{"type":"slider","title":"Minutes","source":"duration","min":15,"max":240,"step":15,"onChange":"set-duration","style":{"width":100}}"#])
func appWidgetsThatStayedInTheBarAnimateTheirResize(content: String) throws {
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data(#"""
    {"widgets":[{"id":"app",\#(content),"position":"left"},
                {"id":"note","type":"text","text":"A","position":"left"}]}
    """#.utf8))
    let units = BarUnit.make(widgets: configuration.widgets, groups: configuration.groups)
    let kept: [String: CGFloat] = ["widget:app": 80, "widget:note": 20]
    let both: Set<String> = ["widget:app", "widget:note"]
    let wider: [String: CGFloat] = ["widget:app": 120, "widget:note": 20]
    #expect(BarUnit.animatesResize(units, measured: both, from: kept, to: wider, reduceMotion: false))
    #expect(!BarUnit.animatesResize(units, measured: both, from: kept, to: kept, reduceMotion: false))
    #expect(!BarUnit.animatesResize(units, measured: ["widget:note"], from: kept, to: wider, reduceMotion: false))
    #expect(!BarUnit.animatesResize(units, measured: both, from: kept, to: ["widget:app": 80, "widget:note": 40],
                                    reduceMotion: false))
    #expect(!BarUnit.animatesResize(units, measured: both, from: kept, to: wider, reduceMotion: true))
}

@Test func soundWidgetsAnimateTheirResizeAsTheVolumeComesAndGoes() throws {
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data(#"""
    {"providers":{"speakers":{"type":"audio"}},
     "widgets":[{"id":"sound","type":"audio","position":"right"},
                {"id":"named","type":"provider","provider":"speakers","position":"right"},
                {"id":"power","type":"battery","position":"right"}]}
    """#.utf8))
    let units = BarUnit.make(widgets: configuration.widgets, groups: configuration.groups)
    let all = Set(units.map(\.id))
    let kept: [String: CGFloat] = ["widget:sound": 20, "widget:named": 20, "widget:power": 60]
    func animates(_ id: String, measured: Set<String> = all, reduceMotion: Bool = false) -> Bool {
        BarUnit.animatesResize(units, measured: measured, from: kept, to: kept.merging([id: 52]) { $1 }, reduceMotion: reduceMotion,
                               providerType: configuration.providerType(of:))
    }
    #expect(animates("widget:sound"))
    #expect(animates("widget:named"))
    #expect(!animates("widget:sound", measured: all.subtracting(["widget:sound"])), "Its first measurement doesn't animate")
    #expect(!animates("widget:sound", reduceMotion: true))
    #expect(!animates("widget:power"))
}

@Test @MainActor func updateTileAnimatesItsFirstMeasurement() {
    let units = BarUnit.make(widgets: [AppUpdate.tile(.available)], groups: [:])
    let id = units[0].id
    #expect(BarUnit.animatesResize(units, measured: [], from: [:], to: [id: 80], reduceMotion: false))
    #expect(!BarUnit.animatesResize(units, measured: [id], from: [id: 120], to: [id: 120], reduceMotion: false))
    #expect(!BarUnit.animatesResize(units, measured: [], from: [:], to: [id: 80], reduceMotion: true))
}

/// The transition `ResolvedBlockMotion` hands a block's content when drawn in `environment`.
@MainActor private func resolvedTransition(of block: PopupBlock, motion: BlockMotion,
                                           environment: @escaping (inout EnvironmentValues) -> Void) throws -> WidgetTransition {
    final class Seen { var transition: WidgetTransition? }
    let seen = Seen()
    let renderer = ImageRenderer(content: ResolvedBlockMotion(motion: motion, block: block) { transition, _ in
        seen.transition = transition
        return Color.clear.frame(width: 4, height: 4)
    }.transformEnvironment(\.self, transform: environment))
    _ = renderer.cgImage
    return try #require(seen.transition)
}

@Test @MainActor func blocksShowNoTransitionInTheMeasuringCopy() throws {
    let plain = try block(#"{"type":"field","field":"text"}"#)
    let own = try block(#"{"type":"field","field":"text","transition":"roll"}"#)
    let motion = BlockMotion(transition: .fade)
    #expect(try resolvedTransition(of: plain, motion: motion) { _ in } == .fade)
    #expect(try resolvedTransition(of: own, motion: motion) { _ in } == .roll)
    #expect(try resolvedTransition(of: plain, motion: motion) { $0.measuringBarWidths = true } == WidgetTransition.none)
    #expect(try resolvedTransition(of: own, motion: motion) { $0.measuringBarWidths = true } == WidgetTransition.none)
}

/// What a view sees of its environment, and of the transaction of a change.
@MainActor @Observable private final class ProbeSeen {
    var change = 0
    @ObservationIgnored var measuring: Bool?
    @ObservationIgnored var animation: Animation?
    @ObservationIgnored var disablesAnimations: Bool?
}

private struct Probe: View {
    let seen: ProbeSeen
    @Environment(\.measuringBarWidths) private var measuring

    var body: some View {
        seen.measuring = measuring
        return Color.clear.frame(width: 4 + Double(seen.change), height: 4).transaction { transaction in
            seen.animation = transaction.animation
            seen.disablesAnimations = transaction.disablesAnimations
        }
    }
}

/// What a probe drawn in `content` sees of an animated change.
@MainActor private func seen(_ content: (Probe) -> some View) -> ProbeSeen {
    let seen = ProbeSeen()
    let host = NSHostingView(rootView: content(Probe(seen: seen)))
    host.frame = CGRect(x: 0, y: 0, width: 20, height: 20)
    host.layoutSubtreeIfNeeded()
    withAnimation(.default) { seen.change += 1 }
    host.layoutSubtreeIfNeeded()
    return seen
}

@Test @MainActor func theMeasuringCopyMeasuresWithoutAnimating() {
    let outside = seen { $0 }
    #expect(outside.measuring == false)
    #expect(outside.animation == .default)
    #expect(outside.disablesAnimations == false)
    let inside = seen { $0.modifier(MeasuringCopy()) }
    #expect(inside.measuring == true)
    #expect(inside.animation == nil)
    #expect(inside.disablesAnimations == true)
}

@Test func theBarMeasuresWidgetsInTheMeasuringCopy() {
    #expect(String(reflecting: BarView.Body.self).contains("MeasuringCopy"))
}

@Test func animationDurationTimesTheBarsMotionAndKeepsItsCurve() throws {
    let bar = try JSONDecoder().decode(BarSettings.self, from: Data(#"{"motion":"bouncy","animationDuration":0}"#.utf8))
    #expect(bar.animation == WidgetAnimation(curve: .bouncy, duration: 0))
}
