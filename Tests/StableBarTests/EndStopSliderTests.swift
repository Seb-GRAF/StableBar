import AppKit
import SwiftUI
import Testing
@testable import StableBar

private func timer(_ slider: String) -> String {
    #"{"widgets":[{"id":"timer","type":"text","text":"T","position":"right","hoverLayout":{"type":"slider","title":"Minutes","source":"duration","min":15,"max":240,"step":15,"onChange":"set","#
        + slider + "}}]}"
}

@Test func aSliderEndStopDecodesWithItsValueAndLabel() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "end-stop.json")
    var loader = ConfigurationLoader()
    let configuration = try loader.load(url, data: Data(timer(#""endStop":{"value":0,"label":"∞"}"#).utf8))
    guard case let .slider(_, _, minimum, maximum, step, endStop, _) = configuration.widgets.first?.hoverLayout?.content else {
        Issue.record("Expected a slider")
        return
    }
    #expect([minimum, maximum, step] == [15, 240, 15])
    #expect(endStop == SliderEndStop(value: 0, label: "∞"))
    let plain = try loader.load(url, data: Data(timer(#""style":{"width":104}"#).utf8))
    guard case let .slider(_, _, _, _, _, none, _) = plain.widgets.first?.hoverLayout?.content else {
        Issue.record("Expected a slider")
        return
    }
    #expect(none == nil)
}

@Test func sliderEndStopMistakesNameTheirProblem() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "end-stop.json")
    var loader = ConfigurationLoader()
    let mistakes = [
        #""endStop":{"value":60,"label":"∞"}"#: "widgets.timer: hoverLayout.endStop: An end stop's value must be outside min…max, so the slider can tell it from a step.",
        #""endStop":{"value":0,"label":" "}"#: "widgets.timer: hoverLayout.endStop.label: An end stop needs a label, such as ∞.",
        #""endStop":{"value":0,"label":"∞","symbol":"infinity"}"#: "widgets.timer: hoverLayout.endStop.symbol: Unknown property.",
    ]
    for (slider, message) in mistakes {
        let error = #expect(throws: (any Error).self) { try loader.load(url, data: Data(timer(slider).utf8)) }
        #expect(error.map(errorMessage) == message, "\(slider)")
    }
    #expect(throws: (any Error).self) { try loader.load(url, data: Data(timer(#""endStop":{"value":0}"#).utf8)) }
}

/// A 104-point slider with the small control size's 10-point knob, over Amphetamine's 15–240 minutes.
private let minutes = EndStopSliderTrack(width: 104, knobWidth: 10, minimum: 15, maximum: 240, step: 15)

@Test func anEndStopSitsPastANotchAfterTheSteps() {
    #expect(minutes.rangeEnd == 80)
    #expect(minutes.notchCenter == 84)
    #expect(minutes.stopStart == 88)
    #expect(minutes.center(of: .value(15)) == 5)
    #expect(minutes.center(of: .value(240)) == 75)
    #expect(minutes.center(of: .end) == 96)
    #expect(minutes.center(of: .value(1000)) == 75, "Values past max sit on max, not on the end stop")
    #expect(minutes.ticks.count == 16)
    #expect(minutes.ticks.first == 5)
    #expect(minutes.ticks.last == 75)
}

@Test func draggingPastTheMaximumHoldsTheKnobUntilWellIntoTheNotch() {
    #expect(minutes.stop(at: 75, from: .value(225)) == .value(240))
    #expect(minutes.stop(at: 85.9, from: .value(240)) == .value(240))
    #expect(minutes.stop(at: 86, from: .value(240)) == .end)
    #expect(minutes.stop(at: 82, from: .end) == .end, "Leaving takes most of the notch too")
    #expect(minutes.stop(at: 81.9, from: .end) == .value(240))
    #expect(minutes.stop(at: -20, from: .end) == .value(15))
    #expect(minutes.stop(at: 40, from: .value(15)) == .value(135), "Halfway along 70 points is 127.5, the nearest step 135")
}

@Test func arrowKeysStepFromTheMaximumOntoTheEndStopAndBack() {
    #expect(minutes.stop(after: .value(225), forward: true) == .value(240))
    #expect(minutes.stop(after: .value(240), forward: true) == .end)
    #expect(minutes.stop(after: .end, forward: true) == .end)
    #expect(minutes.stop(after: .end, forward: false) == .value(240))
    #expect(minutes.stop(after: .value(15), forward: false) == .value(15))
    let uneven = EndStopSliderTrack(width: 104, knobWidth: 10, minimum: 0, maximum: 1, step: 0.3)
    #expect(uneven.stop(after: .value(0.9), forward: true) == .end, "The last step a step can't pass leads to the end stop")
}

@Test func stepsTooCloseForDotsDrawNone() {
    #expect(EndStopSliderTrack(width: 104, knobWidth: 10, minimum: 0, maximum: 1, step: 0.01).ticks.isEmpty)
}

@MainActor @Observable private final class HostedSlider {
    var value = 60.0
    var disabled = false
    var editing = false
    var sent: [Double] = []
}

private struct HostedSliderView: View {
    let slider: HostedSlider

    var body: some View {
        EndStopSlider(title: "Minutes", value: slider.value, minimum: 15, maximum: 240, step: 15,
                      endStop: SliderEndStop(value: 0, label: "∞")) {
            slider.sent.append($0)
            slider.value = $0
        }
        .labelsHidden()
        .controlSize(.small)
        .disabled(slider.disabled)
        .onPreferenceChange(ControlEditingPreference.self) { slider.editing = $0 }
        .frame(width: 104, height: 20)
    }
}

/// SwiftUI skips `onEnded` for a drag it cancels, as disabling the slider mid-drag does. The slider must then stop
/// editing, so hover controls can collapse, and send nothing.
@Test @MainActor func aCancelledDragStopsEditingAndSendsNothing() async throws {
    let slider = HostedSlider()
    let host = NSHostingView(rootView: HostedSliderView(slider: slider))
    _ = NSApplication.shared
    // SwiftUI needs an ordered window for hit testing. Keep it invisible.
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 104, height: 20), styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    window.contentView = host
    window.orderFrontRegardless()
    defer { window.close() }

    func poll(until condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if condition() { return true }
            await Task.yield()
        }
        return false
    }
    func send(_ type: NSEvent.EventType, x: Double) throws {
        let event = try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: 10), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        window.sendEvent(event)
    }
    try #require(await poll { window.isVisible && host.hitTest(CGPoint(x: 52, y: 10)) != nil })

    // On the 104-point track with a 10-point knob, 60 sits at x 19 and x 40 picks 135.
    try send(.leftMouseDown, x: 19)
    try send(.leftMouseDragged, x: 40)
    #expect(await poll { slider.editing })
    try send(.leftMouseUp, x: 40)
    #expect(await poll { !slider.editing })
    #expect(slider.sent == [135], "A completed drag sends its value")

    try send(.leftMouseDown, x: 40)
    try send(.leftMouseDragged, x: 60)
    #expect(await poll { slider.editing })
    slider.disabled = true
    #expect(await poll { !slider.editing }, "A cancelled drag stops editing")
    slider.disabled = false
    try send(.leftMouseUp, x: 60)
    _ = await poll { false } // Gives a stray `onEnded` its chance to send.
    #expect(slider.sent == [135], "A cancelled drag sends nothing")
}
