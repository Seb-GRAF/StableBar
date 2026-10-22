import AppKit
import Foundation
import Observation
import SwiftUI
import Testing
@testable import StableBar

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(json.utf8))
}

/// `content` inside the box a bar widget draws around it.
@MainActor private func boxed(_ content: some View, _ appearance: WidgetAppearance) -> some View {
    content
        .font(appearance.font)
        .foregroundStyle(appearance.foreground)
        .padding(.horizontal, appearance.paddingHorizontal)
        .padding(.vertical, appearance.paddingVertical)
        .background(appearance.background, in: RoundedRectangle(cornerRadius: appearance.cornerRadius))
}

/// A view drawn at 2× in 8-bit sRGB.
private struct Drawing {
    let width: Int
    let height: Int
    let rgba: [UInt8]

    /// The largest difference of one color channel between this drawing and `other`. Drawings of
    /// different sizes differ completely.
    func difference(from other: Drawing) -> Int {
        guard width == other.width, height == other.height else { return 255 }
        return zip(rgba, other.rgba).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
    }
}

/// How far a color channel may differ between two drawings that should match. A process draws some
/// antialiased pixels one step (1/255) differently when it first draws new content, and under load
/// that change can come between any two drawings; the first graph case fails at 0 in every run. Real
/// differences are far larger.
private let tolerance = 1

/// `content` drawn at 2×.
@MainActor private func draw(_ content: some View) throws -> Drawing {
    let renderer = ImageRenderer(content: content)
    renderer.scale = 2
    let image = try #require(renderer.cgImage)
    let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                         bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let data = try #require(context.data)
    return Drawing(width: image.width, height: image.height,
                   rgba: Array(UnsafeRawBufferPointer(start: data, count: image.width * image.height * 4)))
}

/// The frontmost app a case draws: none, this process through the store as the bar draws it, or
/// `name` with Finder's icon.
private enum FrontmostApp {
    case noApp, thisProcess, named(String)
}

/// An active-app widget's default layout, drawn with `icon` as the frontmost app's icon and `name`
/// as its name, so the drawing doesn't depend on the apps running when the test does.
@MainActor private func appBlocks(_ widget: StableBar.WidgetConfiguration, name: String?, icon: NSImage, style: LayoutStyle, date: Date) throws -> some View {
    let label = widget.label(output: nil, activeApp: name, date: date)
    let layout = try #require(widget.defaultLayout(label, output: nil, appIcon: true))
    return PopupBlockView(block: layout,
                          inheritedStyle: style.inherited, fields: label.fields,
                          context: BlockContext(fillsWidth: false, open: { _ in }, states: style.states, tracksHover: style.tracksHover, appIcon: icon,
                                                runAction: { _, _ in }))
}

