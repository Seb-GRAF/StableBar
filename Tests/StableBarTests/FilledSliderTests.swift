import Foundation
import Testing
@testable import StableBar

private func volume(_ slider: String) -> String {
    #"{"widgets":[{"id":"sound","type":"text","text":"S","position":"right","popup":{"style":{},"layout":{"type":"slider","title":"Volume","source":"volume","onChange":"set","#
        + slider + "}}}]}"
}

@Test func aFilledSliderDecodesWithItsIconAndRange() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "filled-slider.json")
    var loader = ConfigurationLoader()
    let configuration = try loader.load(url, data: Data(volume(#""filled":true,"icon":"speaker.wave.2.fill","step":0.05"#).utf8))
    guard case let .filledSlider(title, source, minimum, maximum, step, icon, command) = configuration.widgets.first?.popup?.layout.content else {
        Issue.record("Expected a filled slider")
        return
    }
    #expect([title, source, command] == ["Volume", "volume", "set"])
    #expect([minimum, maximum, step] == [0, 1, 0.05])
    #expect(icon == "speaker.wave.2.fill")
    let native = try loader.load(url, data: Data(volume(#""filled":false"#).utf8))
    guard case .slider = native.widgets.first?.popup?.layout.content else {
        Issue.record("Expected the native slider")
        return
    }
}

@Test func filledSliderMistakesNameTheirProblem() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "filled-slider.json")
    var loader = ConfigurationLoader()
    let mistakes = [
        #""filled":true,"min":0,"max":1,"endStop":{"value":2,"label":"∞"}"#:
            "widgets.sound: popup.layout.filled: A filled slider can't have an end stop.",
        #""icon":"speaker.fill""#: #"widgets.sound: popup.layout.icon: Only a filled slider shows an icon; add "filled": true."#,
    ]
    for (slider, message) in mistakes {
        let error = #expect(throws: (any Error).self) { try loader.load(url, data: Data(volume(slider).utf8)) }
        #expect(error.map(errorMessage) == message, "\(slider)")
    }
}

/// A 288-point bar, 40 points tall, over 0–1 in hundredths.
private let bar = FilledSliderTrack(width: 288, height: 40, minimum: 0, maximum: 1, step: 0.01)

@Test func aFilledSlidersFillStartsAsTallAsTheBarAndEndsAtItsWidth() {
    #expect(bar.fillWidth(for: 0) == 40)
    #expect(bar.fillWidth(for: 1) == 288)
    #expect(bar.fillWidth(for: 0.5) == 164)
    #expect(bar.fillWidth(for: -3) == 40, "Values below the range sit at its start")
    #expect(bar.fillWidth(for: 7) == 288, "Values past the range fill the bar")
    #expect(FilledSliderTrack(width: 30, height: 40, minimum: 0, maximum: 1, step: 0.01).fillWidth(for: 0) == 30,
            "A bar narrower than it is tall is filled, not overrun")
}

@Test func aPointerSetsTheValueWhoseFillEndsUnderIt() {
    #expect(bar.value(at: 20) == 0, "The cap's center at the start is the minimum")
    #expect(bar.value(at: 268) == 1)
    #expect(bar.value(at: 144) == 0.5)
    #expect(bar.value(at: -50) == 0)
    #expect(bar.value(at: 400) == 1)
    let tenths = FilledSliderTrack(width: 288, height: 40, minimum: 0, maximum: 100, step: 10)
    #expect(tenths.value(at: 150) == 50, "Halfway is snapped to the nearest step")
}

@Test func arrowKeysMoveAFilledSliderOneStepWithinItsRange() {
    let tenths = FilledSliderTrack(width: 0, height: 0, minimum: 0, maximum: 100, step: 10)
    #expect(tenths.value(after: 40, forward: true) == 50)
    #expect(tenths.value(after: 43, forward: false) == 30, "A value between steps moves from its nearest step")
    #expect(tenths.value(after: 100, forward: true) == 100)
    #expect(tenths.value(after: 0, forward: false) == 0)
}
