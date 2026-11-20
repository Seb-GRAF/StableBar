import AppKit
import Foundation
import Observation
import SwiftUI
import Testing
@testable import StableBar

private func sliderBlock(_ properties: String = "") throws -> PopupBlock {
    try JSONDecoder().decode(PopupBlock.self, from: Data(#"{"type":"slider","title":"Volume","source":"volume","onChange":"set"\#(properties)}"#.utf8))
}

@Test func sliderRolesRespectExplicitChoicesAndOtherwiseFollowTheComposedStyle() throws {
    let roles = ["slider": WidgetStyle(background: .color(HexColor(0x112233ff)), height: 40),
                 "value": WidgetStyle(fontSize: 17)]
    let automatic = try sliderBlock()
    #expect(automatic.automaticallyFillsSlider(roles: roles))
    #expect(automatic.effectiveRole(roles: roles) == .slider)
    #expect(!automatic.automaticallyFillsSlider(roles: [:]))
    #expect(!automatic.automaticallyFillsSlider(roles: ["slider": WidgetStyle()]))
    #expect(automatic.effectiveRole(roles: [:]) == nil)
    #expect(automatic.automaticallyFillsSlider(roles: ["slider": WidgetStyle(cornerRadius: 0)]))
    for properties in [#", "filled":false"#, #", "filled":true"#, #", "role":"value""#] {
        let explicit = try sliderBlock(properties)
        #expect(!explicit.automaticallyFillsSlider(roles: roles))
        let style = explicit.resolvedStyle(inherited: WidgetStyle(), styles: [:], fields: [:], states: StyleStates(), roles: roles)
        #expect(style.box.background == nil, "An explicit choice does not acquire the implicit slider role")
    }
    #expect(try sliderBlock(#", "role":"slider""#).automaticallyFillsSlider(roles: roles))
    let explicit = try sliderBlock(#", "role":"slider", "filled":true"#)
    #expect(explicit.resolvedStyle(inherited: WidgetStyle(), styles: [:], fields: [:], states: StyleStates(), roles: roles).box.height == 40)
}

@Test func automaticSliderStylesPreserveTheCascadeAndSubscribeToModeOnlyWhenUsed() throws {
    let roles = ["slider": WidgetStyle(height: 40, states: ["mode.command": WidgetStyle(accent: HexColor(0xff0000ff))])]
    let slider = try sliderBlock(#", "style":{"height":32}, "styleSource":"live""#)
    let style = slider.resolvedStyle(inherited: WidgetStyle(fontSize: 13), styles: ["live": WidgetStyle(height: 24)], fields: [:],
                                    states: StyleStates(mode: ModePresentation(mode: "tailing", aliases: ["tailing": "command"])), roles: roles)
    #expect(style.box.height == 24)
    #expect(style.text.fontSize == 13)
    #expect(style.text.accent == HexColor(0xff0000ff))
    #expect(slider.usesModeStates(roles: roles))
    #expect(!slider.usesModeStates(roles: [:]))
    #expect(try !sliderBlock(#", "filled":false"#).usesModeStates(roles: roles))
    #expect(try !sliderBlock(#", "filled":true"#).usesModeStates(roles: roles))
}

@Test @MainActor func sliderRolesComposeThroughIncludesTemplatesProfilesAndScreenLooks() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data(#"{"roles":{"slider":{"height":40}},"templates":{"control":{"type":"text","text":"Volume","position":"right","hoverLayout":{"type":"slider","title":"Volume","source":"volume","set":"volume"}}}}"#.utf8)
        .write(to: directory.appending(path: "base.json"))
    let json = #"""
    {"includes":["base.json"],"widgets":[{"id":"control","template":"control"},{"id":"sound","type":"audio","position":"left"}],
     "profiles":[{"name":"p","configuration":{"roles":{"slider":{"cornerRadius":20}}}}],
     "screens":{"monitor":{"roles":{"slider":null}},
       "laptop":{"roles":{"slider":{"states":{"mode.command":{"height":30}}}}}}}
    """#
    var loader = ConfigurationLoader()
    let config = try loader.load(directory.appending(path: "config.json"), data: Data(json.utf8))
    let slider = try #require(config.widgets.first?.hoverLayout)
    #expect(config.roleStyle(.slider).height == 40)
    #expect(config.roleStyle(.slider).cornerRadius == 20)
    #expect(slider.automaticallyFillsSlider(roles: config.roles))
    #expect(config.look(on: .monitor).roleStyle(.slider).height == nil)
    #expect(config.look(on: .monitor).roleStyle(.slider).cornerRadius == 20, "Profiles compose after screen look overrides")
    let withoutProfile = try loader.load(directory.appending(path: "config.json"),
        data: Data(json.replacingOccurrences(of: #""name":"p""#, with: #""name":"p","enabled":false"#).utf8))
    #expect(!slider.automaticallyFillsSlider(roles: withoutProfile.look(on: .monitor).roles))
    #expect(config.needsModeConnection, "A role used only by one screen still subscribes to mode changes")
    #expect(config.look(on: .laptop).usesSliderModeStates(config.widgets[1]))
    #expect(!config.usesSliderModeStates(config.widgets[1]))
}

@Test @MainActor func automaticInlineSlidersFitTheirWholeBoxAndPopupsKeepTheirHeight() throws {
    let style = WidgetStyle(paddingVertical: 3, height: 30, paddingTop: 4, paddingBottom: 6)
    #expect(style.inlineControlHeight == 20)
    #expect(WidgetStyle().inlineControlHeight > 0)
    #expect(WidgetStyle(paddingVertical: 4, height: 0).limitingSliderHeight(to: 20).paddingTop == 0)
    let slider = try sliderBlock()
    let roles = ["slider": WidgetStyle(paddingVertical: 12, height: 40)]
    let resolved = slider.resolvedStyle(inherited: WidgetStyle(), styles: [:], fields: [:], states: StyleStates(), roles: roles)
    let limited = resolved.limitingSliderHeight(to: style.inlineControlHeight).box
    #expect(limited.height == 20)
    #expect((limited.paddingTop ?? 0) + (limited.paddingBottom ?? 0) == 19)
    let popup = NSHostingView(rootView: PopupBlockView(block: slider, inheritedStyle: WidgetStyle(), fields: [:],
        context: BlockContext(roles: roles, fillsWidth: false, open: { _ in }, runAction: { _, _ in })).frame(width: 100))
    let inline = NSHostingView(rootView: PopupBlockView(block: slider, inheritedStyle: WidgetStyle(), fields: [:],
        context: BlockContext(roles: roles, inlineControlHeight: 20, fillsWidth: false, open: { _ in }, runAction: { _, _ in })).frame(width: 100))
    #expect(popup.fittingSize.height == 40)
    #expect(inline.fittingSize.height == 20)
    let nested = try JSONDecoder().decode(PopupBlock.self, from: Data(#"{"type":"row","style":{"paddingVertical":3},"children":[{"type":"slider","title":"Volume","source":"volume","set":"volume"}]}"#.utf8))
    let wrapper = NSHostingView(rootView: PopupBlockView(block: nested, inheritedStyle: WidgetStyle(), fields: [:],
        context: BlockContext(roles: roles, inlineControlHeight: 20, fillsWidth: false, open: { _ in }, runAction: { _, _ in })).frame(width: 100))
    #expect(wrapper.fittingSize.height == 20, "A padded wrapper shares the inline height budget")
    let overflowing = try JSONDecoder().decode(PopupBlock.self, from: Data(#"{"type":"row","style":{"paddingVertical":-3},"children":[{"type":"slider","title":"Volume","source":"volume","set":"volume"}]}"#.utf8))
    let negative = NSHostingView(rootView: PopupBlockView(block: overflowing, inheritedStyle: WidgetStyle(), fields: [:],
        context: BlockContext(roles: roles, inlineControlHeight: 20, fillsWidth: false, open: { _ in }, runAction: { _, _ in })).frame(width: 100))
    #expect(negative.fittingSize.height == 14, "Negative padding doesn't let the inline slider grow past the widget")
}

@MainActor @Observable private final class SliderInteraction {
    var value = 0.2
    var sent: [Double] = []
    var editing = false
    var disabled = false
}

@Test(arguments: [false, true]) @MainActor
func filledSlidersDeliverContinuouslyOnlyWhenRequested(continuous: Bool) async throws {
    let state = SliderInteraction()
    struct Control: View {
        let state: SliderInteraction
        let continuous: Bool
        var body: some View {
            FilledSlider(title: "Volume", value: state.value, minimum: 0, maximum: 1, step: 0.1, endStop: nil, icon: nil,
                         height: 20, drawsTrack: true, appearance: WidgetAppearance(WidgetStyle(), defaults: WidgetStyle()),
                         continuous: continuous) {
                state.sent.append($0)
                state.value = $0
            }
            .disabled(state.disabled)
            .onPreferenceChange(ControlEditingPreference.self) { state.editing = $0 }
            .frame(width: 100, height: 20)
        }
    }
    let host = NSHostingView(rootView: Control(state: state, continuous: continuous))
    _ = NSApplication.shared
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 20), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    window.contentView = host
    window.orderFrontRegardless()
    defer { window.close() }
    func poll(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if condition() { return true }
            await Task.yield()
        }
        return false
    }
    func send(_ type: NSEvent.EventType, x: Double) throws {
        let event = try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: 10), modifierFlags: [], timestamp: 0,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        window.sendEvent(event)
    }
    try #require(await poll { window.isVisible && host.hitTest(CGPoint(x: 26, y: 10)) != nil })
    try send(.leftMouseDown, x: 26)
    try send(.leftMouseDragged, x: 70)
    try #require(await poll { state.editing })
    #expect(continuous ? !state.sent.isEmpty : state.sent.isEmpty)
    try send(.leftMouseUp, x: 70)
    try #require(await poll { !state.editing })
    #expect(state.sent.count == 1, "The final event does not duplicate a continuous update")
    #expect(abs((state.sent.last ?? 0) - 0.8) < 1e-9)
    let sent = state.sent.count
    try send(.leftMouseDown, x: 70)
    try send(.leftMouseDragged, x: 40)
    try #require(await poll { state.editing })
    state.disabled = true
    try #require(await poll { !state.editing })
    #expect(continuous ? state.sent.count > sent : state.sent.count == sent)
}
