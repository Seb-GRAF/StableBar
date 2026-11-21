import Testing
@testable import StableBar

@Test func aSliderKeepsItsStepTicksOnlyWhereTheyStayApart() {
    // Settings' 110-point number field sliders, whose ticks would all sit closer than 6 points.
    #expect(!SliderSteps(range: 16...100, step: 1).ticksFit(width: 110))
    #expect(!SliderSteps(range: 0...40, step: 1).ticksFit(width: 110))
    #expect(!SliderSteps(range: 0...30, step: 1).ticksFit(width: 110))
    #expect(!SliderSteps(range: 0...20, step: 1).ticksFit(width: 110))
    #expect(!SliderSteps(range: 110...200, step: 5).ticksFit(width: 110))
    #expect(SliderSteps(range: 0...15, step: 1).ticksFit(width: 110))
    // A popup slider's default step, and a coarser one.
    #expect(!SliderSteps(range: 0...1, step: 0.01).ticksFit(width: 260))
    #expect(SliderSteps(range: 0...1, step: 0.1).ticksFit(width: 260))
    // Two stops still need room between their ticks; a step past the range has none to draw.
    #expect(!SliderSteps(range: 0...1, step: 1).ticksFit(width: 25))
    #expect(SliderSteps(range: 0...1, step: 1).ticksFit(width: 26))
    #expect(SliderSteps(range: 0...1, step: 2).ticksFit(width: 10))
}

@Test func aSliderWithoutItsStepRoundsToTheNearestStep() {
    let steps = SliderSteps(range: 110...200, step: 5)
    #expect(steps.stepped(112.4) == 110)
    #expect(steps.stepped(112.6) == 115)
    #expect(steps.stepped(90) == 110)
    #expect(steps.stepped(250) == 200)
    #expect(SliderSteps(range: 0...10, step: 3).stepped(10) == 9)
}

@Test func aSliderWithoutItsStepStillMovesOneStepAtATime() {
    let steps = SliderSteps(range: 16...100, step: 1)
    #expect(steps.step(from: 40, forward: true) == 41)
    #expect(steps.step(from: 40, forward: false) == 39)
    #expect(steps.step(from: 40.4, forward: true) == 41)
    #expect(steps.step(from: 100, forward: true) == 100)
    #expect(steps.step(from: 16, forward: false) == 16)
}