@Test @MainActor func defaultLayoutsDrawExactlyLikeBuiltInWidgets() throws {
    let date = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 9, minute: 41)))
    let icon = NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")
    _ = NSApplication.shared
    try #require(NSRunningApplication.current.icon != nil)
    let cases: [(widget: String, output: String?, app: FrontmostApp)] = [
        (#"{"id":"w","type":"text","text":"Ready 12%","icon":"bolt","position":"left"}"#, nil, .noApp),
        (#"{"id":"w","type":"text","text":"Ready","icon":"","position":"left"}"#, nil, .noApp),
        (#"{"id":"w","type":"text","text":"","icon":"apple.logo","position":"left"}"#, nil, .noApp),
        (#"{"id":"w","type":"text","text":"Ready","position":"left"}"#, nil, .noApp),
        (#"{"id":"w","type":"clock","format":"EEE d MMM  HH:mm","icon":"clock","position":"right"}"#, nil, .noApp),
        (#"{"id":"w","type":"activeApp","position":"left"}"#, nil, .thisProcess),
        (#"{"id":"w","type":"activeApp","position":"left"}"#, nil, .named("Finder 12")),
        (#"{"id":"w","type":"activeApp","position":"left"}"#, nil, .noApp),
        (#"{"id":"w","type":"script","command":"true","icon":"bolt","position":"right"}"#, #"{"text":"Busy 3","icon":"hammer"}"#, .noApp),
        (#"{"id":"w","type":"script","command":"true","icon":"cpu","position":"right"}"#, #"{"text":"12%","value":0.12}"#, .noApp),
        (#"{"id":"w","type":"script","command":"true","position":"right"}"#, #"{"text":"","value":0.5}"#, .noApp),
        (#"{"id":"w","type":"script","command":"true","icon":"speaker.wave.2","position":"right"}"#, #"{"text":""}"#, .noApp),
        (#"{"id":"w","type":"system","position":"right"}"#, #"{"text":"85%","icon":"cpu","value":0.85}"#, .noApp)
    ]
    let styles = try [
        decode(WidgetStyle.self, "{}"),
        decode(WidgetStyle.self, ##"""
        {"foreground":"#ff8800","accent":"#00aa66","fontName":"Menlo","fontSize":15,"fontWeight":"bold","iconSize":16,"spacing":9,
         "states":{"hover":{"foreground":"#ffffff","fontWeight":"light","spacing":3},"open":{"accent":"#3366ff","iconSize":11}}}
        """##)
    ]
    for item in cases {
        let widget = try decode(WidgetConfiguration.self, item.widget)
        let store = BarStore(configurationURL: FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json"))
        if case .thisProcess = item.app { store.activeApp = NSRunningApplication.current } else { store.activeApp = nil }
        let app: (name: String?, icon: NSImage?) = switch item.app {
        case .noApp: (nil, nil)
        case .thisProcess: (store.activeApp?.localizedName, store.activeApp?.icon)
        case let .named(name): (name, icon)
        }
        if let json = item.output {
            let script = ScriptWidget()
            script.output = try ScriptOutput.read(Data(json.utf8))
            script.samples = [0.1, 0.6, 0.35, 0.8, 0.12]
            store.scripts[widget.id] = script
        }
        let script = store.scripts[widget.id]
        for (index, style) in styles.enumerated() {
            let resolution = ResolvedWidgetStyle(base: resolveStyle([style, widget.style]))
            for (hovered, open) in [(false, false), (true, false), (false, true), (true, true)] {
                let appearance = WidgetAppearance(resolution.style(hovered: hovered, open: open), defaults: WidgetStyle())
                let builtIn = BuiltInLabel(content: widget.content,
                                           label: widget.label(output: script?.output, activeApp: app.name, date: date),
                                           appIcon: app.icon,
                                           samples: script?.output.value == nil ? nil : script?.samples, appearance: appearance)
                let layoutStyle = resolution.layoutStyle(configured: false, hovered: hovered, open: open)
                let drawn = if case let .named(name) = item.app {
                    try draw(boxed(appBlocks(widget, name: name, icon: icon, style: layoutStyle, date: date), appearance))
                } else {
                    try draw(boxed(WidgetBlocks(widget: widget, store: store, style: layoutStyle, date: date, runAction: { _, _ in }), appearance))
                }
                let expected = try draw(boxed(builtIn, appearance))
                let name = "\(item.widget), app \(item.app), style \(index), hovered: \(hovered), open: \(open)"
                #expect(Double(expected.width) / 2 > appearance.paddingHorizontal * 2, "\(name) draws something")
                #expect(drawn.width == expected.width && drawn.height == expected.height, "\(name)")
                #expect(drawn.difference(from: expected) <= tolerance, "\(name)")
            }
        }
    }
}

@Test @MainActor func batteryAndSoundDefaultLayoutsFitTheirLabelAndKeepExplicitGraphs() throws {
    for (type, icon, source) in [("battery", "battery.100percent", "percent"), ("audio", "speaker.wave.2", "volume")] {
        for named in [false, true] {
            let provider = named ? #""type":"provider","provider":"metric""# : #""type":"\#(type)""#
            let widget = try decode(WidgetConfiguration.self, #"{"id":"w",\#(provider),"position":"right"}"#)
            let output = try decode(ScriptOutput.self, #"{"text":"85%","icon":"\#(icon)","value":0.85,"values":{"\#(source)":0.85}}"#)
            let label = widget.label(output: output, activeApp: nil, date: .now)
            let layout = try #require(widget.defaultLayout(label, output: output, appIcon: false, providerType: named ? type : nil))
            // Sound shows its volume only after a change, so at rest it is the icon alone.
            let value = type == "audio" ? nil : PopupBlock(content: .field("text"), hideWhenEmpty: "text")
            let speaker = PopupBlock(content: .symbol(name: "", source: "icon"), widestSymbol: type == "audio" ? AudioMonitor.widestIcon : nil)
            let expected = PopupBlock(content: .row([speaker, value].compactMap { $0 }), keepsLineHeight: true)
            let context = BlockContext(samples: [0.85], values: [source: 0.85], fillsWidth: false, open: { _ in }, runAction: { _, _ in })
            let drawn = try draw(PopupBlockView(block: layout, inheritedStyle: WidgetStyle(), fields: label.fields, context: context))
            let plain = try draw(PopupBlockView(block: expected, inheritedStyle: WidgetStyle(), fields: label.fields, context: context))
            #expect(drawn.width == plain.width)
            #expect(drawn.difference(from: plain) <= tolerance)
            let graph = try #require(WidgetMetricDisplay.graph.layout(for: source)).decoded(PopupBlock.self)
            let withGraph = try draw(PopupBlockView(block: graph, inheritedStyle: WidgetStyle(), fields: label.fields, context: context))
            #expect(withGraph.width > drawn.width)
        }
    }
}

@Test @MainActor func hiddenBlocksAddNoSpacing() throws {
    for type in ["row", "column"] {
        let shown = try decode(PopupBlock.self, #"{"type":"\#(type)","children":[{"type":"text","text":"A"},{"type":"text","text":"B"}]}"#)
        let hidden = try decode(PopupBlock.self, #"""
        {"type":"\#(type)","children":[{"type":"text","text":"A"},{"type":"field","field":"empty","hideWhenEmpty":"empty"},{"type":"text","text":"B"}]}
        """#)
        let context = BlockContext(fillsWidth: false, open: { _ in }, runAction: { _, _ in })
        let expected = try draw(PopupBlockView(block: shown, inheritedStyle: WidgetStyle(), fields: [:], context: context))
        let drawn = try draw(PopupBlockView(block: hidden, inheritedStyle: WidgetStyle(), fields: [:], context: context))
        #expect(drawn.width == expected.width && drawn.height == expected.height, "\(type)")
        #expect(drawn.difference(from: expected) <= tolerance, "\(type)")
    }
}

@Test @MainActor func scrollingTextTakesItsOwnWidthUpToMaxWidth() throws {
    let context = BlockContext(fillsWidth: false, open: { _ in }, runAction: { _, _ in })
    func drawing(_ text: String, style: String, scrolls: Bool = true) throws -> Drawing {
        let speed = scrolls ? #","scrollSpeed":20"# : ""
        let block = try decode(PopupBlock.self, #"{"type":"field","field":"title"\#(speed),"style":\#(style)}"#)
        return try draw(PopupBlockView(block: block, inheritedStyle: WidgetStyle(fontSize: 13), fields: ["title": text], context: context))
    }
    let short = "Mikasa"
    let long = "Mikasa — Moha MMZ, the extended mix that keeps going"
    let plain = try drawing(short, style: "{}", scrolls: false)
    #expect(plain.width < 320)
    #expect(try drawing(short, style: #"{"maxWidth":160}"#).width == plain.width, "A short title leaves no gap after it")
    #expect(try drawing(long, style: #"{"maxWidth":160}"#).width == 320, "A long title stops at maxWidth")
    #expect(try drawing(short, style: #"{"minWidth":160}"#).width == 320)
    #expect(try drawing(short, style: #"{"width":160}"#).width == 320, "A fixed width keeps its footprint")
    #expect(try drawing(long, style: #"{"width":160,"maxWidth":40}"#).width == 320, "A fixed width wins over maxWidth")
}

@Test @MainActor func blocksStayWithinTheirMinimumAndMaximumWidths() throws {
    func width(_ json: String, fillsWidth: Bool = false, offered: CGFloat? = nil) throws -> Int {
        let block = try decode(PopupBlock.self, json)
        let renderer = ImageRenderer(content: PopupBlockView(block: block, inheritedStyle: WidgetStyle(fontSize: 13), fields: [:],
                                                             context: BlockContext(fillsWidth: fillsWidth, open: { _ in }, runAction: { _, _ in })))
        renderer.proposedSize = ProposedViewSize(width: offered, height: nil)
        return try #require(renderer.cgImage).width
    }
    let text = try width(#"{"type":"text","text":"Ready"}"#)
    #expect(try width(#"{"type":"text","text":"Ready","style":{"maxWidth":200}}"#) == text)
    #expect(try width(#"{"type":"text","text":"Ready","style":{"minWidth":200}}"#) == 200)
    #expect(try width(#"{"type":"text","text":"A much longer status line","style":{"maxWidth":40}}"#) == 40)
    #expect(try width(#"{"type":"text","text":"Ready"}"#, fillsWidth: true, offered: 300) == 300)
    #expect(try width(#"{"type":"text","text":"Ready","style":{"maxWidth":120}}"#, fillsWidth: true, offered: 300) == 120,
            "A popup block fills the width up to its maxWidth")
}

/// A drawing is one frame, so this checks the still shapes: playing in the measuring copy and under
/// Reduce Motion, and settled when the source is off.
@Test @MainActor func equalizersDrawStillWhileMeasuredAndSettleWhenTheirSourceIsOff() throws {
    let style = WidgetStyle(foreground: HexColor(0x2255ccff))
    let block = try decode(PopupBlock.self, #"{"type":"equalizer","source":"playing"}"#)
    let always = try decode(PopupBlock.self, #"{"type":"equalizer"}"#)
    func drawing(_ block: PopupBlock, fields: [String: String] = [:], values: [String: Double] = [:],
                 _ environment: @escaping (inout EnvironmentValues) -> Void) throws -> Drawing {
        let context = BlockContext(values: values, fillsWidth: false, open: { _ in }, runAction: { _, _ in })
        return try draw(PopupBlockView(block: block, inheritedStyle: style, fields: fields, context: context)
            .transformEnvironment(\.self, transform: environment))
    }
    let measuring: (inout EnvironmentValues) -> Void = { $0.measuringBarWidths = true }
    let reduceMotion: (inout EnvironmentValues) -> Void = { $0._accessibilityReduceMotion = true }
    let playing = try drawing(always, measuring)
    #expect(playing.width == 28 && playing.height == 24, "Four 2 pt bars, 2 pt apart, 12 pt tall, at 2×")
    #expect(try drawing(always, reduceMotion).difference(from: playing) <= tolerance)
    for on in [["playing": "1"], ["playing": "true"]] {
        #expect(try drawing(block, fields: on, measuring).difference(from: playing) <= tolerance, "\(on)")
    }
    #expect(try drawing(block, values: ["playing": 1], measuring).difference(from: playing) <= tolerance)
    let settled = try drawing(block, fields: ["playing": ""], measuring)
    #expect(settled.width == playing.width && settled.height == playing.height, "Settling keeps the footprint")
    #expect(settled.difference(from: playing) > tolerance)
    #expect(try drawing(block, measuring).difference(from: settled) <= tolerance, "A missing field is off")
}

@Test func defaultLayoutsDrawTheWidgetsHoverAndOpenStylesWhileConfiguredLayoutsKeepTheirOwnHover() throws {
    let resolution = ResolvedWidgetStyle(base: try decode(WidgetStyle.self, ##"""
    {"foreground":"#111111","states":{"hover":{"fontWeight":"bold","foreground":"#222222"},"open":{"foreground":"#333333"}}}
    """##), state: "warning")
    let byDefault = resolution.layoutStyle(configured: false, hovered: true, open: true)
    #expect(byDefault.inherited == resolution.style(hovered: true, open: true))
    #expect(byDefault.inherited.fontWeight == "bold")
    #expect(byDefault.inherited.foreground == HexColor(0x333333ff))
    #expect(byDefault.states == StyleStates())
    #expect(!byDefault.tracksHover)
    let configured = resolution.layoutStyle(configured: true, hovered: true, open: true)
    #expect(configured.inherited == resolution.base)
    #expect(configured.states == StyleStates(data: "warning", open: true))
    #expect(configured.tracksHover)
    let script = try decode(WidgetConfiguration.self, #"{"id":"w","type":"script","command":"true","position":"right"}"#)
    #expect(script.defaultLayout(WidgetLabel(text: "…", icon: nil, fields: [:]), output: nil, appIcon: false) == nil)
    let spaces = try decode(WidgetConfiguration.self, #"{"id":"w","type":"workspaces","position":"left"}"#)
    #expect(spaces.defaultLayout(WidgetLabel(text: "", icon: nil, fields: [:]), output: nil, appIcon: false) == nil)
}

@Test @MainActor func blocksShowTheirHoverOnlyWhereTheyTrackIt() throws {
    let resolution = ResolvedWidgetStyle(base: try decode(WidgetStyle.self, ##"""
    {"foreground":"#2255cc","states":{"hover":{"foreground":"#cc2222"},"open":{"foreground":"#22aa44"}}}
    """##))
    let text = PopupBlock(content: .text("Ready"))
    func drawing(_ style: LayoutStyle, pointerInside: Bool) throws -> Drawing {
        let context = BlockContext(fillsWidth: false, open: { _ in }, states: style.states, tracksHover: style.tracksHover, runAction: { _, _ in })
        return try draw(PopupBlockView(block: text, inheritedStyle: style.inherited, fields: [:], context: context, pointerInside: pointerInside))
    }
    let configured = resolution.layoutStyle(configured: true, hovered: false, open: false)
    #expect(try drawing(configured, pointerInside: true).difference(from: drawing(configured, pointerInside: false)) > tolerance,
            "A configured layout's block shows its hover")
    let byDefault = resolution.layoutStyle(configured: false, hovered: true, open: true)
    #expect(try drawing(byDefault, pointerInside: true).difference(from: drawing(byDefault, pointerInside: false)) <= tolerance,
            "A default layout's block keeps the hover and open style it inherited")
}

@Test @MainActor func transitionsDrawTextFieldAndSymbolBlocksLikeNoneAtRest() throws {
    let style = WidgetStyle(foreground: HexColor(0x2255ccff), fontSize: 13)
    let blocks = try [#"{"type":"text","text":"Ready 12"}"#, #"{"type":"field","field":"text"}"#, #"{"type":"symbol","name":"bolt.fill"}"#]
        .map { try decode(PopupBlock.self, $0) }
    func drawing(_ block: PopupBlock, _ transition: WidgetTransition) throws -> Drawing {
        let context = BlockContext(fillsWidth: false, open: { _ in }, motion: BlockMotion(transition: transition), runAction: { _, _ in })
        return try draw(PopupBlockView(block: block, inheritedStyle: style, fields: ["text": "Ready 12"], context: context))
    }
    for block in blocks {
        let expected = try drawing(block, .none)
        for transition in [WidgetTransition.fade, .roll, .numeric] {
            let drawn = try drawing(block, transition)
            #expect(drawn.width == expected.width && drawn.height == expected.height, "\(block.content) \(transition)")
            #expect(drawn.difference(from: expected) <= tolerance, "\(block.content) \(transition)")
        }
    }
}

@Test @MainActor func theSoundWidgetShowsItsIconAndTheVolumeOnlyAfterAChange() throws {
    let store = BarStore(configurationURL: FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json"))
    store.configuration = try decode(Configuration.self, #"""
    {"providers":{"speakers":{"type":"audio"}},
     "widgets":[{"id":"sound","type":"audio","position":"right"},
                {"id":"named","type":"provider","provider":"speakers","position":"right"},
                {"id":"icon","type":"text","text":"","icon":"speaker.wave.3","position":"right"}]}
    """#)
    store.preparePresentations()
    for id in ["sound", "named"] {
        let script = ScriptWidget()
        script.output = try ScriptOutput.read(Data(#"""
        {"text":"62%","icon":"speaker.wave.3","value":0.62,"values":{"volume":0.62},"fields":{"device":"Speakers","muted":"false"}}
        """#.utf8))
        script.samples = [0.1, 0.6, 0.35, 0.8, 0.62]
        store.scripts[id] = script
    }
    let widgets = try #require(store.configuration?.widgets)
    let style = ResolvedWidgetStyle(base: WidgetStyle()).layoutStyle(configured: false, hovered: false, open: false)
    func drawing(_ id: String) throws -> Drawing {
        try draw(WidgetBlocks(widget: try #require(widgets.first { $0.id == id }), store: store, style: style, runAction: { _, _ in }))
    }
    let iconOnly = try drawing("icon")
    for id in ["sound", "named"] {
        let rest = try drawing(id)
        #expect(rest.width == iconOnly.width && rest.height == iconOnly.height, "\(id) draws no graph and no volume at rest")
        #expect(rest.difference(from: iconOnly) <= tolerance, "\(id)")
        let presentation = try #require(store.presentations[id])
        presentation.show(TemporaryOutput(fields: ["changedVolume": "62%"], duration: 30), output: 1)
        let changed = try drawing(id)
        #expect(changed.width > rest.width && changed.height == rest.height, "\(id) shows the volume beside its icon after a change")
        presentation.show(TemporaryOutput(fields: ["changedVolume": ""], duration: 30), output: 2)
        #expect(try drawing(id).difference(from: iconOnly) <= tolerance, "\(id) hides the volume when muted")
        var levels: [Drawing] = []
        for volume in [0, 0.2, 0.5, 0.9] {
            store.scripts[id]?.output.icon = AudioMonitor.icon(volume: volume, muted: false)
            levels.append(try drawing(id))
        }
        #expect(levels.allSatisfy { $0.width == rest.width && $0.height == rest.height }, "\(id) keeps its width at every level")
        #expect(zip(levels, levels.dropFirst()).allSatisfy { $0.difference(from: $1) > tolerance }, "\(id) draws each level")
    }
}

@Test @MainActor func hoveringTheSoundWidgetOpensAVolumeSliderOnTheDisplayItIsOn() throws {
    let store = BarStore(configurationURL: FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json"))
    store.configuration = try decode(Configuration.self, #"""
    {"widgets":[{"id":"sound","type":"audio","position":"right"},{"id":"fixed","type":"audio","position":"left"}]}
    """#)
    store.preparePresentations()
    for (id, json) in [("sound", #"{"text":"62%","icon":"speaker.wave.2","value":0.62,"values":{"volume":0.62}}"#),
                       ("fixed", #"{"text":"HDMI","icon":"speaker.wave.2","fields":{"volumeAvailable":"false"}}"#)] {
        let script = ScriptWidget()
        script.output = try ScriptOutput.read(Data(json.utf8))
        store.scripts[id] = script
    }
    let widgets = try #require(store.configuration?.widgets)
    let style = ResolvedWidgetStyle(base: WidgetStyle()).layoutStyle(configured: false, hovered: false, open: false)
    // The measuring copy, as the bar sizes the widget: it follows the presentation, not the pointer.
    func drawing(_ id: String, on display: Int) throws -> Drawing {
        let widget = try #require(widgets.first { $0.id == id })
        return try draw(SoundWidgetView(widget: widget, store: store, monitor: display, style: style, hovered: false, motion: BlockMotion(),
                                        runAction: { _, _ in })
            .environment(\.measuringBarWidths, true))
    }
    let rest = try drawing("sound", on: 1)
    try #require(store.presentations["sound"]).setExpanded(true, on: 1)
    let open = try drawing("sound", on: 1)
    #expect(open.width > rest.width + 2 * 72, "The slider and the volume open beside the icon")
    #expect(open.height == rest.height)
    #expect(try drawing("sound", on: 2).width == rest.width, "Other displays stay closed")
    try #require(store.presentations["sound"]).setExpanded(false, on: 1)
    #expect(try drawing("sound", on: 1).width == rest.width)
    let fixed = try drawing("fixed", on: 1)
    try #require(store.presentations["fixed"]).setExpanded(true, on: 1)
    #expect(try drawing("fixed", on: 1).width == fixed.width, "A device without a volume control has no slider")
    #expect(SoundWidgetView.opensBeforeIcon(.right))
    #expect(WidgetPosition.allCases.filter(SoundWidgetView.opensBeforeIcon) == [.right], "Only the right of the bar grows to the left")
}

@Test(arguments: [true, false]) @MainActor
func hoverExpansionKeepsControlsOutsideTheLabelThroughoutTheAnimation(controlsBefore: Bool) throws {
    for expansion in stride(from: 0.0, through: 1.0, by: 0.1) {
        let drawing = try draw(HoverExpansionLayout(expansion: expansion, spacing: 6, controlsBefore: controlsBefore) {
            Color(.sRGB, red: 0, green: 0, blue: 1).frame(width: 100, height: 16)
            Color(.sRGB, red: 1, green: 0, blue: 0).frame(width: 24, height: 16)
        }.clipped())
        #expect(drawing.height == 32)
        let start = controlsBefore ? drawing.width - 48 : 0
        for x in (start + 2)..<(start + 46) {
            let pixel = (drawing.width * 16 + x) * 4
            #expect(drawing.rgba[pixel] == 255)
            #expect(drawing.rgba[pixel + 2] == 0)
        }
    }
}

@Test @MainActor func hoverLayoutsMeasureTheirExpandedWidthOnOnlyTheHoveredDisplay() throws {
    let store = BarStore(configurationURL: FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json"))
    store.configuration = try decode(Configuration.self, #"""
    {"widgets":[{"id":"timer","type":"text","text":"60m","position":"right",
     "hoverLayout":{"type":"slider","title":"Minutes","source":"duration","min":15,"max":240,"step":15,
                    "onChange":"set-duration","style":{"width":100,"height":16}}}]}
    """#)
    store.preparePresentations()
    let widget = try #require(store.configuration?.widgets.first)
    let layout = try #require(widget.hoverLayout)
    let style = ResolvedWidgetStyle(base: WidgetStyle()).layoutStyle(configured: true, hovered: false, open: false)
    func drawing(on display: Int) throws -> Drawing {
        try draw(HoverLayoutView(widget: widget, layout: layout, store: store, monitor: display, style: style,
                                 hovered: false, motion: BlockMotion(), runAction: { _, _ in }) {
            Text("60m").frame(height: 16)
        }.environment(\.measuringBarWidths, true))
    }
    let rest = try drawing(on: 1)
    try #require(store.presentations["timer"]).setExpanded(true, on: 1)
    let open = try drawing(on: 1)
    #expect(open.width > rest.width + 190)
    #expect(open.height == rest.height)
    #expect(try drawing(on: 2).width == rest.width)
    try #require(store.presentations["timer"]).setExpanded(false, on: 1)
    #expect(try drawing(on: 1).width == rest.width)
}

@Test @MainActor func onlyActiveAppBlocksRedrawWhenTheFrontmostAppChanges() async throws {
    let store = BarStore(configurationURL: FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json"))
    let note = try decode(WidgetConfiguration.self, #"{"id":"note","type":"text","text":"Ready","position":"left"}"#)
    let app = try decode(WidgetConfiguration.self, #"{"id":"app","type":"activeApp","position":"left"}"#)
    let style = ResolvedWidgetStyle(base: WidgetStyle()).layoutStyle(configured: false, hovered: false, open: false)
    await confirmation("The active app redraws", expectedCount: 1) { redrawn in
        await confirmation("The text widget stays valid", expectedCount: 0) { invalidated in
            withObservationTracking { _ = WidgetBlocks(widget: app, store: store, style: style, runAction: { _, _ in }).body } onChange: { redrawn() }
            withObservationTracking { _ = WidgetBlocks(widget: note, store: store, style: style, runAction: { _, _ in }).body } onChange: { invalidated() }
            store.activeApp = NSRunningApplication.current
        }
    }
}

@Test func builtInWidgetsDrawThroughBlocks() {
    let body = String(reflecting: WidgetView.Body.self)
    let drawsBlocks = body.contains("WidgetBlocks")
    let drawsBuiltInLabels = body.contains("BuiltInLabel")
    let keepsWorkspaces = body.contains("WorkspaceView")
    #expect(drawsBlocks)
    #expect(!drawsBuiltInLabels)
    #expect(keepsWorkspaces)
}
