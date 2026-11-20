@testable import StableBar
import Testing

/// The effects of drawings `times` seconds after the first, each matching the previous one when `matches` says so.
private func effects(_ still: inout StillDrawing, matches: [Bool], ready: Bool = true, loading: Bool = false,
                     times: [Double]? = nil) -> [[StillDrawing.Effect]] {
    matches.indices.map { index in
        let time = times?[index] ?? Double(index) / 10
        return still.handle(.drawn(matchesPrevious: matches[index], ready: ready, loading: loading, at: .seconds(time)))
    }
}

@Test func theDrawingIsKeptOnceTwoInARowMatchThePreviousOne() {
    var still = StillDrawing()
    #expect(effects(&still, matches: [false, true, true]) == [[.drawAgain], [.drawAgain], [.keep]])
}

@Test func aChangedDrawingStartsOver() {
    var still = StillDrawing()
    #expect(effects(&still, matches: [false, true, false, true, true])
            == [[.drawAgain], [.drawAgain], [.drawAgain], [.drawAgain], [.keep]])
}

@Test func drawingsMatchingWhileTheViewsAreNotReadyDoNotCount() {
    var still = StillDrawing()
    #expect(effects(&still, matches: [false, true, true], ready: false) == [[.drawAgain], [.drawAgain], [.drawAgain]])
    #expect(effects(&still, matches: [true, true]) == [[.drawAgain], [.keep]])
}

@Test func aDrawingWithALoadingIndicatorHoldsStillForTheLoadingHold() {
    var still = StillDrawing()
    let hold = Double(StillDrawing.loadingHold.components.seconds)
    #expect(effects(&still, matches: [false, true, true, true], loading: true, times: [0, 0.1, 0.2, hold - 0.1])
            == [[.drawAgain], [.drawAgain], [.drawAgain], [.drawAgain]])
    #expect(effects(&still, matches: [true], loading: true, times: [hold]) == [[.keep]])
}

@Test func aLoadingIndicatorThatGoesAwayEndsTheHold() {
    var still = StillDrawing()
    #expect(effects(&still, matches: [false, true], loading: true) == [[.drawAgain], [.drawAgain]])
    #expect(effects(&still, matches: [false, true, true], times: [0.2, 0.3, 0.4]) == [[.drawAgain], [.drawAgain], [.keep]])
}

@Test func drawingsThatNeverHoldStillFail() {
    var still = StillDrawing()
    let all = effects(&still, matches: Array(repeating: false, count: StillDrawing.limit))
    #expect(all.dropLast().allSatisfy { $0 == [.drawAgain] })
    #expect(all.last == [.fail])
}
