import Foundation
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
