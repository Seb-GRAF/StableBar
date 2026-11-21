import SwiftUI
import Testing
@testable import StableBar

struct SetupMotionTests {
    @Test(arguments: [0.0, 0.08, 0.16])
    func reducedMotionRevealsEveryStageAfterRemoval(delay: Double) {
        let motion = SetupMotion(reduceMotion: true)
        #expect(motion.stepEffect == .fade)
        #expect(motion.revealAnimation(delay: delay) == .easeOut(duration: 0.2).delay(0.2))
        #expect(motion.removalAnimation == .easeOut(duration: 0.2))
    }

    @Test(arguments: [0.0, 0.08, 0.16])
    func fullMotionKeepsTheStaggeredRise(delay: Double) {
        let motion = SetupMotion(reduceMotion: false)
        #expect(motion.stepEffect == .rise)
        #expect(motion.revealAnimation(delay: delay) == .smooth(duration: 0.5).delay(0.22 + delay))
        #expect(motion.removalAnimation == .easeIn(duration: 0.2))
    }

    @Test(arguments: [false, true])
    func scrollingAndFeedbackMoveOnlyWithoutReduceMotion(reduceMotion: Bool) {
        let motion = SetupMotion(reduceMotion: reduceMotion)
        #expect(motion.movement(.smooth(duration: 0.3)) == (reduceMotion ? nil : .smooth(duration: 0.3)))
        #expect(motion.movement(.snappy) == (reduceMotion ? nil : .snappy))
    }

    /// With Reduce Motion, the intro only fades: nothing zooms, rises, sweeps, grows or wipes.
    @Test func reducedMotionIntroOnlyFades() {
        for time in stride(from: 0.0, through: 3, by: 0.05) {
            let intro = SetupIntro(reduceMotion: true, time: time)
            #expect(intro.zoom == 1 && intro.nameRise == 0 && intro.sweep == 0 && intro.line == 0 && intro.glow == 0)
            #expect(intro.open == 1 && intro.widgets == 1)
        }
    }

    /// Each intro has settled by its end, which a click or Return jumps to.
    @Test(arguments: [false, true])
    func introSettlesByItsEnd(reduceMotion: Bool) {
        let end = SetupIntro(reduceMotion: reduceMotion, time: 0).length
        for time in [end, 60] {
            let intro = SetupIntro(reduceMotion: reduceMotion, time: time)
            #expect(intro.wallpaper == 1 && intro.zoom == 1 && intro.softness == 1 && intro.name == 1 && intro.nameRise == 0)
            #expect(intro.glow == 0 && intro.open == 1 && intro.bar == 1 && intro.widgets == 1 && intro.invitation == 1)
        }
        #expect(SetupIntro(reduceMotion: reduceMotion, time: 0).wallpaper == 0)
    }
}
