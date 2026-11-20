import Testing
@testable import StableBar

@Test func aSliderKeepsItsStepTicksOnlyWhereTheyStayApart() {
    // Settings' 110-point number field sliders.
    #expect(!SliderSteps(range: 16...100, step: 1).ticksFit(width: 110))
    #expect(!SliderSteps(range: 0...40, step: 1).ticksFit(width: 110))
    #expect(SliderSteps(range: 110...200, step: 5).ticksFit(width: 110))
    // A popup slider's default step, and a coarser one.
    #expect(!SliderSteps(range: 0...1, step: 0.01).ticksFit(width: 260))
    #expect(SliderSteps(range: 0...1, step: 0.1).ticksFit(width: 260))
    #expect(SliderSteps(range: 0...1, step: 2).ticksFit(width: 40))
}

@Test func aSliderWithoutItsStepRoundsToTheNearestStep() {
    let steps = SliderSteps(range: 110...200, step: 5)
    #expect(steps.stepped(112.4) == 110)
    #expect(steps.stepped(112.6) == 115)
    #expect(steps.stepped(90) == 110)
    #expect(steps.stepped(250) == 200)
    #expect(SliderSteps(range: 0...10, step: 3).stepped(10) == 9)
}
