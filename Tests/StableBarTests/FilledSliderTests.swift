import Foundation
import Testing
@testable import StableBar

private func volume(_ slider: String) -> String {
    #"{"widgets":[{"id":"sound","type":"text","text":"S","position":"right","popup":{"style":{},"layout":{"type":"slider","title":"Volume","source":"volume","onChange":"set","#
        + slider + "}}}]}"
}

@Test func aFilledSliderDecodesWithItsIconRangeAndEndStop() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "filled-slider.json")
    var loader = ConfigurationLoader()
    let configuration = try loader.load(url, data: Data(volume(#""filled":true,"icon":"speaker.wave.2.fill","step":0.05"#).utf8))
    guard case let .filledSlider(title, source, minimum, maximum, step, endStop, icon, command) = configuration.widgets.first?.popup?.layout.content else {
        Issue.record("Expected a filled slider")
        return
    }
    #expect([title, source, command] == ["Volume", "volume", "set"])
    #expect([minimum, maximum, step] == [0, 1, 0.05])
    #expect(endStop == nil)
    #expect(icon == "speaker.wave.2.fill")
    let timer = try loader.load(url, data: Data(volume(#""filled":true,"min":15,"max":240,"step":15,"endStop":{"value":0,"label":"∞"}"#).utf8))
    guard case let .filledSlider(_, _, _, _, _, stop, none, _) = timer.widgets.first?.popup?.layout.content else {
        Issue.record("Expected a filled slider with an end stop")
        return
    }
    #expect(stop == SliderEndStop(value: 0, label: "∞"))
    #expect(none == nil)
    let native = try loader.load(url, data: Data(volume(#""filled":false"#).utf8))
    guard case .slider = native.widgets.first?.popup?.layout.content else {
        Issue.record("Expected the native slider")
        return
    }
}

@Test func anIconWithoutAFilledSliderNamesItsProblem() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "filled-slider.json")
    var loader = ConfigurationLoader()
    let error = #expect(throws: (any Error).self) { try loader.load(url, data: Data(volume(#""icon":"speaker.fill""#).utf8)) }
    #expect(error.map(errorMessage) == #"widgets.sound: popup.layout.icon: Only a filled slider shows an icon; add "filled": true."#)
}

/// A 288-point bar, 40 points tall, over 0–1 in hundredths.
private let bar = FilledSliderTrack(width: 288, height: 40, minimum: 0, maximum: 1, step: 0.01)

@Test func aFilledSlidersFillStartsAsTallAsTheBarAndEndsAtItsWidth() {
    #expect(bar.fillWidth(for: .value(0)) == 40)
    #expect(bar.fillWidth(for: .value(1)) == 288)
    #expect(bar.fillWidth(for: .value(0.5)) == 164)
    #expect(bar.fillWidth(for: .value(-3)) == 40, "Values below the range sit at its start")
    #expect(bar.fillWidth(for: .value(7)) == 288, "Values past the range fill the bar")
    #expect(FilledSliderTrack(width: 30, height: 40, minimum: 0, maximum: 1, step: 0.01).fillWidth(for: .value(0)) == 30,
            "A bar narrower than it is tall is filled, not overrun")
}

@Test func aPointerSetsTheValueWhoseFillEndsUnderIt() {
    #expect(bar.stop(at: 20, from: .value(0.5)) == .value(0), "The cap's center at the start is the minimum")
    #expect(bar.stop(at: 268, from: .value(0.5)) == .value(1))
    #expect(bar.stop(at: 144, from: .value(0)) == .value(0.5))
    #expect(bar.stop(at: -50, from: .value(0.5)) == .value(0))
    #expect(bar.stop(at: 400, from: .value(0.5)) == .value(1), "Without an end stop, nothing lies past the maximum")
    let tenths = FilledSliderTrack(width: 288, height: 40, minimum: 0, maximum: 100, step: 10)
    #expect(tenths.stop(at: 150, from: .value(0)) == .value(50), "Halfway is snapped to the nearest step")
}

@Test func arrowKeysMoveAFilledSliderOneStepWithinItsRange() {
    let tenths = FilledSliderTrack(width: 0, height: 0, minimum: 0, maximum: 100, step: 10)
    #expect(tenths.stop(after: .value(40), forward: true) == .value(50))
    #expect(tenths.stop(after: .value(43), forward: false) == .value(30), "A value between steps moves from its nearest step")
    #expect(tenths.stop(after: .value(100), forward: true) == .value(100))
    #expect(tenths.stop(after: .value(0), forward: false) == .value(0))
}

/// Amphetamine's 15–240 minutes and ∞ on a 288-point bar, 40 points tall: the end stop takes 46 points after an 8-point notch.
private let minutes = FilledSliderTrack(width: 288, height: 40, minimum: 15, maximum: 240, step: 15, endStop: true)

@Test func aFilledSlidersEndStopFollowsANotchAndFillsTheWholeBar() {
    #expect(minutes.rangeEnd == 234)
    #expect(minutes.notchCenter == 238)
    #expect(minutes.stopCenter == 265)
    #expect(minutes.fillWidth(for: .value(15)) == 40)
    #expect(minutes.fillWidth(for: .value(240)) == 234, "The steps fill up to the notch")
    #expect(minutes.fillWidth(for: .end) == 288)
}

@Test func aShortFilledSliderNarrowsItsCapSoItsStepsStillMove() {
    let short = FilledSliderTrack(width: 80, height: 40, minimum: 15, maximum: 240, step: 15, endStop: true)
    #expect(short.cap == 22, "An 8-point notch and a stop 6 points wider than the cap leave 80 − 14 = 66 points for three caps")
    #expect(short.fillWidth(for: .value(15)) == 22)
    #expect(short.fillWidth(for: .value(240)) == 44)
    #expect(short.fillWidth(for: .end) == 80)
    #expect(minutes.cap == 40, "A bar with room keeps a cap as wide as it is tall")
}

@Test func aFilledSliderAsksForRoomToKeepItsFillAsWideAsTheBarIsTall() {
    #expect(FilledSliderTrack.minimumWidth(height: 40, endStop: false) == 80)
    #expect(FilledSliderTrack.minimumWidth(height: 40, endStop: true) == 134)
    let narrowest = FilledSliderTrack(width: 134, height: 40, minimum: 15, maximum: 240, step: 15, endStop: true)
    #expect(narrowest.cap == 40)
    #expect(narrowest.fillWidth(for: .value(15)) == 40, "The fill starts as wide as the bar is tall, so an icon sits on it")
    #expect(narrowest.fillWidth(for: .value(240)) - narrowest.fillWidth(for: .value(15)) == 40, "The steps keep a cap's width of travel")
    let amphetamine = FilledSliderTrack(width: 104, height: 28, minimum: 15, maximum: 240, step: 15, endStop: true)
    #expect(amphetamine.cap == 28, "Amphetamine's 104-point hover slider at the default height keeps its full cap")
}

@Test func draggingAFilledSliderIntoItsNotchSnapsOntoTheEndStop() {
    #expect(minutes.stop(at: 214, from: .value(225)) == .value(240))
    #expect(minutes.stop(at: 239.9, from: .value(240)) == .value(240), "Most of the notch holds the maximum")
    #expect(minutes.stop(at: 240, from: .value(240)) == .end)
    #expect(minutes.stop(at: 236, from: .end) == .end, "Leaving takes most of the notch too")
    #expect(minutes.stop(at: 20, from: .end) == .value(15))
    #expect(minutes.stop(after: .value(240), forward: true) == .end)
    #expect(minutes.stop(after: .end, forward: false) == .value(240))
}
